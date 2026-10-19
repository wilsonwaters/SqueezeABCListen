#!/usr/bin/perl
# Plugins::ABCListen::Collections, D4 extensions for the ABC section pages, offline (SimpleAsyncHTTP
# stub fails any unrouted URL; fake clock): page() on the five section fixtures (MiniEPG and
# LiveRadioCarousel -> stations, MetaCollection sub-collections, ProgramAggregationCollection,
# station-only collections -> stationCards, untitled collections, skipped components), Home
# unchanged, synthetic edge cases (unknown components, empty / count-less MetaCollections, missing
# or lower-case papiServiceId); aggregationItems (request shape, 6 h cache, errors) and the
# %FETCHERS paging of a collection menu; and the D1 review amendments: station cards looked up by
# path (Stations->byPageSlug, contract 7), event-only stations checked on air before stationItem
# (checkOnAir, 3 s deadline), plain-function calls.
#
# Fixtures: t/data/discovery/nextdata-section-{news,sport,kidslisten,kidslisten-programs,audiobooks}
# .trimmed.json (/_next/data/build-3afcd04f/... captured 2026-10-19 for research §6.1, research
# note dropped), bff-programAggregationCollection-9317914-kidslisten-programs-size50.json (fresh capture,
# srcSet cut to 1, analytics dropped), nextdata-listen-home.trimmed.json (D1); t/data/live/ event
# status fixtures (L1).

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
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $COL       = 'Plugins::ABCListen::Collections';
my $STATIONS  = 'Plugins::ABCListen::Stations';
my $SITE      = 'https://www.abc.net.au';
my $BFF       = "$SITE/core-next/api/";
my $NEXT      = "$SITE/_next/data/build-3afcd04f";
my $T0        = 1_792_400_000;
my $ICON      = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $CLIENT    = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $COLL_MENU = \&Plugins::ABCListen::Collections::_collectionMenu;
my $MORE      = string('PLUGIN_ABCLISTEN_MORE');

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

my %SECTION_FILE = (
	'/listen/news'        => 'news',
	'/listen/sport'       => 'sport',
	'/kidslisten'         => 'kidslisten',
	'/kidslisten/programs' => 'kidslisten-programs',
	'/listen/audiobooks'  => 'audiobooks',
);

# ---- recording wrappers around L1's real functions ----

my ( @BY_PAGE_SLUG, @STATION_ITEM, @CHECK_ON_AIR );
{
	no warnings qw(redefine once);
	my $byPageSlug  = \&Plugins::ABCListen::Stations::byPageSlug;
	my $checkOnAir  = \&Plugins::ABCListen::Stations::checkOnAir;
	my $stationItem = \&Plugins::ABCListen::Live::stationItem;
	*Plugins::ABCListen::Stations::byPageSlug = sub { push @BY_PAGE_SLUG, $_[1]; goto &$byPageSlug };
	*Plugins::ABCListen::Stations::checkOnAir = sub { push @CHECK_ON_AIR, [ @{ $_[1] } ]; goto &$checkOnAir };
	*Plugins::ABCListen::Live::stationItem    = sub { push @STATION_ITEM, $_[2]; goto &$stationItem };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	$STATIONS->_reset;
	$STATIONS->_setRecords;
	@BY_PAGE_SLUG = @STATION_ITEM = @CHECK_ON_AIR = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

sub route_section {
	my $path = shift;
	route( "$NEXT$path.json", file => "discovery/nextdata-section-$SECTION_FILE{$path}.trimmed.json", headers => $JSON_TYPE );
}

sub route_json {
	my ( $match, $data, %opt ) = @_;
	route( $match, code => 200, headers => $JSON_TYPE, content => to_json($data), %opt );
}

sub page_with { return { pageProps => { data => { componentsContent => [@_] } } } }

sub card {
	my ( $uri, %more ) = @_;
	return { contentUri => $uri, cardTitle => 'Card ' . ( $uri =~ m{/([0-9]+)\z} )[0], %more };
}

sub run {
	my ( $fn, @args ) = @_;
	my $c = collector();
	$COL->$fn( @args, $c->cb );
	return $c;
}

sub page_of {
	my $path = shift;
	my $c    = run( 'page', $path );
	is( $c->count, 1, "page($path): one callback" );
	return ( $c->args(0) )[0];
}

sub feed {
	my ( $code, @passthrough ) = @_;
	my $c = collector();
	$code->( $CLIENT, $c->cb, {}, @passthrough );
	return $c;
}

sub items_of { my ($r) = $_[0]->args(0); return ref $r eq 'HASH' ? $r->{items} : undef }

sub titles { [ map { $_->{title} } @{ $_[0]->{collections} } ] }
sub ids    { [ map { $_->{id} } @{ $_[0]->{collections} } ] }

sub debug_logged    { grep { $_->{level} eq 'DEBUG' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub problems_logged { grep { $_->{level} =~ /WARN|ERROR/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

sub with_debug {
	my $code = shift;
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';
	return $code->();
}

sub epg_route {
	my ( $id, $file, %opt ) = @_;
	route( "${BFF}epgNowPlaying/$id/now?imageRatio=1x1", file => "live/$file", headers => $JSON_TYPE, %opt );
}

# ---------------------------------------------------------------------------
# page() on the section fixtures
# ---------------------------------------------------------------------------

subtest 'News: MiniEPG -> stations (NEWS); 9 StandardCollections in page order; AppStoreCTA skipped' => sub {
	fresh();
	route_section('/listen/news');
	my $page = with_debug( sub { page_of('/listen/news') } );

	is_deeply(
		$page->{stations},
		[ { serviceId => 'NEWS', title => 'Continuous News', start => 1_792_350_000, end => 1_792_407_600, component => 'MiniEPG' } ],
		'one station: papiServiceId NEWS, the MiniEPG title, start/end as epochs (2026-10-18T19:00Z, 2026-10-19T11:00Z)'
	);
	is_deeply(
		titles($page),
		[ 'Latest News', 'Daily Programs', 'Beyond The Headlines', 'ABC News Daily', 'Latest Current Affairs', 'Featured Podcasts', 'News from Radio National', 'Latest from NewsRadio', 'Regional & Rural News' ],
		'the 9 collections, in page order'
	);
	is_deeply( $page->{stationCards} || {}, {}, 'no station-only collection' );
	is( scalar( grep { $_->{message} =~ /ignoring component/ } debug_logged() ), 0, 'MiniEPG and AppStoreCTA are known components (no "ignoring" line)' );
};

subtest 'Sport: "Radio Stations" -> stationCards (externallink, hosts with and without www); LiveRadioCarousel cards[] -> stations with heading; Promo skipped' => sub {
	fresh();
	route_section('/listen/sport');
	my $page = with_debug( sub { page_of('/listen/sport') } );

	is_deeply( titles($page), [ 'Radio Stations', 'Best of ABC Sport', 'Latest Cricket', 'Rugby League World Cup', 'Programs', 'Off Season' ], 'collections in page order (Promo, carousel, AppStoreCTA are not collections)' );
	is_deeply( [ keys %{ $page->{stationCards} } ], ['107158694'], 'only "Radio Stations" is station-only' );
	is_deeply(
		[ map { $_->{path} } @{ $page->{stationCards}->{107158694} } ],
		[ map {"/listen/live/$_"} qw(sport sportrapid sportextra cricket worldcup worldcuprapid aflw) ],
		'its 7 externallink cards in order (https://abc.net.au/... links map like www ones)'
	);
	is_deeply(
		[ map { [ $_->{serviceId}, $_->{component}, $_->{heading} ] } @{ $page->{stations} } ],
		[ [ 'GRANDSTAND', 'LiveRadioCarousel', 'Live & Upcoming Events' ], [ 'ABCSPORTSYNC', 'LiveRadioCarousel', 'Live & Upcoming Events' ] ],
		'carousel cards (componentProps.cards[]) -> stations, keeping the heading'
	);
	is( $page->{stations}->[0]->{title}, 'Men’s International Cricket 2nd Test, Day 2: South Africa v Australia', 'the event title' );
	is_deeply( [ @{ $page->{stations}->[0] }{qw(start end)} ], [ 1_792_395_000, 1_792_425_600 ], 'start/end epochs' );
	is_deeply( [ map { ( $_->{message} =~ /component (\S+)/ )[0] } grep { $_->{message} =~ /ignoring component/ } debug_logged() ], ['Promo'], 'Promo skipped with one DEBUG line' );
	is( scalar problems_logged(), 0, 'no WARN/ERROR' );
};

subtest 'Kids listen: untitled hero kept (title undef -> "Featured" link); AppOnwardJourney skipped' => sub {
	fresh();
	route_section('/kidslisten');
	my $page = page_of('/kidslisten');

	is_deeply( ids($page), [qw(9317798 9317620)], 'hero 9317798, then Latest Programs 9317620' );
	is( $page->{collections}->[0]->{title}, undef, 'the hero has no title' );
	like( $page->{collections}->[0]->{image}, qr/57d20113b44f1d8459aa775ffce912eb/, 'image of its first supported card (an audioepisode; the article card is skipped)' );
	my $link = $COL->collectionItem( $CLIENT, $page->{collections}->[0], 0 );
	is( $link->{name}, string('PLUGIN_ABCLISTEN_FEATURED'), 'collectionItem names it "Featured" (D1 token), never blank' );
	ok( !$page->{stations}, 'no stations key (the live station is static, D4 Sections)' );
};

subtest 'Kids listen programs: ProgramAggregationCollection -> { id, title, image, kind => aggregation }; "People" (person cards) omitted' => sub {
	fresh();
	route_section('/kidslisten/programs');
	my $page = page_of('/kidslisten/programs');

	is( scalar @{ $page->{collections} }, 1, 'one collection' );
	my $col = $page->{collections}->[0];
	is_deeply( [ @$col{qw(id title kind)} ], [ '9317914', 'Programs', 'aggregation' ], 'id from contentUri (no componentProps.id), title from heading, kind aggregation' );
	like( $col->{image}, qr/f145fc77c718224c5ec9a81b4122ba23.*width=300/, 'first program card\'s image at 300 px' );
};

subtest 'Audiobooks: MetaCollection -> its 9 non-empty sub-collections in order; TeaserNavigator, Promo skipped' => sub {
	fresh();
	route_section('/listen/audiobooks');
	my $page = with_debug( sub { page_of('/listen/audiobooks') } );

	is_deeply(
		[ map { [ $_->{id}, $_->{title} ] } @{ $page->{collections} } ],
		[
			[ 105672994 => 'Most Popular' ], [ 107282012 => 'Top 100 Australian Books' ], [ 105611690 => 'Crime & Thriller' ],
			[ 106929080 => 'Audio Dramas' ], [ 105888784 => 'Popular Fiction' ], [ 106028888 => 'Timeless Audiobooks' ],
			[ 106510880 => 'Books for Kids' ], [ 105637010 => 'Beyond The Book' ], [ 105707526 => 'Programs For Book Lovers' ],
		],
		'Live Events and the untitled sub-collection (itemsCount 0) are omitted'
	);
	is_deeply( [ sort keys %{ $page->{collections}->[0] } ], [qw(id image title)], 'keys id, title, image' );
	is( $page->{collections}->[0]->{image}, undef, 'no embedded cards: no image (the link gets the plugin icon)' );
	is( $COL->collectionItem( $CLIENT, $page->{collections}->[0], 0 )->{image}, $ICON, '... the plugin icon' );
	is_deeply( [ sort map { ( $_->{message} =~ /component (\S+)/ )[0] } grep { $_->{message} =~ /ignoring component/ } debug_logged() ], [qw(Promo TeaserNavigator)], 'Promo and TeaserNavigator: one DEBUG line each' );
};

subtest 'Home is unchanged: same collections and hero as D1; the carousel only adds a stations key Home ignores' => sub {
	fresh();
	route( "$NEXT/listen.json", file => 'discovery/nextdata-listen-home.trimmed.json', headers => $JSON_TYPE );
	my ($page) = run('home')->args(0);

	is_deeply(
		titles($page),
		[ "Today's Top Picks", 'Top 100 Australian Books', 'Radio Stations', 'Latest News', 'Most Popular Podcasts', 'True Crime & Investigations', 'Health & Wellbeing', 'Society & Culture', 'Music For Every Mood', 'Looking For Something New?', 'Relax & Sleep', 'Categories' ],
		'D1\'s home collections'
	);
	is( scalar @{ $page->{hero} }, 4, 'hero unchanged' );
	ok( !grep( { exists $_->{kind} } @{ $page->{collections} } ), 'no kind on Home collections' );
	is_deeply( [ sort keys %$page ], [qw(collections hero stale stationCards stations)], 'new keys only: stations, stationCards' );
};

# ---------------------------------------------------------------------------
# Synthetic edge cases
# ---------------------------------------------------------------------------

subtest 'synthetic: unknown components, empty / count-less MetaCollections, papiServiceId cases' => sub {
	fresh();
	route_json( "$NEXT/x.json", page_with(
		{ component => 'Tracklist',      componentProps => {} },
		{ component => 'SomethingNew',   componentProps => { items => [ card('coremedia://audio/1') ] } },
		{ component => 'MetaCollection', componentProps => {} },
		{ component => 'MetaCollection', componentProps => { items => [
			{ id => '11', title => 'Empty', itemsCount => 0 },
			{ id => '12', title => 'No count' },
			{ id => 'x13', title => 'Bad id', itemsCount => 3 },
			{ id => '14', title => '', itemsCount => 2 },
			'junk',
		] } },
		{ component => 'MiniEPG', componentProps => { title => 'No service' } },
		{ component => 'MiniEPG', componentProps => { papiServiceId => 'bad id!', title => 'Bad' } },
		{ component => 'LiveRadioCarousel', componentProps => { heading => '', cards => [
			{ papiServiceId => 'itinerant_four', title => 'Test cricket', start => 'not a date', end => '2026-10-19T16:00:00+00:00' },
			{ title => 'No service' },
		] } },
		{ component => 'ProgramAggregationCollection', key => '21', componentProps => { heading => 'Nothing supported', items => [ card('coremedia://person/2') ] } },
		{ component => 'ProgramAggregationCollection', componentProps => { contentUri => 'coremedia://collection/22', title => 'Titled', items => [ card( 'coremedia://program/3', articleLink => '/listen/programs/three/' ) ] } },
	) );

	my $page = with_debug( sub { page_of('/x') } );
	is_deeply(
		[ map { [ $_->{id}, $_->{title}, $_->{kind} ] } @{ $page->{collections} } ],
		[ [ '12', 'No count', undef ], [ '14', undef, undef ], [ '22', 'Titled', 'aggregation' ] ],
		'itemsCount 0 dropped, missing itemsCount kept, non-numeric id dropped, empty title -> undef; an aggregation without a supported card is omitted, one with a title keeps it'
	);
	is_deeply(
		$page->{stations},
		[ { serviceId => 'ITINERANT_FOUR', title => 'Test cricket', start => undef, end => 1_792_425_600, component => 'LiveRadioCarousel', heading => undef } ],
		'lower-case papiServiceId upper-cased; missing or malformed ids dropped; empty heading undef; a bad date undef'
	);
	is_deeply( [ sort map { ( $_->{message} =~ /component (\S+)/ )[0] } grep { $_->{message} =~ /ignoring component/ } debug_logged() ], [qw(SomethingNew Tracklist)], 'unknown components: DEBUG once each' );
	is( scalar problems_logged(), 0, 'no WARN/ERROR' );
};

# ---------------------------------------------------------------------------
# aggregationItems and %FETCHERS
# ---------------------------------------------------------------------------

my $AGG_URL = "${BFF}programAggregationCollection/x?collectionId=9317914&offset=0&size=50";

subtest 'aggregationItems: request shape, items() result shape, 6 h cache, errors' => sub {
	fresh();
	route( $AGG_URL, file => 'discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json', headers => $JSON_TYPE );

	my $c = run( 'aggregationItems', 9317914, 0, 50 );
	is( $c->count, 1, 'one callback' );
	my ($result) = $c->args(0);
	is_deeply( [ map { $_->{url} } requests() ], [$AGG_URL], 'GET core-next/api/programAggregationCollection/x?collectionId=9317914&offset=0&size=50' );
	is_deeply( [ @$result{qw(title total count)} ], [ 'Programs', 34, 34 ], 'title from heading, total 34, 34 cards' );
	is_deeply( [ map { $_->{title} } @{ $result->{cards} }[ 0 .. 2 ] ], [ 'Bangers & Mash-Ups', 'Bedtime Stories', 'Bedtime Stories with R.A. Spratt' ], 'program cards, A–Z as ABC orders them' );
	is( $result->{cards}->[0]->{type}, 'program', 'program refs' );

	advanceTime( 6 * 3600 - 1 );
	run( 'aggregationItems', 9317914, 0, 50 );
	is( scalar requests(), 1, 'cached for 6 h' );
	advanceTime(2);
	run( 'aggregationItems', 9317914, 0, 50 );
	is( scalar requests(), 2, 'then fetched again' );

	fresh();
	route( $AGG_URL, code => 500, content => 'oops' );
	is_deeply( [ run( 'aggregationItems', 9317914, 0, 50 )->args(0) ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'error -> LOAD_FAILED, once' );
	is_deeply( [ run( 'aggregationItems', 'abc', 0, 50 )->args(0) ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'a bad id -> LOAD_FAILED without a request' );
	is( scalar( grep { $_->{url} =~ /collectionId=abc/ } requests() ), 0, 'no request for it' );
};

subtest '%FETCHERS / menuPage: kind => aggregation pages 50 at a time with programAggregationCollection/x; other kinds 20 with collection/x' => sub {
	fresh();
	route( $AGG_URL, file => 'discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json', headers => $JSON_TYPE );

	my $link = $COL->collectionItem( $CLIENT, { id => '9317914', title => 'All Kids listen programs', kind => 'aggregation' }, 0 );
	is( $link->{passthrough}->[0]->{kind}, 'aggregation', 'the kind travels in the passthrough' );

	my $items = items_of( feed( $link->{url}, @{ $link->{passthrough} } ) );
	is( scalar @$items, 34, 'All Kids listen programs: the 34 programs in one A–Z list (no More…)' );
	is( $items->[0]->{passthrough}->[0]->{path}, '/kidslisten/programs/bangers-and-mash-ups', 'program rows (O2 programItem)' );
	is( scalar( grep { $_->{url} =~ m{/collection/x} } requests() ), 0, 'never collection/x' );

	fresh();
	my @fifty = map { card( "coremedia://program/$_", articleLink => "/kidslisten/programs/p$_/" ) } 1 .. 50;
	route_json( "${BFF}programAggregationCollection/x?collectionId=8&offset=0&size=50",  { collection => { heading => 'Big', pagination => { total => 51 }, items => \@fifty } } );
	route_json( "${BFF}programAggregationCollection/x?collectionId=8&offset=50&size=50", { collection => { heading => 'Big', pagination => { total => 51 }, items => [ card( 'coremedia://program/51', articleLink => '/kidslisten/programs/p51/' ) ] } } );
	$link  = $COL->collectionItem( $CLIENT, { id => '8', title => 'Big', kind => 'aggregation' }, 0 );
	$items = items_of( feed( $link->{url}, @{ $link->{passthrough} } ) );
	is_deeply( [ scalar @$items, $items->[-1]->{name} ], [ 51, $MORE ], 'more than 50: 50 + More…' );
	my $more = items_of( feed( $items->[-1]->{url}, @{ $items->[-1]->{passthrough} } ) );
	is( scalar @$more, 1, 'the next page (offset 50) through the same fetcher; last page: no More…' );

	my $c = collector();
	$COL->menuPage( { id => '8', kind => 'aggregation' }, 0, $c->cb );
	is( ( $c->args(0) )[0]->{count}, 50, 'menuPage(\%collection, $offset, $cb): the menu\'s page (served from the same cache)' );
	is( scalar( grep { $_->{url} =~ /collectionId=8&offset=0/ } requests() ), 1, '... no second request' );

	fresh();
	for my $kind ( undef, 'unknown-kind' ) {
		Slim::Networking::SimpleAsyncHTTP->reset;
		route_json( "${BFF}collection/x?collectionId=5&offset=0&size=20", { collection => { title => 'Five', pagination => { total => 1 }, items => [ card( 'coremedia://program/9', articleLink => '/listen/programs/nine/' ) ] } } );
		my $plain = $COL->collectionItem( $CLIENT, { id => 5, title => 'Five', ( defined $kind ? ( kind => $kind ) : () ) }, 0 );
		is( scalar @{ items_of( feed( $plain->{url}, @{ $plain->{passthrough} } ) ) }, 1, 'kind ' . ( $kind // 'none' ) . ': items() (collection/x, 20 per page)' );
	}

	# the fetchers look items / aggregationItems up when called: a replaced function is the one used
	fresh();
	my @calls;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::items            = sub { push @calls, [ items => @_[ 0, 1, 2, 4 ] ]; $_[3]->( { count => 0, cards => [] } ) };
		local *Plugins::ABCListen::Collections::aggregationItems = sub { push @calls, [ aggregationItems => @_[ 0, 1, 2, 4 ] ]; $_[3]->( { count => 0, cards => [] } ) };
		$COL->menuPage( { id => '5', query => { rootMetaCollectionId => '7' } }, 20, sub { } );
		$COL->menuPage( { id => '8', kind => 'aggregation' }, 0, sub { } );
	}
	is_deeply( \@calls, [ [ 'items', '5', 20, 20, { rootMetaCollectionId => '7' } ], [ 'aggregationItems', '8', 0, 50, undef ] ], 'menuPage calls a replaced items / aggregationItems (late binding), with the collection\'s query' );
	is( scalar requests(), 0, 'no request' );
};

# ---------------------------------------------------------------------------
# D1 review amendments
# ---------------------------------------------------------------------------

subtest 'amendment 1: station cards are looked up by path (L1 owns the rules); /news is not NewsRadio' => sub {
	fresh();
	my $url = sub {
		my $item = $COL->itemFor( $CLIENT, Plugins::ABCListen::API::cardRef( card(@_) ), 1 );
		return $item ? $item->{url} : undef;
	};

	is( $url->( 'coremedia://externallink/1', articleLink => 'https://www.abc.net.au/listen/news' ), 'abclisten://live/NEWS', '/listen/news (externallink, no /live/ segment) -> NEWS' );
	is( $BY_PAGE_SLUG[-1], '/listen/news', 'byPageSlug got the site path' );
	is( $url->( 'coremedia://channel/2', articleLink => 'https://www.abc.net.au/news/' ), undef, '/news (the ABC News website) -> no station' );
	is( $url->( 'coremedia://externallink/3', articleLink => 'https://abc.net.au/listen/live/worldcup' ), 'abclisten://live/SPORT_WORLDCUP', 'abc.net.au without www' );
	is( $url->( 'coremedia://externallink/4', articleLink => 'https://www.abc.net.au/listen/live/sportrapid' ), undef, 'HLS-only (ABC SPORT RAPID): stationItem undef -> no row' );
	is( $url->( 'coremedia://externallink/5', articleLink => 'https://www.abc.net.au/listen/radio#find-your-local-station' ), undef, 'a link that is no station' );
	ok( !defined &Plugins::ABCListen::Collections::_slugCandidates, 'no slug guessing left in Collections' );
};

subtest 'amendment 2: itemsFor checks event-only services on air (checkOnAir) before stationItem' => sub {
	my @refs = map { Plugins::ABCListen::API::cardRef( card( "coremedia://externallink/$_->[0]", articleLink => "https://www.abc.net.au/listen/live/$_->[1]" ) ) } [ 1, 'sport' ], [ 2, 'bbl' ];

	fresh();
	epg_route( 'SPORT_BBL', 'epg-event-onair-pls.json' );
	my $c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	is( $c->count, 1, 'one callback' );
	is_deeply( [ map { $_->{url} } @{ ( $c->args(0) )[0] } ], [qw(abclisten://live/GRANDSTAND abclisten://live/SPORT_BBL)], 'BBL on air: listed (it would be dropped without the check)' );
	is_deeply( \@CHECK_ON_AIR, [ ['SPORT_BBL'] ], 'Stations->checkOnAir with the event-only services only' );

	fresh();
	epg_route( 'SPORT_BBL', 'bff-epgNowPlaying-SPORT_BBL-now.json' );
	$c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	is_deeply( [ map { $_->{url} } @{ ( $c->args(0) )[0] } ], ['abclisten://live/GRANDSTAND'], 'BBL off air (null): left out' );

	fresh();
	epg_route( 'SPORT_BBL', 'epg-event-onair-pls.json', defer => 1 );
	$c = run( 'itemsFor', $CLIENT, \@refs, 1 );
	is( $c->count, 0, 'waits for the status' );
	advanceTime(2.9);
	is( $c->count, 0, 'still at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at the 3 s deadline' );
	is_deeply( [ map { $_->{url} } @{ ( $c->args(0) )[0] } ], ['abclisten://live/GRANDSTAND'], 'unknown status: left out' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'a late status never calls back again' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left' );
	is( scalar( grep { $_->{url} =~ /SPORT_BBL/ } @{ ( run( 'itemsFor', $CLIENT, \@refs, 1 )->args(0) )[0] } ), 1, 'next open: the late status (on air) is cached' );

	fresh();
	$c = run( 'itemsFor', $CLIENT, [ $refs[0] ], 1 );
	is( $c->count, 1, 'no event-only service: synchronous' );
	is( scalar @CHECK_ON_AIR, 0, '... and no check' );

	fresh();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Stations::checkOnAir = sub { die "status broke\n" };
		$c = run( 'checkOnAir', ['SPORT_BBL'] );
	}
	is( $c->count, 1, 'checkOnAir: Stations dying -> still exactly one callback' );
	is( scalar Slim::Utils::Timers::pending(), 0, '... and no timer left' );
	{
		local *Plugins::ABCListen::Stations::checkOnAir;
		is( run( 'checkOnAir', ['SPORT_BBL'] )->count, 1, 'no Stations->checkOnAir: answers at once' );
	}
};

subtest 'amendment 4: public functions also work as plain functions' => sub {
	fresh();
	my $ref = Plugins::ABCListen::API::cardRef( card( 'coremedia://audioepisode/7', articleLink => '/listen/programs/x/seven/7' ) );

	is( Plugins::ABCListen::Collections::itemFor( $CLIENT, $ref, 1 )->{play}, 'abclisten://episode/7', 'itemFor($client, ...)' );
	is( Plugins::ABCListen::Collections::itemFor( undef, $ref, 1 )->{play}, 'abclisten://episode/7', 'itemFor(undef, ...)' );
	is( Plugins::ABCListen::Collections::collectionItem( undef, { id => 3, title => 'Three' }, 0 )->{name}, 'Three', 'collectionItem(undef, ...)' );

	my $c = collector();
	Plugins::ABCListen::Collections::itemsFor( $CLIENT, [$ref], 1, $c->cb );
	is( ( $c->args(0) )[0]->[0]->{play}, 'abclisten://episode/7', 'itemsFor($client, ...)' );

	$c = collector();
	Plugins::ABCListen::Collections::checkOnAir( [], $c->cb );
	is( $c->count, 1, 'checkOnAir(\@ids, $cb)' );
};

done_testing();
