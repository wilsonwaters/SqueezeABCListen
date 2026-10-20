#!/usr/bin/perl
# Plugins::ABCListen::Discover (top-level "Home", D1; "Podcasts" and Home's root, D2) and the
# collection menus of Plugins::ABCListen::Collections, offline (SimpleAsyncHTTP stub fails any
# unrouted URL; fake clock): the Home and Podcasts items (exact keys, weights, menuWeights, no
# network) and their place at the top; Home's root (Featured, Popular now, Popular in sport, then
# the home collections in page order without the home "Categories" collection, found by
# podcasts()'s rule rather than its id (D6; D7: a mixed collection with a category card stays
# listed, a categories collection without an id leaves the next one listed); Featured omitted
# without a mappable hero item; no request beyond the home page); collection menus (20 per page + More… with the right offsets, last page
# without More…, missing total, empty / null / past-the-end pages, API errors, the depth limit);
# the home Categories collection -> True Crime (dynamiccollection leaf ids); Radio Stations with and without L1's live
# API; the keys the menu:1 (Jive) rendering relies on; readable names everywhere; exactly one
# callback on every path. The Podcasts menu itself: t/42-categories.t; Popular now /
# Popular in sport: t/43-recommendations.t.
#
# Fixtures: t/data/discovery/ (see t/40-collections.t) and the F3 search page
# t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::Discover;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Search;
use Plugins::ABCListen::Sections;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# L1's Stations.pm may not exist yet: let require() find the test's stubs either way.
eval { require Plugins::ABCListen::Stations; 1 } or $INC{'Plugins/ABCListen/Stations.pm'} = __FILE__;

my $DISCOVER    = 'Plugins::ABCListen::Discover';
my $COL         = 'Plugins::ABCListen::Collections';
my $SITE        = 'https://www.abc.net.au';
my $BFF_COLL    = "$SITE/core-next/api/collection/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $T0          = 1_792_400_000;
my $ICON        = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $CLIENT      = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $HOME_ROOT   = \&Plugins::ABCListen::Discover::_homeRoot;
my $PODCASTS    = \&Plugins::ABCListen::Discover::_podcastsRoot;
my $RECS_MENU   = \&Plugins::ABCListen::Discover::_recommendationsMenu;
my $COLL_MENU   = \&Plugins::ABCListen::Collections::_collectionMenu;
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE        = string('PLUGIN_ABCLISTEN_MORE');
my $FEATURED    = string('PLUGIN_ABCLISTEN_FEATURED');
my $POPULAR     = string('PLUGIN_ABCLISTEN_POPULAR_NOW');
my $SPORT       = string('PLUGIN_ABCLISTEN_POPULAR_SPORT');

my @HOME_TITLES = (
	"Today's Top Picks", 'Top 100 Australian Books', 'Radio Stations', 'Latest News', 'Most Popular Podcasts',
	'True Crime & Investigations', 'Health & Wellbeing', 'Society & Culture', 'Music For Every Mood',
	'Looking For Something New?', 'Relax & Sleep',
);    # the page's 13th collection, "Categories" (14123152), is listed under Podcasts instead

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# L1 stubs (contract 7): the test's own station table, by site path (D4: lookups are by path)
my %SLUGS;
{
	no warnings qw(redefine once);
	*Plugins::ABCListen::Stations::byPageSlug = sub { $SLUGS{ $_[1] } };
	*Plugins::ABCListen::Live::stationItem    = sub {
		my ( $class, $client, $id ) = @_;
		my $url = "abclisten://live/$id";
		return { name => "Station $id", type => 'audio', on_select => 'play', url => $url, favorites_url => $url, image => $ICON };
	};
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	%SLUGS = ( '/listen/live/sport' => 'SPORT', '/listen/radionational' => 'RN', '/triplej' => 'TRIPLEJ', '/listen/classic' => 'CLASSIC' );
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture( $_[0] ) ) }

sub route_home { route( "$NEXT/listen.json", file => 'discovery/nextdata-listen-home.trimmed.json', headers => $JSON_TYPE ) }

sub route_collection {
	my ( $id, $offset, $file ) = @_;
	route( "$BFF_COLL?collectionId=$id&offset=$offset&size=20", file => "discovery/$file", headers => $JSON_TYPE );
}

sub route_json {
	my ( $match, $data ) = @_;
	route( $match, code => 200, headers => $JSON_TYPE, content => to_json($data) );
}

# Program pages are not routed in most tests: name lookups fail fast (no fixture) and keep the
# card titles. Silence their WARN lines by checking only this module's messages where it matters.

# Call a feed coderef as XMLBrowser does: ($client, $cb, $args, @passthrough). Returns the collector.
sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item {
	my ( $item, $client ) = @_;
	return feed( $item->{url}, $client, @{ $item->{passthrough} || [] } );
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && !ref $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty text name" );
}

sub home_root {
	my $c = feed( $HOME_ROOT, $CLIENT );
	is( $c->count, 1, 'Home: one callback' );
	return items_of($c);
}

sub collection_requests { map { $_->{url} } grep { $_->{url} =~ m{/collection/x} } requests() }

sub card {
	my ( $uri, %more ) = @_;
	return { contentUri => $uri, cardTitle => 'Card ' . ( $uri =~ m{/([0-9]+)\z} )[0], %more };
}

sub warnings_from_collections { grep { $_->{level} =~ /WARN|ERROR/ && $_->{message} !~ /nextData \/(?:listen|triplej|kidslisten)\/programs\// } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# ---------------------------------------------------------------------------

subtest 'menuItems: "Home" (weight 10) and "Podcasts" (weight 30) links, then the D4 sections; no network; menuWeights' => sub {
	fresh();
	my $c = collector();
	$DISCOVER->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'one callback' );
	my ($items) = $c->args(0);
	is_deeply(
		[ @$items[ 0, 1 ] ],
		[
			{ name => 'Home',     type => 'link', url => $HOME_ROOT, image => $ICON, weight => 10 },
			{ name => 'Podcasts', type => 'link', url => $PODCASTS,  image => $ICON, weight => 30 },
		],
		'exact keys: name, type link, url (_homeRoot / _podcastsRoot), plugin icon, weight'
	);
	is_deeply( [ @$items[ 2 .. $#$items ] ], [ Plugins::ABCListen::Sections->topItems(undef) ], 'then Sections->topItems (D4; exact keys in t/47), nothing else' );
	my ( $home, $podcasts ) = @$items;
	is( $home->{name}, string('PLUGIN_ABCLISTEN_HOME'), 'Home: name from PLUGIN_ABCLISTEN_HOME' );
	is( $home->{weight}, Plugins::ABCListen::Util::topWeight('home'), 'Home: weight = Util::topWeight("home")' );
	is( $podcasts->{name}, string('PLUGIN_ABCLISTEN_PODCASTS'), 'Podcasts: name from PLUGIN_ABCLISTEN_PODCASTS' );
	is( $podcasts->{weight}, Plugins::ABCListen::Util::topWeight('podcasts'), 'Podcasts: weight = Util::topWeight("podcasts")' );
	is_deeply(
		[ $DISCOVER->menuWeights ],
		[ ( map { Plugins::ABCListen::Util::topWeight($_) } qw(home podcasts) ), Plugins::ABCListen::Sections->menuWeights ],
		'menuWeights = (topWeight("home"), topWeight("podcasts"), Sections->menuWeights)'
	);
	is( scalar requests(), 0, 'no HTTP request' );
	ok( eval { $DISCOVER->init; 1 }, 'init is harmless' );

	$c = collector();
	$DISCOVER->menuItems( $CLIENT, $c->cb, {} );
	is_deeply( names( ( $c->args(0) )[0] ), [ 'Home', 'Podcasts', 'News', 'Sport', 'Kids listen', 'Audiobooks' ], 'with a client too' );
};

subtest 'top level: Home first (10), Podcasts after Radio (30)' => sub {
	fresh();
	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( undef, $c->cb, { params => {} } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is( $items->[0]->{name}, 'Home', 'Home first' );
	is_deeply(
		names($items),
		[ 'Home', 'Radio', 'Podcasts', 'News', 'Sport', 'Kids listen', 'Audiobooks', 'Programs', 'Search', 'My ABC listen' ],
		'Home, Radio, Podcasts (D2), News, Sport, Kids listen, Audiobooks (D4), Programs, Search (D3), My ABC listen (M2)'
	);
	ok( !( grep { exists $_->{weight} } @$items ), 'weights removed by Plugin.pm' );
	is( scalar requests(), 0, 'no HTTP request for the top level' );
};

subtest 'Home root: Featured, Popular now, Popular in sport, then the home collections in page order' => sub {
	fresh();
	route_home();
	my $items = home_root();

	is_deeply(
		names($items),
		[ $FEATURED, 'Popular now', 'Popular in sport', @HOME_TITLES ],
		'Featured, Popular now, Popular in sport, then every home StandardCollection in page order without "Explore Video Podcasts" and "Categories"'
	);
	is_deeply( [ map { [ $_->{url}, $_->{passthrough} ] } @$items[ 1, 2 ] ], [ [ $RECS_MENU, ['homepagePopularNow'] ], [ $RECS_MENU, ['homepageSports'] ] ], 'Popular now / Popular in sport open the recommendations homepagePopularNow / homepageSports' );
	is_deeply( $items->[1], { name => $POPULAR, type => 'link', url => $RECS_MENU, passthrough => ['homepagePopularNow'], image => $ICON }, 'Popular now: exact keys (static link, plugin icon)' );
	is( $SPORT, 'Popular in sport', '(PLUGIN_ABCLISTEN_POPULAR_SPORT text)' );
	is_deeply( [ map { $_->{url} } requests() ], [ "$SITE/listen/search", "$NEXT/listen.json" ], 'building the root fetches only the home page (Popular now / in sport fetch nothing until opened)' );

	my $featured = $items->[0];
	is( $featured->{type}, 'link', 'Featured is a link' );
	is( ref $featured->{items}, 'ARRAY', 'with its items inline' );
	is_deeply( [ map { $_->{line1} } @{ $featured->{items} } ], [ 'Bondy: From Hero to Zero', 'Planet America', 'Dark Menace' ],
		'Featured: the hero items in carousel order; the unknown one (Top 100 Australian Books countdown page) skipped' );
	is( $featured->{image}, $featured->{items}->[0]->{image}, 'Featured shows the first hero item\'s artwork' );
	is( $featured->{items}->[0]->{play}, 'abclisten://episode/107182078', 'a hero episode plays directly' );
	is( $featured->{items}->[1]->{url}, \&Plugins::ABCListen::OnDemand::_programMenu, 'a hero program opens O2\'s program menu' );
	ok( !( grep { m{/programs/} } map { $_->{url} } requests() ), 'hero items: no program name lookups' );

	my ($popular) = grep { $_->{name} eq 'Most Popular Podcasts' } @$items;
	is_deeply(
		$popular,
		{
			name        => 'Most Popular Podcasts',
			type        => 'link',
			url         => $COLL_MENU,
			passthrough => [ { id => '103194120', title => 'Most Popular Podcasts', image => $popular->{image} }, 0, 1 ],
			image       => $popular->{image},
		},
		'collection link: exact keys (name, type, url, passthrough [collection, offset 0, level 1], image)'
	);
	like( $popular->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/0b00910f69470533fe28ab472d099166\?.*width=300}, 'the first card\'s artwork' );
	ok( !( grep { !$_->{image} } @$items ), 'every root item has an image' );
	ok( !( grep { $_->{passthrough} && ref $_->{passthrough}->[0] eq 'HASH' && $_->{passthrough}->[0]->{id} eq '14123152' } @$items ), 'the home "Categories" collection (14123152) is not listed' );
	ok( !( grep { $_->{name} =~ /\A(?:Categories|Browse by category|Podcasts)\z/ } @$items ), 'no Categories, Browse by category or Podcasts entry under Home (they are in the top-level Podcasts menu)' );
	ok( !( grep { exists $_->{description} } @$items, @{ $featured->{items} } ), 'no description on any browse item (LMS menu rule 1)' );
	check_names( $items, 'Home' );
	check_names( $featured->{items}, 'Featured' );
	is( scalar warnings_from_collections(), 0, 'no WARN or ERROR' );
};

subtest 'Home root (D6): the categories collection is found by podcasts()\'s rule (category cards), not by its id' => sub {
	my $home       = json_file('discovery/nextdata-listen-home.trimmed.json');
	my @components = @{ $home->{pageProps}->{data}->{componentsContent} };
	my ($categories) = grep { ( $_->{key} // '' ) eq '14123152' } @components;
	my ($picks)      = grep { ( $_->{key} // '' ) eq '103194114' } @components;
	my $with = sub {
		my %replace = @_;
		my @list = map { exists $replace{ $_->{key} // '' } ? @{ $replace{ $_->{key} } } : $_ } @components;
		route_json( "$NEXT/listen.json", { pageProps => { data => { componentsContent => \@list } } } );
	};
	my $copy = sub {
		my ( $component, $id, $title ) = @_;
		return { %$component, key => $id, componentProps => { %{ $component->{componentProps} }, id => $id, defined $title ? ( title => $title ) : () } };
	};
	my $ids = sub { [ map { $_->{passthrough}->[0]->{id} } grep { $_->{url} && $_->{url} == $COLL_MENU } @{ $_[0] } ] };

	fresh();
	$with->( 14123152 => [ $copy->( $categories, '99999999' ) ] );
	my $items = home_root();
	is_deeply( names($items), [ $FEATURED, $POPULAR, $SPORT, @HOME_TITLES ], 'ABC re-creates "Categories" with a new id (99999999): still not listed under Home' );
	ok( !( grep { $_ eq '99999999' } @{ $ids->($items) } ), '(no link to 99999999)' );

	fresh();
	$with->(
		103194114 => [ $copy->( $categories, '555', 'Browse' ), $picks ],
		14123152  => [ $copy->( $picks, '14123152', 'Not categories' ) ],
	);
	$items = home_root();
	ok( !( grep { $_ eq '555' } @{ $ids->($items) } ), 'the first collection with category cards (555) is the one left out' );
	is( ( grep { $_->{name} eq 'Not categories' } @$items )[0]->{passthrough}->[0]->{id}, '14123152', 'a collection with id 14123152 but no category cards is listed' );

	fresh();
	$with->( 103194114 => [ $copy->( $categories, '555', 'Browse' ), $picks ] );
	$items = home_root();
	ok( !( grep { $_ eq '555' } @{ $ids->($items) } ), 'two collections with category cards: the first (555) is left out ...' );
	ok( ( grep { $_ eq '14123152' } @{ $ids->($items) } ), '... the second (14123152) is listed (podcasts() also uses the first)' );

	fresh();
	$with->( 14123152 => [] );
	is_deeply( names( home_root() ), [ $FEATURED, $POPULAR, $SPORT, @HOME_TITLES ], 'no categories collection: every collection listed' );

	# D7 (D6 review finding 1): ABC adds one category card to an earlier Home collection
	my ($categoryCard) = @{ $categories->{componentProps}->{items} };
	my $mixed = { %$picks, componentProps => { %{ $picks->{componentProps} }, items => [ @{ $picks->{componentProps}->{items} }, $categoryCard ] } };
	fresh();
	$with->( 103194114 => [$mixed] );
	$items = home_root();
	is_deeply( names($items), [ $FEATURED, $POPULAR, $SPORT, @HOME_TITLES ], 'D7: Today\'s Top Picks with one category card added: still listed; Categories still hidden' );
	ok( ( grep { $_ eq '103194114' } @{ $ids->($items) } ), '(the mixed collection 103194114 is listed)' );
	ok( !( grep { $_ eq '14123152' } @{ $ids->($items) } ), '(the real categories collection 14123152 is not)' );

	# D7 (D6 review finding 2): a categories collection without an id, then the real one
	my $noId = { %$categories, key => 'no-id', componentProps => { %{ $categories->{componentProps} } } };
	delete $noId->{componentProps}->{id};
	fresh();
	$with->( 103194114 => [ $noId, $picks ] );
	$items = home_root();
	ok( ( grep { $_ eq '14123152' } @{ $ids->($items) } ), 'D7: a categories collection without an id first: categoriesId undef, so the second (14123152) is listed under Home' );
	is_deeply( names($items), [ $FEATURED, $POPULAR, $SPORT, @HOME_TITLES, 'Categories' ], '(the id-less one is omitted; Categories is listed last, in page order)' );
};

subtest 'Home root: Featured omitted when no hero item maps; collection link fallbacks' => sub {
	fresh();
	route_json( "$NEXT/listen.json", { pageProps => { data => { componentsContent => [
		{ component => 'HeroCarousel', componentProps => { items => [
			{ itemUri => 'coremedia://unknown/1', title => 'Countdown', buttonProps => { canonicalURL => 'https://www.abc.net.au/listen/listenapp' } },
			{ itemUri => 'coremedia://article/2', title => 'Article', buttonProps => { canonicalURL => 'https://www.abc.net.au/news/x/2' } },
		] } },
		{ component => 'StandardCollection', key => '7', componentProps => { id => '7', title => '', items => [ card('coremedia://audio/8') ] } },
	] } } } );

	my $items = home_root();
	is_deeply( names($items), [ $POPULAR, $SPORT, $FEATURED ], 'no Featured entry: Popular now, Popular in sport, then the untitled collection, named "Featured" rather than blank' );
	is( $items->[2]->{url}, $COLL_MENU, '(it is the collection link)' );
	is( $items->[2]->{image}, $ICON, 'no card image: the plugin icon' );

	fresh();
	route_json( "$NEXT/listen.json", { pageProps => { data => { componentsContent => [ { component => 'AppStoreCTA', componentProps => {} } ] } } } );
	is_deeply( names( home_root() ), [ $POPULAR, $SPORT ], 'no home collections: Popular now and Popular in sport, never an empty list' );
};

subtest 'Home root: page errors; last-good copy' => sub {
	fresh();
	route( "$NEXT/listen.json", code => 500, content => 'down' );
	my $items = home_root();
	is_deeply( names($items), [ $POPULAR, $SPORT, $LOAD_FAILED ], 'ABC down, nothing cached: Popular now, Popular in sport, then one LOAD_FAILED item' );
	is_deeply( $items->[2], { name => $LOAD_FAILED, type => 'text' }, '(a text item)' );

	fresh();
	route( "$NEXT/listen.json", code => 429, content => 'slow' );
	is_deeply( home_root()->[2], { name => string('PLUGIN_ABCLISTEN_RATE_LIMITED'), type => 'text' }, 'the API token\'s text (RATE_LIMITED)' );

	fresh();
	route_home();
	my $before = names( home_root() );
	advanceTime(3601);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( "$NEXT/listen.json", code => 500, content => 'down' );
	is_deeply( names( home_root() ), $before, 'ABC down after the hour: the last-good home is served' );

	fresh();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::home = sub { die "engine broke\n" };
		is_deeply( home_root(), [ { name => $LOAD_FAILED, type => 'text' } ], 'the engine dying: LOAD_FAILED item, once' );
	}
	{
		no warnings 'redefine';
		route_home();
		local *Plugins::ABCListen::Collections::collectionItem = sub { die "link broke\n" };
		is_deeply( home_root(), [ { name => $LOAD_FAILED, type => 'text' } ], 'building the root dying: LOAD_FAILED item, once' );
	}
};

subtest 'collection menu: 20 per page + More…; last page without More…' => sub {
	fresh();
	route_home();
	route_collection( 103194120, 0,  'bff-collection-103194120-most-popular-podcasts-o0.json' );
	route_collection( 103194120, 20, 'bff-collection-103194120-most-popular-podcasts-o20.json' );
	route_collection( 103194120, 40, 'bff-collection-103194120-most-popular-podcasts-o40.json' );

	my ($popular) = grep { $_->{name} eq 'Most Popular Podcasts' } @{ home_root() };

	my $c = open_item($popular);
	advanceTime(3);    # program name lookups (not routed here) end by the deadline at the latest
	is( $c->count, 1, 'page 1: one callback' );
	my $page1 = items_of($c);
	is( scalar @$page1, 21, '20 items + More…' );
	is( scalar( grep { $_->{url} && $_->{url} == \&Plugins::ABCListen::OnDemand::_programMenu } @$page1 ), 20, '20 program links' );
	ok( !( grep { !$_->{image} } @$page1[ 0 .. 19 ] ), 'every program link has an image' );
	is_deeply( $page1->[20], { name => $MORE, type => 'link', url => $COLL_MENU, passthrough => [ { id => '103194120', title => 'Most Popular Podcasts', image => $popular->{image} }, 20, 1 ] }, 'More…: next offset 20, same level' );
	is( $page1->[20]->{name}, 'More…', 'named "More…"' );

	$c = open_item( $page1->[20] );
	advanceTime(3);
	my $page2 = items_of($c);
	is( scalar @$page2, 21, 'page 2: 20 + More…' );
	is( $page2->[20]->{passthrough}->[1], 40, 'More… offset 40' );

	$c = open_item( $page2->[20] );
	advanceTime(3);
	my $page3 = items_of($c);
	is( scalar @$page3, 15, 'page 3: the last 15 programs, no More… (40 + 15 = total 55)' );
	ok( !( grep { $_->{name} eq $MORE } @$page3 ), 'no More…' );

	is_deeply(
		[ collection_requests() ],
		[ map {"$BFF_COLL?collectionId=103194120&offset=$_&size=20"} 0, 20, 40 ],
		'requests: offsets 0, 20, 40, size 20'
	);
	check_names( [ @$page1, @$page2, @$page3 ], 'Most Popular Podcasts' );
	is( $c->count, 1, 'one callback per page' );
};

subtest 'collection menu: names of programs (second open uses the cache)' => sub {
	fresh();
	route_collection( 103194120, 0, 'bff-collection-103194120-most-popular-podcasts-o0.json' );
	route( "$NEXT/listen/programs/if-youre-listening.json", file => 'discovery/nextdata-program-if-youre-listening.trimmed.json', headers => $JSON_TYPE );

	my $collection = { id => '103194120', title => 'Most Popular Podcasts' };
	my $c = feed( $COLL_MENU, $CLIENT, $collection, 0, 1 );
	advanceTime(3);
	is( items_of($c)->[0]->{name}, "If You're Listening", 'coremedia://program/104252122 is named "If You\'re Listening" (its ABC page), not the tagline' );
	is( items_of($c)->[0]->{passthrough}->[0]->{description}, "What's really going on behind the biggest news stories", 'the tagline travels as the program\'s description' );

	$c = feed( $COLL_MENU, $CLIENT, $collection, 0, 1 );
	is( $c->count, 1, 'second open: answered at once (collection and program page cached)' );
	is( items_of($c)->[0]->{name}, "If You're Listening", 'second open: same name' );
};

subtest 'collection menu: empty, null, past the end, missing total, short pages' => sub {
	fresh();
	route( qr{\Q$BFF_COLL\E\?collectionId=1&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { title => 'Empty', items => [], pagination => { offset => 0, size => 0, total => 0 } } } ) );
	is_deeply( items_of( feed( $COLL_MENU, $CLIENT, { id => 1 }, 0, 1 ) ), [ { name => $EMPTY, type => 'text' } ], 'empty collection: "Nothing here right now"' );
	is( $EMPTY, 'Nothing here right now', '(PLUGIN_ABCLISTEN_EMPTY_COLLECTION text)' );

	fresh();
	route_collection( 14129466, 0, 'bff-collection-14129466-null.json' );
	is_deeply( items_of( feed( $COLL_MENU, $CLIENT, { id => 14129466 }, 0, 1 ) ), [ { name => $EMPTY, type => 'text' } ], '{"collection":null}: empty text item' );

	fresh();
	route( qr{\Q$BFF_COLL\E\?collectionId=2&offset=60&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => [], pagination => { offset => 60, size => 0, total => 55 } } } ) );
	is_deeply( items_of( feed( $COLL_MENU, $CLIENT, { id => 2 }, 60, 1 ) ), [ { name => $EMPTY, type => 'text' } ], 'offset >= total: empty text item, no More…' );

	fresh();
	my @audio = map { card( "coremedia://audio/$_", articleLink => "/listen/programs/x/y/$_" ) } 1 .. 3;
	route( qr{\Q$BFF_COLL\E\?collectionId=3&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => \@audio, pagination => {} } } ) );
	my $items = items_of( feed( $COLL_MENU, $CLIENT, { id => 3 }, 0, 1 ) );
	is( scalar @$items, 3, 'no total: the cards, no More…' );

	fresh();
	route( qr{\Q$BFF_COLL\E\?collectionId=4&offset=0&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => \@audio, pagination => { total => 50 } } } ) );
	route( qr{\Q$BFF_COLL\E\?collectionId=4&offset=3&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => [], pagination => { total => 50 } } } ) );
	$items = items_of( feed( $COLL_MENU, $CLIENT, { id => 4 }, 0, 1 ) );
	is_deeply( [ names($items)->[-1], $items->[-1]->{passthrough}->[1] ], [ $MORE, 3 ], 'fewer cards than total: More… at offset + cards sent (3)' );
	is_deeply( items_of( open_item( $items->[-1] ) ), [ { name => $EMPTY, type => 'text' } ], 'a page with 0 cards ends it: empty text, no More…' );

	fresh();
	my @videos = map { card("coremedia://video/$_") } 1 .. 3;
	route( qr{\Q$BFF_COLL\E\?collectionId=5&offset=0&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => \@videos, pagination => { total => 6 } } } ) );
	$items = items_of( feed( $COLL_MENU, $CLIENT, { id => 5 }, 0, 1 ) );
	is_deeply( [ map { [ $_->{name}, $_->{passthrough} ? $_->{passthrough}->[1] : undef ] } @$items ], [ [ $MORE, 3 ] ], 'a page of unsupported cards with more to come: just More…' );
};

subtest 'collection menu: API errors are one text item' => sub {
	fresh();
	route( qr{\Q$BFF_COLL\E}, code => 500, content => 'down' );
	my $c = feed( $COLL_MENU, $CLIENT, { id => 103194120 }, 0, 1 );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ { name => $LOAD_FAILED, type => 'text' } ], 'LOAD_FAILED text item' );

	fresh();
	route( qr{\Q$BFF_COLL\E}, code => 429, content => 'slow' );
	is_deeply( items_of( feed( $COLL_MENU, $CLIENT, { id => 103194120 }, 0, 1 ) ), [ { name => string('PLUGIN_ABCLISTEN_RATE_LIMITED'), type => 'text' } ], 'RATE_LIMITED text item' );

	fresh();
	is_deeply( items_of( feed( $COLL_MENU, $CLIENT, undef, undef, undef ) ), [ { name => $LOAD_FAILED, type => 'text' } ], 'a broken passthrough: LOAD_FAILED, no request' );
	is( scalar requests(), 0, 'no request' );

	fresh();
	route_collection( 103194114, 0, 'bff-collection-103194114-todays-top-picks.json' );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub { die "builder broke\n" };
		$c = feed( $COLL_MENU, $CLIENT, { id => 103194114 }, 0, 1 );
	}
	is( $c->count, 1, 'every builder dying: still one callback' );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'nothing listable: empty text item' );

	fresh();
	route_collection( 103194114, 0, 'bff-collection-103194114-todays-top-picks.json' );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::itemsFor = sub { die "engine broke\n" };
		$c = feed( $COLL_MENU, $CLIENT, { id => 103194114 }, 0, 1 );
	}
	is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'the engine dying: one LOAD_FAILED callback' );

	fresh();
	route_collection( 103194114, 0, 'bff-collection-103194114-todays-top-picks.json' );
	my $calls = 0;
	my $dies  = sub { $calls++; die "LMS callback broke\n" };
	eval { $COLL_MENU->( $CLIENT, $dies, {}, { id => 103194114 }, 0, 1 ); 1 };
	is( $calls, 1, 'a callback that dies is called once, never twice' );
};

subtest 'Today\'s Top Picks: episodes play directly (menu:1 shape keys)' => sub {
	fresh();
	route_collection( 103194114, 0, 'bff-collection-103194114-todays-top-picks.json' );
	my $items = items_of( feed( $COLL_MENU, $CLIENT, { id => 103194114, title => "Today's Top Picks" }, 0, 1 ) );

	is( scalar @$items, 8, 'the 8 cards (audioepisode, audiosegment, audio)' );
	for my $item (@$items) {
		like( $item->{play}, qr{\Aabclisten://episode/[0-9]+\z}, "$item->{line1}: play = abclisten://episode/<id> (Jive play action; favourites store it)" );
		is( $item->{type}, 'link', "$item->{line1}: a link to the episode page" );
		ok( $item->{image}, "$item->{line1}: image" );
	}
	is( $items->[0]->{play}, 'abclisten://episode/107232952', 'the first card plays its cardId, not its teaser contentUri id 107282420' );
	check_names( $items, "Today's Top Picks" );
};

subtest 'home Categories collection -> True Crime: program links (dynamiccollection leaf id)' => sub {
	fresh();
	route_collection( 14123152,  0, 'bff-collection-14123152-categories.trimmed.json' );
	route_collection( 104142226, 0, 'bff-collection-104142226-true-crime-category.trimmed.json' );

	# no longer listed under Home (D2: Podcasts -> Browse by category, t/42), but the engine still pages it
	my $list = items_of( feed( $COLL_MENU, $CLIENT, { id => '14123152', title => 'Categories' }, 0, 1 ) );
	is_deeply( names($list), [ 'News & Analysis', 'True Crime', 'Sport', 'For Kids & Families', 'History', 'Society & Culture', $MORE ], 'the category links (trimmed fixture: 6 of 18, then More…)' );

	my ($trueCrime) = grep { $_->{name} eq 'True Crime' } @$list;
	is( $trueCrime->{passthrough}->[0]->{id}, '104142226', 'True Crime pages collection 104142226 (articleLink leaf)' );
	is( $trueCrime->{passthrough}->[2], 2, 'at level 2' );

	my $c = open_item($trueCrime);
	advanceTime(3);
	my $programs = items_of($c);
	cmp_ok( scalar( grep { $_->{url} && $_->{url} == \&Plugins::ABCListen::OnDemand::_programMenu } @$programs ), '>=', 1, '>= 1 program link' );
	is( $programs->[-1]->{name}, $MORE, 'More… (ABC reports 22)' );
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=104142226&offset=0&size=20", 'requested collectionId=104142226' );
};

subtest 'depth limit: nested collections stop at level 3 with a visible text item' => sub {
	fresh();
	# collection 9 contains itself
	route( qr{\Q$BFF_COLL\E\?collectionId=9&}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { title => 'Loop', items => [ card( 'coremedia://collection/9', cardTitle => 'Loop' ) ], pagination => { total => 1 } } } ) );

	my $level1 = items_of( feed( $COLL_MENU, $CLIENT, { id => 9, title => 'Loop' }, 0, 1 ) );
	is( $level1->[0]->{passthrough}->[2], 2, 'level 1 lists the nested collection (opens level 2)' );
	my $level2 = items_of( open_item( $level1->[0] ) );
	is( $level2->[0]->{passthrough}->[2], 3, 'level 2 lists it (opens level 3)' );
	my $level3 = items_of( open_item( $level2->[0] ) );
	is_deeply( $level3, [ { name => $EMPTY, type => 'text' } ], 'level 3: the nested link is dropped; a visible text item, not an empty list' );
};

subtest 'Radio Stations: station items with L1\'s live API; omitted from Home without it' => sub {
	fresh();
	route_home();
	route_collection( 102833294, 0, 'bff-collection-102833294-radio-stations.json' );

	my ($stations) = grep { $_->{name} eq 'Radio Stations' } @{ home_root() };
	ok( $stations, 'Radio Stations listed' );
	my $items = items_of( open_item($stations) );
	is_deeply( [ map { $_->{url} } @$items ], [ map {"abclisten://live/$_"} qw(SPORT RN CLASSIC TRIPLEJ) ], 'the mapped station cards, in order, as Live->stationItem builds them' );
	is( scalar warnings_from_collections(), 0, 'unmapped cards: no WARN/ERROR' );

	fresh();
	route_home();
	no warnings 'redefine';
	local *Plugins::ABCListen::Stations::byPageSlug;
	ok( !( grep { $_->{name} eq 'Radio Stations' } @{ home_root() } ), 'no Stations->byPageSlug (L1 not merged): Radio Stations is not offered' );
	is( scalar warnings_from_collections(), 0, 'no WARN/ERROR' );
};

subtest 'a feed callback that dies (D1 review): logged, never called a second time, never escapes' => sub {
	my $dying = sub {
		my $calls = shift;
		return sub { $$calls++; die "LMS callback broke\n" };
	};
	my $logged = sub { scalar grep { $_->{level} eq 'ERROR' && $_->{message} =~ /LMS callback broke/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) };

	fresh();
	route_home();
	my $calls = 0;
	ok( eval { $HOME_ROOT->( $CLIENT, $dying->( \$calls ), {} ); 1 }, 'Home (page fetched): the death does not escape' ) or diag $@;
	is( $calls, 1, 'Home: called once, not again with an error item (Collections\' once-guard catches it; Discover\'s _once would stop a second call)' );
	is( $logged->(), 1, 'Home: logged at ERROR' );

	$calls = 0;
	ok( eval { $HOME_ROOT->( $CLIENT, $dying->( \$calls ), {} ); 1 }, 'Home (cached page, synchronous): the death does not escape' ) or diag $@;
	is( $calls, 1, 'Home (cached): called once' );

	fresh();
	route_collection( 103194120, 0, 'bff-collection-103194120-most-popular-podcasts-o0.json' );
	$calls = 0;
	ok( eval { $COLL_MENU->( $CLIENT, $dying->( \$calls ), {}, { id => 103194120, title => 'Most Popular Podcasts' }, 0, 1 ); 1 }, 'collection menu: the death does not escape' ) or diag $@;
	is( $calls, 1, 'collection menu: called once' );
	is( $logged->(), 1, 'collection menu: logged at ERROR' );

	fresh();
	route( "$NEXT/listen.json", code => 500, content => 'oops' );
	$calls = 0;
	ok( eval { $HOME_ROOT->( $CLIENT, $dying->( \$calls ), {} ); 1 }, 'Home error path: the death does not escape' ) or diag $@;
	is( $calls, 1, 'Home error path: called once (the error item)' );
};

done_testing();
