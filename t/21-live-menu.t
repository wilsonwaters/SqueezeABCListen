#!/usr/bin/perl
# Plugins::ABCListen::Live menus (OPML shapes, offline): the top-level Radio item (exact keys,
# weight); Radio's 12 networks then Sport / Local radio / Time-zone versions; the exact keys of a
# station item; Local radio's state order for homeState '' / undef / invalid and each of the 8 states
# ("(your state)" only when set); capital-first station order per state; home-state time-zone
# versions for SA/QLD/NT/WA (none for ACT/NSW/VIC/TAS); the 17 time-zone versions; Sport without
# HLS-only, duplicate and off-air services, with the 3 s event-check deadline on the fake clock;
# stationItem (undef for unknown/hidden/unplayable ids); no player ($client undef); readable names
# (no raw tokens); and exactly one callback on every path, also when building a menu dies.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use ABCListenTest::FakeClient;

use Plugins::ABCListen::Live;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::API;
use Plugins::ABCListen::Util qw(topWeight ICON);

my $S     = 'Plugins::ABCListen::Stations';
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

my @STATION_KEYS = sort qw(name line1 favorites_title type on_select url favorites_url image favorites_icon description);

# record INFO and DEBUG calls too
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub reset_all {
	resetStubs();
	$S->_reset();
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

sub id_of { my ($id) = ( $_[0]->{url} // '' ) =~ m{\Aabclisten://live/([A-Z0-9_]+)\z}; return $id }

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

	is_deeply( [ sort keys %$rn ], \@STATION_KEYS, 'exact keys: name line1 favorites_title type on_select url favorites_url image favorites_icon description' );
	my $image = Plugins::ABCListen::API::imageUrl( $rec->{logo}, 300 );
	is_deeply(
		$rn,
		{
			name            => 'Radio National',
			line1           => 'Radio National',
			favorites_title => 'Radio National',
			type            => 'audio',
			on_select       => 'play',
			url             => 'abclisten://live/RN',
			favorites_url   => 'abclisten://live/RN',
			image           => $image,
			favorites_icon  => $image,
			description     => $rec->{synopsis},
		},
		'values: name, play, abclisten://live/RN, logo at 300 px, synopsis'
	);
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
			like( $item->{description}, qr/\A\Q$CITY{$home}\E time\b/, "$home: $name description starts \"$CITY{$home} time\"" );
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
	like( $tj->{description}, qr/\APerth time - /, 'WA: "Perth time - <synopsis>"' );
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

	my $c = open_feed( undef, sport_feed(undef) );
	is( $c->count, 1, 'answers once' );
	my $items = items_of($c);
	is_deeply( [ map { id_of($_) } @$items ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO)], 'GRANDSTAND, ITINERANT_THREE, ITINERANT_ONE, ITINERANT_TWO' );
	is_deeply( [ map { $_->{name} } @$items ], [ 'ABC SPORT', 'ABC SPORT EXTRA', 'ABC Rugby League World Cup', 'ABC AFLW' ], 'their names' );
	is( scalar( grep { $_->{name} =~ /RAPID|CRICKET/i } @$items ), 0, 'no ABC SPORT RAPID / RLWC RAPID / CRICKET rows' );
	is( scalar( grep { $_->{url} =~ /SPORT_WORLDCUP|SPORT_AFLW/ } @$items ), 0, 'duplicates listed once (under ITINERANT_ONE / ITINERANT_TWO)' );
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/} } requests() ), 7, 'one check per event-only service' );

	reset_all();
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json' );
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' );
	$items = items_of( open_feed( $PLAYER, sport_feed($PLAYER) ) );
	is_deeply( [ map { id_of($_) } @$items ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO SPORT_BBL)], 'an on-air event service is listed' );
	is( $items->[-1]->{name}, 'ABC BBL', '... by name' );
	like( $items->[-1]->{image}, qr/cropW=/, '... with its logo' );
	check_names( $items, 'Sport' );

	resetStubs();
	route( qr{epgNowPlaying/}, code => 500 );
	$items = items_of( open_feed( undef, sport_feed(undef) ) );
	is( scalar( grep { $_->{url} =~ /SPORT_BBL/ } @$items ), 1, 'within 5 min the cached status is used (no new check)' );
	is( scalar( requests() ), 0, '... no request' );
};

subtest 'Sport: 3 s deadline for the event checks; unknown = hidden; once only' => sub {
	reset_all();
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json', defer => 1 );
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );

	my $feed = sport_feed(undef);
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

	my $again = open_feed( undef, $feed );
	is( $again->count, 1, 'next open: answers at once from the cache' );
	is( scalar( grep { id_of($_) eq 'SPORT_BBL' } @{ items_of($again) } ), 1, '... with the event service the late check found on air' );

	reset_all();
	route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );
	$c = open_feed( undef, sport_feed(undef) );
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
		is( $item && $item->{url}, "abclisten://live/$id", "stationItem($id): a playable row" );
		is_deeply( [ sort keys %{ $item || {} } ], \@STATION_KEYS, "stationItem($id): station keys" );
	}
	is( Plugins::ABCListen::Live->stationItem( undef, 'TRIPLEJ_PERTH' )->{name}, 'triple j Perth', 'a variant by its own name' );

	resetStubs();
	route( qr{epgNowPlaying/SPORT_TENNIS}, file => 'live/epg-event-onair-mediahub.json' );
	$S->eventStatus( 'SPORT_TENNIS', sub { } );
	is( Plugins::ABCListen::Live->stationItem( undef, 'SPORT_TENNIS' )->{name}, 'ABC Tennis', 'an event service while on air' );
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
