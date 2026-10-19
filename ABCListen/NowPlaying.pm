package Plugins::ABCListen::NowPlaying;

# The program on air (and the next one) per live service, from ABC's EPG "now/next" data:
# GET https://www.abc.net.au/core-next/api/epgNowPlaying/<SERVICE_ID>/now?imageRatio=1x1 (and /next),
# through API::bff (research abc-listen-api.md section 5). Data only: used by the Radio menus
# (Live.pm) and the live Now Playing metadata (LiveMetadata.pm).
#
#   NowPlaying->programNow($id, $cb)    $cb->($program) or $cb->(undef[, $error]): exactly one call,
#                                       synchronous from the cache, else when the request is done.
#                                       undef without $error: nothing on air ({}, `null`, no title,
#                                       not a hash: an event service off air, or between programs).
#   NowPlaying->programNext($id, $cb)   the same for /next; fetched only when asked for (song info).
#   NowPlaying->cached($id)             the fresh "now" program, or undef
#   NowPlaying->lastGood($id)           the last "now" program fetched, while its end is still in the
#                                       future, else undef (menus and metadata at a deadline or after
#                                       a failure)
#   parse($data, $id)                   pure: the decoded epgNowPlaying body -> $program or undef
#   timeSlot($program)                  pure: '6:00am–9:00am' (server local time), the start time
#                                       alone without an end, undef without a start
#
# Each can be called as a function or as a class method.
#
# $program = { serviceId, title, start, end, presenters, image, programPath }
#   start, end   epochs (Util::parseISO8601), or undef
#   presenters   preparedPresenters[].names.full joined with ', ' (an entry like "Jordan & Luka" is
#                one presenter), or undef
#   image        the preparedImage srcSet entry for about IMAGE_PX (580) px (API::imageUrl), else its
#                imgSrc, or undef
#   programPath  API::sitePath(programLink): only on (www.)abc.net.au, else undef
# Title and presenters are entity-decoded, whitespace collapsed and trimmed, never truncated.
#
# Cache (in memory, per service and now/next): a program until its boundary (now: end; next: start,
# when it becomes "now"), clamped to MIN_TTL..MAX_TTL (60 s - 15 min); a missing, past or
# inconsistent (end <= start) boundary, and "nothing on air", MIN_TTL. After a failed request (HTTP
# error, 404 for a service without EPG, 429, timeout, bad JSON) NEGATIVE_TTL (60 s), during which
# programNow answers (undef, $error) without a request. Identical requests are coalesced: one
# upstream request for every caller. At most CONCURRENCY (6) requests run at a time; the others
# wait in a queue. A "nothing on air" answer forgets the last-good program.
#
# Logging: a failed request is logged at WARN once per run of consecutive failures (per service and
# now/next), then at DEBUG. API::bff is called with quiet => 1, so it logs failures at DEBUG only.
#
# Owned by the live stream: L2 creates (ai-state/streams.md, rule 5).

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Util;

use constant MIN_TTL      => 60;
use constant MAX_TTL      => 900;
use constant NEGATIVE_TTL => 60;
use constant CONCURRENCY  => 6;
use constant TIMEOUT      => 8;      # seconds per request
use constant IMAGE_PX     => 580;

use constant EN_DASH => "\x{2013}";

my $log = logger('plugin.abclisten');

my %CACHE;        # "$variant:$id" => { program => $program | undef, error => $message | undef, expires }
my %LAST_GOOD;    # $id => $program ("now" only)
my %WAITERS;      # "$variant:$id" => [ callbacks ] while queued or in flight
my %FAILURES;     # "$variant:$id" => consecutive failed requests
my @QUEUE;        # [ $variant, $id ] waiting for a request slot
my $running = 0;

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub programNow {
	shift if _isClass( $_[0] );
	return _get( 'now', @_ );
}

sub programNext {
	shift if _isClass( $_[0] );
	return _get( 'next', @_ );
}

sub cached {
	shift if _isClass( $_[0] );
	my $id = shift;

	return undef unless _isServiceId($id);

	my $entry = $CACHE{"now:$id"} or return undef;
	return undef unless time() < $entry->{expires} && $entry->{program};

	return { %{ $entry->{program} } };
}

sub lastGood {
	shift if _isClass( $_[0] );
	my $id = shift;

	return undef unless _isServiceId($id);

	my $program = $LAST_GOOD{$id} or return undef;
	return undef unless defined $program->{end} && $program->{end} > time();

	return {%$program};
}

sub parse {
	shift if _isClass( $_[0] );
	my ( $data, $id ) = @_;

	return undef unless ref $data eq 'HASH';

	my $title = _clean( $data->{title} );
	return undef unless defined $title;

	my @presenters;
	if ( ref $data->{preparedPresenters} eq 'ARRAY' ) {
		for my $presenter ( @{ $data->{preparedPresenters} } ) {
			next unless ref $presenter eq 'HASH' && ref $presenter->{names} eq 'HASH';
			my $name = _clean( $presenter->{names}->{full} );
			push @presenters, $name if defined $name;
		}
	}

	my $image = ref $data->{preparedImage} eq 'HASH' ? Plugins::ABCListen::API::imageUrl( $data->{preparedImage}, IMAGE_PX ) : undef;
	$image = undef unless defined $image && $image =~ m{\Ahttps?://\S+\z}i;

	my $link = $data->{programLink};

	return {
		serviceId   => $id,
		title       => $title,
		start       => _epoch( $data->{start} ),
		end         => _epoch( $data->{end} ),
		presenters  => @presenters ? join( ', ', @presenters ) : undef,
		image       => $image,
		programPath => defined $link && !ref $link ? Plugins::ABCListen::API::sitePath($link) : undef,
	};
}

sub timeSlot {
	shift if _isClass( $_[0] );
	my $program = shift;

	return undef unless ref $program eq 'HASH';

	my $start = Plugins::ABCListen::Util::friendlyTime( $program->{start} );
	return undef unless defined $start;

	my $end = Plugins::ABCListen::Util::friendlyTime( $program->{end} );
	return defined $end ? $start . EN_DASH . $end : $start;
}

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

sub _get {
	my ( $variant, $id, $cb ) = @_;

	$cb = _once( $cb, "$variant:" . ( defined $id && !ref $id ? $id : '?' ) );

	return $cb->( undef, 'not a service id' ) unless _isServiceId($id);

	my $key = "$variant:$id";

	if ( my $entry = $CACHE{$key} ) {
		if ( time() < $entry->{expires} ) {
			return $cb->( undef, $entry->{error} ) if defined $entry->{error};
			return $cb->( $entry->{program} ? { %{ $entry->{program} } } : undef );
		}
	}

	my $waiting = $WAITERS{$key};
	push @{ $WAITERS{$key} }, $cb;
	return if $waiting;

	push @QUEUE, [ $variant, $id ];
	_pump();

	return;
}

sub _pump {
	while ( $running < CONCURRENCY && @QUEUE ) {
		my ( $variant, $id ) = @{ shift @QUEUE };
		$running++;

		my $settled = 0;
		my $done    = sub {
			return if $settled++;
			$running--;
			_settle( $variant, $id, @_ );
			_pump();
		};

		eval {
			Plugins::ABCListen::API::bff(
				"epgNowPlaying/$id/$variant",
				{ imageRatio => '1x1' },
				sub { $done->( { data => $_[0] } ) },
				sub { $done->( { error => $_[0] } ) },
				{ quiet => 1, timeout => TIMEOUT },
			);
			1;
		} or $done->( { error => { message => 'request failed: ' . ( $@ || 'unknown problem' ) } } );
	}

	return;
}

# A request is done: cache the outcome, log it, answer every waiting caller.
sub _settle {
	my ( $variant, $id, $result ) = @_;

	my $key = "$variant:$id";
	my $now = time();
	my ( $program, $error );

	if ( my $failure = $result->{error} ) {
		my $message = ref $failure eq 'HASH' && defined $failure->{message} ? $failure->{message} : 'unknown problem';

		if ( _isEmptyBody($failure) ) {
			# a `null` body is how ABC says "nothing on air" for event services
			main::DEBUGLOG && $log->is_debug && $log->debug("Program $variant for $id: nothing on air (null)");
		}
		else {
			$error = $message;
		}
	}
	else {
		$program = eval { parse( $result->{data}, $id ) };
		$log->error( "Could not read the program $variant for $id: " . ( $@ || 'unknown problem' ) ) if $@;
	}

	if ( defined $error ) {
		$CACHE{$key} = { error => $error, expires => $now + NEGATIVE_TTL };

		if ( $FAILURES{$key}++ ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Program $variant for $id still unavailable: $error");
		}
		else {
			$log->warn( "Program $variant for $id unavailable (retrying in " . NEGATIVE_TTL . " s; repeats are logged at DEBUG): $error" );
		}
	}
	else {
		delete $FAILURES{$key};

		my $ttl = _ttl( $variant, $program, $now );
		$CACHE{$key} = { program => $program, expires => $now + $ttl };

		if ( $variant eq 'now' ) {
			if   ($program) { $LAST_GOOD{$id} = $program }
			else            { delete $LAST_GOOD{$id} }
		}

		main::DEBUGLOG && $log->is_debug && $log->debug( sprintf(
			"Program %s for %s: %s; cached for %d s", $variant, $id, $program ? "'$program->{title}'" : 'nothing on air', $ttl,
		) );
	}

	for my $cb ( @{ delete $WAITERS{$key} || [] } ) {
		defined $error ? $cb->( undef, $error ) : $cb->( $program ? {%$program} : undef );
	}

	return;
}

# Cache lifetime: until the program's boundary (now: its end; next: its start), clamped.
sub _ttl {
	my ( $variant, $program, $now ) = @_;

	return MIN_TTL unless $program;

	my ( $start, $end ) = @{$program}{qw(start end)};
	return MIN_TTL if defined $start && defined $end && $end <= $start;

	my $boundary = $variant eq 'next' ? $start : $end;
	return MIN_TTL unless defined $boundary && $boundary > $now;

	my $ttl = $boundary - $now;
	return $ttl < MIN_TTL ? MIN_TTL : $ttl > MAX_TTL ? MAX_TTL : $ttl;
}

# HTTP.pm reports a JSON `null` (or other non-object) body as an error.
sub _isEmptyBody {
	my $failure = shift;
	return ref $failure eq 'HASH' && defined $failure->{message} && $failure->{message} =~ /\AUnexpected JSON response \(not an object or array\)/ ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# $cb wrapped to run at most once; a die in it is logged, never propagated.
sub _once {
	my ( $cb, $what ) = @_;
	my $called = 0;

	return sub {
		return if $called++;
		return unless ref $cb eq 'CODE';
		eval { $cb->(@_); 1 } or $log->error( "Program $what callback died: " . ( $@ || 'unknown problem' ) );
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

sub _isServiceId { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[A-Z0-9_]+\z/ }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# test helper: forget everything (a restarted LMS starts like this)
sub _reset {
	%CACHE     = ();
	%LAST_GOOD = ();
	%WAITERS   = ();
	%FAILURES  = ();
	@QUEUE     = ();
	$running   = 0;
	return;
}

1;
