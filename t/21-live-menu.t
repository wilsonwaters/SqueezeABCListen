#!/usr/bin/perl
# Plugins::ABCListen::Live menus (OPML shapes, offline): the top-level Radio item (exact keys,
# weight); Radio's 12 networks then Sport / Local radio / Time-zone versions; the exact keys of a
# station item; Local radio's state order for homeState '' / undef / invalid and each of the 8 states
# ("(your state)" only when set); capital-first station order per state; home-state time-zone
# versions for SA/QLD/NT/WA (none for ACT/NSW/VIC/TAS); the 17 time-zone versions; Sport without
# HLS-only, duplicate and off-air services, with the 3 s event-check deadline on the fake clock;
# stationItem (undef for unknown/hidden/unplayable ids); no player ($client undef); readable names
# (no raw tokens); and exactly one callback on every path, also when building a menu dies.
# L2 (on air): line2 "On air: <program> · <presenters>" and description "<program> (<slot>) —
# <presenters>" + the L1 text on a new line; one programNow per listed station (time-zone versions
# use their own EPG); the 3 s deadline with 7 slow stations (<= 6 requests at a time, cached and
# last-good data used, answered once); stationItem from cached data only, never fetching; Sport
# fetches the listed stations after the event checks. L3: Sport makes exactly the expected number
# of requests (a cap), and an on-air event service's program reuses the event check's response.
# L4: station rows are links that also play (exact keys: type link, url = the station menu,
# passthrough [<ID>], play / favorites_url abclisten://live/<ID>, favorites_type audio, no on_select,
# no description); L2's description (and the "<City> time" text of home-state versions) moved to
# the station menu's Listen live (t/27-station-menu.t covers the menu itself).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use POSIX ();

use ABCListenTest::FakeClient;

use Plugins::ABCListen::Live;
use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::API;
use Plugins::ABCListen::Util qw(topWeight ICON);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $S     = 'Plugins::ABCListen::Stations';
my $NP    = 'Plugins::ABCListen::NowPlaying';
my $BFF   = 'https://www.abc.net.au/core-next/api/';
my $NOW   = 1_792_389_600;    # 2026-10-19 19:00 AEDT
my $prefs = preferences('plugin.abclisten');

my $PLAYER = ABCListenTest::FakeClient->new('00:00:00:00:00:01');

my @NETWORK_NAMES = (
	'Radio National', 'NewsRadio', 'ABC KIDS listen', 'Radio Australia', 'ABC Classic', 'triple j',
	'Double J', 'ABC Country', 'ABC Jazz', 'triple j Unearthed', 'Classic 2', 'triple j Hottest',
);
my @NETWORK_IDS = qw(RN NEWS KIDSLISTEN RA_ML CLASSIC TRIPLEJ DOUBLEJ COUNTRY JAZZ UNEARTHED CLASSIC2 H100);

my %STATE_NAME = (
	ACT => 'Australian Capital Territory', NSW => 'New South Wales', NT => 'Northern Territory', QLD => 'Queensland',
	SA  => 'South Australia', TAS => 'Tasmania', VIC => 'Victoria', WA => 'Western Australia',
);
my @STATES_AZ = qw(ACT NSW NT QLD SA TAS VIC WA);    # A-Z by full name

my %CAPITAL = (
	ACT => '666 ABC Canberra', NSW => '702 ABC Sydney', NT => '105.7 ABC Darwin', QLD => '612 ABC Brisbane',
	SA  => '891 ABC Adelaide', TAS => '936 ABC Hobart', VIC => '774 ABC Melbourne', WA => '102.5 ABC Perth',
);
my %COUNT = ( NSW => 14, ACT => 1, NT => 2, VIC => 9, SA => 5, TAS => 2, QLD => 11, WA => 8 );

my %CITY = ( SA => 'Adelaide', QLD => 'Brisbane', NT => 'Darwin', WA => 'Perth' );
my %VARIANT = (
	SA  => { RN => 'RN_SA',  TRIPLEJ => 'TRIPLEJ_ADELAIDE', DOUBLEJ => 'DOUBLEJ_ADELAIDE', CLASSIC => 'CLASSIC_ADELAIDE' },
	QLD => { RN => 'RN_QLD', TRIPLEJ => 'TRIPLEJ_BRISBANE', DOUBLEJ => 'DOUBLEJ_BRISBANE', CLASSIC => 'CLASSIC_BRISBANE' },
	NT  => { RN => 'RN_NT',  TRIPLEJ => 'TRIPLEJ_DARWIN',   DOUBLEJ => 'DOUBLEJ_DARWIN',   CLASSIC => 'CLASSIC_DARWIN' },
	WA  => { RN => 'RN_WA',  TRIPLEJ => 'TRIPLEJ_PERTH',    DOUBLEJ => 'DOUBLEJ_PERTH',    CLASSIC => 'CLASSIC_PERTH' },
);
my %VARIANT_TITLE = (
	RN_SA => 'Radio National SA', RN_QLD => 'Radio National Qld', RN_NT => 'Radio National NT', RN_WA => 'Radio National WA',
	map { my ( $net, $label ) = @$_; map { ( "${net}_" . uc($_) => "$label $_" ) } qw(Adelaide Brisbane Darwin Perth) }
		[ TRIPLEJ => 'triple j' ], [ DOUBLEJ => 'Double J' ], [ CLASSIC => 'ABC Classic' ],
);

my @STATION_KEYS = sort qw(name line1 favorites_title type url passthrough play favorites_url favorites_type image favorites_icon);

# record INFO and DEBUG calls too
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub reset_all {
	resetStubs();
	$S->_reset();
	$NP->_reset();
	$S->_setRecords();
	setTime($NOW);
	$prefs->set( homeState => '' );
	return;
}

sub radio_item {
	my $client = shift;
	my $c      = collector();
	Plugins::ABCListen::Live->menuItems( $client, $c->cb, {} );
	return ( $c->args(0) )[0]->[0];
}

# Open a link item (or a feed code ref) like XMLBrowser does: ($client, $cb, $args, @passthrough).
# Returns the collector.
sub open_feed {
	my ( $client, $item ) = @_;
	my $c = collector();
	my $code = ref $item eq 'CODE' ? $item : $item->{url};
	$code->( $client, $c->cb, {}, @{ ( ref $item eq 'HASH' && $item->{passthrough} ) || [] } );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub radio {
	my $client = shift;
	return items_of( open_feed( $client, radio_item($client) ) );
}

sub link_named {
	my ( $items, $name ) = @_;
	my ($link) = grep { $_->{name} eq $name } @$items;
	return $link;
}

sub local_states {
	my $client = shift;
	return items_of( open_feed( $client, link_named( radio($client), 'Local radio' ) ) );
}

sub state_stations {
	my ( $client, $stateItem ) = @_;
	return items_of( open_feed( $client, $stateItem ) );
}

sub id_of { my ($id) = ( $_[0]->{play} // '' ) =~ m{\Aabclisten://live/([A-Z0-9_]+)\z}; return $id }

# L4: a station row's station menu, opened like XMLBrowser does; its first row is Listen live.
sub listen_live {
	my ( $client, $row ) = @_;
	my $c = open_feed( $client, $row );
	advanceTime(3);
	my $items = items_of($c) || [];
	return $items->[0];
}

sub check_names {
	my ( $items, $label ) = @_;
	my @bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ ) || $_->{name} =~ /PLUGIN_ABCLISTEN/ || ( $_->{description} // '' ) =~ /PLUGIN_ABCLISTEN/ } @$items;
	is( scalar @bad, 0, "$label: every row has a readable name (no raw tokens)" );
}

# ---- top level ----

subtest 'top level: one "Radio" link with exact keys and the radio weight' => sub {
	reset_all();
	my $c = collector();
	Plugins::ABCListen::Live->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'menuItems calls back once' );
	my ($items) = $c->args(0);
	is( scalar @$items, 1, 'exactly one item' );

	my $radio = $items->[0];
	is_deeply( [ sort keys %$radio ], [qw(image name type url weight)], 'exact keys: name type url image weight' );
	is( $radio->{name},   'Radio', 'named "Radio"' );
	is( $radio->{name},   string('PLUGIN_ABCLISTEN_RADIO'), 'from PLUGIN_ABCLISTEN_RADIO' );
	is( $radio->{type},   'link', 'a link' );
	is( ref $radio->{url}, 'CODE', 'url is a feed' );
	is( $radio->{image},  ICON, 'the plugin icon' );
	is( $radio->{weight}, topWeight('radio'), 'weight topWeight("radio")' );
	is( $radio->{weight}, 20, '(20)' );
	is_deeply( [ Plugins::ABCListen::Live->menuWeights ], [20], 'menuWeights: the radio weight' );
	is( scalar( requests() ), 0, 'no request for the top level' );
};

# ---- Radio ----

subtest 'Radio: 12 networks (BFF order), then Sport, Local radio, Time-zone versions' => sub {
	reset_all();
	route( qr{collection/listen/radio}, content => '{}', defer => 1 );    # enrichment never arrives

	my $c = open_feed( undef, radio_item(undef) );
	is( $c->count, 1, 'answers once, without waiting for the enrichment' );
	my $items = items_of($c);
	is( scalar @$items, 15, '15 rows' );
	is_deeply( [ map { $_->{name} } @$items[ 0 .. 11 ] ], \@NETWORK_NAMES, 'the 12 networks, by name' );
	is_deeply( [ map { id_of($_) } @$items[ 0 .. 11 ] ], \@NETWORK_IDS, '... ids in the BFF national-collection order' );
	is_deeply( [ map { $_->{name} } @$items[ 12 .. 14 ] ], [ 'Sport', 'Local radio', 'Time-zone versions' ], 'then the three links' );

	for my $link ( @$items[ 12 .. 14 ] ) {
		is_deeply( [ sort keys %$link ], [qw(image name type url)], "$link->{name}: a link (name type url image)" );
		is( ref $link->{url}, 'CODE', "$link->{name}: navigable feed" );
	}
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 9, 'the 9 collections were requested for next time' );
	check_names( $items, 'Radio' );
};

subtest 'station item: exact keys and values' => sub {
	reset_all();
	my $items = radio(undef);
	my ($rn) = grep { id_of($_) && id_of($_) eq 'RN' } @$items;
	my $rec = $S->get('RN');

	is_deeply( [ sort keys %$rn ], \@STATION_KEYS, 'exact keys: name line1 favorites_title type url passthrough play favorites_url favorites_type image favorites_icon' );
	my $image = Plugins::ABCListen::API::imageUrl( $rec->{logo}, 300 );
	is( ref $rn->{url}, 'CODE', 'url: the station menu (a feed)' );
	is_deeply(
		{ %$rn, url => 'CODE' },
		{
			name            => 'Radio National',
			line1           => 'Radio National',
			favorites_title => 'Radio National',
			type            => 'link',
			url             => 'CODE',
			passthrough     => ['RN'],
			play            => 'abclisten://live/RN',
			favorites_url   => 'abclisten://live/RN',
			favorites_type  => 'audio',
			image           => $image,
			favorites_icon  => $image,
		},
		'values: a link to the RN station menu that plays abclisten://live/RN, favourites that URL as audio, logo at 300 px'
	);
	ok( !exists $rn->{on_select},   'no on_select (touch skins open the row; play plays it)' );
	ok( !exists $rn->{description}, 'no description on a link (LMS menu rule 1)' );
	is( listen_live( undef, $rn )->{description}, $rec->{synopsis}, 'the synopsis moved to the station menu\'s Listen live' );
	like( $image, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/[0-9a-f]{32}\?impolicy=wcms_crop_resize&cropH=\d+&cropW=\d+&xPos=0&yPos=0&width=300&height=300\z}, 'the logo keeps its crop params, 300 px' );

	for my $row ( @$items[ 0 .. 11 ] ) {
		like( $row->{image}, qr/cropW=\d+.*width=300/, "$row->{name}: a logo, not the plugin icon" );
	}

	my $item = Plugins::ABCListen::Live->stationItem( undef, 'RN' );
	is_deeply( $item, $rn, 'stationItem builds the same row' );
};

# ---- Local radio ----

subtest 'Local radio: state order and "(your state)"' => sub {
	for my $home ( '', undef, 'XX', 'nsw', [] ) {
		reset_all();
		$prefs->set( homeState => $home );
		my $states = local_states(undef);
		my $label  = defined $home ? ( ref $home ? 'a ref' : "'$home'" ) : 'undef';
		is_deeply( [ map { $_->{name} } @$states ], [ map { $STATE_NAME{$_} } @STATES_AZ[ 1, 0, 2 .. 7 ] ], "homeState $label: New South Wales first, unlabelled, then A-Z" );
		is( scalar( grep { $_->{name} =~ /your state/ } @$states ), 0, "homeState $label: no \"(your state)\"" );
	}

	for my $home (@STATES_AZ) {
		reset_all();
		$prefs->set( homeState => $home );
		my $states = local_states($PLAYER);
		my @want   = ( "$STATE_NAME{$home} (your state)", map { $STATE_NAME{$_} } grep { $_ ne $home } @STATES_AZ );
		is_deeply( [ map { $_->{name} } @$states ], \@want, "homeState $home: \"$want[0]\" first, the rest A-Z" );
		is_deeply( $states->[0]->{passthrough}, [$home], "homeState $home: its link opens $home" );
	}

	reset_all();
	my $states = local_states(undef);
	is( scalar @$states, 8, '8 states' );
	is_deeply( [ sort keys %{ $states->[0] } ], [qw(image name passthrough type url)], 'state rows: links' );
	check_names( $states, 'Local radio' );

	$prefs->set( homeState => 'WA' );
	is( local_states(undef)->[0]->{name}, 'Western Australia (your state)', 'a pref change applies at the next open' );
	is( string('PLUGIN_ABCLISTEN_YOUR_STATE'), '%s (your state)', '(the suffix is PLUGIN_ABCLISTEN_YOUR_STATE)' );
};

subtest 'state lists: capital-city station first, then A-Z' => sub {
	reset_all();
	my %byState = map { $_->{passthrough}->[0] => $_ } @{ local_states(undef) };

	for my $state (@STATES_AZ) {
		my $stations = state_stations( undef, $byState{$state} );
		is( scalar @$stations, $COUNT{$state}, "$state: $COUNT{$state} stations" );
		is( $stations->[0]->{name}, $CAPITAL{$state}, "$state: $CAPITAL{$state} first" );
		my @rest = map { $_->{name} } @$stations[ 1 .. $#$stations ];
		is_deeply( \@rest, [ sort { lc $a cmp lc $b } @rest ], "$state: the rest A-Z" );
		is( scalar( grep { join( ',', sort keys %$_ ) ne join( ',', @STATION_KEYS ) } @$stations ), 0, "$state: station rows have the station keys" );
		is( scalar( grep { $_->{image} !~ /cropW=/ } @$stations ), 0, "$state: every row has its logo" );
		check_names( $stations, $state );
	}

	my @qld = map { $_->{name} } @{ state_stations( undef, $byState{QLD} ) };
	ok( ( grep { $_ eq 'ABC Wide Bay' } @qld ), 'Queensland includes ABC Wide Bay' );
	is_deeply( [ map { $_->{name} } @{ state_stations( undef, $byState{NT} ) } ], [ '105.7 ABC Darwin', 'ABC Alice Springs' ], 'Northern Territory: Darwin once (Katherine is Darwin), Alice Springs' );

	my $c = collector();
	Plugins::ABCListen::Live::_stateMenu( undef, $c->cb, {}, 'XX' );
	is_deeply( [ $c->args(0) ], [ { items => [] } ], 'an unknown state: an empty list, once' );
};

subtest 'state lists: the capital comes first even when A-Z would put it later' => sub {
	reset_all();

	# Every real capital's name starts with its frequency ("702 ABC Sydney"), so A-Z alone puts it first.
	# Here Sydney is renamed to sort between the other stations.
	my %rec = map { $_->{id} => $_ } Plugins::ABCListen::StationData::records();
	$S->_setRecords( $rec{LOCAL_UPPERHUNTER}, { %{ $rec{LOCAL_SYDNEY} }, name => 'ABC Sydney' }, $rec{LOCAL_NEWCASTLE}, $rec{LOCAL_ILLAWARRA} );

	my $c = collector();
	Plugins::ABCListen::Live::_stateMenu( undef, $c->cb, {}, 'NSW' );
	my ($result) = $c->args(0);
	is_deeply(
		[ map { $_->{name} } @{ $result->{items} } ],
		[ 'ABC Sydney', 'ABC Illawarra', 'ABC Newcastle', 'ABC Upper Hunter' ],
		'NSW: "ABC Sydney" (the capital) first, then the rest A-Z'
	);
	is( $c->count, 1, 'answered once' );

	reset_all();
};

# ---- home-state time-zone versions ----

subtest 'home-state variants: SA/QLD/NT/WA substitute RN, triple j, Double J, ABC Classic' => sub {
	for my $home ( sort keys %VARIANT ) {
		reset_all();
		$prefs->set( homeState => $home );
		my $items = radio($PLAYER);
		my %row   = map { $_->{name} => $_ } @$items;

		for my $network ( sort keys %{ $VARIANT{$home} } ) {
			my $variant = $VARIANT{$home}->{$network};
			my $name    = $S->get($network)->{name};
			my $item    = $row{$name};
			is( id_of($item), $variant, "$home: the $name row plays $variant" );
			is( $item->{favorites_url}, "abclisten://live/$variant", "$home: $name favourite URL" );
			is( $item->{name}, $name, "$home: $name keeps its name" );
			like( listen_live( undef, $item )->{description}, qr/\A\Q$CITY{$home}\E time\b/, "$home: $name Listen live's description starts \"$CITY{$home} time\"" );
			is( $item->{favorites_title}, $VARIANT_TITLE{$variant}, "$home: $name favorites_title \"$VARIANT_TITLE{$variant}\"" );
		}

		is( id_of( $row{NewsRadio} ), 'NEWS', "$home: other networks unchanged" );
		is( scalar @$items, 15, "$home: still 15 rows" );
	}

	for my $home ( qw(ACT NSW VIC TAS), '' ) {
		reset_all();
		$prefs->set( homeState => $home );
		is_deeply( [ map { id_of($_) } @{ radio(undef) }[ 0 .. 11 ] ], \@NETWORK_IDS, "homeState '$home': no substitution" );
	}

	reset_all();
	$prefs->set( homeState => 'WA' );
	my ($tj) = grep { $_->{name} eq 'triple j' } @{ radio(undef) };
	like( listen_live( undef, $tj )->{description}, qr/\APerth time - /, 'WA: "Perth time - <synopsis>" (station menu, Listen live)' );
	is( string('PLUGIN_ABCLISTEN_CITY_TIME'), '%s time', '(from PLUGIN_ABCLISTEN_CITY_TIME)' );
};

# ---- Time-zone versions ----

subtest 'Time-zone versions: all 17, by network (Networks order), cities A-Z' => sub {
	for my $home ( '', 'WA' ) {
		reset_all();
		$prefs->set( homeState => $home );
		my $items = items_of( open_feed( undef, link_named( radio(undef), 'Time-zone versions' ) ) );
		is( scalar @$items, 17, "homeState '$home': 17 rows" );
		is_deeply(
			[ map { id_of($_) } @$items ],
			[qw(RN_SA RN_QLD RN_NT RN_WA RA CLASSIC_ADELAIDE CLASSIC_BRISBANE CLASSIC_DARWIN CLASSIC_PERTH TRIPLEJ_ADELAIDE TRIPLEJ_BRISBANE TRIPLEJ_DARWIN TRIPLEJ_PERTH DOUBLEJ_ADELAIDE DOUBLEJ_BRISBANE DOUBLEJ_DARWIN DOUBLEJ_PERTH)],
			"homeState '$home': RN, Radio Australia, ABC Classic, triple j, Double J; Adelaide, Brisbane, Darwin, Perth"
		);
		is( $items->[4]->{name}, 'Radio Australia (English)', 'Radio Australia (English) is told apart' );
		is( $items->[12]->{favorites_title}, 'triple j Perth', 'variant rows carry their own titles' );
		is( scalar( grep { join( ',', sort keys %$_ ) ne join( ',', @STATION_KEYS ) } @$items ), 0, 'station rows' );
		check_names( $items, 'Time-zone versions' );
	}
};

# ---- Sport ----

sub sport_feed {
	my $client = shift;
	return link_named( radio($client), 'Sport' );
}

subtest 'Sport: listed services; no HLS-only, duplicate or off-air services' => sub {
	reset_all();
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' );    # every event service off air (null)

	my $feed = sport_feed(undef);
	$NP->_reset();    # (L3) forget the Radio menu's programs, so that any other programNow shows as a request
	my $before = scalar requests();
	my $c      = open_feed( undef, $feed );
	is( $c->count, 1, 'answers once' );
	is( scalar( requests() ) - $before, 11, 'exactly 11 requests: 7 event checks + the programs of the 4 listed stations (L3: a cap)' );
	my $items = items_of($c);
	is_deeply( [ map { id_of($_) } @$items ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO)], 'GRANDSTAND, ITINERANT_THREE, ITINERANT_ONE, ITINERANT_TWO' );
	is_deeply( [ map { $_->{name} } @$items ], [ 'ABC SPORT', 'ABC SPORT EXTRA', 'ABC Rugby League World Cup', 'ABC AFLW' ], 'their names' );
	is( scalar( grep { $_->{name} =~ /RAPID|CRICKET/i } @$items ), 0, 'no ABC SPORT RAPID / RLWC RAPID / CRICKET rows' );
	is( scalar( grep { $_->{play} =~ /SPORT_WORLDCUP|SPORT_AFLW/ } @$items ), 0, 'duplicates listed once (under ITINERANT_ONE / ITINERANT_TWO)' );
	my %event = map { $_->{id} => 1 } grep { $_->{eventOnly} } $S->list('sport');
	is( scalar( grep { m{/epgNowPlaying/(\w+)/} && $event{$1} } map { $_->{url} } requests() ), 7, 'one check per event-only service' );
	my %sport = map { $_->{id} => 1 } $S->list('sport');
	is_deeply(
		[ sort map { m{/epgNowPlaying/(\w+)/now} && $sport{$1} && !$event{$1} ? $1 : () } map { $_->{url} } requests() ],
		[ sort qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO) ],
		'the program on air of each listed station is fetched (L2)'
	);

	reset_all();
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json' );
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' );
	$feed   = sport_feed($PLAYER);
	$before = scalar requests();
	$items  = items_of( open_feed( $PLAYER, $feed ) );
	is_deeply( [ map { id_of($_) } @$items ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO SPORT_BBL)], 'an on-air event service is listed' );
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/SPORT_BBL/now} } requests() ), 1, 'its epgNowPlaying is fetched once: the program on air comes from the event check\'s response (no duplicate; L3)' );
	is( scalar( requests() ) - $before, 11, '... 11 requests in all: 7 event checks + the programs of the 4 other listed stations' );
	is( $items->[-1]->{name}, 'ABC BBL', '... by name' );
	like( $items->[-1]->{image}, qr/cropW=/, '... with its logo' );
	check_names( $items, 'Sport' );

	resetStubs();
	route( qr{epgNowPlaying/}, code => 500 );
	$items = items_of( open_feed( undef, sport_feed(undef) ) );
	is( scalar( grep { $_->{play} =~ /SPORT_BBL/ } @$items ), 1, 'within 5 min the cached status is used (no new check)' );
	is( scalar( requests() ), 0, '... no request' );
};

subtest 'Sport: 3 s deadline for the event checks; unknown = hidden; once only' => sub {
	reset_all();
	my $feed = sport_feed(undef);    # (Radio first: L2 waits for the networks' programs too)
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json', defer => 1 );
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );

	my $c    = open_feed( undef, $feed );
	is( $c->count, 0, 'waits for the checks' );
	advanceTime(2.9);
	is( $c->count, 0, 'still waiting at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at 3 s' );
	is_deeply( [ map { id_of( $_ ) } @{ items_of($c) } ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO)], 'unknown event status: hidden' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'late answers do not call back again' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timer left' );

	my $checks = scalar requests();
	my $again  = open_feed( undef, $feed );
	is( scalar( requests() ) - $checks, 0, 'next open: no request (event status from the cache; the newly listed station\'s program from the event check\'s fresh response: no duplicate, L3)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $again->count, 1, '... answers' );
	is( scalar( grep { id_of($_) eq 'SPORT_BBL' } @{ items_of($again) } ), 1, '... with the event service the late check found on air' );

	reset_all();
	$feed = sport_feed(undef);
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );
	$c = open_feed( undef, $feed );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'all checks done before the deadline: answers then' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... and the deadline timer is cancelled' );
	advanceTime(5);
	is( $c->count, 1, 'still once' );
};

# ---- stationItem ----

subtest 'stationItem: undef for unknown, hidden and unplayable ids' => sub {
	reset_all();
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );

	for my $id ( 'NOPE', undef, '', 'KIDSLISTEN_NT', 'ITINERANT_FOUR', 'ABCSPORTSYNC', 'ABC_AFL_RAPID', 'SPORT_BBL' ) {
		is( Plugins::ABCListen::Live->stationItem( undef, $id ), undef, 'stationItem(' . ( $id // 'undef' ) . '): undef' );
	}

	for my $id (qw(NEWS KIDSLISTEN LOCAL_WIDEBAY TRIPLEJ_PERTH SPORT_WORLDCUP SPORT_AFLW GRANDSTAND)) {
		my $item = Plugins::ABCListen::Live->stationItem( $PLAYER, $id );
		is( $item && $item->{play}, "abclisten://live/$id", "stationItem($id): a playable row" );
		is_deeply( [ sort keys %{ $item || {} } ], \@STATION_KEYS, "stationItem($id): station keys" );
	}
	is( Plugins::ABCListen::Live->stationItem( undef, 'TRIPLEJ_PERTH' )->{name}, 'triple j Perth', 'a variant by its own name' );

	resetStubs();
	route( qr{epgNowPlaying/SPORT_TENNIS}, file => 'live/epg-event-onair-mediahub.json' );
	$S->eventStatus( 'SPORT_TENNIS', sub { } );
	is( Plugins::ABCListen::Live->stationItem( undef, 'SPORT_TENNIS' )->{name}, 'ABC Tennis', 'an event service while on air' );
};

# ---- on air (L2) ----

my $RN_START = Plugins::ABCListen::Util::parseISO8601('2026-10-19T07:00:00Z');    # 6:00pm AEDT

sub epg_requests { return scalar grep { $_->{url} =~ m{/epgNowPlaying/} } requests() }

sub row_of {
	my ( $items, $id ) = @_;
	my ($row) = grep { ( id_of($_) // '' ) eq $id } @$items;
	return $row;
}

subtest 'on air: line2, and the description in the station menu, from the program on air' => sub {
	reset_all();
	setTime( $RN_START + 1800 );
	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );
	route( "${BFF}epgNowPlaying/NEWS/now?imageRatio=1x1", content => '{"title":"BBC World","start":"2026-10-19T11:00:00+00:00","end":"2026-10-19T19:00:00+00:00","preparedPresenters":[],"preparedImage":null}' );

	my $c     = open_feed( undef, radio_item(undef) );
	my $items = items_of($c);
	is( $c->count, 1, 'Radio answers once (no player)' );
	is( epg_requests(), 12, 'one programNow per network' );

	my $rn = row_of( $items, 'RN' );
	is( $rn->{line2}, "On air: The Radio National Hour \x{B7} Fran Kelly", 'line2 "On air: <program> · <presenters>"' );
	is( listen_live( undef, $rn )->{description}, "The Radio National Hour (6:00pm\x{2013}7:00pm) \x{2014} Fran Kelly\n" . $S->get('RN')->{synopsis}, 'Listen live\'s description "<program> (<slot>) — <presenters>", then the synopsis on a new line' );
	is_deeply( [ sort keys %$rn ], [ sort @STATION_KEYS, 'line2' ], 'station keys plus line2' );
	is( $rn->{name}, 'Radio National', 'the name stays the station\'s' );
	is( string('PLUGIN_ABCLISTEN_ON_AIR'), 'On air: %s', '(PLUGIN_ABCLISTEN_ON_AIR has a placeholder)' );

	my $news = row_of( $items, 'NEWS' );
	is( $news->{line2}, 'On air: BBC World', 'no presenters: no " · "' );
	like( listen_live( undef, $news )->{description}, qr/\ABBC World \(10:00pm\x{2013}6:00am\)\n/, 'no presenters: no " — "; a slot across midnight' );

	my $tj = row_of( $items, 'TRIPLEJ' );
	ok( !exists $tj->{line2}, 'a station without program data: no line2' );
	is( listen_live( undef, $tj )->{description}, $S->get('TRIPLEJ')->{synopsis}, '... and the L1 description in its station menu' );
	check_names( $items, 'Radio (on air)' );

	setTime( $RN_START + 1800 );    # (listen_live moved the clock)
	resetStubs();
	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );
	route( "${BFF}epgNowPlaying/NEWS/now?imageRatio=1x1", content => '{"title":"BBC World","start":"2026-10-19T11:00:00+00:00","end":"2026-10-19T19:00:00+00:00","preparedPresenters":[],"preparedImage":null}' );
	$NP->_reset();
	open_feed( undef, radio_item(undef) );
	is( epg_requests(), 12, '(again from scratch: 12 requests)' );
	$c = open_feed( $PLAYER, radio_item($PLAYER) );
	is( epg_requests(), 12, 'opened again at once: no request (programs cached, failures in the 60 s negative cache)' );
	is( row_of( items_of($c), 'RN' )->{line2}, $rn->{line2}, '... RN from the cache' );
	advanceTime(60);
	open_feed( $PLAYER, radio_item($PLAYER) );
	is( epg_requests(), 22, '60 s later: the 10 failed ones are asked again, RN and NEWS are still cached' );
};

subtest 'on air: a home-state time-zone version uses its own EPG' => sub {
	reset_all();
	setTime( Plugins::ABCListen::Util::parseISO8601('2026-10-19T05:00:00Z') );
	$prefs->set( homeState => 'WA' );
	route( "${BFF}epgNowPlaying/TRIPLEJ_PERTH/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json' );
	route( "${BFF}epgNowPlaying/TRIPLEJ/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );

	my $tj = row_of( radio(undef), 'TRIPLEJ_PERTH' );
	is( $tj->{name},  'triple j', 'the triple j row plays TRIPLEJ_PERTH' );
	is( $tj->{line2}, "On air: Drive \x{B7} Jordan & Luka", 'line2 from TRIPLEJ_PERTH\'s EPG' );
	like( listen_live( undef, $tj )->{description}, qr/\ADrive \(3:00pm\x{2013}5:30pm\) \x{2014} Jordan & Luka\nPerth time - /, 'Listen live\'s description: on air, then "Perth time - <synopsis>"' );
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/TRIPLEJ/} } requests() ), 0, 'the network\'s own EPG is not fetched for it' );
};

subtest 'on air: 3 s deadline with 7 slow stations, <= 6 requests at a time, cached data used, once' => sub {
	reset_all();
	setTime( $RN_START + 1800 );
	my @seven = grep { ( $_->{state} // '' ) eq 'NSW' && $_->{group} eq 'local' } Plugins::ABCListen::StationData::records();
	@seven = @seven[ 0 .. 6 ];
	$S->_setRecords(@seven);
	my ( $first, $last ) = map { $_->{id} } @seven[ 0, 6 ];

	# a program fetched earlier for one station: stale now, but still on air (last good)
	route( "${BFF}epgNowPlaying/$first/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );
	$NP->programNow( $first, sub { } );
	advanceTime(900);
	resetStubs();
	route( qr{/epgNowPlaying/}, file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );

	my $c = collector();
	Plugins::ABCListen::Live::_stateMenu( undef, $c->cb, {}, 'NSW' );
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 6, '7 stations: 6 requests in flight' );
	advanceTime(2.9);
	is( $c->count, 0, 'waits at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at 3 s' );

	my $items = items_of($c);
	is( scalar @$items, 7, '7 rows' );
	my %row = map { id_of($_) => $_ } @$items;
	is( $row{$first}->{line2}, "On air: The Radio National Hour \x{B7} Fran Kelly", 'the last-good program is used at the deadline' );
	is( scalar( grep { exists $_->{line2} } @$items ), 1, 'stations without data get no on-air text' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( epg_requests(), 7, 'the 7th request starts once a slot is free' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'late answers do not call back again' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timer left' );

	$c = collector();
	Plugins::ABCListen::Live::_stateMenu( undef, $c->cb, {}, 'NSW' );
	is( $c->count, 1, 'opened again: answered at once' );
	is( scalar( grep { exists $_->{line2} } @{ items_of($c) } ), 7, '... with on-air text for every station' );
	is( epg_requests(), 7, '... from the cache' );
	ok( exists $row{$last}, '(the 7th station is listed)' );
};

subtest 'stationItem: cached and last-good data only, never a fetch; a new hash each time' => sub {
	reset_all();
	setTime( $RN_START + 1800 );

	my $item = Plugins::ABCListen::Live->stationItem( undef, 'RN' );
	ok( !exists $item->{line2}, 'nothing cached: no line2' );
	is( epg_requests(), 0, 'stationItem makes no request' );

	route( "${BFF}epgNowPlaying/RN/now?imageRatio=1x1", file => 'live/bff-epgNowPlaying-RN-now.json' );
	$NP->programNow( 'RN', sub { } );
	$item = Plugins::ABCListen::Live->stationItem( $PLAYER, 'RN' );
	is( $item->{line2}, "On air: The Radio National Hour \x{B7} Fran Kelly", 'cached: line2' );
	ok( !exists $item->{description}, 'no description on the row (a link)' );

	advanceTime(900);
	is( Plugins::ABCListen::Live->stationItem( undef, 'RN' )->{line2}, $item->{line2}, 'stale but still on air: the last-good program' );
	is( epg_requests(), 1, '... still no request from stationItem' );

	$item->{line2} = 'Event title';
	isnt( Plugins::ABCListen::Live->stationItem( undef, 'RN' )->{line2}, 'Event title', 'changing a returned item does not change the next one' );

	setTime( $RN_START + 3600 );
	ok( !exists Plugins::ABCListen::Live->stationItem( undef, 'RN' )->{line2}, 'once the program has ended: no on-air text' );
};

# ---- robustness ----

subtest 'exactly one callback on every path, also when building fails; no player' => sub {
	reset_all();

	my @feeds = (
		[ Radio                => sub { radio_item(undef) } ],
		[ 'Local radio'        => sub { link_named( radio(undef), 'Local radio' ) } ],
		[ 'Time-zone versions' => sub { link_named( radio(undef), 'Time-zone versions' ) } ],
		[ Sport                => sub { link_named( radio(undef), 'Sport' ) } ],
		[ Queensland           => sub { ( grep { $_->{passthrough}->[0] eq 'QLD' } @{ local_states(undef) } )[0] } ],
	);

	for my $feed (@feeds) {
		my ( $name, $get ) = @$feed;
		my $item = $get->();

		my $c = open_feed( undef, $item );
		advanceTime(3);
		is( $c->count, 1, "$name: one callback (no player)" );
		ok( scalar @{ items_of($c) || [] }, "$name: items" );

		{
			no warnings 'redefine';
			local *Plugins::ABCListen::Stations::list = sub { die "boom\n" };
			$c = open_feed( $PLAYER, $item );
			advanceTime(3);
		}
		is( $c->count, 1, "$name: building dies -> still one callback" );
		my $items = items_of($c);
		if ( $name eq 'Local radio' ) {
			is( scalar @$items, 8, "$name: does not need the station list" );
		}
		else {
			is_deeply( $items, [ { name => string('PLUGIN_ABCLISTEN_ERROR'), type => 'text' } ], "$name: one readable error row" );
		}
	}

	ok( scalar( logged('ERROR') ), 'the failures are logged' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timers left' );
};

done_testing();
