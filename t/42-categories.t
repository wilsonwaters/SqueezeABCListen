#!/usr/bin/perl
# The top-level Podcasts menu (D2): Plugins::ABCListen::Collections->podcasts / staticCategories /
# withImages / items(..., \%extraQuery) / the collection menu's category fallback, and
# Plugins::ABCListen::Discover::_podcastsRoot, offline (SimpleAsyncHTTP stub fails any unrouted
# URL; fake clock): the podcasts page -> 3 sub-collections + 8 categories (leaf ids, names,
# images); the static category list when the page fails or lists none; the menu order (New &
# Noteworthy, Most Popular Podcasts, Award Winning Podcasts, Browse by category, All podcasts
# A–Z) with and without programsByType (a stub), and with O3's own; sub-collection requests with rootMetaCollectionId
# and metaInMeta; artwork from each sub-collection's first page (3 s deadline, shared cache);
# Browse by category -> True Crime paging (offsets, More…) -> O2's program menu; the category
# page fallback when a category id gives nothing; items() unchanged without the extra hash;
# readable names, icons, text items for empty/failure states; exactly one callback everywhere.
#
# Fixtures (t/data/discovery/, recorded 2026-10-19 by D2; lists trimmed, shape unedited):
#   nextdata-listen-podcasts.json               GET /_next/data/build-3afcd04f/listen/podcasts.json
#                                               (pageProps.data only; all 3 sub-collections, all 8 categories)
#   bff-collection-podcasts-new-noteworthy.json GET /core-next/api/collection/x?collectionId=105492374
#                                               &metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20 (3 of 7)
#   bff-collection-category-true-crime.json     GET /core-next/api/collection/x?collectionId=104142226&offset=0&size=20 (4 of 22)
#   nextdata-category-true-crime.json           GET /_next/data/build-3afcd04f/listen/listenapp/true-crime/104142226.json
#                                               (pageProps.data only; 3 of 16 cards)
# plus t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f) and O3's
# t/data/ondemand/algolia-programs-list.json (the program index behind programsByType).

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
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $COL         = 'Plugins::ABCListen::Collections';
my $SITE        = 'https://www.abc.net.au';
my $BFF_COLL    = "$SITE/core-next/api/collection/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $T0          = 1_792_400_000;
my $ICON        = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $CLIENT      = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $PODCASTS    = \&Plugins::ABCListen::Discover::_podcastsRoot;
my $PODCASTS_AZ = \&Plugins::ABCListen::Discover::_podcastsAZ;
my $COLL_MENU   = \&Plugins::ABCListen::Collections::_collectionMenu;
my $PROGRAM     = \&Plugins::ABCListen::OnDemand::_programMenu;
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE        = string('PLUGIN_ABCLISTEN_MORE');
my $BROWSE      = string('PLUGIN_ABCLISTEN_CATEGORIES');
my $AZ          = string('PLUGIN_ABCLISTEN_PODCASTS_AZ');
my $META_QUERY  = { rootMetaCollectionId => '106118844', metaInMeta => 'false' };

my @SUB_COLLECTIONS = ( [ 105492374 => 'New & Noteworthy' ], [ 103470928 => 'Most Popular Podcasts' ], [ 11511926 => 'Award Winning Podcasts' ] );

# the 8 category cards on the podcasts page (2026-10-19): [ page id, cardTitle, articleLink ]
my @CATEGORIES = (
	[ 104142082 => 'News & Analysis',              '/listen/listenapp/news-and-analysis/104142082' ],
	[ 104142226 => 'True Crime',                   '/listen/listenapp/true-crime/104142226' ],
	[ 104142200 => 'Sport',                        '/listen/listenapp/sport/104142200' ],
	[ 104141842 => 'For Kids & Families',          '/listen/listenapp/kids-and-families/104141842' ],
	[ 104141924 => 'History',                      '/listen/listenapp/history/104141924' ],
	[ 104142164 => 'Society & Culture',            '/listen/listenapp/society-and-culture/104142164' ],
	[ 104142058 => 'Music',                        '/listen/listenapp/music/104142058' ],
	[ 104141814 => 'Conversations & Storytelling', '/listen/listenapp/conversations-storytelling/104141814' ],
);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture( $_[0] ) ) }

sub route_json {
	my ( $match, $data, %opt ) = @_;
	route( $match, code => 200, headers => $JSON_TYPE, content => to_json($data), %opt );
}

sub route_podcasts { route( "$NEXT/listen/podcasts.json", file => 'discovery/nextdata-listen-podcasts.json', headers => $JSON_TYPE ) }

sub sub_url { my ( $id, $offset ) = @_; return "$BFF_COLL?collectionId=$id&metaInMeta=false&offset=" . ( $offset || 0 ) . "&rootMetaCollectionId=106118844&size=20" }

# New & Noteworthy from its fixture, Most Popular Podcasts with one synthetic card, Award Winning unrouted
sub route_sub_collections {
	route( sub_url(105492374), file => 'discovery/bff-collection-podcasts-new-noteworthy.json', headers => $JSON_TYPE );
	route_json( sub_url(103470928), { collection => { title => 'Most Popular Podcasts', pagination => { total => 1 }, items => [ program_card( 1, 'https://img.test/popular.jpg' ) ] } } );
}

sub program_card {
	my ( $id, $image ) = @_;
	return { contentUri => "coremedia://program/$id", cardId => "$id", cardTitle => "Program $id", articleLink => "/listen/programs/program-$id/", $image ? ( cardImagePrepared => { imgSrc => $image } ) : () };
}

sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item {
	my ( $item, $client ) = @_;
	return feed( $item->{url}, $client || $CLIENT, @{ $item->{passthrough} || [] } );
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : $result;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && !ref $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty text name" );
}

# Podcasts menu (with or without O3's programsByType); returns the items after the 3 s image deadline at most
sub podcasts_root {
	my $c = feed( $PODCASTS, $CLIENT );
	advanceTime(3) unless $c->count;
	is( $c->count, 1, 'Podcasts: one callback' );
	return items_of($c);
}

sub run {
	my ( $fn, @args ) = @_;
	my $c = collector();
	$COL->$fn( @args, $c->cb );
	return $c;
}

sub urls { map { $_->{url} } requests() }

sub collection_requests { grep {m{/collection/x}} urls() }

sub warnings_logged { grep { $_->{level} =~ /WARN|ERROR/ && $_->{message} !~ /nextData \/listen\/programs\// } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# O3's programsByType: absent, or a recording stub
my @AZ_CALLS;
sub with_az {
	my $code = shift;
	no warnings qw(redefine once);
	local *Plugins::ABCListen::OnDemand::programsByType = sub {
		my ( $class, $client, $cb, $type ) = @_;
		push @AZ_CALLS, [ $class, $client, $type ];
		$cb->( [ { name => 'A Very British Cult', type => 'link', url => $PROGRAM, passthrough => [ { path => '/listen/programs/a-very-british-cult' } ] } ] );
	};
	return $code->();
}

sub without_az {
	my $code = shift;
	no warnings 'once';
	local *Plugins::ABCListen::OnDemand::programsByType;
	return $code->();
}

# ---------------------------------------------------------------------------
# podcasts() / staticCategories()
# ---------------------------------------------------------------------------

subtest 'podcasts(): the podcasts page -> 3 sub-collections and 8 categories (leaf ids, names, images)' => sub {
	fresh();
	route_podcasts();

	my $c = run('podcasts');
	is( $c->count, 1, 'one callback' );
	my ($page) = $c->args(0);

	is_deeply(
		$page->{collections},
		[ map { { id => "$_->[0]", title => $_->[1], query => $META_QUERY } } @SUB_COLLECTIONS ],
		'the MetaCollection (106118844) sub-collections in page order, each with { rootMetaCollectionId => 106118844, metaInMeta => false }'
	);

	is( scalar @{ $page->{categories} }, 8, 'exactly 8 categories' );
	is_deeply(
		[ map { [ $_->{id}, $_->{title}, $_->{fallbackPath} ] } @{ $page->{categories} } ],
		[ map { [ "$_->[0]", $_->[1], $_->[2] ] } @CATEGORIES ],
		'ids = the numeric last segment of articleLink (= cardId, not the dynamiccollection contentUri id), names = cardTitle, fallbackPath = the category page'
	);
	my $cards = json_file('discovery/nextdata-listen-podcasts.json')->{pageProps}->{data}->{componentsContent}->[2]->{componentProps}->{items};
	is_deeply( [ map { $_->{image} } @{ $page->{categories} } ], [ map { Plugins::ABCListen::API::cardRef($_)->{image} } @$cards ], 'images = the category cards\' images (cardRef, 300 px)' );
	like( $page->{categories}->[1]->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/5935d43e568af74c2d506c775e920578\?.*width=300}, 'True Crime: its tile artwork' );
	is( $page->{stale}, 0, 'not stale' );
	is_deeply( [ grep {m{/_next/data/}} urls() ], ["$NEXT/listen/podcasts.json"], 'GET /_next/data/<buildId>/listen/podcasts.json' );

	advanceTime(3599);
	run('podcasts');
	is( scalar( grep {m{/listen/podcasts\.json}} urls() ), 1, 'cached for 1 h' );
	advanceTime(2);
	run('podcasts');
	is( scalar( grep {m{/listen/podcasts\.json}} urls() ), 2, 'fetched again after 1 h' );
};

subtest 'podcasts(): skipped cards and sub-collections; missing parts are empty lists' => sub {
	fresh();
	my $category = sub {
		my ( $id, $title, $link ) = @_;
		return { contentUri => "coremedia://dynamiccollection/$id", cardTitle => $title, articleLink => $link };
	};
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [
		{ component => 'StandardCollection', key => '1', componentProps => { id => '1', title => 'Not categories', items => [ program_card(5) ] } },
		{ component => 'MetaCollection', key => '77', componentProps => { items => [
			{ id => '201', title => 'Has items', itemsCount => 4 },
			{ id => '202', title => 'Empty', itemsCount => 0 },
			{ id => 'abc', title => 'No numeric id' },
			{ id => '203', title => '  No count  ' },
			'junk',
		] } },
		{ component => 'MetaCollection', key => '88', componentProps => { rootMetaCollectionId => '88', items => [ { id => '301', title => 'Second meta' } ] } },
		{ component => 'StandardCollection', key => '2', componentProps => { id => '2', title => 'Categories', items => [
			$category->( 11, 'Good', '/listen/listenapp/good/104' ),
			$category->( 12, 'No leaf', '/listen/listenapp/no-leaf' ),
			program_card(6),
			{ contentUri => 'nope', cardTitle => 'Bad' },
			$category->( 13, 'Absolute', 'https://www.abc.net.au/listen/listenapp/absolute/105/' ),
		] } },
		{ component => 'StandardCollection', key => '3', componentProps => { id => '3', items => [ $category->( 14, 'Later', '/listen/listenapp/later/106' ) ] } },
	] } } } );

	my ($page) = run('podcasts')->args(0);
	is_deeply(
		$page->{collections},
		[ { id => '201', title => 'Has items', query => { rootMetaCollectionId => '77', metaInMeta => 'false' } }, { id => '203', title => 'No count', query => { rootMetaCollectionId => '77', metaInMeta => 'false' } } ],
		'the first MetaCollection only (id from key when rootMetaCollectionId is missing); itemsCount 0, non-numeric ids and junk left out; titles trimmed'
	);
	is_deeply(
		[ map { [ $_->{id}, $_->{title}, $_->{fallbackPath} ] } @{ $page->{categories} } ],
		[ [ '104', 'Good', '/listen/listenapp/good/104' ], [ '105', 'Absolute', '/listen/listenapp/absolute/105' ] ],
		'the first collection with dynamiccollection cards; cards without a numeric articleLink leaf, other types and bad cards skipped; absolute links made site paths'
	);
	is( $page->{categories}->[0]->{image}, undef, 'a card without an image: image undef' );

	fresh();
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [ { component => 'AppOnwardJourney' } ] } } } );
	is_deeply( ( run('podcasts')->args(0) )[0], { collections => [], categories => [], stale => 0 }, 'neither part on the page: two empty lists (the menu decides)' );

	fresh();
	route_json( "$NEXT/listen/podcasts.json", { pageProps => {} } );
	is_deeply( ( run('podcasts')->args(0) )[0], { collections => [], categories => [], stale => 0 }, 'no data at all: empty lists, not an error' );
};

subtest 'podcasts(): errors; the last-good page is served stale' => sub {
	fresh();
	route( "$NEXT/listen/podcasts.json", code => 500, content => 'down' );
	my $c = run('podcasts');
	is_deeply( [ $c->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ] ], 'HTTP error, nothing cached: { error => LOAD_FAILED }, once' );

	fresh();
	route( "$NEXT/listen/podcasts.json", code => 429, content => 'slow' );
	is_deeply( [ run('podcasts')->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' } ] ], '429: RATE_LIMITED' );

	fresh();
	route_podcasts();
	run('podcasts');
	advanceTime(3601);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( "$NEXT/listen/podcasts.json", code => 500, content => 'down' );
	my ($page) = run('podcasts')->args(0);
	is( $page->{stale}, 1, 'ABC down after the hour: the last-good page, stale => 1' );
	is( scalar @{ $page->{categories} }, 8, '(with its 8 categories)' );
};

subtest 'staticCategories(): the 8 podcast categories (fallback list)' => sub {
	my @static = $COL->staticCategories;
	is_deeply(
		[ map { [ $_->{id}, $_->{title} ] } @static ],
		[
			[ 104142082, 'News & Analysis' ], [ 104142226, 'True Crime' ], [ 104142200, 'Sport' ], [ 104141842, 'Kids & Families' ],
			[ 104141924, 'History' ], [ 104142164, 'Society & Culture' ], [ 104142058, 'Music' ], [ 104141814, 'Conversations & Storytelling' ],
		],
		'names and page ids in ABC\'s order'
	);
	like( $_->{fallbackPath}, qr{\A/listen/listenapp/[a-z-]+/$_->{id}\z}, "$_->{title}: fallbackPath /listen/listenapp/<slug>/<id>" ) for @static;
	is( $static[1]->{fallbackPath}, '/listen/listenapp/true-crime/104142226', 'True Crime\'s page' );
	ok( !( grep { defined $_->{image} } @static ), 'no images (the menu shows the plugin icon)' );
};

# ---------------------------------------------------------------------------
# The Podcasts menu
# ---------------------------------------------------------------------------

subtest 'Podcasts: New & Noteworthy, Most Popular Podcasts, Award Winning Podcasts, Browse by category, All podcasts A–Z' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();

	my $items = with_az( sub { podcasts_root() } );
	is_deeply( names($items), [ 'New & Noteworthy', 'Most Popular Podcasts', 'Award Winning Podcasts', 'Browse by category', 'All podcasts A–Z' ], 'in this order' );

	my $nn = $items->[0];
	is_deeply(
		$nn,
		{
			name        => 'New & Noteworthy',
			type        => 'link',
			url         => $COLL_MENU,
			passthrough => [ { id => '105492374', title => 'New & Noteworthy', query => $META_QUERY, image => $nn->{image} }, 0, 1 ],
			image       => $nn->{image},
		},
		'a sub-collection: collectionItem link (passthrough [collection with its MetaCollection query, offset 0, level 1])'
	);
	my $first = Plugins::ABCListen::API::cardRef( json_file('discovery/bff-collection-podcasts-new-noteworthy.json')->{collection}->{items}->[0] );
	is( $nn->{image}, $first->{image}, 'New & Noteworthy shows its first card\'s artwork' );
	like( $nn->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/.*width=300}, '(a 300 px ABC image)' );
	is( $items->[1]->{image}, 'https://img.test/popular.jpg', 'Most Popular Podcasts: its first card\'s artwork' );
	is( $items->[2]->{image}, $ICON, 'Award Winning Podcasts: its first page failed, so the plugin icon' );

	my $browse = $items->[3];
	is( $browse->{name}, $BROWSE, 'Browse by category: PLUGIN_ABCLISTEN_CATEGORIES' );
	is( $browse->{type}, 'link', 'a link' );
	is_deeply( names( $browse->{items} ), [ map { $_->[1] } @CATEGORIES ], 'with the 8 categories inline, named as ABC\'s category cards' );
	is( $browse->{image}, $browse->{items}->[0]->{image}, 'it shows the first category\'s artwork' );
	is_deeply(
		$browse->{items}->[1],
		{
			name        => 'True Crime',
			type        => 'link',
			url         => $COLL_MENU,
			passthrough => [ { id => '104142226', title => 'True Crime', image => $browse->{items}->[1]->{image}, fallbackPath => '/listen/listenapp/true-crime/104142226' }, 0, 2 ],
			image       => $browse->{items}->[1]->{image},
		},
		'a category: collectionItem link to its page id, with its page as fallbackPath (level 2)'
	);
	ok( !( grep { $_ eq $ICON } map { $_->{image} } @{ $browse->{items} } ), 'every category has its tile artwork' );

	is_deeply( $items->[4], { name => $AZ, type => 'link', url => $PODCASTS_AZ, image => $ICON }, 'All podcasts A–Z: exact keys' );
	is( $AZ, 'All podcasts A–Z', '(PLUGIN_ABCLISTEN_PODCASTS_AZ text)' );

	is_deeply(
		[ urls() ],
		[ "$SITE/listen/search", "$NEXT/listen/podcasts.json", map { sub_url( $_->[0] ) } @SUB_COLLECTIONS ],
		'requests: the podcasts page, then each sub-collection\'s first page (for artwork); nothing for the categories'
	);
	check_names( [ @$items, @{ $browse->{items} } ], 'Podcasts' );
	ok( !( grep { exists $_->{description} } @$items, @{ $browse->{items} } ), 'no description on any browse item (LMS menu rule 1)' );
	is_deeply( [ map { $_->{message} =~ /collectionId=11511926/ ? 'the failed request' : $_->{message} } warnings_logged() ], ['the failed request'], 'no WARN or ERROR beyond API.pm logging the failed Award Winning request' );
};

subtest 'Podcasts: All podcasts A–Z only while OnDemand can programsByType (O3); it lists programsByType(..., "podcast")' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	my $items = without_az( sub { podcasts_root() } );
	is_deeply( names($items), [ 'New & Noteworthy', 'Most Popular Podcasts', 'Award Winning Podcasts', 'Browse by category' ], 'O3 not merged (no programsByType): no A–Z entry' );

	fresh();
	route_podcasts();
	route_sub_collections();
	@AZ_CALLS = ();
	with_az( sub {
		$items = podcasts_root();
		is( $items->[-1]->{name}, 'All podcasts A–Z', 'with programsByType: the A–Z entry is last' );

		my $c = open_item( $items->[-1] );
		is( $c->count, 1, 'A–Z: one callback' );
		is_deeply( names( items_of($c) ), ['A Very British Cult'], 'answers programsByType\'s items' );
		is_deeply( \@AZ_CALLS, [ [ 'Plugins::ABCListen::OnDemand', $CLIENT, 'podcast' ] ], 'called once as OnDemand->programsByType($client, $cb, "podcast")' );

		$c = feed( $PODCASTS_AZ, undef );
		is( $AZ_CALLS[-1]->[1], undef, 'without a client: $client undef' );
	} );

	fresh();
	{
		no warnings qw(redefine once);
		local *Plugins::ABCListen::OnDemand::programsByType = sub { die "index broke\n" };
		my $c = feed( $PODCASTS_AZ, $CLIENT );
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'programsByType dying: one LOAD_FAILED text item' );
	}
};

subtest 'All podcasts A–Z with O3\'s own programsByType: the rows By type -> Podcasts shows' => sub {
	plan skip_all => 'OnDemand->programsByType (O3) is not there' unless Plugins::ABCListen::OnDemand->can('programsByType');

	fresh();
	Plugins::ABCListen::ProgramIndex::_reset() if Plugins::ABCListen::ProgramIndex->can('_reset');
	route( 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query', file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );
	route_podcasts();
	route_sub_collections();

	my $items = podcasts_root();
	is( $items->[-1]->{name}, 'All podcasts A–Z', 'O3 merged: the A–Z entry is listed, last' );

	my $c = open_item( $items->[-1] );
	is( $c->count, 1, 'one callback' );
	my $direct = collector();
	Plugins::ABCListen::OnDemand->programsByType( $CLIENT, $direct->cb, 'podcast' );
	is_deeply( items_of($c), ( $direct->args(0) )[0], 'exactly programsByType($client, $cb, "podcast")\'s rows (Algolia fixture, cached after the first call)' );
	cmp_ok( scalar @{ items_of($c) }, '>=', 1, '>= 1 podcast' );
	ok( !( grep { !$_->{url} || $_->{url} != $PROGRAM } @{ items_of($c) } ), 'each opens O2\'s program -> episodes menu' );
	check_names( items_of($c), 'All podcasts A–Z' );
};

subtest 'Podcasts: the page fails -> LOAD_FAILED, the static categories, A–Z; missing parts' => sub {
	fresh();
	route( "$NEXT/listen/podcasts.json", code => 500, content => 'down' );
	my $items = with_az( sub { podcasts_root() } );
	is_deeply( names($items), [ $LOAD_FAILED, 'Browse by category', 'All podcasts A–Z' ], 'ABC down, nothing cached: LOAD_FAILED in place of the collections, then Browse by category and A–Z' );
	is_deeply( $items->[0], { name => $LOAD_FAILED, type => 'text' }, '(a text item)' );
	is_deeply( names( $items->[1]->{items} ), [ map { $_->{title} } $COL->staticCategories ], 'Browse by category: the static list' );
	is_deeply( [ map { $_->{image} } $items->[1], @{ $items->[1]->{items} } ], [ ($ICON) x 9 ], 'no artwork: the plugin icon on the entry and each category' );
	is( $items->[1]->{items}->[1]->{passthrough}->[0]->{fallbackPath}, '/listen/listenapp/true-crime/104142226', 'static categories keep their page as fallbackPath' );
	is_deeply( [ collection_requests() ], [], 'no collection requests' );

	fresh();
	route( "$NEXT/listen/podcasts.json", code => 429, content => 'slow' );
	is( without_az( sub { podcasts_root() } )->[0]->{name}, string('PLUGIN_ABCLISTEN_RATE_LIMITED'), 'the API token\'s text (RATE_LIMITED)' );

	fresh();
	my $data = json_file('discovery/nextdata-listen-podcasts.json');
	my @components = @{ $data->{pageProps}->{data}->{componentsContent} };
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [ grep { $_->{component} ne 'MetaCollection' } @components ] } } } );
	$items = without_az( sub { podcasts_root() } );
	is_deeply( names($items), [ $LOAD_FAILED, 'Browse by category' ], 'MetaCollection missing: LOAD_FAILED, then the page\'s categories' );
	is( $items->[1]->{items}->[3]->{name}, 'For Kids & Families', '(the live names: "For Kids & Families")' );

	fresh();
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [ grep { $_->{component} ne 'StandardCollection' } @components ] } } } );
	route_sub_collections();
	$items = without_az( sub { podcasts_root() } );
	is_deeply( names($items), [ ( map { $_->[1] } @SUB_COLLECTIONS ), 'Browse by category' ], 'Categories collection missing: the sub-collections, then Browse by category ...' );
	is( $items->[3]->{items}->[3]->{name}, 'Kids & Families', '... with the static list ("Kids & Families")' );

	fresh();
	route_podcasts();
	route_sub_collections();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::podcasts = sub { die "engine broke\n" };
		is_deeply( without_az( sub { podcasts_root() } ), [ { name => $LOAD_FAILED, type => 'text' } ], 'podcasts() dying: one LOAD_FAILED item, once' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::withImages = sub { die "images broke\n" };
		is_deeply( without_az( sub { podcasts_root() } ), [ { name => $LOAD_FAILED, type => 'text' } ], 'withImages dying: one LOAD_FAILED item, once' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::collectionItem = sub { die "link broke\n" };
		is_deeply( without_az( sub { podcasts_root() } ), [ { name => $LOAD_FAILED, type => 'text' } ], 'building the items dying: one LOAD_FAILED item, once' );
	}
};

subtest 'Podcasts sub-collections: requests carry rootMetaCollectionId=106118844 and metaInMeta=false; opening uses the cached first page' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	my $items = without_az( sub { podcasts_root() } );

	is_deeply(
		[ collection_requests() ],
		[
			"$BFF_COLL?collectionId=105492374&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
			"$BFF_COLL?collectionId=103470928&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
			"$BFF_COLL?collectionId=11511926&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
		],
		'the recorded URLs carry rootMetaCollectionId=106118844 and metaInMeta=false'
	);

	my $c = open_item( $items->[0] );
	advanceTime(3);
	my $nn = items_of($c);
	is( $c->count, 1, 'New & Noteworthy: one callback' );
	cmp_ok( scalar( grep { $_->{url} && $_->{url} == $PROGRAM } @$nn ), '>=', 1, 'New & Noteworthy: >= 1 program item (O2\'s program menu)' );
	is_deeply( [ map { $_->{passthrough}->[0]->{path} } @$nn[ 0 .. 2 ] ], [ '/listen/programs/planet-america-page', '/listen/programs/abc-rewind', '/listen/programs/the-walkers-the-real-salt-path' ], 'each opens its program page' );
	is( scalar( collection_requests() ), 3, 'opening it made no new collection request (the artwork lookup cached its first page)' );
	is( $nn->[-1]->{name}, $MORE, 'More… (ABC reports 7, the fixture holds 3)' );
	is_deeply( $nn->[-1]->{passthrough}, [ { id => '105492374', title => 'New & Noteworthy', query => $META_QUERY, image => $items->[0]->{image} }, 3, 1 ], 'More… keeps the query, next offset 3' );

	route_json( sub_url( 105492374, 3 ), { collection => { pagination => { total => 7 }, items => [ program_card(9) ] } } );
	open_item( $nn->[-1] );
	advanceTime(3);
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=105492374&metaInMeta=false&offset=3&rootMetaCollectionId=106118844&size=20", 'More…: offset 3 with the same query' );
	check_names( $nn, 'New & Noteworthy' );
};

subtest 'withImages: first supported card\'s image; the 3 s deadline; errors; one callback' => sub {
	fresh();
	route_json( qr{collectionId=1&}, { collection => { items => [ { contentUri => 'coremedia://video/9', cardImagePrepared => { imgSrc => 'https://img.test/video.jpg' } }, program_card( 2, 'https://img.test/two.jpg' ) ] } } );
	route_json( qr{collectionId=3&}, { collection => { items => [ program_card(4) ] } } );
	my $c = collector();
	$COL->withImages( [ { id => 1 }, { id => 3 }, { id => 5, image => 'https://img.test/own.jpg' }, { id => 'x' }, 'junk' ], $c->cb );
	is( $c->count, 1, 'answered at once when every first page answers at once' );
	is_deeply(
		( $c->args(0) )[0],
		[ { id => 1, image => 'https://img.test/two.jpg' }, { id => 3 }, { id => 5, image => 'https://img.test/own.jpg' }, { id => 'x' } ],
		'the first supported card\'s image (the video card is skipped); no image card: none; an own image kept, no request; non-numeric ids untouched; junk dropped'
	);
	is_deeply( [ collection_requests() ], [ "$BFF_COLL?collectionId=1&offset=0&size=20", "$BFF_COLL?collectionId=3&offset=0&size=20" ], 'one first-page request each (no query: none added)' );

	fresh();
	route_json( qr{collectionId=1&}, { collection => { items => [ program_card( 2, 'https://img.test/late.jpg' ) ] } }, defer => 1 );
	route( qr{collectionId=3&}, code => 500, content => 'down' );
	$c = collector();
	$COL->withImages( [ { id => 1 }, { id => 3 } ], $c->cb );
	is( $c->count, 0, 'waiting for the slow first page' );
	advanceTime(2.9);
	is( $c->count, 0, 'still waiting at 2.9 s' );
	advanceTime(0.2);
	is( $c->count, 1, 'answered at the 3 s deadline' );
	is_deeply( ( $c->args(0) )[0], [ { id => 1 }, { id => 3 } ], 'slow and failed lookups: no image' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late answer does not call back again' );
	is_deeply( ( $c->args(0) )[0], [ { id => 1 }, { id => 3 } ], 'nor change what was answered' );

	fresh();
	$c = collector();
	$COL->withImages( [], $c->cb );
	is_deeply( [ $c->calls ], [ [ [] ] ], 'nothing to look up: [] at once' );
	$c = collector();
	$COL->withImages( undef, $c->cb );
	is_deeply( [ $c->calls ], [ [ [] ] ], 'undef: [] at once' );
	is( scalar requests(), 0, 'no request' );

	fresh();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::items = sub { die "items broke\n" };
		$c = collector();
		$COL->withImages( [ { id => 1 }, { id => 2 } ], $c->cb );
	}
	is_deeply( [ $c->calls ], [ [ [ { id => 1 }, { id => 2 } ] ] ], 'items() dying: no images, one callback' );
	is( scalar Slim::Utils::Timers->pending, 0, 'the deadline timer is gone' );
};

# ---------------------------------------------------------------------------
# Browse by category -> a category
# ---------------------------------------------------------------------------

subtest 'Browse by category -> True Crime: collectionId=104142226 pages 20 at a time + More… -> O2\'s program menu' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	route( "$BFF_COLL?collectionId=104142226&offset=0&size=20", file => 'discovery/bff-collection-category-true-crime.json', headers => $JSON_TYPE );

	my $browse = without_az( sub { podcasts_root() } )->[3];
	my ($trueCrime) = grep { $_->{name} eq 'True Crime' } @{ $browse->{items} };

	my $c = open_item($trueCrime);
	advanceTime(3);
	is( $c->count, 1, 'one callback' );
	my $programs = items_of($c);
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=104142226&offset=0&size=20", 'GET collection/x?collectionId=104142226&offset=0&size=20 (the category page id; no MetaCollection query)' );
	is_deeply( names($programs), [ 'The Case Of', 'Unravel', 'Uncover', 'Someone Knows Something', $MORE ], 'the program links (4 recorded of 22), then More…' );
	is_deeply( [ map { $_->{url} } @$programs[ 0 .. 3 ] ], [ ($PROGRAM) x 4 ], 'each opens O2\'s program -> episodes menu' );
	is( $programs->[0]->{passthrough}->[0]->{path}, '/listen/programs/the-case-of', 'with its program page path' );
	ok( !( grep { !$_->{image} || $_->{image} eq $ICON } @$programs[ 0 .. 3 ] ), 'every program shows its artwork' );
	is_deeply( $programs->[4]->{passthrough}, [ $trueCrime->{passthrough}->[0], 4, 2 ], 'More…: the same category, next offset 4, level 2' );

	route_json( "$BFF_COLL?collectionId=104142226&offset=4&size=20", { collection => { pagination => { total => 22 }, items => [ program_card(7), program_card(8) ] } } );
	$c = open_item( $programs->[4] );
	advanceTime(3);
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=104142226&offset=4&size=20", 'More…: offset 4' );
	is_deeply( names( items_of($c) ), [ 'Program 7', 'Program 8', $MORE ], 'the next page, More… again (6 of 22)' );
	is( items_of($c)->[-1]->{passthrough}->[1], 6, 'next offset 6' );
	ok( !( grep {m{/_next/data/.*listenapp}} urls() ), 'no category page fetched (the id pages directly)' );
	check_names( $programs, 'True Crime' );
};

subtest 'category fallback: the category id gives nothing -> its page\'s first collection' => sub {
	fresh();
	route( "$BFF_COLL?collectionId=999&offset=0&size=20", code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => [], pagination => { total => 0 } } } ) );
	route( "$NEXT/listen/listenapp/true-crime/104142226.json", file => 'discovery/nextdata-category-true-crime.json', headers => $JSON_TYPE );
	route( "$BFF_COLL?collectionId=104142226&offset=0&size=20", file => 'discovery/bff-collection-category-true-crime.json', headers => $JSON_TYPE );

	my $category = { id => '999', title => 'True Crime', fallbackPath => '/listen/listenapp/true-crime/104142226' };
	my $c = feed( $COLL_MENU, $CLIENT, $category, 0, 2 );
	advanceTime(3);
	is( $c->count, 1, 'one callback' );
	is_deeply(
		[ grep { !m{/listen/programs/} } urls() ],
		[ "$BFF_COLL?collectionId=999&offset=0&size=20", "$SITE/listen/search", "$NEXT/listen/listenapp/true-crime/104142226.json", "$BFF_COLL?collectionId=104142226&offset=0&size=20" ],
		'0 cards for 999 -> nextData(the category page) -> its first StandardCollection (componentProps.id 104142226) -> collection/x for 104142226'
	);
	my $items = items_of($c);
	is_deeply( names($items), [ 'The Case Of', 'Unravel', 'Uncover', 'Someone Knows Something', $MORE ], 'its programs and More…' );
	is_deeply( $items->[-1]->{passthrough}, [ { id => '104142226', title => 'True Crime' }, 4, 2 ], 'More… pages 104142226 (no fallbackPath: no second fallback)' );

	fresh();
	route( "$BFF_COLL?collectionId=999&offset=0&size=20", code => 404, content => 'gone' );
	route( "$NEXT/listen/listenapp/true-crime/104142226.json", file => 'discovery/nextdata-category-true-crime.json', headers => $JSON_TYPE );
	route( "$BFF_COLL?collectionId=104142226&offset=0&size=20", file => 'discovery/bff-collection-category-true-crime.json', headers => $JSON_TYPE );
	$c = feed( $COLL_MENU, $CLIENT, $category, 0, 2 );
	advanceTime(3);
	is_deeply( names( items_of($c) )->[0], 'The Case Of', 'a static id that 404s: the same fallback' );
	is( $c->count, 1, 'one callback' );

	fresh();
	route_json( "$BFF_COLL?collectionId=999&offset=0&size=20", { collection => { items => [] } } );
	route_json( "$NEXT/listen/listenapp/true-crime/104142226.json", { pageProps => { data => { componentsContent => [ { component => 'StandardCollection', key => 'x', componentProps => { id => '104142226', items => [ program_card(1) ] } } ] } } } );
	route_json( "$BFF_COLL?collectionId=104142226&offset=0&size=20", { collection => { items => [] } } );
	$c = feed( $COLL_MENU, $CLIENT, $category, 0, 2 );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'still empty after the fallback: "Nothing here right now"' );
	is( $c->count, 1, 'one callback' );
};

subtest 'category fallback: not taken for the same id, a failing page, offset > 0 or collections without fallbackPath' => sub {
	my $category = { id => '104142226', title => 'True Crime', fallbackPath => '/listen/listenapp/true-crime/104142226' };

	fresh();
	route_json( "$BFF_COLL?collectionId=104142226&offset=0&size=20", { collection => { items => [] } } );
	route( "$NEXT/listen/listenapp/true-crime/104142226.json", file => 'discovery/nextdata-category-true-crime.json', headers => $JSON_TYPE );
	my $c = feed( $COLL_MENU, $CLIENT, $category, 0, 2 );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'the page\'s collection is the same id: no second request, "Nothing here right now"' );
	is( scalar( collection_requests() ), 1, '(one collection request)' );

	fresh();
	route( "$BFF_COLL?collectionId=104142226&offset=0&size=20", code => 500, content => 'down' );
	route( "$NEXT/listen/listenapp/true-crime/104142226.json", code => 500, content => 'down' );
	$c = feed( $COLL_MENU, $CLIENT, $category, 0, 2 );
	is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'collection and page both failing: the original LOAD_FAILED, once' );

	fresh();
	route_json( "$BFF_COLL?collectionId=104142226&offset=20&size=20", { collection => { items => [] } } );
	$c = feed( $COLL_MENU, $CLIENT, $category, 20, 2 );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'offset 20: no fallback' );
	ok( !( grep {m{/_next/data/}} urls() ), 'no page request' );

	fresh();
	route_json( "$BFF_COLL?collectionId=5&offset=0&size=20", { collection => { items => [] } } );
	$c = feed( $COLL_MENU, $CLIENT, { id => 5 }, 0, 1 );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'no fallbackPath (D1 collections): unchanged' );
	ok( !( grep {m{/_next/data/}} urls() ), 'no page request' );

	fresh();
	route_json( "$BFF_COLL?collectionId=999&offset=0&size=20", { collection => { items => [] } } );
	route( "$NEXT/listen/listenapp/true-crime/104142226.json", file => 'discovery/nextdata-category-true-crime.json', headers => $JSON_TYPE );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::items = do {
			my $real = \&Plugins::ABCListen::Collections::items;
			my $n    = 0;
			sub { die "items broke\n" if $n++; goto &$real };
		};
		$c = feed( $COLL_MENU, $CLIENT, { %$category, id => '999' }, 0, 2 );
	}
	is_deeply( [ $c->calls ], [ [ { items => [ { name => $EMPTY, type => 'text' } ] } ] ], 'the fallback dying: the original result ("Nothing here right now"), once' );
};

# ---------------------------------------------------------------------------
# items() with the extra query (D1 regression)
# ---------------------------------------------------------------------------

subtest 'items(): without the extra hash the request is unchanged (D1); extras merged, never overriding' => sub {
	fresh();
	route( qr{\Q$BFF_COLL\E}, file => 'discovery/bff-collection-category-true-crime.json', headers => $JSON_TYPE );

	my $c = run( 'items', 104142226, 0, 20 );
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=104142226&offset=0&size=20", 'no extra hash: collectionId, offset, size only' );
	my ($page) = $c->args(0);
	is_deeply( [ @$page{qw(title total count)} ], [ 'True Crime & Investigations', 22, 4 ], 'result shape unchanged (title, total, count)' );

	my $c2 = collector();
	$COL->items( 105492374, 0, 20, $c2->cb, { rootMetaCollectionId => 106118844, metaInMeta => 'false' } );
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=105492374&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20", 'extras merged into the query (sorted keys)' );
	is( $c2->count, 1, 'one callback' );

	$COL->items( 7, 40, 10, sub { }, { collectionId => 1, offset => 0, size => 99, ref => [1], undef => undef } );
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=7&offset=40&size=10", 'collectionId, offset and size win; non-text values dropped' );

	$COL->items( 8, 0, 20, sub { }, 'not a hash' );
	is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=8&offset=0&size=20", 'a non-hash extra is ignored' );
};

done_testing();
