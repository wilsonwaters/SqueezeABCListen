#!/usr/bin/perl
# Plugins::ABCListen::Live station menu and day lists (L4; offline, fake clock, any process TZ):
#   * station rows (Radio lists, stationItem for D1/D4) are link + play: exact keys, type link,
#     url = the station menu, passthrough [<ID>], play / favorites_url abclisten://live/<ID>,
#     favorites_type audio, no on_select, no description; a D4-style copy with line2 / description
#     overridden still opens the same menu;
#   * the station menu, in order: Listen live (exact keys: audio, on_select play, the live URL and
#     favourites), "On air: <program> · <presenters>" (fetched within 3 s when not cached, once;
#     "On air: no program information" when unknown, so Today keeps index 2 for stale item ids),
#     Today, Yesterday and 5 dates ("Sat 17 Oct") - station-local (Perth vs Sydney), links with
#     passthrough [<ID>, <date>] and no description;
#   * day lists: a heading "Mon 19 Oct · Sydney time" (text, no image: Material lists the day; the
#     station's clock: Sydney for every eastern zone, Brisbane, Adelaide for Broken Hill, Darwin,
#     Perth), then "6:00am · <program>" names, exactly one " (on air)" (start <= now < end, latest
#     start wins; none in a gap; a row starting this second is on air, one ending this second is
#     not), started rows (start <= now) with a program path built by OnDemand->programItem
#     ($client, { title, path, image, description }) with only name/line1 overridden (line2 =
#     presenters when O2 set none), programItem undef or dying -> text row, future rows and rows
#     without a program path -> text rows (line2 presenters, description synopsis, no image: Material
#     lists the day), the station logo for a program row without an image; a full RN day (31 rows,
#     one on air, rows after it text);
#   * NO_SCHEDULE / LOAD_FAILED / RATE_LIMITED text items; stale or unknown ids and dates; exactly one
#     callback on every path (errors, dying code, a schedule that never answers: 15 s deadline, a
#     dying callback; the deadline is cancelled by a late-but-in-time answer); no player ($client
#     undef, passed on to programItem); no timers left.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use ABCListenTest::FakeClient;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Schedule;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util qw(parseISO8601 ICON);

my $S      = 'Plugins::ABCListen::Stations';
my $NP     = 'Plugins::ABCListen::NowPlaying';
my $SCH    = 'Plugins::ABCListen::Schedule';
my $LIVE   = 'Plugins::ABCListen::Live';
my $BFF    = 'https://www.abc.net.au/core-next/api/';
my $PLAYER = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $prefs  = preferences('plugin.abclisten');

my $MIDDOT = " \x{B7} ";
my $ON_AIR = ' (on air)';

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub t { parseISO8601(shift) }

# ---- a recording wrapper around O2's programItem ----

my ( @PROGRAM_ITEM, $FORCE_PROGRAM_ITEM );
{
	no warnings qw(redefine once);
	my $programItem = \&Plugins::ABCListen::OnDemand::programItem;
	*Plugins::ABCListen::OnDemand::programItem = sub {
		push @PROGRAM_ITEM, [ $_[1], { %{ $_[2] } } ];
		return $FORCE_PROGRAM_ITEM->(@_) if $FORCE_PROGRAM_ITEM;
		goto &$programItem;
	};
}

sub reset_all {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$S->_reset();
	$NP->_reset();
	$SCH->_reset();
	$S->_setRecords();
	@PROGRAM_ITEM       = ();
	$FORCE_PROGRAM_ITEM = undef;
	$prefs->set( homeState => '' );
	setTime( shift || t('2026-10-18T18:45:00Z') );    # 5:45am AEDT Monday 19 Oct: ABC News Daily on air
	return;
}

# Open a link item (or call a feed) like XMLBrowser: ($client, $cb, $args, @passthrough).
sub open_item {
	my ( $client, $item, @passthrough ) = @_;
	my $c    = collector();
	my $code = ref $item eq 'CODE' ? $item : $item->{url};
	$code->( $client, $c->cb, {}, ref $item eq 'HASH' ? @{ $item->{passthrough} || [] } : @passthrough );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub station_menu {
	my ( $client, $id ) = @_;
	my $c = open_item( $client, $LIVE->stationItem( $client, $id ) );
	advanceTime(3);
	is( $c->count, 1, "$id station menu: one callback" );
	return items_of($c);
}

sub day_menu {
	my ( $client, $id, $date ) = @_;
	my $c = open_item( $client, \&Plugins::ABCListen::Live::_dayMenu, $id, $date );
	return $c;
}

sub route_day { route( qr{/core-next/api/schedule\?.*service=$_[0]&}, ref $_[1] ? %{ $_[1] } : ( file => "live/$_[1]" ) ) }

sub names { [ map { $_->{name} } @{ $_[0] } ] }

sub text_item { { name => string(shift), type => 'text' } }

# A day list's heading row and its schedule rows.
sub split_day {
	my @rows    = @{ shift || [] };
	my $heading = shift @rows;
	return ( $heading, \@rows );
}

sub heading { { name => shift() . " \x{B7} " . shift() . ' time', type => 'text' } }

# ---------------------------------------------------------------------------
# Station rows
# ---------------------------------------------------------------------------

subtest 'station rows: link + play, exact keys; stationItem has the same shape (D1, D4)' => sub {
	reset_all();
	my $rec  = $S->get('RN');
	my $logo = Plugins::ABCListen::API::imageUrl( $rec->{logo}, 300 );
	my $row  = $LIVE->stationItem( undef, 'RN' );

	is_deeply( [ sort keys %$row ], [ sort qw(name line1 type url passthrough play favorites_url favorites_type favorites_title image favorites_icon) ], 'exact keys' );
	is( $row->{type}, 'link', 'type link' );
	is( $row->{url}, \&Plugins::ABCListen::Live::_stationMenu, 'url: the station menu' );
	is_deeply( $row->{passthrough}, ['RN'], 'passthrough [RN]' );
	is( $row->{play}, 'abclisten://live/RN', 'play abclisten://live/RN (the play control and the CLI play the station)' );
	is_deeply( [ @$row{qw(favorites_url favorites_type favorites_title favorites_icon image)} ], [ 'abclisten://live/RN', 'audio', 'Radio National', $logo, $logo ], 'favourites: the live URL as audio, the station title and logo' );
	ok( !exists $row->{on_select}, 'no on_select' );
	ok( !exists $row->{description}, 'no description (LMS menu rule 1)' );

	my $copy = { %$row, line2 => 'Event title', description => 'D4 event text' };
	my $c = open_item( undef, $copy );
	is_deeply( names( items_of($c) ), names( station_menu( undef, 'RN' ) ), 'a D4-style copy (line2/description overridden) opens the same station menu' );
};

# ---------------------------------------------------------------------------
# Station menu
# ---------------------------------------------------------------------------

subtest 'station menu: Listen live, On air, Today, Yesterday, 5 dates' => sub {
	reset_all( t('2026-10-19T07:30:00Z') );    # 6:30pm AEDT Monday 19 Oct, The Radio National Hour
	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );

	my $items = station_menu( $PLAYER, 'RN' );
	is_deeply(
		names($items),
		[ 'Listen live', "On air: The Radio National Hour${MIDDOT}Fran Kelly", 'Today', 'Yesterday', 'Sat 17 Oct', 'Fri 16 Oct', 'Thu 15 Oct', 'Wed 14 Oct', 'Tue 13 Oct' ],
		'in order; the dates are the 5 days before yesterday'
	);
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/RN/now} } requests() ), 1, 'the program on air was fetched once (not cached yet)' );

	my $rec  = $S->get('RN');
	my $logo = Plugins::ABCListen::API::imageUrl( $rec->{logo}, 300 );
	my $live = $items->[0];
	is_deeply( [ sort keys %$live ], [ sort qw(name type on_select url favorites_url favorites_title image favorites_icon description) ], 'Listen live: exact keys' );
	is_deeply( [ @$live{qw(type on_select url favorites_url favorites_title image favorites_icon)} ], [ 'audio', 'play', ('abclisten://live/RN') x 2, 'Radio National', $logo, $logo ], 'Listen live: plays abclisten://live/RN, favourites it with the station title and logo' );
	is( $live->{name}, string('PLUGIN_ABCLISTEN_LISTEN_LIVE'), 'Listen live: PLUGIN_ABCLISTEN_LISTEN_LIVE' );
	like( $live->{description}, qr/\AThe Radio National Hour \(.+\) \x{2014} Fran Kelly\n\Q$rec->{synopsis}\E\z/, 'Listen live: description = what is on air, then the synopsis (Default skin detail view)' );
	is_deeply( $items->[1], { name => "On air: The Radio National Hour${MIDDOT}Fran Kelly", type => 'text' }, 'the on-air line: a text item' );

	my @days = @$items[ 2 .. 8 ];
	is_deeply( [ map { $_->{passthrough} } @days ], [ map { [ 'RN', "2026-10-$_" ] } qw(19 18 17 16 15 14 13) ], 'day links: passthrough [RN, date], today first' );
	is( scalar( grep { join( ',', sort keys %$_ ) ne 'name,passthrough,type,url' || $_->{type} ne 'link' || $_->{url} != \&Plugins::ABCListen::Live::_dayMenu } @days ), 0, 'day links: exactly name, type link, url (the day list), passthrough; no description' );
	is_deeply( [ map { $_->{name} } @days[ 0, 1 ] ], [ string('PLUGIN_ABCLISTEN_TODAY'), string('PLUGIN_ABCLISTEN_YESTERDAY') ], 'Today / Yesterday from their tokens' );

	my $again = station_menu( undef, 'RN' );
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/} } requests() ), 1, 'opened again: the program comes from the cache' );

	reset_all( t('2026-10-19T07:30:00Z') );
	route( qr{/epgNowPlaying/}, code => 500 );
	$items = station_menu( undef, 'RN' );
	is_deeply( names($items), [ 'Listen live', 'On air: no program information', 'Today', 'Yesterday', 'Sat 17 Oct', 'Fri 16 Oct', 'Thu 15 Oct', 'Wed 14 Oct', 'Tue 13 Oct' ], 'nothing known on air: "On air: no program information" in its place' );
	is_deeply( $items->[1], text_item('PLUGIN_ABCLISTEN_ON_AIR_UNKNOWN'), '... a text item (PLUGIN_ABCLISTEN_ON_AIR_UNKNOWN)' );
	is( $items->[0]->{description}, $S->get('RN')->{synopsis}, '... and Listen live\'s description is the synopsis' );
};

subtest 'station menu: the program fetch waits at most 3 s; answered once' => sub {
	reset_all( t('2026-10-19T07:30:00Z') );
	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );

	my $c = open_item( undef, $LIVE->stationItem( undef, 'RN' ) );
	is( $c->count, 0, 'waits for the program on air' );
	advanceTime(2.9);
	is( $c->count, 0, 'still at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at 3 s' );
	is_deeply( [ map { $_->{name} } @{ items_of($c) }[ 1, 2 ] ], [ 'On air: no program information', 'Today' ], '... with "no program information"; Today stays third' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late program does not call back again' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left' );
	is( station_menu( undef, 'RN' )->[1]->{name}, "On air: The Radio National Hour${MIDDOT}Fran Kelly", 'next open: the late answer is used' );
};

subtest 'station menu: station-local dates (Perth vs Sydney), time-zone versions, home-state rows' => sub {
	reset_all( t('2026-10-19T14:30:00Z') );    # 1:30am Tue 20 Oct in Sydney, 10:30pm Mon 19 Oct in Perth

	my $perth = station_menu( undef, 'LOCAL_PERTH' );
	is_deeply( [ map { $_->{passthrough} } @$perth[ 2, 3 ] ], [ [ 'LOCAL_PERTH', '2026-10-19' ], [ 'LOCAL_PERTH', '2026-10-18' ] ], 'LOCAL_PERTH: Today is the 19th, Yesterday the 18th (Perth time)' );
	is( $perth->[4]->{name}, 'Sat 17 Oct', '... then Sat 17 Oct' );

	my $rn = station_menu( undef, 'RN' );
	is_deeply( [ map { $_->{passthrough} } @$rn[ 2, 3 ] ], [ [ 'RN', '2026-10-20' ], [ 'RN', '2026-10-19' ] ], 'RN at the same instant: Today is the 20th (Sydney time)' );
	is( $rn->[4]->{name}, 'Sun 18 Oct', '... then Sun 18 Oct' );

	my $tj = station_menu( undef, 'TRIPLEJ_PERTH' );
	is_deeply( $tj->[2]->{passthrough}, [ 'TRIPLEJ_PERTH', '2026-10-19' ], 'a time-zone version: its own id and tz' );
	like( $tj->[0]->{description}, qr/\APerth time - /, '... Listen live says "Perth time - <synopsis>"' );

	$prefs->set( homeState => 'WA' );
	my $radio = collector();
	Plugins::ABCListen::Live::_radioMenu( undef, $radio->cb, {} );
	advanceTime(3);
	my ($row) = grep { $_->{name} eq 'Radio National' } @{ items_of($radio) };
	is_deeply( [ @$row{qw(play passthrough)} ], [ 'abclisten://live/RN_WA', ['RN_WA'] ], 'homeState WA: the Radio National row plays and opens RN_WA' );
	my $c = open_item( undef, $row );
	advanceTime(3);
	is_deeply( items_of($c)->[2]->{passthrough}, [ 'RN_WA', '2026-10-19' ], '... whose Today is Perth\'s (RN WA runs on Perth time)' );
};

subtest 'station menu: Today keeps its index with and without a program on air (stale item ids)' => sub {
	reset_all( t('2026-10-19T07:30:00Z') );
	route( qr{/epgNowPlaying/}, code => 500 );
	my $without = station_menu( undef, 'RN' );
	reset_all( t('2026-10-19T07:30:00Z') );
	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );
	my $with = station_menu( undef, 'RN' );

	is( scalar @$without, scalar @$with, 'the same number of rows' );
	is_deeply( [ map { $_->{name} } $without->[1], $with->[1] ], [ 'On air: no program information', "On air: The Radio National Hour${MIDDOT}Fran Kelly" ], 'row 1: the on-air row either way' );
	is_deeply( [ map { $_->{passthrough} } $without->[2], $with->[2] ], [ ( [ 'RN', '2026-10-19' ] ) x 2 ], 'row 2: Today either way' );
	is_deeply( [ map { $_->{passthrough} } @$without[ 2 .. 8 ] ], [ map { $_->{passthrough} } @$with[ 2 .. 8 ] ], 'rows 2-8: the same days at the same indexes' );
};

# ---------------------------------------------------------------------------
# Day lists
# ---------------------------------------------------------------------------

subtest 'day list: names, (on air), program rows via OnDemand->programItem, text rows' => sub {
	reset_all();
	route_day( RN => 'bff-schedule-RN-day.json' );

	my $c = day_menu( $PLAYER, 'RN', '2026-10-19' );
	my ( $heading, $items ) = split_day( items_of($c) );
	is( $c->count, 1, 'one callback' );
	is_deeply( $heading, heading( 'Mon 19 Oct', 'Sydney' ), 'first a heading: "Mon 19 Oct · Sydney time" (text, no image)' );
	is_deeply(
		names($items),
		[ "12:00am${MIDDOT}Download This Show", "12:30am${MIDDOT}Crowdscience (BBC)", "5:30am${MIDDOT}ABC News Daily and Radio National Hour Highlights$ON_AIR", "6:00am${MIDDOT}Radio National Breakfast" ],
		'"<time> · <program>", the program on air marked " (on air)" in its name'
	);
	is_deeply( [ map { $_->{type} } @$items ], [qw(link text link text)], 'started rows with a program page link; no program page / not started yet: text' );

	is( scalar @PROGRAM_ITEM, 2, 'programItem called for the two started rows with a program path' );
	is( $PROGRAM_ITEM[0]->[0], $PLAYER, '... with the client' );
	my $raw = $SCH->parse( JSON::PP->new->utf8->decode( fixture('live/bff-schedule-RN-day.json') ), 'Australia/Sydney' );
	is_deeply(
		$PROGRAM_ITEM[0]->[1],
		{ title => 'Download This Show', path => '/radionational/programs/downloadthisshow', image => $raw->[0]->{image}, description => $raw->[0]->{synopsis} },
		'programItem($client, { title, path => programPath, image, description => synopsis })'
	);
	is( $PROGRAM_ITEM[1]->[1]->{path}, '/listen/programs/abc-news-daily', '... the on-air row too' );

	my $o2 = Plugins::ABCListen::OnDemand->programItem( $PLAYER, $PROGRAM_ITEM[0]->[1] );
	my %row = %{ $items->[0] };
	is_deeply( [ @row{qw(name line1 line2)} ], [ "12:00am${MIDDOT}Download This Show", "12:00am${MIDDOT}Download This Show", 'Rae Johnston' ], 'name and line1 carry the time; line2 = presenters (O2 set none)' );
	delete @row{qw(name line1 line2)};
	delete @{$o2}{qw(name line1 line2)};
	is_deeply( \%row, $o2, 'everything else is O2\'s row (url, passthrough, image, ...)' );
	is( $items->[0]->{url}, \&Plugins::ABCListen::OnDemand::_programMenu, '... opening O2\'s program menu (catch-up episodes)' );
	ok( !exists $items->[2]->{line2}, 'no presenters: no line2' );
	is( scalar( grep { exists $_->{description} } grep { $_->{type} ne 'text' } @$items ), 0, 'no description on a link row' );
	is( scalar( grep { exists $_->{play} || exists $_->{on_select} } @$items ), 0, 'nothing plays from a day list row itself' );

	is_deeply(
		[ sort keys %{ $items->[3] } ],
		[ sort qw(name line1 line2 type description) ],
		'a text row: name, line1, line2 (presenters), description (synopsis); no image (Material then lists the day instead of a grid)'
	);
	is_deeply( [ @{ $items->[3] }{qw(line2 description)} ], [ 'Sally Sara', $raw->[3]->{synopsis} ], '... presenters and synopsis' );
	like( $items->[2]->{image}, qr{resize\.abcradio\.net\.au}, 'a program row: the schedule\'s image' );
	ok( !exists $items->[1]->{line2}, 'a text row without presenters: no line2' );

	reset_all( t('2026-10-19T08:00:00Z') );    # the whole day has started
	route_day( RN => 'bff-schedule-RN-day.json' );
	( $heading, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is_deeply( [ map { $_->{type} } @$items ], [qw(link text link link)], 'later: every started row with a program page links' );
	is( scalar( grep { $_->{name} =~ /\Q$ON_AIR\E\z/ } @$items ), 0, 'nothing on air at 7pm in this (trimmed) day: no mark' );
	is( $PROGRAM_ITEM[0]->[0], undef, 'no player: programItem gets undef' );
};

subtest 'day list: a full RN day - 31 rows, one on air, rows after it are text' => sub {
	reset_all( t('2026-10-19T23:50:00Z') );    # 10:50am AEDT Tue 20 Oct: Critics Corner (10:45-11:00)
	route_day( RN => 'bff-schedule-RN-2026-10-20.trimmed.json' );

	my ( $heading, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-20' ) ) );
	is_deeply( $heading, heading( 'Tue 20 Oct', 'Sydney' ), 'the heading' );
	is( scalar @$items, 31, 'then one row per schedule item' );
	is( scalar( grep { $_->{name} !~ /\A[0-9]{1,2}:[0-9]{2}[ap]m \x{B7} \S/ } @$items ), 0, 'every name starts with its time ("6:00am · ...")' );
	my @onAir = grep { $items->[$_]->{name} =~ /\Q$ON_AIR\E\z/ } 0 .. $#$items;
	is_deeply( [ map { $items->[$_]->{name} } @onAir ], ["10:45am${MIDDOT}Critics Corner$ON_AIR"], 'exactly one row is on air' );
	is( scalar( grep { $_->{type} ne 'text' } @$items[ $onAir[0] + 1 .. $#$items ] ), 0, 'every row after it is text (future)' );
	is( $items->[ $onAir[0] ]->{type}, 'link', 'the on-air row links to its program' );
	is( $items->[0]->{type}, 'text', 'Radiolab (an off-site URL): text' );
	is( scalar( grep { $_->{type} eq 'link' } @$items ), 12, 'the 12 started rows with a program page link' );
};

subtest 'day list: (on air) with overlaps and gaps; the station logo without an image' => sub {
	my $body = sub {
		JSON::PP->new->encode( { formattedScheduleArray => [ { items => [ map { my ( $s, $e, $title ) = @$_; { rawStartTime => $s, ( $e ? ( rawEndTime => $e ) : () ), title => $title, url => "https://www.abc.net.au/listen/programs/\L$title" } } @_ ] } ] } );
	};

	reset_all( t('2026-10-19T03:15:00Z') );
	route_day( RN => { content => $body->( [ '2026-10-19T01:00:00Z', '2026-10-19T04:00:00Z', 'Long' ], [ '2026-10-19T03:00:00Z', '2026-10-19T03:30:00Z', 'Inside' ] ) } );
	my ( undef, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is_deeply( names($items), [ "12:00pm${MIDDOT}Long", "2:00pm${MIDDOT}Inside$ON_AIR" ], 'two candidates: the latest start is on air' );
	is( $PROGRAM_ITEM[0]->[1]->{image}, Plugins::ABCListen::API::imageUrl( $S->get('RN')->{logo}, 300 ), 'no schedule image: programItem gets the station logo' );
	is( $items->[0]->{image}, Plugins::ABCListen::API::imageUrl( $S->get('RN')->{logo}, 300 ), '... and the row shows it' );
	like( $items->[0]->{image}, qr/cropW=\d+.*width=300/, '... at 300 px' );

	reset_all( t('2026-10-19T02:30:00Z') );
	route_day( RN => { content => $body->( [ '2026-10-19T01:00:00Z', '2026-10-19T02:00:00Z', 'Before' ], [ '2026-10-19T03:00:00Z', '2026-10-19T04:00:00Z', 'After' ] ) } );
	is( scalar( grep {/on air/} @{ names( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) ) } ), 0, 'a gap: nothing marked' );

	# a row starting this very second is on air (and links: it has started); a row ending this very
	# second is not on air, nor is anything in the gap after it
	reset_all( t('2026-10-19T03:00:00Z') );
	route_day( RN => { content => $body->( [ '2026-10-19T02:00:00Z', '2026-10-19T03:00:00Z', 'Ending' ], [ '2026-10-19T03:00:00Z', '2026-10-19T04:00:00Z', 'Starting' ] ) } );
	( undef, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is_deeply( names($items), [ "1:00pm${MIDDOT}Ending", "2:00pm${MIDDOT}Starting$ON_AIR" ], 'start == now: on air; end == now: not on air' );
	is( $items->[1]->{type}, 'link', '... and the row starting now links to its program' );

	reset_all( t('2026-10-19T03:00:00Z') );
	route_day( RN => { content => $body->( [ '2026-10-19T02:00:00Z', '2026-10-19T03:00:00Z', 'Ending' ], [ '2026-10-19T04:00:00Z', '2026-10-19T05:00:00Z', 'Later' ] ) } );
	( undef, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is( scalar( grep {/on air/} @{ names($items) } ), 0, 'now == end with a gap after it: nothing marked' );
	is_deeply( [ map { $_->{type} } @$items ], [qw(link text)], '... the ended row links, the later one is text' );

	reset_all( t('2026-10-19T09:00:00Z') );
	route_day( RN => { content => $body->( [ '2026-10-19T01:00:00Z', '2026-10-19T02:00:00Z', 'First' ], [ '2026-10-19T08:00:00Z', undef, 'Open-ended' ] ) } );
	is( scalar( grep {/on air/} @{ names( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) ) } ), 0, 'the last row without an end: not marked' );
};

subtest 'day list: programItem undef or dying -> a text row' => sub {
	reset_all();
	route_day( RN => 'bff-schedule-RN-day.json' );
	$FORCE_PROGRAM_ITEM = sub {undef};
	my ( undef, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is_deeply( [ map { $_->{type} } @$items ], [qw(text text text text)], 'programItem undef: text rows' );
	is( $items->[0]->{name}, "12:00am${MIDDOT}Download This Show", '... with the same name' );
	is( $items->[0]->{description}, 'Explore the latest in technology, social media, consumer electronics, digital culture and more.', '... and the synopsis' );

	reset_all();
	route_day( RN => 'bff-schedule-RN-day.json' );
	$FORCE_PROGRAM_ITEM = sub { die "O2 broke\n" };
	my $c = day_menu( undef, 'RN', '2026-10-19' );
	is( $c->count, 1, 'programItem dies: one callback' );
	is_deeply( [ map { $_->{type} } @{ items_of($c) } ], [qw(text text text text text)], '... text rows (after the heading)' );
	ok( ( grep { $_->{message} =~ /O2 broke/ } logged('ERROR') ), '... logged' );
};

subtest 'day list heading: the date and the station clock; past days stay a list (Material)' => sub {
	my $body = sub {
		JSON::PP->new->encode( { formattedScheduleArray => [ { items => [ map { { rawStartTime => $_->[0], rawEndTime => $_->[1], title => $_->[2], start => $_->[3],
			url => "https://www.abc.net.au/darwin/programs/\L$_->[2]", cardImagePrepared => { imgSrc => "https://resize.abcradio.net.au/x=/340x340/center/middle/\L$_->[2].jpg" } } } @_ ] } ] } );
	};

	# 105.7 ABC Darwin, yesterday: every row has started and has a program page and an image
	reset_all( t('2026-10-19T06:00:00Z') );    # 3:30pm Darwin, Monday 19 Oct
	route_day( LOCAL_DARWIN => { content => $body->( [ '2026-10-17T15:00:00Z', '2026-10-17T20:30:00Z', 'Overnights', '12:30am' ], [ '2026-10-17T20:30:00Z', '2026-10-17T23:30:00Z', 'Breakfast', '6:00am' ] ) } );
	my $c = day_menu( undef, 'LOCAL_DARWIN', '2026-10-18' );
	my ( $heading, $rows ) = split_day( items_of($c) );
	is_deeply( $heading, heading( 'Sun 18 Oct', 'Darwin' ), 'LOCAL_DARWIN, Sun 18 Oct: "Sun 18 Oct · Darwin time"' );
	ok( !exists $heading->{image} && !exists $heading->{line2}, '... a plain text row: no image, no line2' );
	is_deeply( [ map { [ $_->{type}, $_->{image} ? 1 : 0 ] } @$rows ], [ [ 'link', 1 ], [ 'link', 1 ] ], 'every schedule row is a link with an image (Material would make a grid of it) ...' );
	is( scalar( grep { $_->{type} eq 'text' && !exists $_->{image} } @{ items_of($c) } ), 1, '... and the heading is the text row without an image that keeps it a list' );
	is( $rows->[0]->{name}, "12:30am${MIDDOT}Overnights", 'the schedule rows follow, names unchanged' );

	my %zone = (
		RN               => 'Sydney',      # Australia/Sydney
		LOCAL_MELBOURNE  => 'Sydney',      # Australia/Melbourne: the same eastern clock
		LOCAL_HOBART     => 'Sydney',
		LOCAL_CANBERRA   => 'Sydney',
		LOCAL_BRISBANE   => 'Brisbane',    # no DST
		LOCAL_ADELAIDE   => 'Adelaide',
		LOCAL_BROKENHILL => 'Adelaide',    # Broken Hill keeps Adelaide time
		LOCAL_DARWIN     => 'Darwin',
		LOCAL_PERTH      => 'Perth',
		TRIPLEJ_PERTH    => 'Perth',
	);
	for my $id ( sort keys %zone ) {
		reset_all( t('2026-10-19T06:00:00Z') );
		route_day( $id => { content => $body->( [ '2026-10-17T15:00:00Z', '2026-10-17T20:30:00Z', 'Overnights', '12:30am' ] ) } );
		my ($first) = split_day( items_of( day_menu( undef, $id, '2026-10-18' ) ) );
		is( $first->{name}, "Sun 18 Oct${MIDDOT}$zone{$id} time", "$id ($S->get($id)->{tz}): $zone{$id} time" );
	}
	is( string('PLUGIN_ABCLISTEN_CITY_TIME'), '%s time', '(the clock from PLUGIN_ABCLISTEN_CITY_TIME, as L1\'s "<City> time")' );
};

subtest 'day list: no schedule, errors, stale ids - one readable text item, once' => sub {
	my @cases = (
		[ '{}',               { content => '{}' },                                [ text_item('PLUGIN_ABCLISTEN_NO_SCHEDULE') ] ],
		[ 'empty blocks',     { content => '{"formattedScheduleArray":[{"items":[]}]}' }, [ text_item('PLUGIN_ABCLISTEN_NO_SCHEDULE') ] ],
		[ '500',              { code => 500, content => 'x' },                    [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ],
		[ '429',              { code => 429, content => 'x' },                    [ text_item('PLUGIN_ABCLISTEN_RATE_LIMITED') ] ],
		[ 'bad JSON',         { content => '{"formattedScheduleArray":[' },      [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ],
	);
	for my $case (@cases) {
		my ( $label, $response, $want ) = @$case;
		reset_all();
		route_day( RN => $response );
		my $c = day_menu( undef, 'RN', '2026-10-19' );
		is( $c->count, 1, "$label: one callback" );
		is_deeply( items_of($c), $want, "$label: $want->[0]->{name}" );
	}
	is( string('PLUGIN_ABCLISTEN_NO_SCHEDULE'), 'No schedule available for this day', '(NO_SCHEDULE reads as text)' );

	reset_all();
	route( qr{/core-next/api/schedule\?}, content => '{}' );
	for my $args ( [ 'RN', '2026-13-01' ], [ 'RN', undef ], [ undef, undef ], [ 'rn', '2026-10-19' ] ) {
		my $c = day_menu( undef, @$args );
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ], 'stale/invalid day (' . join( ', ', map { $_ // 'undef' } @$args ) . '): LOAD_FAILED, once' );
	}
	is_deeply( items_of( day_menu( undef, 'NOPE_XYZ', '2026-10-19' ) ), [ text_item('PLUGIN_ABCLISTEN_NO_SCHEDULE') ], 'an unknown station: NO_SCHEDULE' );

	for my $id ( 'NOPE', undef, 'rn', [] ) {
		my $c = open_item( undef, \&Plugins::ABCListen::Live::_stationMenu, $id );
		advanceTime(3);
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ], 'station menu for a stale/unknown id (' . ( ref $id || $id // 'undef' ) . '): LOAD_FAILED, once' );
	}
};

subtest 'day list: exactly one callback when the schedule dies, never answers, or the callback dies' => sub {
	reset_all();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Schedule::day = sub { die "schedule broke\n" };
		my $c = day_menu( undef, 'RN', '2026-10-19' );
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ], 'Schedule->day dies: LOAD_FAILED, once' );
	}
	is( scalar Slim::Utils::Timers::pending(), 0, '... no timer' );

	my $late;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Schedule::day = sub { $late = $_[3] };
		my $c = day_menu( undef, 'RN', '2026-10-19' );
		is( $c->count, 0, 'no answer yet' );
		advanceTime(14.9);
		is( $c->count, 0, 'waits up to 15 s' );
		advanceTime(0.1);
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item('PLUGIN_ABCLISTEN_LOAD_FAILED') ] ], 'at 15 s: LOAD_FAILED' );
		$late->( [] );
		is( $c->count, 1, 'a late schedule does not call back again' );
	}
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left' );

	reset_all();
	route_day( RN => { file => 'live/bff-schedule-RN-day.json', defer => 1 } );
	my $c = day_menu( undef, 'RN', '2026-10-19' );
	is( scalar Slim::Utils::Timers::pending(), 1, 'an answer that is not cached: the deadline timer runs' );
	advanceTime(5);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the schedule arrives after 5 s: answered' );
	is( scalar Slim::Utils::Timers::pending(), 0, '... and the deadline timer is cancelled' );
	advanceTime(20);
	is( $c->count, 1, 'still once after the deadline' );
	is( scalar( grep { $_->{message} =~ /took longer/ } logged('WARN') ), 0, '... and no deadline WARN' );

	reset_all();
	route_day( RN => { content => '{}', defer => 1 } );
	my $calls = 0;
	Plugins::ABCListen::Live::_dayMenu( undef, sub { $calls++; die "skin broke\n" }, {}, 'RN', '2026-10-19' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(20);
	is( $calls, 1, 'a callback that dies is called once (no deadline answer after it)' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left' );

	reset_all();
	route_day( RN => 'bff-schedule-RN-day.json' );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Stations::get = sub { die "catalogue broke\n" };
		my $c = day_menu( undef, 'RN', '2026-10-19' );
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item('PLUGIN_ABCLISTEN_ERROR') ] ], 'building the rows dies: one readable error item, once' );
	}
};

subtest 'accessibility: text conveys the state; names are self-contained' => sub {
	reset_all();
	route_day( RN => 'bff-schedule-RN-day.json' );
	my ( $heading, $items ) = split_day( items_of( day_menu( undef, 'RN', '2026-10-19' ) ) );
	is( scalar( grep { $_->{name} =~ /\(on air\)\z/ && $_->{line1} eq $_->{name} } @$items ), 1, '"(on air)" is in the name and line1 (not only highlight or position)' );
	like( $heading->{name}, qr/\A(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat) [1-9][0-9]? [A-Z][a-z]{2} \x{B7} [A-Z][A-Za-z ]+ time\z/, 'the heading says the date and the clock in words' );
	$items = [ $heading, @$items ];
	is( string('PLUGIN_ABCLISTEN_ON_AIR_MARK'), '(on air)', '(from PLUGIN_ABCLISTEN_ON_AIR_MARK)' );
	my @menu = @{ station_menu( undef, 'RN' ) };
	is( scalar( grep { $_->{type} eq 'link' && $_->{name} !~ /\A(?:Today|Yesterday|(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat) [1-9][0-9]? [A-Z][a-z]{2})\z/ } @menu ), 0, 'day labels are words or full dates' );
	is( scalar( grep { !defined $_->{name} || $_->{name} !~ /\S/ || $_->{name} =~ /PLUGIN_ABCLISTEN/ } @menu, @$items ), 0, 'no empty names, no raw tokens' );
};

done_testing();
