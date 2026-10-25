#!/usr/bin/perl
# M2: Plugins::ABCListen::MyABC menus, offline (SimpleAsyncHTTP stub, fake clock, server time zone
# Australia/Sydney). F8 (#78): a 50-row Latest walk writes the episode meta cache only for what
# changed (50 new entries, then none; renewed once a day); a followed program ABC removed is a WARN
# once a day, DEBUG on the other rebuilds.
#   * the top-level "My ABC listen" item (exact keys, weight, menuWeights, last among the hooks' items);
#   * My ABC listen: the empty state (one instructional text item), "Latest episodes" and
#     "Followed programs (N)" (N counts follows, not tombstones; both rows stay while only
#     tombstones are left, and Latest episodes lists the tombstones' episodes); Followed programs as
#     OnDemand->programItem rows in follow order, an unfollowed program keeping its row for 30 min;
#   * Latest episodes over three routed programs: merge order (date, then program, then id; undated
#     last), one row per episode (its own program wins), the 50 cap, "<program>: " name/line1
#     prefixes with the meta-cache title untouched, O2's programTitle rule, at most 4 programs in
#     flight, a failing program skipped, all failing -> LOAD_FAILED, nothing -> NO_EPISODES, the
#     25 s deadline (late results ignored), the 15 min cache (a hit starts no fetch and serves the
#     same cache entry; a follow starts a new list; an unfollow or a re-follow within 30 min keeps
#     it), exactly one callback (also when LMS's callback dies). Cache hits are told from rebuilds
#     by Latest's fetch starts (a spy on Programs::episodes at Latest's page size) and by a marker
#     planted in the cached list, never by HTTP requests: O2 caches the program pages (6 h) and
#     episode lists (15 min), so a rebuild makes none;
#   * the program-menu provider (OnDemand's registry): two follow rows from isFollowed (Follow + hint
#     text, or "✓ Following" text + Unfollow), explicit op, [] without a path, exactly one callback;
#     through OnDemand's real program menu;
#   * the action: idempotent explicit op (never a toggle), the confirmation text item with
#     showBriefly / nextWindow, LOAD_FAILED for a bad request;
#   * stale item ids on a rebuilt menu (program menu and song info, follow and unfollow): re-opening
#     any id from before the change never changes the stored follows, and no later row moves;
#   * stale item ids through My ABC listen -> Followed programs -> program menu: after an unfollow
#     (the reviewer's sequence: two programs whose menus share a layout, the first unfollowed) and
#     after a new follow (one that would sort first A-Z), every id from before opens the same row
#     and never changes the follows; a re-follow within 30 min restores the follows exactly;
#   * M4 (#59), stale item ids through My ABC listen -> Latest episodes -> episode -> "More from
#     <program>" -> program menu (O4's row; until O4 is in, the episode menu is wrapped to add it
#     by O4's rule): follow A, B, C, unfollow B there, then every id from before leads to the same
#     episode, the same More from and the same rows (only B's own follow rows changed state), the
#     repeated Unfollow id lands on B's hint text (a no-op), and no id ever changes the follows; a
#     re-follow there restores B in place; the cached list (marker) is served throughout and no
#     fetch starts. Latest keeps B's episodes in place for 30 min, also when the 15 min cache
#     expires meanwhile: B's tombstone is fetched too, the rebuilt rows are exactly the old ones
#     (programTitle included) and every id re-walks to the same rows; then they leave;
#   * the song-info provider: the follow rows only for episode URLs whose meta-cache entry has a path
#     under /programs/ or /audiobooks/ (O8: or under a network-relative program such as
#     /triplej/hottest-100) and a programTitle; the named labels follow the state; undef for live
#     (even with a meta entry under the live id) and foreign URLs; no HTTP; an exception contained;
#   * O8, Hottest 100 (/triplej/hottest-100, which 308s to /triplej/programs/hottest-100): its
#     program menu's episodes -> song info with Follow "Hottest 100" -> Followed programs lists it
#     under the A–Z row's path, the program menu says Following too, Latest lists its episodes, the
#     two song-info rows stay two through follow and unfollow, and the unfollowed program keeps its
#     Followed programs row (M4). Its fixtures are O7's (t/data/ondemand/
#     nextdata-program-hottest-100.trimmed.json, bff-episodesWithSegments-hottest-100.trimmed.json).
#
# Fixtures: t/data/ondemand/nextdata-program-scienceshow.trimmed.json (O2), the F3 search page
# t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f), and t/data/myabc/
# (synthetic, shaped like the recorded cards): Classic Drive and Hack program pages, the newest 5
# episodes of The Science Show (4 own, one undated, plus a Lab Notes episode), Classic Drive (5)
# and Hack (two at the same time, one undated, plus Classic Drive's 107300002). Programs for the cap,
# concurrency and deadline cases are generated in code, and so is "Atlas" (Classic Drive's page
# under another title and path).

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
	Plugins::ABCListen::MyABC::_reset();    # F8: which failing programs were logged at WARN
	reset_latest_fetches();
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

# Latest's fetch starts: the collection id of every Programs::episodes call made with Latest's page
# size (MyABC::LATEST_PER_PROGRAM; program menus ask for 50), counted at the call, before any cache.
# O2 caches each program's page (6 h) and episode list (15 min), so a Latest list built again makes
# no HTTP request: HTTP requests can't tell a Latest cache hit from a rebuild; fetch starts can.
# latest_fetches() -> the ids (list) or how many (scalar); fresh() resets them.
my @LATEST_FETCHES;
{
	no warnings 'redefine';
	my $episodes = \&Plugins::ABCListen::Programs::episodes;
	*Plugins::ABCListen::Programs::episodes = sub {
		push @LATEST_FETCHES, $_[0] if defined $_[2] && $_[2] == Plugins::ABCListen::MyABC::LATEST_PER_PROGRAM;
		goto &$episodes;
	};
}

sub latest_fetches       { return @LATEST_FETCHES }
sub reset_latest_fetches { @LATEST_FETCHES = (); return }

sub _cache { Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE ) }

# Plant a marker in every ref of the Latest list cached under the key of every entry (followed
# programs and tombstones). Call it in the fake-clock second the list was built, so the entry keeps
# its expiry. A row served from that cache entry carries the marker in its passthrough; a list built
# again (a new key, a dropped entry, a refresh) does not. Returns the number of refs marked.
sub plant_marker {
	my $key    = Plugins::ABCListen::MyABC::_latestKey( [ $F->listWithUnfollowed ] );
	my $cached = _cache()->get($key);
	return 0 unless ref $cached eq 'ARRAY' && @$cached;
	$_->{episode}->{m4Marker} = 1 for @$cached;
	_cache()->set( $key, $cached, Plugins::ABCListen::MyABC::LATEST_TTL );
	return scalar @$cached;
}

# How many rows carry the marker (served from the marked cache entry).
sub marked { my $items = shift; return scalar grep { ref $_->{passthrough} eq 'ARRAY' && ref $_->{passthrough}->[0] eq 'HASH' && $_->{passthrough}->[0]->{m4Marker} } @{ $items || [] } }

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

# Program menus for Classic Drive and Hack: one header row each (the description), so their follow
# rows share an index.
sub route_program_menus {
	route( "$NEXT$CLASSIC.json", file => 'myabc/nextdata-program-classic-drive.synthetic.json', headers => $JSON_TYPE );
	route( "$NEXT$HACK.json",    file => 'myabc/nextdata-program-hack.synthetic.json',          headers => $JSON_TYPE );
	route( "$EPS?collectionId=90000102&offset=0&size=50", file => 'myabc/bff-episodesWithSegments-classic-drive.synthetic.json', headers => $JSON_TYPE );
	route( "$EPS?collectionId=90000202&offset=0&size=50", file => 'myabc/bff-episodesWithSegments-hack.synthetic.json',          headers => $JSON_TYPE );
}

# A program at $path titled $title with Classic Drive's page (the same menu layout) and episodes.
sub route_program_like_classic {
	my ( $path, $title ) = @_;
	my $page = JSON::PP::decode_json( fixture('myabc/nextdata-program-classic-drive.synthetic.json') );
	$page->{pageProps}->{heroImageWithCTAPrepared}->{heading} = $title;
	route( "$NEXT$path.json", content => to_json($page), headers => $JSON_TYPE );
}

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
	is( items_of( feed( $MY_ABC, undef ) )->[1]->{name}, 'Followed programs (2)', 'the count follows the list (a tombstone is not counted)' );

	$F->unfollow($_) for $SCIENCE, $CLASSIC;
	is_deeply( names( items_of( feed( $MY_ABC, undef ) ) ), [ 'Latest episodes', 'Followed programs (0)' ], 'only tombstones left: both rows stay (ids into Followed programs and Latest episodes still work)' );
	is( scalar requests(), 0, 'no network access for My ABC listen' );

	route_three();
	my %programs = map { ( $_->{name} =~ /\A([^:]+):/ )[0] => 1 } @{ items_of( feed( $LATEST, undef ) ) };
	is_deeply( [ sort keys %programs ], [ 'Classic Drive', 'Hack', 'The Science Show' ], '... Latest episodes: the unfollowed programs\' episodes until their tombstones expire (M4)' );

	advanceTime(1800);
	is_deeply( items_of( feed( $MY_ABC, undef ) ), [ text_item($HELP) ], '30 min later: the help text' );
	is_deeply( items_of( feed( $LATEST, undef ) ), [ text_item($HELP) ], '... and Latest episodes (a stale id): the help text' );
};

subtest 'Followed programs: OnDemand->programItem rows in follow order; an unfollowed program keeps its row 30 min' => sub {
	fresh();
	follow_three();
	$F->follow( { title => 'The Bush Telegraph', path => '/listen/programs/bushtelegraph/' } );

	my $items = items_of( feed( $FOLLOWED, undef ) );
	is_deeply( names($items), [ 'The Science Show', 'Classic Drive', 'Hack', 'The Bush Telegraph' ], 'follow order, oldest first (not A-Z): the newest follow is the last row' );

	my @expected = map { Plugins::ABCListen::OnDemand->programItem( undef, $_ ) } (
		{%SCIENCE_SHOW}, {%CLASSIC_DRIVE}, {%HACK_SHOW},
		{ title => 'The Bush Telegraph', path => '/listen/programs/bushtelegraph' },
	);
	is_deeply( $items, \@expected, 'each row is exactly programItem({title, path, id?, image?, network?}) (no followedAt)' );
	is( $items->[0]->{line2}, 'Radio National', 'line2: the stored network' );
	like( $items->[0]->{image}, qr/a9bfe6ad8b283391297dd347dd60de8f\?width=862/, 'image: the stored image' );
	is( $items->[0]->{url}, $PROGRAM, 'rows open O2\'s program menu' );
	is( $items->[3]->{image}, $ICON, 'no image: the plugin icon' );
	ok( !( grep { exists $_->{description} } @$items ), 'no description on the browse rows (menu rule 1)' );
	check_names( $items, 'Followed programs' );

	$F->unfollow($CLASSIC);
	is_deeply( items_of( feed( $FOLLOWED, undef ) ), \@expected, 'Classic Drive unfollowed: the same rows (its row stays, the same programItem row)' );
	is( items_of( feed( $MY_ABC, undef ) )->[1]->{name}, 'Followed programs (3)', '... and not counted' );
	advanceTime(1799);
	is_deeply( items_of( feed( $FOLLOWED, undef ) ), \@expected, '... for 30 min' );
	advanceTime(1);
	is_deeply( names( items_of( feed( $FOLLOWED, undef ) ) ), [ 'The Science Show', 'Hack', 'The Bush Telegraph' ], 'then its row is gone' );

	$F->unfollow($_) for $SCIENCE, $HACK, '/listen/programs/bushtelegraph';
	is_deeply( names( items_of( feed( $FOLLOWED, undef ) ) ), [ 'The Science Show', 'Hack', 'The Bush Telegraph' ], 'all unfollowed: the rows stay for 30 min' );
	advanceTime(1800);
	is_deeply( items_of( feed( $FOLLOWED, undef ) ), [ text_item($HELP) ], 'then the help text' );
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
	ok( ( grep {m{skipped the program Classic Drive \(/listen/programs/classic-drive\)}} @warnings ), 'Classic Drive (404) skipped, logged at WARN' );
	ok( ( grep {m{skipped the program Hack \(/triplej/programs/hack\)}} @warnings ),           'Hack (episodes timed out) skipped, logged at WARN' );

	fresh();
	follow_three();
	route( qr{/_next/data/.*/programs/}, error => 'Timed out waiting for data' );
	$c = feed( $LATEST, undef );
	is( $c->count, 1, 'all failing: one callback' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'all failing: one LOAD_FAILED text item' );
	is( scalar( grep {/skipped the program/} warnings_logged() ), 3, 'three WARNs' );

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
	ok( ( grep {/answered after 25 s without 2 of 3 programs/} warnings_logged() ), 'WARN: how many programs were left out' );

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

subtest 'Latest episodes: cached 15 min; a cache hit starts no fetch; a follow starts a new list, an unfollow keeps it' => sub {
	fresh();
	route_three();
	follow_three();
	my $gen1 = '/listen/programs/gen-1';

	# cache hits are told apart from rebuilds by Latest's fetch starts and by a marker planted in the
	# cached list, not by HTTP requests (O2's own caches answer a rebuild without any)
	my $first = items_of( feed( $LATEST, undef ) );
	is_deeply( [ sort( latest_fetches() ) ], [qw(2885458 90000102 90000202)], 'first open: one fetch per program' );
	my $count = scalar requests();

	my $second = items_of( feed( $LATEST, undef ) );
	is( scalar( latest_fetches() ), 3, 'second open: no fetch started (a Latest cache hit)' );
	is( scalar requests(), $count, '... and no HTTP request' );
	is_deeply( $second, $first, 'the same rows' );

	ok( plant_marker(), 'a marker planted in the cached list' );
	my $client    = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my $forPlayer = items_of( feed( $LATEST, $client ) );
	is_deeply( names($forPlayer), names($first), 'the same rows for a player (server-wide)' );
	is( marked($forPlayer), scalar @$first, '... from the same cache entry (every row has the marker)' );
	is( scalar( latest_fetches() ), 3, '... no fetch started' );

	route_generated(1);
	$F->follow( { title => 'Generated 1', path => $gen1 } );
	my $third = items_of( feed( $LATEST, undef ) );
	is_deeply( [ sort( ( latest_fetches() )[ 3 .. 6 ] ) ], [qw(2885458 90000102 90000202 91000001)], 'after a follow: a new list (a new cache key), the four programs fetched' );
	is( marked($third), 0, '... built again (no marker)' );
	ok( ( grep { $_->{name} =~ /\AGenerated 1: / } @$third ), 'and the new program\'s episodes are in' );

	ok( plant_marker(), 'a marker planted in the new cached list' );
	$F->unfollow($gen1);
	my $unfollowed = items_of( feed( $LATEST, undef ) );
	is_deeply( names($unfollowed), names($third), 'after the unfollow: the same list (M4: the tombstone keeps its episodes in place)' );
	is( marked($unfollowed), scalar @$third, '... the same cache entry (the same key): every row has the marker' );
	is( scalar( latest_fetches() ), 7, '... no fetch started' );

	$F->follow( { title => 'Generated 1', path => $gen1 } );
	my $refollowed = items_of( feed( $LATEST, undef ) );
	is_deeply( names($refollowed), names($third), 'a re-follow within 30 min: the same list' );
	is( marked($refollowed), scalar @$third, '... the same cache entry' );
	is( scalar( latest_fetches() ), 7, '... no fetch started' );
	$F->unfollow($gen1);

	advanceTime(901);
	my $refreshed = items_of( feed( $LATEST, undef ) );
	is_deeply( [ sort( ( latest_fetches() )[ 7 .. 10 ] ) ], [qw(2885458 90000102 90000202 91000001)], 'after 15 min: fetched again, gen-1\'s tombstone included' );
	is( scalar( latest_fetches() ), 11, '... once each' );
	is( marked($refreshed), 0, '... a new list (no marker)' );
	ok( ( grep { $_->{name} =~ /\AGenerated 1: / } @$refreshed ), '... gen-1\'s episodes still in (its tombstone is 901 s old)' );

	my $cached = _cache()->get( Plugins::ABCListen::MyABC::_latestKey( [ $F->listWithUnfollowed ] ) );
	ok( ref $cached eq 'ARRAY' && !( grep { ref $_->{episode} ne 'HASH' } @$cached ), 'the cache holds plain episode refs (keyed on follows and tombstones)' );
	my $dump = JSON::PP->new->allow_unknown->canonical->encode($cached);
	unlike( $dump, qr/CODE/, '... no code refs' );

	advanceTime(900);    # 1801 s after the unfollow
	is_deeply( names( items_of( feed( $LATEST, undef ) ) ), names($first), '30 min after the unfollow: the list without it' );
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
	is_deeply( [ $F->list ], [], 'nothing followed (a tombstone is stored)' );
	my $stored = stored_follows();

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
	is( stored_follows(), $stored, 'every stale id: the follows are unchanged' );
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
	$stored = stored_follows();

	is_deeply( open_id( $menu, $u ), $HINT_ROW, 'the stale Unfollow id: a text row, a no-op' );
	for my $i (@openableFollowing) {
		open_id( $menu, $i );
		ok( !$F->isFollowed($SCIENCE), "stale id $i ($following->[$i]->{name}): still not following" );
	}
	is( stored_follows(), $stored, 'the follows are unchanged' );
};

# Every id a client can hold into Followed programs, as index paths from My ABC listen: [1, i] per
# program row and [1, i, k] per row of its program menu that opens.
sub followed_ids {
	my $my = shift;
	my @ids;
	for my $i ( openable( open_id( $my, 1 ) ) ) {
		push @ids, [ 1, $i ], map { [ 1, $i, $_ ] } openable( open_id( $my, 1, $i ) );
	}
	return @ids;
}

# The name of the row an index path leads to now, without opening that row.
sub row_at {
	my ( $build, @index ) = @_;
	my $last  = pop @index;
	my $items = @index ? open_id( $build, @index ) : $build->();
	return ref $items eq 'ARRAY' && ref $items->[$last] eq 'HASH' ? $items->[$last]->{name} : undef;
}

sub id_of { join '.', @{ $_[0] } }

sub is_action_name { defined $_[0] && $_[0] =~ /\A(?:Follow|Unfollow) "/ }

subtest 'stale ids, Followed programs: unfollow the first program, then every id from before -> no follow changes' => sub {
	fresh();
	route_program_menus();
	my $my = sub { items_of( feed( $MY_ABC, undef ) ) };

	# the reviewer's sequence: follow two programs whose menus share a layout ...
	for my $program ( {%CLASSIC_DRIVE}, {%HACK_SHOW} ) {
		my $menu = items_of( open_item( Plugins::ABCListen::OnDemand->programItem( undef, $program ) ) );
		open_item( $menu->[ op_index( $menu, 'follow' ) ] );
		advanceTime(60);
	}
	ok( $F->isFollowed($CLASSIC) && $F->isFollowed($HACK), 'following Classic Drive, then Hack' );

	my $followed = open_id( $my, 1 );
	is_deeply( names($followed), [ 'Classic Drive', 'Hack' ], 'Followed programs: Classic Drive, Hack' );
	my $u = op_index( open_id( $my, 1, 0 ), 'unfollow' );
	is( op_index( open_id( $my, 1, 1 ), 'unfollow' ), $u, "both program menus have Unfollow at index $u (a moved row would hit Hack's)" );

	my @ids = followed_ids($my);
	my %was = map { id_of($_) => row_at( $my, @$_ ) } @ids;
	my $original = stored_follows();

	# ... then unfollow the first through Followed programs
	is_deeply( names( open_id( $my, 1, 0, $u ) ), ['No longer following Classic Drive'], "Unfollow at 1.0.$u: Classic Drive" );
	ok( !$F->isFollowed($CLASSIC) && $F->isFollowed($HACK), 'Classic Drive unfollowed, Hack still followed' );
	my $stored = stored_follows();

	is( $my->()->[1]->{name}, 'Followed programs (1)', 'My ABC listen: Followed programs (1)' );
	is_deeply( open_id( $my, 1 ), $followed, 'Followed programs: the same rows (Classic Drive keeps its row)' );
	is_deeply( open_id( $my, 1, 0, $u ), $HINT_ROW, "the stale Unfollow id 1.0.$u: the hint text row of Classic Drive's menu, a no-op" );
	is( stored_follows(), $stored, '... the follows are unchanged' );

	for my $id (@ids) {
		my $now = row_at( $my, @$id );

		# an action that is still the same action (Unfollow "Hack") is not stale: skip it
		if ( is_action_name($now) && $now eq $was{ id_of($id) } ) {
			pass( 'id ' . id_of($id) . " is still $now (not re-opened)" );
			next;
		}
		open_id( $my, @$id );
		is( stored_follows(), $stored, 'stale id ' . id_of($id) . " (was $was{ id_of($id) }, now " . ( $now // 'nothing' ) . '): the follows are unchanged' );
	}
	ok( !$F->isFollowed($CLASSIC) && $F->isFollowed($HACK), 'after every stale id: Classic Drive unfollowed, Hack followed' );

	# re-follow within 30 min, from the row Classic Drive kept: in place, with its followedAt
	advanceTime(600);
	my $f = op_index( open_id( $my, 1, 0 ), 'follow' );
	is( $f, $u - 1, "its menu: Follow at index $f" );
	is_deeply( names( open_id( $my, 1, 0, $f ) ), ['Following Classic Drive'], '10 min later, Follow: following Classic Drive' );
	is( stored_follows(), $original, '... the stored follows are exactly as before the unfollow (place and followedAt kept)' );
	is_deeply( open_id( $my, 1 ), $followed, '... and Followed programs has the same rows' );
	is_deeply( open_id( $my, 1, 0, $f ), text_item('✓ Following "Classic Drive"'), 'the stale Follow id: the "✓ Following" text row, a no-op' );
	is( stored_follows(), $original, '... unchanged' );

	# the limit: 30 min after an unfollow its tombstone expires, and later rows move up
	open_id( $my, 1, 0, $u );
	advanceTime(1800);
	is_deeply( names( open_id( $my, 1 ) ), ['Hack'], 'unfollowed again, 30 min later: the row is gone (the documented limit)' );
};

subtest 'stale ids, Followed programs: follow a new program, then every id from before -> the same rows' => sub {
	fresh();
	route_program_menus();
	route_program_like_classic( '/listen/programs/atlas', 'Atlas' );
	my $my = sub { items_of( feed( $MY_ABC, undef ) ) };

	$F->follow( {%CLASSIC_DRIVE} );
	advanceTime(60);
	$F->follow( {%HACK_SHOW} );
	advanceTime(60);

	my $followed = open_id( $my, 1 );
	is_deeply( names($followed), [ 'Classic Drive', 'Hack' ], 'Followed programs: Classic Drive, Hack' );
	my $u = op_index( open_id( $my, 1, 0 ), 'unfollow' );
	my @ids = followed_ids($my);
	my %was = map { id_of($_) => row_at( $my, @$_ ) } @ids;

	# follow Atlas (A-Z it would be the first row) from its own program menu
	my $atlas = items_of( open_item( Plugins::ABCListen::OnDemand->programItem( undef, { title => 'Atlas', path => '/listen/programs/atlas' } ) ) );
	my $f = op_index( $atlas, 'follow' );
	is( $f, $u - 1, 'Atlas\'s menu has the same layout' );
	is_deeply( names( items_of( open_item( $atlas->[$f] ) ) ), ['Following Atlas'], 'Follow "Atlas"' );
	my $stored = stored_follows();

	my $after = open_id( $my, 1 );
	is_deeply( names($after), [ 'Classic Drive', 'Hack', 'Atlas' ], 'Followed programs: Atlas appended' );
	is_deeply( [ @$after[ 0 .. $#$followed ] ], $followed, '... the rows from before are unchanged' );
	is( $my->()->[1]->{name}, 'Followed programs (3)', 'My ABC listen: Followed programs (3)' );

	for my $id (@ids) {
		is( row_at( $my, @$id ), $was{ id_of($id) }, 'id ' . id_of($id) . " still leads to $was{ id_of($id) }" );
	}

	for my $id ( grep { !is_action_name( $was{ id_of($_) } ) } @ids ) {
		open_id( $my, @$id );
		is( stored_follows(), $stored, 'stale id ' . id_of($id) . " ($was{ id_of($id) }): the follows are unchanged" );
	}

	# the stale Unfollow id of the first row: still Classic Drive's, and only it
	is_deeply( names( open_id( $my, 1, 0, $u ) ), ['No longer following Classic Drive'], "the stale id 1.0.$u: Unfollow \"Classic Drive\", as when it was issued" );
	ok( $F->isFollowed($HACK) && $F->isFollowed('/listen/programs/atlas'), '... Hack and Atlas still followed' );
};

# ---------------------------------------------------------------------------
# Stale ids through Latest episodes -> episode -> "More from <program>" -> program menu (M4, #59)
# ---------------------------------------------------------------------------

# O4 adds "More from <program>" to the episode menu: a programItem row for the episode's program.
# Until O4 is in, $code runs with the episode menu wrapped to append the same row by O4's rule (the
# program path Follow::programPathFor(episode path), the episode's programTitle, programId and
# programImage, name "More from <title>"); when the menu already has a program row (O4's own),
# nothing is added. Every id is re-walked from the top, as LMS does (open_id).
sub with_more_from {
	my $code = shift;
	my $orig = \&Plugins::ABCListen::OnDemand::_episodeMenu;

	no warnings 'redefine';
	local *Plugins::ABCListen::OnDemand::_episodeMenu = sub {
		my ( $client, $cb, $args, $episode ) = @_;
		$orig->( $client, sub {
			my ( $result, @rest ) = @_;
			my $items = ref $result eq 'HASH' ? $result->{items} : undef;
			my $path  = ref $episode eq 'HASH' ? $F->programPathFor( $episode->{path} ) : undef;

			if ( ref $items eq 'ARRAY' && !( grep { ref $_->{url} eq 'CODE' && $_->{url} == $PROGRAM } @$items ) && defined $path && defined $episode->{programTitle} ) {
				my %program = ( path => $path, title => $episode->{programTitle} );
				$program{id}    = $episode->{programId}    if defined $episode->{programId};
				$program{image} = $episode->{programImage} if defined $episode->{programImage};

				my $more = Plugins::ABCListen::OnDemand->programItem( $client, \%program );
				$more->{name} = $more->{line1} = "More from $program{title}";
				$result = { %$result, items => [ @$items, $more ] };
			}

			$cb->( $result, @rest );
		}, $args, $episode );
	};

	return $code->();
}

# The index of the "More from" row (O4's, or with_more_from's) in an episode menu.
sub more_from_index {
	my $items = shift;
	my @found = grep { ref $items->[$_]->{url} eq 'CODE' && $items->[$_]->{url} == $PROGRAM } 0 .. $#$items;
	return $found[0];
}

# Every id a client can hold into Latest episodes, as index paths from My ABC listen: [0, n] per
# episode row, [0, n, m] per row of its episode menu that opens ("More from"), and [0, n, m, k] per
# row of that program menu that opens (Follow / Unfollow, episodes, More episodes).
sub latest_ids {
	my $my = shift;
	my @ids;
	for my $n ( openable( open_id( $my, 0 ) ) ) {
		push @ids, [ 0, $n ];
		for my $m ( openable( open_id( $my, 0, $n ) ) ) {
			push @ids, [ 0, $n, $m ], map { [ 0, $n, $m, $_ ] } openable( open_id( $my, 0, $n, $m ) );
		}
	}
	return @ids;
}

# After B (Classic Drive) was unfollowed: every id from before (\%was: id -> row name) leads to
# the same row now, except B's Unfollow rows, which are B's hint text (B is not followed).
sub check_ids_after_unfollow {
	my ( $my, $ids, $was, $when ) = @_;
	for my $id (@$ids) {
		my $now  = row_at( $my, @$id );
		my $then = $was->{ id_of($id) };
		if ( $then eq 'Unfollow "Classic Drive"' ) {
			is( $now, $HINT_ROW->{name}, "$when: id " . id_of($id) . ': B\'s Unfollow row is now B\'s hint text (B not followed)' );
		}
		else {
			is( $now, $then, "$when: id " . id_of($id) . " still leads to $then" );
		}
	}
	return;
}

sub program_of { my $name = shift; return defined $name && $name =~ /\A([^:]+): / ? $1 : undef }

sub route_latest_and_menus {
	route_three();
	route_program_menus();
	route( qr{\Q$EPS\E\?collectionId=2885458&offset=0&size=50\z}, file => 'myabc/bff-episodesWithSegments-scienceshow-latest.synthetic.json', headers => $JSON_TYPE );
}

subtest 'stale ids, Latest -> episode -> More from: unfollow B there; every id from before -> the same programs; the repeated Unfollow id is a no-op on B' => sub {
	fresh();
	route_latest_and_menus();
	follow_three();    # A = The Science Show, B = Classic Drive, C = Hack
	my $my = sub { items_of( feed( $MY_ABC, undef ) ) };

	with_more_from( sub {
		my $latest = open_id( $my, 0 );
		my @before = @{ plays($latest) };
		is_deeply( [ map { program_of( $_->{name} ) } @$latest[ 0 .. 2 ] ], [ 'The Science Show', 'Classic Drive', 'Hack' ], 'Latest episodes: A, B, C first' );

		# B's first row, its More from row, and B's Unfollow row in that program menu
		my ($n) = grep { ( program_of( $latest->[$_]->{name} ) // '' ) eq 'Classic Drive' } 0 .. $#$latest;
		my $m = more_from_index( open_id( $my, 0, $n ) );
		ok( defined $m, "row $n (Classic Drive) has a More from row at $m" );
		is( row_at( $my, 0, $n, $m ), 'More from Classic Drive', '... More from Classic Drive' );
		my $u = op_index( open_id( $my, 0, $n, $m ), 'unfollow' );
		is( row_at( $my, 0, $n, $m, $u ), 'Unfollow "Classic Drive"', "... whose menu has Unfollow \"Classic Drive\" at $u" );

		# the trap the fix closes: without B's rows, row n is Hack's, with More from at the same index
		# and Unfollow "Hack" at the same index in Hack's menu
		my ($h) = grep { ( program_of( $latest->[$_]->{name} ) // '' ) eq 'Hack' } 0 .. $#$latest;
		is( more_from_index( open_id( $my, 0, $h ) ), $m, "Hack's row $h: More from at $m too" );
		is( row_at( $my, 0, $h, $m, $u ), 'Unfollow "Hack"', "... and Unfollow \"Hack\" at $u (a moved row would hit it)" );

		my @ids = latest_ids($my);
		my %was = map { id_of($_) => row_at( $my, @$_ ) } @ids;
		is( scalar( latest_fetches() ), 3, 'the whole walk fetched each program once (every other open was a Latest cache hit)' );

		# a marker in the cached list: every row served from that same cache entry carries it
		is( plant_marker(), scalar @before, 'a marker planted in every ref of the cached list' );

		# unfollow B through Latest episodes -> episode -> More from
		is_deeply( names( open_id( $my, 0, $n, $m, $u ) ), ['No longer following Classic Drive'], "0.$n.$m.$u: No longer following Classic Drive" );
		ok( !$F->isFollowed($CLASSIC), 'B unfollowed' );
		ok( $F->isFollowed($SCIENCE) && $F->isFollowed($HACK), 'A and C still followed' );
		my $stored = stored_follows();

		my $now = open_id( $my, 0 );
		is_deeply( plays($now), \@before, 'Latest episodes: the same rows in the same order (B\'s episodes kept)' );
		is( marked($now), scalar @before, '... served from the same cache entry: the marker is on every row (the key did not change, nothing dropped it)' );
		is( scalar( latest_fetches() ), 3, '... and no fetch was started' );

		# every id from before leads to the same row; only B's own follow rows changed state
		check_ids_after_unfollow( $my, \@ids, \%was, 'after the unfollow' );

		# the repeated Unfollow id: B's hint text row (a no-op), never A's or C's Unfollow
		is_deeply( open_id( $my, 0, $n, $m, $u ), $HINT_ROW, "the repeated Unfollow id 0.$n.$m.$u: B's hint text row, a no-op" );
		is( stored_follows(), $stored, '... the follows are unchanged' );

		# every other id from before: the same rows, and none changes the follows
		for my $id (@ids) {
			my $now = row_at( $my, @$id );
			if ( is_action_name($now) && $now eq $was{ id_of($id) } ) {
				pass( 'id ' . id_of($id) . " is still $now (not stale, not re-opened)" );
				next;
			}
			open_id( $my, @$id );
			is( stored_follows(), $stored, 'stale id ' . id_of($id) . " (was $was{ id_of($id) }): the follows are unchanged" );
		}
		ok( !$F->isFollowed($CLASSIC) && $F->isFollowed($SCIENCE) && $F->isFollowed($HACK), 'after every stale id: only B unfollowed' );

		# a re-follow from the same place within 30 min: the same list, B followed again in place
		my $f = op_index( open_id( $my, 0, $n, $m ), 'follow' );
		is( $f, $u - 1, "B's menu now offers Follow at $f" );
		is_deeply( names( open_id( $my, 0, $n, $m, $f ) ), ['Following Classic Drive'], 'Follow from the same place: following Classic Drive' );
		is_deeply( [ map { $_->{path} } $F->list ], [ $SCIENCE, $CLASSIC, $HACK ], '... in its place' );
		my $end = open_id( $my, 0 );
		is_deeply( plays($end), \@before, '... and Latest episodes is unchanged' );
		is( marked($end), scalar @before, 'after every stale id and the re-follow: still the same cache entry (the marker)' );
		is( scalar( latest_fetches() ), 3, '... and no fetch was started at all' );
	} );
};

subtest 'Latest after an unfollow: B\'s episodes stay in place for 30 min (also across the 15 min refresh), then leave' => sub {
	fresh();
	route_latest_and_menus();
	follow_three();
	my $my = sub { items_of( feed( $MY_ABC, undef ) ) };

	my $latest = items_of( feed( $LATEST, undef ) );
	my @before = @{ plays($latest) };
	my @bRows  = grep { ( program_of( $latest->[$_]->{name} ) // '' ) eq 'Classic Drive' } 0 .. $#$latest;
	ok( scalar @bRows, 'Classic Drive (B) has rows: ' . join( ', ', @bRows ) );
	my $key = Plugins::ABCListen::MyABC::_latestKey( [ $F->listWithUnfollowed ] );
	is( ref _cache()->get($key), 'ARRAY', 'cached under the key of every entry, tombstones included' );
	is_deeply( [ map { $_->{passthrough}->[0]->{programTitle} } @$latest[@bRows] ], [ ('Classic Drive') x @bRows ], 'B\'s own episodes carry programTitle (More from needs it)' );

	# every id through Latest -> episode -> More from -> program menu, and the row it leads to
	my ( @ids, %was );
	with_more_from( sub {
		@ids = latest_ids($my);
		%was = map { id_of($_) => row_at( $my, @$_ ) } @ids;
	} );
	ok( ( grep { ( $was{$_} // '' ) eq 'More from Classic Drive' } keys %was ), 'ids into B\'s program menu through More from' );
	is( plant_marker(), scalar @before, 'a marker planted in every ref of the cached list' );
	is( scalar( latest_fetches() ), 3, 'so far: one fetch per program' );

	$F->unfollow($CLASSIC);
	my $unfollowed = items_of( feed( $LATEST, undef ) );
	is_deeply( plays($unfollowed), \@before, 'unfollowed: the same rows' );
	is( marked($unfollowed), scalar @before, '... from the same cache entry (the marker): an unfollow keeps the cache key' );
	is( scalar( latest_fetches() ), 3, '... no fetch started' );
	is( _cache()->get( Plugins::ABCListen::MyABC::_latestKey( [ $F->list ] ) ), undef, '... (no list was built under a key of the followed programs only)' );

	advanceTime(901);
	is( _cache()->get($key), undef, '15 min later: the cached list has expired' );
	my $rebuilt = items_of( feed( $LATEST, undef ) );
	is( ref _cache()->get($key), 'ARRAY', '... and is built again under the same key' );
	my @fetched = latest_fetches();
	is_deeply( [ sort @fetched[ 3 .. $#fetched ] ], [qw(2885458 90000102 90000202)], '... fetched from A, B (the tombstone) and C, once each' );
	is( marked($rebuilt), 0, '... a new list (no marker)' );
	is_deeply( plays($rebuilt), \@before, '... with B\'s episodes still in their places (the tombstone is fetched too)' );
	is_deeply( $rebuilt, $latest, '... exactly the rows from before the unfollow (passthrough included: B\'s programTitle, programId, programImage)' );

	# the rebuilt list, walked again: every id from before still leads to the same episode, its More
	# from to the same program menu, and the same rows there (B's follow rows now offer Follow)
	ok( plant_marker(), 'a marker planted in the rebuilt list' );
	with_more_from( sub { check_ids_after_unfollow( $my, \@ids, \%was, 'after the 15 min rebuild' ) } );
	is( scalar( latest_fetches() ), 6, '... the walk started no fetch' );

	advanceTime(898);    # 1799 s after the unfollow
	my $late = items_of( feed( $LATEST, undef ) );
	is_deeply( plays($late), \@before, '1799 s after the unfollow: still the same rows' );
	is( marked($late), scalar @before, '... from the cache entry built at 901 s (the marker)' );
	is( scalar( latest_fetches() ), 6, '... no fetch started' );

	advanceTime(1);      # 1800 s: the tombstone expires (the list cached at 901 s is still fresh)
	is( ref _cache()->get($key), 'ARRAY', '1800 s: the list with B is still cached ...' );
	my $after = items_of( feed( $LATEST, undef ) );
	is( scalar( grep { ( program_of( $_->{name} ) // '' ) eq 'Classic Drive' } @$after ), 0, '30 min after the unfollow: no row from B any more' );
	ok( !( grep { $_ eq '107300001' || $_ eq '107300003' || $_ eq '107300004' || $_ eq '107300005' } @{ plays($after) } ), '... B\'s own episodes are gone' );
	is_deeply( [ map { $_->{name} } grep { ( $_->{play} || '' ) =~ /107300002\z/ } @$after ], ["Hack: Thu 15 Oct $ENDASH Classic Drive: Wednesday"], '... except the one C (Hack) lists itself, now as Hack\'s row' );
	is_deeply( [ sort keys %{ { map { ( program_of( $_->{name} ) // '' ) => 1 } @$after } } ], [ 'Hack', 'The Science Show' ], '... A and C stay' );
	is( ref _cache()->get( Plugins::ABCListen::MyABC::_latestKey( [ $F->list ] ) ), 'ARRAY', '... the new list is cached under the key of A and C (B\'s tombstone gone)' );
	is( items_of( feed( $MY_ABC, undef ) )->[1]->{name}, 'Followed programs (2)', 'Followed programs (2)' );
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
	Plugins::ABCListen::Util::setEpisodeMeta( '2885', { path => "$SCIENCE/x/2885", programTitle => 'The Science Show', title => 'x' } );
	is( ref $TRACKINFO->( undef, 'abclisten://episode/2885' ), 'ARRAY', 'meta entry 2885: rows for abclisten://episode/2885' );

	for my $case (
		[ 'a live station',          'abclisten://live/TRIPLEJ' ],
		[ 'a live id with a meta entry', 'abclisten://live/2885' ],
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

# ---------------------------------------------------------------------------
# O8: Hottest 100, a network-relative program
# ---------------------------------------------------------------------------

my $H100 = '/triplej/hottest-100';

# ABC's answers on 2026-10-19 (O7): /triplej/hottest-100 308s to /triplej/programs/hottest-100.
sub route_hottest_100 {
	route( "$NEXT$H100.json", code => 308, headers => { Location => '/triplej/programs/hottest-100' }, content => '/triplej/programs/hottest-100' );
	route( "$NEXT/triplej/programs/hottest-100.json", file => 'ondemand/nextdata-program-hottest-100.trimmed.json', headers => $JSON_TYPE );
	route( qr{\A\Q$EPS\E\?collectionId=12158996&}, file => 'ondemand/bff-episodesWithSegments-hottest-100.trimmed.json', headers => $JSON_TYPE );
}

subtest 'O8: Hottest 100 - an episode\'s song info has Follow "Hottest 100"; following lists it in Followed programs under the A–Z row\'s path' => sub {
	fresh();
	route_hottest_100();
	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');

	# Programs -> All programs A–Z -> H -> Hottest 100 (the row O7's index lists) -> its episodes
	my $row  = Plugins::ABCListen::OnDemand->programItem( $client, { title => 'Hottest 100', path => $H100, id => '8199386', network => 'triple j' } );
	my $menu = items_of( open_item( $row, $client ) );
	is_deeply( [ @{ names($menu) }[ 1, 2 ] ], [ 'Follow "Hottest 100"', 'Follow to see its new episodes in My ABC listen' ], 'the program menu: Follow "Hottest 100" (as before O8)' );
	is_deeply( plays( [ grep { $_->{play} } @$menu ] ), [qw(106246016 106246024)], 'its 2 episodes' );

	# one plays: song info
	my $url  = 'abclisten://episode/106246016';
	my $meta = Plugins::ABCListen::Util::getEpisodeMeta('106246016');
	is( $meta->{path}, "$H100/hottest-100-25---1/106246016", 'the episode\'s path is network-relative (/triplej/hottest-100/<slug>/<id>)' );
	is( $meta->{programTitle}, 'Hottest 100', '... with its program title' );

	my $rows   = $TRACKINFO->( $client, $url, undef, {}, {} );
	my $target = { title => 'Hottest 100', path => $H100, id => '8199386', image => $meta->{image} };
	is_deeply(
		$rows,
		[ {
			name        => 'Follow "Hottest 100"',
			type        => 'link',
			url         => $ACTION,
			nextWindow  => 'parent',
			passthrough => [ { op => 'follow', program => $target } ],
		}, text_item('Follow to see its new episodes in My ABC listen') ],
		'song info: Follow "Hottest 100" for /triplej/hottest-100, then the hint (no rows before O8)'
	);

	# Follow there
	is_deeply( names( items_of( open_item( $rows->[0], $client ) ) ), ['Following Hottest 100'], 'Follow: "Following Hottest 100"' );
	ok( $F->isFollowed($H100), 'followed under /triplej/hottest-100' );

	# My ABC listen -> Followed programs: Hottest 100
	is( items_of( feed( $MY_ABC, $client ) )->[1]->{name}, 'Followed programs (1)', 'My ABC listen: Followed programs (1)' );
	my $followed = items_of( feed( $FOLLOWED, $client ) );
	is_deeply( names($followed), ['Hottest 100'], 'Followed programs: Hottest 100' );
	is( $followed->[0]->{passthrough}->[0]->{path}, $H100, '... the row opens /triplej/hottest-100 (the A–Z row\'s path)' );

	# the same program everywhere: its program menu (from the A–Z row or from Followed programs) says Following
	for my $from ( [ 'the A–Z row', $row ], [ 'Followed programs', $followed->[0] ] ) {
		my $items = items_of( open_item( $from->[1], $client ) );
		is_deeply( [ @{ names($items) }[ 1, 2 ] ], [ "\x{2713} Following \"Hottest 100\"", 'Unfollow "Hottest 100"' ], "the program menu from $from->[0]: Following, Unfollow" );
	}

	# Latest episodes: its episodes
	my $latest = items_of( feed( $LATEST, $client ) );
	is_deeply( plays($latest), [qw(106246016 106246024)], 'Latest episodes: its 2 episodes' );
	like( $latest->[0]->{name}, qr/\AHottest 100: /, '... "Hottest 100: " rows' );

	# song info now: Following, Unfollow (still two rows); Unfollow there
	$rows = $TRACKINFO->( $client, $url );
	is_deeply( names($rows), [ "\x{2713} Following \"Hottest 100\"", 'Unfollow "Hottest 100"' ], 'song info while following: Following, Unfollow (two rows)' );
	is_deeply( names( items_of( open_item( $rows->[1], $client ) ) ), ['No longer following Hottest 100'], 'Unfollow: "No longer following Hottest 100"' );
	ok( !$F->isFollowed($H100), 'not followed any more' );
	is_deeply( names( items_of( feed( $FOLLOWED, $client ) ) ), ['Hottest 100'], 'Followed programs keeps its row for 30 min (M4 tombstone)' );
	is( scalar @{ $TRACKINFO->( $client, $url ) }, 2, 'song info: two rows again (Follow, hint)' );

	# the other episode: the same program
	is( $TRACKINFO->( undef, 'abclisten://episode/106246024' )->[0]->{passthrough}->[0]->{program}->{path}, $H100, 'the other episode: the same program path' );

	is( scalar( warnings_logged() ) + scalar( errors_logged() ), 0, 'nothing at WARN or ERROR' );
};

subtest 'O8: /programs/ episodes are unchanged; a network page or an archived page under a network has no follow rows' => sub {
	fresh();
	Plugins::ABCListen::Util::setEpisodeMeta( '107266790', { path => "$SCIENCE/trees-potatoes-brendan-may-step/107266790", programTitle => 'The Science Show' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '107400001', { path => '/triplej/programs/hack/hack-15-october/107400001', programTitle => 'Hack' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '7099490',   { path => '/listen/radionational/archived/summerschool/chas-licciardello/7099490', programTitle => 'Summer School' } );
	Plugins::ABCListen::Util::setEpisodeMeta( '2913842',   { path => '/listen/radionational/robyn-williams/2913842', programTitle => 'The Science Show' } );

	is( $TRACKINFO->( undef, 'abclisten://episode/107266790' )->[0]->{passthrough}->[0]->{program}->{path}, $SCIENCE, '/listen/programs/: the program path, as before' );
	is( $TRACKINFO->( undef, 'abclisten://episode/107400001' )->[0]->{passthrough}->[0]->{program}->{path}, $HACK,    '/triplej/programs/: the program path, as before' );
	is( $TRACKINFO->( undef, 'abclisten://episode/7099490' ), undef, 'an archived program\'s page under /listen/radionational: no follow rows' );
	is( $TRACKINFO->( undef, 'abclisten://episode/2913842' ), undef, 'a presenter page under /listen/radionational: no follow rows' );
};

# ---------------------------------------------------------------------------
# F8 (#78): cache writes per walk, the WARN for a removed program
# ---------------------------------------------------------------------------

subtest 'F8: walking the 50-row Latest episodes list writes the meta cache only for what changed' => sub {
	fresh();
	$F->follow($_) for map { route_generated($_) } 1 .. 12;

	my %writes;
	no warnings 'redefine';
	my $set = \&Slim::Utils::Cache::set;
	local *Slim::Utils::Cache::set = sub { $writes{ $_[1] =~ /^episode-meta:/ ? 'meta' : 'other' }++; $set->(@_) };
	my $walk = sub {
		%writes = ();
		my $rows = items_of( feed( $LATEST, undef ) );
		return [ scalar @$rows, $writes{meta} || 0, $writes{other} || 0 ];
	};

	is_deeply( $walk->(), [ 50, 50, 26 ], 'first walk: 50 rows, 50 new meta entries written (and 26 other writes: 12 pages, 12 episode lists, the site config, the merged list)' );
	advanceTime(60);
	is_deeply( $walk->(), [ 50, 0, 0 ], 'the same walk a minute later (LMS re-walks for every item_id): 50 rows, no write at all (before F8: 50 meta writes)' );
	advanceTime(60);
	is_deeply( $walk->(), [ 50, 0, 0 ], '... and again' );

	advanceTime(900);
	is_deeply( $walk->(), [ 50, 0, 13 ], 'rebuilt after 15 min (the same answers from ABC): no meta write; 13 other writes (12 episode lists fetched again, 15 min TTL, and the merged list)' );

	setTime( $T0 + 86400 );
	my $r = $walk->();
	is_deeply( [ @$r[ 0, 1 ] ], [ 50, 50 ], 'a day later: the 50 unchanged entries are written once more (their 30 days renewed)' );
	advanceTime(60);
	is( $walk->()->[1], 0, '... and not again' );
};

subtest 'F8: a followed program ABC removed: one WARN a day, DEBUG on every other Latest rebuild' => sub {
	fresh();
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';    # record DEBUG lines too
	$F->follow( route_generated(1) );
	route( "$NEXT/listen/programs/removed.json", code => 404, content => '{}' );
	$F->follow( { title => 'Removed Program', path => '/listen/programs/removed' } );

	my $logged = sub { my $level = shift; scalar grep { $_->{level} eq $level && $_->{message} =~ m{skipped the program Removed Program \(/listen/programs/removed\)} } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) };

	# in use for an hour: Latest rebuilt every 15 min
	for my $rebuild ( 1 .. 4 ) {
		is( scalar @{ items_of( feed( $LATEST, undef ) ) }, 5, "rebuild $rebuild: Generated 1's five episodes" );
		advanceTime(901);
	}
	is( $logged->('WARN'),  1, 'four rebuilds: one WARN (before F8: four, and one every 15 min for ever)' );
	is( $logged->('DEBUG'), 3, '... the other three at DEBUG' );

	setTime( $T0 + 86400 );
	feed( $LATEST, undef );
	is( $logged->('WARN'), 2, 'a day after the first WARN: one more' );

	route( "$NEXT/listen/programs/removed-too.json", code => 404, content => '{}' );
	$F->follow( { title => 'Also Removed', path => '/listen/programs/removed-too' } );
	feed( $LATEST, undef );
	is( scalar( grep { m{skipped the program Also Removed} } warnings_logged() ), 1, 'another removed program: its own WARN' );
	is( $logged->('WARN'), 2, '... and none more for the first' );
};

done_testing();
