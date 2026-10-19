#!/usr/bin/perl
# Plugins::ABCListen::Collections (D1 collection engine), offline (SimpleAsyncHTTP stub, fake clock):
# page()/home() parsing (component order, hero normalisation, ignored and unknown components,
# collections without a supported card omitted, stale and buildId-drift paths through API.pm,
# section pages), items() (title/total/count/cards, cache, null/empty/error), the itemFor
# dispatcher per card type (recording stubs for programItem / episodeItem / stationItem /
# byPageSlug; cardId ids; dynamiccollection leaf ids; station slug candidates; teaser and hero
# path rules; skipped types; depth limit; dying builders) and itemsFor (duplicates, FQ4 program
# name lookups: rename, errors, the 3 s deadline on the fake clock, at most 4 at a time).
#
# Fixtures: t/data/discovery/ - nextdata-listen-home.trimmed.json (fresh capture of
# /_next/data/build-3afcd04f/listen.json on 2026-10-19: every component, lists cut to 3-4),
# bff-collection-*.json (collection/x responses as served; *.trimmed: items cut),
# nextdata-program-if-youre-listening.trimmed.json (program page keys Programs.pm reads); plus
# t/data/foundation/nextdata-section-news.trimmed.json (a cardId != contentUri card) and
# listen-search.trimmed.html (buildId build-3afcd04f).

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
use Plugins::ABCListen::Live;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# L1's Stations.pm may not exist yet: let require() find the test's stubs below either way.
eval { require Plugins::ABCListen::Stations; 1 } or $INC{'Plugins/ABCListen/Stations.pm'} = __FILE__;

my $COL       = 'Plugins::ABCListen::Collections';
my $SITE      = 'https://www.abc.net.au';
my $BFF_COLL  = "$SITE/core-next/api/collection/x";
my $NEXT      = "$SITE/_next/data/build-3afcd04f";
my $T0        = 1_792_400_000;
my $ICON      = Plugins::ABCListen::Util::ICON;
my $WCMS      = 'https://live-production.wcms.abc-cdn.net.au';
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $CLIENT    = ABCListenTest::FakeClient->new('00:00:00:00:00:01');

my $HOME_COLLECTIONS = [
	[ 103194114 => "Today's Top Picks" ],
	[ 103194116 => 'Top 100 Australian Books' ],
	[ 102833294 => 'Radio Stations' ],
	[ 104903746 => 'Latest News' ],
	[ 103194120 => 'Most Popular Podcasts' ],
	[ 103194124 => 'True Crime & Investigations' ],
	[ 14123148  => 'Health & Wellbeing' ],
	[ 103194150 => 'Society & Culture' ],
	[ 104223142 => 'Music For Every Mood' ],
	[ 103207758 => 'Looking For Something New?' ],
	[ 106728212 => 'Relax & Sleep' ],
	[ 14123152  => 'Categories' ],
];

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- recording builder stubs (call the real builders unless told otherwise) ----

my ( @PROGRAM_ITEM, @EPISODE_ITEM, @STATION_ITEM, @BY_PAGE_SLUG );
my %SLUGS;    # byPageSlug table for the test: site path (D4: lookups are by path) => service id
my ( $realProgramItem, $realEpisodeItem ) = ( \&Plugins::ABCListen::OnDemand::programItem, \&Plugins::ABCListen::OnDemand::episodeItem );
my $realByPageSlug = Plugins::ABCListen::Stations->can('byPageSlug');    # L1's rules (undef before L1)
{
	no warnings qw(redefine once);
	*Plugins::ABCListen::OnDemand::programItem = sub { push @PROGRAM_ITEM, { %{ $_[2] } }; goto &$realProgramItem };
	*Plugins::ABCListen::OnDemand::episodeItem = sub { push @EPISODE_ITEM, { %{ $_[2] } }; goto &$realEpisodeItem };
	*Plugins::ABCListen::Stations::byPageSlug  = sub { push @BY_PAGE_SLUG, $_[1]; return $SLUGS{ $_[1] } };
	*Plugins::ABCListen::Live::stationItem     = sub {
		my ( $class, $client, $id ) = @_;
		push @STATION_ITEM, [ $client, $id ];
		my $url = "abclisten://live/$id";
		return { name => "Station $id", type => 'audio', on_select => 'play', url => $url, favorites_url => $url, image => $ICON };
	};
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	@PROGRAM_ITEM = @EPISODE_ITEM = @STATION_ITEM = @BY_PAGE_SLUG = ();
	%SLUGS = ( '/listen/live/sport' => 'SPORT', '/listen/radionational' => 'RN', '/triplej' => 'TRIPLEJ', '/pacific/live' => 'RA1', '/listen/live/country' => 'COUNTRY' );
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture( $_[0] ) ) }

sub route_home { route( "$NEXT/listen.json", file => 'discovery/nextdata-listen-home.trimmed.json', headers => $JSON_TYPE ) }

sub route_json {
	my ( $match, $data, %opt ) = @_;
	route( $match, code => 200, headers => $JSON_TYPE, content => to_json($data), %opt );
}

sub route_collection {
	my ( $id, $offset, $file ) = @_;
	route( "$BFF_COLL?collectionId=$id&offset=$offset&size=20", file => "discovery/$file", headers => $JSON_TYPE );
}

# A synthetic page with these components
sub page_with { return { pageProps => { data => { componentsContent => [@_] } } } }

sub collection_component {
	my ( $id, $title, @cards ) = @_;
	return { component => 'StandardCollection', key => $id, componentProps => { id => $id, title => $title, items => \@cards } };
}

sub card {
	my ( $uri, %more ) = @_;
	return { contentUri => $uri, cardTitle => 'Card ' . ( $uri =~ m{/([0-9]+)\z} )[0], %more };
}

sub sized { my ( $hash, $w, $h, %crop ) = @_; return "$WCMS/$hash?impolicy=wcms_crop_resize&cropH=$crop{h}&cropW=$crop{w}&xPos=$crop{x}&yPos=0&width=$w&height=$h" }

# Run an async collections call; returns the collector.
sub run {
	my ( $fn, @args ) = @_;
	my $c = collector();
	$COL->$fn( @args, $c->cb );
	return $c;
}

sub ref_from_card { Plugins::ABCListen::API::cardRef(shift) }

sub nextdata_requests { grep { m{/_next/data/} } map { $_->{url} } requests() }

sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub errors_logged   { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub debug_logged    { grep { $_->{level} eq 'DEBUG' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

sub with_debug {
	my $code = shift;
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';
	return $code->();
}

# ---------------------------------------------------------------------------
# page() / home()
# ---------------------------------------------------------------------------

subtest 'home(): collections in page order; video-only omitted; first supported card image' => sub {
	fresh();
	route_home();

	my $c = run('home');
	is( $c->count, 1, 'one callback' );
	my ($page) = $c->args(0);

	is_deeply(
		[ map { [ $_->{id}, $_->{title} ] } @{ $page->{collections} } ],
		$HOME_COLLECTIONS,
		'every StandardCollection in page order, minus "Explore Video Podcasts" (106944162, video only)'
	);
	ok( !( grep { $_->{id} eq '106944162' } @{ $page->{collections} } ), 'Explore Video Podcasts is absent' );
	is( $page->{stale}, 0, 'not stale' );

	my %byId = map { $_->{id} => $_ } @{ $page->{collections} };
	is( $byId{103194120}->{image}, sized( '0b00910f69470533fe28ab472d099166', 300, 300, h => 3000, w => 3000, x => 0 ), 'Most Popular Podcasts: the first card\'s image at 300 px (crop params kept)' );
	is( $byId{102833294}->{image}, sized( '0e4716af37e3f3b3195240a06d4a1409', 300, 300, h => 1500, w => 1500, x => 0 ),
		'Radio Stations: the image of its first SUPPORTED card (ABC SPORT, /listen/live/sport), not "ABC local radio stations" (/listen/radio#find-your-local-station is no station)' );
	is_deeply( [ sort keys %{ $byId{103194114} } ], [qw(id image title)], 'collection keys: id, title, image' );

	is( scalar @{ $page->{hero} }, 4, 'hero: the 4 carousel items of the fixture, unknown ones included (itemFor skips those)' );
	is_deeply( [ map { "$_->{type}/$_->{id}" } @{ $page->{hero} } ],
		[ 'unknown/107265358', 'audioepisode/107182078', 'program/107208268', 'audioepisode/107220162' ], 'hero items in carousel order' );
	is( scalar warnings_logged(), 0, 'no WARN' );
	is( scalar errors_logged(),   0, 'no ERROR' );
};

subtest 'hero normaliser: the cardRef shape from HeroCarousel items' => sub {
	fresh();
	route_home();
	my ($page) = run('home')->args(0);
	my ( $unknown, $episode, $program, $episode2 ) = @{ $page->{hero} };

	is_deeply(
		$episode,
		{
			type         => 'audioepisode',
			id           => '107182078',
			uriId        => '107182078',
			title        => 'Bondy: From Hero to Zero',
			tagline      => undef,
			path         => '/listen/programs/abc-rewind/alan-bond-business-corruption-america-cup-perth-/107182078',
			image        => sized( 'ba55437ec5ecb309a93603f15c87e7de', 300, 300, h => 3000, w => 3000, x => 0 ),
			date         => undef,
			duration     => undef,
			programId    => undef,
			docType      => 'audioepisode',
			description  => "Alan Bond was a genius, master salesman and con man. His '80s win of the America\x{2019}s Cup put Australia on the global stage. Mark Humphries tells the remarkable true story of Alan Bond; from the glitzy highs to his spectacular crash and burn.",
			programTitle => 'ABC Rewind',
			hero         => 1,
		},
		'audioepisode: exact ref (title trimmed, duration 0 -> undef, path from canonicalURL, programTitle)'
	);
	is( $episode2->{duration}, 2495, 'a positive buttonProps.duration is kept' );
	is( $program->{type}, 'program', 'program item' );
	is( $program->{title}, 'Planet America', 'program title' );
	is( $program->{path}, '/listen/programs/planet-america-page', 'program path (canonicalURL, no trailing slash)' );
	is( $program->{programTitle}, undef, 'empty programTitle -> undef' );
	is( $unknown->{type}, 'unknown', 'unknown item kept as a ref' );
	is( $unknown->{path}, '/listen/radionational/countdown/top100books/1-100', 'with its path' );

	# entities, a leaf that differs from the itemUri id, a missing itemUri
	fresh();
	route_json( "$NEXT/listen.json", page_with( {
		component      => 'HeroCarousel',
		componentProps => { items => [
			{ itemUri => 'coremedia://audio/1', title => ' Rock &amp; Roll ', description => 'A &quot;b&quot;', imgSrc => undef, buttonProps => { canonicalURL => 'https://abc.net.au/listen/programs/x/y/22', duration => 60 } },
			{ title => 'no uri' },
			'not a hash',
		] },
	} ) );
	($page) = run('home')->args(0);
	is( scalar @{ $page->{hero} }, 1, 'items without a coremedia itemUri are dropped' );
	is_deeply( [ @{ $page->{hero}->[0] }{qw(id uriId title description image duration path)} ],
		[ '22', '1', 'Rock & Roll', 'A "b"', undef, 60, '/listen/programs/x/y/22' ], 'entities decoded (Util::decodeEntities), audio id = canonicalURL leaf, abc.net.au host accepted' );
};

subtest 'page(): ignored and unknown components; a dying handler is isolated' => sub {
	fresh();
	route_json( "$NEXT/listen.json", page_with(
		{ component => 'LiveRadioCarousel',         componentProps => { cards => [ { papiServiceId => 'RN' } ] } },
		{ component => 'RecommendationsExperiment', componentProps => {} },
		{ component => 'ExperimentEnroller',        componentProps => {} },
		{ component => 'AppStoreCTA',               componentProps => {} },
		{ component => 'AppOnwardJourney',          componentProps => {} },
		{ component => 'Promo',                     componentProps => {} },
		{ component => 'Promo',                     componentProps => {} },
		{ component => 'TeaserNavigator',           componentProps => {} },
		collection_component( 11, 'Programs', card( 'coremedia://program/5', articleLink => '/listen/programs/five/' ) ),
		'junk',
	) );

	my $page = with_debug( sub { ( run('home')->args(0) )[0] } );
	is_deeply( [ map { $_->{title} } @{ $page->{collections} } ], ['Programs'], 'only the StandardCollection becomes a collection' );
	is_deeply( $page->{hero}, [], 'no hero' );
	my @unknown = grep { $_->{message} =~ /ignoring component/ } debug_logged();
	is_deeply( [ map { ( $_->{message} =~ /component (\S+)/ )[0] } @unknown ], [qw(Promo TeaserNavigator)], 'each unknown component type logged once at DEBUG; known ones not at all' );
	is( scalar warnings_logged(), 0, 'no WARN' );

	fresh();
	route_home();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::cardRef = sub { die "card parser broke\n" };
		my $c = run('home');
		is( $c->count, 1, 'one callback although every StandardCollection handler died' );
		($page) = $c->args(0);
	}
	is_deeply( $page->{collections}, [], 'the collections were skipped' );
	is( scalar @{ $page->{hero} }, 4, 'the hero still parsed' );
	is( scalar( grep { $_->{message} =~ /skipped a StandardCollection component: card parser broke/ } warnings_logged() ), 1, 'logged at WARN once per component name' );
};

subtest 'page(): collections without an id or without a supported card are omitted' => sub {
	fresh();
	route_json( "$NEXT/x.json", page_with(
		collection_component( 1, 'Videos', card('coremedia://video/1'), card('coremedia://videosegment/2') ),
		collection_component( 2, 'Articles and people', card('coremedia://article/3'), card('coremedia://person/4') ),
		collection_component( 3, 'Empty' ),
		{ component => 'StandardCollection', key => 'abc', componentProps => { title => 'No id', items => [ card('coremedia://audio/5') ] } },
		{ component => 'StandardCollection', key => '6', componentProps => { title => 'Key id', items => [ card('coremedia://audio/7') ] } },
		collection_component( 8, undef, card( 'coremedia://video/9', cardImagePrepared => { imgSrc => 'https://example.test/v.jpg' } ), card('coremedia://audioepisode/10') ),
		collection_component( 11, 'Bad dynamic', card( 'coremedia://dynamiccollection/12', articleLink => '/listen/listenapp/no-leaf/' ) ),
		collection_component( 13, 'Program without a path', card('coremedia://program/14') ),
	) );

	my ($page) = run( 'page', '/x' )->args(0);
	is_deeply(
		[ map { [ $_->{id}, $_->{title}, $_->{image} ] } @{ $page->{collections} } ],
		[ [ '6', 'Key id', undef ], [ '8', undef, undef ] ],
		'kept: id from key when componentProps.id is missing; untitled kept (title undef); image of the first SUPPORTED card (none here)'
	);
};

subtest 'page(\'/listen\') gives the same result as home()' => sub {
	fresh();
	route_home();
	my ($home) = run('home')->args(0);
	my ($page) = run( 'page', '/listen' )->args(0);
	is_deeply( $page, $home, 'identical' );
	is( scalar( grep {m{/listen\.json\z}} nextdata_requests() ), 1, 'one request: the second call is a cache hit (1 h)' );

	my ($full) = run( 'page', 'https://www.abc.net.au/listen/' )->args(0);
	is_deeply( $full, $home, 'a full URL with a trailing slash names the same page' );
};

subtest 'page(): cache 1 h, last-good copy when ABC fails, LOAD_FAILED without one' => sub {
	fresh();
	route_home();
	my ($first) = run('home')->args(0);

	advanceTime(3599);
	run('home');
	is( scalar nextdata_requests(), 1, 'within the hour: no new request' );

	advanceTime(2);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( "$NEXT/listen.json", code => 500, content => 'oops' );
	my $c = run('home');
	is( $c->count, 1, 'one callback' );
	my ($stale) = $c->args(0);
	is( $stale->{stale}, 1, 'after the hour, ABC failing: the last-good page is served with stale => 1' );
	is_deeply( $stale->{collections}, $first->{collections}, 'same collections' );

	fresh();
	route( "$NEXT/listen.json", code => 500, content => 'oops' );
	($c) = run('home');
	is_deeply( [ $c->args(0) ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'no cached copy: { error => LOAD_FAILED }, once' );

	fresh();
	route( "$NEXT/listen.json", code => 429, content => 'slow down' );
	is_deeply( [ run('home')->args(0) ], [ { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' } ], 'the API token is passed through (RATE_LIMITED)' );

	fresh();
	route_json( "$NEXT/listen.json", { pageProps => { data => { componentsContent => 'nope' } } } );
	is_deeply( ( run('home')->args(0) )[0], { hero => [], collections => [], stale => 0 }, 'a page without components: empty lists, no error' );
};

subtest 'page(): a stale buildId is handled by API::nextData (404 -> rediscover -> retry)' => sub {
	fresh();
	Slim::Networking::SimpleAsyncHTTP->reset;
	my $searches = 0;
	Slim::Networking::SimpleAsyncHTTP->addRoute( "$SITE/listen/search", sub { $searches++; return { code => 200, headers => { 'Content-Type' => 'text/html' }, content => '<script>{"buildId":"build-' . ( $searches == 1 ? 'old' : 'new' ) . '"}</script>' } } );
	route( "$SITE/_next/data/build-old/listen.json", code => 404, headers => { 'Content-Type' => 'text/html' }, content => fixture('foundation/next-data-404.html') );
	route( "$SITE/_next/data/build-new/listen.json", file => 'discovery/nextdata-listen-home.trimmed.json', headers => $JSON_TYPE );

	my $c = run('home');
	is( $c->count, 1, 'one callback' );
	my ($page) = $c->args(0);
	is( scalar @{ $page->{collections} }, scalar @$HOME_COLLECTIONS, 'the home page, from the rediscovered buildId' );
	is( $searches, 2, 'the search page was read twice (initial + refresh)' );
};

subtest 'page() on a section page (D4 reuse): News collections; a cardId != contentUri card' => sub {
	fresh();
	route( "$NEXT/listen/news.json", file => 'foundation/nextdata-section-news.trimmed.json', headers => $JSON_TYPE );

	my ($page) = run( 'page', '/listen/news' )->args(0);
	is_deeply(
		[ map { $_->{title} } @{ $page->{collections} } ],
		[ 'Latest News', 'Daily Programs', 'Beyond The Headlines', 'ABC News Daily', 'Latest Current Affairs', 'Featured Podcasts', 'News from Radio National', 'Latest from NewsRadio', 'Regional & Rural News' ],
		'the 9 StandardCollections in page order (MiniEPG, AppStoreCTA ignored)'
	);

	my $data = json_file('foundation/nextdata-section-news.trimmed.json');
	my ($current) = grep { ( $_->{componentProps}->{title} || '' ) eq 'Latest Current Affairs' } @{ $data->{pageProps}->{data}->{componentsContent} };
	my $ref = ref_from_card( $current->{componentProps}->{items}->[0] );
	is( $ref->{uriId}, '103186434', 'the card\'s contentUri id is the dynamic teaser 103186434' );

	my $item = $COL->itemFor( $CLIENT, $ref, 1 );
	is( $EPISODE_ITEM[-1]->{id}, '107232996', 'episodeItem gets the cardId 107232996 as the episode id' );
	is( $item->{play}, 'abclisten://episode/107232996', 'the item plays (and favourites store) abclisten://episode/107232996, never the teaser id' );
};

# ---------------------------------------------------------------------------
# items()
# ---------------------------------------------------------------------------

subtest 'items(): title, total, count and cards; request; 30 min cache' => sub {
	fresh();
	route_collection( 103194120, 0, 'bff-collection-103194120-most-popular-podcasts-o0.json' );

	my $c = run( 'items', 103194120, 0, 20 );
	is( $c->count, 1, 'one callback' );
	my ($page) = $c->args(0);
	is( $page->{title}, 'Most Popular Podcasts', 'title' );
	is( $page->{total}, 55, 'total = collection.pagination.total' );
	is( $page->{count}, 20, 'count = cards ABC sent' );
	is( scalar @{ $page->{cards} }, 20, '20 card refs' );
	is_deeply( $page->{cards}->[0], ref_from_card( json_file('discovery/bff-collection-103194120-most-popular-podcasts-o0.json')->{collection}->{items}->[0] ), 'cards are API::cardRef refs' );
	is( $page->{cards}->[0]->{id}, '9593170', 'ids are cardIds (coremedia://program/104252122 -> 9593170)' );
	is_deeply( [ map { $_->{url} } grep { $_->{url} =~ /collection/ } requests() ], ["$BFF_COLL?collectionId=103194120&offset=0&size=20"], 'GET collection/x?collectionId&offset&size' );

	advanceTime(1799);
	run( 'items', 103194120, 0, 20 );
	is( scalar( grep { $_->{url} =~ /collection/ } requests() ), 1, 'cached for 30 min' );
	advanceTime(2);
	run( 'items', 103194120, 0, 20 );
	is( scalar( grep { $_->{url} =~ /collection/ } requests() ), 2, 'fetched again after 30 min' );

	fresh();
	route( qr{\Q$BFF_COLL\E\?collectionId=7&offset=0&size=20}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { id => 7 } } ) );
	is_deeply( ( run( 'items', '7', undef, undef )->args(0) )[0], { title => undef, total => undef, count => 0, cards => [] }, 'defaults offset 0 / size 20; missing total -> undef; no items -> []' );
};

subtest 'items(): null or empty collections; errors; bad ids' => sub {
	fresh();
	route_collection( 14129466, 0, 'bff-collection-14129466-null.json' );
	is_deeply( ( run( 'items', 14129466, 0, 20 )->args(0) )[0], { title => undef, total => undef, count => 0, cards => [] }, '{"collection":null} (a dynamiccollection contentUri id) -> empty page, not an error' );

	fresh();
	route( qr{\Q$BFF_COLL\E\?collectionId=103194120&offset=0&size=10}, file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE );
	is_deeply( ( run( 'items', 103194120, 0, 10 )->args(0) )[0], { title => 'Most Popular Podcasts', total => 0, count => 0, cards => [] }, 'total 0, no items' );

	fresh();
	route( qr{\Q$BFF_COLL\E}, code => 503, content => 'down' );
	my $c = run( 'items', 1, 0, 20 );
	is_deeply( [ $c->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ] ], 'HTTP error -> { error => LOAD_FAILED }, once' );

	fresh();
	$c = run( 'items', 'abc', 0, 20 );
	is_deeply( [ $c->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ] ], 'a non-numeric id -> LOAD_FAILED without a request' );
	is( scalar requests(), 0, 'no request' );

	fresh();
	route( qr{\Q$BFF_COLL\E}, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { items => [ { contentUri => 'nope' }, card('coremedia://audio/1'), 'junk' ], pagination => { total => 3 } } } ) );
	my ($page) = run( 'items', 1, 0, 20 )->args(0);
	is( $page->{count}, 3, 'count includes unparseable cards (for paging)' );
	is( scalar @{ $page->{cards} }, 1, 'cards without a parseable contentUri are dropped' );
};

# ---------------------------------------------------------------------------
# itemFor dispatch
# ---------------------------------------------------------------------------

subtest 'itemFor: program -> programItem (tagline as description; name rules from cardRef)' => sub {
	fresh();
	my @cards = @{ json_file('discovery/bff-collection-103194120-most-popular-podcasts-o0.json')->{collection}->{items} };

	my $iyl  = ref_from_card( $cards[0] );    # alt "If-You're-Listening 3000x3000 Podcast square" is no name
	my $item = $COL->itemFor( $CLIENT, $iyl, 1 );
	is_deeply(
		$PROGRAM_ITEM[-1],
		{
			title       => "What's really going on behind the biggest news stories",
			path        => '/listen/programs/if-youre-listening',
			id          => '9593170',
			image       => $iyl->{image},
			description => $iyl->{description},
		},
		'programItem args: title, path, id (cardId), image, description (no tagline: the card\'s description)'
	);
	is( $item->{type}, 'link', 'a program link (Jive "go")' );
	is( $item->{url}, \&Plugins::ABCListen::OnDemand::_programMenu, 'opening it is O2\'s program menu' );
	ok( !exists $item->{description}, 'no description on the browse item (LMS menu rule 1)' );
	like( $item->{image}, qr/\A\Q$WCMS\E\/0b00910f69470533fe28ab472d099166\?.*cropW=3000.*&width=300&height=169\z/, 'artwork 300 px wide, crop params kept' );

	my $roaming = ref_from_card( $cards[1] );    # alt "Global Roaming podcast" is taken as the name
	$COL->itemFor( $CLIENT, $roaming, 1 );
	is( $PROGRAM_ITEM[-1]->{title}, 'Global Roaming podcast', 'name from cardRef (alt text)' );
	is( $PROGRAM_ITEM[-1]->{description}, 'Global news and how to make sense of it', 'the tagline (cardTitle) is the description' );
	is( $item->{passthrough}->[0]->{path}, '/listen/programs/if-youre-listening', 'canonical path in the passthrough' );
};

subtest 'itemFor: audioepisode / audio / audiosegment -> episodeItem (cardId ids; undef passes through)' => sub {
	fresh();
	my @cards = @{ json_file('discovery/bff-collection-103194114-todays-top-picks.json')->{collection}->{items} };

	my %seen;
	for my $card (@cards) {
		my $ref  = ref_from_card($card);
		my $item = $COL->itemFor( $CLIENT, $ref, 1 );
		next if $seen{ $ref->{type} }++;

		is_deeply(
			$EPISODE_ITEM[-1],
			{
				id => $card->{cardId}, docType => $ref->{type}, title => $ref->{title}, programTitle => undef, programId => undef,
				path => $ref->{path}, image => $ref->{image}, description => $ref->{description}, date => undef, duration => $card->{cardMediaIndicatorPrepared}->{duration},
			},
			"$ref->{type}: episodeItem gets id = cardId $card->{cardId}, docType, title, path, image, description, duration; undef date/programTitle stay undef"
		);
		is( $item->{play}, "abclisten://episode/$card->{cardId}", "$ref->{type}: plays abclisten://episode/<cardId>" );
		is( $item->{name}, $ref->{title}, "$ref->{type}: without a date the name is the title (no '1 Jan 1970')" );
		unlike( $item->{line2} // '', qr/1970|0 min/, "$ref->{type}: no fabricated date or duration" );
	}
	is_deeply( [ sort keys %seen ], [qw(audio audioepisode audiosegment)], 'all three audio types seen' );
	ok( ( grep { $_->{id} eq '107232952' } @EPISODE_ITEM ), 'contentUri 107282420 (teaser) -> id 107232952 (cardId)' );
};

subtest 'itemFor: collection -> nested link; dynamiccollection -> articleLink leaf id' => sub {
	fresh();
	my @categories = @{ json_file('discovery/bff-collection-14123152-categories.trimmed.json')->{collection}->{items} };
	my $trueCrime  = ref_from_card( $categories[1] );

	my $item = $COL->itemFor( $CLIENT, $trueCrime, 1 );
	is_deeply(
		$item,
		{
			name        => 'True Crime',
			type        => 'link',
			url         => \&Plugins::ABCListen::Collections::_collectionMenu,
			passthrough => [ { id => '104142226', title => 'True Crime', image => $trueCrime->{image} }, 0, 2 ],
			image       => $trueCrime->{image},
		},
		'dynamiccollection: link to collection 104142226 (the articleLink leaf, not contentUri 14129462), menu level 2'
	);

	my $ref = ref_from_card( card( 'coremedia://dynamiccollection/14129462', cardId => '104142226', articleLink => '/listen/listenapp/true-crime/' ) );
	is( $COL->itemFor( $CLIENT, $ref, 1 ), undef, 'dynamiccollection without a numeric articleLink leaf: skipped' );

	$ref  = ref_from_card( card( 'coremedia://collection/555', cardTitle => 'Nested' ) );
	$item = $COL->itemFor( $CLIENT, $ref, 2 );
	is_deeply( [ @$item{qw(name type image)}, $item->{passthrough} ], [ 'Nested', 'link', $ICON, [ { id => '555', title => 'Nested', image => undef }, 0, 3 ] ], 'collection card: link (id, title), plugin icon without an image, level 3' );
};

subtest 'itemFor: channel / externallink -> Stations->byPageSlug($path) -> Live->stationItem (D4: lookups by path)' => sub {
	fresh();
	my @cards = @{ json_file('discovery/bff-collection-102833294-radio-stations.json')->{collection}->{items} };

	my @results;
	for my $card (@cards) {
		@BY_PAGE_SLUG = ();
		my $item = $COL->itemFor( $CLIENT, ref_from_card($card), 1 );
		push @results, [ $card->{cardTitle}, [@BY_PAGE_SLUG], $item ? $item->{url} : undef ];
	}

	is_deeply(
		\@results,
		[
			[ 'ABC local radio stations', ['/listen/radio'], undef ],                                     # maps to nothing
			[ 'ABC SPORT',                ['/listen/live/sport'], 'abclisten://live/SPORT' ],
			[ 'ABC Radio National',       ['/listen/radionational'], 'abclisten://live/RN' ],
			[ 'ABC NewsRadio',            ['/listen/news'], undef ],                                      # not in the test table
			[ 'ABC Classic',              ['/listen/classic'], undef ],
			[ 'triple j',                 ['/triplej'], 'abclisten://live/TRIPLEJ' ],
			[ 'Double J',                 ['/listen/doublej'], undef ],
			[ 'ABC Country',              ['/listen/live/country'], 'abclisten://live/COUNTRY' ],
			[ 'ABC Jazz',                 ['/listen/jazz'], undef ],
			[ 'ABC Kids listen',          ['/kidslisten'], undef ],
			[ 'ABC Radio Australia',      ['/pacific/live'], 'abclisten://live/RA1' ],
			[ 'ABC Classic 2',            ['/listen/live/classic2'], undef ],
			[ 'triple j Hottest',         ['/triplejhottest'], undef ],
			[ 'triple j Unearthed',       [], undef ],                                                    # off-site link: no site path
		],
		'one Stations->byPageSlug call per card, with the card\'s site path (no slug guessing); the id it returns is the station'
	);
	is_deeply( $STATION_ITEM[0], [ $CLIENT, 'SPORT' ], 'stationItem($client, $serviceId)' );
	is( scalar warnings_logged(), 0, 'unmapped station cards: no WARN' );

	SKIP: {
		skip 'L1 not merged', 4 unless $realByPageSlug;
		no warnings 'redefine';
		local *Plugins::ABCListen::Stations::byPageSlug = sub { push @BY_PAGE_SLUG, $_[1]; goto &$realByPageSlug };
		my $url = sub { my $item = $COL->itemFor( $CLIENT, ref_from_card( card( @_, cardTitle => 'x' ) ), 1 ); $item ? $item->{url} : undef };

		is( $url->( 'coremedia://externallink/1', articleLink => 'https://www.abc.net.au/listen/news' ), 'abclisten://live/NEWS', 'L1 rules: /listen/news is NewsRadio' );
		is( $url->( 'coremedia://channel/2', articleLink => 'https://www.abc.net.au/news' ), undef, 'L1 rules: /news (the ABC News website) is no station' );
		is( $url->( 'coremedia://externallink/3', articleLink => 'https://abc.net.au/listen/live/sportextra' ), 'abclisten://live/ITINERANT_THREE', 'L1 rules: abc.net.au without www maps (ABC SPORT EXTRA)' );
		is( $url->( 'coremedia://externallink/4', articleLink => '/kidslisten/' ), 'abclisten://live/KIDSLISTEN', 'L1 rules: a network home (/kidslisten) maps' );
	}
};

subtest 'itemFor: station cards without L1\'s live API are skipped silently' => sub {
	fresh();
	my $ref = ref_from_card( card( 'coremedia://channel/1', articleLink => '/listen/radionational/' ) );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Stations::byPageSlug;
		is( $COL->itemFor( $CLIENT, $ref, 1 ), undef, 'no Stations->byPageSlug: undef' );
	}
	{
		local *Plugins::ABCListen::Live::stationItem;
		is( $COL->itemFor( $CLIENT, $ref, 1 ), undef, 'no Live->stationItem: undef' );
	}
	is( scalar @STATION_ITEM, 0, 'stationItem never called' );
	is( scalar( warnings_logged() ) + scalar( errors_logged() ), 0, 'no WARN or ERROR' );

	fresh();
	route_home();
	{
		local *Plugins::ABCListen::Stations::byPageSlug;
		my ($page) = run('home')->args(0);
		ok( !( grep { $_->{id} eq '102833294' } @{ $page->{collections} } ), 'page(): Radio Stations has no supported card then, so it is omitted from Home' );
	}
};

subtest 'itemFor: teaser and hero "unknown" items by path shape' => sub {
	fresh();
	my %cases = (
		'/listen/programs/scienceshow/'                        => [ 'program', '/listen/programs/scienceshow' ],
		'https://www.abc.net.au/triplej/programs/hack'         => [ 'program', '/triplej/programs/hack' ],
		'/listen/programs/scienceshow/some-episode/107000000/' => [ 'episode', '107000000' ],
		'/listen/programs/scienceshow/some-episode'            => [ undef ],
		'/news/2026-10-19/a-story/107000001'                   => [ undef ],
		'/listen/radionational/countdown/top100books/1-100'    => [ undef ],
		'/listen/listenapp'                                    => [ undef ],
	);

	for my $type (qw(teaser unknown)) {
		for my $link ( sort keys %cases ) {
			@PROGRAM_ITEM = @EPISODE_ITEM = ();
			my $item = $COL->itemFor( $CLIENT, ref_from_card( card( "coremedia://$type/42", articleLink => $link, cardTitle => 'Teaser' ) ), 1 );
			my ( $kind, $value ) = @{ $cases{$link} };

			if ( !$kind ) {
				is( $item, undef, "$type $link: skipped" );
			}
			elsif ( $kind eq 'program' ) {
				is_deeply( [ $PROGRAM_ITEM[0]->{path}, $PROGRAM_ITEM[0]->{id} ], [ $value, undef ], "$type $link: program (no id: 42 is a teaser id)" );
			}
			else {
				is_deeply( [ @{ $EPISODE_ITEM[0] }{qw(id docType)} ], [ $value, 'audioepisode' ], "$type $link: episode $value, docType audioepisode" );
				is( $item->{play}, "abclisten://episode/$value", "$type $link: plays the leaf id" );
			}
		}
	}
};

subtest 'itemFor: article, video, videosegment, person, unknown types, bad refs -> undef (DEBUG)' => sub {
	fresh();
	my @skipped = map { ref_from_card( card( $_, articleLink => '/listen/programs/x/y/1' ) ) } qw(
		coremedia://article/1 coremedia://video/2 coremedia://videosegment/3 coremedia://person/4
		coremedia://taxonomy/5 coremedia://newthing/6
	);
	push @skipped, ref_from_card( card( 'coremedia://externallink/7', articleLink => 'https://www.triplejunearthed.com/' ) );
	push @skipped, ref_from_card( card('coremedia://program/8') );    # no path

	with_debug( sub {
		is( $COL->itemFor( $CLIENT, $_, 1 ), undef, "$_->{type}: undef" ) for @skipped;
	} );
	is( scalar( grep { $_->{message} =~ /skipped card/ } debug_logged() ), scalar @skipped, 'each logged at DEBUG ("skipped card")' );
	is( scalar( warnings_logged() ) + scalar( errors_logged() ), 0, 'no WARN or ERROR' );
	is( scalar(@PROGRAM_ITEM) + scalar(@EPISODE_ITEM), 0, 'no builder called' );

	is( $COL->itemFor( $CLIENT, undef, 1 ), undef, 'undef ref' );
	is( $COL->itemFor( $CLIENT, { type => undef }, 1 ), undef, 'ref without a type' );
	is( $COL->itemFor( $CLIENT, { type => 'audio', id => 'x1' }, 1 ), undef, 'audio ref without a numeric id' );
};

subtest 'itemFor: depth limit (3 levels below Home)' => sub {
	fresh();
	my $program    = ref_from_card( card( 'coremedia://program/1', articleLink => '/listen/programs/one/' ) );
	my $collection = ref_from_card( card( 'coremedia://collection/2', cardTitle => 'Inner' ) );

	ok( $COL->itemFor( $CLIENT, $program, 3 ), 'a program at level 3: built' );
	is( $COL->itemFor( $CLIENT, $program, 4 ), undef, 'anything at level 4: undef' );
	ok( $COL->itemFor( $CLIENT, $program, undef ), 'undef depth counts as level 1' );

	is( $COL->itemFor( $CLIENT, $collection, 2 )->{passthrough}->[2], 3, 'a collection at level 2 opens level 3' );
	is( $COL->itemFor( $CLIENT, $collection, 3 ), undef, 'a collection at level 3 would open level 4: undef' );

	is( $COL->collectionItem( $CLIENT, { id => 9, title => 'Root' }, 0 )->{passthrough}->[2], 1, 'collectionItem at a page root (0) opens level 1' );
	is( $COL->collectionItem( $CLIENT, { id => 9, title => 'Deep' }, 3 ), undef, 'collectionItem at level 3: undef' );
	is( $COL->collectionItem( $CLIENT, { id => 'x', title => 'Bad' }, 0 ), undef, 'collectionItem without a numeric id: undef' );
	is( $COL->collectionItem( $CLIENT, { id => 9, title => ' ' }, 0 )->{name}, string('PLUGIN_ABCLISTEN_FEATURED'), 'collectionItem without a title: "Featured", never blank' );
};

subtest 'itemFor: a builder that dies skips that card, WARN once per card type' => sub {
	fresh();
	my @refs = map { ref_from_card( card( "coremedia://program/$_", articleLink => "/listen/programs/p$_/" ) ) } 1 .. 3;
	push @refs, ref_from_card( card( 'coremedia://audio/9', articleLink => '/listen/programs/x/y/9' ) );

	my @items;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::programItem = sub { die "builder broke\n" };
		@items = map { $COL->itemFor( $CLIENT, $_, 1 ) } @refs;
	}

	is_deeply( [ map { defined $_ ? 1 : 0 } @items ], [ 0, 0, 0, 1 ], 'program cards skipped, the audio card still built' );
	my @warnings = grep { $_->{message} =~ /couldn't build an item for a program card: builder broke/ } warnings_logged();
	is( scalar @warnings, 1, 'one WARN for the program type' );
	is( scalar errors_logged(), 0, 'no ERROR' );
};

# ---------------------------------------------------------------------------
# itemsFor (a page of cards) and program names
# ---------------------------------------------------------------------------

my @MPP = @{ json_file('discovery/bff-collection-103194120-most-popular-podcasts-o0.json')->{collection}->{items} };

# Program pages: If You're Listening (fixture) and Background Briefing (synthetic) answer, others 404
# (all => 1: every program page answers with the If You're Listening fixture); defer => 1: slow.
sub program_page_route {
	my %opt = @_;
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$NEXT\E/(?:listen|triplej|kidslisten)/programs/}, sub {
		my $url  = shift;
		my %slow = $opt{defer} ? ( defer => 1 ) : ();
		if ( $url =~ m{/backgroundbriefing\.json\z} && !$opt{all} ) {
			return { code => 200, headers => $JSON_TYPE, content => to_json( { pageProps => { heroImageWithCTAPrepared => { heading => 'Background Briefing', uri => 'coremedia://program/2891294' } } } ), %slow };
		}
		return { code => 404, content => 'nope', %slow } unless $url =~ m{/if-youre-listening\.json\z} || $opt{all};
		return { code => 200, headers => $JSON_TYPE, content => fixture('discovery/nextdata-program-if-youre-listening.trimmed.json'), %slow };
	} );
}

subtest 'itemsFor: duplicates (same type + id) emitted once; order kept; synchronous without lookups' => sub {
	fresh();
	my $a = ref_from_card( card( 'coremedia://audio/1', articleLink => '/listen/programs/x/a/1' ) );
	my $b = ref_from_card( card( 'coremedia://audioepisode/2', articleLink => '/listen/programs/x/b/2' ) );
	my $c = run( 'itemsFor', $CLIENT, [ $a, $b, {%$a}, 'junk', $b ], 1 );
	is( $c->count, 1, 'one callback, synchronously (no program lookups)' );
	is_deeply( [ map { $_->{play} } @{ ( $c->args(0) )[0] } ], [ 'abclisten://episode/1', 'abclisten://episode/2' ], 'each ref once, in order' );

	$c = run( 'itemsFor', $CLIENT, undef, 1 );
	is_deeply( [ $c->calls ], [ [ [] ] ], 'no refs: [] once' );
};

subtest 'itemsFor: program names (FQ4): found -> renamed, cardTitle as description; errors keep cardRef\'s name' => sub {
	fresh();
	program_page_route();

	# If You're Listening (cardTitle is a tagline), Global Roaming (alt "Global Roaming podcast"),
	# No One Saw It Coming (alt "Global Roaming podcast": another program's name), Background
	# Briefing (alt "BackgroundBriefing_3000x3000.jpg")
	my @refs = map { ref_from_card($_) } @MPP[ 0, 1, 3, 4 ];
	is( $refs[3]->{title}, 'BackgroundBriefing_3000x3000.jpg', 'precondition: cardRef names Background Briefing after its image file' );
	is( $refs[2]->{title}, 'Global Roaming podcast', 'precondition: cardRef names No One Saw It Coming after another program' );

	my $c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	is_deeply(
		[ sort grep { m{/programs/} } nextdata_requests() ],
		[ map {"$NEXT/listen/programs/$_.json"} sort qw(if-youre-listening global-roaming no-one-saw-it-coming backgroundbriefing) ],
		'every (non-hero) program card is looked up once'
	);

	is( $c->count, 1, 'one callback' );
	my ($items) = $c->args(0);
	is_deeply(
		[ map { $_->{name} } @$items ],
		[ "If You're Listening", 'Global Roaming podcast', 'Global Roaming podcast', 'Background Briefing' ],
		'found: the program\'s own name (heroImageWithCTAPrepared.heading); not found (404): cardRef\'s name is kept'
	);
	is_deeply(
		[ map { $_->{description} } @PROGRAM_ITEM ],
		[ "What's really going on behind the biggest news stories", 'Global news and how to make sense of it', 'Big moments that changed the course of history', 'Must-listen investigative journalism' ],
		'the cardTitle (tagline) is the description: after a rename, and kept when the lookup failed'
	);
	is( $items->[0]->{passthrough}->[0]->{description}, "What's really going on behind the biggest news stories", 'carried in the passthrough (LMS menu rule 1)' );
	ok( !exists $items->[0]->{description}, 'no description key on the row' );

	# second open: the program page is cached by Programs (6 h)
	Slim::Networking::SimpleAsyncHTTP->reset;
	program_page_route();
	@PROGRAM_ITEM = ();
	$c = run( 'itemsFor', $CLIENT, [ $refs[0] ], 1 );
	is( ( $c->args(0) )[0]->[0]->{name}, "If You're Listening", 'second open: named from the cache, synchronously' );
	is( scalar requests(), 0, 'no request' );

	# the page name equals the card title: the card's description stays the description
	fresh();
	program_page_route();
	my $named = ref_from_card( { %{ $MPP[0] }, cardTitle => "If You're Listening" } );
	run( 'itemsFor', $CLIENT, [$named], 1 );
	is( $PROGRAM_ITEM[0]->{title}, "If You're Listening", 'named' );
	is( $PROGRAM_ITEM[0]->{description}, $named->{description}, 'name == cardTitle: the card\'s description is kept' );
};

subtest 'itemsFor: hero program refs and refs without a path are not looked up' => sub {
	fresh();
	route_home();
	program_page_route( all => 1 );
	my ($page) = run('home')->args(0);
	Slim::Networking::SimpleAsyncHTTP->reset;

	my $c = run( 'itemsFor', $CLIENT, $page->{hero}, 1 );
	is( scalar requests(), 0, 'no lookups for hero items (they carry the program title)' );
	is_deeply( [ map { $_->{line1} } @{ ( $c->args(0) )[0] } ], [ 'Bondy: From Hero to Zero', 'Planet America', 'Dark Menace' ], 'hero: unknown skipped, program and episodes mapped, in order' );

	$c = run( 'itemsFor', $CLIENT, [ ref_from_card( card('coremedia://program/1') ) ], 1 );
	is_deeply( [ $c->calls ], [ [ [] ] ], 'a program card without a path: no lookup, no item' );
	is( scalar requests(), 0, 'no request' );
};

subtest 'itemsFor: the 3 s deadline (fake clock); late lookups warm the cache' => sub {
	fresh();
	program_page_route( defer => 1 );

	my @refs = map { ref_from_card($_) } @MPP[ 0, 2 ];
	my $c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	is( $c->count, 0, 'waiting for the lookups' );

	advanceTime(2.9);
	is( $c->count, 0, 'still waiting at 2.9 s' );
	advanceTime(0.2);
	is( $c->count, 1, 'answered at the 3 s deadline' );
	is( ( $c->args(0) )[0]->[0]->{name}, "What's really going on behind the biggest news stories", 'with the card titles' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'late lookups never call back again' );

	$c = run( 'itemsFor', $CLIENT, [ $refs[0] ], 1 );
	is( $c->count, 1, 'next open: immediate' );
	is( ( $c->args(0) )[0]->[0]->{name}, "If You're Listening", 'named: the late lookup warmed the cache' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left behind' );
};

subtest 'itemsFor: at most 4 lookups at a time; queued ones carry on after the deadline' => sub {
	fresh();
	program_page_route( defer => 1, all => 1 );

	my @refs = map { ref_from_card($_) } @MPP;
	is( scalar @refs, 20, '20 programs to look up' );

	my $c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	my @inFlight = ( scalar Slim::Networking::SimpleAsyncHTTP->deferred );
	while ( Slim::Networking::SimpleAsyncHTTP->deferred ) {
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		push @inFlight, scalar Slim::Networking::SimpleAsyncHTTP->deferred;
	}
	is( $inFlight[0], 4, '4 lookups start at once' );
	cmp_ok( ( sort { $b <=> $a } @inFlight )[0], '<=', 4, 'never more than 4 in flight' );
	is( scalar( grep { m{/programs/} } nextdata_requests() ), scalar @refs, 'every program looked up exactly once' );
	is( $c->count, 1, 'answered once all were found (before the deadline)' );
	is( ( $c->args(0) )[0]->[0]->{name}, "If You're Listening", 'renamed (every page answers with this fixture)' );

	fresh();
	program_page_route( defer => 1, all => 1 );
	$c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	advanceTime(3);
	is( $c->count, 1, 'deadline: answered with 4 lookups in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred while Slim::Networking::SimpleAsyncHTTP->deferred;
	is( scalar( grep { m{/programs/} } nextdata_requests() ), scalar @refs, 'the queued lookups still ran after the deadline (cache warm-up)' );
	is( $c->count, 1, 'still one callback' );
};

subtest 'itemsFor: a lookup that dies is an error (card title kept); exactly one callback' => sub {
	fresh();
	my $c;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Programs::program = sub { die "lookup broke\n" };
		$c = run( 'itemsFor', $CLIENT, [ ref_from_card( $MPP[0] ) ], 1 );
	}
	is( $c->count, 1, 'one callback' );
	is( ( $c->args(0) )[0]->[0]->{name}, "What's really going on behind the biggest news stories", 'card title kept' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'deadline timer cancelled' );
};

done_testing();
