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
# Public builder (ai-state/streams.md contract 7):
#   Live->stationItem($client, $serviceId) -> a playable station item, or undef for unknown, hidden,
#   HLS-only and off-air (or not yet known) event services.
#
# live kind
#   resolve   Stations->streamCandidates: { url => first, alternates => [rest], failToken =>
#             PLUGIN_ABCLISTEN_LIVE_FAILED }, or { error => LIVE_HLS_ONLY | LIVE_OFF_AIR |
#             UNAVAILABLE (unknown id) }; exactly one callback.
#   metadata  { title => station name, artist => "ABC listen", cover => logo (~600 px),
#             bitrate => "56kbps CBR" } (no bitrate when the stream playing isn't StreamGuys
#             Icecast); synchronous, no network, never dies. L2 replaces it with program data.
#
# Owned by the live stream: L1 creates; L2 owns _stationItem text (line2/description), L4 its type and
# the station submenu.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

use constant MENU_DEADLINE   => 3;               # seconds
use constant ITEM_IMAGE_PX   => 300;
use constant COVER_IMAGE_PX  => 600;
use constant ICECAST_BITRATE => '56kbps CBR';    # StreamGuys Icecast HE-AAC

use constant LIVE_FAILED => 'PLUGIN_ABCLISTEN_LIVE_FAILED';

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

my $STATIONS = 'Plugins::ABCListen::Stations';

my @STATES = qw(ACT NSW NT QLD SA TAS VIC WA);
my %STATES = map { $_ => 1 } @STATES;

# networks whose row plays the home state's time-zone version (homeState SA, QLD, NT or WA)
my @HOME_VARIANT_NETWORKS = qw(RN TRIPLEJ DOUBLEJ CLASSIC);

sub init {
	Plugins::ABCListen::ProtocolHandler->registerKind(
		live => {
			resolve  => \&_resolve,
			metadata => \&_metadata,
		}
	);

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

	_answer( $client, $cb, 'Radio', sub {
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

	my ( $answered, $timer ) = (0);

	my $answer = sub {
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		_answer( $client, $cb, 'Sport', sub {
			die $listError if defined $listError;
			[ map { _stationItem( $client, $_ ) } grep { $STATIONS->playable( $_->{id} ) } @recs ];
		} );
	};

	eval { $STATIONS->checkOnAir( \@events, $answer ); 1 } or do {
		$log->error( 'Could not check the event services: ' . ( $@ || 'unknown error' ) );
		$answer->();
	};

	return if $answered;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + MENU_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Event services not all known within ' . MENU_DEADLINE . ' s; answering Sport without them' );
		$answer->();
	} );

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

	_answer( $client, $cb, 'Local radio state', sub {
		[ map { _stationItem( $client, $_ ) } grep { $STATIONS->playable( $_->{id} ) } $STATIONS->list( 'local', $state // '' ) ];
	} );
}

sub _variantMenu {
	my ( $client, $cb, $args ) = @_;

	_answer( $client, $cb, 'Time-zone versions', sub {
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
# its logo. %opts: name (shown instead of the station's), prefix (starts the description).
sub _stationItem {
	my ( $client, $rec, %opts ) = @_;

	my $url   = Plugins::ABCListen::Util::liveUrl( $rec->{id} );
	my $name  = defined $opts{name} ? $opts{name} : $rec->{name};
	my $image = Plugins::ABCListen::API::imageUrl( $rec->{logo}, ITEM_IMAGE_PX ) || Plugins::ABCListen::Util::ICON;

	my @description = grep { defined && length } $opts{prefix}, $rec->{synopsis};

	return {
		name            => $name,
		line1           => $name,
		favorites_title => $rec->{name},
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		image           => $image,
		favorites_icon  => $image,
		( @description ? ( description => join( ' - ', @description ) ) : () ),
	};
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
