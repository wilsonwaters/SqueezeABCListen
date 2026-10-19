package Plugins::ABCListen::Live;

# Live radio hook (hook API: see Plugin.pm): the top-level "Radio" link (the ABC listen app's Radio
# tab) and the `live` protocol-handler kind (Plugins::ABCListen::ProtocolHandler->registerKind).
#
# Radio
#   the 12 national and music networks (BFF national-collection order), then the links
#   Sport          the listed sport services; event-only services only while ABC reports them on air
#                  (checked with a MENU_DEADLINE (3 s) deadline; unknown = hidden)
#   Local radio    the 8 states: the home state first, as "<State> (your state)" (homeState '' or
#                  invalid: New South Wales first, unlabelled), the rest A-Z by full name; each state
#                  lists its stations, capital-city station first, then A-Z
#   Time-zone versions  all 17 time-zone versions, by network, cities A-Z
# With homeState SA, QLD, NT or WA, the Radio National, triple j, Double J and ABC Classic rows play
# that state's time-zone version: same name, description "<City> time ...", favorites_title the
# version's own title.
#
# Every menu answers exactly once, within MENU_DEADLINE: the catalogue is local, BFF enrichment is
# only read from cache (Stations->enrich applies cached collections at once and fetches the others
# for next time) and event status comes from cache or the deadline.
#
# On air (L2): station lists (Radio's networks, a state, Time-zone versions, Sport) first fetch the
# program on air of every station they list (NowPlaying->programNow: cached until the program ends,
# at most 6 requests at a time), then answer when all are known or at MENU_DEADLINE, with whatever
# is cached or last-good. A station row with a known program gets
#   line2        "On air: <program> · <presenters>" (Material, Jive, menu:1; no " · " without presenters)
#   description  "<program> (6:00am–9:00am) — <presenters>" (Default skin detail view), then the
#                L1 description ("<City> time - <synopsis>") on a new line
# Rows without program data keep the L1 text. stationItem uses cached/last-good data only.
#
# Public builder (ai-state/streams.md contract 7):
#   Live->stationItem($client, $serviceId) -> a playable station item, or undef for unknown, hidden,
#   HLS-only and off-air (or not yet known) event services. Never fetches; consumers that override
#   line2/description do so on their copy (every call builds a new hash).
#
# live kind
#   resolve   Stations->streamCandidates: { url => first, alternates => [rest], failToken =>
#             PLUGIN_ABCLISTEN_LIVE_FAILED }, or { error => LIVE_HLS_ONLY | LIVE_OFF_AIR |
#             UNAVAILABLE (unknown id) }; exactly one callback.
#   metadata, onStream, onStop
#             Plugins::ABCListen::LiveMetadata (L2): the program on air, polled per master player and
#             pushed to Now Playing. Its station fallback is _metadata here: { title => station
#             name, artist => "ABC listen", cover => logo (~600 px), bitrate => "56kbps CBR" } (no
#             bitrate when the stream playing isn't StreamGuys Icecast); synchronous, no network,
#             never dies. onStream (_onStream) also logs a fallback to another stream family once
#             per play (L5: Stations->noteStream).
# Song info: LiveMetadata->trackInfo ("Program info"), registered as a Slim::Menu::TrackInfo
# provider.
#
# Pref liveQuality (L5): initialised and validated in init; Stations reads it at play time.
#
# Owned by the live stream: L1 creates; L2 owns _stationItem text (line2/description), L4 its type and
# the station submenu.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::LiveMetadata;
use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

use constant MENU_DEADLINE   => 3;               # seconds
use constant ITEM_IMAGE_PX   => 300;
use constant COVER_IMAGE_PX  => 600;
use constant ICECAST_BITRATE => '56kbps CBR';    # StreamGuys Icecast HE-AAC

use constant LIVE_FAILED => 'PLUGIN_ABCLISTEN_LIVE_FAILED';

use constant MIDDOT  => " \x{B7} ";
use constant EM_DASH => " \x{2014} ";

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

my $STATIONS    = 'Plugins::ABCListen::Stations';
my $NOW_PLAYING = 'Plugins::ABCListen::NowPlaying';
my $METADATA    = 'Plugins::ABCListen::LiveMetadata';

my @STATES = qw(ACT NSW NT QLD SA TAS VIC WA);
my %STATES = map { $_ => 1 } @STATES;

# networks whose row plays the home state's time-zone version (homeState SA, QLD, NT or WA)
my @HOME_VARIANT_NETWORKS = qw(RN TRIPLEJ DOUBLEJ CLASSIC);

sub init {
	$METADATA->init( stationMeta => \&_metadata );

	# === L5 === the liveQuality pref ('standard' | 'mediahub'; validator in Stations.pm)
	$prefs->init( { liveQuality => 'standard' } );
	$prefs->setValidate( { validator => \&Plugins::ABCListen::Stations::validateLiveQuality }, 'liveQuality' );
	# === /L5 ===

	Plugins::ABCListen::ProtocolHandler->registerKind(
		live => {
			resolve  => \&_resolve,
			metadata => \&Plugins::ABCListen::LiveMetadata::metadata,
			onStream => \&_onStream,    # L2's LiveMetadata::onStream, then L5's fallback log
			onStop   => \&Plugins::ABCListen::LiveMetadata::onStop,
		}
	);

	Slim::Menu::TrackInfo->registerInfoProvider( abclistenProgramInfo => (
		after => 'top',
		func  => \&Plugins::ABCListen::LiveMetadata::trackInfo,
	) );

	return;
}

# The top-level "Radio" item sorts at the "radio" weight (see Plugin.pm, Util::topWeight).
sub menuWeights { Plugins::ABCListen::Util::topWeight('radio') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_RADIO' ),
		type   => 'link',
		url    => \&_radioMenu,
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight('radio'),
	} ] );
}

sub stationItem {
	my ( $class, $client, $id ) = @_;

	return undef unless $STATIONS->playable($id);

	my $rec = $STATIONS->get($id) or return undef;
	return undef if $rec->{group} eq 'hidden';

	return _stationItem( $client, $rec );
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

sub _radioMenu {
	my ( $client, $cb, $args ) = @_;

	_answerStations( $client, $cb, 'Radio', sub {
		eval { $STATIONS->enrich(); 1 } or $log->error( 'Could not start the station enrichment: ' . ( $@ || 'unknown error' ) );

		my $home = _homeState();

		my @items = map { _networkItem( $client, $_, $home ) } grep { $STATIONS->playable( $_->{id} ) } $STATIONS->list('network');

		push @items,
			_link( $client, 'PLUGIN_ABCLISTEN_SPORT',             \&_sportMenu ),
			_link( $client, 'PLUGIN_ABCLISTEN_LOCAL_RADIO',       \&_localMenu ),
			_link( $client, 'PLUGIN_ABCLISTEN_TIMEZONE_VERSIONS', \&_variantMenu );

		return \@items;
	} );
}

# A network row; with a home state that has its own time-zone version, that version plays.
sub _networkItem {
	my ( $client, $rec, $home ) = @_;

	if ( $home && grep { $_ eq $rec->{id} } @HOME_VARIANT_NETWORKS ) {
		my ($variant) = grep { ( $_->{state} || '' ) eq $home && $_->{network} eq $rec->{id} } $STATIONS->list('variant');

		if ( $variant && $variant->{city} && $STATIONS->playable( $variant->{id} ) ) {
			return _stationItem(
				$client, $variant,
				name   => $rec->{name},
				prefix => cstring( $client, 'PLUGIN_ABCLISTEN_CITY_TIME', $variant->{city} ),
			);
		}
	}

	return _stationItem( $client, $rec );
}

sub _sportMenu {
	my ( $client, $cb, $args ) = @_;

	my @recs;
	my $listError = eval { @recs = $STATIONS->list('sport'); 1 } ? undef : ( $@ || 'unknown error' );
	my @events    = map { $_->{id} } grep { $_->{eventOnly} } @recs;

	# the event checks come first (they decide which event services are listed); unknown at the
	# deadline = hidden
	_answerStations(
		$client, $cb, 'Sport',
		sub {
			die $listError if defined $listError;
			[ map { _stationItem( $client, $_ ) } grep { $STATIONS->playable( $_->{id} ) } @recs ];
		},
		sub { $STATIONS->checkOnAir( \@events, shift ) },
	);

	return;
}

sub _localMenu {
	my ( $client, $cb, $args ) = @_;

	_answer( $client, $cb, 'Local radio', sub {
		my $home  = _homeState();
		my $first = $home || 'NSW';

		my %names = map { $_ => cstring( $client, "PLUGIN_ABCLISTEN_STATE_$_" ) } @STATES;
		my @rest  = sort { lc $names{$a} cmp lc $names{$b} } grep { $_ ne $first } @STATES;

		return [ map {
			my $state = $_;
			my $name  = $home && $state eq $home ? cstring( $client, 'PLUGIN_ABCLISTEN_YOUR_STATE', $names{$state} ) : $names{$state};
			{
				name        => $name,
				type        => 'link',
				url         => \&_stateMenu,
				passthrough => [$state],
				image       => Plugins::ABCListen::Util::ICON,
			};
		} $first, @rest ];
	} );
}

sub _stateMenu {
	my ( $client, $cb, $args, $state ) = @_;

	_answerStations( $client, $cb, 'Local radio state', sub {
		[ map { _stationItem( $client, $_ ) } grep { $STATIONS->playable( $_->{id} ) } $STATIONS->list( 'local', $state // '' ) ];
	} );
}

sub _variantMenu {
	my ( $client, $cb, $args ) = @_;

	_answerStations( $client, $cb, 'Time-zone versions', sub {
		[ map { _stationItem( $client, $_ ) } grep { $STATIONS->playable( $_->{id} ) } $STATIONS->list('variant') ];
	} );
}

# Build a menu's items with $build and answer { items => [...] } once; if building dies, the error
# is logged and the menu holds one error text item.
sub _answer {
	my ( $client, $cb, $what, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( "Could not build the $what menu: " . ( $@ || 'no items' ) );
		$items = [ { name => cstring( $client, 'PLUGIN_ABCLISTEN_ERROR' ), type => 'text' } ];
	}

	$cb->( { items => $items } );
	return;
}

# Answer a station list once, within MENU_DEADLINE (L2): the program on air is fetched for every
# station $build lists, then the list is built again with their on-air text (_answer). Optional
# $prepare->($done) runs first and calls $done once (Sport: the event checks); the stations listed
# after it are fetched too. At the deadline the list is built with whatever is cached or last-good;
# late answers only fill NowPlaying's cache.
sub _answerStations {
	my ( $client, $cb, $what, $build, $prepare ) = @_;

	my ( $answered, $timer, $pending, %requested ) = ( 0, undef, 1 );

	my $answer = sub {
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		_answer( $client, $cb, $what, $build );
	};

	my $doneOne = sub { $answer->() unless --$pending > 0 };

	# fetch the programs of the listed stations not asked for yet
	my $fetch = sub {
		return if $answered;

		my $items = eval { $build->() };

		for my $id ( grep { !$requested{$_}++ } _liveIds($items) ) {
			$pending++;
			my $once = 0;
			eval { $NOW_PLAYING->programNow( $id, sub { $doneOne->() unless $once++ } ); 1 } or do {
				$log->error( "Could not get the program on air for $id: " . ( $@ || 'unknown error' ) );
				$doneOne->() unless $once++;
			};
		}
	};

	$fetch->();

	if ($prepare) {
		$pending++;
		my $once = 0;
		my $prepared = sub {
			return if $once++;
			$fetch->();
			$doneOne->();
		};

		eval { $prepare->($prepared); 1 } or do {
			$log->error( "Could not prepare the $what menu: " . ( $@ || 'unknown error' ) );
			$prepared->();
		};
	}

	$doneOne->();    # everything is started
	return if $answered;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + MENU_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( "$what: not everything known within " . MENU_DEADLINE . ' s; answering with what is cached' );
		$answer->();
	} );

	return;
}

# The distinct live service ids of a list of items (from their abclisten://live/ URLs).
sub _liveIds {
	my $items = shift;
	return () unless ref $items eq 'ARRAY';

	my %seen;
	return grep { !$seen{$_}++ } map {
		my $parsed = ref $_ eq 'HASH' ? Plugins::ABCListen::Util::parseUrl( $_->{url} ) : undef;
		$parsed && $parsed->{kind} eq 'live' ? $parsed->{id} : ();
	} @$items;
}

sub _link {
	my ( $client, $token, $url ) = @_;

	return {
		name  => cstring( $client, $token ),
		type  => 'link',
		url   => $url,
		image => Plugins::ABCListen::Util::ICON,
	};
}

# A playable station row. Favourites keep the abclisten://live/<ID> URL, the station's own title and
# its logo. %opts: name (shown instead of the station's), prefix (starts the L1 description). With a
# cached or last-good program on air (never fetched here), line2 and the description's first line
# say what is on air.
sub _stationItem {
	my ( $client, $rec, %opts ) = @_;

	my $url   = Plugins::ABCListen::Util::liveUrl( $rec->{id} );
	my $name  = defined $opts{name} ? $opts{name} : $rec->{name};
	my $image = Plugins::ABCListen::API::imageUrl( $rec->{logo}, ITEM_IMAGE_PX ) || Plugins::ABCListen::Util::ICON;

	my @description = grep { defined && length } $opts{prefix}, $rec->{synopsis};
	my $description = @description ? join( ' - ', @description ) : undef;

	my ( $line2, $onAir ) = _onAirText( $client, $rec->{id} );
	$description = join( "\n", grep { defined } $onAir, $description ) if defined $onAir;

	return {
		name            => $name,
		line1           => $name,
		( defined $line2 ? ( line2 => $line2 ) : () ),
		favorites_title => $rec->{name},
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		image           => $image,
		favorites_icon  => $image,
		( defined $description ? ( description => $description ) : () ),
	};
}

# (line2, description line) for a station's cached or last-good program on air, or () without one:
#   "On air: <program> · <presenters>"   "<program> (<time slot>) — <presenters>"
sub _onAirText {
	my ( $client, $id ) = @_;

	my $program = eval { $NOW_PLAYING->cached($id) || $NOW_PLAYING->lastGood($id) };
	$log->error( "Could not read the program on air for $id: $@" ) if $@;
	return () unless ref $program eq 'HASH' && defined $program->{title} && length $program->{title};

	my $presenters = defined $program->{presenters} && length $program->{presenters} ? $program->{presenters} : undef;
	my $slot       = $NOW_PLAYING->timeSlot($program);

	my $line2 = cstring( $client, 'PLUGIN_ABCLISTEN_ON_AIR', join( MIDDOT, grep { defined } $program->{title}, $presenters ) );
	my $text  = $program->{title} . ( defined $slot ? " ($slot)" : '' ) . ( defined $presenters ? EM_DASH . $presenters : '' );

	return ( $line2, $text );
}

# homeState pref: one of the 8 state codes, else '' (undef, '' or an invalid hand-edited value).
sub _homeState {
	my $home = eval { $prefs->get('homeState') };
	return defined $home && !ref $home && $STATES{$home} ? $home : '';
}

# ---------------------------------------------------------------------------
# live kind
# ---------------------------------------------------------------------------

sub _resolve {
	my ( $client, $id, $cb ) = @_;

	my $answered = 0;
	my $answer   = sub { $cb->(@_) unless $answered++ };

	$STATIONS->streamCandidates( $id, sub {
		my $result = shift;

		if ( ref $result eq 'ARRAY' && @$result ) {
			my ( $url, @alternates ) = @$result;
			return $answer->( { url => $url, alternates => \@alternates, failToken => LIVE_FAILED } );
		}

		my $error = ref $result eq 'HASH' && $result->{error} ? $result->{error} : LIVE_FAILED;
		$answer->( { error => $error } );
	} );

	return;
}

# === L5 === the live kind's onStream: L2's metadata poll (unchanged), then L5's fallback log (once
# per play). Each part contains its own errors, so one never stops the other.
sub _onStream {
	Plugins::ABCListen::LiveMetadata::onStream(@_);
	eval { $STATIONS->noteStream(@_); 1 } or $log->warn( 'Live stream fallback check failed: ' . ( $@ || 'unknown error' ) );
	return;
}
# === /L5 ===

sub _metadata {
	my ( $client, $url, $id ) = @_;

	my $meta = eval {
		my $rec = $STATIONS->get($id) or return {};

		my %meta = (
			title  => $rec->{name},
			artist => Slim::Utils::Strings::string('PLUGIN_ABCLISTEN'),
		);

		my $cover = Plugins::ABCListen::API::imageUrl( $rec->{logo}, COVER_IMAGE_PX );
		$meta{cover} = $cover if defined $cover;

		my $bitrate = _bitrate( $client, $url, $rec );
		$meta{bitrate} = $bitrate if defined $bitrate;

		\%meta;
	};

	return ref $meta eq 'HASH' ? $meta : {};
}

# StreamGuys Icecast is 56 kbps HE-AAC. undef when the station plays another stream: the client's
# current song for this URL streams from elsewhere (a mediahub alternate), or the station has no
# Icecast stream at all.
sub _bitrate {
	my ( $client, $url, $rec ) = @_;

	my $streamUrl = eval {
		my $song = $client && $client->playingSong;
		$song && $song->currentTrack && $song->currentTrack->url eq $url ? $song->streamUrl : undef;
	};

	if ( defined $streamUrl && !ref $streamUrl ) {
		return $streamUrl =~ m{\Ahttps?://abc\.streamguys1\.com/}i ? ICECAST_BITRATE : undef;
	}

	return $rec->{mount} || $rec->{eventOnly} ? ICECAST_BITRATE : undef;
}

1;
