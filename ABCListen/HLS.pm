package Plugins::ABCListen::HLS;

# Live HLS audio (L6, #80): plays an HLS stream (ABC's .m3u8 live streams) to LMS as ADTS AAC, in pure
# Perl, inside LMS's event loop, with no other plugin and no ffmpeg. The protocol handler
# (Plugins::ABCListen::ProtocolHandler) uses it for a candidate a kind flags { url => <.m3u8>, hls => 1 }:
#
#   HLS->handles($url)          1 for an HLS playlist URL (http(s), path ending .m3u8): the protocol handler
#                               reads a song whose streamUrl is one through this module and never lets the
#                               player stream it directly.
#   HLS->scanUrl($url, \%args)  the scan of an HLS candidate (instead of LMS's remote scanner): loads the
#                               playlist (a master playlist: the AAC variant with the highest bandwidth, then
#                               its media playlist) and the first segment, demuxes it, then calls
#                               $args->{cb} exactly once: ($track) a remote track for $url (content type
#                               aac, bitrate measured from the audio, sample rate, channels), or
#                               (undef, $error) when the stream can't be played (an HTTP error such as a
#                               geo-block 403, an encrypted or byte-range playlist, no AAC audio, a
#                               timeout). The protocol handler then tries its next candidate (Icecast).
#                               The prepared stream is kept for HLS->new (at most PREPARED_MAX streams, for
#                               PREPARED_TTL seconds), so playback starts with the audio already fetched.
#   HLS->new(\%args)            the stream LMS reads (args->{url}: the HLS URL): the prepared stream for the
#                               URL, else a new one. An IO::Handle without a file descriptor, like other
#                               segment-based protocol handlers: sysread returns ADTS AAC bytes, or undef
#                               with $! = EINTR while it waits for data (LMS tries again 0.4 s later), and
#                               0 at the end of the stream. contentType is 'aac', bitrate the measured bps.
#
# Playback (pull-driven: nothing happens between LMS's reads, so there are no timers to leak)
#   * A live playlist (no EXT-X-ENDLIST) starts LIVE_EDGE (3) segments before its end (HLS: no closer
#     than three target durations), a finished one at its first segment.
#   * At most one request at a time, each with a timeout (PLAYLIST_TIMEOUT, SEGMENT_TIMEOUT). The next
#     segment is fetched only when less than BUFFER_LOW bytes of audio are buffered, so the stream holds at
#     most about one segment ahead of the player (whose own buffer smooths playback). TS segments are
#     demuxed DEMUX_SLICE bytes per read, so no read takes long on a slow CPU.
#   * The media playlist is reloaded when the known segments run out: not before its target duration
#     after a reload that brought new segments, half of it after one that didn't (RFC 8216 6.3.4).
#   * If the next segment has left the live window (a long pause, a slow network) or the server restarted
#     its numbering, the stream skips ahead to LIVE_EDGE segments before the end (logged at INFO). After a
#     failed segment the playlist is reloaded before the retry; a segment that fails twice is skipped.
#     EXT-X-DISCONTINUITY and a skip reset the demuxer. After MAX_FAILURES failed requests in a row
#     (backing off 2, 4, 8 s) the stream ends; so does EXT-X-ENDLIST once its last segment is read.
#   * close (LMS: stop, track change, power off) drops the buffers at once; a request still in flight is
#     ignored when it answers (or times out).
#
# Formats: MPEG-TS with ADTS AAC (stream type 0x0F; ABC's mediaserviceslive streams), fragmented MP4
# with AAC (EXT-X-MAP; StreamGuys' Sport Rapid streams, rewrapped as ADTS) and packed ADTS audio (an ID3
# tag is dropped). Not supported (the scan fails, so the protocol handler falls back): encrypted streams
# (EXT-X-KEY other than NONE), EXT-X-BYTERANGE segments, playlists without AAC audio.
#
#   parsePlaylist($body, $url)  -> { type => 'master', variants => [ { url, bandwidth, codecs } ] }
#                                  | { type => 'media', targetDuration, sequence, endList, encrypted, byteRange,
#                                      segments => [ { seq, url, duration, discontinuity, map } ] } | undef
#   chooseVariant(\@variants)   -> the audio-only (mp4a or no CODECS) variant with the highest bandwidth, or undef
#   adtsInfo($bytes)            -> { frames, bytes, sampleRate, channels, seconds, bitrate } of whole ADTS frames
#   Plugins::ABCListen::HLS::TS, ::FMP4, ::Packed   the demuxers: new, feed($bytes) -> ADTS bytes, reset, error
#
# Owned by the live stream (L6).

use strict;
use warnings;

use base qw(IO::Handle);

use Time::HiRes ();
use URI;

use Slim::Utils::Errno;
use Slim::Utils::Log;

use Plugins::ABCListen::HTTP;

use constant PLAYLIST_TIMEOUT => 10;            # seconds
use constant SEGMENT_TIMEOUT  => 20;            # seconds
use constant LIVE_EDGE        => 3;             # start a live playlist this many segments before its end
use constant BUFFER_LOW       => 64 * 1024;     # bytes of audio below which the next segment is fetched
use constant DEMUX_SLICE      => 64 * 1024;     # TS bytes demuxed per read
use constant MAX_FAILURES     => 4;             # failed requests in a row that end the stream
use constant MAX_BACKOFF      => 8;             # seconds between retries, at most
use constant SEGMENT_TRIES    => 2;             # a segment that fails this often is skipped
use constant PREPARED_TTL     => 60;            # seconds a prepared stream waits for HLS->new
use constant PREPARED_MAX     => 4;

my $log = logger('plugin.abclisten');

my %PREPARED;    # HLS URL => { stream, at }

# ---------------------------------------------------------------------------
# Protocol handler interface
# ---------------------------------------------------------------------------

sub handles {
	my ( $class, $url ) = @_;
	return defined $url && !ref $url && $url =~ m{\Ahttps?://[^/?#]+/[^?#]*\.m3u8(?:[?#]|\z)}i ? 1 : 0;
}

sub scanUrl {
	my ( $class, $url, $args ) = @_;

	$args ||= {};
	my $lmsCb = ref $args->{cb} eq 'CODE' ? $args->{cb} : sub { };
	my $done  = 0;
	my $cb    = sub { $lmsCb->(@_) unless $done++ };

	return $cb->( undef, 'HLS: not an HLS URL' ) unless $class->handles($url);

	my $stream = $class->_stream($url);

	_v($stream)->{prepared} = sub {
		my $error = shift;

		if ( defined $error ) {
			main::INFOLOG && $log->is_info && $log->info("HLS stream $url can't be played: $error");
			$stream->close;
			return $cb->( undef, $error );
		}

		my $track = eval { _track( $url, _v($stream) ) };
		if ( !$track ) {
			$log->warn( "HLS stream $url: could not create its track: " . ( $@ || 'unknown error' ) );
			$stream->close;
			return $cb->( undef, 'HLS: no track' );
		}

		_keep( $url, $stream );
		$cb->($track);
	};

	$stream->_pump;
	return;
}

sub new {
	my ( $class, $args ) = @_;

	my $url = $args && $args->{url};
	return undef unless $class->handles($url);

	my $stream = _take($url) || $class->_stream($url);
	my $v      = _v($stream);

	main::INFOLOG && $log->is_info && $log->info( "HLS: streaming $url" . ( $v->{mediaUrl} ? " ($v->{mediaUrl})" : '' ) );

	return $stream;
}

sub contentType { 'aac' }

sub bitrate { _v( $_[0] )->{bitrate} || 0 }

sub isRemote { 1 }

sub sysread {
	my $self = $_[0];
	my $max  = $_[2] || DEMUX_SLICE;
	my $v    = _v($self);

	return 0 if $v->{closed};

	$self->_demux;
	$self->_pump;
	$self->_demux unless length $v->{out};    # a segment that just arrived

	if ( length $v->{out} ) {
		$_[1] = substr( $v->{out}, 0, $max, '' );
		return length $_[1];
	}

	if ( $v->{ended} && !length $v->{pending} ) {
		main::INFOLOG && $log->is_info && $log->info("HLS: end of $v->{url}: $v->{ended}") unless $v->{endLogged}++;
		return 0;
	}

	$! = EINTR;
	return undef;
}

sub close {
	my $self = shift;
	my $v    = _v($self) or return 1;

	return 1 if $v->{closed}++;

	main::INFOLOG && $log->is_info && $log->info("HLS: closing $v->{url}");

	$v->{out} = $v->{pending} = '';
	$v->{demux} = {};
	delete $v->{prepared};

	return 1;
}

# ---------------------------------------------------------------------------
# The stream
# ---------------------------------------------------------------------------

sub _stream {
	my ( $class, $url ) = @_;

	my $self = IO::Handle::new($class);

	${*$self}{abclistenHls} = {
		url        => $url,
		mediaUrl   => undef,     # the media playlist
		playlist   => undef,     # its last parse
		next       => undef,     # sequence number of the next segment
		reset      => 1,         # reset the demuxer before the next segment
		mapUrl     => undef,     # fMP4: the initialisation segment the demuxer was set up with
		demux      => {},        # format => demuxer
		pending    => '',        # the segment being demuxed
		format     => undef,     # its format
		out        => '',        # ADTS audio for LMS
		busy       => 0,         # a request is in flight
		failures   => 0,         # failed requests in a row
		tries      => 0,         # failed attempts at the next segment
		reloadAt   => 0,         # don't reload the playlist before this time
		stale      => 0,         # reload the playlist before the next segment (one failed)
		ended      => undef,     # why the stream ends (no more requests)
		closed     => 0,
		bitrate    => undef,
		sampleRate => undef,
		channels   => undef,
	};

	return $self;
}

sub _v { ref $_[0] && ${ *{ $_[0] } }{abclistenHls} }

# Start the next request, if one is due.
sub _pump {
	my $self = shift;
	my $v    = _v($self);

	return if $v->{busy} || $v->{closed} || $v->{ended};
	return if Time::HiRes::time() < ( $v->{retryAt} || 0 );

	return $self->_loadPlaylist( $v->{mediaUrl} || $v->{url} ) unless $v->{playlist} && !$v->{stale};

	# one segment at a time, and only when the audio buffered runs low
	return if length $v->{pending} || length $v->{out} >= BUFFER_LOW;

	if ( my $segment = $self->_nextSegment ) {
		return $self->_loadMap($segment) if defined $segment->{map} && ( $v->{mapUrl} // '' ) ne $segment->{map};
		return $self->_loadSegment($segment);
	}

	return $self->_end('end of the playlist') if $v->{playlist}->{endList};
	return $self->_loadPlaylist( $v->{mediaUrl} ) if Time::HiRes::time() >= $v->{reloadAt};

	return;
}

# The next segment to fetch, if the playlist has it; sets the start position, and skips ahead when the
# next segment has left the live window.
sub _nextSegment {
	my $self = shift;
	my $v    = _v($self);

	my $segments = $v->{playlist}->{segments};
	return undef unless @$segments;

	my $first = $segments->[0]->{seq};
	my $start = $v->{playlist}->{endList} ? 0 : ( @$segments > LIVE_EDGE ? @$segments - LIVE_EDGE : 0 );

	if ( !defined $v->{next} ) {
		$v->{next} = $segments->[$start]->{seq};
	}
	elsif ( $v->{next} < $first || $v->{next} > $segments->[-1]->{seq} + 1 ) {
		# left the live window (a long pause), or the server restarted its numbering
		main::INFOLOG && $log->is_info && $log->info( "HLS: segment $v->{next} of $v->{url} is not in the playlist ($first-" . $segments->[-1]->{seq} . '); skipping to ' . $segments->[$start]->{seq} );
		$v->{next}  = $segments->[$start]->{seq};
		$v->{reset} = 1;
		$v->{tries} = 0;
	}

	my $i = $v->{next} - $first;
	return $i <= $#$segments ? $segments->[$i] : undef;
}

sub _loadPlaylist {
	my ( $self, $url ) = @_;
	my $v = _v($self);

	my $started = Time::HiRes::time();

	$self->_get( $url, PLAYLIST_TIMEOUT, sub {
		my $body = shift;

		my $playlist = parsePlaylist( $body, $url ) or return $self->_failed("not an HLS playlist ($url)", 1);

		if ( $playlist->{type} eq 'master' ) {
			return $self->_failed("a master playlist inside a master playlist ($url)", 1) if $v->{mediaUrl};

			my $variant = chooseVariant( $playlist->{variants} ) or return $self->_failed("no AAC audio variant ($url)", 1);

			$v->{mediaUrl} = $variant->{url};
			$v->{bitrate}  = $variant->{bandwidth};
			main::INFOLOG && $log->is_info && $log->info( "HLS: $url -> $variant->{url} (" . ( $variant->{codecs} // 'no codecs' ) . ", $variant->{bandwidth} bps)" );

			return $self->_loadPlaylist( $variant->{url} );
		}

		return $self->_failed("encrypted stream (EXT-X-KEY $playlist->{encrypted}) not supported ($url)", 1) if $playlist->{encrypted};
		return $self->_failed("byte-range segments not supported ($url)", 1) if $playlist->{byteRange};

		my $old = $v->{playlist};
		$v->{mediaUrl} ||= $url;
		$v->{stale} = 0;

		if ( !@{ $playlist->{segments} } ) {
			return $self->_failed("the playlist has no segments ($url)") unless $old;
			$playlist = { %$old, endList => $playlist->{endList} };
		}

		my $last    = $playlist->{segments}->[-1]->{seq};
		my $changed = !$old || $last > $old->{segments}->[-1]->{seq} || $playlist->{endList};
		my $wait    = ( $playlist->{targetDuration} || 10 ) * ( $changed ? 1 : 0.5 );

		$v->{playlist} = $playlist;
		$v->{reloadAt} = $started + $wait;

		main::DEBUGLOG && $log->is_debug && $log->debug( "HLS: $url has segments " . $playlist->{segments}->[0]->{seq} . "-$last" . ( $changed ? '' : ' (unchanged)' ) );
	} );

	return;
}

# fMP4: the initialisation segment of the next segment
sub _loadMap {
	my ( $self, $segment ) = @_;
	my $v = _v($self);

	$self->_get( $segment->{map}, SEGMENT_TIMEOUT, sub {
		my $init  = shift;
		my $demux = Plugins::ABCListen::HLS::FMP4->new($init);

		return $self->_failed( 'unsupported fragmented MP4 audio: ' . $demux->error . " ($segment->{map})", 1 ) if $demux->error;

		$v->{demux}->{fmp4} = $demux;
		$v->{mapUrl} = $segment->{map};
	} );

	return;
}

sub _loadSegment {
	my ( $self, $segment ) = @_;
	my $v = _v($self);

	$self->_get(
		$segment->{url},
		SEGMENT_TIMEOUT,
		sub {
			my $body = shift;

			$v->{next}  = $segment->{seq} + 1;
			$v->{tries} = 0;

			my $format = defined $segment->{map} ? 'fmp4' : _format($body) or return $self->_failed("unsupported segment format ($segment->{url})", 1);

			$v->{reset} = 1 if $segment->{discontinuity};

			if ( $v->{reset} ) {
				$_->reset for values %{ $v->{demux} };
				$v->{reset} = 0;
			}

			$v->{demux}->{$format} ||= _demuxer($format);
			$v->{format}  = $format;
			$v->{pending} = $body;

			main::DEBUGLOG && $log->is_debug && $log->debug( "HLS: segment $segment->{seq} ($format, " . length($body) . ' bytes)' );

			$self->_preparedAudio if $v->{prepared};
		},
		sub {
			# reload the playlist before trying again (the segment may have left the window); skip a
			# segment that keeps failing
			$v->{stale} = 1;
			if ( ++$v->{tries} >= SEGMENT_TRIES ) {
				main::INFOLOG && $log->is_info && $log->info("HLS: skipping segment $segment->{seq} ($segment->{url})");
				$v->{next}  = $segment->{seq} + 1;
				$v->{tries} = 0;
				$v->{reset} = 1;
			}
		},
	);

	return;
}

# A prepared stream's first segment arrived: demux it all and measure the audio.
sub _preparedAudio {
	my $self = shift;
	my $v    = _v($self);

	$self->_demux( length $v->{pending} );

	my $error = $v->{demux}->{ $v->{format} }->error;
	my $info  = adtsInfo( $v->{out} );

	if ( !defined $error && !$info ) {
		$error = 'no AAC audio in the first segment';
	}

	if ( !defined $error ) {
		$v->{bitrate}    = $info->{bitrate};
		$v->{sampleRate} = $info->{sampleRate};
		$v->{channels}   = $info->{channels};

		main::INFOLOG && $log->is_info && $log->info( sprintf( 'HLS: %s plays %s AAC, %d Hz, %d channel(s), %d kbps', $v->{url}, $v->{format}, $info->{sampleRate}, $info->{channels}, $info->{bitrate} / 1000 ) );
	}

	my $prepared = delete $v->{prepared};
	$prepared->( defined $error ? "HLS: $error" : undef );

	return;
}

# GET $url; $ok->($body) on success, then the next request is started. A failure counts towards
# MAX_FAILURES (the retries back off) and calls $retry; a preparing stream fails at once.
sub _get {
	my ( $self, $url, $timeout, $ok, $retry ) = @_;
	my $v = _v($self);

	$v->{busy} = 1;

	Plugins::ABCListen::HTTP::get(
		$url,
		sub {
			my $body = shift;
			$v->{busy} = 0;
			return if $v->{closed};

			$v->{failures} = 0;
			$v->{retryAt}  = 0;
			$ok->( defined $body ? $body : '' );

			$self->_pump unless $v->{closed};
		},
		sub {
			my $error = shift;
			$v->{busy} = 0;
			return if $v->{closed};

			$retry->() if $retry;
			$self->_failed( $error || "request failed ($url)" );
		},
		{ timeout => $timeout, quiet => 1 },
	);

	return;
}

# A failed step: a preparing stream fails; a playing one retries later, and ends after MAX_FAILURES
# failures in a row ($fatal: at once).
sub _failed {
	my ( $self, $error, $fatal ) = @_;
	my $v = _v($self);

	if ( my $prepared = delete $v->{prepared} ) {
		return $prepared->("HLS: $error");
	}

	my $failures = ++$v->{failures};

	return $self->_end($error) if $fatal || $failures >= MAX_FAILURES;

	my $backoff = 2**$failures;
	$backoff = MAX_BACKOFF if $backoff > MAX_BACKOFF;
	$v->{retryAt} = Time::HiRes::time() + $backoff;

	main::INFOLOG && $log->is_info && $log->info("HLS: $error; retrying in $backoff s");
	return;
}

sub _end {
	my ( $self, $why ) = @_;
	my $v = _v($self);

	if ( my $prepared = delete $v->{prepared} ) {
		return $prepared->("HLS: $why");
	}

	$v->{ended} ||= $why;
	main::INFOLOG && $log->is_info && $log->info("HLS: $v->{url} ends after the buffered audio: $why");

	return;
}

# Demux (part of) the pending segment into the audio buffer: at most $limit (default DEMUX_SLICE) bytes
# of TS, a whole fMP4 or packed segment.
sub _demux {
	my ( $self, $limit ) = @_;
	my $v = _v($self);

	return unless length $v->{pending};

	my $demux = $v->{demux}->{ $v->{format} };
	my $take  = $v->{format} eq 'ts' ? ( $limit || DEMUX_SLICE ) : length $v->{pending};

	$v->{out} .= $demux->feed( substr( $v->{pending}, 0, $take, '' ) );

	if ( defined $demux->error && !$v->{prepared} ) {
		$v->{pending} = '';
		$self->_end( 'unsupported audio: ' . $demux->error );
	}

	return;
}

# The remote track the scan answers.
sub _track {
	my ( $url, $v ) = @_;

	require Slim::Schema;
	my $track = Slim::Schema->updateOrCreate( { url => $url } ) or return undef;

	$track->content_type('aac');
	$track->bitrate( $v->{bitrate} ) if $v->{bitrate};
	$track->samplerate( $v->{sampleRate} ) if $v->{sampleRate};
	$track->channels( $v->{channels} ) if $v->{channels};

	return $track;
}

# Keep a prepared stream for HLS->new; expired and surplus ones are closed.
sub _keep {
	my ( $url, $stream ) = @_;

	my $now = Time::HiRes::time();

	for my $key ( keys %PREPARED ) {
		my $entry = $PREPARED{$key};
		next if $key ne $url && $now - $entry->{at} < PREPARED_TTL && $now >= $entry->{at};
		delete $PREPARED{$key};
		$entry->{stream}->close;
	}

	$PREPARED{$url} = { stream => $stream, at => $now };

	my @old = sort { $PREPARED{$a}->{at} <=> $PREPARED{$b}->{at} } keys %PREPARED;
	while ( @old > PREPARED_MAX ) {
		my $entry = delete $PREPARED{ shift @old };
		$entry->{stream}->close;
	}

	return;
}

sub _take {
	my $url   = shift;
	my $entry = delete $PREPARED{$url} or return undef;
	my $age   = Time::HiRes::time() - $entry->{at};

	return $entry->{stream} if $age >= 0 && $age < PREPARED_TTL;

	$entry->{stream}->close;
	return undef;
}

# test helpers
sub _prepared { return scalar keys %PREPARED }
sub _reset    { $_->{stream}->close for values %PREPARED; %PREPARED = (); return }

# ---------------------------------------------------------------------------
# Playlists
# ---------------------------------------------------------------------------

sub parsePlaylist {
	my ( $body, $base ) = @_;
	return undef unless defined $body && !ref $body;

	$body =~ s/\A\xEF\xBB\xBF//;
	my @lines = grep { length } map { _trim($_) } split /\r\n|\r|\n/, $body;
	return undef unless @lines && $lines[0] eq '#EXTM3U';

	my $abs = sub { my $u = shift; eval { URI->new_abs( $u, $base )->as_string } // $u };

	if ( grep { /\A#EXT-X-STREAM-INF:/ } @lines ) {
		my ( @variants, $attrs );

		for my $line (@lines) {
			if ( $line =~ /\A#EXT-X-STREAM-INF:(.*)\z/ ) {
				$attrs = _attributes($1);
			}
			elsif ( $attrs && $line !~ /\A#/ ) {
				my $bandwidth = $attrs->{'AVERAGE-BANDWIDTH'} // $attrs->{BANDWIDTH};
				push @variants, {
					url       => $abs->($line),
					bandwidth => defined $bandwidth && $bandwidth =~ /\A\d+\z/ ? $bandwidth + 0 : 0,
					codecs    => $attrs->{CODECS},
				};
				undef $attrs;
			}
		}

		return { type => 'master', variants => \@variants };
	}

	my %playlist = ( type => 'media', targetDuration => 0, sequence => 0, endList => 0, encrypted => undef, byteRange => 0, segments => [] );
	my ( $duration, $discontinuity, $map, $key ) = ( undef, 0, undef, undef );

	for my $line (@lines) {
		if ( $line =~ /\A#EXT-X-TARGETDURATION:\s*(\d+(?:\.\d+)?)/ ) {
			$playlist{targetDuration} = $1 + 0;
		}
		elsif ( $line =~ /\A#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/ ) {
			$playlist{sequence} = $1 + 0;
		}
		elsif ( $line eq '#EXT-X-ENDLIST' ) {
			$playlist{endList} = 1;
		}
		elsif ( $line eq '#EXT-X-DISCONTINUITY' ) {
			$discontinuity = 1;
		}
		elsif ( $line =~ /\A#EXT-X-KEY:(.*)\z/ ) {
			my $method = uc( _attributes($1)->{METHOD} // '' );
			$key = $method eq 'NONE' ? undef : ( length $method ? $method : 'unknown' );
		}
		elsif ( $line =~ /\A#EXT-X-MAP:(.*)\z/ ) {
			my $attrs = _attributes($1);
			$map = defined $attrs->{URI} ? $abs->( $attrs->{URI} ) : undef;
			$playlist{byteRange} = 1 if defined $attrs->{BYTERANGE};
		}
		elsif ( $line =~ /\A#EXT-X-BYTERANGE:/ ) {
			$playlist{byteRange} = 1;
		}
		elsif ( $line =~ /\A#EXTINF:\s*(-?\d+(?:\.\d+)?)?/ ) {
			$duration = defined $1 ? $1 + 0 : 0;
		}
		elsif ( $line !~ /\A#/ ) {
			next unless defined $duration;

			push @{ $playlist{segments} }, {
				seq           => $playlist{sequence} + @{ $playlist{segments} },
				url           => $abs->($line),
				duration      => $duration,
				discontinuity => $discontinuity,
				map           => $map,
			};
			$playlist{encrypted} ||= $key if defined $key;

			( $duration, $discontinuity ) = ( undef, 0 );
		}
	}

	return \%playlist;
}

# KEY=value,KEY="quoted, value" -> { KEY => value }
sub _attributes {
	my $list = shift // '';
	my %attrs;
	while ( $list =~ /\G\s*([A-Z0-9-]+)=("[^"]*"|[^,]*)\s*(?:,|\z)/gc ) {
		my ( $name, $value ) = ( $1, $2 );
		$value =~ s/\A"(.*)"\z/$1/s;
		$attrs{$name} = $value;
	}
	return \%attrs;
}

sub chooseVariant {
	my $variants = shift;
	return undef unless ref $variants eq 'ARRAY';

	my @audio = grep {
		my @codecs = grep { length } map { _trim($_) } split /,/, ( $_->{codecs} // '' );
		!grep { !/\Amp4a\./i } @codecs;
	} grep { ref $_ eq 'HASH' && defined $_->{url} } @$variants;

	my ($best) = sort { ( $b->{bandwidth} || 0 ) <=> ( $a->{bandwidth} || 0 ) } @audio;
	return $best;
}

sub _trim {
	my $s = shift;
	$s =~ s/\A\s+|\s+\z//g;
	return $s;
}

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------

my @SAMPLE_RATES = ( 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 );

sub adtsInfo {
	my $data = shift;
	return undef unless defined $data && length $data;

	my ( $frames, $bytes, $rate, $channels ) = ( 0, 0 );

	for ( my $at = 0; $at + 7 <= length $data; ) {
		my @h = unpack 'C7', substr( $data, $at, 7 );
		last unless $h[0] == 0xFF && ( $h[1] & 0xF6 ) == 0xF0;

		my $length = ( ( $h[3] & 0x03 ) << 11 ) | ( $h[4] << 3 ) | ( $h[5] >> 5 );
		my $header = $h[1] & 0x01 ? 7 : 9;
		last if $length < $header || $at + $length > length $data;

		$rate     //= $SAMPLE_RATES[ ( $h[2] >> 2 ) & 0x0F ];
		$channels //= ( ( $h[2] & 0x01 ) << 2 ) | ( $h[3] >> 6 );

		$frames++;
		$bytes += $length - $header;
		$at    += $length;
	}

	return undef unless $frames && $rate;

	my $seconds = $frames * 1024 / $rate;
	return {
		frames     => $frames,
		bytes      => $bytes,
		sampleRate => $rate,
		channels   => $channels,
		seconds    => $seconds,
		bitrate    => int( $bytes * 8 / $seconds / 1000 + 0.5 ) * 1000,
	};
}

# A 7-byte ADTS header (no CRC) for a raw AAC frame of $size bytes.
sub _adtsHeader {
	my ( $profile, $rateIndex, $channels, $size ) = @_;
	my $length = $size + 7;

	return pack 'C7',
		0xFF, 0xF1,
		( ( $profile & 0x03 ) << 6 ) | ( ( $rateIndex & 0x0F ) << 2 ) | ( ( $channels >> 2 ) & 0x01 ),
		( ( $channels & 0x03 ) << 6 ) | ( ( $length >> 11 ) & 0x03 ),
		( $length >> 3 ) & 0xFF,
		( ( $length & 0x07 ) << 5 ) | 0x1F,
		0xFC;
}

# A segment's format from its first bytes: ts, packed (ADTS, maybe after an ID3 tag), or undef.
sub _format {
	my $data = shift;
	return undef unless defined $data && length $data;

	return 'ts' if substr( $data, 0, 1 ) eq "\x47" && ( length $data < 189 || substr( $data, 188, 1 ) eq "\x47" );
	return 'packed' if substr( $data, 0, 3 ) eq 'ID3' || $data =~ /\A\xFF[\xF0-\xF1\xF8-\xF9]/;
	return undef;
}

sub _demuxer {
	my $format = shift;
	return Plugins::ABCListen::HLS::TS->new     if $format eq 'ts';
	return Plugins::ABCListen::HLS::Packed->new if $format eq 'packed';
	return Plugins::ABCListen::HLS::FMP4->new(undef);    # only without its map
}

# ---------------------------------------------------------------------------
# MPEG-TS -> ADTS: the payload of the first AAC (stream type 0x0F) elementary stream of the first program
# ---------------------------------------------------------------------------

package Plugins::ABCListen::HLS::TS;

use constant PACKET => 188;

sub new { my $self = bless {}, shift; $self->reset; return $self }

# Forget the stream layout and any partial packet (a discontinuity).
sub reset {
	my $self = shift;
	%$self = ( buf => '', pmt => undef, audio => undef, inPes => 0, sync => 1, error => undef );
	return;
}

sub error { $_[0]->{error} }

sub feed {
	my ( $self, $data ) = @_;

	$self->{buf} .= $data if defined $data;

	my $buf = \$self->{buf};
	my $out = '';
	my $at  = 0;

	while ( length($$buf) - $at >= PACKET ) {
		if ( substr( $$buf, $at, 1 ) ne "\x47" ) {
			$at = _resync( $buf, $at + 1 );
			next;
		}

		$out .= $self->_packet( substr( $$buf, $at, PACKET ) );
		$at += PACKET;
	}

	substr( $$buf, 0, $at, '' );

	return $out;
}

# The offset of the next sync byte from $from that is followed by another one a packet later (or is in
# the last packet), else the end of the buffer.
sub _resync {
	my ( $buf, $from ) = @_;

	for ( my $at = index( $$buf, "\x47", $from ); $at >= 0; $at = index( $$buf, "\x47", $at + 1 ) ) {
		return $at if $at + PACKET >= length $$buf || substr( $$buf, $at + PACKET, 1 ) eq "\x47";
	}

	return length $$buf;
}

sub _packet {
	my ( $self, $packet ) = @_;

	my ( undef, $b1, $b2, $b3 ) = unpack 'C4', $packet;
	my $pid  = ( ( $b1 & 0x1F ) << 8 ) | $b2;
	my $pusi = $b1 & 0x40;
	my $afc  = ( $b3 >> 4 ) & 0x03;

	return '' unless $afc & 0x01;    # no payload

	my $start = 4;
	$start += 1 + unpack( 'C', substr( $packet, 4, 1 ) ) if $afc & 0x02;
	return '' if $start >= PACKET;

	my $payload = substr( $packet, $start );

	if ( $pid == 0 ) {
		$self->_pat($payload) if $pusi;
		return '';
	}

	if ( defined $self->{pmt} && $pid == $self->{pmt} ) {
		$self->_pmt($payload) if $pusi;
		return '';
	}

	return '' unless defined $self->{audio} && $pid == $self->{audio};

	if ($pusi) {
		# a PES packet starts: 00 00 01, stream id, length (2), flags (2), header length
		$self->{inPes} = 0;
		return '' unless length $payload >= 9 && substr( $payload, 0, 3 ) eq "\x00\x00\x01";

		my $headerLength = unpack 'C', substr( $payload, 8, 1 );
		return '' if 9 + $headerLength > length $payload;

		$payload = substr( $payload, 9 + $headerLength );
		$self->{inPes} = 1;
	}

	return '' unless $self->{inPes};

	if ( $self->{sync} ) {
		# after a reset, start at an ADTS frame
		return '' unless $payload =~ /\xFF[\xF0-\xF1\xF8-\xF9]/g;
		$payload = substr( $payload, pos($payload) - 2 );
		$self->{sync} = 0;
	}

	return $payload;
}

# The section a PSI payload carries (after the pointer field), or undef.
sub _section {
	my $payload = shift;
	my $pointer = unpack 'C', $payload;
	return undef if 1 + $pointer + 3 > length $payload;

	my $section = substr( $payload, 1 + $pointer );
	my $length  = unpack( 'n', substr( $section, 1, 2 ) ) & 0x0FFF;
	return undef if $length < 9 || 3 + $length > length $section;    # a section across packets: not used by HLS

	return substr( $section, 0, 3 + $length );
}

sub _pat {
	my ( $self, $payload ) = @_;
	my $section = _section($payload) or return;

	# program loop between the 8-byte header and the CRC
	for ( my $i = 8; $i + 4 <= length($section) - 4; $i += 4 ) {
		my ( $program, $pid ) = unpack 'nn', substr( $section, $i, 4 );
		next unless $program;    # 0: the network PID
		$self->{pmt} = $pid & 0x1FFF;
		last;
	}

	return;
}

sub _pmt {
	my ( $self, $payload ) = @_;
	my $section = _section($payload) or return;

	my $infoLength = unpack( 'n', substr( $section, 10, 2 ) ) & 0x0FFF;
	my ( $aac, @types );

	for ( my $i = 12 + $infoLength; $i + 5 <= length($section) - 4; ) {
		my ( $type, $pid, $esLength ) = unpack 'Cnn', substr( $section, $i, 5 );
		push @types, sprintf( '0x%02X', $type );
		$aac //= $pid & 0x1FFF if $type == 0x0F;
		$i += 5 + ( $esLength & 0x0FFF );
	}

	if ( defined $aac ) {
		$self->{audio} = $aac;
		$self->{error} = undef;
	}
	else {
		$self->{error} = 'no ADTS AAC stream in the transport stream (stream types: ' . ( join( ' ', @types ) || 'none' ) . ')';
	}

	return;
}

# ---------------------------------------------------------------------------
# Packed audio (RFC 8216 3.4): ADTS frames, maybe after an ID3 tag (dropped)
# ---------------------------------------------------------------------------

package Plugins::ABCListen::HLS::Packed;

sub new   { bless {}, shift }
sub reset { }
sub error { undef }

sub feed {
	my ( $self, $data ) = @_;
	return '' unless defined $data;

	# ID3v2 tags: "ID3", version (2), flags, size (4 x 7 bits)
	while ( length $data >= 10 && substr( $data, 0, 3 ) eq 'ID3' ) {
		my ( $flags, @size ) = unpack 'x5 C C4', $data;
		my $size = 10 + ( $size[0] << 21 | $size[1] << 14 | $size[2] << 7 | $size[3] ) + ( $flags & 0x10 ? 10 : 0 );
		substr( $data, 0, $size > length $data ? length $data : $size, '' );
	}

	return $data;
}

# ---------------------------------------------------------------------------
# Fragmented MP4 -> ADTS: the AAC samples of the first sound track, each with an ADTS header
# ---------------------------------------------------------------------------

package Plugins::ABCListen::HLS::FMP4;

# new($init): the initialisation segment (moov) gives the track, its AudioSpecificConfig and defaults.
sub new {
	my ( $class, $init ) = @_;
	my $self = bless { error => undef }, $class;

	return $self->_error('no initialisation segment') unless defined $init && length $init;

	my ($moov) = _boxes( \$init, 0, length $init, 'moov' ) or return $self->_error('no moov box');

	for my $trak ( _boxes( \$init, $moov->[1], $moov->[2], 'trak' ) ) {
		my ($tkhd) = _boxes( \$init, $trak->[1], $trak->[2], 'tkhd' ) or next;
		my ($mdia) = _boxes( \$init, $trak->[1], $trak->[2], 'mdia' ) or next;
		my ($hdlr) = _boxes( \$init, $mdia->[1], $mdia->[2], 'hdlr' ) or next;
		next unless substr( $init, $hdlr->[1] + 8, 4 ) eq 'soun';

		my $stsd = _path( \$init, $mdia, qw(minf stbl stsd) ) or next;
		my $entry = $stsd->[1] + 8;    # version/flags, entry count
		next if $entry + 8 > $stsd->[2];

		my ( $size, $type ) = unpack 'Na4', substr( $init, $entry, 8 );
		return $self->_error("sample entry '$type' (encrypted or not AAC)") unless $type eq 'mp4a';

		# AudioSampleEntry: 8-byte box header, 28 bytes of fields (QuickTime sound versions 1 and 2: 16 and
		# 36 more), then child boxes
		my $soundVersion = unpack q(n), substr( $init, $entry + 16, 2 );
		my $children     = $entry + 36 + ( $soundVersion == 1 ? 16 : $soundVersion == 2 ? 36 : 0 );
		my ($esds) = _boxes( \$init, $children, $entry + $size, 'esds' ) or return $self->_error('no esds box');
		my $asc = _decoderConfig( substr( $init, $esds->[1] + 4, $esds->[2] - $esds->[1] - 4 ) ) // return $self->_error('no AudioSpecificConfig');

		my $config = _audioConfig($asc) or return $self->_error( 'unsupported AudioSpecificConfig ' . unpack( 'H*', $asc ) );

		my $version = unpack 'C', substr( $init, $tkhd->[1], 1 );
		$self->{track} = unpack 'N', substr( $init, $tkhd->[1] + ( $version ? 20 : 12 ), 4 );
		$self->{config} = $config;
		last;
	}

	return $self->_error('no AAC sound track') unless $self->{config};

	# trex: the fragments' default sample size for the track
	if ( my $mvex = ( _boxes( \$init, $moov->[1], $moov->[2], 'mvex' ) )[0] ) {
		for my $trex ( _boxes( \$init, $mvex->[1], $mvex->[2], 'trex' ) ) {
			my ( $track, undef, undef, $defaultSize ) = unpack 'x4 N4', substr( $init, $trex->[1], 20 );
			$self->{defaultSize} = $defaultSize if $track == $self->{track};
		}
	}

	return $self;
}

sub reset { }
sub error { $_[0]->{error} }

sub _error {
	my ( $self, $error ) = @_;
	$self->{error} = $error;
	return $self;
}

# A whole media segment (moof + mdat pairs) -> ADTS frames.
sub feed {
	my ( $self, $data ) = @_;
	return '' if $self->{error} || !defined $data || !length $data;

	my ( $out, $samples ) = ('');

	for my $box ( _boxes( \$data, 0, length $data ) ) {
		my ( $type, $start, $end, $boxStart ) = @$box;

		if ( $type eq 'moof' ) {
			$samples = $self->_moof( \$data, $boxStart, $start, $end );
		}
		elsif ( $type eq 'mdat' && $samples ) {
			my $config = $self->{config};
			my $at     = $start;    # samples without a data offset follow each other from the payload start

			for my $sample (@$samples) {
				my ( $offset, $size ) = @$sample;
				$offset = $at unless defined $offset;
				last if $offset < $start || $offset + $size > $end || $size + 7 > 0x1FFF;

				$out .= Plugins::ABCListen::HLS::_adtsHeader( $config->{profile}, $config->{rateIndex}, $config->{channels}, $size ) . substr( $data, $offset, $size );
				$at = $offset + $size;
			}

			undef $samples;
		}
	}

	return $out;
}

# The samples of our track in a moof: [ [ offset in the segment (undef: after the previous sample, from
# the mdat payload start), size ], ... ]
sub _moof {
	my ( $self, $data, $moofStart, $start, $end ) = @_;
	my @samples;

	for my $traf ( _boxes( $data, $start, $end, 'traf' ) ) {
		my ($tfhd) = _boxes( $data, $traf->[1], $traf->[2], 'tfhd' ) or next;
		my ( $flags, $track ) = unpack 'N N', substr( $$data, $tfhd->[1], 8 );
		$flags &= 0xFFFFFF;
		next unless $track == $self->{track};

		my $at   = $tfhd->[1] + 8;
		my $base = $moofStart;
		if ( $flags & 0x01 ) { my ( $hi, $lo ) = unpack 'NN', substr( $$data, $at, 8 ); $base = $hi * 4294967296 + $lo; $at += 8 }
		$at += 4 if $flags & 0x02;
		$at += 4 if $flags & 0x08;
		my $defaultSize = $flags & 0x10 ? unpack( 'N', substr( $$data, $at, 4 ) ) : $self->{defaultSize};

		my $next;    # where the next run's data starts when it has no data offset
		for my $trun ( _boxes( $data, $traf->[1], $traf->[2], 'trun' ) ) {
			my ( $runFlags, $count ) = unpack 'N N', substr( $$data, $trun->[1], 8 );
			$runFlags &= 0xFFFFFF;

			my $p = $trun->[1] + 8;
			my $offset = $next;
			if ( $runFlags & 0x01 ) { $offset = $base + unpack( 'l>', substr( $$data, $p, 4 ) ); $p += 4 }
			$p += 4 if $runFlags & 0x04;

			my @fields = grep { $runFlags & $_ } ( 0x100, 0x200, 0x400, 0x800 );
			my $stride = 4 * @fields;
			return [] if $p + $count * $stride > $trun->[2];

			for my $i ( 0 .. $count - 1 ) {
				my $size = $defaultSize;
				if ( $runFlags & 0x200 ) {
					my $skip = $runFlags & 0x100 ? 4 : 0;
					$size = unpack 'N', substr( $$data, $p + $i * $stride + $skip, 4 );
				}
				return [] unless $size;

				push @samples, [ $offset, $size ];
				$offset += $size if defined $offset;
			}

			$next = $offset;
		}
	}

	return \@samples;
}

# The boxes in [$start, $end) of $$data, optionally only those of $type: [ type, payload start, end,
# box start ].
sub _boxes {
	my ( $data, $start, $end, $want ) = @_;
	my @boxes;

	for ( my $at = $start; $at + 8 <= $end; ) {
		my ( $size, $type ) = unpack 'Na4', substr( $$data, $at, 8 );
		my $header = 8;

		if ( $size == 1 ) {
			last if $at + 16 > $end;
			my ( $hi, $lo ) = unpack 'NN', substr( $$data, $at + 8, 8 );
			$size   = $hi * 4294967296 + $lo;
			$header = 16;
		}
		elsif ( $size == 0 ) {
			$size = $end - $at;
		}

		last if $size < $header || $at + $size > $end;

		push @boxes, [ $type, $at + $header, $at + $size, $at ] if !defined $want || $type eq $want;
		$at += $size;
	}

	return @boxes;
}

sub _path {
	my ( $data, $box, @types ) = @_;
	for my $type (@types) {
		($box) = _boxes( $data, $box->[1], $box->[2], $type ) or return undef;
	}
	return $box;
}

# esds payload (after version/flags) -> the DecoderSpecificInfo bytes, or undef.
sub _decoderConfig {
	my $esds = shift;
	my $at   = 0;

	my $descriptor = sub {
		return () if $at + 2 > length $esds;
		my $tag = unpack 'C', substr( $esds, $at++, 1 );
		my $length = 0;
		for ( 1 .. 4 ) {
			return () if $at >= length $esds;
			my $byte = unpack 'C', substr( $esds, $at++, 1 );
			$length = ( $length << 7 ) | ( $byte & 0x7F );
			last unless $byte & 0x80;
		}
		return ( $tag, $length );
	};

	my ( $tag, $length ) = $descriptor->();
	return undef unless defined $tag && $tag == 0x03;

	my $flags = unpack 'C', substr( $esds, $at + 2, 1 ) // "\0";
	$at += 3;
	$at += 2 if $flags & 0x80;
	$at += 1 + unpack( 'C', substr( $esds, $at, 1 ) // "\0" ) if $flags & 0x40;
	$at += 2 if $flags & 0x20;

	( $tag, $length ) = $descriptor->();
	return undef unless defined $tag && $tag == 0x04;
	$at += 13;

	( $tag, $length ) = $descriptor->();
	return undef unless defined $tag && $tag == 0x05 && $at + $length <= length $esds;

	return substr( $esds, $at, $length );
}

# AudioSpecificConfig -> { profile, rateIndex, channels } for ADTS, or undef. HE-AAC (SBR, PS) is
# signalled as its AAC LC core; the decoder finds the SBR data in the frames (implicit signalling).
sub _audioConfig {
	my $asc  = shift;
	my $bits = unpack 'B*', $asc // '';
	return undef if length $bits < 16;

	my $at   = 0;
	my $read = sub { my $n = shift; my $v = oct( '0b' . substr( $bits, $at, $n ) ); $at += $n; return $v };

	my $objectType = $read->(5);
	$objectType = 32 + $read->(6) if $objectType == 31;

	my $rateIndex = $read->(4);
	return undef if $rateIndex > 12;    # an explicit 24-bit rate: no ADTS index for it

	my $channels = $read->(4);

	if ( $objectType == 5 || $objectType == 29 ) {
		return undef if length $bits < $at + 9;
		my $extensionRate = $read->(4);
		$read->(24) if $extensionRate == 15;
		$objectType = $read->(5);
	}

	return undef unless $objectType >= 1 && $objectType <= 4 && $channels >= 1 && $channels <= 7;

	return { profile => $objectType - 1, rateIndex => $rateIndex, channels => $channels };
}

1;
