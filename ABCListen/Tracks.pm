package Plugins::ABCListen::Tracks;

# Songs on ABC's music stations: the song playing now and the recently played list, from ABC's
# public music API (https://music.abcradio.net.au/api/v1/plays/..., API::music) and, for the
# time-zone versions of the music networks, the site's BFF (musicNowPlaying, API::bff) (research
# abc-listen-api.md section 5). Data only: used by the live Now Playing metadata and its song info
# (LiveMetadata.pm).
#
# Which services have song data (from the station catalogue, Stations->get):
#   main music stations   a record with musicStation (triple j, Double J, Unearthed, ABC Jazz, ABC
#                         Country, ABC Classic, Classic 2, triple j Hottest, ABC KIDS listen):
#                         GET plays/<musicStation>/now.json
#   time-zone versions    a variant (group 'variant') of a network with musicStation (TRIPLEJ_*,
#                         DOUBLEJ_*, CLASSIC_*): GET core-next/api/musicNowPlaying/<VARIANT_ID>?tz=<its
#                         tz> (upper-case id). Never the parent's feed: a time-zone version plays
#                         the network hours later.
#   anything else         (talk, local, sport, Radio Australia, RN and Kids listen versions,
#                         unknown ids) no song data: no request to any music endpoint, ever.
#
#   Tracks->station($id)          the music API station name of a main music station, else undef
#   Tracks->hasSongs($id)         1 for a main music station or a time-zone version of one, else 0
#   Tracks->now($id, $cb)         $cb->($song), $cb->(undef) (no song now: between songs, or no
#                                 song data for $id) or $cb->(undef, $error): exactly one call,
#                                 synchronous from the cache, else when the request is done
#   Tracks->current($id)          the song to show now, without a request: the last song ABC
#                                 reported while it is current (songEnd still ahead; played_time in
#                                 the future counts as current) and at most one empty or failed
#                                 answer came after it (last-good: one transient miss is
#                                 bridged, the second means program mode); else undef
#   Tracks->pollIn($id)           seconds until the cached answer for $id is due a refresh (the
#                                 track delay of LiveMetadata's poll): ttl(nextUpdated) after a song
#                                 or an empty answer, ERROR_TTL (30) after a failure; undef without
#                                 song data (no-data answers, services without songs, nothing
#                                 cached)
#   Tracks->recent($id, $n, $cb)  main music stations only: $cb->(\@plays) (up to $n, newest
#                                 first, possibly empty) or $cb->(undef, $error), exactly once.
#                                 GET plays/search.json?station=<musicStation>&order=desc&limit=10,
#                                 cached RECENT_TTL (60 s), failures ERROR_TTL (30 s); coalesced
#   parseNow($data, $fallbackArtist)       pure: a decoded plays/<station>/now.json -> $song | undef
#   parseMapiNow($data, $fallbackArtist)   pure: a decoded BFF musicNowPlaying -> $song | undef
#   parseRecent($data, $n)                 pure: a decoded plays/search.json -> \@plays
#   songEnd($song)                         pure: playedTime + duration; without a duration (or
#                                          without playedTime) nextUpdated + END_GRACE (30 s);
#                                          undef when neither is known
#   ttl($nextUpdated, $now)                pure: nextUpdated - now clamped to MIN_TTL..MAX_TTL
#                                          (20-120 s); DEFAULT_TTL (60) without nextUpdated
# Each can be called as a function or as a class method.
#
# $song = { title, artist, album, cover, playedTime, duration, nextUpdated }
#   title        now.recording.title (BFF: mapiNow.title); no title = no song
#   artist       now.summary.artist when not empty; else the recording's artists[] of type
#                'primary' joined with ', '; else $fallbackArtist (the station name). For ABC Classic
#                summary.artist is the composer, "Last, First" ("Boccherini, Luigi"): performers
#                are not shown. BFF: mapiNow.artist, else $fallbackArtist.
#   album        now.release.title (else the recording's first release), plus " (<release_year>)"
#                when it has a 4-digit year; BFF: mapiNow.release.title or releaseTitle; else undef
#   cover        the release artwork's sizes[] entry nearest COVER_PX (580) px wide, square sizes
#                (1x1) first, else that artwork's url; else the same from the recording's artwork;
#                BFF: release artwork, else primaryImage; else undef. resize.abcradio.net.au URLs
#                are signed, so they are used as ABC gives them.
#   playedTime   epoch of played_time (BFF: playedTime), or undef
#   duration     recording.duration (BFF: duration) in seconds when a positive number, else undef
#   nextUpdated  epoch of the response's next_updated (BFF: nextUpdated), or undef
# $play = { playedTime, artist, title } (artist as above, undef when unknown; title required)
# Text is entity-decoded, whitespace collapsed and trimmed, never truncated.
#
# Cache (in memory, per service): an answer (song or empty now) until ttl(nextUpdated) (20-120 s;
# 60 s without next_updated, 20 s when it has passed). No song data for the service (HTTP 400 from
# the music API, e.g. rn or local_sydney; for a time-zone version, mapiNow null/missing/{}, a `null`
# body, or HTTP 4xx (not 429) or 500, which BFF answers for every variant id as of 2026-10-19) ->
# undef, NO_DATA_TTL (6 h), logged at INFO, never at WARN. Any other failure (5xx, 429, timeout,
# bad JSON) -> ERROR_TTL (30 s), logged at WARN once per run of consecutive failures, then at DEBUG.
# Identical requests are coalesced: one upstream request per service for every caller. API.pm is
# called with quiet => 1 (its own logging at DEBUG only) and without a ttl (no second cache).
#
# Owned by the live stream: L3 creates (ai-state/streams.md, rule 5).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

use constant MIN_TTL      => 20;
use constant MAX_TTL      => 120;
use constant DEFAULT_TTL  => 60;          # no next_updated
use constant ERROR_TTL    => 30;
use constant NO_DATA_TTL  => 6 * 3600;
use constant RECENT_TTL   => 60;
use constant RECENT_LIMIT => 10;          # rows asked of plays/search.json
use constant END_GRACE    => 30;          # a song without a duration is current until nextUpdated + 30 s
use constant MAX_MISSES   => 1;           # empty/failed answers bridged by the last good song
use constant TIMEOUT      => 8;           # seconds per request
use constant COVER_PX     => 580;

my $log = logger('plugin.abclisten');

my %CACHE;        # $id => { song | undef, error | undef, noData, nextUpdated, expires }
my %LAST_GOOD;    # $id => { song, bound (current-until when songEnd is unknown), misses }
my %RECENT;       # $id => { plays | undef, error | undef, expires }
my %WAITERS;      # "now:$id" | "recent:$id" => [ callbacks ] while a request is in flight
my %FAILURES;     # "now:$id" | "recent:$id" => consecutive failed requests

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub station {
	shift if _isClass( $_[0] );
	my $rec = _record(shift) or return undef;
	return _isMain($rec) ? $rec->{musicStation} : undef;
}

sub hasSongs {
	shift if _isClass( $_[0] );
	return _source(shift) ? 1 : 0;
}

sub now {
	shift if _isClass( $_[0] );
	my ( $id, $cb ) = @_;

	$cb = _once( $cb, 'song for ' . ( defined $id && !ref $id ? $id : '?' ) );

	# talk, local and sport services (and unknown ids) never reach a music endpoint
	my $source = _source($id) or return $cb->(undef);

	if ( my $entry = $CACHE{$id} ) {
		if ( _now() < $entry->{expires} ) {
			return $cb->( undef, $entry->{error} ) if defined $entry->{error};
			return $cb->( $entry->{song} ? { %{ $entry->{song} } } : undef );
		}
	}

	my $key     = "now:$id";
	my $waiting = $WAITERS{$key};
	push @{ $WAITERS{$key} }, $cb;
	return if $waiting;

	my $settled = 0;
	my $done    = sub {
		return if $settled++;
		_settleNow( $id, $source, @_ );
	};

	eval {
		if ( $source->{variant} ) {
			Plugins::ABCListen::API::bff(
				"musicNowPlaying/$id",
				{ tz => $source->{tz} },
				sub { $done->( { data => $_[0] } ) },
				sub { $done->( { error => $_[0] } ) },
				{ quiet => 1, timeout => TIMEOUT },
			);
		}
		else {
			Plugins::ABCListen::API::music(
				"plays/$source->{station}/now.json",
				sub { $done->( { data => $_[0] } ) },
				sub { $done->( { error => $_[0] } ) },
				{ quiet => 1, timeout => TIMEOUT },
			);
		}
		1;
	} or $done->( { error => { message => 'request failed: ' . ( $@ || 'unknown problem' ) } } );

	return;
}

sub current {
	shift if _isClass( $_[0] );
	my $id = shift;

	return undef unless defined $id && !ref $id;

	my $last = $LAST_GOOD{$id} or return undef;
	return undef if $last->{misses} > MAX_MISSES;

	my $song = $last->{song};
	my $now  = _now();

	my $current;
	if ( defined $song->{playedTime} && $song->{playedTime} > $now ) {
		$current = 1;    # clock skew: played "in the future"
	}
	elsif ( defined( my $end = songEnd($song) ) ) {
		$current = $end > $now;
	}
	else {
		$current = $now < $last->{bound};
	}

	return $current ? {%$song} : undef;
}

sub pollIn {
	shift if _isClass( $_[0] );
	my $id = shift;

	return undef unless defined $id && !ref $id;

	my $entry = $CACHE{$id} or return undef;
	return undef if $entry->{noData};
	return ERROR_TTL if defined $entry->{error};
	return ttl( $entry->{nextUpdated}, _now() );
}

sub recent {
	shift if _isClass( $_[0] );
	my ( $id, $n, $cb ) = @_;

	$cb = _once( $cb, 'recently played for ' . ( defined $id && !ref $id ? $id : '?' ) );
	$n  = RECENT_LIMIT unless defined $n && $n =~ /\A[0-9]+\z/;

	my $station = station($id) or return $cb->( undef, 'no recently played list for this service' );

	if ( my $entry = $RECENT{$id} ) {
		if ( _now() < $entry->{expires} ) {
			return $cb->( undef, $entry->{error} ) if defined $entry->{error};
			return $cb->( _firstPlays( $entry->{plays}, $n ) );
		}
	}

	my $key = "recent:$id";
	my $waiting = $WAITERS{$key};
	push @{ $WAITERS{$key} }, [ $cb, $n ];
	return if $waiting;

	my $settled = 0;
	my $done    = sub {
		return if $settled++;
		_settleRecent( $id, @_ );
	};

	eval {
		Plugins::ABCListen::API::music(
			'plays/search.json',
			{ station => $station, order => 'desc', limit => RECENT_LIMIT },
			sub { $done->( { data => $_[0] } ) },
			sub { $done->( { error => $_[0] } ) },
			{ quiet => 1, timeout => TIMEOUT },
		);
		1;
	} or $done->( { error => { message => 'request failed: ' . ( $@ || 'unknown problem' ) } } );

	return;
}

# ---------------------------------------------------------------------------
# Pure parts
# ---------------------------------------------------------------------------

sub parseNow {
	shift if _isClass( $_[0] );
	my ( $data, $fallbackArtist ) = @_;

	return undef unless ref $data eq 'HASH';

	my $now = $data->{now};
	return undef unless ref $now eq 'HASH' && ref $now->{recording} eq 'HASH';

	my $recording = $now->{recording};
	my $title     = _clean( $recording->{title} );
	return undef unless defined $title;

	my $release = ref $now->{release} eq 'HASH' ? $now->{release} : _firstHash( $recording->{releases} );

	return {
		title       => $title,
		artist      => _artist( $now, $fallbackArtist ),
		album       => _album($release),
		cover       => _cover( $release && $release->{artwork} ) // _cover( $recording->{artwork} ),
		playedTime  => _epoch( $now->{played_time} ),
		duration    => _seconds( $recording->{duration} ),
		nextUpdated => _epoch( $data->{next_updated} ),
	};
}

sub parseMapiNow {
	shift if _isClass( $_[0] );
	my ( $data, $fallbackArtist ) = @_;

	return undef unless ref $data eq 'HASH';

	my $now = $data->{mapiNow};
	return undef unless ref $now eq 'HASH';

	my $title = _clean( $now->{title} );
	return undef unless defined $title;

	my $release = ref $now->{release} eq 'HASH' ? $now->{release} : {};

	my $cover = _cover( $release->{artwork} );
	if ( !defined $cover ) {
		my $image = ref $now->{primaryImageProps} eq 'HASH' ? $now->{primaryImageProps}->{imgSrc} : undef;
		($cover) = grep { _isUrl($_) } $now->{primaryImage}, $image;
	}

	return {
		title       => $title,
		artist      => _clean( $now->{artist} ) // _clean($fallbackArtist),
		album       => _clean( $release->{title} ) // _clean( $now->{releaseTitle} ),
		cover       => $cover,
		playedTime  => _epoch( $now->{playedTime} ),
		duration    => _seconds( $now->{duration} ),
		nextUpdated => _epoch( $data->{nextUpdated} ),
	};
}

sub parseRecent {
	shift if _isClass( $_[0] );
	my ( $data, $n ) = @_;

	$n = RECENT_LIMIT unless defined $n && !ref $n && $n =~ /\A[0-9]+\z/;

	my @plays;
	my $items = ref $data eq 'HASH' ? $data->{items} : undef;
	return \@plays unless ref $items eq 'ARRAY';

	for my $item (@$items) {
		last if @plays >= $n;
		next unless ref $item eq 'HASH';

		my $recording = ref $item->{recording} eq 'HASH' ? $item->{recording} : {};
		my $summary   = ref $item->{summary} eq 'HASH'   ? $item->{summary}   : {};

		my $title = _clean( $recording->{title} ) // _clean( $summary->{title} );
		next unless defined $title;

		push @plays, {
			playedTime => _epoch( $item->{played_time} ),
			artist     => _artist($item),
			title      => $title,
		};
	}

	return \@plays;
}

sub songEnd {
	shift if _isClass( $_[0] );
	my $song = shift;

	return undef unless ref $song eq 'HASH';

	my ( $played, $duration, $next ) = @{$song}{qw(playedTime duration nextUpdated)};
	return $played + $duration if defined $played && $duration;
	return $next + END_GRACE   if defined $next;
	return undef;
}

sub ttl {
	shift if _isClass( $_[0] );
	my ( $nextUpdated, $now ) = @_;
	$now = _now() unless defined $now;

	return DEFAULT_TTL unless defined $nextUpdated;

	my $ttl = $nextUpdated - $now;
	return $ttl < MIN_TTL ? MIN_TTL : $ttl > MAX_TTL ? MAX_TTL : $ttl;
}

# ---------------------------------------------------------------------------
# Settling requests
# ---------------------------------------------------------------------------

sub _settleNow {
	my ( $id, $source, $result ) = @_;

	my $key = "now:$id";
	my $now = _now();
	my ( $song, $error, $noData, $nextUpdated );

	if ( my $failure = $result->{error} ) {
		my $status  = ref $failure eq 'HASH' ? $failure->{status} : undef;
		my $message = ref $failure eq 'HASH' && defined $failure->{message} ? $failure->{message} : 'unknown problem';

		if ( _isNoData( $source, $status, $failure ) ) {
			$noData = defined $status ? "HTTP $status" : 'a null response';
		}
		else {
			$error = $message;
		}
	}
	else {
		my $data = $result->{data};

		if ( $source->{variant} && !( ref $data eq 'HASH' && ref $data->{mapiNow} eq 'HASH' && %{ $data->{mapiNow} } ) ) {
			$noData = 'mapiNow empty';
		}
		else {
			my $parsed = eval {
				$song = $source->{variant} ? parseMapiNow( $data, $source->{name} ) : parseNow( $data, $source->{name} );
				$nextUpdated = _epoch( ref $data eq 'HASH' ? $data->{ $source->{variant} ? 'nextUpdated' : 'next_updated' } : undef );
				1;
			};
			if ( !$parsed ) {
				$error = 'could not read the response: ' . ( $@ || 'unknown problem' );
				$log->error("Song for $id: $error");
				undef $song;
			}
		}
	}

	if ($noData) {
		$CACHE{$id} = { noData => 1, expires => $now + NO_DATA_TTL };
		delete $LAST_GOOD{$id};
		delete $FAILURES{$key};
		main::INFOLOG && $log->is_info && $log->info( "No song data for $id ($noData); asked again in " . NO_DATA_TTL . ' s' );
	}
	elsif ( defined $error ) {
		$CACHE{$id} = { error => $error, expires => $now + ERROR_TTL };
		$LAST_GOOD{$id}->{misses}++ if $LAST_GOOD{$id};

		if ( $FAILURES{$key}++ ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Song for $id still unavailable: $error");
		}
		else {
			$log->warn( "Song for $id unavailable (retrying in " . ERROR_TTL . " s; repeats are logged at DEBUG): $error" );
		}
	}
	else {
		delete $FAILURES{$key};

		my $ttl = ttl( $nextUpdated, $now );
		$CACHE{$id} = { song => $song, nextUpdated => $nextUpdated, expires => $now + $ttl };

		if ($song) {
			$LAST_GOOD{$id} = { song => $song, bound => $now + $ttl + END_GRACE, misses => 0 };
		}
		elsif ( $LAST_GOOD{$id} ) {
			$LAST_GOOD{$id}->{misses}++;
		}

		main::DEBUGLOG && $log->is_debug && $log->debug( sprintf(
			'Song for %s: %s; cached for %d s', $id, $song ? "'$song->{title}' by " . ( $song->{artist} // '?' ) : 'none now', $ttl,
		) );
	}

	for my $cb ( @{ delete $WAITERS{$key} || [] } ) {
		defined $error ? $cb->( undef, $error ) : $cb->( $song ? {%$song} : undef );
	}

	return;
}

sub _settleRecent {
	my ( $id, $result ) = @_;

	my $key = "recent:$id";
	my $now = _now();
	my ( $plays, $error );

	if ( my $failure = $result->{error} ) {
		$error = ref $failure eq 'HASH' && defined $failure->{message} ? $failure->{message} : 'unknown problem';
	}
	else {
		$plays = eval { parseRecent( $result->{data}, RECENT_LIMIT ) };
		if ( ref $plays ne 'ARRAY' ) {
			$error = 'could not read the response: ' . ( $@ || 'unknown problem' );
			$log->error("Recently played for $id: $error");
			undef $plays;
		}
	}

	if ( defined $error ) {
		$RECENT{$id} = { error => $error, expires => $now + ERROR_TTL };

		if ( $FAILURES{$key}++ ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Recently played for $id still unavailable: $error");
		}
		else {
			$log->warn( "Recently played for $id unavailable (repeats are logged at DEBUG): $error" );
		}
	}
	else {
		delete $FAILURES{$key};
		$RECENT{$id} = { plays => $plays, expires => $now + RECENT_TTL };
		main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( 'Recently played for %s: %d songs; cached for %d s', $id, scalar @$plays, RECENT_TTL ) );
	}

	for my $waiter ( @{ delete $WAITERS{$key} || [] } ) {
		my ( $cb, $n ) = @$waiter;
		defined $error ? $cb->( undef, $error ) : $cb->( _firstPlays( $plays, $n ) );
	}

	return;
}

# No song data for this service (not worth asking again for NO_DATA_TTL): HTTP 400 from the music
# API; for a time-zone version also HTTP 4xx (not 429) and 500 (BFF's "Query error" for every
# variant id), and a `null` body.
sub _isNoData {
	my ( $source, $status, $failure ) = @_;

	return 1 if defined $status && $status == 400;
	return 0 unless $source->{variant};

	if ( defined $status ) {
		return 1 if $status == 500 || ( $status >= 400 && $status < 500 && $status != 429 );
		return 0;
	}

	my $message = ref $failure eq 'HASH' ? $failure->{message} : undef;
	return defined $message && !ref $message
		&& $message =~ /\A(?:Unexpected JSON response \(not an object or array\)|Invalid JSON response: JSON text must be an object or array\b)/ ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Where $id's songs come from: { station, name } (main music station), { variant => 1, tz, name }
# (a time-zone version of one), or undef.
sub _source {
	my $rec = _record(shift) or return undef;

	return { station => $rec->{musicStation}, name => $rec->{name} } if _isMain($rec);

	if ( ( $rec->{group} // '' ) eq 'variant' && defined $rec->{network} && $rec->{network} ne $rec->{id} ) {
		my $parent = _record( $rec->{network} );
		return { variant => 1, tz => $rec->{tz} || 'Australia/Sydney', name => $rec->{name} } if $parent && _isMain($parent);
	}

	return undef;
}

sub _record {
	my $id = shift;
	return undef unless defined $id && !ref $id && $id =~ /\A[A-Z0-9_]+\z/;
	my $rec = Plugins::ABCListen::Stations->get($id);
	return ref $rec eq 'HASH' ? $rec : undef;
}

sub _isMain {
	my $rec = shift;
	return ( $rec->{group} // '' ) ne 'variant' && ( $rec->{group} // '' ) ne 'hidden'
		&& defined $rec->{musicStation} && !ref $rec->{musicStation} && $rec->{musicStation} =~ /\A[a-z0-9_]+\z/ ? 1 : 0;
}

# summary.artist, else the primary artists of the recording, else $fallback.
sub _artist {
	my ( $play, $fallback ) = @_;

	my $summary = ref $play->{summary} eq 'HASH' ? $play->{summary} : {};
	my $artist  = _clean( $summary->{artist} );
	return $artist if defined $artist;

	my $recording = ref $play->{recording} eq 'HASH' ? $play->{recording} : {};
	if ( ref $recording->{artists} eq 'ARRAY' ) {
		my @primary = grep { defined } map { ref $_ eq 'HASH' && ( $_->{type} // '' ) eq 'primary' ? _clean( $_->{name} ) : undef } @{ $recording->{artists} };
		return join( ', ', @primary ) if @primary;
	}

	return _clean($fallback);
}

sub _album {
	my $release = shift;
	return undef unless ref $release eq 'HASH';

	my $title = _clean( $release->{title} );
	return undef unless defined $title;

	my $year = $release->{release_year};
	return defined $year && !ref $year && $year =~ /\A[0-9]{4}\z/ ? "$title ($year)" : $title;
}

# The first artwork with a usable image: its sizes[] entry nearest COVER_PX wide (square sizes
# first; ties go to the larger), else its url.
sub _cover {
	my $artwork = shift;
	return undef unless ref $artwork eq 'ARRAY';

	for my $art (@$artwork) {
		next unless ref $art eq 'HASH';

		my @sizes = grep { ref $_ eq 'HASH' && _isUrl( $_->{url} ) && _seconds( $_->{width} ) } @{ ref $art->{sizes} eq 'ARRAY' ? $art->{sizes} : [] };
		my @square = grep { _isSquare($_) } @sizes;
		@sizes = @square if @square;

		if (@sizes) {
			my ($best) = sort { abs( $a->{width} - COVER_PX ) <=> abs( $b->{width} - COVER_PX ) || $b->{width} <=> $a->{width} } @sizes;
			return $best->{url};
		}

		return $art->{url} if _isUrl( $art->{url} );
	}

	return undef;
}

sub _isSquare {
	my $size  = shift;
	my $ratio = $size->{aspect_ratio} // $size->{aspectRatio};
	return $ratio eq '1x1' ? 1 : 0 if defined $ratio && !ref $ratio;
	return defined $size->{height} && !ref $size->{height} && $size->{height} eq $size->{width} ? 1 : 0;
}

sub _firstHash {
	my $list = shift;
	return undef unless ref $list eq 'ARRAY';
	my ($first) = grep { ref $_ eq 'HASH' } @$list;
	return $first;
}

sub _firstPlays {
	my ( $plays, $n ) = @_;
	my @plays = map { {%$_} } @{ $plays || [] };
	splice( @plays, $n ) if @plays > $n;
	return \@plays;
}

# $cb wrapped to run at most once; a die in it is logged, never propagated.
sub _once {
	my ( $cb, $what ) = @_;
	my $called = 0;

	return sub {
		return if $called++;
		return unless ref $cb eq 'CODE';
		eval { $cb->(@_); 1 } or $log->error( "Tracks: $what callback died: " . ( $@ || 'unknown problem' ) );
		return;
	};
}

# Entity-decoded text with whitespace collapsed and trimmed, or undef when empty.
sub _clean {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::ABCListen::Util::decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/\A //;
	$text =~ s/ \z//;

	return length $text ? $text : undef;
}

sub _epoch {
	my $value = shift;
	return undef unless defined $value && !ref $value;
	return Plugins::ABCListen::Util::parseISO8601($value);
}

# A positive number (seconds, pixels), else undef.
sub _seconds {
	my $value = shift;
	return undef unless defined $value && !ref $value && $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $value > 0;
	return $value + 0;
}

sub _isUrl { defined $_[0] && !ref $_[0] && $_[0] =~ m{\Ahttps?://\S+\z}i }

sub _now { Time::HiRes::time() }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# test helper: forget everything (a restarted LMS starts like this)
sub _reset {
	%CACHE     = ();
	%LAST_GOOD = ();
	%RECENT    = ();
	%WAITERS   = ();
	%FAILURES  = ();
	return;
}

1;
