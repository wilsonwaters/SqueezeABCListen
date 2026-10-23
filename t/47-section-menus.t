#!/usr/bin/perl
# Plugins::ABCListen::Sections (D4: the top-level News, Sport, Kids listen and Audiobooks menus),
# offline (SimpleAsyncHTTP stub fails any unrouted URL; fake clock): the four top-level items (exact
# keys, weights, order, menuWeights, no network) and their place in Discover and the top level; each
# section's row order (live stations -> event links -> page collections -> static extras) with
# recording wrappers around L1's Live->stationItem, O2's programItem and O3's programsByType;
# stationItem undef -> row left out; Kids listen variants only when defined; Sport's inline "Radio
# Stations" and "Live & Upcoming Events" (line2, time range, event-only services); the Kids listen
# extras (prefetched first pages: images, ABC's title, fallbacks; menus served from that cache; at
# most 3 s for them);
# Audiobooks without O3; page failures (stations + extras + the error item; never empty); exactly
# one callback on every path; dying callbacks; menu shapes and readable names; $client undef.
#
# Fixtures: t/data/discovery/nextdata-section-*.trimmed.json (see t/46-sections.t),
# bff-programAggregationCollection-9317914-kidslisten-programs-size50.json,
# bff-collection-104141842-kids-families.trimmed.json (Kids & Families podcasts, items cut to 3,
# total 52), bff-collection-106510880-books-for-kids.json (all 7) - fresh captures 2026-10-19,
# srcSet cut to 1, analytics dropped; t/data/live/ event status fixtures (L1).

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
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Search;
use Plugins::ABCListen::Sections;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $SEC         = 'Plugins::ABCListen::Sections';
my $COL         = 'Plugins::ABCListen::Collections';
my $STATIONS    = 'Plugins::ABCListen::Stations';
my $SITE        = 'https://www.abc.net.au';
my $BFF         = "$SITE/core-next/api/";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $T0          = 1_792_400_000;
my $ICON        = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $CLIENT      = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $COLL_MENU   = \&Plugins::ABCListen::Collections::_collectionMenu;
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE        = string('PLUGIN_ABCLISTEN_MORE');
my $AU_ONLY     = string('PLUGIN_ABCLISTEN_AUDIOBOOKS_AU_ONLY');
my $AZ          = string('PLUGIN_ABCLISTEN_AUDIOBOOKS_AZ');

my %MENU = (
	news       => \&Plugins::ABCListen::Sections::_newsMenu,
	sport      => \&Plugins::ABCListen::Sections::_sportMenu,
	kids       => \&Plugins::ABCListen::Sections::_kidsMenu,
	audiobooks => \&Plugins::ABCListen::Sections::_audiobooksMenu,
);
my %PATH = ( news => '/listen/news', sport => '/listen/sport', kids => '/kidslisten', audiobooks => '/listen/audiobooks' );
my %FILE = ( news => 'news', sport => 'sport', kids => 'kidslisten', audiobooks => 'audiobooks' );

my @NEWS_TITLES = ( 'Latest News', 'Daily Programs', 'Beyond The Headlines', 'ABC News Daily', 'Latest Current Affairs', 'Featured Podcasts', 'News from Radio National', 'Latest from NewsRadio', 'Regional & Rural News' );
my @AUDIOBOOK_TITLES = ( 'Most Popular', 'Top 100 Australian Books', 'Crime & Thriller', 'Audio Dramas', 'Popular Fiction', 'Timeless Audiobooks', 'Books for Kids', 'Beyond The Book', 'Programs For Book Lovers' );
my @KIDS_NAMES = ( 'ABC KIDS listen', 'Featured', 'Latest Programs', 'All Kids listen programs', 'Kids & Families podcasts', 'Books for Kids', 'News Time' );

my $AGG_URL   = "${BFF}programAggregationCollection/x?collectionId=9317914&offset=0&size=50";
my $KIDS_POD  = "${BFF}collection/x?collectionId=104141842&offset=0&size=20";
my $KIDS_BOOK = "${BFF}collection/x?collectionId=106510880&offset=0&size=20";

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- recording wrappers (the real L1 / O2 builders unless told otherwise) ----

my ( @STATION_ITEM, @PROGRAM_ITEM, @BY_TYPE, %FORCE_STATION );
{
	no warnings qw(redefine once);
	my $stationItem = \&Plugins::ABCListen::Live::stationItem;
	my $programItem = \&Plugins::ABCListen::OnDemand::programItem;
	*Plugins::ABCListen::Live::stationItem = sub {
		my ( $class, $client, $id ) = @_;
		push @STATION_ITEM, $id;
		if ( exists $FORCE_STATION{$id} ) {
			return undef unless $FORCE_STATION{$id};
			my $url = "abclisten://live/$id";
			return { name => $FORCE_STATION{$id}, line1 => $FORCE_STATION{$id}, type => 'audio', on_select => 'play', url => $url, favorites_url => $url, image => $ICON };
		}
		goto &$stationItem;
	};
	*Plugins::ABCListen::OnDemand::programItem    = sub { push @PROGRAM_ITEM, { %{ $_[2] } }; goto &$programItem };
	*Plugins::ABCListen::OnDemand::programsByType = sub {
		my ( $class, $client, $cb, $type ) = @_;
		push @BY_TYPE, [ $client, $type ];
		$cb->( [ { name => 'The Dictionary of Lost Words', type => 'link', url => sub { } } ] );
	};
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	$STATIONS->_reset;
	$STATIONS->_setRecords;
	@STATION_ITEM = @PROGRAM_ITEM = @BY_TYPE = ();
	%FORCE_STATION = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

sub route_section {
	my ( $key, %opt ) = @_;
	route( "$NEXT$PATH{$key}.json", file => "discovery/nextdata-section-$FILE{$key}.trimmed.json", headers => $JSON_TYPE, %opt );
}

sub route_kids_extras {
	my %opt = @_;
	route( $AGG_URL,   file => 'discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json', headers => $JSON_TYPE, %opt );
	route( $KIDS_POD,  file => 'discovery/bff-collection-104141842-kids-families.trimmed.json',                    headers => $JSON_TYPE, %opt );
	route( $KIDS_BOOK, file => 'discovery/bff-collection-106510880-books-for-kids.json',                           headers => $JSON_TYPE, %opt );
}

sub route_page_json {
	my ( $key, @components ) = @_;
	route( "$NEXT$PATH{$key}.json", code => 200, headers => $JSON_TYPE, content => to_json( { pageProps => { data => { componentsContent => \@components } } } ) );
}

sub open_feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item { my ( $item, $client ) = @_; return open_feed( $item->{url}, $client, @{ $item->{passthrough} || [] } ) }

sub items_of {
	my ($r) = $_[0]->args(0);
	return ref $r eq 'HASH' ? $r->{items} : ref $r eq 'ARRAY' ? $r : undef;
}

# Open a section root; asserts one callback; returns its items.
sub section {
	my ( $key, $client ) = @_;
	my $c = open_feed( $MENU{$key}, @_ > 1 ? $client : $CLIENT );
	is( $c->count, 1, "$key: one callback" );
	return items_of($c);
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }
sub named { my ( $items, $name ) = @_; my ($item) = grep { $_->{name} eq $name } @$items; return $item }

sub check_shapes {
	my ( $items, $label ) = @_;
	my @bad = grep { !( defined $_->{name} && !ref $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( scalar @bad, 0, "$label: every row has a readable, non-empty text name" );
	is( scalar( grep { $_->{type} ne 'audio' && exists $_->{description} } @$items ), 0, "$label: no description on a non-audio row (LMS menu rule 1)" );
	is( scalar( grep { $_->{type} eq 'audio' && !( ( $_->{url} // '' ) =~ m{\Aabclisten://live/[A-Z0-9_]+\z} && $_->{favorites_url} eq $_->{url} && ( $_->{on_select} // '' ) eq 'play' ) } @$items ), 0,
		"$label: station rows play abclisten://live/<ID> and favourite that URL" );
	is( scalar( grep { exists $_->{play} && $_->{play} =~ m{\Aabclisten://live/} && !( $_->{type} eq 'playlist' && ref $_->{url} eq 'CODE' && $_->{favorites_url} eq $_->{play} && !exists $_->{on_select} ) } @$items ), 0,
		"$label: L4 station rows (type playlist + play) open a feed and favourite their abclisten://live/<ID> play URL, no on_select" );
	is( scalar( grep { $_->{type} eq 'link' && !( ref $_->{url} eq 'CODE' || ref $_->{items} eq 'ARRAY' ) } @$items ), 0, "$label: links open a feed or a list" );
	is( scalar( grep { $_->{type} eq 'text' && ( exists $_->{url} || exists $_->{play} ) } @$items ), 0, "$label: text rows have no action" );
	is( scalar( grep { $_->{type} ne 'text' && !$_->{image} } @$items ), 0, "$label: artwork on every station / link row" );
}

sub requests_like { my $re = shift; return grep { $_->{url} =~ $re } requests() }

sub errors_logged { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub problems      { grep { $_->{level} =~ /WARN|ERROR/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

subtest 'topItems: News, Sport, Kids listen, Audiobooks - exact keys, weights 40/50/60/70, no network; menuWeights' => sub {
	fresh();
	my @top = $SEC->topItems(undef);
	is_deeply(
		\@top,
		[
			{ name => 'News',        type => 'link', url => $MENU{news},       image => $ICON, weight => 40 },
			{ name => 'Sport',       type => 'link', url => $MENU{sport},      image => $ICON, weight => 50 },
			{ name => 'Kids listen', type => 'link', url => $MENU{kids},       image => $ICON, weight => 60 },
			{ name => 'Audiobooks',  type => 'link', url => $MENU{audiobooks}, image => $ICON, weight => 70 },
		],
		'exactly { name type url image weight } each, in this order'
	);
	is_deeply( names( \@top ), [ map { string($_) } qw(PLUGIN_ABCLISTEN_NEWS PLUGIN_ABCLISTEN_SPORT PLUGIN_ABCLISTEN_KIDS PLUGIN_ABCLISTEN_AUDIOBOOKS) ], 'names from F1\'s/L1\'s tokens' );
	is_deeply( [ map { $_->{weight} } @top ], [ map { Plugins::ABCListen::Util::topWeight($_) } qw(news sport kids audiobooks) ], 'weights from Util::topWeight' );
	is_deeply( [ $SEC->menuWeights ], [ 40, 50, 60, 70 ], 'Sections->menuWeights' );
	is_deeply( [ map { $_->{name} } $SEC->topItems($CLIENT) ], names( \@top ), 'with a client too' );

	my $c = collector();
	Plugins::ABCListen::Discover->menuItems( undef, $c->cb, {} );
	is_deeply( [ map { $_->{name} } @{ ( $c->args(0) )[0] } ], [ 'Home', 'Podcasts', 'News', 'Sport', 'Kids listen', 'Audiobooks' ], 'Discover->menuItems: Home, Podcasts (D2), then the four sections' );
	my %weights = map { $_ => 1 } Plugins::ABCListen::Discover->menuWeights;
	ok( $weights{$_}, "Discover->menuWeights includes $_" ) for 40, 50, 60, 70;
	is( scalar requests(), 0, 'no HTTP request' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Sections::topItems = sub { die "sections broke\n" };
		$c = collector();
		Plugins::ABCListen::Discover->menuItems( undef, $c->cb, {} );
	}
	is_deeply( [ map { $_->{name} } @{ ( $c->args(0) )[0] } ], [ 'Home', 'Podcasts' ], 'Sections->topItems dying: Discover still lists Home and Podcasts (logged)' );
	is( scalar( grep { $_->{message} =~ /sections broke/ } errors_logged() ), 1, '... and logs it' );
};

subtest 'top level: Home, Radio, Podcasts, News, Sport, Kids listen, Audiobooks, Programs, Search, My ABC listen' => sub {
	fresh();
	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( undef, $c->cb, { params => {} } );
	is_deeply(
		names( items_of($c) ),
		[ 'Home', 'Radio', 'Podcasts', 'News', 'Sport', 'Kids listen', 'Audiobooks', 'Programs', 'Search', 'My ABC listen' ],
		'sorted by weight between Podcasts (30) and Programs (75)'
	);
	is( scalar requests(), 0, 'no HTTP request for the top level' );
};

# ---------------------------------------------------------------------------
# News
# ---------------------------------------------------------------------------

subtest 'News: ABC NewsRadio first (MiniEPG), then the 9 collections in page order' => sub {
	fresh();
	route_section('news');
	my $items = section('news');

	is_deeply( names($items), [ 'NewsRadio', @NEWS_TITLES ], 'NewsRadio, then the page collections' );
	is_deeply( [ @{ $items->[0] }{qw(type play favorites_url)} ], [ 'playlist', ('abclisten://live/NEWS') x 2 ], 'the station row plays (and favourites) abclisten://live/NEWS (L4: opens and plays, type playlist)' );
	is_deeply( \@STATION_ITEM, ['NEWS'], 'Live->stationItem($client, "NEWS"), once' );
	is( $items->[1]->{url}, $COLL_MENU, 'collection links open D1\'s collection menu' );
	is( $items->[1]->{passthrough}->[0]->{id}, '104903746', '... Latest News (104903746)' );
	check_shapes( $items, 'News' );
	is_deeply( [ map { $_->{url} } requests() ], [ "$SITE/listen/search", "$NEXT/listen/news.json" ], 'one _next/data request (plus the buildId)' );

	fresh();
	route_page_json( 'news', { component => 'StandardCollection', componentProps => { id => '5', title => 'Only', items => [ { contentUri => 'coremedia://audio/6', cardTitle => 'x', articleLink => '/news/2026-10-19/x/6' } ] } } );
	is_deeply( names( section('news') ), [ 'NewsRadio', 'Only' ], 'no MiniEPG: the static NEWS row' );

	fresh();
	route_section('news');
	$FORCE_STATION{NEWS} = undef;
	is_deeply( names( section('news') ), \@NEWS_TITLES, 'stationItem undef (e.g. L1 absent): the row is left out' );
};

# ---------------------------------------------------------------------------
# Sport
# ---------------------------------------------------------------------------

subtest 'Sport: "Radio Stations" inline as station rows; Live & Upcoming Events link; then the collections' => sub {
	fresh();
	route_section('sport');
	my $items = section('sport');

	is_deeply(
		names($items),
		[ 'ABC SPORT', 'ABC SPORT EXTRA', 'ABC Rugby League World Cup', 'ABC AFLW', 'Live & Upcoming Events', 'Best of ABC Sport', 'Latest Cricket', 'Rugby League World Cup', 'Programs', 'Off Season' ],
		'station rows, the events link, then the other 5 collections (no "Radio Stations" link)'
	);
	is_deeply( [ map { $_->{play} } @$items[ 0 .. 3 ] ], [ map {"abclisten://live/$_"} qw(GRANDSTAND ITINERANT_THREE SPORT_WORLDCUP SPORT_AFLW) ], 'their abclisten://live URLs' );
	is( scalar( grep { $_->{name} =~ /RAPID|Rapid|CRICKET/ } @$items ), 0, 'no ABC SPORT RAPID / RLWC Rapid / ABC CRICKET rows (HLS-only: stationItem undef)' );
	ok( ( grep { $_ eq 'ABCSPORTSYNC' } @STATION_ITEM ) && ( grep { $_ eq 'ITINERANT_FOUR' } @STATION_ITEM ), 'stationItem was asked for them' );

	my $events = named( $items, 'Live & Upcoming Events' );
	is( ref $events->{items}, 'ARRAY', 'the events link lists its rows' );
	is( scalar @{ $events->{items} }, 1, 'one playable event station (ABCSPORTSYNC is HLS-only)' );
	my $row   = $events->{items}->[0];
	my $title = 'Men’s International Cricket 2nd Test, Day 2: South Africa v Australia';
	my $window = Plugins::ABCListen::Util::friendlyTime(1_792_395_000) . "\x{2013}" . Plugins::ABCListen::Util::friendlyTime(1_792_425_600);
	is_deeply( [ @$row{qw(name play line2)} ], [ 'ABC SPORT', 'abclisten://live/GRANDSTAND', "$title \x{B7} $window" ], 'a stationItem copy; line2 = "<event title> · <start>–<end>" (L4: the time window a link can\'t carry in a description)' );
	ok( !exists $row->{description}, 'no description: L4 station rows open a menu (LMS menu rule 1)' );
	is( ref $row->{url}, 'CODE', '... so the row still opens its station menu' );
	is( $events->{image}, $row->{image}, 'the link shows the first row\'s artwork' );
	check_shapes( $items, 'Sport' );
	check_shapes( $events->{items}, 'Sport > Live & Upcoming Events' );
	is( scalar( grep { $_->{url} =~ m{/collection/x} } requests() ), 0, 'the station rows come from the page (no collection request)' );
};

subtest 'Sport events: none playable -> no link; event-only services checked on air; each service once per list' => sub {
	my @radio = ( { contentUri => 'coremedia://externallink/1', cardTitle => 'ABC SPORT', articleLink => 'https://www.abc.net.au/listen/live/sport' } );
	my $carousel = sub { { component => 'LiveRadioCarousel', componentProps => { heading => 'Live & Upcoming Events', cards => [@_] } } };
	my $event = sub { my ( $id, $title ) = @_; return { papiServiceId => $id, title => $title, start => '2026-10-19T07:30:00+00:00', end => '2026-10-19T16:00:00+00:00' } };
	my $window = " \x{B7} " . Plugins::ABCListen::Util::friendlyTime(1_792_395_000) . "\x{2013}" . Plugins::ABCListen::Util::friendlyTime(1_792_425_600);

	fresh();
	route_page_json( 'sport', { component => 'StandardCollection', componentProps => { id => '1', title => 'Radio Stations', items => \@radio } }, $carousel->( $event->( 'ABCSPORTSYNC', 'Rapid only' ) ) );
	is_deeply( names( section('sport') ), ['ABC SPORT'], 'no playable event station: no events link' );

	fresh();
	route_page_json( 'sport', $carousel->( $event->( 'sport_bbl', 'BBL 1' ), $event->( 'SPORT_BBL', 'BBL 2' ), $event->( 'GRANDSTAND', 'Cricket' ) ) );
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json', headers => $JSON_TYPE );
	my $items = section('sport');
	is_deeply( [ map { [ $_->{play}, $_->{line2} ] } @{ $items->[0]->{items} } ], [ [ 'abclisten://live/SPORT_BBL', "BBL 1$window" ], [ 'abclisten://live/GRANDSTAND', "Cricket$window" ] ],
		'BBL (event-only, lower-case id) on air: listed once, with its first event; then ABC SPORT' );
	is( scalar requests_like(qr{epgNowPlaying/SPORT_BBL}), 1, 'one on-air check' );

	fresh();
	route_page_json( 'sport', $carousel->( $event->( 'SPORT_BBL', 'BBL' ) ) );
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', headers => $JSON_TYPE, defer => 1 );
	my $c = open_feed( $MENU{sport}, $CLIENT );
	is( $c->count, 0, 'waits for the on-air check' );
	advanceTime(3);
	is( $c->count, 1, 'answers at the 3 s deadline' );
	is_deeply( items_of($c), [ { name => $EMPTY, type => 'text' } ], 'off air / unknown: no link; nothing else to list -> a readable "nothing here" item' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'still one callback' );

	fresh();
	route_page_json( 'sport', { component => 'LiveRadioCarousel', componentProps => { cards => [ $event->( 'GRANDSTAND', 'Untitled carousel event' ) ] } } );
	$items = section('sport');
	is_deeply( [ @{ $items->[0] }{qw(play line2)} ], [ 'abclisten://live/GRANDSTAND', "Untitled carousel event$window" ], 'a carousel without a heading: its stations are rows, with the event text' );

	fresh();
	route_page_json( 'sport', $carousel->( { papiServiceId => 'GRANDSTAND', title => 'No times' }, ) );
	$items = section('sport');
	is( $items->[0]->{items}->[0]->{line2}, 'No times', 'an event without start/end: line2 is the title alone' );

	fresh();
	%FORCE_STATION = ( GRANDSTAND => 'ABC SPORT (audio row)' );
	route_page_json( 'sport', { component => 'LiveRadioCarousel', componentProps => { cards => [ $event->( 'GRANDSTAND', 'An event' ) ] } } );
	$items = section('sport');
	is( $items->[0]->{description}, 'An event (' . Plugins::ABCListen::Util::friendlyTime(1_792_395_000) . "\x{2013}" . Plugins::ABCListen::Util::friendlyTime(1_792_425_600) . ')', 'an audio station row still gets the description "<title> (<start>–<end>)"' );
};

# ---------------------------------------------------------------------------
# Kids listen
# ---------------------------------------------------------------------------

subtest 'Kids listen (full section): live station, Featured, Latest Programs, All Kids listen programs, Kids & Families podcasts, Books for Kids, News Time' => sub {
	fresh();
	route_section('kids');
	route_kids_extras();
	my $items = section('kids');

	is_deeply( names($items), \@KIDS_NAMES, 'in this order' );
	is_deeply( [ @{ $items->[0] }{qw(type play favorites_url)} ], [ 'playlist', ('abclisten://live/KIDSLISTEN') x 2 ], 'ABC KIDS listen plays abclisten://live/KIDSLISTEN (L4: opens and plays, type playlist)' );
	is_deeply( \@STATION_ITEM, [qw(KIDSLISTEN KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA)], 'the state versions are asked for too (HLS-only: undef, so not listed)' );

	my %by = map { $_->{name} => $_ } @$items;
	is_deeply( [ map { $by{$_}->{passthrough}->[0]->{id} } 'Featured', 'Latest Programs' ], [qw(9317798 9317620)], 'the page\'s collections: the untitled hero as "Featured", then Latest Programs' );
	is_deeply( $by{'All Kids listen programs'}->{passthrough}->[0], { id => '9317914', title => 'All Kids listen programs', image => $by{'All Kids listen programs'}->{passthrough}->[0]->{image}, kind => 'aggregation' }, 'All Kids listen programs: the program aggregation 9317914' );
	like( $by{'All Kids listen programs'}->{image}, qr/f145fc77c718224c5ec9a81b4122ba23/, '... with its first program\'s artwork' );
	is( $by{'Kids & Families podcasts'}->{passthrough}->[0]->{id}, '104141842', 'Kids & Families podcasts: collection 104141842' );
	like( $by{'Kids & Families podcasts'}->{image}, qr/wcms\.abc-cdn\.net\.au/, '... with artwork' );
	is( $by{'Books for Kids'}->{passthrough}->[0]->{id}, '106510880', 'Books for Kids: the Audiobooks sub-collection 106510880, named with ABC\'s title' );
	my $newsTimeArt = 'https://live-production.wcms.abc-cdn.net.au/316aa1eb12b66a0ef24d30f6455c86ad?impolicy=wcms_crop_resize&cropH=2812&cropW=2812&xPos=1094&yPos=0&width=300&height=300';
	is_deeply( $PROGRAM_ITEM[-1], { title => 'News Time', path => '/kidslisten/programs/news-time', image => $newsTimeArt }, 'News Time: OnDemand->programItem({ title, path, image })' );
	is( $by{'News Time'}->{passthrough}->[0]->{path}, '/kidslisten/programs/news-time', '... opening O2\'s program menu' );
	like( $by{'News Time'}->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/316aa1eb12b66a0ef24d30f6455c86ad\?}, '... with ABC\'s News Time artwork (its card in All Kids listen programs), not the plugin icon' );
	check_shapes( $items, 'Kids listen' );
	is( scalar requests_like(qr{/_next/data/}), 1, 'one _next/data request (the /kidslisten page)' );

	# the extras' menus come from the cache the root warmed
	my $before = scalar requests();
	my $programs = items_of( open_item( $by{'All Kids listen programs'}, $CLIENT ) );
	is( scalar @$programs, 34, 'All Kids listen programs: all 34 programs, one A–Z list in ABC\'s order (aggregations page 50 at a time)' );
	is( scalar( grep { $_->{name} eq $MORE } @$programs ), 0, 'no More…' );
	is( $programs->[1]->{passthrough}->[0]->{path}, '/kidslisten/programs/bedtime-stories', 'e.g. Bedtime Stories -> its program menu (episodes)' );
	my $podcasts = items_of( open_item( $by{'Kids & Families podcasts'}, $CLIENT ) );
	is( $podcasts->[-1]->{name}, $MORE, 'Kids & Families podcasts: a first page + More… (52 in all)' );
	my $books = items_of( open_item( $by{'Books for Kids'}, $CLIENT ) );
	is( scalar @$books, 7, 'Books for Kids: 7 books' );
	is( scalar( grep { $_->{url} =~ m{/(?:collection|programAggregationCollection)/x} } ( requests() )[ $before .. scalar( requests() ) - 1 ] ), 0, 'no new collection request: served from the root\'s prefetch' );
};

subtest 'Kids listen: state versions listed when stationItem defines them; extras fall back to tokens and the icon' => sub {
	fresh();
	route_section('kids');
	route_kids_extras();
	%FORCE_STATION = ( KIDSLISTEN_NT => 'Kids Listen NT', KIDSLISTEN_WA => 'Kids Listen WA' );
	is_deeply( [ @{ names( section('kids') ) }[ 0 .. 3 ] ], [ 'ABC KIDS listen', 'Kids Listen NT', 'Kids Listen WA', 'Featured' ], 'defined versions follow the main station, in order' );

	fresh();
	route_section('kids');
	route( qr{/(?:collection|programAggregationCollection)/x}, code => 500, content => 'oops' );
	my $items = section('kids');
	is_deeply( names($items), \@KIDS_NAMES, 'the extras\' first pages failed: same rows' );
	my %by = map { $_->{name} => $_ } @$items;
	is( $by{'Books for Kids'}->{name}, string('PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS'), 'Books for Kids named by its token' );
	is_deeply( [ map { $by{$_}->{image} } 'All Kids listen programs', 'Kids & Families podcasts', 'Books for Kids' ], [ ($ICON) x 3 ], 'plugin icon' );
	is( $by{'News Time'}->{image}, $ICON, 'News Time without the programs\' first page: the plugin icon' );

	fresh();
	route_section('kids');
	route( $AGG_URL,  file => 'discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json', headers => $JSON_TYPE );
	route( $KIDS_POD, file => 'discovery/bff-collection-104141842-kids-families.trimmed.json',                    headers => $JSON_TYPE );
	route( $KIDS_BOOK, code => 200, headers => $JSON_TYPE, content => to_json( { collection => { title => 'Books for Kids & Teens', pagination => { total => 0 }, items => [] } } ) );
	is( section('kids')->[5]->{name}, 'Books for Kids & Teens', 'ABC renames Books for Kids: its new title is used (only that extra takes ABC\'s title)' );

	fresh();
	route_page_json( 'kids', { component => 'StandardCollection', componentProps => { id => '104141842', title => 'Kids & Families on the page', items => [ { contentUri => 'coremedia://program/1', cardTitle => 'P', articleLink => '/listen/programs/p/' } ] } } );
	route_kids_extras();
	is( scalar( grep { ref $_->{passthrough}->[0] eq 'HASH' && ( $_->{passthrough}->[0]->{id} // '' ) eq '104141842' } @{ section('kids') } ), 1, 'a collection the page lists itself is not repeated as an extra' );
};

subtest 'live stations: a service named by the MiniEPG, the static list and an inline station collection is listed once' => sub {
	fresh();
	route_page_json(
		'kids',
		{ component => 'MiniEPG', componentProps => { papiServiceId => 'kidslisten', title => 'Now on ABC KIDS listen' } },
		{ component => 'StandardCollection', componentProps => { id => '1', title => 'Radio Stations', items => [ { contentUri => 'coremedia://externallink/2', cardTitle => 'ABC KIDS listen', articleLink => 'https://www.abc.net.au/listen/live/kidslisten' } ] } },
	);
	route_kids_extras();
	my $items = section('kids');

	is( scalar( grep { $_ eq 'KIDSLISTEN' } @STATION_ITEM ), 3, 'stationItem built KIDSLISTEN three times: MiniEPG, the static list, the inline collection' );
	is( scalar( grep { ( $_->{play} // '' ) eq 'abclisten://live/KIDSLISTEN' } @$items ), 1, 'one KIDSLISTEN row' );
	is_deeply( names($items), [ 'ABC KIDS listen', @KIDS_NAMES[ 3 .. $#KIDS_NAMES ] ], 'ABC KIDS listen once, then the extras (no "Radio Stations" link)' );

	fresh();
	%FORCE_STATION = ( KIDSLISTEN_NT => 'Kids Listen NT' );
	route_page_json(
		'kids',
		{ component => 'MiniEPG', componentProps => { papiServiceId => 'KIDSLISTEN_NT' } },
		{ component => 'StandardCollection', componentProps => { id => '1', title => 'Radio Stations', items => [ { contentUri => 'coremedia://externallink/2', cardTitle => 'Kids', articleLink => 'https://www.abc.net.au/listen/live/kidslisten' } ] } },
	);
	route_kids_extras();
	is_deeply( [ @{ names( section('kids') ) }[ 0, 1 ] ], [ 'Kids Listen NT', 'ABC KIDS listen' ], 'each once, in first-seen order (MiniEPG, then the static list)' );
};

subtest 'Kids listen: the extras\' first pages are waited for at most 3 s; late ones fall back (and warm the cache)' => sub {
	my $images = sub { my %by = map { $_->{name} => $_ } @{ $_[0] }; return [ map { $by{$_}->{image} } 'All Kids listen programs', 'Kids & Families podcasts', $_[1] // 'Books for Kids' ] };
	my $AGG_ART = qr/f145fc77c718224c5ec9a81b4122ba23/;

	fresh();
	route_section('kids');
	route_kids_extras( defer => 1 );
	my $c = open_feed( $MENU{kids}, $CLIENT );
	is( $c->count, 0, 'the page is in: waits for the extras' );
	advanceTime(2);
	is( $c->count, 0, '... for up to 3 s' );
	advanceTime(1);
	is( $c->count, 1, 'answers at the 3 s deadline (not the API\'s 8 s timeout)' );
	my $items = items_of($c);
	is_deeply( names($items), [ @KIDS_NAMES[ 0 .. 3 ], 'Kids & Families podcasts', string('PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS'), 'News Time' ], 'the same rows, the late extras named by their tokens' );
	is_deeply( $images->( $items, string('PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS') ), [ ($ICON) x 3 ], 'late extras: the plugin icon' );
	check_shapes( $items, 'Kids listen (late extras)' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred while Slim::Networking::SimpleAsyncHTTP->deferred;
	runTimers();
	is( $c->count, 1, 'the late answers: still one callback' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer left behind' );

	my $before = scalar requests();
	$c = open_feed( $MENU{kids}, $CLIENT );
	is( $c->count, 1, 'next open: answers at once (the late answers warmed the cache)' );
	like( $images->( items_of($c) )->[0], $AGG_ART, '... with the extras\' artwork' );
	is( scalar requests(), $before, '... without a request' );

	fresh();
	route_section('kids');
	route( $AGG_URL,  file => 'discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json', headers => $JSON_TYPE );
	route( $KIDS_POD, file => 'discovery/bff-collection-104141842-kids-families.trimmed.json',                    headers => $JSON_TYPE );
	route( $KIDS_BOOK, file => 'discovery/bff-collection-106510880-books-for-kids.json', headers => $JSON_TYPE, defer => 1 );
	$c = open_feed( $MENU{kids}, $CLIENT );
	is( $c->count, 0, 'two extras in, one pending: waits' );
	advanceTime(3);
	is( $c->count, 1, 'answers at the deadline' );
	my $got = $images->( items_of($c), string('PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS') );
	like( $got->[0], $AGG_ART, 'in time: All Kids listen programs has its artwork' );
	like( $got->[1], qr/wcms\.abc-cdn\.net\.au/, 'in time: Kids & Families podcasts too' );
	is( $got->[2], $ICON, 'late: Books for Kids has the plugin icon' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred while Slim::Networking::SimpleAsyncHTTP->deferred;
	is( $c->count, 1, 'still one callback' );

	fresh();
	route_section( 'kids', defer => 1 );
	route_kids_extras();
	$c = open_feed( $MENU{kids}, $CLIENT );
	advanceTime(5);
	is( $c->count, 0, 'the page itself is always waited for (its own API timeout)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred while Slim::Networking::SimpleAsyncHTTP->deferred;
	runTimers();
	is( $c->count, 1, 'answers when the page is in' );
	is_deeply( names( items_of($c) ), \@KIDS_NAMES, 'with the extras that came in time' );
	like( $images->( items_of($c) )->[0], $AGG_ART, '... and their artwork' );
	is( scalar Slim::Utils::Timers->pending, 0, 'every extra in time: the deadline timer is gone' );

	fresh();
	{
		no warnings 'redefine';
		route_section('kids');
		local *Plugins::ABCListen::Collections::menuPage = sub { die "menuPage broke\n" };
		$c = open_feed( $MENU{kids}, $CLIENT );
	}
	is( $c->count, 1, 'menuPage dying: answers at once' );
	is_deeply( $images->( items_of($c), string('PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS') ), [ ($ICON) x 3 ], '... with the fallbacks' );
	is( scalar Slim::Utils::Timers->pending, 0, '... and no timer left' );
	ok( scalar( grep { $_->{message} =~ /menuPage broke/ } problems() ), 'logged' );
};

# ---------------------------------------------------------------------------
# Audiobooks
# ---------------------------------------------------------------------------

subtest 'Audiobooks: the 9 sub-collections, All audiobooks A–Z (O3), the AU-only note' => sub {
	fresh();
	route_section('audiobooks');
	my $items = section('audiobooks');

	is_deeply( names($items), [ @AUDIOBOOK_TITLES, $AZ, $AU_ONLY ], 'sub-collections in page order, then A–Z, then the note' );
	is( $AU_ONLY, 'Audiobooks play only in Australia.', 'the note\'s text' );
	is_deeply( $items->[-1], { name => $AU_ONLY, type => 'text' }, 'the note is a text row (no action)' );
	is( $items->[0]->{passthrough}->[0]->{id}, '105672994', 'Most Popular = 105672994 (paged with collection/x, no rootMetaCollectionId)' );

	route( "${BFF}collection/x?collectionId=105672994&offset=0&size=20", file => 'discovery/bff-collection-105672994-audiobooks-most-popular.trimmed.json', headers => $JSON_TYPE );
	my $popular = items_of( open_item( $items->[0], $CLIENT ) );
	is_deeply( [ @{ names($popular) }[ 0 .. 2 ] ], [ 'The Dictionary of Lost Words', 'My Brilliant Career', 'The 13-Storey Treehouse' ], 'Most Popular: the books' );
	is( $popular->[0]->{passthrough}->[0]->{path}, '/listen/audiobooks/the-dictionary-of-lost-words-page', 'a book is a program link (O2\'s program menu; its chapters are D5\'s)' );
	is( $popular->[0]->{passthrough}->[0]->{id}, '106353766', '... with the cardId as program id' );

	my $az = items_of( open_item( $items->[-2], $CLIENT ) );
	is_deeply( \@BY_TYPE, [ [ $CLIENT, 'audiobook' ] ], 'All audiobooks A–Z -> OnDemand->programsByType($client, $cb, "audiobook")' );
	is_deeply( names($az), ['The Dictionary of Lost Words'], '... its rows' );
	check_shapes( $items, 'Audiobooks' );

	fresh();
	route_section('audiobooks');
	{
		local *Plugins::ABCListen::OnDemand::programsByType;
		is_deeply( [ @{ names( section('audiobooks') ) }[ -2, -1 ] ], [ 'Programs For Book Lovers', $AU_ONLY ], 'O3 absent: no A–Z entry' );
	}
};

# ---------------------------------------------------------------------------
# Failures, callbacks, shapes
# ---------------------------------------------------------------------------

subtest 'page failure: live stations + static extras + one error item; never an empty list' => sub {
	my %expect = (
		news       => [ 'NewsRadio', $LOAD_FAILED ],
		sport      => [$LOAD_FAILED],
		kids       => [ 'ABC KIDS listen', 'All Kids listen programs', 'Kids & Families podcasts', 'Books for Kids', 'News Time', $LOAD_FAILED ],
		audiobooks => [ $AZ, $AU_ONLY, $LOAD_FAILED ],
	);
	for my $key (qw(news sport kids audiobooks)) {
		fresh();
		route_kids_extras();
		route( "$NEXT$PATH{$key}.json", code => 500, content => 'oops' );
		my $items = section($key);
		is_deeply( names($items), $expect{$key}, "$key: " . join( ', ', @{ $expect{$key} } ) );
		is_deeply( $items->[-1], { name => $LOAD_FAILED, type => 'text' }, "$key: the error is a text row" );
	}

	fresh();
	route( "$NEXT/listen/sport.json", code => 429, content => 'slow down' );
	is_deeply( names( section('sport') ), [ string('PLUGIN_ABCLISTEN_RATE_LIMITED') ], 'the API token is passed through (RATE_LIMITED)' );

	fresh();
	route_section('news');
	section('news');
	advanceTime(3601);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( "$NEXT/listen/news.json", code => 500, content => 'oops' );
	is_deeply( names( section('news') ), [ 'NewsRadio', @NEWS_TITLES ], 'ABC down after the hour: the last-good page (stale_ok), no error row' );

	fresh();
	route_page_json('sport');
	is_deeply( section('sport'), [ { name => $EMPTY, type => 'text' } ], 'a page with nothing usable: one "Nothing here right now" row' );
};

subtest 'exactly one callback on every path (sync cache hits, async, deferred); building dies -> LOAD_FAILED' => sub {
	for my $key (qw(news sport kids audiobooks)) {
		fresh();
		route_section( $key, defer => 1 );
		route_kids_extras( defer => 1 );
		my $c = open_feed( $MENU{$key}, $CLIENT );
		is( $c->count, 0, "$key: waits for the page" );
		Slim::Networking::SimpleAsyncHTTP->completeDeferred while Slim::Networking::SimpleAsyncHTTP->deferred;
		runTimers();
		is( $c->count, 1, "$key: one callback after the requests complete" );

		$c = open_feed( $MENU{$key}, $CLIENT );
		is( $c->count, 1, "$key: cached: one synchronous callback" );
	}

	fresh();
	route_section('news');
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::collectionItem = sub { die "builder broke\n" };
		is_deeply( section('news'), [ { name => $LOAD_FAILED, type => 'text' } ], 'a builder dying: one LOAD_FAILED row' );
	}
	ok( scalar( grep { $_->{message} =~ /builder broke/ } errors_logged() ), 'logged' );

	fresh();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::page = sub { die "page broke\n" };
		is_deeply( section('sport'), [ { name => $LOAD_FAILED, type => 'text' } ], 'page() dying: one LOAD_FAILED row' );
	}
};

subtest 'a callback that dies is logged and never called again' => sub {
	for my $key (qw(news kids)) {
		fresh();
		route_section($key);
		route_kids_extras();
		my $calls = 0;
		my $ok = eval { $MENU{$key}->( $CLIENT, sub { $calls++; die "LMS callback broke\n" }, {} ); 1 };
		ok( $ok, "$key: the death does not escape the menu" );
		is( $calls, 1, "$key: called once" );
		ok( scalar( grep { $_->{message} =~ /LMS callback broke/ } errors_logged() ), "$key: logged" );
	}

	fresh();
	my $calls = 0;
	Plugins::ABCListen::Sections::_audiobooksAZ( $CLIENT, sub { $calls++; die "again\n" }, {} );
	is( $calls, 1, 'All audiobooks A–Z: once' );
};

subtest '$client undef (web UI without a player, CLI): every section builds' => sub {
	for my $key (qw(news sport kids audiobooks)) {
		fresh();
		route_section($key);
		route_kids_extras();
		my $items = section( $key, undef );
		ok( @$items > 1, "$key: rows" );
		check_shapes( $items, "$key (no client)" );
	}
	is( scalar problems(), 0, 'no WARN/ERROR' );
};

done_testing();
