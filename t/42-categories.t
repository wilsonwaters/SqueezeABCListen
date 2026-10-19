#!/usr/bin/perl
# The top-level Podcasts menu (D2): Plugins::ABCListen::Collections->podcasts / staticCategories /
# withImages / items(..., \%extraQuery) / the collection menu's category fallback, and
# Plugins::ABCListen::Discover::_podcastsRoot, offline (SimpleAsyncHTTP stub fails any unrouted
# URL; fake clock): the podcasts page -> 3 sub-collections + 8 categories (leaf ids, names,
# images); the static category list when the page fails or lists none; the menu order (New &
# Noteworthy, Most Popular Podcasts, Award Winning Podcasts, Browse by category, All podcasts
# A–Z) with and without programsByTypeAZ (a stub); All podcasts A–Z's letter groups with O3's own
# index (D6: letter rows, counts adding up to programsByType's podcasts, each letter's rows);
# sub-collection requests with rootMetaCollectionId and metaInMeta; artwork from each
# sub-collection's first page (3 s deadline, at most 4 at a time (D6), shared cache);
# Browse by category -> True Crime paging (offsets, More…) -> O2's program menu; the category
# page fallback when a category id gives nothing; items() unchanged without the extra hash;
# readable names, icons, text items for empty/failure states; exactly one callback everywhere.
# D7: categories() - all 18 categories of ABC's categories collection (paged with a small page
# size, PAGE_TTL cache, stale copy), each fallback (collection error / partial -> the page's
# cards; page error -> the static 18), duplicate page ids, the 3 s deadline, the 10-page cap,
# exactly one callback (dying callback, dying paging); podcasts()'s categories rule and
# categoriesId; the Podcasts menu with 18 categories (Comedy, Science & Environment open their
# podcasts; a slow or failing collection never delays it past 3 s); All podcasts A–Z's Other row
# and Æ/Ø/Œ/ß letters (counts adding up).
#
# Fixtures (t/data/discovery/, recorded 2026-10-19 by D2; lists trimmed, shape unedited):
#   bff-collection-14123152-categories-full.json GET /core-next/api/collection/x?collectionId=14123152&offset=0&size=20
#                                               (D7: as served, all 18 cards; smaller pages are sliced from it)
#   nextdata-listen-podcasts.json               GET /_next/data/build-3afcd04f/listen/podcasts.json
#                                               (pageProps.data only; all 3 sub-collections, all 8 categories)
#   bff-collection-podcasts-new-noteworthy.json GET /core-next/api/collection/x?collectionId=105492374
#                                               &metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20 (3 of 7)
#   bff-collection-category-true-crime.json     GET /core-next/api/collection/x?collectionId=104142226&offset=0&size=20 (4 of 22)
#   nextdata-category-true-crime.json           GET /_next/data/build-3afcd04f/listen/listenapp/true-crime/104142226.json
#                                               (pageProps.data only; 3 of 16 cards)
# plus t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f) and O3's
# t/data/ondemand/algolia-programs-list.json (the program index behind programsByType); D6's
# letter-group tests build synthetic Algolia hit lists (hit()).

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

# D7: all 18 cards of ABC's categories collection 14123152 (2026-10-19): the 8 above, then these 10
my @ALL_CATEGORIES = (
	@CATEGORIES,
	[ 104141870 => 'Health & Wellbeing',    '/listen/listenapp/health-and-wellbeing/104141870' ],
	[ 104142140 => 'Science & Environment', '/listen/listenapp/science-and-environment/104142140' ],
	[ 104141660 => 'Arts & Pop Culture',    '/listen/listenapp/arts-pop-culture/104141660' ],
	[ 104141762 => 'Business & Technology', '/listen/listenapp/business-and-technology/104141762' ],
	[ 104141798 => 'Comedy',                '/listen/listenapp/comedy/104141798' ],
	[ 104141952 => 'Indigenous',            '/listen/listenapp/indigenous/104141952' ],
	[ 104141980 => 'Leisure & Lifestyle',   '/listen/listenapp/leisure-and-lifestyle/104141980' ],
	[ 104142014 => 'Life Improvement',      '/listen/listenapp/life-improvement/104142014' ],
	[ 104142104 => 'Parenting',             '/listen/listenapp/parenting/104142104' ],
	[ 104142128 => 'Religion & Ethics',     '/listen/listenapp/religion-and-ethics/104142128' ],
);
my $CATEGORIES_ID = '14123152';
my $FULL_FIXTURE  = 'discovery/bff-collection-14123152-categories-full.json';

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

# D7: ABC's categories collection (14123152). category_url($offset, $size): its collection/x URL.
sub category_url { my ( $offset, $size ) = @_; return "$BFF_COLL?collectionId=$CATEGORIES_ID&offset=" . ( $offset || 0 ) . '&size=' . ( $size || 20 ) }

# The whole collection at the default page size: one page (ABC serves all 18), from the fixture
sub route_categories { route( category_url(0), file => $FULL_FIXTURE, headers => $JSON_TYPE, @_ ) }

# The collection in pages of $size, as ABC pages it (offset/size/total; verified live 2026-10-19 with
# size 5): each page is the fixture's collection with that slice of its 18 cards. %opt: per offset,
# extra route options (code => 500, defer => 1, ...); routes for those offsets are added first.
sub route_category_pages {
	my ( $size, %opt ) = @_;
	my $full  = json_file($FULL_FIXTURE)->{collection};
	my @cards = @{ $full->{items} };

	my @offsets;
	for ( my $offset = 0; $offset < @cards; $offset += $size ) { push @offsets, $offset }

	for my $offset ( ( grep { $opt{$_} } @offsets ), ( grep { !$opt{$_} } @offsets ) ) {
		my $last  = $offset + $size - 1 > $#cards ? $#cards : $offset + $size - 1;
		my @slice = @cards[ $offset .. $last ];
		route_json( category_url( $offset, $size ), { collection => { %$full, pagination => { offset => $offset, size => scalar @slice, total => scalar @cards }, items => \@slice } }, %{ $opt{$offset} || {} } );
	}
	return;
}

sub category_requests { grep {/collectionId=$CATEGORIES_ID&/} urls() }

# Collections->categories(\%podcasts) through a collector
sub categories_of {
	my $podcasts = shift;
	my $c        = collector();
	$COL->categories( $podcasts, $c->cb );
	return $c;
}

# podcasts()'s result for the recorded podcasts page (8 categories, categoriesId 14123152)
sub podcasts_page {
	route_podcasts();
	my ($page) = run('podcasts')->args(0);
	return $page;
}

sub ids_titles { [ map { [ $_->{id}, $_->{title} ] } @{ $_[0] } ] }
sub expected   { [ map { [ "$_->[0]", $_->[1] ] } @_ ] }

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

# OnDemand's programsByTypeAZ (D6): absent, or a recording stub
my @AZ_CALLS;
sub with_az {
	my $code = shift;
	no warnings qw(redefine once);
	local *Plugins::ABCListen::OnDemand::programsByTypeAZ = sub {
		my ( $class, $client, $cb, $type ) = @_;
		push @AZ_CALLS, [ $class, $client, $type ];
		$cb->( [ { name => 'A Very British Cult', type => 'link', url => $PROGRAM, passthrough => [ { path => '/listen/programs/a-very-british-cult' } ] } ] );
	};
	return $code->();
}

sub without_az {
	my $code = shift;
	no warnings 'once';
	local *Plugins::ABCListen::OnDemand::programsByTypeAZ;
	return $code->();
}

# ---- D6: the program index behind All podcasts A–Z (synthetic Algolia hits) ----

my $ALGOLIA = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $LETTER  = \&Plugins::ABCListen::OnDemand::_letterFeed;
my $SERIAL  = 7000;

sub hit {
	my ( $title, $slug, $network, $type ) = @_;
	my $n = ++$SERIAL;
	return {
		objectID     => "coremedia://program/$n",
		title        => $title,
		canonicalURL => "https://www.abc.net.au/listen/programs/$slug/",
		infoSource   => $network,
		programType  => $type,
	};
}

# 8 podcasts (two titled "Breakfast", two with a leading "The", one starting with a digit) and 3
# programs of other types, which All podcasts A–Z never lists.
sub route_index {
	my @hits = (
		hit( 'The Science Show',       'scienceshow',          'ABC Radio National', 'podcast' ),
		hit( 'Sunday Extra',           'sundayextra',          'ABC Radio National', 'catch-up' ),
		hit( 'science friction',       'science-friction',     'ABC Radio National', 'podcast' ),
		hit( 'Conversations',          'conversations',        'ABC Listen',         'podcast' ),
		hit( 'Saturday Night Country', 'saturdaynightcountry', 'ABC Country',        'music' ),
		hit( 'The Case Of',            'the-case-of',          'ABC Listen',         'Podcast' ),
		hit( '7.30',                   '730',                  'ABC News Podcasts',  'podcast' ),
		hit( 'Unravel',                'unravel',              'ABC Listen',         'podcast' ),
		hit( 'Ukulele Hour',           'ukulele-hour',         'ABC Listen',         undef ),
		hit( 'Breakfast',              'breakfast-sydney',     'ABC Sydney',         'podcast' ),
		hit( 'Breakfast',              'breakfast-perth',      'ABC Perth',          'podcast' ),
	);
	route_json( $ALGOLIA, { hits => \@hits, nbHits => scalar @hits } );
}

sub algolia_requests { grep { $_ eq $ALGOLIA } urls() }

# OnDemand->$method($client, $cb, $type) through a collector
sub by_type {
	my ( $method, $type, $client ) = @_;
	my $c = collector();
	Plugins::ABCListen::OnDemand->$method( $client, $c->cb, $type );
	return $c;
}

sub paths { [ map { $_->{passthrough}->[0]->{path} } @{ $_[0] } ] }

sub text_item { { name => $_[0], type => 'text' } }

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
	is( $page->{categoriesId}, $CATEGORIES_ID, 'categoriesId (D7): the categories collection\'s id, 14123152 (its full card list is fetched by categories())' );
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
		{ component => 'StandardCollection', key => '2', componentProps => { id => '2', title => 'Mixed', items => [
			$category->( 11, 'Good', '/listen/listenapp/good/104' ),
			program_card(6),
			$category->( 15, 'Elsewhere', '/listen/listenapp/elsewhere/107' ),
		] } },
		{ component => 'StandardCollection', key => '3', componentProps => { title => 'Categories', items => [
			$category->( 11, 'Good', '/listen/listenapp/good/104' ),
			$category->( 12, 'No leaf', '/listen/listenapp/no-leaf' ),
			{ contentUri => 'nope', cardTitle => 'Bad' },
			{ contentUri => 'coremedia://article/17', cardTitle => 'An article', articleLink => '/news/17' },
			$category->( 13, 'Absolute', 'https://www.abc.net.au/listen/listenapp/absolute/105/' ),
			$category->( 16, 'Good again', '/listen/listenapp/good/104' ),
		] } },
		{ component => 'StandardCollection', key => '4', componentProps => { id => '4', items => [ $category->( 14, 'Later', '/listen/listenapp/later/106' ), $category->( 18, 'Later too', '/listen/listenapp/later-too/108' ) ] } },
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
		'D7: the first categories collection (a mixed one before it skipped); cards without a numeric articleLink leaf, other types and bad cards skipped; a repeated page id once; absolute links made site paths'
	);
	is( $page->{categoriesId}, '3', 'categoriesId: that collection\'s id, from its key when componentProps.id is missing' );
	is( $page->{categories}->[0]->{image}, undef, 'a card without an image: image undef' );

	fresh();
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [
		{ component => 'StandardCollection', componentProps => { title => 'Categories', items => [ $category->( 11, 'Good', '/listen/listenapp/good/104' ), $category->( 13, 'Absolute', '/listen/listenapp/absolute/105' ) ] } },
		{ component => 'StandardCollection', key => '4', componentProps => { id => '4', items => [ $category->( 14, 'Later', '/listen/listenapp/later/106' ), $category->( 18, 'Later too', '/listen/listenapp/later-too/108' ) ] } },
	] } } } );
	($page) = run('podcasts')->args(0);
	ok( exists $page->{categoriesId} && !defined $page->{categoriesId}, 'D7: a categories collection without any id: categoriesId undef (as page())' );
	is_deeply( [ map { $_->{id} } @{ $page->{categories} } ], [ '104', '105' ], '(its cards are still the categories; the later collection is not used)' );

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

subtest 'staticCategories(): the 18 podcast categories (D7; the last fallback)' => sub {
	my @static = $COL->staticCategories;
	is( scalar @static, 18, '18 categories' );
	is_deeply(
		[ map { [ $_->{id}, $_->{title} ] } @static ],
		[
			[ 104142082, 'News & Analysis' ], [ 104142226, 'True Crime' ], [ 104142200, 'Sport' ], [ 104141842, 'Kids & Families' ],
			[ 104141924, 'History' ], [ 104142164, 'Society & Culture' ], [ 104142058, 'Music' ], [ 104141814, 'Conversations & Storytelling' ],
			[ 104141870, 'Health & Wellbeing' ], [ 104142140, 'Science & Environment' ], [ 104141660, 'Arts & Pop Culture' ],
			[ 104141762, 'Business & Technology' ], [ 104141798, 'Comedy' ], [ 104141952, 'Indigenous' ], [ 104141980, 'Leisure & Lifestyle' ],
			[ 104142014, 'Life Improvement' ], [ 104142104, 'Parenting' ], [ 104142128, 'Religion & Ethics' ],
		],
		'names and page ids in ABC\'s order'
	);
	like( $_->{fallbackPath}, qr{\A/listen/listenapp/[a-z-]+/$_->{id}\z}, "$_->{title}: fallbackPath /listen/listenapp/<slug>/<id>" ) for @static;
	is( $static[1]->{fallbackPath}, '/listen/listenapp/true-crime/104142226', 'True Crime\'s page' );
	ok( !( grep { defined $_->{image} } @static ), 'no images (the menu shows the plugin icon)' );

	my @cards = map { Plugins::ABCListen::API::cardRef($_) } @{ json_file($FULL_FIXTURE)->{collection}->{items} };
	is_deeply( [ map { [ $_->{id}, $_->{fallbackPath} ] } @static ], [ map { [ $_->{id}, $_->{path} ] } @cards ], 'ids and pages = the live collection\'s 18 cards (fixture), in its order' );
};

# ---------------------------------------------------------------------------
# D7: categories() - every category of ABC's categories collection
# ---------------------------------------------------------------------------

subtest 'categories() (D7): the whole collection, paged to its end with a small page size (18 cards over 4 pages); PAGE_TTL cache' => sub {
	fresh();
	my $podcasts = podcasts_page();
	route_category_pages(5);
	local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 5;

	my $c = categories_of($podcasts);
	is( $c->count, 1, 'one callback' );
	my ( $list, $source ) = $c->args(0);
	is( $source, 'collection', 'source: the collection' );
	is_deeply( ids_titles($list), expected(@ALL_CATEGORIES), 'all 18 in ABC\'s order: ids = page ids (articleLink leaf), names = cardTitle' );
	is_deeply( [ map { $_->{fallbackPath} } @$list ], [ map { $_->[2] } @ALL_CATEGORIES ], 'fallbackPath = each category\'s page (site path)' );
	ok( !( grep { !$_->{image} } @$list ), 'every category has its tile image' );
	is_deeply( [ sort keys %{ $list->[0] } ], [qw(fallbackPath id image title)], 'podcasts()\'s category shape' );
	is_deeply( [ category_requests() ], [ map { category_url( $_, 5 ) } 0, 5, 10, 15 ], 'offsets 0, 5, 10, 15 with size 5, nothing past total 18' );

	$c = categories_of($podcasts);
	is( $c->count, 1, 'again: answered at once (cache hits)' );
	is_deeply( ids_titles( ( $c->args(0) )[0] ), expected(@ALL_CATEGORIES), '(the same 18)' );
	is( scalar category_requests(), 4, 'no new request' );
	advanceTime(3599);
	categories_of($podcasts);
	is( scalar category_requests(), 4, 'still cached at 59:59 (PAGE_TTL, 1 h; items()\' own TTL is 30 min)' );
	advanceTime(2);
	categories_of($podcasts);
	is( scalar category_requests(), 8, 'fetched again after 1 h' );

	fresh();
	$podcasts = podcasts_page();
	route_categories();
	local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 20;
	( $list, $source ) = categories_of($podcasts)->args(0);
	is_deeply( [ $source, scalar @$list ], [ 'collection', 18 ], 'the default page size (20): all 18 ...' );
	is_deeply( [ category_requests() ], [ category_url(0) ], '... in one request (ABC serves 18 of 18)' );
};

subtest 'categories() (D7): ABC down after the hour - the last-good collection (stale_ok)' => sub {
	fresh();
	my $podcasts = podcasts_page();
	route_categories();
	categories_of($podcasts);
	advanceTime(3601);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( category_url(0), code => 500, content => 'down' );

	my $c = categories_of($podcasts);
	is( $c->count, 1, 'one callback' );
	my ( $list, $source ) = $c->args(0);
	is_deeply( [ $source, scalar @$list ], [ 'collection', 18 ], 'the last-good copy: all 18' );
	is( scalar category_requests(), 1, '(after one failed request)' );
};

subtest 'categories() (D7): fallbacks - collection error -> the page\'s cards; podcasts page error -> the static 18' => sub {
	fresh();
	my $podcasts = podcasts_page();
	route( category_url(0), code => 500, content => 'down' );
	my $c = categories_of($podcasts);
	is( $c->count, 1, 'collection error: one callback' );
	my ( $list, $source ) = $c->args(0);
	is( $source, 'page', 'source: the podcasts page' );
	is_deeply( ids_titles($list), expected(@CATEGORIES), 'the podcasts page\'s 8 cards' );
	is_deeply( $list, $podcasts->{categories}, '(exactly podcasts()\'s categories)' );

	fresh();
	$podcasts = podcasts_page();
	route( category_url(0), code => 429, content => 'slow' );
	is( ( categories_of($podcasts)->args(0) )[1], 'page', 'rate limited (429): the page\'s cards' );

	fresh();
	$podcasts = podcasts_page();
	route_category_pages( 5, 10 => { code => 500 } );
	{
		local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 5;
		( $list, $source ) = categories_of($podcasts)->args(0);
	}
	is( $source, 'collection+page', 'page 3 fails: what the collection gave, then the page\'s cards' );
	is_deeply( ids_titles($list), expected( @ALL_CATEGORIES[ 0 .. 9 ] ), 'the 10 cards of pages 1-2, in ABC\'s order (the page\'s 8 are among them: not repeated)' );
	is_deeply( [ category_requests() ], [ map { category_url( $_, 5 ) } 0, 5, 10 ], 'no request after the failed page' );

	for my $case (
		[ 'a null collection',                  { collection => undef } ],
		[ 'no category cards (programs only)',  { collection => { pagination => { total => 2 }, items => [ program_card(1), program_card(2) ] } } ],
		[ 'an empty collection',                { collection => { pagination => { total => 0 }, items => [] } } ],
	) {
		fresh();
		$podcasts = podcasts_page();
		route_json( category_url(0), $case->[1] );
		( $list, $source ) = categories_of($podcasts)->args(0);
		is_deeply( [ $source, ids_titles($list) ], [ 'page', expected(@CATEGORIES) ], "$case->[0]: the page's 8" );
	}

	my @static = $COL->staticCategories;
	fresh();
	for my $case (
		[ 'the podcasts page failed',                   { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ],
		[ 'no categories collection on the page',       { collections => [], categories => [], stale => 0 } ],
		[ 'no podcasts result at all',                  undef ],
		[ 'an error with an id (ignored)',              { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED', categoriesId => $CATEGORIES_ID, categories => [ { id => 1, title => 'x' } ] } ],
	) {
		$c = categories_of( $case->[1] );
		is( $c->count, 1, "$case->[0]: one callback, at once" );
		( $list, $source ) = $c->args(0);
		is_deeply( [ $source, $list ], [ 'static', \@static ], "$case->[0]: the static 18" );
	}
	is( scalar requests(), 0, 'no request in any of those' );

	fresh();
	my @two = ( { id => '104141798', title => 'Comedy', image => undef, fallbackPath => '/listen/listenapp/comedy/104141798' }, { id => '104142140', title => 'Science & Environment', image => undef, fallbackPath => '/listen/listenapp/science-and-environment/104142140' } );
	( $list, $source ) = categories_of( { categories => [@two], categoriesId => undef } )->args(0);
	is_deeply( [ $source, $list ], [ 'page', \@two ], 'a categories collection without an id: the page\'s cards ...' );
	is( scalar requests(), 0, '... without a request' );

	route( category_url(0), code => 500, content => 'down' );
	( $list, $source ) = categories_of( { categories => [], categoriesId => $CATEGORIES_ID } )->args(0);
	is_deeply( [ $source, $list ], [ 'static', \@static ], 'the collection fails and the page has no cards: the static 18' );
};

subtest 'categories() (D7): each page id once (within and across pages); other cards skipped' => sub {
	fresh();
	my @cards = @{ json_file($FULL_FIXTURE)->{collection}->{items} };
	my ( $news, $crime, $sport ) = @cards[ 0 .. 2 ];
	my $again = { %$news, contentUri => 'coremedia://dynamiccollection/999', cardId => '999', cardTitle => 'News again' };
	route_json( category_url( 0, 2 ), { collection => { pagination => { total => 6 }, items => [ $news, $news ] } } );
	route_json( category_url( 2, 2 ), { collection => { pagination => { total => 6 }, items => [ program_card(5), $crime ] } } );
	route_json( category_url( 4, 2 ), { collection => { pagination => { total => 6 }, items => [ $again, $sport ] } } );
	local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 2;

	my ( $list, $source ) = categories_of( { categories => [], categoriesId => $CATEGORIES_ID } )->args(0);
	is( $source, 'collection', 'source: the collection' );
	is_deeply( ids_titles($list), [ [ '104142082', 'News & Analysis' ], [ '104142226', 'True Crime' ], [ '104142200', 'Sport' ] ], 'News & Analysis once (the first card wins, also across pages: same page id, other contentUri), the program card skipped' );
	is( scalar category_requests(), 3, 'three pages' );
};

subtest 'categories() (D7): answers at the 3 s deadline; the late pages keep paging and warm the cache' => sub {
	fresh();
	my $podcasts = podcasts_page();
	route_category_pages( 5, 0 => { defer => 1 } );
	local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 5;

	my $c = categories_of($podcasts);
	is( $c->count, 0, 'waiting for the slow first page' );
	advanceTime(2.9);
	is( $c->count, 0, 'still waiting at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered at the 3 s deadline' );
	my ( $list, $source ) = $c->args(0);
	is_deeply( [ $source, ids_titles($list) ], [ 'page', expected(@CATEGORIES) ], 'with the page\'s 8' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer left' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late page: no second callback' );
	is_deeply( [ category_requests() ], [ map { category_url( $_, 5 ) } 0, 5, 10, 15 ], 'the late page went on paging to the end (warming the cache)' );

	$c = categories_of($podcasts);
	( $list, $source ) = $c->args(0);
	is_deeply( [ $c->count, $source, scalar @$list ], [ 1, 'collection', 18 ], 'the next call: all 18, at once, from the cache' );
	is( scalar category_requests(), 4, '(no new request)' );

	fresh();
	$podcasts = podcasts_page();
	route_category_pages( 5, 5 => { defer => 1 } );
	$c = categories_of($podcasts);
	advanceTime(3);
	( $list, $source ) = $c->args(0);
	is( $source, 'collection+page', 'the second page slow: at 3 s, the first page\'s 5 ...' );
	is_deeply( ids_titles($list), expected(@CATEGORIES), '... then the page\'s other 3 (8 in ABC\'s order)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'no second callback' );
};

subtest 'categories() (D7): at most 10 pages; a missing total ends paging' => sub {
	fresh();
	my $podcasts = podcasts_page();
	my ($news) = @{ json_file($FULL_FIXTURE)->{collection}->{items} };
	route_json( qr{collectionId=$CATEGORIES_ID&offset=[0-9]+&size=1\z}, { collection => { pagination => { total => 1000 }, items => [$news] } } );
	local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 1;

	my ( $list, $source ) = categories_of($podcasts)->args(0);
	is( scalar category_requests(), 10, 'total 1000 with size 1: stops after 10 pages' );
	is_deeply( [ $source, ids_titles($list) ], [ 'collection+page', expected(@CATEGORIES) ], 'an unfinished collection: its cards, then the page\'s' );

	fresh();
	route_json( category_url( 0, 1 ), { collection => { items => [$news] } } );
	( $list, $source ) = categories_of( { categories => [], categoriesId => $CATEGORIES_ID } )->args(0);
	is_deeply( [ $source, ids_titles($list) ], [ 'collection', [ [ '104142082', 'News & Analysis' ] ] ], 'no pagination.total: one page, taken as the whole collection' );
	is( scalar category_requests(), 1, '(one request)' );
};

subtest 'categories() (D7): exactly one callback - a dying callback, dying paging; never dies' => sub {
	fresh();
	my $podcasts = podcasts_page();
	route_categories();
	Slim::Utils::Log->resetMessages;

	my $calls = 0;
	ok( eval { $COL->categories( $podcasts, sub { $calls++; die "Discover broke\n" } ); 1 }, 'a callback that dies: no die' ) or diag $@;
	is( $calls, 1, 'called once' );
	ok( ( grep { $_->{level} eq 'ERROR' && $_->{message} =~ /Discover broke/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) ), '(logged at ERROR)' );

	$calls = 0;
	ok( eval { Plugins::ABCListen::Collections::categories( undef, sub { $calls++; die "again\n" } ); 1 }, 'as a plain function, static answer, callback dies: no die' );
	is( $calls, 1, 'called once' );

	fresh();
	$podcasts = podcasts_page();
	route_category_pages( 5, 5 => { defer => 1 } );
	$calls = 0;
	{
		local $Plugins::ABCListen::Collections::CATEGORY_PAGE_SIZE = 5;
		$COL->categories( $podcasts, sub { $calls++; die "late\n" } );
	}
	advanceTime(3);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(10);
	is( $calls, 1, 'a dying callback at the deadline, then late pages: still once' );

	my $c;
	fresh();
	$podcasts = podcasts_page();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::_bffCollection = sub { die "bff broke\n" };
		$c = categories_of($podcasts);
	}
	is_deeply( [ $c->count, ( $c->args(0) )[1] ], [ 1, 'page' ], 'requesting the collection dies: the page\'s cards, once' );
	is( scalar Slim::Utils::Timers->pending, 0, '(the deadline timer is gone)' );

	fresh();
	$podcasts = podcasts_page();
	route_categories();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::_categoryList = sub { die "parse broke\n" };
		$c = categories_of($podcasts);
	}
	is_deeply( [ $c->count, ( $c->args(0) )[1] ], [ 1, 'page' ], 'reading a page of the collection dies: the page\'s cards, once' );
	advanceTime(3);
	is( $c->count, 1, '(no second callback at the deadline)' );
	is( scalar Slim::Utils::Timers->pending, 0, '(no timer left)' );
};

# ---------------------------------------------------------------------------
# The Podcasts menu
# ---------------------------------------------------------------------------

subtest 'Podcasts: New & Noteworthy, Most Popular Podcasts, Award Winning Podcasts, Browse by category, All podcasts A–Z' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	route_categories();

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
	is_deeply( names( $browse->{items} ), [ map { $_->[1] } @ALL_CATEGORIES ], 'D7: with all 18 categories of ABC\'s collection inline (not just the page\'s 8), named as ABC\'s category cards, in ABC\'s order' );
	is_deeply( [ map { $_->{passthrough}->[0]->{id} } @{ $browse->{items} } ], [ map {"$_->[0]"} @ALL_CATEGORIES ], '(their page ids)' );
	is_deeply( [ map { $_->{passthrough}->[0]->{fallbackPath} } @{ $browse->{items} } ], [ map { $_->[2] } @ALL_CATEGORIES ], '(their pages as fallbackPath)' );
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
		[ "$SITE/listen/search", "$NEXT/listen/podcasts.json", ( map { sub_url( $_->[0] ) } @SUB_COLLECTIONS ), category_url(0) ],
		'requests: the podcasts page, then each sub-collection\'s first page (for artwork) and (D7) the categories collection 14123152, one page of 20'
	);
	check_names( [ @$items, @{ $browse->{items} } ], 'Podcasts' );
	ok( !( grep { exists $_->{description} } @$items, @{ $browse->{items} } ), 'no description on any browse item (LMS menu rule 1)' );
	is_deeply( [ map { $_->{message} =~ /collectionId=11511926/ ? 'the failed request' : $_->{message} } warnings_logged() ], ['the failed request'], 'no WARN or ERROR beyond API.pm logging the failed Award Winning request' );
};

subtest 'Podcasts: All podcasts A–Z only while OnDemand can programsByTypeAZ; it lists programsByTypeAZ(..., "podcast")' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	my $items = without_az( sub { podcasts_root() } );
	is_deeply( names($items), [ 'New & Noteworthy', 'Most Popular Podcasts', 'Award Winning Podcasts', 'Browse by category' ], 'no programsByTypeAZ: no A–Z entry' );

	fresh();
	route_podcasts();
	route_sub_collections();
	@AZ_CALLS = ();
	with_az( sub {
		$items = podcasts_root();
		is( $items->[-1]->{name}, 'All podcasts A–Z', 'with programsByTypeAZ: the A–Z entry is last' );

		my $c = open_item( $items->[-1] );
		is( $c->count, 1, 'A–Z: one callback' );
		is_deeply( names( items_of($c) ), ['A Very British Cult'], 'answers programsByTypeAZ\'s items' );
		is_deeply( \@AZ_CALLS, [ [ 'Plugins::ABCListen::OnDemand', $CLIENT, 'podcast' ] ], 'called once as OnDemand->programsByTypeAZ($client, $cb, "podcast")' );

		$c = feed( $PODCASTS_AZ, undef );
		is( $AZ_CALLS[-1]->[1], undef, 'without a client: $client undef' );
	} );

	fresh();
	{
		no warnings qw(redefine once);
		local *Plugins::ABCListen::OnDemand::programsByTypeAZ = sub { die "index broke\n" };
		my $c = feed( $PODCASTS_AZ, $CLIENT );
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'programsByTypeAZ dying: one LOAD_FAILED text item' );
	}
};

subtest 'All podcasts A–Z (D6): letter rows; the counts add up to the podcasts; each letter opens its podcasts' => sub {
	fresh();
	Plugins::ABCListen::ProgramIndex::_reset();
	route_index();
	route_podcasts();
	route_sub_collections();

	my $entry = podcasts_root()->[-1];
	is( $entry->{name}, 'All podcasts A–Z', 'the A–Z entry, last' );

	my $c = open_item($entry);
	is( $c->count, 1, 'one callback' );
	my $letters = items_of($c);
	is_deeply( names($letters), [ 'B (2)', 'C (2)', 'S (2)', 'U (1)', "0\x{2013}9 (1)" ], 'letters A..Z with podcasts, then 0–9; empty letters omitted; programs of other types not counted' );
	is( ( grep { $_->{name} =~ /\A(?:[A-Z]|0\x{2013}9) \([0-9]+\)\z/ } @$letters ), scalar @$letters, 'every name matches ^([A-Z]|0–9) \(\d+\)$ (as Programs -> All programs A–Z)' );
	is_deeply( $letters->[2], { name => 'S (2)', type => 'link', url => $LETTER, passthrough => [ 's', 'podcast' ], image => $ICON }, 'letter row: exact keys (O3\'s letter feed, passthrough [letter, type])' );
	is_deeply( $letters->[-1]->{passthrough}, [ '0-9', 'podcast' ], '0–9 row passthrough' );
	ok( !( grep { exists $_->{description} } @$letters ), 'no description on the letter rows' );
	check_names( $letters, 'letters' );

	my ($podcasts) = by_type( programsByType => 'podcast', $CLIENT )->args(0);
	my $sum = 0;
	$sum += ( $_->{name} =~ /\(([0-9]+)\)\z/ )[0] for @$letters;
	is( $sum, scalar @$podcasts, 'the counts add up to the podcasts programsByType lists (8)' );
	is( $sum, 8, '(8 podcasts)' );

	my %rows  = map { $_->{passthrough}->[0] => items_of( open_item( $_, $CLIENT ) ) } @$letters;
	my %count = map { $_->{passthrough}->[0] => ( $_->{name} =~ /\(([0-9]+)\)\z/ )[0] } @$letters;
	is_deeply( names( $rows{b} ), [ 'Breakfast (ABC Perth)', 'Breakfast (ABC Sydney)' ], 'B: the two Breakfasts, named by network as in programsByType' );
	is_deeply( names( $rows{c} ), [ 'The Case Of', 'Conversations' ], 'C: a leading "The" ignored ("Podcast" counts as podcast)' );
	is_deeply( names( $rows{s} ), [ 'science friction', 'The Science Show' ], 'S: sortKey order; The Science Show under S; no catch-up or music programs' );
	is_deeply( names( $rows{u} ), ['Unravel'], 'U: Unravel (Ukulele Hour is not a podcast)' );
	is_deeply( names( $rows{'0-9'} ), ['7.30'], '0–9: 7.30' );

	for my $letter ( map { $_->{passthrough}->[0] } @$letters ) {
		my %in = map { $_ => 1 } @{ paths( $rows{$letter} ) };
		is_deeply( $rows{$letter}, [ grep { $in{ $_->{passthrough}->[0]->{path} } } @$podcasts ], "$letter: exactly programsByType's rows for those podcasts (keys, names, order)" );
		is( scalar @{ $rows{$letter} }, $count{$letter}, "$letter: as many rows as its count" );
	}
	is_deeply( [ sort map { @{ paths($_) } } values %rows ], [ sort @{ paths($podcasts) } ], 'together, the letters list every podcast once' );
	ok( !( grep { !$_->{url} || $_->{url} != $PROGRAM } map {@$_} values %rows ), 'each podcast opens O2\'s program -> episodes menu' );
	check_names( [ map {@$_} values %rows ], 'podcasts' );
	is( scalar algolia_requests(), 1, 'one Algolia request for the letters, every letter and programsByType (cached)' );

	is_deeply( names( items_of( feed( $PODCASTS_AZ, undef ) ) ), names($letters), 'without a client: the same letters' );
};

subtest 'All podcasts A–Z (D7): Æ/Ø/Œ/ß under A/O/O/S, non-Latin titles in an Other row after 0–9; the counts add up' => sub {
	fresh();
	Plugins::ABCListen::ProgramIndex::_reset();
	my @hits = (
		hit( "\x{C6}sop's Fables",                     'aesops-fables',  'ABC Kids',   'podcast' ),
		hit( 'Alpha',                                  'alpha',          'ABC Listen', 'podcast' ),
		hit( "\x{D8}resund Stories",                   'oresund',        'ABC Listen', 'podcast' ),
		hit( "\x{152}uvre",                            'oeuvre',         'ABC Listen', 'podcast' ),
		hit( "\x{DF}-Bahn",                            'sbahn',          'ABC Listen', 'podcast' ),
		hit( "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}",       'shengyin',       'ABC Listen', 'podcast' ),
		hit( "\x{300C}\x{6545}\x{4E8B}\x{300D}",       'gushi',          'ABC Listen', 'podcast' ),    # 「故事」: CJK quotes skipped
		hit( '7.30',                                   '730',            'ABC News',   'podcast' ),
		hit( "\x{41C}\x{438}\x{440}",                  'mir',            'ABC Listen', 'catch-up' ),   # not a podcast
	);
	route_json( $ALGOLIA, { hits => \@hits, nbHits => scalar @hits } );

	my $c = by_type( programsByTypeAZ => 'podcast', $CLIENT );
	is( $c->count, 1, 'one callback' );
	my ($letters) = $c->args(0);
	is_deeply( names($letters), [ 'A (2)', 'O (2)', 'S (1)', "0\x{2013}9 (1)", 'Other (2)' ], 'A..Z, then 0–9, then Other (PLUGIN_ABCLISTEN_AZ_OTHER); the catch-up program not counted' );
	is_deeply( $letters->[-1], { name => 'Other (2)', type => 'link', url => $LETTER, passthrough => [ 'other', 'podcast' ], image => $ICON }, 'Other row: exact keys (passthrough [other, podcast])' );
	is( string('PLUGIN_ABCLISTEN_AZ_OTHER'), 'Other', '(PLUGIN_ABCLISTEN_AZ_OTHER: "Other")' );

	my ($podcasts) = by_type( programsByType => 'podcast', $CLIENT )->args(0);
	my $sum = 0;
	$sum += ( $_->{name} =~ /\(([0-9]+)\)\z/ )[0] for @$letters;
	is( $sum, scalar @$podcasts, 'the counts add up to the podcasts programsByType lists' );
	is( $sum, 8, '(8 podcasts)' );

	my %rows = map { $_->{passthrough}->[0] => items_of( open_item( $_, $CLIENT ) ) } @$letters;
	is_deeply( names( $rows{a} ), [ 'Alpha', "\x{C6}sop's Fables" ], 'A: Alpha and Æsop\'s Fables (in sortKey order, unchanged)' );
	is_deeply( names( $rows{o} ), [ "\x{D8}resund Stories", "\x{152}uvre" ], 'O: Øresund Stories and Œuvre' );
	is_deeply( names( $rows{s} ), ["\x{DF}-Bahn"], 'S: ß-Bahn' );
	is_deeply( names( $rows{'0-9'} ), ['7.30'], '0–9: digits only' );
	is_deeply( [ sort @{ names( $rows{other} ) } ], [ sort "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}", "\x{300C}\x{6545}\x{4E8B}\x{300D}" ], 'Other: 声音之旅 and 「故事」' );
	for my $letter ( keys %rows ) {
		my %in = map { $_ => 1 } @{ paths( $rows{$letter} ) };
		is_deeply( $rows{$letter}, [ grep { $in{ $_->{passthrough}->[0]->{path} } } @$podcasts ], "$letter: exactly programsByType's rows (keys, names, order)" );
	}
	is_deeply( [ sort map { @{ paths($_) } } values %rows ], [ sort @{ paths($podcasts) } ], 'together, every podcast once' );
	check_names( $letters, 'letters' );

	is_deeply(
		[ sort @{ names( items_of( feed( $LETTER, undef, 'other' ) ) ) } ],
		[ sort "\x{300C}\x{6545}\x{4E8B}\x{300D}", "\x{41C}\x{438}\x{440}", "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}" ],
		'Programs -> All programs A–Z\'s Other row (no type): every non-Latin title, the catch-up one (Мир) too'
	);
};

subtest 'programsByTypeAZ (D6): empty, fallback, unknown type and index errors answer as programsByType; once; never dies' => sub {
	my $NO_PROGRAMS    = string('PLUGIN_ABCLISTEN_NO_PROGRAMS');
	my $INDEX_FALLBACK = string('PLUGIN_ABCLISTEN_INDEX_FALLBACK');

	fresh();
	Plugins::ABCListen::ProgramIndex::_reset();
	route_index();

	my $c = by_type( programsByTypeAZ => 'news' );
	is( $c->count, 1, 'no programs of the type: one callback' );
	is_deeply( ( $c->args(0) )[0], [ text_item($NO_PROGRAMS) ], 'no programs of the type: programsByType\'s NO_PROGRAMS item' );
	is_deeply( ( by_type( programsByTypeAZ => 'music' )->args(0) )[0], [ { name => 'S (1)', type => 'link', url => $LETTER, passthrough => [ 's', 'music' ], image => $ICON } ], 'another type: its own letters' );
	is_deeply( items_of( feed( $LETTER, undef, 'x', 'podcast' ) ), [ text_item($NO_PROGRAMS) ], 'a letter without podcasts (stale link): NO_PROGRAMS' );
	is_deeply( names( items_of( feed( $LETTER, undef, 's' ) ) ), [ 'Saturday Night Country', 'science friction', 'The Science Show', 'Sunday Extra' ], 'without a type: Programs -> All programs A–Z\'s letter, unchanged' );

	for my $key ( 'Podcasts', '', undef ) {
		my $label = defined $key ? "'$key'" : 'undef';
		Slim::Utils::Log->resetMessages;
		$c = by_type( programsByTypeAZ => $key );
		is( $c->count, 1, "type $label: one callback" );
		is_deeply( ( $c->args(0) )[0], [ text_item($LOAD_FAILED) ], "type $label: LOAD_FAILED" );
		ok( ( grep { $_->{level} eq 'WARN' && $_->{message} =~ /\AprogramsByTypeAZ: unknown program type/ } Slim::Utils::Log->messages ), "type $label: WARN, naming programsByTypeAZ (D7), not programsByType" );
	}
	Slim::Utils::Log->resetMessages;
	feed( $LETTER, undef, 's', 'nope' );
	ok( ( grep { $_->{level} eq 'WARN' && $_->{message} =~ /\AprogramsByTypeAZ letter: unknown program type 'nope'/ } Slim::Utils::Log->messages ), 'a letter of an unknown type: the WARN names the letter feed (D7)' );
	Slim::Utils::Log->resetMessages;
	by_type( programsByType => 'nope' );
	ok( ( grep { $_->{level} eq 'WARN' && $_->{message} =~ /\AprogramsByType: unknown program type 'nope'/ } Slim::Utils::Log->messages ), 'programsByType itself: "programsByType: ..."' );
	is_deeply( items_of( feed( $LETTER, undef, 's', 'nope' ) ), [ text_item($LOAD_FAILED) ], 'a letter of an unknown type: LOAD_FAILED' );

	my $calls = 0;
	ok( eval { Plugins::ABCListen::OnDemand->programsByTypeAZ( undef, sub { $calls++; die "D2 broke\n" }, 'podcast' ); 1 }, 'a callback that dies: no die' ) or diag $@;
	is( $calls, 1, 'a callback that dies: called once' );
	$calls = 0;
	ok( eval { $LETTER->( undef, sub { $calls++; die "LMS broke\n" }, {}, 's', 'podcast' ); 1 }, 'a letter, callback dies: no die' ) or diag $@;
	is( $calls, 1, 'a letter, callback dies: called once' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::_bucket = sub { die "bucket broke\n" };
		$c = by_type( programsByTypeAZ => 'podcast' );
		is_deeply( [ $c->calls ], [ [ [ text_item($LOAD_FAILED) ] ] ], 'building the letters dies: one LOAD_FAILED item' );
		$c = feed( $LETTER, undef, 's', 'podcast' );
		is_deeply( [ $c->calls ], [ [ [ text_item($LOAD_FAILED) ] ] ], 'building a letter dies: one LOAD_FAILED item' );
	}

	fresh();
	Plugins::ABCListen::ProgramIndex::_reset();
	route( $ALGOLIA, code => 500 );
	route( qr{/programAggregationCollection/}, code => 500 );
	is_deeply( [ by_type( programsByTypeAZ => 'podcast' )->calls ], [ [ [ text_item($LOAD_FAILED) ] ] ], 'index error: one LOAD_FAILED item' );
	is_deeply( [ feed( $LETTER, undef, 's', 'podcast' )->calls ], [ [ [ text_item($LOAD_FAILED) ] ] ], 'index error, a letter: one LOAD_FAILED item' );
	is_deeply( [ feed( $PODCASTS_AZ, $CLIENT )->calls ], [ [ [ text_item($LOAD_FAILED) ] ] ], 'index error, All podcasts A–Z: one LOAD_FAILED item' );

	fresh();
	Plugins::ABCListen::ProgramIndex::_reset();
	route( $ALGOLIA, code => 500 );
	route( qr{/programAggregationCollection/x\?collectionId=11474038&}, file => 'ondemand/bff-programAggregationCollection-rn.json', headers => $JSON_TYPE );
	route( qr{/programAggregationCollection/}, code => 500 );
	is_deeply( ( by_type( programsByTypeAZ => 'podcast' )->args(0) )[0], [ text_item($INDEX_FALLBACK) ], 'fallback mode (types unknown): programsByType\'s note only' );
	is_deeply( items_of( feed( $LETTER, undef, 's', 'podcast' ) ), [ text_item($INDEX_FALLBACK) ], 'fallback mode, a letter: the note only' );
};

subtest 'Podcasts: the page fails -> LOAD_FAILED, the static categories, A–Z; missing parts' => sub {
	fresh();
	route( "$NEXT/listen/podcasts.json", code => 500, content => 'down' );
	my $items = with_az( sub { podcasts_root() } );
	is_deeply( names($items), [ $LOAD_FAILED, 'Browse by category', 'All podcasts A–Z' ], 'ABC down, nothing cached: LOAD_FAILED in place of the collections, then Browse by category and A–Z' );
	is_deeply( $items->[0], { name => $LOAD_FAILED, type => 'text' }, '(a text item)' );
	is_deeply( names( $items->[1]->{items} ), [ map { $_->{title} } $COL->staticCategories ], 'Browse by category: the static list' );
	is_deeply( [ map { $_->{image} } $items->[1], @{ $items->[1]->{items} } ], [ ($ICON) x 19 ], 'no artwork: the plugin icon on the entry and each category' );
	is( $items->[1]->{items}->[1]->{passthrough}->[0]->{fallbackPath}, '/listen/listenapp/true-crime/104142226', 'static categories keep their page as fallbackPath' );
	is( scalar @{ $items->[1]->{items} }, 18, 'D7: all 18 static categories' );
	is_deeply( [ collection_requests() ], [], 'no collection requests (no categories collection id without the page)' );

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
	is( scalar @{ $items->[1]->{items} }, 8, '(the categories collection is not routed here: the page\'s 8)' );

	fresh();
	route_json( "$NEXT/listen/podcasts.json", { pageProps => { data => { componentsContent => [ grep { $_->{component} ne 'StandardCollection' } @components ] } } } );
	route_sub_collections();
	$items = without_az( sub { podcasts_root() } );
	is_deeply( names($items), [ ( map { $_->[1] } @SUB_COLLECTIONS ), 'Browse by category' ], 'Categories collection missing: the sub-collections, then Browse by category ...' );
	is( $items->[3]->{items}->[3]->{name}, 'Kids & Families', '... with the static list ("Kids & Families")' );
	is( scalar @{ $items->[3]->{items} }, 18, '(all 18)' );

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
	route_categories();
	my $items = without_az( sub { podcasts_root() } );

	is_deeply(
		[ collection_requests() ],
		[
			"$BFF_COLL?collectionId=105492374&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
			"$BFF_COLL?collectionId=103470928&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
			"$BFF_COLL?collectionId=11511926&metaInMeta=false&offset=0&rootMetaCollectionId=106118844&size=20",
			category_url(0),
		],
		'the recorded URLs carry rootMetaCollectionId=106118844 and metaInMeta=false (the categories collection, D7: none)'
	);

	my $c = open_item( $items->[0] );
	advanceTime(3);
	my $nn = items_of($c);
	is( $c->count, 1, 'New & Noteworthy: one callback' );
	cmp_ok( scalar( grep { $_->{url} && $_->{url} == $PROGRAM } @$nn ), '>=', 1, 'New & Noteworthy: >= 1 program item (O2\'s program menu)' );
	is_deeply( [ map { $_->{passthrough}->[0]->{path} } @$nn[ 0 .. 2 ] ], [ '/listen/programs/planet-america-page', '/listen/programs/abc-rewind', '/listen/programs/the-walkers-the-real-salt-path' ], 'each opens its program page' );
	is( scalar( collection_requests() ), 4, 'opening it made no new collection request (the artwork lookup cached its first page)' );
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

subtest 'withImages (D6): at most 4 first pages at a time; the rest start as answers come in; a plain function too' => sub {
	my $route_slow = sub {
		route_json( qr{collectionId=$_&}, { collection => { items => [ program_card( 100 + $_, "https://img.test/$_.jpg" ) ] } }, defer => 1 ) for 1 .. 6;
	};
	my @collections = map { { id => $_ } } 1 .. 6;
	my @withImages  = map { { id => $_, image => "https://img.test/$_.jpg" } } 1 .. 6;

	fresh();
	$route_slow->();
	my $c = collector();
	$COL->withImages( [@collections], $c->cb );
	is_deeply( [ collection_requests() ], [ map {"$BFF_COLL?collectionId=$_&offset=0&size=20"} 1 .. 4 ], '6 collections: the first 4 first pages requested, in order' );
	is( scalar Slim::Networking::SimpleAsyncHTTP->deferred, 4, '4 in flight' );
	is( Slim::Networking::SimpleAsyncHTTP->completeDeferred, 4, 'the 4 answer ...' );
	is_deeply( [ collection_requests() ], [ map {"$BFF_COLL?collectionId=$_&offset=0&size=20"} 1 .. 6 ], '... and the other 2 start' );
	is( scalar Slim::Networking::SimpleAsyncHTTP->deferred, 2, '(2 in flight)' );
	is( $c->count, 0, 'no answer before the last one' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'one callback once all 6 answered' );
	is_deeply( ( $c->args(0) )[0], \@withImages, 'every collection gets its image' );
	is( scalar Slim::Utils::Timers->pending, 0, 'the deadline timer is gone' );

	fresh();
	$route_slow->();
	$c = collector();
	$COL->withImages( [@collections], $c->cb );
	advanceTime(3);
	is( $c->count, 1, 'all 6 slow: answered at the 3 s deadline' );
	is_deeply( ( $c->args(0) )[0], \@collections, 'without images' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar collection_requests(), 6, 'the queued 2 still start after the deadline (they warm the cache the menus use)' );
	is( scalar Slim::Networking::SimpleAsyncHTTP->deferred, 2, 'still never more than 4 in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'late answers: no second callback' );
	is_deeply( ( $c->args(0) )[0], \@collections, 'nor a changed answer' );

	fresh();
	route_json( qr{collectionId=$_&}, { collection => { items => [ program_card( 100 + $_, "https://img.test/$_.jpg" ) ] } } ) for 1 .. 6;
	$c = collector();
	$COL->withImages( [@collections], $c->cb );
	is_deeply( [ $c->calls ], [ [ \@withImages ] ], 'answers at once (cache hits, synchronous): one callback, every image' );
	is( scalar collection_requests(), 6, 'one request each' );

	fresh();
	route_json( qr{collectionId=1&}, { collection => { items => [ program_card( 101, 'https://img.test/1.jpg' ) ] } } );
	$c = collector();
	Plugins::ABCListen::Collections::withImages( [ { id => 1 } ], $c->cb );
	is_deeply( [ $c->calls ], [ [ [ { id => 1, image => 'https://img.test/1.jpg' } ] ] ], 'called as a plain function: the same answer' );
};

# ---------------------------------------------------------------------------
# Browse by category -> a category
# ---------------------------------------------------------------------------

subtest 'Browse by category -> True Crime: collectionId=104142226 pages 20 at a time + More… -> O2\'s program menu' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	route_categories();
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

subtest 'Browse by category (D7) -> Comedy, Science & Environment (not on the podcasts page): their podcasts' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	route_categories();
	route_json( "$BFF_COLL?collectionId=104141798&offset=0&size=20", { collection => { title => 'Comedy', pagination => { total => 2 }, items => [ program_card( 21, 'https://img.test/21.jpg' ), program_card( 22, 'https://img.test/22.jpg' ) ] } } );
	route_json( "$BFF_COLL?collectionId=104142140&offset=0&size=20", { collection => { title => 'Science & Environment', pagination => { total => 1 }, items => [ program_card( 23, 'https://img.test/23.jpg' ) ] } } );

	my $browse = without_az( sub { podcasts_root() } )->[3];
	is( scalar @{ $browse->{items} }, 18, 'Browse by category: 18 categories' );

	for my $case ( [ 'Comedy', 104141798, [ 'Program 21', 'Program 22' ] ], [ 'Science & Environment', 104142140, ['Program 23'] ] ) {
		my ( $name, $id, $programs ) = @$case;
		my ($category) = grep { $_->{name} eq $name } @{ $browse->{items} };
		ok( $category, "$name is listed" ) or next;
		is_deeply( $category->{passthrough}, [ { id => "$id", title => $name, image => $category->{image}, fallbackPath => ( grep { $_->[0] == $id } @ALL_CATEGORIES )[0]->[2] }, 0, 2 ], "$name: collectionItem link to its page id $id (level 2)" );
		like( $category->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/[0-9a-f]+\?.*width=300}, "$name: its tile artwork" );

		my $c = open_item($category);
		advanceTime(3);
		is( $c->count, 1, "$name: one callback" );
		is( ( collection_requests() )[-1], "$BFF_COLL?collectionId=$id&offset=0&size=20", "$name: GET collection/x?collectionId=$id" );
		is_deeply( names( items_of($c) ), $programs, "$name: its podcasts" );
		ok( !( grep { !$_->{url} || $_->{url} != $PROGRAM } @{ items_of($c) } ), "$name: each opens O2's program -> episodes menu" );
	}
};

subtest 'Podcasts (D7): a slow or failing categories collection never delays the menu past 3 s; one callback' => sub {
	fresh();
	route_podcasts();
	route_sub_collections();
	route_categories( defer => 1 );

	my $c = feed( $PODCASTS, $CLIENT );
	is( $c->count, 0, 'the categories collection is slow: waiting' );
	advanceTime(2.9);
	is( $c->count, 0, 'still waiting at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered at 3 s (the withImages wait, unchanged)' );
	my ($browse) = grep { $_->{name} eq $BROWSE } @{ items_of($c) };
	is_deeply( names( $browse->{items} ), [ map { $_->[1] } @CATEGORIES ], 'Browse by category: the podcasts page\'s 8' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late collection: no second callback' );

	$c = feed( $PODCASTS, $CLIENT );
	is( $c->count, 1, 'the next open: at once (everything cached)' );
	($browse) = grep { $_->{name} eq $BROWSE } @{ items_of($c) };
	is( scalar @{ $browse->{items} }, 18, '... with all 18 categories' );

	fresh();
	route_podcasts();
	route_sub_collections();
	route( category_url(0), code => 500, content => 'down' );
	$c = feed( $PODCASTS, $CLIENT );
	is( $c->count, 1, 'the categories collection fails: answered at once' );
	($browse) = grep { $_->{name} eq $BROWSE } @{ items_of($c) };
	is_deeply( names( $browse->{items} ), [ map { $_->[1] } @CATEGORIES ], 'with the podcasts page\'s 8' );

	fresh();
	route_podcasts();
	route_json( sub_url(105492374), { collection => { items => [ program_card( 1, 'https://img.test/1.jpg' ) ] } }, defer => 1 );
	route_categories();
	$c = feed( $PODCASTS, $CLIENT );
	is( $c->count, 0, 'categories answered, an image lookup slow: waiting' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'answered when the last one is in' );
	is( scalar @{ ( grep { $_->{name} eq $BROWSE } @{ items_of($c) } )[0]->{items} }, 18, '(18 categories)' );

	for my $slow ( 0, 1 ) {
		fresh();
		route_podcasts();
		route_sub_collections();
		route_categories( $slow ? ( defer => 1 ) : () );
		my $calls = 0;
		ok( eval { $PODCASTS->( $CLIENT, sub { $calls++; die "LMS broke\n" }, {} ); 1 }, ( $slow ? 'slow' : 'cached' ) . ' categories, LMS\'s callback dies: no die' ) or diag $@;
		advanceTime(3);
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		advanceTime(3);
		is( $calls, 1, '... called once' );
	}

	fresh();
	route_podcasts();
	route_sub_collections();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::categories = sub { die "categories broke\n" };
		is_deeply( without_az( sub { podcasts_root() } ), [ { name => $LOAD_FAILED, type => 'text' } ], 'categories() dying: one LOAD_FAILED item, once (as withImages dying)' );
	}
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
