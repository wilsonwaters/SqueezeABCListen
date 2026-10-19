#!/usr/bin/perl
# M2: Plugins::ABCListen::MyABC menus, offline (SimpleAsyncHTTP stub, fake clock, server time zone
# Australia/Sydney):
#   * the top-level "My ABC listen" item (exact keys, weight, menuWeights, last among the hooks' items);
#   * My ABC listen: the empty state (one instructional text item), "Latest episodes" and
#     "Followed programs (N)"; Followed programs as OnDemand->programItem rows, A-Z;
#   * Latest episodes over three routed programs: merge order (date, then program, then id; undated
#     last), one row per episode (its own program wins), the 50 cap, "<program>: " name/line1
#     prefixes with the meta-cache title untouched, O2's programTitle rule, at most 4 programs in
#     flight, a failing program skipped, all failing -> LOAD_FAILED, nothing -> NO_EPISODES, the
#     25 s deadline (late results ignored), the 15 min cache (no request on a hit; a follow starts a
#     new list), exactly one callback (also when LMS's callback dies);
#   * the program-menu provider (OnDemand's registry): two follow rows from isFollowed (Follow + hint
#     text, or "✓ Following" text + Unfollow), explicit op, [] without a path, exactly one callback;
#     through OnDemand's real program menu;
#   * the action: idempotent explicit op (never a toggle), the confirmation text item with
#     showBriefly / nextWindow, LOAD_FAILED for a bad request;
#   * stale item ids on a rebuilt menu (program menu and song info, follow and unfollow): re-opening
#     any id from before the change never changes the stored follows, and no later row moves;
#   * the song-info provider: the follow rows only for episode URLs whose meta-cache entry has a path
#     under /programs/ or /audiobooks/ and a programTitle; the named labels follow the state; undef
#     for live and foreign URLs; no HTTP; an exception contained.
#
# Fixtures: t/data/ondemand/nextdata-program-scienceshow.trimmed.json (O2), the F3 search page
# t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f), and t/data/myabc/
# (synthetic, shaped like the recorded cards): Classic Drive and Hack program pages, the newest 5
# episodes of The Science Show (4 own, one undated, plus a Lab Notes episode), Classic Drive (5)
# and Hack (two at the same time, one undated, plus Classic Drive's 107300002). Programs for the cap,
# concurrency and deadline cases are generated in code.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();

use Slim::Menu::TrackInfo;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;
use Slim::Web::Settings;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Follow;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $MY        = 'Plugins::ABCListen::MyABC';
my $F         = 'Plugins::ABCListen::Follow';
my $SITE      = 'https://www.abc.net.au';
my $EPS       = "$SITE/core-next/api/episodesWithSegments/x";
my $NEXT      = "$SITE/_next/data/build-3afcd04f";
my $SCIENCE   = '/listen/programs/scienceshow';
my $CLASSIC   = '/listen/programs/classic-drive';
my $HACK      = '/triplej/programs/hack';
my $T0        = 1_792_400_000;    # Mon 19 Oct 2026, 19:53 in Sydney
my $ICON      = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $ENDASH    = "\x{2013}";

my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $NO_EPISODES = string('PLUGIN_ABCLISTEN_NO_EPISODES');
my $HELP        = string('PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP');

my $MY_ABC      = \&Plugins::ABCListen::MyABC::_myABC;
my $LATEST      = \&Plugins::ABCListen::MyABC::_latestEpisodes;
my $FOLLOWED    = \&Plugins::ABCListen::MyABC::_followedPrograms;
my $ACTION      = \&Plugins::ABCListen::MyABC::_followAction;
my $EXTRAS      = \&Plugins::ABCListen::MyABC::_programMenuExtras;
my $TRACKINFO   = \&Plugins::ABCListen::MyABC::_trackInfo;
my $PROGRAM     = \&Plugins::ABCListen::OnDemand::_programMenu;
my $EPISODE     = \&Plugins::ABCListen::OnDemand::_episodeMenu;

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

my %SCIENCE_SHOW = ( title => 'The Science Show', path => $SCIENCE, id => '2885500', image => 'https://live-production.wcms.abc-cdn.net.au/a9bfe6ad8b283391297dd347dd60de8f?width=862&height=862', network => 'Radio National' );
my %CLASSIC_DRIVE = ( title => 'Classic Drive', path => $CLASSIC, id => '90000101', network => 'ABC Classic' );
my %HACK_SHOW     = ( title => 'Hack', path => $HACK, network => 'triple j' );

# ---- helpers ----

sub prefs { preferences('plugin.abclisten') }

sub fresh {
	Slim::Networking::SimpleAsyncHTTP->reset;
	Slim::Utils::Timers->reset;
	Slim::Utils::Cache->resetAll;
	Slim::Utils::Log->resetMessages;
	Slim::Menu::TrackInfo->reset;
	Slim::Web::Settings->reset;
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::OnDemand::_resetProviders();
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
	$MY->init();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	return;
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

sub route_science_menu {
	route( "$NEXT$SCIENCE.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	route( qr{\Q$EPS\E\?collectionId=2885458&offset=0&size=50\z}, file => 'myabc/bff-episodesWithSegments-scienceshow-latest.synthetic.json', headers => $JSON_TYPE );
}

sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item { my ( $item, $client ) = @_; return feed( $item->{url}, $client, @{ $item->{passthrough} || [] } ) }

# LMS keeps no browse session for this plugin (its top level has code-ref feeds), so every item_id
# request rebuilds the menu and walks it by index (Slim::Control::XMLBrowser): $build->() returns
# the rebuilt items, then each index opens that row's feed. A row without a feed (a text row) ends
# the walk and opening it changes nothing. Returns the last feed's items, or that row.
sub open_id {
	my ( $build, @index ) = @_;
	my $items = $build->();
	for my $i (@index) {
		my $item = $items->[$i];
		return $item unless ref $item eq 'HASH' && ref $item->{url} eq 'CODE';
		$items = items_of( open_item($item) );
	}
	return $items;
}

# The indexes of the rows a client can open (and so can hold an item id for).
sub openable { my $items = shift; return grep { ref $items->[$_]->{url} eq 'CODE' } 0 .. $#$items }

# The index of the row whose passthrough op is $op ('follow' | 'unfollow').
sub op_index {
	my ( $items, $op ) = @_;
	my @found = grep { my $pt = $items->[$_]->{passthrough}; ref $pt eq 'ARRAY' && ref $pt->[0] eq 'HASH' && ( $pt->[0]->{op} || '' ) eq $op } 0 .. $#$items;
	return $found[0];
}

sub stored_follows { to_json( prefs()->get('followed') ) }

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }
sub plays { [ map { ( $_->{play} || '' ) =~ m{/([0-9]+)\z} ? $1 : undef } @{ $_[0] } ] }

sub text_item { { name => $_[0], type => 'text' } }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty name" );
}

sub program_requests { grep {m{/_next/data/.*/(?:listen|triplej)/programs/}} map { $_->{url} } requests() }
sub episode_requests { grep {/episodesWithSegments/} map { $_->{url} } requests() }

sub warnings_logged { map { $_->{message} } grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub errors_logged   { map { $_->{message} } grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

sub route_three {
	route( "$NEXT$SCIENCE.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	route( "$NEXT$CLASSIC.json", file => 'myabc/nextdata-program-classic-drive.synthetic.json', headers => $JSON_TYPE );
	route( "$NEXT$HACK.json",    file => 'myabc/nextdata-program-hack.synthetic.json',          headers => $JSON_TYPE );
	route( "$EPS?collectionId=2885458&offset=0&size=5",  file => 'myabc/bff-episodesWithSegments-scienceshow-latest.synthetic.json', headers => $JSON_TYPE );
	route( "$EPS?collectionId=90000102&offset=0&size=5", file => 'myabc/bff-episodesWithSegments-classic-drive.synthetic.json',      headers => $JSON_TYPE );
	route( "$EPS?collectionId=90000202&offset=0&size=5", file => 'myabc/bff-episodesWithSegments-hack.synthetic.json',               headers => $JSON_TYPE );
}

sub follow_three { $F->follow($_) for {%SCIENCE_SHOW}, {%CLASSIC_DRIVE}, {%HACK_SHOW} }

# Generated programs /listen/programs/gen-<n>: a program page (collection 91000000 + n) and its
# newest 5 episodes, published at $T0 - (n * 5 + i) hours. %opt: defer => 1 for the page.
sub route_generated {
	my ( $n, %opt ) = @_;
	my $path = "/listen/programs/gen-$n";
	my $collection = 91_000_000 + $n;

	route( "$NEXT$path.json", headers => $JSON_TYPE, ( $opt{defer} ? ( defer => 1 ) : () ), content => to_json( { pageProps => {
		heroImageWithCTAPrepared  => { heading => "Generated $n", uri => "coremedia://program/9200000$n" },
		programCollectionPrepared => { id => "$collection", items => [], pagination => { offset => 0, size => 10, total => 5 } },
		programTemplate           => 'audio',
		webDistributionRestricted => JSON::PP::false,
	} } ) );

	my @cards = map {
		my $id = 108_000_000 + $n * 10 + $_;
		my @t  = gmtime( $T0 - ( $n * 5 + $_ ) * 3600 );
		+{
			articleLink                => "$path/episode-$_/$id",
			contentUri                 => "coremedia://audioepisode/$id",
			cardId                     => "$id",
			cardTitle                  => "Gen $n episode $_",
			docType                    => 'audioepisode',
			cardAttributionPrepared    => { publishedDate => sprintf( '%04d-%02d-%02dT%02d:%02d:%02d+00:00', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] ) },
			cardMediaIndicatorPrepared => { duration => 1800 },
		}
	} 0 .. 4;

	route( "$EPS?collectionId=$collection&offset=0&size=5", headers => $JSON_TYPE, ( $opt{deferEpisodes} ? ( defer => 1 ) : () ),
		content => to_json( { collection => { id => "$collection", items => \@cards, pagination => { offset => 0, size => 5, total => 5 } } } ) );

	return { title => "Generated $n", path => $path };
}

# ---------------------------------------------------------------------------
# Top level and My ABC listen
# ---------------------------------------------------------------------------

subtest 'top level: one "My ABC listen" link with the myabc weight; menuWeights; last of all' => sub {
	fresh();
	my $c = collector();
	$MY->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'one callback' );
	is_deeply(
		( $c->args(0) )[0],
		[ { name => 'My ABC listen', type => 'link', url => $MY_ABC, image => $ICON, weight => 90 } ],
		'exact keys: name, type link, url _myABC, icon, weight'
	);
	is( ( $c->args(0) )[0]->[0]->{weight}, Plugins::ABCListen::Util::topWeight('myabc'), 'weight = Util::topWeight("myabc")' );
	is( ( $c->args(0) )[0]->[0]->{name}, string('PLUGIN_ABCLISTEN_MY_ABC'), 'from PLUGIN_ABCLISTEN_MY_ABC' );
	is_deeply( [ $MY->menuWeights ], [ Plugins::ABCListen::Util::topWeight('myabc') ], 'menuWeights = (topWeight("myabc"))' );
	is( scalar requests(), 0, 'no network access for the top level' );

	no warnings qw(redefine once);
	my $top = sub { my $name = shift; return { name => "Top $name", type => 'link', url => 'https://example.test/', weight => Plugins::ABCListen::Util::topWeight($name) } };
	local *Plugins::ABCListen::Live::menuItems     = sub { $_[2]->( [ $top->('radio') ] ) };
	local *Plugins::ABCListen::OnDemand::menuItems = sub { $_[2]->( [ $top->('programs') ] ) };
	local *Plugins::ABCListen::Discover::menuItems = sub { $_[2]->( [ map { $top->($_) } qw(home podcasts news sport kids audiobooks) ] ) };
	local *Plugins::ABCListen::Search::menuItems   = sub { $_[2]->( [ $top->('search') ] ) };

	$c = collector();
	Plugins::ABCListen::Plugin::toplevel( ABCListenTest::FakeClient->new('00:00:00:00:00:01'), $c->cb, { params => {} } );
	my ($result) = $c->args(0);
	is( $result->{items}->[-1]->{name}, 'My ABC listen', 'My ABC listen is the last top-level item' );
	is( scalar @{ $result->{items} }, 10, 'ten top-level items' );
};

subtest 'My ABC listen: no follows -> one instructional text item' => sub {
	fresh();
	my $c = feed( $MY_ABC, undef );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ text_item('Open any program and choose Follow') ], 'exactly one text item: the NO_FOLLOWED_HELP text' );

	is_deeply( items_of( feed( $LATEST,   undef ) ), [ text_item($HELP) ], 'Latest episodes with no follows (stale menu): the same help text' );
	is_deeply( items_of( feed( $FOLLOWED, undef ) ), [ text_item($HELP) ], 'Followed programs with no follows (stale menu): the same help text' );
	is( scalar requests(), 0, 'no network access' );
};

subtest 'My ABC listen with follows: Latest episodes, Followed programs (N)' => sub {
	fresh();
	follow_three();
	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');

	for my $who ( [ 'no player', undef ], [ 'a player', $client ] ) {
		my $c = feed( $MY_ABC, $who->[1] );
		is( $c->count, 1, "$who->[0]: one callback" );
		is_deeply(
			items_of($c),
			[
				{ name => 'Latest episodes',       type => 'link', url => $LATEST,   image => $ICON },
				{ name => 'Followed programs (3)', type => 'link', url => $FOLLOWED, image => $ICON },
			],
			"$who->[0]: exact items; the count in the name"
		);
	}

	$F->unfollow($HACK);
	is( items_of( feed( $MY_ABC, undef ) )->[1]->{name}, 'Followed programs (2)', 'the count follows the list' );
	is( scalar requests(), 0, 'no network access' );
};

subtest 'Followed programs: OnDemand->programItem rows, A-Z' => sub {
	fresh();
	follow_three();
	$F->follow( { title => 'The Bush Telegraph', path => '/listen/programs/bushtelegraph/' } );

	my $items = items_of( feed( $FOLLOWED, undef ) );
	is_deeply( names($items), [ 'The Bush Telegraph', 'Classic Drive', 'Hack', 'The Science Show' ], 'A-Z by sortKey ("The" ignored)' );

	my @expected = map { Plugins::ABCListen::OnDemand->programItem( undef, $_ ) } (
		{ title => 'The Bush Telegraph', path => '/listen/programs/bushtelegraph' },
		{%CLASSIC_DRIVE}, {%HACK_SHOW}, {%SCIENCE_SHOW},
	);
	is_deeply( $items, \@expected, 'each row is exactly programItem({title, path, id?, image?, network?}) (no followedAt)' );
	is( $items->[3]->{line2}, 'Radio National', 'line2: the stored network' );
	like( $items->[3]->{image}, qr/a9bfe6ad8b283391297dd347dd60de8f\?width=862/, 'image: the stored image' );
	is( $items->[3]->{url}, $PROGRAM, 'rows open O2\'s program menu' );
	is( $items->[0]->{image}, $ICON, 'no image: the plugin icon' );
	ok( !( grep { exists $_->{description} } @$items ), 'no description on the browse rows (menu rule 1)' );
	check_names( $items, 'Followed programs' );
	is( scalar requests(), 0, 'no network access' );
};

# ---------------------------------------------------------------------------
# Latest episodes
# ---------------------------------------------------------------------------

subtest 'Latest episodes: three programs merged newest first, one row per episode, program prefixes' => sub {
	fresh();
	route_three();
	follow_three();

	my $c = feed( $LATEST, undef );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);

	is_deeply(
		plays($items),
		[qw(107266790 107300001 107400001 107400002 107300002 107300003 107400003 107232984 107300004 107300005 107100003 107100005 107400004 107100004)],
		'date descending; equal dates by program (Classic Drive, Hack, The Science Show), then by id; undated last'
	);
	is( scalar @$items, 14, '15 episodes, one listed by two programs: 14 rows (<= 15)' );

	my %programs = map { ( $_->{name} =~ /\A([^:]+):/ )[0] => 1 } @$items;
	is_deeply( [ sort keys %programs ], [ 'Classic Drive', 'Hack', 'The Science Show' ], 'rows from all three programs' );

	is( $items->[0]->{name},  "The Science Show: Sat 17 Oct $ENDASH Trees, potatoes and a step", 'name: "<program>: <date> – <title>"' );
	is( $items->[0]->{line1}, 'The Science Show: Trees, potatoes and a step',                    'line1: "<program>: <title>"' );
	is( $items->[0]->{line2}, "Sat 17 Oct \x{B7} 55 min",                                        'line2: episodeItem\'s date · duration' );
	is( $items->[4]->{name},  "Classic Drive: Thu 15 Oct $ENDASH Classic Drive: Wednesday",       'the shared episode is listed once, as its own program\'s (Classic Drive)' );
	is( $items->[12]->{name}, 'Hack: Hack: Special (undated)',                                  'undated: "<program>: <title>"' );
	like( $_->{name}, qr/\A(?:Classic Drive|Hack|The Science Show): (?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2} $ENDASH )?\S/, "row name: $_->{name}" ) for @$items;

	my @dates = grep {defined} map { $_->{passthrough}->[0]->{date} } @$items;
	is( scalar( grep { $dates[$_] > $dates[ $_ - 1 ] } 1 .. $#dates ), 0, 'dates are non-increasing' );

	# rows are episodeItem rows with only name/line1 changed
	my %episode = %{ $items->[0]->{passthrough}->[0] };
	my $built   = Plugins::ABCListen::OnDemand->episodeItem( undef, \%episode );
	is_deeply( { %{ $items->[0] }, name => $built->{name}, line1 => $built->{line1} }, $built, 'otherwise exactly the episodeItem row (url, play, image, duration, passthrough)' );
	is( $items->[0]->{url},  $EPISODE,                         'rows open O2\'s episode menu' );
	is( $items->[0]->{play}, 'abclisten://episode/107266790', 'rows play abclisten://episode/<id>' );
	ok( !( grep { exists $_->{description} } @$items ), 'no description on the rows (menu rule 1)' );
	is( scalar( grep { $_->{image} && $_->{image} ne $ICON } @$items ), 14, 'every row has artwork (episode or program image)' );

	# meta cache: the episode title, never the prefixed row text; programTitle only for own episodes
	my $own = Plugins::ABCListen::Util::getEpisodeMeta('107266790');
	is( $own->{title},        'Trees, potatoes and a step', 'meta cache: the plain episode title' );
	is( $own->{programTitle}, 'The Science Show',           'own episode: programTitle (program page title)' );
	is( $own->{programId},    '2885500',                    'own episode: programId' );

	my $lab = Plugins::ABCListen::Util::getEpisodeMeta('107232984');
	ok( !exists $lab->{programTitle} && !exists $lab->{programId}, 'Lab Notes episode listed by The Science Show: no programTitle/programId (O2\'s rule)' );
	my ($labRow) = grep { $_->{play} =~ /107232984/ } @$items;
	is( $labRow->{name}, "The Science Show: Wed 14 Oct $ENDASH Lab Notes: When astronomers make mistakes", '... its row is labelled with the followed program it came from' );
	ok( !exists $labRow->{passthrough}->[0]->{programTitle}, '... and its passthrough has no programTitle' );

	my $classic = Plugins::ABCListen::Util::getEpisodeMeta('107300004');
	is( $classic->{programTitle}, 'Classic Drive', 'Classic Drive episode: programTitle' );
	like( $classic->{image}, qr/c1a55dc0000000000000000000000000/, 'an episode without artwork: the program image is cached' );
	my ($noArt) = grep { $_->{play} =~ /107300004/ } @$items;
	like( $noArt->{image}, qr/c1a55dc0000000000000000000000000.*width=300/, '... and shown (300 px)' );

	is_deeply( [ sort( program_requests() ) ], [ sort map {"$NEXT$_.json"} $SCIENCE, $CLASSIC, $HACK ], 'one program page per followed program' );
	is_deeply( [ sort( episode_requests() ) ], [ sort map {"$EPS?collectionId=$_&offset=0&size=5"} qw(2885458 90000102 90000202) ], 'the newest 5 episodes of each' );
	check_names( $items, 'Latest episodes' );
	is_deeply( [ errors_logged() ], [], 'no errors logged' );
};

subtest 'Latest episodes: an episode listed by two programs belongs to its own program, not the first A-Z' => sub {
	fresh();
	route_three();
	follow_three();

	# Classic Drive (first A-Z) also lists Hack's 107400003
	my $classic = JSON::PP::decode_json( fixture('myabc/bff-episodesWithSegments-classic-drive.synthetic.json') );
	my $hack    = JSON::PP::decode_json( fixture('myabc/bff-episodesWithSegments-hack.synthetic.json') );
	$classic->{collection}->{items}->[4] = $hack->{collection}->{items}->[2];
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( "$EPS?collectionId=90000102&offset=0&size=5", content => to_json($classic), headers => $JSON_TYPE );
	route_three();

	my $items = items_of( feed( $LATEST, undef ) );
	my @rows = grep { $_->{play} =~ /107400003/ } @$items;
	is( scalar @rows, 1, 'shown once' );
	like( $rows[0]->{name}, qr/\AHack: /, 'as Hack\'s (its path is under /triplej/programs/hack)' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('107400003')->{programTitle}, 'Hack', 'meta cache: programTitle Hack' );
};

subtest 'Latest episodes: the newest 50' => sub {
	fresh();
	my @programs = map { route_generated($_) } 1 .. 12;
	$F->follow($_) for @programs;

	my $c = feed( $LATEST, undef );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is( scalar @$items, 50, '12 programs x 5 episodes = 60: the newest 50' );

	my @dates = map { $_->{passthrough}->[0]->{date} } @$items;
	is( scalar( grep { $dates[$_] > $dates[ $_ - 1 ] } 1 .. $#dates ), 0, 'newest first' );
	is( $dates[0],  $T0 - 5 * 3600,  'the newest episode first' );
	is( $dates[-1], $T0 - 54 * 3600, 'the 50th newest last (the 10 oldest left out)' );
	ok( !( grep { $_->{name} =~ /\AGenerated 12: / } @$items ), 'the oldest program\'s episodes are all older than the 50 newest' );
};

subtest 'Latest episodes: at most 4 programs in flight' => sub {
	fresh();
	my @programs = map { route_generated( $_, defer => 1 ) } 1 .. 6;
	$F->follow($_) for @programs;

	my ( $active, $max ) = ( 0, 0 );
	no warnings 'redefine';
	my $orig = \&Plugins::ABCListen::MyABC::_programLatest;
	local *Plugins::ABCListen::MyABC::_programLatest = sub {
		my ( $entry, $cb ) = @_;
		$max = $active if ++$active > $max;
		$orig->( $entry, sub { $active--; $cb->(@_) } );
	};

	my $c = feed( $LATEST, undef );
	is( scalar( program_requests() ), 4, 'four program pages requested at first' );
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 4, 'four waiting' );
	is( $c->count, 0, 'no answer yet' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( program_requests() ), 6, 'as they finish, the last two start' );
	is( $c->count, 0, 'still waiting for the last two' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'then one answer' );
	is( scalar @{ items_of($c) }, 30, 'with all 30 episodes' );
	is( $max, 4, 'never more than 4 programs in flight' );
	is( scalar( Slim::Utils::Timers->pending ), 0, 'the deadline timer is cancelled' );
};

subtest 'Latest episodes: a failing program is skipped (WARN); all failing -> LOAD_FAILED' => sub {
	fresh();
	follow_three();
	route( "$NEXT$CLASSIC.json", code => 404, content => '{}' );
	route( "$EPS?collectionId=90000202&offset=0&size=5", error => 'Timed out waiting for data' );
	route_three();

	my $c = feed( $LATEST, undef );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply( [ sort keys %{ { map { ( $_->{name} =~ /\A([^:]+):/ )[0] => 1 } @$items } } ], ['The Science Show'], 'the program that answered is shown' );
	is( scalar @$items, 5, 'its five episodes' );
	my @warnings = warnings_logged();
	ok( ( grep {m{skipped the followed program Classic Drive \(/listen/programs/classic-drive\)}} @warnings ), 'Classic Drive (404) skipped, logged at WARN' );
	ok( ( grep {m{skipped the followed program Hack \(/triplej/programs/hack\)}} @warnings ),           'Hack (episodes timed out) skipped, logged at WARN' );

	fresh();
	follow_three();
	route( qr{/_next/data/.*/programs/}, error => 'Timed out waiting for data' );
	$c = feed( $LATEST, undef );
	is( $c->count, 1, 'all failing: one callback' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'all failing: one LOAD_FAILED text item' );
	is( scalar( grep {/skipped the followed program/} warnings_logged() ), 3, 'three WARNs' );

	feed( $LATEST, undef );
	ok( scalar( program_requests() ) > 3, 'LOAD_FAILED is not cached: the next open requests again' );
};

subtest 'Latest episodes: programs without episodes contribute nothing; nothing at all -> NO_EPISODES' => sub {
	fresh();
	route( "$NEXT/listen/programs/minimal.json", file => 'ondemand/nextdata-program-minimal.synthetic.json', headers => $JSON_TYPE );
	route( "$NEXT/listen/programs/quiet.json",   file => 'ondemand/nextdata-program-emptydesc.synthetic.json', headers => $JSON_TYPE );
	route( "$EPS?collectionId=90000010&offset=0&size=5", content => to_json( { collection => { id => '90000010', items => [], pagination => { offset => 0, size => 5, total => 0 } } } ), headers => $JSON_TYPE );
	$F->follow( { title => 'Minimal Program', path => '/listen/programs/minimal' } );
	$F->follow( { title => 'Quiet Program',   path => '/listen/programs/quiet' } );

	my $c = feed( $LATEST, undef );
	is_deeply( items_of($c), [ text_item($NO_EPISODES) ], 'one NO_EPISODES text item (O2\'s token)' );
	is( scalar( episode_requests() ), 1, 'no episode request for the program without an episode list' );

	route_three();
	$F->follow( {%SCIENCE_SHOW} );
	is( scalar @{ items_of( feed( $LATEST, undef ) ) }, 5, 'with The Science Show: only its five rows' );
};

subtest 'Latest episodes: the 25 s deadline answers with what has arrived; late results are ignored' => sub {
	fresh();
	route( "$NEXT$CLASSIC.json", file => 'myabc/nextdata-program-classic-drive.synthetic.json', headers => $JSON_TYPE, defer => 1 );
	route( "$EPS?collectionId=90000202&offset=0&size=5", file => 'myabc/bff-episodesWithSegments-hack.synthetic.json', headers => $JSON_TYPE, defer => 1 );
	route_three();
	follow_three();

	my $c = feed( $LATEST, undef );
	is( $c->count, 0, 'waiting for Classic Drive and Hack' );
	advanceTime(24.9);
	is( $c->count, 0, 'still waiting at 24.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered at 25 s' );
	my $items = items_of($c);
	is( scalar @$items, 5, 'with The Science Show\'s five rows' );
	ok( !( grep { $_->{name} !~ /\AThe Science Show: / } @$items ), 'only The Science Show' );
	ok( ( grep {/answered after 25 s without 2 of 3 followed programs/} warnings_logged() ), 'WARN: how many programs were left out' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'late results: no second answer' );
	is_deeply( [ errors_logged() ], [], 'late results: ignored quietly (no errors)' );
	is( scalar( Slim::Utils::Timers->pending ), 0, 'no timer left' );

	# nothing in time: LOAD_FAILED; queued programs never start after the deadline
	fresh();
	my @programs = map { route_generated( $_, defer => 1 ) } 1 .. 6;
	$F->follow($_) for @programs;
	$c = feed( $LATEST, undef );
	advanceTime(25);
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'no program in time: LOAD_FAILED' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( program_requests() ), 4, 'the two queued programs never started' );
	is( $c->count, 1, 'still one answer' );
};

subtest 'Latest episodes: cached 15 min; a cache hit makes no request; a follow starts a new list' => sub {
	fresh();
	route_three();
	follow_three();

	my $first = items_of( feed( $LATEST, undef ) );
	my $count = scalar requests();

	my $second = items_of( feed( $LATEST, undef ) );
	is( scalar requests(), $count, 'second open: no HTTP request' );
	is_deeply( $second, $first, 'the same rows' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is_deeply( names( items_of( feed( $LATEST, $client ) ) ), names($first), 'the same rows for a player (server-wide)' );
	is( scalar requests(), $count, '... from the cache' );

	route_generated(1);
	$F->follow( { title => 'Generated 1', path => '/listen/programs/gen-1' } );
	my $third = items_of( feed( $LATEST, undef ) );
	ok( scalar requests() > $count, 'after a follow: requests again (a new cache key)' );
	ok( ( grep { $_->{name} =~ /\AGenerated 1: / } @$third ), 'and the new program\'s episodes are in' );

	$F->unfollow('/listen/programs/gen-1');
	$count = scalar requests();
	is_deeply( names( items_of( feed( $LATEST, undef ) ) ), names($first), 'after the unfollow: the earlier list' );
	is( scalar requests(), $count, '... still cached' );

	advanceTime(901);
	feed( $LATEST, undef );
	ok( scalar requests() > $count, 'after 15 min: requested again' );

	my $cache = Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE );
	my $cached = $cache->get( Plugins::ABCListen::MyABC::_latestKey( [ $F->list ] ) );
	ok( ref $cached eq 'ARRAY' && !( grep { ref $_->{episode} ne 'HASH' } @$cached ), 'the cache holds plain episode refs' );
	my $dump = JSON::PP->new->allow_unknown->canonical->encode($cached);
	unlike( $dump, qr/CODE/, '... no code refs' );
};

subtest 'Latest episodes: exactly one callback when LMS\'s callback dies' => sub {
	fresh();
	route_three();
	follow_three();
	my $calls = 0;
	$LATEST->( undef, sub { $calls++; die "LMS callback failed\n" }, {} );
	is( $calls, 1, 'called once' );
	ok( ( grep {/LMS callback failed/} errors_logged() ), 'the error is logged' );
};

# ---------------------------------------------------------------------------
# Follow / Unfollow in program menus
# ---------------------------------------------------------------------------

subtest 'program-menu provider: two follow rows, explicit op; [] without a path; one callback' => sub {
	fresh();
	my $program = { %SCIENCE_SHOW, template => 'audio', restricted => 0, episodeCollectionId => '2885458', description => 'About science' };

	my $c = collector();
	$EXTRAS->( undef, $program, $c->cb );
	is( $c->count, 1, 'one callback' );
	is_deeply(
		( $c->args(0) )[0],
		[ {
			name        => 'Follow "The Science Show"',
			type        => 'link',
			url         => $ACTION,
			nextWindow  => 'parent',
			passthrough => [ { op => 'follow', program => {%SCIENCE_SHOW} } ],
		}, text_item('Follow to see its new episodes in My ABC listen') ],
		'not following: Follow "<program>" (op follow, program {title, path, id, image, network} only), then the hint text'
	);

	$F->follow( {%SCIENCE_SHOW} );
	$c = collector();
	$EXTRAS->( ABCListenTest::FakeClient->new('00:00:00:00:00:01'), { %$program, path => "https://www.abc.net.au$SCIENCE/" }, $c->cb );
	my ($items) = $c->args(0);
	is_deeply(
		$items,
		[ text_item('✓ Following "The Science Show"'), {
			name        => 'Unfollow "The Science Show"',
			type        => 'link',
			url         => $ACTION,
			nextWindow  => 'parent',
			passthrough => [ { op => 'unfollow', program => {%SCIENCE_SHOW} } ],
		} ],
		'following (any path spelling): the "✓ Following" text, then Unfollow "<program>" (op unfollow, the canonical path)'
	);

	for my $case ( [ 'no path', { title => 'No path' } ], [ 'the site root', { title => 'Root', path => '/' } ], [ 'another host', { path => 'https://example.com/x' } ], [ 'not a hash', 'junk' ] ) {
		$c = collector();
		$EXTRAS->( undef, $case->[1], $c->cb );
		is( $c->count, 1, "$case->[0]: one callback" );
		is_deeply( ( $c->args(0) )[0], [], "$case->[0]: no item" );
	}

	is( scalar requests(), 0, 'no network access' );
	is_deeply( [ Plugins::ABCListen::OnDemand::_runProviders( undef, {%$program}, sub { $items = shift } ) ], [], 'registered with OnDemand (init)' );
	is_deeply( names($items), [ '✓ Following "The Science Show"', 'Unfollow "The Science Show"' ], '... the registry runs it' );
};

subtest 'the action: explicit op, idempotent (never a toggle), a readable confirmation' => sub {
	fresh();
	my $c = collector();
	$EXTRAS->( undef, {%SCIENCE_SHOW}, $c->cb );
	my $followItem = ( $c->args(0) )[0]->[0];

	$c = open_item($followItem);
	is( $c->count, 1, 'one callback' );
	is_deeply(
		items_of($c),
		[ { name => 'Following The Science Show', type => 'text', showBriefly => 1, nextWindow => 'parent' } ],
		'exactly one text item: "Following <program>" with showBriefly and nextWindow parent'
	);
	ok( $F->isFollowed($SCIENCE), 'followed' );

	$c = open_item($followItem);
	is_deeply( names( items_of($c) ), ['Following The Science Show'], 'the same (stale) Follow item again: the same confirmation' );
	is( scalar( my @l = $F->list ), 1, '... still followed once: no toggle' );

	$c = collector();
	$EXTRAS->( undef, {%SCIENCE_SHOW}, $c->cb );
	my $unfollowItem = ( $c->args(0) )[0]->[1];
	is( $unfollowItem->{name}, 'Unfollow "The Science Show"', 're-opening the program: Unfollow "<program>"' );

	$c = open_item($unfollowItem);
	is_deeply( items_of($c), [ { name => 'No longer following The Science Show', type => 'text', showBriefly => 1, nextWindow => 'parent' } ], 'unfollow: "No longer following <program>"' );
	ok( !$F->isFollowed($SCIENCE), 'unfollowed' );

	open_item($unfollowItem);
	ok( !$F->isFollowed($SCIENCE), 'the stale Unfollow item again: still not followed' );
	open_item($followItem);
	ok( $F->isFollowed($SCIENCE), 'the stale Follow item: follows (its explicit op)' );

	# title fallback in the confirmation
	$c = feed( $ACTION, undef, { op => 'follow', program => { path => '/listen/programs/lab-notes' } } );
	is_deeply( names( items_of($c) ), ['Following lab-notes'], 'no title: the path segment' );

	for my $case (
		[ 'unknown op',  { op => 'toggle', program => {%SCIENCE_SHOW} } ],
		[ 'no op',       { program => {%SCIENCE_SHOW} } ],
		[ 'no path',     { op => 'follow', program => { title => 'X' } } ],
		[ 'no program',  { op => 'unfollow' } ],
		[ 'not a hash',  'junk' ],
	) {
		$c = feed( $ACTION, undef, $case->[1] );
		is( $c->count, 1, "$case->[0]: one callback" );
		is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], "$case->[0]: LOAD_FAILED" );
	}
	is( scalar( my @after = $F->list ), 2, 'bad requests changed nothing' );
	is( scalar requests(), 0, 'no network access' );
};

subtest 'through OnDemand\'s program menu: the follow rows after the header, before the episodes' => sub {
	fresh();
	route_science_menu();

	my $row   = Plugins::ABCListen::OnDemand->programItem( undef, {%SCIENCE_SHOW} );
	my $items = items_of( open_item($row) );
	is_deeply(
		[ @{ names( [ @$items[ 3, 4 ] ] ) } ],
		[ 'Follow "The Science Show"', 'Follow to see its new episodes in My ABC listen' ],
		'description, Presented by, network, then Follow "<program>" and the hint'
	);
	is( $items->[2]->{name}, 'ABC Radio National', 'item 3: the network row' );
	like( $items->[5]->{name}, qr/\ASat 17 Oct $ENDASH /, 'then the first episode' );
	is( scalar @$items, 11, 'two extra rows: description, presenters, network, Follow, hint, 5 episodes, More episodes' );

	my $confirm = items_of( open_item( $items->[3] ) );
	is_deeply( names($confirm), ['Following The Science Show'], 'opening it: the FOLLOWED_OK text' );
	is_deeply( [ map { $_->{path} } $F->list ], [$SCIENCE], 'the program is followed' );

	$items = items_of( open_item($row) );
	is_deeply(
		names( [ @$items[ 3, 4 ] ] ),
		[ '✓ Following "The Science Show"', 'Unfollow "The Science Show"' ],
		're-opening the program: the "✓ Following" text, then Unfollow "<program>"'
	);
	is( $items->[3]->{type}, 'text', '... the "✓ Following" row is plain text' );
	like( $items->[5]->{name}, qr/\ASat 17 Oct $ENDASH /, '... the first episode has not moved' );
	is( scalar @$items, 11, '... still 11 rows' );

	is_deeply( [ sort keys %{ prefs()->get('followed')->[0] } ], [qw(followedAt id image network path title)], 'stored keys' );
};

# ---------------------------------------------------------------------------
# Stale item ids: LMS rebuilds the menu for every item_id request, so an id opens whatever row is
# at its index now. Re-opening an id from before a follow or unfollow must never change the follows.
# ---------------------------------------------------------------------------

my $FOLLOWING_ROW = { name => '✓ Following "The Science Show"', type => 'text' };
my $HINT_ROW      = { name => 'Follow to see its new episodes in My ABC listen', type => 'text' };

subtest 'stale ids, program menu: follow, then every id from before -> still following' => sub {
	fresh();
	route_science_menu();
	my $row     = Plugins::ABCListen::OnDemand->programItem( undef, {%SCIENCE_SHOW} );
	my $program = sub { items_of( open_item($row) ) };

	my $before = $program->();
	my $k      = op_index( $before, 'follow' );
	is( $k, 3, 'Follow at k = 3, right after the header rows' );
	is( op_index( $before, 'unfollow' ), undef, 'no Unfollow row anywhere' );
	my @openable = openable($before);

	open_id( $program, $k );
	ok( $F->isFollowed($SCIENCE), 'opening Follow (id k) follows' );
	my $stored = stored_follows();

	my $after = $program->();
	is( scalar @$after, scalar @$before, 'the rebuilt menu has as many rows' );
	is_deeply( names( [ @$after[ $k + 2 .. $#$after ] ] ), names( [ @$before[ $k + 2 .. $#$before ] ] ), 'no row after the follow rows moved' );

	is_deeply( open_id( $program, $k ), $FOLLOWING_ROW, 'the stale Follow id k: the "✓ Following" text row, a no-op' );
	is( stored_follows(), $stored, '... the follows are unchanged' );

	for my $i (@openable) {
		open_id( $program, $i );
		ok( $F->isFollowed($SCIENCE), "stale id $i ($before->[$i]->{name}): still following" );
	}
	open_id( $program, $openable[1], 1 );
	ok( $F->isFollowed($SCIENCE), 'stale id of the first episode\'s "Play episode": still following' );
	is( stored_follows(), $stored, 'every stale id: the follows are unchanged' );
};

subtest 'stale ids, program menu: unfollow, then every id from before -> still not following' => sub {
	fresh();
	route_science_menu();
	$F->follow( {%SCIENCE_SHOW} );
	my $row     = Plugins::ABCListen::OnDemand->programItem( undef, {%SCIENCE_SHOW} );
	my $program = sub { items_of( open_item($row) ) };

	my $before = $program->();
	is( op_index( $before, 'follow' ), undef, 'following: no Follow row' );
	my $k = op_index( $before, 'unfollow' );
	is( $k, 4, 'Unfollow at k + 1 = 4' );
	is_deeply( $before->[3], $FOLLOWING_ROW, 'row k = 3: the "✓ Following" text row' );
	my @openable = openable($before);

	open_id( $program, $k );
	ok( !$F->isFollowed($SCIENCE), 'opening Unfollow (id k + 1) unfollows' );
	is( stored_follows(), '[]', 'nothing followed' );

	my $after = $program->();
	is( scalar @$after, scalar @$before, 'the rebuilt menu has as many rows' );
	is_deeply( names( [ @$after[ $k + 1 .. $#$after ] ] ), names( [ @$before[ $k + 1 .. $#$before ] ] ), 'no row after the follow rows moved' );

	is_deeply( open_id( $program, $k ), $HINT_ROW, 'the stale Unfollow id k + 1: a text row, a no-op' );
	ok( !$F->isFollowed($SCIENCE), '... still not following' );

	for my $i (@openable) {
		open_id( $program, $i );
		ok( !$F->isFollowed($SCIENCE), "stale id $i ($before->[$i]->{name}): still not following" );
	}
	open_id( $program, $openable[1], 1 );
	ok( !$F->isFollowed($SCIENCE), 'stale id of the first episode\'s "Play episode": still not following' );
	is( stored_follows(), '[]', 'every stale id: the follows are unchanged' );
};

# The song-info menu as Slim::Menu::TrackInfo::menu builds it for every request: a row before the
# provider's (top), the provider's item or items (a hashref or an arrayref), then a later row.
sub song_info {
	my ( $client, $url ) = @_;
	my $ours = $TRACKINFO->( $client, $url );
	return [
		{ name => 'Trees', type => 'text' },
		( ref $ours eq 'ARRAY' ? @$ours : ref $ours eq 'HASH' ? $ours : () ),
		{ name => 'A later row', type => 'link', url => sub { $_[1]->( { items => [ text_item('later') ] } ) } },
	];
}

subtest 'stale ids, song info: follow / unfollow, then every id from before -> unchanged' => sub {
	fresh();
	Plugins::ABCListen::Util::setEpisodeMeta( '107266790', { path => "$SCIENCE/trees-potatoes-brendan-may-step/107266790", programTitle => 'The Science Show', title => 'Trees' } );
	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my $menu   = sub { song_info( $client, 'abclisten://episode/107266790' ) };

	my $before = $menu->();
	my $k      = op_index( $before, 'follow' );
	is( $k, 1, 'not following: Follow right after the top row' );
	is( op_index( $before, 'unfollow' ), undef, '... no Unfollow row' );
	my @openable = openable($before);

	open_id( $menu, $k );
	ok( $F->isFollowed($SCIENCE), 'opening Follow follows' );
	my $stored = stored_follows();

	my $following = $menu->();
	is( scalar @$following, scalar @$before, 'following: as many rows' );
	is_deeply( $following->[$k], $FOLLOWING_ROW, '... row k: the "✓ Following" text row' );
	my $u = op_index( $following, 'unfollow' );
	is( $u, $k + 1, '... Unfollow at k + 1' );
	is( $following->[-1]->{name}, 'A later row', '... the later row has not moved' );

	is_deeply( open_id( $menu, $k ), $FOLLOWING_ROW, 'the stale Follow id: the text row, a no-op' );
	for my $i (@openable) {
		open_id( $menu, $i );
		ok( $F->isFollowed($SCIENCE), "stale id $i ($before->[$i]->{name}): still following" );
	}
	is( stored_follows(), $stored, 'the follows are unchanged' );

	my @openableFollowing = openable($following);
	open_id( $menu, $u );
	ok( !$F->isFollowed($SCIENCE), 'opening Unfollow unfollows' );

	is_deeply( open_id( $menu, $u ), $HINT_ROW, 'the stale Unfollow id: a text row, a no-op' );
	for my $i (@openableFollowing) {
		open_id( $menu, $i );
		ok( !$F->isFollowed($SCIENCE), "stale id $i ($following->[$i]->{name}): still not following" );
	}
	is( stored_follows(), '[]', 'the follows are unchanged' );
};

# ---------------------------------------------------------------------------
# Song info
# ---------------------------------------------------------------------------

subtest 'song info: Follow "<program>" for a playing episode with a known program' => sub {
	fresh();
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{abclistenfollow};
	ok( $provider, 'init registers the abclistenfollow song-info provider' );
	is( $provider->{after}, 'top',      '... after top' );
	is( $provider->{func},  $TRACKINFO, '... with _trackInfo' );

	Plugins::ABCListen::Util::setEpisodeMeta( '107266790', { path => "$SCIENCE/trees-potatoes-brendan-may-step/107266790", programTitle => 'The Science Show', programId => '2885500', image => 'https://example.test/episode.jpg', title => 'Trees' } );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my $rows   = $TRACKINFO->( $client, 'abclisten://episode/107266790', undef, {}, {} );
	my $target = { title => 'The Science Show', path => $SCIENCE, id => '2885500', image => 'https://example.test/episode.jpg' };
	is_deeply(
		$rows,
		[ {
			name        => 'Follow "The Science Show"',
			type        => 'link',
			url         => $ACTION,
			nextWindow  => 'parent',
			passthrough => [ { op => 'follow', program => $target } ],
		}, text_item('Follow to see its new episodes in My ABC listen') ],
		'two rows: Follow "<program>" (the program path from the episode path), then the hint text'
	);

	my $c = open_item( $rows->[0], $client );
	is_deeply( names( items_of($c) ), ['Following The Science Show'], 'opening it: the FOLLOWED_OK text' );
	is( items_of( feed( $MY_ABC, undef ) )->[1]->{name}, 'Followed programs (1)', 'Followed programs (1)' );

	$rows = $TRACKINFO->( undef, 'abclisten://episode/107266790' );
	is_deeply(
		$rows,
		[ text_item('✓ Following "The Science Show"'), {
			name        => 'Unfollow "The Science Show"',
			type        => 'link',
			url         => $ACTION,
			nextWindow  => 'parent',
			passthrough => [ { op => 'unfollow', program => $target } ],
		} ],
		'following (no player too): the "✓ Following" text, then Unfollow "<program>"'
	);

	# Lab Notes listed in The Science Show, after O1's resolve: its own program, never a mismatch
	Plugins::ABCListen::Util::setEpisodeMeta( '107232984', { path => '/listen/programs/lab-notes/lab-notes-when-astronomers-make-mistakes/107232984', programTitle => 'Lab Notes' } );
	my $item = $TRACKINFO->( undef, 'abclisten://episode/107232984' )->[0];
	is( $item->{name}, 'Follow "Lab Notes"', 'Lab Notes episode: Follow "Lab Notes"' );
	is( $item->{passthrough}->[0]->{program}->{path}, '/listen/programs/lab-notes', '... for /listen/programs/lab-notes' );

	Plugins::ABCListen::Util::setEpisodeMeta( '107400001', { path => '/triplej/programs/hack/hack-15-october/107400001', programTitle => 'Hack' } );
	is( $TRACKINFO->( undef, 'abclisten://episode/107400001' )->[0]->{passthrough}->[0]->{program}->{path}, $HACK, 'triple j: /triplej/programs/hack' );

	is( scalar requests(), 0, 'no HTTP' );
};

subtest 'song info: no item without an episode URL, a known path or a program title' => sub {
	fresh();
	Plugins::ABCListen::Util::setEpisodeMeta( '1001', { path => "$SCIENCE/x/1001", title => 'No program title' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '1002', { programTitle => 'No path', title => 'x' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '1003', { path => '/news/2026-10-19/a-story/1003', programTitle => 'News' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '1004', { path => '/listen/programs', programTitle => 'Too short' } );

	for my $case (
		[ 'a live station',          'abclisten://live/TRIPLEJ' ],
		[ 'another scheme',          'https://www.abc.net.au/listen/programs/scienceshow/x/107266790' ],
		[ 'undef',                   undef ],
		[ 'no meta-cache entry',     'abclisten://episode/999999' ],
		[ 'no programTitle',         'abclisten://episode/1001' ],
		[ 'no path',                 'abclisten://episode/1002' ],
		[ 'no /programs/ segment',   'abclisten://episode/1003' ],
		[ 'a too-short path',        'abclisten://episode/1004' ],
	) {
		is( $TRACKINFO->( undef, $case->[1] ), undef, "$case->[0]: undef (no item)" );
	}

	no warnings 'redefine';
	local *Plugins::ABCListen::Util::getEpisodeMeta = sub { die "cache exploded\n" };
	my $item = eval { $TRACKINFO->( undef, 'abclisten://episode/1001' ) };
	is( $@,    '',    'an exception is contained' );
	is( $item, undef, '... no item' );
	ok( ( grep {/Song info Follow item failed: cache exploded/} warnings_logged() ), '... logged at WARN' );
	is( scalar requests(), 0, 'no HTTP' );
};

done_testing();
