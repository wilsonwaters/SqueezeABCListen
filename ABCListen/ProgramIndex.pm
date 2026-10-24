package Plugins::ABCListen::ProgramIndex;

# The index of every ABC listen audio program (A-Z and By type), from ABC's public Algolia search
# index: ONE query a day per LMS. Data only: no menu code (OnDemand builds the menus).
#
# ---- Functions ----------------------------------------------------------------------------------
#   programs($cb) -> $cb->({ items => [program refs], fallback => 0|1 }) | $cb->({ error => TOKEN })
#       Calls $cb EXACTLY ONCE, on every path (a $cb that dies is logged, never called again).
#       Cache hits call back synchronously, other calls later: code must work either way.
#       One API::algolia call, opts { ttl => 86400, stale_ok => 1 }, params:
#         { query => '', hitsPerPage => 1000, distinct => 0,
#           filters => 'contentType:program AND (siteSegment:listen OR siteSegment:triplej OR
#                       siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific
#                       OR canonicalURI_fragments:listen OR canonicalURI_fragments:triplej OR
#                       canonicalURI_fragments:kidslisten OR canonicalURI_fragments:triplejunearthed
#                       OR canonicalURI_fragments:pacific)',
#           attributesToRetrieve => [qw(objectID title canonicalURL shortTeaserText description
#                                       defaultThumbnail infoSource programType)] }
#       D8, why distinct and the canonicalURI_fragments terms (ABC's index, probed 2026-10-23):
#         - distinct => 0: by default the index keeps one hit per title, so the A–Z missed 29
#           programs: the audiobook Persuasion (the podcast Persuasion was kept), Big Ideas,
#           Future Tense, Download This Show, A Big Country, 13 of the 14 programs called
#           "Mornings", Lunch, Live At The Wireless, Classic Albums, Special Features, ...
#         - canonicalURI_fragments: some ABC listen programs are filed under another site segment
#           (AM and The World Today: siteSegment 'adelaide', canonicalURL /listen/programs/...),
#           so a program is also in when a segment of its canonical URL names an ABC listen site
#           (the path rule below still decides what is listed).
#       Programs that ABC's index does not have at all (2026-10-23: Comedy Showcase, Grass Roots
#       and Desko, of the 219 By network programs) are not in the A–Z; By network lists them.
#       API.pm caches the answer 24 h by canonical params (on disk: it survives LMS restarts),
#       coalesces identical queries in flight, and with stale_ok serves the last-good copy (kept
#       7 days) when Algolia fails after that: such data is served as usual (fallback 0).
#       Hits are mapped to program refs in Algolia's order, de-duplicated by path and (D8) by
#       title (case-insensitive) with the path's last segment (one program at a legacy and a
#       current path), the latter only when at most one has a programType (or both the same type
#       key) and the networks are the same or one is missing (_twins): of two, the one at a
#       program page path is kept, then the one with a programType, else the first, in the first
#       one's place (_rank). Hits without
#       a usable path are dropped (count logged at DEBUG), and network-relative paths are kept only
#       when their page checks out (O7, below). nbHits > the hits returned (the index outgrew
#       Algolia's 1000-hit cap) -> the hits returned, WARN logged once per run.
#     Fallback (fallback => 1): when Algolia fails with no last-good copy (RATE_LIMITED, key
#       discovery failure, 4xx/5xx, bad JSON) or returns no usable hit (filter drift, or every
#       page check left out; WARN once per run), so the A-Z is never empty:
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
#   A usable path is on www.abc.net.au (or abc.net.au) and either
#     - a program page: its last-but-one segment is 'programs' or 'audiobooks'
#       ('/listen/programs/scienceshow', '/triplej/programs/hack', '/listen/audiobooks/animal-farm-page');
#     - or (O7) a network-relative program path '<network>/<slug>', <network> being a
#       Programs::networks() sitePath without its '/programs' ('/triplej/hottest-100',
#       '/listen/doublej/summer-mornings'), <slug> not 'programs' or 'audiobooks' (O8: those are
#       the network's list pages, '/triplej/programs'). Every hit is contentType:program (the
#       filter). ABC 308-redirects some of these to their program page ('/triplej/hottest-100' ->
#       '/triplej/programs/hottest-100'), others to a video-only page ('/triplej/like-a-version')
#       or answers 404, so each one's page is checked first (see "Page check").
#   Other hits (network and news pages, episode pages, other hosts, no canonicalURL) are not
#   program pages and are dropped. A listed ref always keeps the Algolia path, which is ABC's
#   canonical path (also the network lists'); Programs->program follows the redirect when it opens.
#
#   Page check (O7), for a network-relative path without a cached decision:
#     API::nextData($path, ..., { stale_ok => 1, quiet => 1, timeout => 8 }) (it follows the 308;
#     the page data it caches is what the program menu then opens), at most 4 in flight; refs are
#     answered, in Algolia order, once every check is in.
#     - listed when the page is a program page (heroImageWithCTAPrepared.uri coremedia://program/<id>)
#       with audio episodes (a programCollectionPrepared item whose docType, or contentUri type, is
#       audioepisode, audio or audiosegment); else left out;
#     - an error with an HTTP status below 500, except 403 and RATE_LIMITED (404: no such page; a
#       redirect loop or off-site target; no page data) -> left out;
#     - no answer (a transport error, 5xx, RATE_LIMITED/429, and (O8) 403, e.g. a CDN block) ->
#       listed, unconfirmed: that decision is cached only UNCONFIRMED_TTL (10 min, O8), so during an
#       ABC outage the A–Z, By type and Podcasts A–Z don't wait for the page checks again on every
#       call; the page is checked again after that;
#     - (O8) a check whose processing dies (or whose request dies) -> listed, NOT cached (checked
#       again on the next call), logged at WARN; the other checks carry on and the index answers
#       as usual, once.
#     Decisions are cached 24 h, as the index (Slim::Utils::Cache 'program-index-page:<path>'), so
#     later calls, cache hits included, answer synchronously. Left out and unchecked pages are
#     logged at DEBUG.
#
#   networkProgramPath($episodePath) -> '<network>/<slug>' | undef            (O8; Follow uses it)
#       Pure. The network-relative program path (as the index lists it, see "A usable path") of an
#       episode or segment path '<network>/<slug>/<episode slug>/<digits id>':
#       '/triplej/hottest-100/hottest-100-25---1/106246016' -> '/triplej/hottest-100' (ABC's
#       canonical path, which the index keeps, not its 308 target '/triplej/programs/hottest-100').
#       Takes any spelling API::sitePath takes. undef for anything else: program page paths
#       ('/triplej/programs/hack/...' is Follow's own rule), a network's list pages
#       ('/triplej/programs/<x>/<id>'), deeper or shallower paths under a network
#       ('/listen/radionational/archived/<program>/<slug>/<id>', presenter pages
#       '/listen/radionational/<name>/<id>'), a last segment that is not an id, other hosts.
#
#   typeKey($programType) -> 'podcast' | 'catchup' | 'music' | 'news' | 'audiobook' | 'other'
#       Pure (case-insensitive, trimmed): podcast -> podcast; catch-up -> catchup; music and
#       'Music Playlists' -> music; news-briefing -> news; audiobook -> audiobook; undef, '' and
#       any other value -> other (a value not in this table is logged at DEBUG, once per value).
#
#   All of them work as class methods (Plugins::ABCListen::ProgramIndex->programs($cb)) or as
#   plain functions (Plugins::ABCListen::ProgramIndex::programs($cb)).
#
# Owned by the ondemand stream (O3; O7 added the page check; D8 the filter's URL segments,
# distinct => 0 and the merge of one program's two documents; O8 networkProgramPath, the network
# list pages left out, the short cache of unconfirmed checks, 403 and dying checks).

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util qw(CACHE_NAMESPACE decodeEntities);

use constant LOAD_FAILED     => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED    => 'PLUGIN_ABCLISTEN_RATE_LIMITED';
use constant INDEX_TTL       => 86400;    # one Algolia query a day; page check decisions as long
use constant HITS_PER_PAGE   => 1000;     # Algolia's cap; no paging past it
use constant MAX_IN_FLIGHT   => 4;        # network lists (fallback) or page checks loading at once
use constant PAGE_TIMEOUT    => 8;        # seconds per page check (a menu waits for it, as in Programs)
use constant UNCONFIRMED_TTL => 600;      # O8: a page check without an answer (listed) is cached this long

# The ABC listen sites, as site segments and (D8) as canonical URL segments (see the header)
use constant FILTERS => 'contentType:program AND (siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten'
	. ' OR siteSegment:triplejunearthed OR siteSegment:pacific'
	. ' OR canonicalURI_fragments:listen OR canonicalURI_fragments:triplej OR canonicalURI_fragments:kidslisten'
	. ' OR canonicalURI_fragments:triplejunearthed OR canonicalURI_fragments:pacific)';

my @ATTRIBUTES = qw(objectID title canonicalURL shortTeaserText description defaultThumbnail infoSource programType);

my %TYPE_KEY = (
	'podcast'         => 'podcast',
	'catch-up'        => 'catchup',
	'music'           => 'music',
	'music playlists' => 'music',
	'news-briefing'   => 'news',
	'audiobook'       => 'audiobook',
);

my %AUDIO_DOC = map { $_ => 1 } qw(audioepisode audio audiosegment);

# O8: '<network>/<slug>' with one of these slugs is a network's list page, not a program
my %LIST_SLUG = map { $_ => 1 } qw(programs audiobooks);

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
			distinct             => 0,    # D8: every program, also those sharing a title
			filters              => FILTERS,
			attributesToRetrieve => [@ATTRIBUTES],
		},
		sub {
			my $data = shift;
			_guard( $once, sub {
				_checkPages( $once, _refs($data), sub {
					my $refs = shift;
					return $once->( { items => $refs, fallback => 0 } ) if @$refs;

					# filter drift: never an empty A-Z (logged at WARN once per run; the empty answer is cached)
					$log->warn('The ABC listen program index has no programs; showing the network lists') unless $emptyWarned++;
					_fallback($once);
				} );
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

	my %networks = _networkPaths();

	my ( %atPath, %atTitle, @refs );    # path -> index in @refs; title+slug key -> [indexes]
	my ( $dropped, $twins ) = ( 0, 0 );
	for my $hit (@hits) {
		my $ref = _ref( $hit, \%networks );
		if ( !$ref ) {
			$dropped++;
			next;
		}

		# the same path: the same program; the same title and slug (D8): only a twin (_twins)
		my $i = $atPath{ $ref->{path} };
		if ( !defined $i ) {
			($i) = grep { _twins( $refs[$_], $ref ) } @{ $atTitle{ _titleKey($ref) } || [] };
		}

		if ( !defined $i ) {
			push @refs, $ref;
			$i = $#refs;
		}
		else {
			# D8: the same program twice: the better ref (_rank), else the first, in the first one's place
			$twins++;
			$refs[$i] = $ref if _rank($ref) > _rank( $refs[$i] );
		}

		for my $r ( $ref, $refs[$i] ) {
			$atPath{ $r->{path} } = $i;
			my $key = _titleKey($r);
			next unless length $key;
			my $list = $atTitle{$key} ||= [];
			push @$list, $i unless grep { $_ == $i } @$list;
		}
	}

	main::DEBUGLOG && $dropped && $log->is_debug && $log->debug("Program index: $dropped hits without a program page skipped");
	main::DEBUGLOG && $twins   && $log->is_debug && $log->debug("Program index: $twins hits of a program listed already merged");

	return \@refs;
}

# D8: with distinct => 0 ABC's index has some programs twice: one document at a legacy path and
# one at the current one ('Big Ideas' at /radionational/programs/bigideas and
# /listen/programs/bigideas, the first without a programType or network), or at a
# network-relative and a program path (/listen/classic/special-features,
# /listen/programs/special-features). Such twins share their title (lower case) and their path's
# last segment (_titleKey: '' without a title, so such refs never match); two refs with the same
# path are always one program.
sub _titleKey {
	my $ref = shift;
	my ($slug) = $ref->{path} =~ m{/([^/]+)\z};
	return defined $ref->{title} && defined $slug ? lc( $ref->{title} ) . "\0$slug" : '';
}

# Two refs with the same _titleKey are twins only when they can be one program: at most one has a
# programType, or both have the same type key (an audiobook and a podcast of one title and slug,
# /listen/audiobooks/the-secret-keeper and /listen/programs/the-secret-keeper, stay two), and the
# networks are the same (case-insensitive) or one is missing (Mornings on two networks stay two).
sub _twins {
	my ( $x, $y ) = @_;
	return 0 unless length _titleKey($x) && _titleKey($x) eq _titleKey($y);

	if ( defined $x->{programType} && defined $y->{programType} ) {
		return 0 unless typeKey( $x->{programType} ) eq typeKey( $y->{programType} );
	}
	if ( defined $x->{network} && defined $y->{network} ) {
		return 0 unless lc $x->{network} eq lc $y->{network};
	}
	return 1;
}

# D8: which of two refs of one program is listed: a program page path (always listed; a
# network-relative path needs its page check) first, then one with a programType (By type).
sub _rank {
	my $ref = shift;
	return ( _isProgramPath( $ref->{path} ) ? 2 : 0 ) + ( defined $ref->{programType} ? 1 : 0 );
}

# One Algolia hit -> a program ref, or undef without a program page or network-relative path
# (\%networks: _networkPaths).
sub _ref {
	my ( $hit, $networks ) = @_;

	my $path = Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} );
	return undef unless defined $path && ( _isProgramPath($path) || _isNetworkRelative( $path, $networks ) );

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

# A program page path: its last-but-one segment is 'programs' or 'audiobooks'.
sub _isProgramPath { $_[0] =~ m{/(?:programs|audiobooks)/[^/]+\z} }

# The network paths ('/listen/radionational', '/triplej', ...) as a set: Programs::networks()
# sitePaths without their '/programs'.
sub _networkPaths {
	return map { defined $_->{sitePath} && $_->{sitePath} =~ m{\A(/.+)/programs\z} ? ( $1 => 1 ) : () } Plugins::ABCListen::Programs::networks();
}

# A network-relative program path: '<network>/<slug>', the slug not a list page's (O8:
# '/triplej/programs' and '/<network>/audiobooks' are the network's lists, never programs).
sub _isNetworkRelative {
	my ( $path, $networks ) = @_;
	return $path =~ m{\A(/.+)/([^/]+)\z} && $networks->{$1} && !$LIST_SLUG{$2} ? 1 : 0;
}

# O8 (see the header): the network-relative program path of an episode path
# '<network>/<slug>/<episode slug>/<digits>', by the index's own rule (_isNetworkRelative).
sub networkProgramPath {
	shift if _isClass( $_[0] );
	my $path = Plugins::ABCListen::API::sitePath(shift);
	return undef unless defined $path;

	my ($program) = $path =~ m{\A(/.+)/[^/]+/[0-9]+\z};
	return defined $program && _isNetworkRelative( $program, { _networkPaths() } ) ? $program : undef;
}

# ---------------------------------------------------------------------------
# Page check (O7): network-relative paths
# ---------------------------------------------------------------------------

# Program refs -> $cb->(\@refs to list), in order: the program page paths, and the network-relative
# paths whose page checks out. Synchronous when every decision is cached. A check whose
# processing dies is listed (O8: _launchChecks); only a dying $cb (or launch) answers $fail
# (programs()' callback) with LOAD_FAILED.
sub _checkPages {
	my ( $fail, $refs, $cb ) = @_;

	my ( %listed, @paths );
	for my $path ( map { $_->{path} } @$refs ) {
		next if _isProgramPath($path);
		my $decision = _cachedDecision($path);
		if   ( defined $decision ) { $listed{$path} = $decision }
		else                       { push @paths, $path }
	}

	my $finish = sub { $cb->( [ grep { _isProgramPath( $_->{path} ) || $listed{ $_->{path} } } @$refs ] ) };
	return $finish->() unless @paths;

	_launchChecks( { fail => $fail, paths => \@paths, listed => \%listed, finish => $finish, next => 0, active => 0, done => 0 } );
	return;
}

# Start page checks until MAX_IN_FLIGHT are loading (callbacks may come back synchronously).
# Each check settles once (the first of its callbacks, or its request dying); O8: a decision
# that dies lists the program, uncached, and the other checks carry on.
sub _launchChecks {
	my $state = shift;

	while ( $state->{active} < MAX_IN_FLIGHT && $state->{next} < @{ $state->{paths} } ) {
		my $path = $state->{paths}->[ $state->{next}++ ];
		$state->{active}++;

		my $settled = 0;
		my $settle  = sub {
			my $decide = shift;
			return if $settled++;

			my $listed;
			eval { $listed = $decide->(); 1 } or do {
				my $why = $@ || 'unknown error';
				chomp $why;
				$log->warn("Program index: checking $path failed ($why); listed");
				$listed = 1;
			};

			_guard( $state->{fail}, sub {
				$state->{listed}->{$path} = $listed;
				$state->{active}--;

				return $state->{finish}->() if ++$state->{done} == @{ $state->{paths} };
				_launchChecks($state);
			} );
		};

		eval {
			Plugins::ABCListen::API::nextData(
				$path,
				sub { my $props = shift; $settle->( sub { _pageDecision( $path, $props ) } ) },
				sub { my $error = shift; $settle->( sub { _errorDecision( $path, $error ) } ) },
				{ stale_ok => 1, quiet => 1, timeout => PAGE_TIMEOUT },
			);
			1;
		} or do {
			my $why = $@ || 'unknown error';
			$settle->( sub { die $why } );
		};
	}

	return;
}

# The page data of $path -> 1 (listed) or 0 (left out); the decision is cached.
sub _pageDecision {
	my ( $path, $props ) = @_;

	my $listed = _isAudioProgram($props) ? 1 : 0;
	main::DEBUGLOG && !$listed && $log->is_debug && $log->debug("Program index: $path left out: not a program page with audio episodes");

	_remember( $path, $listed );
	return $listed;
}

# A failed page check -> 0 (left out, cached) when ABC answered (404, a redirect loop, no page
# data, ...); 1 (listed, unconfirmed: cached UNCONFIRMED_TTL, then checked again) without an
# answer (a transport error, 5xx, 429; O8: 403, which a CDN block answers).
sub _errorDecision {
	my ( $path, $error ) = @_;
	$error = {} unless ref $error eq 'HASH';

	my $status  = $error->{status};
	my $message = defined $error->{message} ? $error->{message} : 'error';

	if ( !defined $status || $status !~ /\A[0-9]+\z/ || $status >= 500 || $status == 403 || ( $error->{error} || '' ) eq RATE_LIMITED ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Program index: couldn't check $path ($message); listed");
		_remember( $path, 1, 1 );    # unconfirmed
		return 1;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Program index: $path left out: $message");
	_remember( $path, 0 );
	return 0;
}

# Page data -> true for a program page (heroImageWithCTAPrepared.uri coremedia://program/<id>)
# with audio episodes (a programCollectionPrepared item whose docType or contentUri type is an
# audio type).
sub _isAudioProgram {
	my $props = shift;
	return 0 unless ref $props eq 'HASH';

	my $hero = $props->{heroImageWithCTAPrepared};
	my ($type) = Plugins::ABCListen::API::coreMediaRef( ref $hero eq 'HASH' ? $hero->{uri} : undef );
	return 0 unless defined $type && $type eq 'program';

	my $collection = $props->{programCollectionPrepared};
	my $items      = ref $collection eq 'HASH' && ref $collection->{items} eq 'ARRAY' ? $collection->{items} : [];

	for my $card ( grep { ref $_ eq 'HASH' } @$items ) {
		my ($cardType) = Plugins::ABCListen::API::coreMediaRef( $card->{contentUri} );
		my $docType = defined $card->{docType} && !ref $card->{docType} ? lc $card->{docType} : '';
		return 1 if $AUDIO_DOC{$docType} || ( defined $cardType && $AUDIO_DOC{$cardType} );
	}

	return 0;
}

# The cached decision for $path: 1 (listed), 0 (left out) or undef (none).
sub _cachedDecision {
	my $path = shift;

	my $entry = eval { _cache()->get( _decisionKey($path) ) };
	$log->error("Program index: reading the page check of $path failed: $@") if $@;

	return ref $entry eq 'HASH' && defined $entry->{listed} ? ( $entry->{listed} ? 1 : 0 ) : undef;
}

# Cache a decision INDEX_TTL, or (O8) an unconfirmed one (a check without an answer) UNCONFIRMED_TTL.
sub _remember {
	my ( $path, $listed, $unconfirmed ) = @_;
	my $entry = $unconfirmed ? { listed => $listed, unconfirmed => 1 } : { listed => $listed };
	eval { _cache()->set( _decisionKey($path), $entry, $unconfirmed ? UNCONFIRMED_TTL : INDEX_TTL ); 1 }
		or $log->error( "Program index: caching the page check of $path failed: " . ( $@ || 'unknown error' ) );
	return;
}

# Cache keys are hashed by LMS (MD5), which needs bytes.
sub _decisionKey {
	my $key = 'program-index-page:' . shift;
	utf8::encode($key);
	return $key;
}

sub _cache { Slim::Utils::Cache->new(CACHE_NAMESPACE) }

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
