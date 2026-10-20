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
# that state's time-zone version: same name, favorites_title the version's own title (its station
# menu's "Listen live" says "<City> time ...").
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
# and its station menu's "Listen live" the description "<program> (6:00am–9:00am) — <presenters>"
# (Default skin detail view), then the L1 description ("<City> time - <synopsis>") on a new line.
# stationItem uses cached/last-good data only.
#
# Station rows (L4) both open and play (ai-state/research/lms-plugin-guide.md section 4):
#   { name, line1, line2?, type => 'link', url => \&_stationMenu, passthrough => [<ID>],
#     play => 'abclisten://live/<ID>', favorites_url => the same URL, favorites_type => 'audio',
#     favorites_title => the station's own title, favorites_icon, image }
# No on_select (touch skins open the row; 'play' plays it and is what favourites store, so
# favourites saved before L4, plain abclisten://live/<ID> audio entries, play as before) and no
# description (LMS menu rule 1: a non-audio item with a description can't be opened over JSON-RPC).
#
# Station menu (_stationMenu, passthrough [<ID>]; answered like a station list, so the program on air
# is fetched within MENU_DEADLINE when it isn't cached):
#   Listen live           type audio, on_select play, the live URL and favourites, the station logo,
#                         the description above
#   On air: <program> · <presenters>   text, from NowPlaying's cache / last-good; left out when unknown
#   Today, Yesterday, then the 5 dates before ("Sat 17 Oct"), station-local (Schedule->dayList): links
#                         to the day list (passthrough [<ID>, 'YYYY-MM-DD'], so a menu built at
#                         23:59 still shows the date it was built for)
# Day list (_dayMenu): Schedule->day rows in start order, ABC's broadcast day as returned:
#   name / line1  "6:00am · <program>" (station-local time; the Default skin shows only the name),
#                 " (on air)" added to the row with start <= now < end (the latest such start)
#   rows that have started and have a program path: OnDemand->programItem($client, { title, path,
#                 image, description => synopsis }) (contract 6: O2's program menu, i.e. that
#                 program's catch-up episodes), only name/line1 overridden; line2 = presenters when
#                 O2 set none; image: the schedule's (~340 px), else the station logo
#   other rows (future, no program page, programItem undef): text, line2 = presenters,
#                 description = synopsis, no image (Material shows the day as a list, not a grid)
#   no rows: one PLUGIN_ABCLISTEN_NO_SCHEDULE text item; an error: one LOAD_FAILED (or RATE_LIMITED)
#   text item; answered exactly once, also when building dies or the schedule takes longer than
#   DAY_DEADLINE.
# LMS keeps no browse session for this plugin (code-ref feeds), so every item_id request rebuilds
# the menus and opens the row at that index: the station menu's rows only move when the on-air
# line appears or goes (an id taken before that opens the neighbouring row). Feeds called with a
# stale or unknown station id or date answer one readable error item.
#
# Public builder (ai-state/streams.md contract 7):
#   Live->stationItem($client, $serviceId) -> a station row (link + play, above), or undef for
#   unknown, hidden, HLS-only and off-air (or not yet known) event services. Never fetches;
#   consumers that override line2 do so on their copy (every call builds a new hash).
#
# live kind
#   resolve   Stations->streamCandidates: { url => first, alternates => [rest], failToken =>
#             PLUGIN_ABCLISTEN_LIVE_FAILED }, or { error => LIVE_HLS_ONLY | LIVE_OFF_AIR |
#             UNAVAILABLE (unknown id) }; exactly one callback.
#   metadata, onStream, onStop
#             Plugins::ABCListen::LiveMetadata (L2): the program on air (L3: the song on music
#             stations), polled per master player and pushed to Now Playing. Its station fallback is
#             _metadata here: { title => station name, artist => "ABC listen", cover => logo
#             (~600 px), bitrate => "56kbps CBR" } (no bitrate when the stream playing isn't
#             StreamGuys Icecast); synchronous, no network, never dies. onStream (_onStream) also
#             logs a fallback to another stream family once per play (L5: Stations->noteStream);
#             a LiveMetadata onStream that dies is logged and doesn't stop it.
# Song info: LiveMetadata->trackInfo ("Program info") and, after it, LiveMetadata->recentInfo
# ("Recently played", L3), registered as Slim::Menu::TrackInfo providers.
#
# Pref liveQuality (L5): initialised and validated in init; Stations reads it at play time.
#
# Owned by the live stream: L1 creates; L2 owns _stationItem text (line2), L4 its type, the station
# menu and the day lists (data: Plugins::ABCListen::Schedule).

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
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Schedule;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

use constant MENU_DEADLINE   => 3;               # seconds
use constant DAY_DEADLINE    => 15;              # seconds (the schedule request times out after 10)
use constant ITEM_IMAGE_PX   => 300;
use constant COVER_IMAGE_PX  => 600;
use constant ICECAST_BITRATE => '56kbps CBR';    # StreamGuys Icecast HE-AAC

use constant LIVE_FAILED  => 'PLUGIN_ABCLISTEN_LIVE_FAILED';
use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';
use constant NO_SCHEDULE  => 'PLUGIN_ABCLISTEN_NO_SCHEDULE';

use constant MIDDOT  => " \x{B7} ";
use constant EM_DASH => " \x{2014} ";

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

my $STATIONS    = 'Plugins::ABCListen::Stations';
my $NOW_PLAYING = 'Plugins::ABCListen::NowPlaying';
my $METADATA    = 'Plugins::ABCListen::LiveMetadata';
my $SCHEDULE    = 'Plugins::ABCListen::Schedule';
my $ONDEMAND    = 'Plugins::ABCListen::OnDemand';

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

	# L3: "Recently played" (main music stations), right after "Program info"
	Slim::Menu::TrackInfo->registerInfoProvider( abclistenRecentlyPlayed => (
		after => 'abclistenProgramInfo',
		func  => \&Plugins::ABCListen::LiveMetadata::recentInfo,
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
			return _stationItem( $client, $variant, name => $rec->{name} );
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

# The distinct live service ids of a list of items (from their abclisten://live/ URLs: a station
# row's play, Listen live's url).
sub _liveIds {
	my $items = shift;
	return () unless ref $items eq 'ARRAY';

	my %seen;
	return grep { !$seen{$_}++ } map {
		my $url    = ref $_ eq 'HASH' ? ( defined $_->{play} ? $_->{play} : $_->{url} ) : undef;
		my $parsed = defined $url && !ref $url ? Plugins::ABCListen::Util::parseUrl($url) : undef;
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

# A station row (L4): a link to the station menu that also plays the station (play). Favourites keep
# the abclisten://live/<ID> URL, the station's own title and its logo. %opts: name (shown instead
# of the station's). With a cached or last-good program on air (never fetched here), line2 says
# what is on air. No description (LMS menu rule 1; the station menu's Listen live carries it).
sub _stationItem {
	my ( $client, $rec, %opts ) = @_;

	my $url   = Plugins::ABCListen::Util::liveUrl( $rec->{id} );
	my $name  = defined $opts{name} ? $opts{name} : $rec->{name};
	my $image = _logo($rec);

	my ($line2) = _onAirText( $client, $rec->{id} );

	return {
		name            => $name,
		line1           => $name,
		( defined $line2 ? ( line2 => $line2 ) : () ),
		type            => 'link',
		url             => \&_stationMenu,
		passthrough     => [ $rec->{id} ],
		play            => $url,
		favorites_url   => $url,
		favorites_type  => 'audio',
		favorites_title => $rec->{name},
		image           => $image,
		favorites_icon  => $image,
	};
}

sub _logo {
	my $rec = shift;
	return Plugins::ABCListen::API::imageUrl( $rec->{logo}, ITEM_IMAGE_PX ) || Plugins::ABCListen::Util::ICON;
}

# ---------------------------------------------------------------------------
# Station menu and day lists (L4)
# ---------------------------------------------------------------------------

sub _stationMenu {
	my ( $client, $cb, $args, $id ) = @_;

	# answered like a station list: Listen live's URL makes _answerStations fetch the program on air
	_answerStations( $client, $cb, 'station', sub { _stationMenuItems( $client, $id ) } );

	return;
}

sub _stationMenuItems {
	my ( $client, $id ) = @_;

	my $rec = _isServiceId($id) ? $STATIONS->get($id) : undef;
	return [ _textItem( $client, LOAD_FAILED ) ] unless ref $rec eq 'HASH';

	my $url   = Plugins::ABCListen::Util::liveUrl( $rec->{id} );
	my $image = _logo($rec);

	my ( $line2, $onAir ) = _onAirText( $client, $rec->{id} );

	my $prefix = ( $rec->{group} || '' ) eq 'variant' && _hasText( $rec->{city} )
		? cstring( $client, 'PLUGIN_ABCLISTEN_CITY_TIME', $rec->{city} )
		: undef;
	my $about       = join( ' - ', grep { _hasText($_) } $prefix, $rec->{synopsis} );
	my $description = join( "\n", grep { _hasText($_) } $onAir, $about );

	my @items = ( {
		name            => cstring( $client, 'PLUGIN_ABCLISTEN_LISTEN_LIVE' ),
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		favorites_title => $rec->{name},
		image           => $image,
		favorites_icon  => $image,
		( length $description ? ( description => $description ) : () ),
	} );

	push @items, { name => $line2, type => 'text' } if defined $line2;

	for my $day ( @{ $SCHEDULE->dayList( $rec->{tz}, time() ) } ) {
		push @items, {
			name        => $day->{token} ? cstring( $client, $day->{token} ) : $day->{label},
			type        => 'link',
			url         => \&_dayMenu,
			passthrough => [ $rec->{id}, $day->{date} ],
		};
	}

	return \@items;
}

sub _dayMenu {
	my ( $client, $cb, $args, $id, $date ) = @_;

	my ( $answered, $timer ) = ( 0, undef );
	my $what = 'schedule ' . ( defined $id ? $id : '?' ) . ' ' . ( defined $date ? $date : '?' );

	my $answer = sub {
		my $build = shift;
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		_answer( $client, $cb, $what, $build );
	};

	eval {
		$SCHEDULE->day( $id, $date, sub {
			my ( $rows, $error ) = @_;
			$answer->( sub { _dayItems( $client, $id, $rows, $error ) } );
		} );
		1;
	} or do {
		$log->error( "Could not get the $what: " . ( $@ || 'unknown error' ) );
		$answer->( sub { [ _textItem( $client, LOAD_FAILED ) ] } );
	};

	return if $answered;

	# Schedule->day always calls back (its request times out first); this only guards the menu
	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + DAY_DEADLINE, sub {
		undef $timer;
		$log->warn( "The $what took longer than " . DAY_DEADLINE . ' s' );
		$answer->( sub { [ _textItem( $client, LOAD_FAILED ) ] } );
	} );

	return;
}

sub _dayItems {
	my ( $client, $id, $rows, $error ) = @_;

	return [ _textItem( $client, defined $error && $error eq RATE_LIMITED ? RATE_LIMITED : LOAD_FAILED ) ] unless ref $rows eq 'ARRAY';
	return [ _textItem( $client, NO_SCHEDULE ) ] unless @$rows;

	my $rec  = $STATIONS->get($id);
	my $logo = ref $rec eq 'HASH' ? _logo($rec) : Plugins::ABCListen::Util::ICON;
	my $now  = time();

	# on air: start <= now < end; with overlaps, the latest start
	my $onAir;
	for my $i ( 0 .. $#$rows ) {
		my $row = $rows->[$i];
		next unless $row->{start} <= $now && defined $row->{end} && $now < $row->{end};
		$onAir = $i if !defined $onAir || $row->{start} >= $rows->[$onAir]->{start};
	}

	my $mark = cstring( $client, 'PLUGIN_ABCLISTEN_ON_AIR_MARK' );
	my @items;

	for my $i ( 0 .. $#$rows ) {
		my $row   = $rows->[$i];
		my $name  = $row->{timeLabel} . MIDDOT . $row->{title};
		my $image = $row->{image} || $logo;
		$name .= " $mark" if defined $onAir && $i == $onAir;

		# a program that has started: its catch-up episodes (O2's program menu)
		if ( $row->{start} <= $now && defined $row->{programPath} ) {
			my $item = eval {
				$ONDEMAND->programItem( $client, {
					title => $row->{title},
					path  => $row->{programPath},
					image => $image,
					( defined $row->{synopsis} ? ( description => $row->{synopsis} ) : () ),
				} );
			};
			$log->error("Could not build the program row for $row->{programPath}: $@") if $@;

			if ( ref $item eq 'HASH' ) {
				$item->{name}  = $item->{line1} = $name;
				$item->{line2} = $row->{presenters} if defined $row->{presenters} && !defined $item->{line2};
				push @items, $item;
				next;
			}
		}

		# no image on a text row: Material turns a text item with an image into a grid tile (the whole
		# day becomes a grid of truncated captions, line2 printed as a literal "<br/>"); without one
		# it shows the day as a list
		push @items, {
			name  => $name,
			line1 => $name,
			type  => 'text',
			( defined $row->{presenters} ? ( line2       => $row->{presenters} ) : () ),
			( defined $row->{synopsis}   ? ( description => $row->{synopsis} )   : () ),
		};
	}

	return \@items;
}

sub _textItem {
	my ( $client, $token ) = @_;
	return { name => cstring( $client, $token ), type => 'text' };
}

sub _hasText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

sub _isServiceId { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[A-Z0-9_]+\z/ }

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
# per play). Each part contains its own errors, so one never stops the other (L3: the metadata
# poll is wrapped here too, so a die in it can't skip the fallback check).
sub _onStream {
	eval { Plugins::ABCListen::LiveMetadata::onStream(@_); 1 } or $log->warn( 'Live metadata onStream failed: ' . ( $@ || 'unknown error' ) );
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
