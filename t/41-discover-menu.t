#!/usr/bin/perl
# Plugins::ABCListen::Discover (top-level "Home", D1) and the collection menus of
# Plugins::ABCListen::Collections, offline (SimpleAsyncHTTP stub fails any unrouted URL; fake
# clock): the Home item (exact keys, weight, menuWeights, no network) and its place at the top;
# Home's root (Featured, then the home collections in page order; Featured omitted without a
# mappable hero item); collection menus (20 per page + More… with the right offsets, last page
# without More…, missing total, empty / null / past-the-end pages, API errors, the depth limit);
# Categories -> True Crime (dynamiccollection leaf ids); Radio Stations with and without L1's live
# API; the keys the menu:1 (Jive) rendering relies on; readable names everywhere; exactly one
# callback on every path.
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
my $COLL_MENU   = \&Plugins::ABCListen::Collections::_collectionMenu;
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE        = string('PLUGIN_ABCLISTEN_MORE');
my $FEATURED    = string('PLUGIN_ABCLISTEN_FEATURED');

my @HOME_TITLES = (
	"Today's Top Picks", 'Top 100 Australian Books', 'Radio Stations', 'Latest News', 'Most Popular Podcasts',
	'True Crime & Investigations', 'Health & Wellbeing', 'Society & Culture', 'Music For Every Mood',
	'Looking For Something New?', 'Relax & Sleep', 'Categories',
);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# L1 stubs (contract 7): the test's own station table
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
	%SLUGS = ( sport => 'SPORT', radionational => 'RN', triplej => 'TRIPLEJ', classic => 'CLASSIC' );
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

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

subtest 'menuItems: one "Home" link, weight 10, no network; menuWeights' => sub {
	fresh();
	my $c = collector();
	$DISCOVER->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'one callback' );
	is_deeply(
		[ $c->args(0) ],
		[ [ { name => 'Home', type => 'link', url => $HOME_ROOT, image => $ICON, weight => 10 } ] ],
		'exact keys: name "Home", type link, url _homeRoot, plugin icon, weight'
	);
	is( ( $c->args(0) )[0]->[0]->{name}, string('PLUGIN_ABCLISTEN_HOME'), 'name from PLUGIN_ABCLISTEN_HOME' );
	is( ( $c->args(0) )[0]->[0]->{weight}, Plugins::ABCListen::Util::topWeight('home'), 'weight = Util::topWeight("home")' );
	is_deeply( [ $DISCOVER->menuWeights ], [ Plugins::ABCListen::Util::topWeight('home') ], 'menuWeights = (topWeight("home"))' );
	is( scalar requests(), 0, 'no HTTP request' );
	ok( eval { $DISCOVER->init; 1 }, 'init is harmless' );

	$c = collector();
	$DISCOVER->menuItems( $CLIENT, $c->cb, {} );
	is( ( $c->args(0) )[0]->[0]->{name}, 'Home', 'with a client too' );
};

subtest 'top level: Home is first (weight 10)' => sub {
	fresh();
	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( undef, $c->cb, { params => {} } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is( $items->[0]->{name}, 'Home', 'Home first' );
	is_deeply( names($items), [ 'Home', 'Radio', 'Programs', 'Search', 'My ABC listen' ], 'Home, Radio, Programs, Search (D3), My ABC listen (M2)' );
	ok( !exists $items->[0]->{weight}, 'weight removed by Plugin.pm' );
	is( scalar requests(), 0, 'no HTTP request for the top level' );
};

subtest 'Home root: Featured, then the home collections in page order' => sub {
	fresh();
	route_home();
	my $items = home_root();

	is_deeply( names($items), [ $FEATURED, @HOME_TITLES ], 'Featured, then every home StandardCollection in page order without "Explore Video Podcasts"' );

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
	ok( !( grep { exists $_->{description} } @$items, @{ $featured->{items} } ), 'no description on any browse item (LMS menu rule 1)' );
	check_names( $items, 'Home' );
	check_names( $featured->{items}, 'Featured' );
	is( scalar warnings_from_collections(), 0, 'no WARN or ERROR' );
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
	is_deeply( names($items), [$FEATURED], 'no Featured entry: the only item is the untitled collection, named "Featured" rather than blank' );
	is( $items->[0]->{url}, $COLL_MENU, '(it is the collection link)' );
	is( $items->[0]->{image}, $ICON, 'no card image: the plugin icon' );

	fresh();
	route_json( "$NEXT/listen.json", { pageProps => { data => { componentsContent => [ { component => 'AppStoreCTA', componentProps => {} } ] } } } );
	is_deeply( home_root(), [ { name => $EMPTY, type => 'text' } ], 'nothing to list: one "Nothing here right now" text item, never an empty list' );
};

subtest 'Home root: page errors; last-good copy' => sub {
	fresh();
	route( "$NEXT/listen.json", code => 500, content => 'down' );
	is_deeply( home_root(), [ { name => $LOAD_FAILED, type => 'text' } ], 'ABC down, nothing cached: one LOAD_FAILED text item' );

	fresh();
	route( "$NEXT/listen.json", code => 429, content => 'slow' );
	is_deeply( home_root(), [ { name => string('PLUGIN_ABCLISTEN_RATE_LIMITED'), type => 'text' } ], 'the API token\'s text (RATE_LIMITED)' );

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

subtest 'Categories -> True Crime: program links (dynamiccollection leaf id)' => sub {
	fresh();
	route_home();
	route_collection( 14123152,  0, 'bff-collection-14123152-categories.trimmed.json' );
	route_collection( 104142226, 0, 'bff-collection-104142226-true-crime-category.trimmed.json' );

	my ($categories) = grep { $_->{name} eq 'Categories' } @{ home_root() };
	my $list = items_of( open_item($categories) );
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

done_testing();
