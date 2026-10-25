#!/usr/bin/perl
# U2 (#84): one continuous list instead of "More…" / "More episodes…" pages.
#
# Program menus (OnDemand::_programMenu) are LMS partial feeds: Slim::Control::XMLBrowser and
# Slim::Web::XMLBrowser pass a code-ref feed index/quantity (the rows a client lists, or the row it
# opens with quantity 1), and the feed answers { items, offset, total }. U2 round 2: rows are
# numbered by audio episode over all of ABC's pages (50 a page; a video card has no row), so every
# page the program has is loaded for any window: page 0 first (its total says which), then the
# others. Covered here: the requests per open, scrolling from the cache, opening one row cold,
# the web UI's pages, the rows before a window that XMLBrowser adds, total and offset, stable ids
# (row i is the same episode whatever the window, with videos dropped across pages too), the
# whole list without a window (Play all), at most 4 requests in flight, a window past the end, no
# request past ABC's total, provider rows, a program page that over- or undercounts, exactly one
# callback.
# U2 review: menus of more than 200 rows have no leading textarea, so every 200-row chunk that
# SqueezePlay/jivelite ask for counts the same (XMLBrowser's menu-mode count is emulated here);
# a failed page of 50 is loaded again as pages of 10 (the first two, then the rest once one
# loads), places that still fail keep an error row, and a failed page isn't asked for again for
# 60 s (per program). U2 round 2: when ABC fails everything, an open asks for page 0 and its
# first 10 only; a rate-limited page isn't asked for in pages of 10.
#
# Collection menus (Collections::_collectionMenu) use the bounded full fetch: every page of the
# collection to 200 cards, at most 4 requests at a time, within 4 s of the first page; a page that
# failed, was empty or was late ends the list (no gap). Covered: the whole list, the cap, the
# concurrency, the deadline (and that a late page is used on the next open), a failed page,
# cross-page duplicates, stable rows, the names looked up for the rows asked for, exactly one
# callback.
#
# Fixtures: the Science Show program page (t/data/ondemand, as t/33) and synthetic episode and
# collection pages served by offset/size like ABC.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $OD          = 'Plugins::ABCListen::OnDemand';
my $SITE        = 'https://www.abc.net.au';
my $BFF         = "$SITE/core-next/api";
my $EPS         = "$BFF/episodesWithSegments/x";
my $COLL        = "$BFF/collection/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $SCIENCE     = '/listen/programs/scienceshow';
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $RATE        = string('PLUGIN_ABCLISTEN_RATE_LIMITED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE_EPS    = "More episodes\x{2026}";    # the row v1.0.0 listed (its token is gone)

my $PROGRAM_MENU = \&Plugins::ABCListen::OnDemand::_programMenu;
my $COLL_MENU    = \&Plugins::ABCListen::Collections::_collectionMenu;
my $HEADER       = 3;      # the Science Show's rows before its episodes: About, presenters, network (no textarea: > 200 rows)
my $TOTAL        = 253;    # ... and 250 episodes

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::Collections->_reset;
	Plugins::ABCListen::OnDemand::_resetProviders();
	setTime(1_792_400_000);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub offset_of { $_[0] =~ /[?&]offset=([0-9]+)/ ? $1 + 0 : undef }
sub page_of   { $_[0] =~ /[?&]offset=([0-9]+)&size=([0-9]+)/ ? "$1/$2" : undef }

sub episode_offsets    { map { offset_of( $_->{url} ) } grep { $_->{url} =~ /episodesWithSegments/ } requests() }
sub episode_pages      { map { page_of( $_->{url} ) } grep { $_->{url} =~ /episodesWithSegments/ } requests() }
sub collection_offsets { map { offset_of( $_->{url} ) } grep { $_->{url} =~ m{/collection/x} } requests() }

# Call a feed as XMLBrowser does, with these args; the collector
sub feed {
	my ( $code, $args, @passthrough ) = @_;
	my $c = collector();
	$code->( undef, $c->cb, $args, @passthrough );
	return $c;
}

sub answer { my ($c) = @_; my ($feed) = $c->args(0); return $feed }
sub names  { [ map { $_->{name} } @{ $_[0] } ] }
sub plays  { [ map { $_->{play} // $_->{name} } @{ $_[0] } ] }

sub science { feed( $PROGRAM_MENU, $_[0], { title => 'The Science Show', path => $SCIENCE } ) }

# Slim::Control::XMLBrowser in menu mode (menu:1: SqueezePlay, jivelite, Squeezer, Material): the
# feed gets index - j, quantity + j (j = min(10, index)); the reply lists rows index .. index +
# quantity - 1 and its count is the feed's total, one lower when a textarea row is among the rows
# it lists (it moves into window.textarea). Returns (count, rows listed).
sub menu_chunk {
	my ( $index, $quantity ) = @_;
	my $j    = $index < 10 ? $index : 10;
	my $feed = answer( science( { index => $index - $j, quantity => $quantity + $j } ) );
	my @rows = grep {defined} @{ $feed->{items} }[ $index - $feed->{offset} .. $index - $feed->{offset} + $quantity - 1 ];
	my $textareas = grep { ( $_->{type} // '' ) eq 'textarea' } @rows;
	return ( $feed->{total} - $textareas, scalar(@rows) - $textareas );
}

# The Science Show program page; its program page says the collection has $detailTotal episodes;
# $description replaces its description (one paragraph)
sub route_science {
	my ( $detailTotal, $description ) = @_;
	my $page = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') );
	$page->{pageProps}->{programCollectionPrepared}->{pagination}->{total} = $detailTotal if defined $detailTotal;
	$page->{pageProps}->{heroDescriptionPrepared} = { descriptionPrepared => { descriptor => { type => 'tagname', key => 'div', children => [ { type => 'tagname', key => 'p', children => [ { type => 'text', content => $description } ] } ] } } } if defined $description;
	route( "$NEXT$SCIENCE.json", content => to_json($page), headers => $JSON_TYPE );
}

# Another program: The Science Show's page at $path, its episode collection $collection
sub route_program {
	my ( $path, $collection ) = @_;
	my $page = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') );
	$page->{pageProps}->{programCollectionPrepared}->{id} = "$collection";
	route( "$NEXT$path.json", content => to_json($page), headers => $JSON_TYPE );
}

my $TEMPLATE = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') )->{pageProps}->{programCollectionPrepared}->{items}->[0];
my $NEWEST   = timegm( 0, 0, 1, 17, 9, 2026 );

sub episode_card {
	my $n    = shift;
	my %card = %$TEMPLATE;
	my $id   = 300000 + $n;
	my @t    = gmtime( $NEWEST - $n * 3 * 86400 );
	$card{contentUri}              = "coremedia://audioepisode/$id";
	$card{cardId}                  = "$id";
	$card{cardTitle}               = "Episode $n";
	$card{articleLink}             = "$SCIENCE/episode-$n/$id";
	$card{cardAttributionPrepared} = { publishedDate => sprintf( '%04d-%02d-%02dT%02d:00:00+00:00', $t[5] + 1900, $t[4] + 1, $t[3], $t[2] ) };
	$card{segments}                = undef;
	return \%card;
}

# ABC's episode pages by offset/size: %opt total (250), have (how many it really holds: total),
# fail => { 'offset/size' or offset => code }, defer => { 'offset/size' or offset => 1 },
# video => { n => 1 } (the card at n is a video: Programs drops it, so its page holds one episode
# fewer), collection (2885458, The Science Show's)
sub route_episodes {
	my %opt        = @_;
	my $total      = defined $opt{total} ? $opt{total} : 250;
	my $have       = defined $opt{have}  ? $opt{have}  : $total;
	my $collection = $opt{collection} || 2885458;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$EPS\E\?collectionId=$collection&}, sub {
		my $url = shift;
		my ( $offset, $size ) = ( offset_of($url), $url =~ /size=([0-9]+)/ );
		my $fail = $opt{fail} && ( $opt{fail}->{"$offset/$size"} || $opt{fail}->{$offset} );
		return { code => $fail } if $fail;
		my @cards = map { $opt{video} && $opt{video}->{$_} ? { %{ episode_card($_) }, contentUri => "coremedia://video/$_", docType => 'video' } : episode_card($_) } grep { $_ < $have } $offset .. $offset + $size - 1;
		return {
			code    => 200,
			headers => $JSON_TYPE,
			content => to_json( { collection => { id => "$collection", items => \@cards, pagination => { offset => $offset, size => $size + 0, total => $total } } } ),
			( $opt{defer} && ( $opt{defer}->{"$offset/$size"} || $opt{defer}->{$offset} ) ? ( defer => 1 ) : () ),
		};
	} );
}

# the episode number of a row (undef for other rows)
sub episode_no { my $item = shift; return $item && ( $item->{name} // '' ) =~ /Episode ([0-9]+)\z/ ? $1 + 0 : undef }

# ---------------------------------------------------------------------------
# Program menu: the window -> ABC page mapping
# ---------------------------------------------------------------------------

subtest 'program menu, first open (menu:1 asks 0..99): every page (page 0, then the 4 others); rows 0..99; offset 0, total 253' => sub {
	fresh();
	route_science();
	route_episodes();

	my $c = science( { index => 0, quantity => 100 } );
	is( $c->count, 1, 'one callback' );
	my $feed = answer($c);
	is( $feed->{offset}, 0,      'offset 0' );
	is( $feed->{total},  $TOTAL, 'total 253: 3 header rows and ABC\'s 250 episodes' );
	is( scalar @{ $feed->{items} }, 100, '100 rows' );
	is_deeply( names( [ @{ $feed->{items} }[ 0 .. 2 ] ] ), [ 'About this program', 'Presented by Robyn Williams, Belinda Smith', 'ABC Radio National' ], 'the header rows first (no textarea: more than 200 rows)' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} }[ 3 .. 99 ] ], [ 0 .. 96 ], 'then episodes 0..96, newest first' );
	is_deeply( [ episode_pages() ], [ map {"$_/50"} 0, 50, 100, 150, 200 ], 'every page of 50 (rows are numbered by episode over all of them): 0, then 50..200' );
	ok( !( grep { ( $_->{name} // '' ) eq $MORE_EPS } @{ $feed->{items} } ), 'no "More episodes…" row' );
};

subtest 'program menu, scrolling (rows 100..199, then 200..252): from the cached pages' => sub {
	fresh();
	route_science();
	route_episodes();
	science( { index => 0, quantity => 100 } );

	my $feed = answer( science( { index => 100, quantity => 100 } ) );
	is( $feed->{offset}, 100,    'offset 100' );
	is( $feed->{total},  $TOTAL, 'total 253' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} } ], [ 97 .. 196 ], 'episodes 97..196' );

	$feed = answer( science( { index => 200, quantity => 100 } ) );
	is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ 200, $TOTAL, 53 ], 'the last window: offset 200, 53 rows to the total' );
	is( episode_no( $feed->{items}->[-1] ), 249, 'the last row: episode 249, ABC\'s 250th' );
	is( scalar( episode_pages() ), 5, 'no request while scrolling (the 5 pages of the first open, cached 15 min)' );
};

subtest 'program menu, SqueezePlay/jivelite chunks of 200 (menu mode): the same count in every chunk (U2 review)' => sub {
	fresh();
	route_science();
	route_episodes();
	my ( $count0, $rows0 ) = menu_chunk( 0,   200 );
	my ( $count1, $rows1 ) = menu_chunk( 200, 200 );
	is( $count0, $TOTAL, 'chunk 0..199: count 253' );
	is( $count1, $count0, 'chunk 200..399: the same count (DB.lua drops its rows when the count changes)' );
	is( $rows0 + $rows1, $TOTAL, '... and the two chunks hold all 253 rows (200 + 53)' );

	# the boundary: the menu has 200 rows or fewer with the textarea -> it stays (one chunk holds it all)
	for my $case ( [ 196, 200, 1 ], [ 197, 200, 0 ] ) {
		my ( $episodes, $rows, $textarea ) = @$case;
		fresh();
		route_science( undef, 'Science, weekly.' );
		route_episodes( total => $episodes );
		my $feed = answer( science( { index => 0, quantity => 200 } ) );
		is( $feed->{total}, $rows, "$episodes episodes: $rows rows" );
		is( ( $feed->{items}->[0]->{type} eq 'textarea' ? 1 : 0 ), $textarea, $textarea ? '... with the textarea first (textarea, About, 2 header rows, 196 episodes = 200: one chunk)' : '... without a textarea (it would make 201 rows: About first)' );
		my ( $count, $listed ) = menu_chunk( 0, 200 );
		is( $listed, $count, '... chunk 0..199 lists every row it counts' );
		my ($next) = menu_chunk( 200, 200 );
		is( $next, $count, '... and a chunk from 200 counts the same' ) unless $textarea;
	}
};

subtest 'program menu, opening one row (index k, quantity 1) cold: the same episode as in the whole list' => sub {
	fresh();
	route_science();
	route_episodes();
	my $whole = answer( science( {} ) )->{items};
	is( scalar @$whole, $TOTAL, '(the whole list: 253 rows)' );

	for my $k ( 0, 1, 2, 3, 52, 53, 103, 153, 252 ) {
		fresh();
		route_science();
		route_episodes();
		my $feed = answer( science( { index => $k, quantity => 1 } ) );
		is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ $k, $TOTAL, 1 ], "row $k: offset $k, total 253, one row" );
		is_deeply( plays( $feed->{items} ), plays( [ $whole->[$k] ] ), "row $k is the whole list's row $k (stable id)" );
	}
	is( scalar( episode_pages() ), 5, 'a cold open of one row loads the program\'s 5 pages (to number the rows)' );
};

subtest 'program menu: XMLBrowser\'s extra rows before a window, and the web UI\'s pages of 50' => sub {
	fresh();
	route_science();
	route_episodes();
	my $whole = answer( science( {} ) )->{items};

	# Slim::Control::XMLBrowser asks index - 10, quantity + 10 (room for context-menu rows)
	my $feed = answer( science( { index => 90, quantity => 110 } ) );
	is_deeply( [ $feed->{offset}, scalar @{ $feed->{items} } ], [ 90, 110 ], 'index 90, quantity 110: rows 90..199' );
	is_deeply( plays( $feed->{items} ), plays( [ @$whole[ 90 .. 199 ] ] ), '... the whole list\'s rows 90..199' );

	# Slim::Web::XMLBrowser: index = the page's start, quantity = itemsPerPage (50)
	for my $start ( 0, 50, 200, 250 ) {
		$feed = answer( science( { isWeb => 1, wantMetadata => 1, wantIndex => 1, index => $start, quantity => 50 } ) );
		my $to = $start + 50 > $TOTAL ? $TOTAL : $start + 50;
		is_deeply( [ $feed->{offset}, $feed->{total} ], [ $start, $TOTAL ], "web page from $start: offset $start, total 253" );
		is_deeply( plays( $feed->{items} ), plays( [ @$whole[ $start .. $to - 1 ] ] ), "... rows $start.." . ( $to - 1 ) );
	}

	# a search-suffixed or odd index: its leading digits; junk: the whole list
	is( answer( science( { index => '7_x', quantity => 1 } ) )->{offset}, 7, 'index "7_x": 7' );
	is( scalar @{ answer( science( { index => 'x', quantity => 5 } ) )->{items} }, $TOTAL, 'index "x": no window, the whole list' );
	is( scalar @{ answer( science( { index => 3, quantity => 0 } ) )->{items} }, $TOTAL, 'quantity 0: the whole list' );
};

subtest 'program menu: no window (playlist commands: Play all / Add all) is the whole list; page 0 first, then at most 4 at once' => sub {
	fresh();
	route_science();
	route_episodes( defer => { map { $_ => 1 } 0, 50, 100, 150, 200 } );

	my $c = science(undef);
	is( $c->count, 0, 'waiting for ABC' );
	is_deeply( [ map { page_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], ['0/50'], 'page 0 alone first (its total says which pages there are)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { page_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ map {"$_/50"} 50, 100, 150, 200 ], 'then the 4 others at once' );
	is( $c->count, 0, 'still waiting' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'then one callback' );
	my $feed = answer($c);
	is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ 0, $TOTAL, $TOTAL ], 'offset 0, total 253, every row' );
	is( scalar( grep { $_->{play} } @{ $feed->{items} } ), 250, 'all 250 episodes playable (what Play all would queue)' );

	# pages of 10 too: never more than 4 in flight
	fresh();
	route_science();
	route_episodes( fail => { '50/50' => 500, '100/50' => 500 }, defer => { map { ( "$_/10" => 1 ) } map { $_ * 10 } 5 .. 14 } );
	$c = science(undef);
	is_deeply( [ map { page_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ '50/10', '60/10', '100/10', '110/10' ], 'pages 50 and 100 failed: their first two pages of 10 (4 in flight)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { page_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ '70/10', '80/10', '90/10', '120/10' ], '... then the rest, 4 at a time' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { page_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ '130/10', '140/10' ], '... and the last 2' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ $c->count, scalar @{ answer($c)->{items} } ], [ 1, $TOTAL ], '... then one callback: every row' );
	is_deeply( [ map { episode_no($_) } @{ answer($c)->{items} }[ $HEADER + 50 .. $HEADER + 149 ] ], [ 50 .. 149 ], '... episodes 50..149 from the pages of 10' );
};

subtest 'program menu: rows are numbered by audio episode; a card that isn\'t one (a video) has no row, and nothing takes its place (U2 round 2)' => sub {
	# a video at 60 (Programs drops it): 249 episodes
	fresh();
	route_science();
	route_episodes( video => { 60 => 1 } );
	my $whole = answer( science( {} ) )->{items};
	is( scalar @$whole, $TOTAL - 1, 'the whole list: 252 rows (3 header rows, 249 episodes)' );
	is_deeply( [ map { episode_no($_) } @$whole[ $HEADER + 59, $HEADER + 60 ] ], [ 59, 61 ], 'the video at 60 has no row: 61 follows 59' );
	is( episode_no( $whole->[ $HEADER + 99 ] ), 100, 'every later episode moves up one, across pages: row 99 is episode 100' );
	is( episode_no( $whole->[-1] ), 249, '... to episode 249, last' );
	is( scalar( grep { !defined episode_no($_) } @$whole[ $HEADER .. $#$whole ] ), 0, 'no row that isn\'t an episode' );
	for my $k ( $HEADER + 59, $HEADER + 60, $HEADER + 99, $HEADER + 150, $#$whole ) {
		fresh();
		route_science();
		route_episodes( video => { 60 => 1 } );
		my $feed = answer( science( { index => $k, quantity => 1 } ) );
		is_deeply( [ $feed->{total}, @{ plays( $feed->{items} ) } ], [ $TOTAL - 1, @{ plays( [ $whole->[$k] ] ) } ], "row $k opened alone, cold: total 252, the whole list's row $k" );
	}

	# Jazztrack on 2026-10-25: videos at 53 and 54 (in rows 53-54 of its page 1)
	fresh();
	route_science();
	route_episodes( video => { 53 => 1, 54 => 1 } );
	my ( $count0, $rows0 ) = menu_chunk( 0,   200 );
	my ( $count1, $rows1 ) = menu_chunk( 200, 200 );
	is_deeply( [ $count0, $count1, $rows0 + $rows1 ], [ $TOTAL - 2, $TOTAL - 2, $TOTAL - 2 ], 'videos at 53, 54: chunks 0..199 and 200..399 both count 251 and hold all 251 rows' );
	is_deeply( [ map { episode_no($_) } @{ answer( science( { index => $HEADER + 52, quantity => 3 } ) )->{items} } ], [ 52, 55, 56 ], '... episodes 52, 55, 56 in rows 52..54' );

	# The Grill: a block of 23 videos mid-list
	fresh();
	route_science();
	route_episodes( video => { map { $_ => 1 } 90 .. 112 } );
	my $feed = answer( science( {} ) );
	is( $feed->{total}, $TOTAL - 23, 'a block of 23 videos (90..112): total 230' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} }[ $HEADER + 89, $HEADER + 90 ] ], [ 89, 113 ], '... episode 113 follows 89' );

	# ABC's list shrank: it says 250, holds 230
	fresh();
	route_science();
	route_episodes( total => 250, have => 230 );
	$feed = answer( science( {} ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} }, episode_no( $feed->{items}->[-1] ) ], [ 233, 233, 229 ], 'ABC says 250 and holds 230: 233 rows, the last episode 229' );

	# the 200-row rule counts episodes, not ABC's cards: 199 cards, 3 of them videos -> 200 rows with the textarea
	fresh();
	route_science( undef, 'Science, weekly.' );
	route_episodes( total => 199, video => { 10 => 1, 70 => 1, 130 => 1 } );
	$feed = answer( science( { index => 0, quantity => 200 } ) );
	is_deeply( [ $feed->{total}, $feed->{items}->[0]->{type} ], [ 200, 'textarea' ], '199 cards, 3 videos: 196 episodes, 200 rows with the textarea first' );
};

subtest 'program menu: a failed page is loaded again as pages of 10; what still fails keeps its places; total never changes (U2 review)' => sub {
	# RN Breakfast on 2026-10-25: ABC fails 150/50 (and 175/25, 190/10) every time, 150/10..180/10 load
	fresh();
	route_science();
	route_episodes( fail => { '150/50' => 500, '190/10' => 500 } );
	my $feed = answer( science( {} ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ $TOTAL, $TOTAL ], 'the whole list: total 253, 253 rows' );
	my @rows = @{ $feed->{items} }[ $HEADER + 150 .. $HEADER + 199 ];
	is_deeply( [ map { episode_no($_) } @rows[ 0 .. 39 ] ], [ 150 .. 189 ], 'episodes 150..189 from the pages of 10' );
	is_deeply( names( [ @rows[ 40 .. 49 ] ] ), [ ($LOAD_FAILED) x 10 ], 'episodes 190..199 (their page of 10 failed too): 10 LOAD_FAILED rows in their places' );
	is( episode_no( $feed->{items}->[ $HEADER + 200 ] ), 200, 'episode 200 in its place' );
	is_deeply( [ grep {m{/10\z}} episode_pages() ], [ map {"$_/10"} 150, 160, 170, 180, 190 ], 'the failed page\'s pages of 10: 150 and 160 first, then the other 3' );

	# every window counts the same (the web UI pages by it; SqueezePlay/jivelite drop their rows when it changes)
	for my $window ( [ 0, 50 ], [ 0, 200 ], [ 150, 50 ], [ 190, 10 ], [ 200, 56 ] ) {
		my ( $index, $quantity ) = @$window;
		my $w = answer( science( { index => $index, quantity => $quantity } ) );
		is( $w->{total}, $TOTAL, "window $index+$quantity: total 253" );
		my $to = $index + $quantity > $TOTAL ? $TOTAL : $index + $quantity;
		is_deeply( names( $w->{items} ), names( [ @{ $feed->{items} }[ $index .. $to - 1 ] ] ), "... the whole list's rows $index.." . ( $to - 1 ) );
	}

	# a failure is remembered for 60 s: no request for it meanwhile
	my $asked = sub { scalar grep { $_ eq $_[0] } episode_pages() };
	my %before = map { $_ => $asked->($_) } '150/50', '190/10';
	advanceTime(59);
	answer( science( { index => 150, quantity => 60 } ) );
	is_deeply( { map { $_ => $asked->($_) } '150/50', '190/10' }, \%before, 'opened again within 60 s: 150/50 and 190/10 not asked for again' );
	advanceTime(2);
	answer( science( { index => 150, quantity => 60 } ) );
	is_deeply( { map { $_ => $asked->($_) - $before{$_} } '150/50', '190/10' }, { '150/50' => 1, '190/10' => 1 }, 'after 60 s: asked for once more each' );

	# the first page of 10 fails, the second loads: the rest are asked for
	fresh();
	route_science();
	route_episodes( fail => { '50/50' => 500, '50/10' => 500 } );
	$feed = answer( science( { index => 0, quantity => 300 } ) );
	is_deeply( [ grep {m{/10\z}} episode_pages() ], [ map {"$_/10"} 50, 60, 70, 80, 90 ], 'page 50 failed, 50/10 failed, 60/10 loaded: 70..90 asked for too' );
	is_deeply( [ map { episode_no($_) // $_->{name} } @{ $feed->{items} }[ $HEADER + 49 .. $HEADER + 60 ] ], [ 49, ($LOAD_FAILED) x 10, 60 ], '... rows 50..59 LOAD_FAILED, 60 on: episodes' );

	# a rate-limited page: not asked for in pages of 10; its 50 places show the rate-limit text
	fresh();
	route_science();
	route_episodes( fail => { '50/50' => 429 } );
	$feed = answer( science( { index => 0, quantity => 300 } ) );
	is_deeply( [ grep {m{/10\z}} episode_pages() ], [], 'page 50 rate limited (429): no pages of 10' );
	is_deeply( [ $feed->{total}, map { $_->{name} } @{ $feed->{items} }[ $HEADER + 50, $HEADER + 99 ] ], [ $TOTAL, $RATE, $RATE ], '... rows 50..99: the RATE_LIMITED text; total 253' );
	is( episode_no( $feed->{items}->[ $HEADER + 100 ] ), 100, '... episode 100 in its place' );

	# page 0 failed, its first 10 load: the total from them (not the program page's 100), the list as usual
	fresh();
	route_science(100);
	route_episodes( fail => { '0/50' => 500 } );
	$feed = answer( science( { index => 0, quantity => 20 } ) );
	is( $feed->{total}, $TOTAL, 'page 0 failed, its first 10 loaded: total 253 (their total, not the program page\'s 100)' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} }[ 3 .. 19 ] ], [ 0 .. 16 ], '... episodes 0..16 from pages of 10' );
	is_deeply( [ episode_pages() ], [ '0/50', '0/10', '10/10', '20/10', '30/10', '40/10', '50/50', '100/50', '150/50', '200/50' ], '... requests: 0/50, 0/10 alone, then page 0\'s other pages of 10 and the other pages' );
	$feed = answer( science( { index => 120, quantity => 10 } ) );
	is_deeply( [ $feed->{total}, map { episode_no($_) } @{ $feed->{items} } ], [ $TOTAL, 117 .. 126 ], '... a window past page 0: total 253, episodes 117..126' );
};

subtest 'program menu: when ABC fails everything, an open asks for page 0 and its first 10 only (U2 round 2)' => sub {
	my @windows = ( [ 'the whole list (Play all)', undef ], [ 'a Jive chunk (menu:1 0..199)', { index => 0, quantity => 200 } ], [ 'a web page (50..99)', { isWeb => 1, index => 50, quantity => 50 } ], [ 'one row (index 120)', { index => 120, quantity => 1 } ] );
	for my $case (@windows) {
		my ( $what, $window ) = @$case;
		fresh();
		route_science();
		route_episodes( fail => { map { ( $_ * 10 ) => 500 } 0 .. 24 } );
		my $feed = answer( science($window) );
		is_deeply( [ episode_pages() ], [ '0/50', '0/10' ], "every page 500, $what: 2 requests (0/50, then 0/10 alone)" );
		is_deeply( [ $feed->{total} ], [5], '... the list: the header (textarea, About, presenters, network) and LOAD_FAILED: total 5' );
		answer( science($window) );
		is( scalar( episode_pages() ), 2, '... opened again within 60 s: no request' );
	}
	my $feed = answer( science( {} ) );
	is( names( $feed->{items} )->[-1], $LOAD_FAILED, 'the last row: LOAD_FAILED' );

	# page 0 rate limited: not even its first 10
	fresh();
	route_science();
	route_episodes( fail => { 0 => 429 } );
	$feed = answer( science( {} ) );
	is_deeply( [ [ episode_pages() ], names( $feed->{items} )->[-1], $feed->{total} ], [ ['0/50'], $RATE, 5 ], 'page 0 rate limited (429): one request; the header and RATE_LIMITED' );

	# page 0 loads, every other page and page of 10 fails: each failed page asks for its first two pages of 10, no more
	fresh();
	route_science();
	route_episodes( fail => { map { ( $_ * 10 ) => 500 } 5 .. 24 } );
	$feed = answer( science( { index => 0, quantity => 200 } ) );
	is_deeply( [ episode_pages() ], [ ( map {"$_/50"} 0, 50, 100, 150, 200 ), ( map {"$_/10"} 50, 60, 100, 110, 150, 160, 200, 210 ) ], 'page 0 loads, the rest fails: 5 pages, then 2 pages of 10 for each failed page (13 requests, 12 failing)' );
	is_deeply( [ $feed->{total}, episode_no( $feed->{items}->[ $HEADER + 49 ] ), $feed->{items}->[ $HEADER + 50 ]->{name} ], [ $TOTAL, 49, $LOAD_FAILED ], '... total 253: episodes 0..49, then LOAD_FAILED in every place' );
	answer( science( { index => 0, quantity => 200 } ) );
	is( scalar( episode_pages() ), 13, '... opened again within 60 s: no request' );
};

subtest 'program menu: the failure cache is per program (U2 round 2)' => sub {
	fresh();
	route_science();
	route_episodes( fail => { '150/50' => 500, 150 => 500, 160 => 500 } );
	route_program( '/listen/programs/other', 4242 );
	route_episodes( collection => 4242 );

	my $science = answer( science( {} ) );
	is( $science->{items}->[ $HEADER + 150 ]->{name}, $LOAD_FAILED, 'The Science Show: page 150 failed (and its first two pages of 10)' );
	my $other = answer( feed( $PROGRAM_MENU, {}, { title => 'Other', path => '/listen/programs/other' } ) );
	is( scalar grep( { $_ eq '150/50' } map { page_of( $_->{url} ) } grep { $_->{url} =~ /collectionId=4242&/ } requests() ), 1, 'another program within 60 s: its page 150 is asked for' );
	is( episode_no( $other->{items}->[ $HEADER + 150 ] ), 150, '... and listed' );
};

subtest 'program menu: never a request past ABC\'s total; a window past the end; a window in the header' => sub {
	fresh();
	route_science(30);
	route_episodes( total => 30 );
	my $feed = answer( science( { index => 0, quantity => 512 } ) );    # Squeezer's page
	is( $feed->{total}, 34, 'a program with 30 episodes, Squeezer\'s 0..511: 34 rows (textarea, About, 2 header rows, 30 episodes)' );
	is_deeply( [ episode_pages() ], ['0/50'], '... one request (page 0), none at 50..200' );

	fresh();
	route_science(250);
	route_episodes( total => 30 );
	answer( science( { index => 0, quantity => 512 } ) );
	is_deeply( [ episode_pages() ], ['0/50'], 'the program page overcounting (250 for 30): page 0\'s total wins, one request' );

	fresh();
	route_science();
	route_episodes( total => 120 );
	$feed = answer( science( { index => 0, quantity => 25000 } ) );    # Material asks for everything at once
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 124, 124 ], 'a program with 120 episodes, quantity 25000 (Material): 124 rows' );
	is_deeply( [ episode_pages() ], [ map {"$_/50"} 0, 50, 100 ], '... pages 0, 50, 100' );
	$feed = answer( science( { index => 0, quantity => 100 } ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 124, 100 ], '... rows 0..99: 100 rows of a total 124 (page 0\'s total, not the program page\'s 250)' );

	fresh();
	route_science();
	route_episodes();
	$feed = answer( science( { index => 300, quantity => 10 } ) );
	is_deeply( [ $feed->{items}, $feed->{offset}, $feed->{total} ], [ [], 300, $TOTAL ], 'past the end: no rows, offset 300, total 253' );

	fresh();
	route_science();
	route_episodes();
	$feed = answer( science( { index => 1, quantity => 1 } ) );
	is_deeply( [ names( $feed->{items} ), $feed->{total} ], [ ['Presented by Robyn Williams, Belinda Smith'], $TOTAL ], 'row 1: Presented by; total 253' );
};

subtest 'program menu: provider rows and a program page that undercounts' => sub {
	fresh();
	route_science();
	route_episodes();
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Follow', type => 'text' }, { name => 'Hint', type => 'text' } ] ) } );

	# header 3 + 2 provider rows: row 104 is episode 99
	my $feed = answer( science( { index => 104, quantity => 1 } ) );
	is( episode_no( $feed->{items}->[0] ), 99, 'row 104: episode 99' );
	is( $feed->{total}, $TOTAL + 2, 'total 255 (5 rows before the episodes)' );

	fresh();
	route_science(50);    # the program page says 50 episodes; ABC has 250
	route_episodes();
	$feed = answer( science( { index => 0, quantity => 500 } ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ $TOTAL, $TOTAL ], 'the program page says 50: page 0\'s total (250) wins, every row' );
	is_deeply( [ episode_offsets() ], [ 0, 50, 100, 150, 200 ], 'page 0, then 50..200' );
};

subtest 'program menu: 100 or more rows after the description: "About this program" even for a short one (Material hides the header)' => sub {
	# rows after the textarea: Presented by, the network, then the episodes
	for my $case ( [ 98, 1 ], [ 97, 0 ], [ 30, 0 ] ) {
		my ( $episodes, $about ) = @$case;
		fresh();
		route_science( undef, 'Science, weekly.' );
		route_episodes( total => $episodes );
		my $feed = answer( science( { index => 0, quantity => 300 } ) );
		is_deeply( $feed->{items}->[0], { name => 'Science, weekly.', type => 'textarea' }, "$episodes episodes: the (short) description first" );
		if ($about) {
			is_deeply( $feed->{items}->[1], { name => 'About this program', type => 'link', items => [ { name => 'Science, weekly.', type => 'textarea' } ] }, "... 2 + $episodes rows after it (>= 100): About this program" );
		}
		else {
			is( $feed->{items}->[1]->{name}, 'Presented by Robyn Williams, Belinda Smith', "... 2 + $episodes rows after it (< 100): no About row" );
		}
		is( $feed->{total}, 1 + $about + 2 + $episodes, "... total " . ( 1 + $about + 2 + $episodes ) );
	}

	# 250 episodes: no textarea (more than 200 rows), About first; the same rows whatever the window
	fresh();
	route_science( undef, 'Science, weekly.' );
	route_episodes( total => 250 );
	my $feed = answer( science( { index => 0, quantity => 300 } ) );
	is_deeply( $feed->{items}->[0], { name => 'About this program', type => 'link', items => [ { name => 'Science, weekly.', type => 'textarea' } ] }, '250 episodes: About this program first, no textarea' );
	is( $feed->{total}, $TOTAL, '... total 253' );
	is_deeply( names( answer( science( { index => 0, quantity => 1 } ) )->{items} ), ['About this program'], 'row 0 opened alone: About this program' );
	is( episode_no( answer( science( { index => 3, quantity => 1 } ) )->{items}->[0] ), 0, 'row 3: episode 0' );
};

subtest 'program menu: exactly one callback' => sub {
	fresh();
	route_science();
	route_episodes( defer => { 50 => 1 } );
	my $calls = 0;
	my $dies  = sub { $calls++; die "LMS broke\n" };
	ok( eval { $PROGRAM_MENU->( undef, $dies, { index => 0, quantity => 100 }, { title => 'The Science Show', path => $SCIENCE } ); 1 }, 'a callback that dies: nothing escapes' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $calls, 1, '... and it is called once' );

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Programs::episodes = sub { my $cb = $_[3]; $cb->( { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ); $cb->( { items => [], total => 0 } ) };
		my $c = science( {} );
		is( $c->count, 1, 'a page that answers twice: one callback' );
		is( names( answer($c)->{items} )->[-1], $LOAD_FAILED, '... with the first answer' );
	}

	for my $slow ( 0, 1 ) {
		fresh();
		route_science();
		route_episodes( defer => { 200 => $slow } );
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::_programHeader = sub { die "header broke\n" };
		my $c = science( { index => 0, quantity => 10 } );
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		my $how = $slow ? 'after ABC answers later (inside its callback)' : 'with the pages answering at once';
		is( $c->count, 1, "building the rows dies once the pages are in, $how: one callback" );
		is_deeply( answer($c)->{items}, [ { name => $LOAD_FAILED, type => 'text' } ], '... the LOAD_FAILED row' );
	}

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Programs::episodes = sub { die "episodes broke\n" };
		my $c = science( {} );
		is( $c->count, 1, 'a page request that dies: one callback' );
		is( names( answer($c)->{items} )->[-1], $LOAD_FAILED, '... LOAD_FAILED after the header' );
	}
};

# ---------------------------------------------------------------------------
# Collection menus: the bounded full fetch
# ---------------------------------------------------------------------------

sub program_card {
	my $n = shift;
	return { contentUri => "coremedia://program/$n", cardId => "$n", cardTitle => "Program $n", articleLink => "$SITE/listen/programs/p$n/" };
}

# A collection of $total program cards in pages by offset/size; fail => { offset => code },
# defer => { offset => 1 }, cards => \@cards (instead of program 1..total)
sub route_collection {
	my ( $id, %opt ) = @_;
	my @cards = $opt{cards} ? @{ $opt{cards} } : map { program_card($_) } 1 .. $opt{total};
	my $total = defined $opt{total} ? $opt{total} : scalar @cards;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$COLL\E\?collectionId=$id&}, sub {
		my $url = shift;
		my ( $offset, $size ) = ( offset_of($url), $url =~ /size=([0-9]+)/ );
		return { code => $opt{fail}->{$offset} } if $opt{fail} && $opt{fail}->{$offset};
		my @page = grep {defined} @cards[ $offset .. $offset + $size - 1 ];
		return {
			code    => 200,
			headers => $JSON_TYPE,
			content => to_json( { collection => { title => "Collection $id", items => \@page, pagination => { offset => $offset, size => $size + 0, total => $total } } } ),
			( $opt{defer} && $opt{defer}->{$offset} ? ( defer => 1 ) : () ),
		};
	} );
}

sub collection { my $id = shift; my $c = feed( $COLL_MENU, {}, { id => $id, title => "Collection $id" }, 0, 1 ); advanceTime(3); return $c }

subtest 'collection menu: 97 cards (Music) as one list; 5 pages of 20; at most 4 in flight' => sub {
	fresh();
	route_collection( 104142058, total => 97, defer => { map { $_ => 1 } 20, 40, 60, 80 } );
	my $c = feed( $COLL_MENU, {}, { id => 104142058, title => 'Music' }, 0, 1 );
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 20, 40, 60, 80 ], 'after the first page: the 4 others at once (4 in flight)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(3);    # program names (not routed: they fail and keep the card titles)
	is( $c->count, 1, 'one callback' );
	my $items = answer($c)->{items};
	is( scalar @$items, 97, '97 rows' );
	is_deeply( names($items), [ map {"Program $_"} 1 .. 97 ], 'in ABC\'s order, no "More…" row' );
	is_deeply( [ collection_offsets() ], [ 0, 20, 40, 60, 80 ], 'pages of 20 at 0..80; nothing at 100' );

	fresh();
	route_collection( 6, total => 200, defer => { map { $_ * 20 => 1 } 1 .. 9 } );
	$c = feed( $COLL_MENU, {}, { id => 6 }, 0, 1 );
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 20, 40, 60, 80 ], '200 cards: 4 later pages in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 100, 120, 140, 160 ], '... as they answer, the next 4' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [180], '... then the last' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 200, '... 200 rows' );

	fresh();
	route_collection( 7, total => 500 );
	my $list = answer( collection(7) )->{items};
	is( scalar @$list, 200, '500 cards: the first 200 (the cap)' );
	is( $list->[-1]->{name}, 'Program 200', '... to Program 200' );
	is_deeply( [ collection_offsets() ], [ map { $_ * 20 } 0 .. 9 ], '10 pages of 20; nothing at 200' );
};

subtest 'collection menu: the 4 s deadline; a late page is left out (no gap) and used on the next open' => sub {
	fresh();
	route_collection( 8, total => 100, defer => { 40 => 1 } );
	my $c = feed( $COLL_MENU, {}, { id => 8, title => 'Eight' }, 0, 1 );
	is( $c->count, 0, 'waiting for the page at 40' );
	advanceTime(3.9);
	is( $c->count, 0, 'still waiting at 3.9 s' );
	advanceTime(0.1);
	advanceTime(3);    # program names
	is( $c->count, 1, 'answered at the 4 s deadline' );
	is_deeply( names( answer($c)->{items} ), [ map {"Program $_"} 1 .. 40 ], 'pages 0 and 20 only: the page at 60 loaded but comes after the late one (no gap)' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late page answers: no second callback' );

	my $again = collection(8);
	is( scalar @{ answer($again)->{items} }, 100, 'the next open: all 100 (every page cached)' );
	is_deeply( [ collection_offsets() ], [ 0, 20, 40, 60, 80 ], '... without a new request' );
};

subtest 'collection menu: a failed or empty page ends the list; the first page\'s error is the menu' => sub {
	fresh();
	route_collection( 9, total => 100, fail => { 60 => 500 } );
	is_deeply( names( answer( collection(9) )->{items} ), [ map {"Program $_"} 1 .. 60 ], 'the page at 60 failed: 60 rows (80 left out too: no gap)' );

	fresh();
	route_collection( 10, total => 100, fail => { 0 => 429 } );
	is_deeply( answer( collection(10) )->{items}, [ { name => $RATE, type => 'text' } ], 'the first page rate-limited: its text row' );
	is_deeply( [ collection_offsets() ], [0], '... and no other request' );

	fresh();
	route_collection( 11, total => 0 );
	is_deeply( answer( collection(11) )->{items}, [ { name => $EMPTY, type => 'text' } ], 'an empty collection: "Nothing here right now"' );
};

subtest 'collection menu: a card on two pages is listed once; the rows are the same on every open' => sub {
	fresh();
	my @cards = map { program_card($_) } 1 .. 30;
	$cards[25] = program_card(3);    # ABC's ranking moved program 3 between the two page loads
	route_collection( 12, cards => \@cards );
	my $first = names( answer( collection(12) )->{items} );
	is( scalar @$first, 29, '30 cards, one of them twice: 29 rows' );
	is( scalar( grep { $_ eq 'Program 3' } @$first ), 1, 'Program 3 once, where it first appears' );
	is_deeply( names( answer( collection(12) )->{items} ), $first, 'opened again: the same rows in the same order (stable ids)' );
};

subtest 'collection menu: program names are looked up only for the rows LMS asks for' => sub {
	my $lookups = sub { scalar grep { $_->{url} =~ m{/_next/data/.*/listen/programs/p[0-9]+\.json} } requests() };

	fresh();
	route_collection( 15, total => 97 );
	my $c = feed( $COLL_MENU, {}, { id => 15 }, 0, 1 );
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 97, 'no window: 97 rows' );
	cmp_ok( $lookups->(), '>=', 12, 'no window (Material asks for everything): every program\'s name is looked up (4 at a time, ' . $lookups->() . ' by the deadline)' );

	fresh();
	route_collection( 15, total => 97 );
	$c = feed( $COLL_MENU, { index => 50, quantity => 1 }, { id => 15 }, 0, 1 );
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 97, 'opening row 50 (index 50, quantity 1): the list is whole (row 50 is Program 51)' );
	is( answer($c)->{items}->[50]->{name}, 'Program 51', '... row 50' );
	advanceTime(30);    # let every lookup that was started finish
	is( $lookups->(), 1, '... and only row 50 had its name looked up' );
	is_deeply( [ map { m{/p([0-9]+)\.json} ? $1 : () } map { $_->{url} } requests() ], [51], '... program 51' );

	fresh();
	route_collection( 15, total => 97 );
	$c = feed( $COLL_MENU, { index => 0, quantity => 20 }, { id => 15 }, 0, 1 );
	advanceTime(30);
	is( $lookups->(), 20, 'rows 0..19 (index 0, quantity 20): 20 names' );

	# cards that list nothing (15 videos, an off-site program) before the window: rows, not cards, count
	fresh();
	my @cards = ( ( map { { contentUri => "coremedia://video/$_", cardId => "$_", cardTitle => "Video $_" } } 1 .. 15 ), { %{ program_card(98) }, articleLink => 'https://example.com/elsewhere' }, map { program_card($_) } 1 .. 40 );
	route_collection( 16, cards => \@cards );
	$c = feed( $COLL_MENU, { index => 5, quantity => 1 }, { id => 16 }, 0, 1 );
	advanceTime(30);
	is( answer($c)->{items}->[5]->{name}, 'Program 6', 'row 5 is Program 6 (card 21)' );
	is_deeply( [ map { m{/p([0-9]+)\.json} ? $1 : () } map { $_->{url} } requests() ], [6], '... and only its name was looked up' );

	# a program ref with a path off ABC's site (itemsFor lists no row for it) before the window
	fresh();
	my @refs = ( { type => 'program', id => '97', title => 'Elsewhere', path => 'https://example.com/listen/programs/p97' }, map { { type => 'program', id => "$_", title => "Program $_", path => "/listen/programs/p$_" } } 1 .. 10 );
	my $got = collector();
	Plugins::ABCListen::Collections->itemsFor( undef, \@refs, 1, $got->cb, { names => [ 2, 3 ] } );
	advanceTime(30);
	my ($items) = $got->args(0);
	is_deeply( [ scalar @$items, $items->[2]->{name} ], [ 10, 'Program 3' ], 'refs: an off-site program path, then programs 1..10: 10 rows, row 2 is Program 3' );
	is_deeply( [ map { m{/p([0-9]+)\.json} ? $1 : () } map { $_->{url} } requests() ], [3], '... rows [2, 3): only Program 3\'s name was looked up (the off-site ref is no row)' );
};

subtest 'collection menu: exactly one callback' => sub {
	fresh();
	route_collection( 13, total => 60, defer => { 20 => 1 } );
	my $calls = 0;
	my $dies  = sub { $calls++; die "LMS broke\n" };
	ok( eval { $COLL_MENU->( undef, $dies, {}, { id => 13 }, 0, 1 ); 1 }, 'a callback that dies: nothing escapes' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(10);
	is( $calls, 1, '... called once' );

	fresh();
	route_collection( 14, total => 60 );
	{
		no warnings 'redefine';
		my $menuPage = \&Plugins::ABCListen::Collections::menuPage;
		local *Plugins::ABCListen::Collections::menuPage = sub { die "page broke\n" if $_[1] == 20; goto &$menuPage };
		my $c = collection(14);
		is( $c->count, 1, 'a page request that dies: one callback' );
		is( scalar @{ answer($c)->{items} }, 20, '... the pages before it' );
	}
};

done_testing();
