package Plugins::ABCListen::LiveMetadata;

# Now Playing metadata for live stations (abclisten://live/<SERVICE_ID>), and its per-player
# poll/push engine. A port of the reference plugin's RTRFM/LiveMetadata.pm, generalised to many
# services. Program mode (L2): the program on air from Plugins::ABCListen::NowPlaying. Track mode
# (L3): the song playing now on music stations, from Plugins::ABCListen::Tracks, falling back to
# program mode between songs, on talk stations and without song data.
#
#   init(stationMeta => \&code)    called from Live->init. stationMeta($client, $url, $id) is the
#                                  live kind's station metadata (L1: { title => station name,
#                                  artist => "ABC listen", cover => logo, bitrate }, {} when unknown).
#   metadata($client, $url, $id)   the live kind's metadata hook (ProtocolHandler kind registry):
#                                  synchronous, no network, never dies. buildMeta of the station
#                                  metadata, NowPlaying's cached (else last-good) program and, for a
#                                  service with song data, Tracks->current (the song while it is
#                                  current, with last-good). When the program isn't fresh it starts
#                                  an asynchronous NowPlaying->programNow and returns what it has;
#                                  songs are only fetched by the poll (only while someone plays the
#                                  station). For a player that plays (or pauses on) this URL
#                                  without a running poll, it also starts the poll (stale-poll
#                                  recovery: after an LMS restart, a reconnect, or forgotten timers).
#   onStream($client, $song, $id)  starts the poll for $client's master (sync groups: one poll per
#                                  master, whichever player LMS calls this for), or moves it to $id.
#                                  A poll already running for the master and $id is kept.
#   onStop($song, $id)             stops the master's poll, if it polls $id.
#   buildMeta($station, $program[, $song])
#                                  pure. Track mode (a $song with a title): the station metadata
#                                  with title => song, artist => song artist || station name,
#                                  album => "<program> · <station name>" (without a program: the
#                                  song's album (release), else the station name), cover => song
#                                  cover || program image || station cover. Else, no program: the
#                                  station metadata. Program mode: the station metadata with
#                                  title => program, artist => presenters || station name, album =>
#                                  station name, cover => program image || station cover.
#   nextDelay($program, $now)      pure: seconds to the next poll, end + BOUNDARY_GRACE (30) - now
#                                  clamped to MIN_DELAY..MAX_DELAY (60-900); MIN_DELAY without a
#                                  program or its end.
#   trackInfo($client, $url, ...)  Slim::Menu::TrackInfo provider (registered by Live->init): for a
#                                  known live station, a "Program info" link; undef for other URLs.
#                                  The link's feed answers exactly once, within INFO_DEADLINE (3 s):
#                                  the station synopsis (textarea, first: in menu mode LMS blanks
#                                  rows listed before a textarea), "On air: <program> · <time slot>",
#                                  "Presented by <presenters>", "Next: <program> · <time slot>"
#                                  (NowPlaying->programNext, fetched only here); rows without data
#                                  are left out (the station name when nothing is known).
#   recentInfo($client, $url, ...) Slim::Menu::TrackInfo provider (L3, registered by Live->init
#                                  after "Program info"): for the main music stations
#                                  (Tracks->station; not talk stations, not time-zone versions), a
#                                  "Recently played" link; undef for other URLs. Its feed answers
#                                  exactly once, within INFO_DEADLINE (3 s): up to RECENT_ROWS (10)
#                                  text rows "9:41pm · Artist – Title" (server local time,
#                                  Util::friendlyTime; no time or no artist: that part left out);
#                                  empty, failed or late: one text row "No recently played songs".
#
# Polling: one Slim::Utils::Timers timer per master player (keyed on the player object) refreshes
# what is due for the service it plays: NowPlaying (cached until the program ends) and, for a
# service with song data, Tracks (cached until next_updated, 20-120 s). The next poll comes at the
# minimum of the program delay (nextDelay: program end + 30 s, clamped 60-900 s; ERROR_DELAY (30 s)
# after a failed program fetch), the track delay (Tracks->pollIn: next_updated - now, clamped
# 20-120 s; 30 s after a failed song fetch; none without song data) and, while a song is current,
# its end (Tracks->songEnd - now, at least 20 s; that poll is answered from Tracks' cache and
# pushes program mode on time), and ERROR_DELAY after an update that dies. A poll stops (kills its timer, makes no fetch) once the master is neither
# playing nor paused, or its current playlist URL isn't the polled live URL any more, and on
# onStop; switching to a station without songs stops the song fetches with it. A poll with neither
# a pending timer nor a fetch in flight, or kept for another client object with the same id (a
# reconnected player), is stale and is replaced at the next metadata call. Services nobody plays
# are never polled; all players share NowPlaying's and Tracks' caches, so one upstream request per
# refresh per service.
#
# Push, when { title, artist, album, cover } differs from what was last pushed to the master (kept
# on the player, so a restarted poll doesn't re-push): ProtocolHandler::getMetadataFor dispatches
# to the metadata hook above and ignores the song's pluginData(wmaMeta), so nothing is written
# there: the hook already reads NowPlaying's and Tracks' updated caches. The sequence is
#   Slim::Music::Info::setCurrentTitle($url, $title)          (no client: not a new song)
#   $master->currentPlaylistUpdateTime(Time::HiRes::time())    (the Default skin refreshes on it)
#   Slim::Control::Request::notifyFromArray($master, ['newmetadata'])   (Material, players)
# $song->duration / startOffset are never touched, and setCurrentTitle never gets a client.
#
# Logging: DEBUG for each poll, push and stop decision. Fetch failures are logged by NowPlaying. An
# unexpected exception is logged at ERROR the first time, then at DEBUG.
#
# Owned by the live stream: L2 creates, L3 extends (track mode) (ai-state/streams.md, rule 5).

use strict;
use warnings;

use Scalar::Util ();
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Tracks;
use Plugins::ABCListen::Util;

use constant BOUNDARY_GRACE => 30;    # poll this long after the program's end
use constant MIN_DELAY      => 60;
use constant MAX_DELAY      => 900;
use constant ERROR_DELAY    => 30;
use constant INFO_DEADLINE  => 3;     # seconds for the Program info and Recently played feeds
use constant RECENT_ROWS    => 10;

use constant PUSHED_KEY => 'liveMetaPushed';
use constant MIDDOT     => " \x{B7} ";
use constant EN_DASH    => " \x{2013} ";

my $log = logger('plugin.abclisten');

my $NOW_PLAYING = 'Plugins::ABCListen::NowPlaying';
my $TRACKS      = 'Plugins::ABCListen::Tracks';

my $stationMeta;    # code ref: the live kind's station metadata (L1)
my %polls;          # master id => { master, id, url, timer (weak; undef once fired or killed), fetching }
my %errorsSeen;     # unexpected errors already logged at ERROR

sub init {
	my ( $class, %args ) = @_;
	$stationMeta = $args{stationMeta} if ref $args{stationMeta} eq 'CODE';
	return;
}

# ---------------------------------------------------------------------------
# The live kind's hooks
# ---------------------------------------------------------------------------

sub metadata {
	my ( $client, $url, $id ) = @_;

	my $meta = eval { _metadata( $client, $url, $id ) };
	return $meta if ref $meta eq 'HASH';

	_unexpected( 'Live metadata failed', $@ );

	$meta = eval { _station( $client, $url, $id ) };
	return ref $meta eq 'HASH' ? $meta : {};
}

sub _metadata {
	my ( $client, $url, $id ) = @_;

	my $station = _station( $client, $url, $id );
	return {} unless %$station;

	my $program = $NOW_PLAYING->cached($id);

	if ( !$program ) {
		# not fresh: refresh in the background (answered from NowPlaying's cache, negative cache or
		# a request already in flight without a new request), use the last good program meanwhile
		$NOW_PLAYING->programNow( $id, sub { } );
		$program = $NOW_PLAYING->cached($id) || $NOW_PLAYING->lastGood($id);
	}

	if ( $client && ( my $master = $client->master ) ) {
		_start( $master, $id, 'metadata for a live URL it plays, without a running poll' )
			if !_polling( $master, $id ) && _playsUrl( $master, $url );
	}

	# the song (L3): from Tracks' cache only (the poll fetches it, while someone plays the station)
	my $song = $TRACKS->hasSongs($id) ? $TRACKS->current($id) : undef;

	return buildMeta( $station, $program, $song );
}

sub onStream {
	my ( $client, $song, $id ) = @_;

	eval {
		my $master = $client && $client->master;
		_start( $master, $id, 'onStream' ) if $master && !_polling( $master, $id );
		1;
	} or _unexpected( 'Live metadata onStream failed', $@ );

	return;
}

sub onStop {
	my ( $song, $id ) = @_;

	eval {
		my $master = $song && $song->master;
		my $state  = $master && $polls{ $master->id };
		_stop( $master, 'onStop' ) if $state && $state->{id} eq ( $id // '' );
		1;
	} or _unexpected( 'Live metadata onStop failed', $@ );

	return;
}

# ---------------------------------------------------------------------------
# Pure parts
# ---------------------------------------------------------------------------

sub buildMeta {
	shift if _isClass( $_[0] );
	my ( $station, $program, $song ) = @_;

	my %meta = ref $station eq 'HASH' ? %$station : ();
	my $hasProgram = ref $program eq 'HASH' && _isText( $program->{title} );

	if ( ref $song eq 'HASH' && _isText( $song->{title} ) ) {
		my $name = $meta{title};

		$meta{title}  = $song->{title};
		$meta{artist} = _isText( $song->{artist} ) ? $song->{artist} : $name;
		$meta{album}  = $hasProgram ? join( MIDDOT, grep { _isText($_) } $program->{title}, $name )
			: _isText( $song->{album} ) ? $song->{album}
			: $name;
		$meta{cover} = $song->{cover} if _isText( $song->{cover} );
		$meta{cover} = $program->{image} if !_isText( $song->{cover} ) && $hasProgram && _isText( $program->{image} );

		delete $meta{$_} for grep { !defined $meta{$_} } keys %meta;

		return \%meta;
	}

	return \%meta unless $hasProgram;

	my $name = $meta{title};

	$meta{title}  = $program->{title};
	$meta{artist} = _isText( $program->{presenters} ) ? $program->{presenters} : $name;
	$meta{album}  = $name;
	$meta{cover}  = $program->{image} if _isText( $program->{image} );

	delete $meta{$_} for grep { !defined $meta{$_} } keys %meta;

	return \%meta;
}

sub nextDelay {
	shift if _isClass( $_[0] );
	my ( $program, $now ) = @_;
	$now = Time::HiRes::time() unless defined $now;

	return MIN_DELAY unless ref $program eq 'HASH' && defined $program->{end};

	my $delay = $program->{end} + BOUNDARY_GRACE - $now;
	return $delay < MIN_DELAY ? MIN_DELAY : $delay > MAX_DELAY ? MAX_DELAY : $delay;
}

# ---------------------------------------------------------------------------
# Poll engine
# ---------------------------------------------------------------------------

sub _start {
	my ( $master, $id, $why ) = @_;

	my $old = $polls{ $master->id };
	_stop( $old->{master}, "switching to $id" ) if $old;

	$polls{ $master->id } = { master => $master, id => $id, url => Plugins::ABCListen::Util::liveUrl($id) };

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: start polling ' . $id . ' for ' . _who($master) . " ($why)" );

	_poll($master);
	return;
}

# True while $master has a live poll for $id: its timer pending or its fetch in flight.
sub _polling {
	my ( $master, $id ) = @_;

	my $state = $polls{ $master->id } or return 0;
	return 0 unless $state->{master} == $master && ( $state->{timer} || $state->{fetching} );
	return defined $id ? $state->{id} eq $id : 1;
}

sub _poll {
	my $master = shift;

	Slim::Utils::Timers::killTimers( $master, \&_poll );

	my $state = $polls{ $master->id } or return;
	return unless $state->{master} == $master;
	delete $state->{timer};

	eval {
		if ( _playsUrl( $master, $state->{url} ) ) {
			main::DEBUGLOG && $log->is_debug && $log->debug( "Live metadata: polling $state->{id} for " . _who($master) );
			_fetch( $master, $state );
		}
		else {
			_stop( $master, "not playing $state->{url} any more" );
		}
		1;
	} or do {
		_unexpected( 'Live metadata poll failed', $@ );
		delete $state->{fetching};
		_schedule( $master, ERROR_DELAY ) if _isCurrent( $master, $state );
	};

	return;
}

# Refresh what is due: the program (NowPlaying) and, for a service with song data, the song
# (Tracks); both answer from their caches when fresh. _fetched runs once both have answered.
sub _fetch {
	my ( $master, $state ) = @_;

	my $id = $state->{id};
	my @sources = ( [ program => sub { $NOW_PLAYING->programNow( $id, @_ ) } ] );
	push @sources, [ track => sub { $TRACKS->now( $id, @_ ) } ] if $TRACKS->hasSongs($id);

	my %results;
	my $left = @sources;
	$state->{fetching} = 1;

	for my $source (@sources) {
		my ( $name, $start ) = @$source;

		my $once = 0;
		my $done = sub {
			return if $once++;
			$results{$name} = [@_];
			_fetched( $master, $state, \%results ) unless --$left;
		};

		eval { $start->($done); 1 } or do {
			_unexpected( "Live metadata $name fetch failed", $@ );
			$done->( undef, 'request failed' );
		};
	}

	return;
}

# The answers of NowPlaying (and Tracks), synchronous or not. Never dies: an update that fails is
# retried after ERROR_DELAY rather than leaving the poll without a timer.
sub _fetched {
	my ( $master, $state, $results ) = @_;

	delete $state->{fetching};

	eval { _update( $master, $state, $results ); 1 } or do {
		_unexpected( 'Live metadata update failed', $@ );
		_schedule( $master, ERROR_DELAY ) if _isCurrent( $master, $state );
	};

	return;
}

sub _update {
	my ( $master, $state, $results ) = @_;

	# stopped, or stopped and started again, while the request was in flight
	return unless _isCurrent( $master, $state );

	my $url = $state->{url};
	return _stop( $master, "not playing $url any more" ) unless _playsUrl( $master, $url );

	my $id = $state->{id};
	my ( $program, $error ) = @{ $results->{program} || [] };

	# track mode (L3): the song while it is current (with last-good), and its refresh delay
	my $hasSongs   = $results->{track} ? 1 : 0;
	my $song       = $hasSongs ? $TRACKS->current($id) : undef;
	my $trackDelay = $hasSongs ? $TRACKS->pollIn($id)  : undef;

	my $now   = Time::HiRes::time();
	my $delay = defined $error ? ERROR_DELAY : nextDelay( $program, $now );
	$delay = $trackDelay if defined $trackDelay && $trackDelay < $delay;

	# a current song that ends before that: poll at its end (answered from Tracks' cache), so the
	# switch to program mode is pushed when it happens
	if ( $song && defined( my $end = $TRACKS->songEnd($song) ) ) {
		my $endDelay = $end - $now;
		$endDelay = Plugins::ABCListen::Tracks::MIN_TTL if $endDelay < Plugins::ABCListen::Tracks::MIN_TTL;
		$delay    = $endDelay if $endDelay < $delay;
	}

	if ( defined $error && !$song ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Live metadata: no program data for $id (fetch failed), no push" );
		return _schedule( $master, $delay );
	}

	my $meta = buildMeta( _station( $master, $url, $id ), $program || $NOW_PLAYING->lastGood($id), $song );

	if ( _changed( $master->pluginData(PUSHED_KEY), $meta ) ) {
		_push( $master, $url, $meta );
		$master->pluginData( PUSHED_KEY, { map { $_ => $meta->{$_} } grep { defined $meta->{$_} } qw(title artist album cover) } );
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: unchanged for ' . _who($master) . ', no push' );
	}

	_schedule( $master, $delay );
	return;
}

sub _isCurrent {
	my ( $master, $state ) = @_;
	my $current = $polls{ $master->id };
	return $current && $current == $state;
}

sub _schedule {
	my ( $master, $delay ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_poll );
	my $timer = Slim::Utils::Timers::setTimer( $master, Time::HiRes::time() + $delay, \&_poll );

	# weak: undef once the timer has fired or been killed (also by LMS's forgetTimer)
	if ( my $state = $polls{ $master->id } ) {
		$state->{timer} = $timer;
		Scalar::Util::weaken( $state->{timer} );
	}

	main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( 'Live metadata: next poll for %s in %d s', _who($master), $delay ) );
	return;
}

sub _stop {
	my ( $master, $reason ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_poll );
	delete $polls{ $master->id };

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: stop polling for ' . _who($master) . ": $reason" );
	return;
}

sub _changed {
	my ( $old, $new ) = @_;
	return 1 unless ref $old eq 'HASH';

	for my $key (qw(title artist album cover)) {
		my ( $x, $y ) = ( $old->{$key}, $new->{$key} );
		return 1 if defined $x != defined $y || ( defined $x && $x ne $y );
	}

	return 0;
}

sub _push {
	my ( $master, $url, $meta ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( "Live metadata: push '%s' to %s", $meta->{title} // '', _who($master) ) );

	Slim::Music::Info::setCurrentTitle( $url, $meta->{title} );
	$master->currentPlaylistUpdateTime( Time::HiRes::time() );
	Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

	return;
}

# The URL $master plays (or pauses on) is $url.
sub _playsUrl {
	my ( $master, $url ) = @_;

	return 0 unless defined $url && ( $master->isPlaying || $master->isPaused );

	my $current = Slim::Player::Playlist::url($master);
	return defined $current && !ref $current && $current eq $url ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Song info: "Program info"
# ---------------------------------------------------------------------------

sub trackInfo {
	my ( $client, $url ) = @_;

	my $item = eval {
		my $parsed = Plugins::ABCListen::Util::parseUrl($url);
		return undef unless $parsed && $parsed->{kind} eq 'live' && Plugins::ABCListen::Stations->get( $parsed->{id} );

		{
			name        => cstring( $client, 'PLUGIN_ABCLISTEN_PROGRAM_INFO' ),
			type        => 'link',
			url         => \&_programInfo,
			passthrough => [ $parsed->{id} ],
		};
	};
	_unexpected( 'Program info entry failed', $@ ) if $@;

	return $item;
}

sub _programInfo {
	my ( $client, $cb, $args, $id ) = @_;

	my ( $answered, $timer, $left, $next ) = ( 0, undef, 2 );

	my $answer = sub {
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		my $items = eval { _programInfoItems( $client, $id, $next ) };
		if ( ref $items ne 'ARRAY' ) {
			_unexpected( 'Program info failed', $@ );
			$items = [ { name => cstring( $client, 'PLUGIN_ABCLISTEN_ERROR' ), type => 'text' } ];
		}

		$cb->( { items => $items } );
	};

	my $doneOne = sub { $answer->() unless --$left };

	for my $fetch (
		[ programNow  => sub { $doneOne->() } ],
		[ programNext => sub { $next = $_[0]; $doneOne->() } ],
	) {
		my ( $method, $done ) = @$fetch;
		my $once = 0;
		eval { $NOW_PLAYING->$method( $id, sub { $done->(@_) unless $once++ } ); 1 } or do {
			_unexpected( "Program info $method failed", $@ );
			$done->() unless $once++;
		};
	}

	return if $answered;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + INFO_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( "Program info for $id: answering after " . INFO_DEADLINE . ' s with what is known' );
		$answer->();
	} );

	return;
}

sub _programInfoItems {
	my ( $client, $id, $next ) = @_;

	my $rec = Plugins::ABCListen::Stations->get($id) || {};
	my $now = $NOW_PLAYING->cached($id) || $NOW_PLAYING->lastGood($id);

	my @items;
	push @items, { type => 'textarea', wrap => 1, name => $rec->{synopsis} } if _isText( $rec->{synopsis} );

	if ($now) {
		push @items, { type => 'text', name => cstring( $client, 'PLUGIN_ABCLISTEN_ON_AIR', _label($now) ) };
		push @items, { type => 'text', name => cstring( $client, 'PLUGIN_ABCLISTEN_PRESENTED_BY', $now->{presenters} ) } if _isText( $now->{presenters} );
	}

	push @items, { type => 'text', name => cstring( $client, 'PLUGIN_ABCLISTEN_NEXT', _label($next) ) } if ref $next eq 'HASH' && _isText( $next->{title} );

	push @items, { type => 'text', name => $rec->{name} } if !@items && _isText( $rec->{name} );

	return \@items;
}

# "<program> · <time slot>", or the program alone without a time.
sub _label {
	my $program = shift;
	my $slot    = $NOW_PLAYING->timeSlot($program);
	return defined $slot ? $program->{title} . MIDDOT . $slot : $program->{title};
}

# ---------------------------------------------------------------------------
# Song info: "Recently played" (L3)
# ---------------------------------------------------------------------------

sub recentInfo {
	my ( $client, $url ) = @_;

	my $item = eval {
		my $parsed = Plugins::ABCListen::Util::parseUrl($url);
		return undef unless $parsed && $parsed->{kind} eq 'live' && $TRACKS->station( $parsed->{id} );

		{
			name        => cstring( $client, 'PLUGIN_ABCLISTEN_RECENTLY_PLAYED' ),
			type        => 'link',
			url         => \&_recentlyPlayed,
			passthrough => [ $parsed->{id} ],
		};
	};
	_unexpected( 'Recently played entry failed', $@ ) if $@;

	return $item;
}

sub _recentlyPlayed {
	my ( $client, $cb, $args, $id ) = @_;

	my ( $answered, $timer ) = (0);

	my $answer = sub {
		my $plays = shift;
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		my $items = eval { _recentItems( $client, $plays ) };
		if ( ref $items ne 'ARRAY' ) {
			_unexpected( 'Recently played failed', $@ );
			$items = [ { name => cstring( $client, 'PLUGIN_ABCLISTEN_NO_RECENT_TRACKS' ), type => 'text' } ];
		}

		$cb->( { items => $items } );
	};

	eval { $TRACKS->recent( $id, RECENT_ROWS, sub { $answer->( $_[0] ) } ); 1 } or do {
		_unexpected( 'Recently played fetch failed', $@ );
		$answer->(undef);
	};

	return if $answered;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + INFO_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( "Recently played for $id: no answer within " . INFO_DEADLINE . ' s' );
		$answer->(undef);
	} );

	return;
}

# Text rows "9:41pm · Artist – Title" (newest first), or one row saying there are none.
sub _recentItems {
	my ( $client, $plays ) = @_;

	my @items;
	for my $play ( ref $plays eq 'ARRAY' ? @$plays : () ) {
		next unless ref $play eq 'HASH' && _isText( $play->{title} );

		my $song = _isText( $play->{artist} ) ? $play->{artist} . EN_DASH . $play->{title} : $play->{title};
		my $time = Plugins::ABCListen::Util::friendlyTime( $play->{playedTime} );

		push @items, { type => 'text', name => defined $time ? $time . MIDDOT . $song : $song };
		last if @items >= RECENT_ROWS;
	}

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_ABCLISTEN_NO_RECENT_TRACKS' ), type => 'text' } ];
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The live kind's station metadata (a copy; {} when unknown or without init).
sub _station {
	my ( $client, $url, $id ) = @_;
	return {} unless $stationMeta;

	my $meta = $stationMeta->( $client, $url, $id );
	return ref $meta eq 'HASH' ? {%$meta} : {};
}

sub _who {
	my $master = shift;
	my $name = eval { $master->can('name') ? $master->name : undef };
	return defined $name && length $name ? "$name (" . $master->id . ')' : $master->id;
}

# Log an unexpected exception at ERROR the first time, at DEBUG after that (metadata runs on every
# status request).
sub _unexpected {
	my ( $what, $problem ) = @_;

	$problem = 'unknown problem' unless defined $problem && length $problem;
	$problem =~ s/\s+\z//;
	my $message = "$what: $problem";

	if ( $errorsSeen{$message}++ ) {
		main::DEBUGLOG && $log->is_debug && $log->debug($message);
	}
	else {
		$log->error($message);
	}

	return;
}

sub _isText { defined $_[0] && !ref $_[0] && length $_[0] }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# test helper: forget all poll state (a restarted LMS starts like this)
sub _reset {
	Slim::Utils::Timers::killTimers( $_->{master}, \&_poll ) for values %polls;
	%polls      = ();
	%errorsSeen = ();
	return;
}

1;
