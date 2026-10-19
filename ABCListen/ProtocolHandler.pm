package Plugins::ABCListen::ProtocolHandler;

# Protocol handler for abclisten:// URLs (Plugins::ABCListen::Util URL contract), registered by
# Plugin.pm. A thin handler, modelled on core Slim::Plugin::Podcast::ProtocolHandler and the
# "Thin Protocol Handler" notes in LMS DEVELOPERS.txt. Playlists, favourites and presets only
# ever hold the stable abclisten:// URL; the stream is chosen at play time by the URL's kind,
# which a feature module registers here. The handler itself knows nothing about ABC.
#
# FROZEN after F2 (ai-state/streams.md contract 4, parallel-work rule 1): kinds plug in through
# registerKind from their own module; changes to this file need orchestrator sign-off.
#
# Kind registry contract
# ======================
#
#   Plugins::ABCListen::ProtocolHandler->registerKind($kind, \%impl)
#     $kind  matches ^[a-z]+$ and is the URL kind from Util::parseUrl: 'live' (registered by
#            Live->init), 'episode' (registered by Episode->init).
#     %impl  resolve and metadata (code refs, required); onStream and onStop (code refs,
#            optional). Any other name, value or key croaks: it is a programming error, and the
#            hook engine's eval around init logs it. Registering a kind again replaces the
#            previous registration (logged at INFO).
#
#   resolve($client, $id, $cb)                                    ($client may be undef)
#     Called at play time (scanUrl) with the id from the URL. Synchronous or asynchronous; it
#     must call $cb exactly once, with one of:
#       { error => 'PLUGIN_ABCLISTEN_<...>' }   the item can't be played; the player shows this
#                                               string token
#       { url        => $candidate,             tried first
#         alternates => [ $candidate, ... ],    optional, tried in order after a failed scan
#         meta       => { title, artist, album, cover, duration },
#                                               optional, kept in memory for getMetadataFor
#         failToken  => 'PLUGIN_ABCLISTEN_<...>' }
#                                               optional, reported when no candidate plays
#                                               (default PLUGIN_ABCLISTEN_STREAM_FAILED)
#     A candidate is a URL string or { url => $url, hls => 1 }. Undef, empty and duplicate
#     candidates are dropped, and so is every URL matching /\.m3u8(\?|$)/i that isn't flagged
#     hls => 1: LMS can't play HLS, so only the PlayHLS path (L5) may flag one. No candidate
#     left: failToken. Each candidate is scanned by the core remote scanner (SUPER::scanUrl) in
#     turn; the first that scans plays.
#     Misbehaving resolvers are contained: if resolve dies before calling back, or doesn't call
#     back within RESOLVE_TIMEOUT (20) seconds, the play fails with
#     PLUGIN_ABCLISTEN_STREAM_FAILED; a second or late call of $cb is ignored, and a die after
#     the first call is logged (the answer counts). $cb never dies: only resolve itself runs in
#     the eval that reports "Resolve for <url> died"; a synchronous answer is played after
#     resolve returns.
#
#   metadata($client, $url, $id) -> \%meta                        ($client may be undef)
#     Synchronous, no network, cheap: LMS calls it for every status and display refresh.
#     Returns any of { title, artist, album, cover, duration }. Only non-empty scalar values
#     are used; a non-hash result, or an exception (logged), counts as no metadata.
#
#   onStream($client, $song, $id)    onStop($song, $id)           (optional)
#     LMS's onStream/onStop for a song whose current track is a URL of this kind, plus the
#     parsed id: when it starts streaming (also after a seek) and when it stops. Exceptions are
#     logged and contained.
#
# What the handler does
# =====================
#   scanUrl       URL -> Util::parseUrl (unparseable: PLUGIN_ABCLISTEN_BAD_URL) -> kind (not
#                 registered: PLUGIN_ABCLISTEN_UNAVAILABLE) -> resolve -> scan the candidates.
#                 After the first successful scan: $song->streamUrl is the scanned (possibly
#                 redirected) stream URL, the track title comes from getMetadataFor, the cover
#                 embedded in the stream is dropped, the track URL is the abclisten:// URL again
#                 (byte for byte) and the playlist update time is bumped. Every failure calls
#                 back (undef, $token) and is logged at INFO with the URL and the token.
#                 LMS's callback runs exactly once on every path: if core code dies before it
#                 (the scanner, or the scanned track or song), the play fails with
#                 PLUGIN_ABCLISTEN_STREAM_FAILED and the die is logged at WARN as the scan's; a
#                 die in LMS's callback is logged at WARN as LMS's and contained. Neither is
#                 reported as a resolve failure.
#   new           opens $song->streamUrl, except after a redirect (proxied streaming), where it
#                 keeps the redirected URL to avoid a redirect loop.
#   getMetadataFor  synchronous, no network, never dies. For abclisten:// URLs, these layers
#                 merged, later ones winning: { title => PLUGIN_ABCLISTEN, cover and icon =>
#                 Util::ICON } < the meta of the URL's last resolve (kept for the last META_MAX
#                 (100) URLs) < the kind's metadata. {} for other URLs. getCurrentTitle gives the
#                 same title; getIcon is Util::ICON.
#   It never sets the song's duration or startOffset (seeking and the progress bar depend on
#   them) and never sets the current title with a client (that fires 'newsong'). Kinds that push
#   live metadata do so in their own code.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Carp qw(croak);
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

use Plugins::ABCListen::Util;

use constant RESOLVE_TIMEOUT => 20;     # seconds a kind's resolve may take
use constant META_MAX        => 100;    # resolve meta is kept for this many URLs (oldest evicted)
use constant BAD_URL       => 'PLUGIN_ABCLISTEN_BAD_URL';
use constant UNAVAILABLE   => 'PLUGIN_ABCLISTEN_UNAVAILABLE';
use constant STREAM_FAILED => 'PLUGIN_ABCLISTEN_STREAM_FAILED';

my $log = logger('plugin.abclisten');

# implementation keys: name => required
my %IMPL_KEYS = ( resolve => 1, metadata => 1, onStream => 0, onStop => 0 );

my %KINDS;         # kind => { resolve, metadata, onStream?, onStop? }
my %META;          # abclisten:// URL => meta of its last resolve (non-empty scalar values only)
my @META_ORDER;    # the URLs in %META, oldest first
# ---------------------------------------------------------------------------
# Kind registry
# ---------------------------------------------------------------------------

sub registerKind {
	my ( $class, $kind, $impl ) = @_;

	if ( !defined $kind || ref $kind || $kind !~ /\A[a-z]+\z/ ) {
		croak( 'registerKind: the kind must match ^[a-z]+$, not ' . ( defined $kind ? "'$kind'" : 'undef' ) );
	}

	croak("registerKind('$kind'): the implementation must be a hash ref") unless ref $impl eq 'HASH';

	for my $key ( sort keys %$impl ) {
		croak("registerKind('$kind'): unknown key '$key' (allowed: resolve, metadata, onStream, onStop)") unless exists $IMPL_KEYS{$key};
		croak("registerKind('$kind'): '$key' must be a code ref") unless ref $impl->{$key} eq 'CODE';
	}

	for my $key ( grep { $IMPL_KEYS{$_} } sort keys %IMPL_KEYS ) {
		croak("registerKind('$kind'): '$key' (a code ref) is required") unless $impl->{$key};
	}

	main::INFOLOG && $log->is_info && $log->info("Replacing the registration of kind '$kind'") if $KINDS{$kind};

	$KINDS{$kind} = {%$impl};

	return 1;
}

# ---------------------------------------------------------------------------
# Playback
# ---------------------------------------------------------------------------

sub scanUrl {
	my ( $class, $url, $args ) = @_;

	# everything the play needs apart from $args (the scan callbacks may not refer to $args); cb
	# is LMS's callback, wrapped to run exactly once (see _callbackOnce)
	my $state = { url => $url, song => $args->{song} };
	( $state->{cb}, $state->{calledBack} ) = _callbackOnce( $url, $args->{cb} );

	my $cb     = $state->{cb};
	my $parsed = Plugins::ABCListen::Util::parseUrl($url) or return _fail( $cb, $url, BAD_URL );
	my $kind   = $KINDS{ $parsed->{kind} }               or return _fail( $cb, $url, UNAVAILABLE );

	my $answered  = 0;
	my $inResolve = 1;
	my ( $syncAnswer, $timer );

	# resolve's callback. It isn't stored in $args, so it may refer to $args.
	my $resolved = sub {
		my $result = shift;

		if ( $answered++ ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Resolve for $url called back more than once, or after the timeout; ignoring the extra call");
			return;
		}

		# a synchronous answer is played after resolve returns, outside the eval that guards the
		# kind's code, so a die in the scanner or in LMS's callback isn't taken for the resolver's
		if ($inResolve) {
			$syncAnswer = [$result];
			return;
		}

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		$class->_play( $state, $args, $result );
		return;
	};

	# only the kind's code runs in this eval
	my $ok    = eval { $kind->{resolve}->( $args->{client}, $parsed->{id}, $resolved ); 1 };
	my $error = $@;
	$inResolve = 0;

	if ( !$ok ) {
		$log->warn( "Resolve for $url died: " . ( $error || 'unknown error' ) );

		# an answer given before the die still counts
		return _fail( $cb, $url, STREAM_FAILED ) unless $answered++;
	}

	return $class->_play( $state, $args, $syncAnswer->[0] ) if $syncAnswer;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + RESOLVE_TIMEOUT, sub {
		undef $timer;
		return if $answered++;

		main::INFOLOG && $log->is_info && $log->info( "Resolve for $url did not call back within " . RESOLVE_TIMEOUT . ' s' );
		_fail( $cb, $url, STREAM_FAILED );
	} );

	return;
}

# LMS's scan callback, wrapped so that it runs at most once (a further call is ignored, at DEBUG).
# An exception in it is LMS's own: it is logged as such and contained, so it never reaches the
# kind's code, the scanner or _guard, and is never taken for a resolve or scan failure. Returns
# the wrapper and a ref to a flag that is true once the callback has run.
sub _callbackOnce {
	my ( $url, $lmsCb ) = @_;

	$lmsCb ||= sub { };
	$url = '' unless defined $url;

	my $calledBack = 0;

	my $cb = sub {
		if ( $calledBack++ ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Ignoring a further play callback for $url");
			return;
		}

		eval { $lmsCb->(@_); 1 } or $log->warn( "LMS's play callback for $url died: " . ( $@ || 'unknown error' ) );
		return;
	};

	return ( $cb, \$calledBack );
}

# Run $code: core code on the way to LMS's callback (the remote scanner, the scanned track and the
# song). If it dies, the exception is logged as $what's, and the play fails with STREAM_FAILED
# unless LMS's callback already ran, so the callback runs exactly once whatever happens.
sub _guard {
	my ( $state, $what, $code ) = @_;

	return if eval { $code->(); 1 };

	my $error = $@ || 'unknown error';

	if ( ${ $state->{calledBack} } ) {
		$log->warn("$what for $state->{url} died after the play callback: $error");
		return;
	}

	$log->warn("$what for $state->{url} died: $error");
	_fail( $state->{cb}, $state->{url}, STREAM_FAILED );

	return;
}

# resolve's answer: fail with its error token, or scan its candidates.
sub _play {
	my ( $class, $state, $args, $result ) = @_;

	my ( $url, $cb ) = @$state{qw(url cb)};

	return _fail( $cb, $url, STREAM_FAILED ) unless ref $result eq 'HASH';
	return _fail( $cb, $url, _isText( $result->{error} ) ? $result->{error} : STREAM_FAILED ) if exists $result->{error};

	_rememberMeta( $url, $result->{meta} ) if ref $result->{meta} eq 'HASH';

	my $failToken  = _isText( $result->{failToken} ) ? $result->{failToken} : STREAM_FAILED;
	my @candidates = _candidates( $url, $result );

	return _fail( $cb, $url, $failToken ) unless @candidates;

	# the args for each alternate's scan: a copy of $args, without LMS's callback
	my %base = %$args;
	delete $base{cb};

	$state->{base}       = \%base;
	$state->{candidates} = \@candidates;
	$state->{failToken}  = $failToken;

	$class->_scan( $state, $args, 0 );

	return;
}

# The usable candidate URLs, in order: url, then the alternates; no undef, empty or duplicate
# ones, and no .m3u8 unless flagged hls.
sub _candidates {
	my ( $url, $result ) = @_;

	my ( @candidates, %seen );

	for my $candidate ( $result->{url}, ref $result->{alternates} eq 'ARRAY' ? @{ $result->{alternates} } : () ) {
		my ( $streamUrl, $hls ) = ref $candidate eq 'HASH' ? ( $candidate->{url}, $candidate->{hls} ) : ( $candidate, 0 );

		next unless _isText($streamUrl);

		if ( $streamUrl =~ /\.m3u8(\?|$)/i && !$hls ) {
			main::INFOLOG && $log->is_info && $log->info("Skipping HLS candidate $streamUrl for $url (not flagged hls)");
			next;
		}

		push @candidates, $streamUrl unless $seen{$streamUrl}++;
	}

	return @candidates;
}

# Scan candidate $i with the core remote scanner.
sub _scan {
	my ( $class, $state, $args, $i ) = @_;

	my $url       = $state->{url};
	my $streamUrl = $state->{candidates}->[$i];

	main::INFOLOG && $log->is_info && $log->info("Scanning $streamUrl for $url");

	# the wrapped callback is stored in $args, so it must not refer to $args itself: that would be a
	# reference cycle, leaking the args hash, the callback and the song on every play. The scanner
	# may call it later, from its own context, so it is guarded too.
	$args->{cb} = sub {
		my @answer = @_;
		_guard( $state, "Handling the scan of $streamUrl", sub { $class->_scanned( $state, $i, @answer ) } );
		return;
	};

	_guard( $state, "Scanning $streamUrl", sub { $class->SUPER::scanUrl( $streamUrl, $args ) } );

	return;
}

# The scanner's answer for candidate $i: after a failed scan, on to the next candidate (or
# failToken); otherwise set up the track and the song, and call LMS's callback.
sub _scanned {
	my ( $class, $state, $i, $track, @rest ) = @_;

	my $url       = $state->{url};
	my $streamUrl = $state->{candidates}->[$i];

	if ( !$track ) {
		my $error = $rest[0];
		main::INFOLOG && $log->is_info && $log->info( "Scan of $streamUrl for $url failed: " . ( defined $error ? $error : 'unknown error' ) );

		if ( $i < $#{ $state->{candidates} } ) {
			return $class->_scan( $state, { %{ $state->{base} } }, $i + 1 );
		}

		return _fail( $state->{cb}, $url, $state->{failToken} );
	}

	my $song = $state->{song};

	# the scanned track's URL is the streamable (maybe redirected) URL
	$song->streamUrl( $track->url ) if $song;

	# the stored title is the item's, from getMetadataFor (no client)
	$track->title( $class->getMetadataFor( undef, $url )->{title} );

	# ignore cover art in the stream, so getMetadataFor's cover is shown
	$track->cover(0);

	# from now on the track is the abclisten:// URL, byte for byte, so playlist and favourites
	# matching keep working
	$track->url($url);

	# the web UI only refreshes the playlist when this changes
	$song->master->currentPlaylistUpdateTime( Time::HiRes::time() ) if $song;

	$state->{cb}->( $track, @rest );

	return;
}

sub _fail {
	my ( $cb, $url, $token ) = @_;

	main::INFOLOG && $log->is_info && $log->info( "Can't play " . ( defined $url ? $url : '' ) . ": $token" );

	$cb->( undef, $token );
	return;
}

sub new {
	my ( $class, $args ) = @_;

	# stream the resolved URL; after a redirect, keep the redirected URL to avoid a loop
	$args->{url} = $args->{song}->streamUrl if $args->{song} && !$args->{redir};

	return $class->SUPER::new($args);
}

sub onStream {
	my ( $class, $client, $song ) = @_;

	my ( $hook, $id ) = _songHook( $song, 'onStream' ) or return;

	eval { $hook->( $client, $song, $id ); 1 } or $log->warn( 'onStream failed for ' . $song->currentTrack->url . ': ' . ( $@ || 'unknown error' ) );

	return;
}

sub onStop {
	my ( $class, $song ) = @_;

	my ( $hook, $id ) = _songHook( $song, 'onStop' ) or return;

	eval { $hook->( $song, $id ); 1 } or $log->warn( 'onStop failed for ' . $song->currentTrack->url . ': ' . ( $@ || 'unknown error' ) );

	return;
}

# The kind hook $name for the song's current track, and the id; () if there is none.
sub _songHook {
	my ( $song, $name ) = @_;

	my $track  = $song && $song->currentTrack or return;
	my $parsed = Plugins::ABCListen::Util::parseUrl( $track->url ) or return;
	my $kind   = $KINDS{ $parsed->{kind} } or return;

	return $kind->{$name} ? ( $kind->{$name}, $parsed->{id} ) : ();
}

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	return {} unless defined $url && $url =~ m{\Aabclisten://};

	my $icon = Plugins::ABCListen::Util::ICON;
	my %meta = ( title => Slim::Utils::Strings::string('PLUGIN_ABCLISTEN'), cover => $icon, icon => $icon );

	%meta = ( %meta, %{ $META{$url} } ) if $META{$url};

	my $parsed = Plugins::ABCListen::Util::parseUrl($url);
	my $kind   = $parsed && $KINDS{ $parsed->{kind} };

	if ($kind) {
		my $kindMeta = eval { $kind->{metadata}->( $client, $url, $parsed->{id} ) };
		$log->warn("Metadata for $url failed: $@") if $@;

		%meta = ( %meta, _textFields($kindMeta) ) if ref $kindMeta eq 'HASH';
	}

	return \%meta;
}

sub getCurrentTitle {
	my ( $class, $client, $url ) = @_;
	return $class->getMetadataFor( $client, $url )->{title};
}

sub getIcon { Plugins::ABCListen::Util::ICON }

sub isRemote { 1 }

# Keep a resolve's meta for getMetadataFor; the oldest of more than META_MAX URLs is dropped.
sub _rememberMeta {
	my ( $url, $meta ) = @_;

	@META_ORDER = grep { $_ ne $url } @META_ORDER if exists $META{$url};

	$META{$url} = { _textFields($meta) };
	push @META_ORDER, $url;

	delete $META{ shift @META_ORDER } while @META_ORDER > META_MAX;

	return;
}

# The non-empty scalar values of a hash.
sub _textFields {
	my $hash = shift;
	return map { ( $_ => $hash->{$_} ) } grep { _isText( $hash->{$_} ) } keys %$hash;
}

sub _isText { defined $_[0] && !ref $_[0] && length $_[0] }

1;
