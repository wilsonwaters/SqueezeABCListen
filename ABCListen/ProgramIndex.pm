package Plugins::ABCListen::ProgramIndex;

# The index of every ABC listen audio program (A-Z and By type), from ABC's public Algolia search
# index: ONE query a day per LMS. Data only: no menu code (OnDemand builds the menus).
#
# ---- Functions ----------------------------------------------------------------------------------
#   programs($cb) -> $cb->({ items => [program refs], fallback => 0|1 }) | $cb->({ error => TOKEN })
#       Calls $cb EXACTLY ONCE, on every path (a $cb that dies is logged, never called again).
#       Cache hits call back synchronously, other calls later: code must work either way.
#       One API::algolia call, opts { ttl => 86400, stale_ok => 1 }, params:
#         { query => '', hitsPerPage => 1000,
#           filters => 'contentType:program AND (siteSegment:listen OR siteSegment:triplej OR
#                       siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)',
#           attributesToRetrieve => [qw(objectID title canonicalURL shortTeaserText description
#                                       defaultThumbnail infoSource programType)] }
#       API.pm caches the answer 24 h by canonical params (on disk: it survives LMS restarts),
#       coalesces identical queries in flight, and with stale_ok serves the last-good copy (kept
#       7 days) when Algolia fails after that: such data is served as usual (fallback 0).
#       Hits are mapped to program refs in Algolia's order, de-duplicated by path; hits without
#       a usable path are dropped (count logged at DEBUG). nbHits > the hits returned (the index
#       outgrew Algolia's 1000-hit cap) -> the hits returned, WARN logged once per run.
#     Fallback (fallback => 1): when Algolia fails with no last-good copy (RATE_LIMITED, key
#       discovery failure, 4xx/5xx, bad JSON) or returns no usable hit (filter drift; WARN
#       once per run), so the A-Z is never empty:
#       Programs->networkPrograms($key) for every Programs->networks() entry, at most 4 in
#       flight (O2 caches them 6 h); the union in network order, de-duplicated by path, refs as
#       Programs returns them (no programType). Every network failing too ->
#       { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }.
#
#   Program ref (Algolia; contract 6 program shape plus programType), optional keys absent
#   when unknown:
#     { id          (digits, from API::coreMediaRef(objectID) 'coremedia://program/<id>'),
#       title       (entity-decoded, whitespace collapsed and trimmed),
#       path        (API::sitePath(canonicalURL): the canonical program path),
#       description (shortTeaserText, else description; decoded and trimmed),
#       image       (defaultThumbnail->{'1x1'}, the raw URL: programItem sizes it),
#       network     (infoSource, trimmed: 'ABC Radio National', 'ABC Country', ...),
#       programType (the raw value: 'podcast', 'catch-up', 'Music Playlists', ...) }
#   A usable path is a www.abc.net.au (or abc.net.au) program page: its last-but-one segment is
#   'programs' or 'audiobooks' ('/listen/programs/scienceshow', '/triplej/programs/hack',
#   '/listen/audiobooks/animal-farm-page'). Other hits (network and news pages, other hosts, no
#   canonicalURL) are not program pages and are dropped.
#
#   typeKey($programType) -> 'podcast' | 'catchup' | 'music' | 'news' | 'audiobook' | 'other'
#       Pure (case-insensitive, trimmed): podcast -> podcast; catch-up -> catchup; music and
#       'Music Playlists' -> music; news-briefing -> news; audiobook -> audiobook; undef, '' and
#       any other value -> other (a value not in this table is logged at DEBUG, once per value).
#
#   Both work as class methods (Plugins::ABCListen::ProgramIndex->programs($cb)) or as plain
#   functions (Plugins::ABCListen::ProgramIndex::programs($cb)).
#
# Owned by the ondemand stream (O3).

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util qw(decodeEntities);

use constant LOAD_FAILED   => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant INDEX_TTL     => 86400;    # one Algolia query a day
use constant HITS_PER_PAGE => 1000;     # Algolia's cap; no paging past it
use constant MAX_IN_FLIGHT => 4;        # fallback: network lists loading at once

use constant FILTERS => 'contentType:program AND (siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten'
	. ' OR siteSegment:triplejunearthed OR siteSegment:pacific)';

my @ATTRIBUTES = qw(objectID title canonicalURL shortTeaserText description defaultThumbnail infoSource programType);

my %TYPE_KEY = (
	'podcast'         => 'podcast',
	'catch-up'        => 'catchup',
	'music'           => 'music',
	'music playlists' => 'music',
	'news-briefing'   => 'news',
	'audiobook'       => 'audiobook',
);

my $log = logger('plugin.abclisten');

my %unknownType;    # programType values logged as unknown (once each)
my $cappedWarned;   # nbHits > hits logged (once per run)
my $emptyWarned;    # an index without programs logged (once per run)

# ---------------------------------------------------------------------------
# The index
# ---------------------------------------------------------------------------

sub programs {
	shift if _isClass( $_[0] );
	my $cb   = shift;
	my $once = _once($cb);

	Plugins::ABCListen::API::algolia(
		{
			query                => '',
			hitsPerPage          => HITS_PER_PAGE,
			filters              => FILTERS,
			attributesToRetrieve => [@ATTRIBUTES],
		},
		sub {
			my $data = shift;
			_guard( $once, sub {
				my $refs = _refs($data);
				return $once->( { items => $refs, fallback => 0 } ) if @$refs;

				# filter drift: never an empty A-Z (logged at WARN once per run; the empty answer is cached)
				$log->warn('The ABC listen program index has no programs; showing the network lists') unless $emptyWarned++;
				_fallback($once);
			} );
		},
		sub {
			my $error = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug( 'Program index unavailable (' . ( ref $error eq 'HASH' && $error->{error} || 'error' ) . '); showing the network lists' );
			_guard( $once, sub { _fallback($once) } );
		},
		{ ttl => INDEX_TTL, stale_ok => 1 },
	);

	return;
}

# Algolia answer -> program refs (Algolia order, de-duplicated by path).
sub _refs {
	my $data = shift;
	$data = {} unless ref $data eq 'HASH';

	my @hits = grep { ref $_ eq 'HASH' } @{ ref $data->{hits} eq 'ARRAY' ? $data->{hits} : [] };

	my $nbHits = $data->{nbHits};
	if ( defined $nbHits && !ref $nbHits && $nbHits =~ /\A[0-9]+\z/ && $nbHits > @hits && @hits && !$cappedWarned++ ) {
		$log->warn( "The ABC listen program index has $nbHits programs; only the first " . scalar(@hits) . ' are listed' );
	}

	my ( %seen, @refs );
	my $dropped = 0;
	for my $hit (@hits) {
		my $ref = _ref($hit);
		if ( !$ref ) {
			$dropped++;
			next;
		}
		push @refs, $ref unless $seen{ $ref->{path} }++;
	}

	main::DEBUGLOG && $dropped && $log->is_debug && $log->debug("Program index: $dropped hits without a program page skipped");

	return \@refs;
}

# One Algolia hit -> a program ref, or undef without a program page path.
sub _ref {
	my $hit = shift;

	my $path = Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} );
	return undef unless defined $path && $path =~ m{/(?:programs|audiobooks)/[^/]+\z};

	my %ref = ( path => $path );

	my ( $type, $id ) = Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} );
	$ref{id} = $id if defined $type && $type eq 'program';

	my $title = _text( $hit->{title} );
	$ref{title} = $title if defined $title;

	my $description = _text( $hit->{shortTeaserText} );
	$description = _text( $hit->{description} ) unless defined $description;
	$ref{description} = $description if defined $description;

	my $thumbnail = ref $hit->{defaultThumbnail} eq 'HASH' ? $hit->{defaultThumbnail}->{'1x1'} : undef;
	$ref{image} = $thumbnail if defined $thumbnail && !ref $thumbnail && $thumbnail =~ /\S/;

	my $network = _text( $hit->{infoSource} );
	$ref{network} = $network if defined $network;

	my $programType = $hit->{programType};
	$ref{programType} = $programType if defined $programType && !ref $programType && length $programType;

	return \%ref;
}

# ---------------------------------------------------------------------------
# Fallback: the union of O2's network lists
# ---------------------------------------------------------------------------

sub _fallback {
	my $cb = shift;

	my @keys = map { $_->{key} } Plugins::ABCListen::Programs::networks();
	my $state = { cb => $cb, keys => \@keys, results => [], next => 0, active => 0, done => 0 };

	return _finishFallback($state) unless @keys;
	_launch($state);
	return;
}

# Start network lists until MAX_IN_FLIGHT are loading (callbacks may come back synchronously).
sub _launch {
	my $state = shift;

	while ( $state->{active} < MAX_IN_FLIGHT && $state->{next} < @{ $state->{keys} } ) {
		my $i = $state->{next}++;
		$state->{active}++;

		Plugins::ABCListen::Programs::networkPrograms( $state->{keys}->[$i], sub {
			my $result = shift;
			_guard( $state->{cb}, sub {
				$state->{results}->[$i] = $result;
				$state->{active}--;

				return _finishFallback($state) if ++$state->{done} == @{ $state->{keys} };
				_launch($state);
			} );
		} );
	}

	return;
}

sub _finishFallback {
	my $state = shift;

	my ( %seen, @refs );
	for my $result ( @{ $state->{results} } ) {
		next unless ref $result eq 'HASH' && ref $result->{items} eq 'ARRAY';
		for my $program ( @{ $result->{items} } ) {
			next unless ref $program eq 'HASH' && defined $program->{path};
			push @refs, $program unless $seen{ $program->{path} }++;
		}
	}

	if ( !@refs ) {
		$log->warn('The ABC listen program index and every network list failed');
		return $state->{cb}->( { error => LOAD_FAILED } );
	}

	$state->{cb}->( { items => \@refs, fallback => 1 } );
}

# ---------------------------------------------------------------------------
# Program types
# ---------------------------------------------------------------------------

sub typeKey {
	shift if _isClass( $_[0] );
	my $programType = shift;
	return 'other' unless defined $programType && !ref $programType;

	( my $value = lc $programType ) =~ s/\A\s+|\s+\z//g;
	return 'other' unless length $value;

	return $TYPE_KEY{$value} if $TYPE_KEY{$value};

	main::DEBUGLOG && !$unknownType{$value}++ && $log->is_debug && $log->debug("Program index: unknown programType '$programType' listed as Other");
	return 'other';
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A callback wrapper that passes on only the first call; a callback that dies is logged.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub {
		return if $called++;
		eval { $cb->(@_) if ref $cb eq 'CODE'; 1 } or $log->error( 'ABC listen program index callback failed: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# Run $code; if it dies, log and answer $fail with LOAD_FAILED (ignored if already answered).
sub _guard {
	my ( $fail, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Processing the ABC listen program index failed: ' . ( $@ || 'unknown error' ) );
		$fail->( { error => LOAD_FAILED } );
	};
	return;
}

sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;
	$text = decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/\A | \z//g;
	return length $text ? $text : undef;
}

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# Forget what was logged once (for tests).
sub _reset {
	%unknownType  = ();
	$cappedWarned = 0;
	$emptyWarned  = 0;
	return;
}

1;
