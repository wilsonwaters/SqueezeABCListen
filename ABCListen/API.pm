package Plugins::ABCListen::API;

# The ABC data client (ai-state/streams.md contract 5): one async API over ABC's undocumented web
# endpoints (ai-state/research/abc-listen-api.md) that hides buildIds, Algolia keys and budgets,
# retries, caching and request coalescing. Data layer only: no menu code, no endpoint-specific
# parsing (callers get decoded JSON or the raw body). All HTTP goes through Plugins::ABCListen::HTTP
# (explicit LMS User-Agent, async only).
#
# ---- Callbacks (every network function below) ---------------------------------------------------
#   Exactly one of $cb / $ecb is called per call, on every path.
#     success: $cb->($data, \%info)   $info->{stale} is 1 when $data is the last-good copy, else 0
#              $info->{at} is when $data was fetched from ABC (epoch): now for a network answer, the
#              stored time for a cache hit or a last-good copy (D5: freshness of seeded audio URLs).
#     error:   $ecb->({ error => TOKEN, message => <readable detail for logs>, status => <HTTP code | undef> })
#              TOKEN is 'PLUGIN_ABCLISTEN_LOAD_FAILED', or 'PLUGIN_ABCLISTEN_RATE_LIMITED' (HTTP 429, or
#              the Algolia budget is used up).
#   - Cache hits and invalid arguments call back SYNCHRONOUSLY, before the function returns; other
#     calls call back later. Code must work either way.
#   - Without $ecb an error is only logged; without $cb a success is dropped. A callback that dies is
#     logged (ERROR) and never leads to a second callback.
#   - Identical requests in flight share one HTTP request; every caller gets its own callback and
#     its own copy of the data. If one caller's callback dies, the others still run.
#   - Results are plain data (decoded JSON or strings), never code refs.
#
# ---- Common \%opts --------------------------------------------------------------------------------
#   ttl      => seconds  serve a cached successful result younger than this, without a request.
#                        Absent or 0: no cache, except algolia (default 3600) and siteConfig (always 6 h).
#   stale_ok => 1        on error, serve the last-good copy with $info->{stale} = 1. The copy is kept
#                        7 days, for calls made with stale_ok. The first stale serve per cache key per
#                        run logs at WARN, later ones at DEBUG.
#   quiet    => 1        log failures (and stale serves) at DEBUG instead of WARN.
#   timeout  => seconds  passed to HTTP.pm (default 15).
#
# ---- Network functions ----------------------------------------------------------------------------
#   bff($path, \%query, $cb, $ecb, \%opts)     GET https://www.abc.net.au/core-next/api/<path>?<query>
#   papi($path, \%query, $cb, $ecb, \%opts)    GET https://program.abcradio.net.au/api/v1/<path>?<query>
#   music($path, \%query, $cb, $ecb, \%opts)   GET https://music.abcradio.net.au/api/v1/<path>?<query>
#       $data is the decoded JSON. A leading '/' on $path is optional; \%query may be undef or left
#       out (bff('recommendations/listen/homepagePopularNow', $cb, $ecb)). Query
#       keys are sorted and keys and values URI-escaped (UTF-8); an array value repeats its key. So
#       URLs and cache keys are canonical.
#   text($url, $cb, $ecb, \%opts)
#       GET $url (http or https); $data is the raw body (bytes), e.g. a .pls playlist.
#   siteConfig($cb, $ecb, \%opts)
#       GET https://www.abc.net.au/listen/search -> { buildId, algolia => { appId, apiKey, indexName } | undef }
#       buildId from "buildId":"..."; algolia from the __NEXT_DATA__ JSON (the hash with
#       client => {appId, apiKey} and a sibling indexName; the Search component's wins over the
#       masthead's query-suggestions index). Cached 6 h (opts ttl is ignored); opts force => 1 skips
#       the cache. On failure the last-good config is served as stale, else LOAD_FAILED. A page with a
#       buildId but no Algolia config is a success with algolia => undef.
#   nextData($pagePath, $cb, $ecb, \%opts)
#       GET https://www.abc.net.au/_next/data/<buildId><path>.json -> its pageProps.
#       $pagePath is a site path ('/listen', '/kidslisten', '/listen/programs/scienceshow') or an
#       https://(www.)abc.net.au/... URL, normalised by sitePath (query, fragment, trailing '/' dropped).
#       - F4: the path (and every redirect target) is requested as ABC serves it: characters
#         outside the URL path characters %-encoded as UTF-8, then all lower-case ('/listen/x/
#         el-ni%C3%B1o' -> '/listen/x/el-ni%c3%b1o'). Any other spelling gets a 307 with only an
#         x-nextjs-redirect header (to the lower-cased path) and no Location, which LMS can't follow;
#         so it is never asked for.
#       - F6: a 307 (or 301/302/303) that still comes back without a Location, to another page,
#         say, is followed by its x-nextjs-redirect header, once per call: HTTP.pm passes the
#         error callback LMS's response. A second such 307 in one chain is LOAD_FAILED (status
#         307). One without x-nextjs-redirect is LOAD_FAILED with status undef, without a buildId
#         refresh, as before.
#       - 404 or a non-JSON body (stale buildId): refresh siteConfig once and retry once, only if the
#         buildId changed. Refreshes are limited to one per 60 s across all callers: within that window
#         a 404 is returned as LOAD_FAILED (status 404) without a new discovery.
#       - Follows pageProps.__N_REDIRECT (site-relative, relative or absolute) and, F4, HTTP redirects
#         LMS doesn't follow: a 308 (legacy '/radionational/programs/futuretense' -> Location
#         '/listen/programs/futuretense'), by its Location, else its x-nextjs-redirect header, and
#         (F6) the 307 above. Up to 2 hops in all; a 3rd hop, a loop or an off-site target ->
#         LOAD_FAILED (status 200 for a __N_REDIRECT, the HTTP code for a 308 or 307). A 308
#         without either header: as a non-JSON body.
#       - Cached under the final path, and the path asked for (both as requested, so every spelling
#         of a page shares one entry), never under the buildId.
#   algolia(\%params, $cb, $ecb, \%opts)
#       POST https://<appId>-dsn.algolia.net/1/indexes/<indexName>/query, body = JSON of \%params, with
#       the X-Algolia-Application-Id / X-Algolia-API-Key headers from siteConfig (never hard-coded).
#       $data is the decoded response. Cached by canonical params (sorted-key JSON), default TTL 3600 s.
#       - Budget: at most 300 network queries in any 60 minutes (cache hits and coalesced calls are
#         free). Over budget -> RATE_LIMITED without a request (cached results are still served).
#       - 401/403 -> rediscover siteConfig once (60 s limit as above) and retry once if the credentials
#         changed (the retry counts against the budget); else LOAD_FAILED. 429 -> RATE_LIMITED. No
#         Algolia config on the site -> LOAD_FAILED.
#       - The API key is never logged, and messages from this module never contain the app id (the
#         request URL logged by HTTP.pm/LMS at DEBUG does, as it is the host name).
#
# ---- Pure helpers (no I/O) ------------------------------------------------------------------------
#   imageUrl($preparedOrUrl, $px)  URL string or prepared image hash { imgSrc, srcSet } -> URL for
#       about $px pixels wide, or undef for undef/''.
#       - live-production.wcms.abc-cdn.net.au with impolicy + cropW/cropH: every param kept, width=$px,
#         height=round($px * cropH / cropW). Without crop params: unchanged (never adds impolicy). A
#         prepared hash uses imgSrc's crop params (srcSet entries may differ).
#       - resize.abcradio.net.au: the srcSet entry ("<url> <n>w") with the smallest width >= $px, else
#         the largest; unchanged without a srcSet (the signature breaks if the size changes).
#       - other hosts: unchanged.
#   richText($x)  rich-text descriptor node, a hash with descriptor or descriptionPrepared.descriptor,
#       or a plain string -> plain text. type "text" contents in document order; block keys (p, div,
#       @@standfirst, li, h1-h6, blockquote, br) separate paragraphs with "\n\n"; no-break spaces
#       become spaces, whitespace is collapsed inside paragraphs, entities decoded. Anything else -> ''.
#   coreMediaRef($uri)  'coremedia://program/123' -> ('program', '123'); anything else -> ().
#   sitePath($absOrRel)  path on (www.)abc.net.au starting with '/', without query, fragment or
#       trailing '/' ('/' for the home page); other hosts and non-URLs -> undef.
#   cardRef($card)  a BFF/Next data card -> { type, id, uriId, title, tagline, path, image, date,
#       duration, programId, docType, description } (every key present, undef when unknown), or undef
#       without a parseable contentUri.
#       - type, uriId: from coreMediaRef(contentUri); every type passes through.
#       - id: cardId when all digits; else (audio types, dynamiccollection) the numeric last segment
#         of articleLink; else uriId. (Curated cards often carry a teaser id in contentUri.)
#       - title: for programs, cardTitle when it spells the articleLink slug (the last path segment
#         minus a trailing '-page'; letters and digits compared case-insensitively and without
#         accents, only non-alphanumerics between them, the slug a prefix of cardTitle ending at a
#         word boundary: 'The Dinner Mix: Brisbane Special' matches /the-dinner-mix/, 'God Forbid'
#         /godforbid/); else, when cardImagePrepared.alt looks like a name (non-empty, <= 50 chars,
#         no NxN token, none of logo/image/illustration/photo/graphic/stylised/stylized/square/
#         featuring) and spells the slug the same way (F5), the part of alt that spells it, plus a
#         '?' or '!' right after it, underscores as spaces ('Global Roaming podcast' ->
#         'Global Roaming', 'BackgroundBriefing_3000x3000.jpg' -> 'BackgroundBriefing'); else
#         cardTitle. Alt text that does not spell the slug (another program's name, an episode, a
#         file name) is never the title. tagline = cardTitle when title came from alt and differs
#         from it (trimmed, case-insensitive), else undef.
#       - path = sitePath(articleLink); image = imageUrl(cardImagePrepared, 300); date =
#         parseISO8601(cardAttributionPrepared.publishedDate); duration =
#         cardMediaIndicatorPrepared.duration when a positive integer; programId = programID or
#         programId when numeric; docType = docType, else type for audio types; description.
#       - text fields are entity-decoded and trimmed ('' -> undef).
#
# Owned by the foundation stream: other streams may only append to it (and must say so in their PR).

use strict;
use warnings;

use JSON::PP ();
use JSON::XS::VersionOneAndTwo;
use Storable ();
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::ABCListen::HTTP;
use Plugins::ABCListen::Util qw(CACHE_NAMESPACE SITE_BASE decodeEntities parseISO8601);

use Exporter qw(import);
our @EXPORT_OK = qw(
	bff papi music text siteConfig nextData algolia
	imageUrl richText coreMediaRef sitePath cardRef
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';

use constant BFF_BASE    => SITE_BASE . '/core-next/api/';
use constant PAPI_BASE   => 'https://program.abcradio.net.au/api/v1/';
use constant MUSIC_BASE  => 'https://music.abcradio.net.au/api/v1/';
use constant NEXT_BASE   => SITE_BASE . '/_next/data/';
use constant SEARCH_PAGE => SITE_BASE . '/listen/search';

use constant SITE_CONFIG_TTL  => 6 * 3600;
use constant LAST_GOOD_TTL    => 7 * 86400;
use constant REFRESH_INTERVAL => 60;           # at most one forced siteConfig refresh per minute
use constant MAX_REDIRECTS    => 2;
use constant ALGOLIA_TTL      => 3600;
use constant ALGOLIA_BUDGET   => 300;          # network queries per ALGOLIA_WINDOW (ABC's key allows 400/h/IP)
use constant ALGOLIA_WINDOW   => 3600;
use constant CARD_IMAGE_PX    => 300;

use constant SITE_CONFIG_OP  => 'siteConfig';
use constant SITE_CONFIG_KEY => 'api:siteConfig';

my $log = logger('plugin.abclisten');

my $HAS_NORMALIZE = eval { require Unicode::Normalize; 1 } ? 1 : 0;

my $CANONICAL = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1)->allow_blessed(1);

my %inFlight;          # coalescing key => { id, waiters => [ { cb, ecb, opts } ] }
my $flightId = 0;
my @algoliaSent;       # times of the Algolia queries sent in the current window
my $lastRefresh;       # time of the last forced siteConfig refresh (nextData / algolia rediscovery)
my %staleWarned;       # cache key => 1 once a stale serve has been logged at WARN

# ---------------------------------------------------------------------------
# Network functions
# ---------------------------------------------------------------------------

sub bff   { shift if _isClass( $_[0] ); _getJSON( BFF_BASE,   @_ ) }
sub papi  { shift if _isClass( $_[0] ); _getJSON( PAPI_BASE,  @_ ) }
sub music { shift if _isClass( $_[0] ); _getJSON( MUSIC_BASE, @_ ) }

sub _getJSON {
	my ( $base, $path, @args ) = @_;

	unshift @args, undef if ref $args[0] eq 'CODE';    # \%query omitted
	my ( $query, $cb, $ecb, $opts ) = @args;

	my $url = _url( $base, $path, $query );

	_run( {
		key      => "GET $url",
		cacheKey => "api:json:$url",
		what     => "GET $url",
		start    => sub {
			my ( $done, $o ) = @_;
			Plugins::ABCListen::HTTP::getJSON(
				$url,
				sub { $done->( { data => $_[0] } ) },
				sub { $done->( { error => _httpError(@_) } ) },
				_httpOpts($o),
			);
		},
	}, $cb, $ecb, $opts );
}

sub text {
	shift if _isClass( $_[0] );
	my ( $url, $cb, $ecb, $opts ) = @_;

	return _invalid( $ecb, 'text: not an http(s) URL: ' . _show($url) )
		unless defined $url && !ref $url && $url =~ m{\Ahttps?://\S+\z}i;

	_run( {
		key      => "GET $url (text)",
		cacheKey => "api:text:$url",
		what     => "GET $url",
		start    => sub {
			my ( $done, $o ) = @_;
			Plugins::ABCListen::HTTP::get(
				$url,
				sub { $done->( { data => $_[0] } ) },
				sub { $done->( { error => _httpError(@_) } ) },
				_httpOpts($o),
			);
		},
	}, $cb, $ecb, $opts );
}

sub siteConfig {
	shift if _isClass( $_[0] );
	my ( $cb, $ecb, $opts ) = @_;
	$opts = {} unless ref $opts eq 'HASH';

	_run( {
		key        => SITE_CONFIG_OP,
		cacheKey   => SITE_CONFIG_KEY,
		defaultTtl => SITE_CONFIG_TTL,
		force      => $opts->{force},
		what       => 'siteConfig',
		start      => \&_fetchSiteConfig,
	}, $cb, $ecb, { stale_ok => 1, quiet => $opts->{quiet}, timeout => $opts->{timeout} } );
}

sub _fetchSiteConfig {
	my ( $done, $opts ) = @_;

	Plugins::ABCListen::HTTP::get(
		SEARCH_PAGE,
		_handler( $done, 'siteConfig', sub {
			my $config = _parseSiteConfig( $_[0] );

			if ( !$config ) {
				return $done->( { error => _error( LOAD_FAILED, 'No buildId found on ' . SEARCH_PAGE, 200 ) } );
			}

			main::DEBUGLOG && $log->is_debug && $log->debug( sprintf(
				'ABC site config: buildId %s, Algolia index %s',
				$config->{buildId}, $config->{algolia} ? $config->{algolia}->{indexName} : 'none',
			) );

			$done->( { data => $config } );
		} ),
		sub { $done->( { error => _httpError(@_) } ) },
		_httpOpts($opts),
	);
}

# The search page HTML -> { buildId, algolia }, or undef without a buildId.
sub _parseSiteConfig {
	my $html = shift;
	return undef unless defined $html && !ref $html;

	my ($buildId) = $html =~ /"buildId":"([^"]+)"/;
	return undef unless defined $buildId && $buildId =~ /\A[A-Za-z0-9._-]+\z/;

	my $algolia;
	if ( $html =~ m{<script\b[^>]*\bid=["']?__NEXT_DATA__["']?[^>]*>(.*?)</script>}is ) {
		my $nextData = eval { from_json($1) };
		$algolia = _findAlgolia($nextData) if ref $nextData;
	}

	return { buildId => $buildId, algolia => $algolia };
}

# Walk __NEXT_DATA__ (keys sorted, so the order is stable) for hashes holding
# client => { appId, apiKey } and a sibling indexName. The Search component's config wins, then any
# index that isn't a query-suggestions index, then anything.
sub _findAlgolia {
	my $root = shift;
	my @found;    # [ rank, { appId, apiKey, indexName } ]

	my $walk;
	$walk = sub {
		my ( $node, $parent, $depth ) = @_;
		return if $depth > 100;

		if ( ref $node eq 'ARRAY' ) {
			$walk->( $_, $parent, $depth + 1 ) for @$node;
			return;
		}
		return unless ref $node eq 'HASH';

		if ( my $config = _algoliaConfig($node) ) {
			my $rank = ref $parent eq 'HASH' && ( $parent->{component} || '' ) eq 'Search' ? 0
				: $config->{indexName} =~ /suggestion/i ? 2
				: 1;
			push @found, [ $rank, $config ];
		}

		$walk->( $node->{$_}, $node, $depth + 1 ) for sort keys %$node;
	};

	$walk->( $root, undef, 0 );
	undef $walk;

	my ($best) = sort { $a->[0] <=> $b->[0] } @found;    # sort is stable for equal ranks
	return $best ? $best->[1] : undef;
}

sub _algoliaConfig {
	my $hash   = shift;
	my $client = $hash->{client};
	return undef unless ref $client eq 'HASH';

	my ( $appId, $apiKey, $indexName ) = ( $client->{appId}, $client->{apiKey}, $hash->{indexName} );
	return undef unless _isWord( $appId, qr/\A[A-Za-z0-9]+\z/ )
		&& _isWord( $apiKey,    qr/\A[\x21-\x7E]+\z/ )
		&& _isWord( $indexName, qr/\A[A-Za-z0-9._-]+\z/ );

	return { appId => $appId, apiKey => $apiKey, indexName => $indexName };
}

sub _isWord { defined $_[0] && !ref $_[0] && $_[0] =~ $_[1] }

sub nextData {
	shift if _isClass( $_[0] );
	my ( $pagePath, $cb, $ecb, $opts ) = @_;

	my $path = _servedPath( sitePath($pagePath) );
	return _invalid( $ecb, 'nextData: not a page on www.abc.net.au: ' . _show($pagePath) ) unless defined $path;

	_run( {
		key      => "nextData $path",
		cacheKey => _nextKey($path),
		what     => "nextData $path",
		start    => sub {
			my ( $done, $o ) = @_;
			my $state = { path => $path, chain => [$path], seen => { $path => 1 }, retried => 0, opts => $o, done => $done };

			siteConfig(
				_handler( $done, "nextData $path", sub { _nextDataGet( $state, $_[0]->{buildId}, $path ) } ),
				sub { $done->( { error => $_[0] } ) },
				{ quiet => 1 },
			);
		},
	}, $cb, $ecb, $opts );
}

sub _nextKey { 'api:next:' . $_[0] }

sub _nextDataGet {
	my ( $state, $buildId, $path ) = @_;
	my $done = $state->{done};
	my $what = "nextData $state->{path}";

	my $url = NEXT_BASE . $buildId . ( $path eq '/' ? '/index' : $path ) . '.json';

	Plugins::ABCListen::HTTP::getJSON(
		$url,
		_handler( $done, $what, sub { _nextDataResponse( $state, $buildId, $path, $_[0] ) } ),
		_handler( $done, $what, sub {
			my $error = _httpError(@_);

			# F4: a redirect LMS doesn't follow (a 308: legacy /radionational/programs/... paths);
			# F6: or can't (a 307 with only x-nextjs-redirect: its response comes third)
			my ( $target, $code, $nextjs ) = _redirectTarget( $_[1], $_[2] );
			if ( defined $target ) {
				my $status = defined $error->{status} ? $error->{status} : $code;
				return _nextDataRedirect( $state, $buildId, $path, $target, $status, $nextjs );
			}

			# a stale buildId shows as a 404 or an HTML page instead of JSON
			if ( ( ( $error->{status} || 0 ) == 404 || _isNotJSON( $_[0] ) ) && !$state->{retried}++ ) {
				return _refreshBuildId( $state, $buildId, $path, $error );
			}

			$done->( { error => $error } );
		} ),
		_httpOpts( $state->{opts} ),
	);
}

sub _nextDataResponse {
	my ( $state, $buildId, $path, $json ) = @_;
	my $done = $state->{done};

	my $pageProps = ref $json eq 'HASH' ? $json->{pageProps} : undef;
	if ( ref $pageProps ne 'HASH' ) {
		return $done->( { error => _error( LOAD_FAILED, "No pageProps in the page data for $path", 200 ) } );
	}

	my $target = $pageProps->{__N_REDIRECT};
	if ( !defined $target ) {
		return $done->( { data => $pageProps, cacheKeys => [ map { _nextKey($_) } @{ $state->{chain} } ] } );
	}

	_nextDataRedirect( $state, $buildId, $path, $target, 200 );
}

# Follow the page data at $path to $target: a __N_REDIRECT, or an HTTP redirect LMS didn't follow
# (F4). One hop of the chain: loops, a 3rd hop and off-site targets are LOAD_FAILED with $status
# (200 for __N_REDIRECT, the HTTP code otherwise). $nextjs (F6): the hop is a 307's
# x-nextjs-redirect, which is followed once per call; a second one is LOAD_FAILED too.
sub _nextDataRedirect {
	my ( $state, $buildId, $path, $target, $status, $nextjs ) = @_;
	my $done  = $state->{done};
	my $chain = $state->{chain};

	my $next = _redirectPath( $path, $target );

	if ( !defined $next ) {
		return $done->( { error => _error( LOAD_FAILED, "Page data for $path redirects off the ABC site: " . _show($target), $status ) } );
	}
	if ( $state->{seen}->{$next}++ ) {
		return $done->( { error => _error( LOAD_FAILED, 'Redirect loop: ' . join( ' -> ', @$chain, $next ), $status ) } );
	}

	push @$chain, $next;
	if ( @$chain - 1 > MAX_REDIRECTS ) {
		return $done->( { error => _error( LOAD_FAILED, 'Too many redirects: ' . join( ' -> ', @$chain ), $status ) } );
	}
	if ( $nextjs && $state->{nextjsRedirects}++ ) {
		return $done->( { error => _error( LOAD_FAILED, 'A second x-nextjs-redirect: ' . join( ' -> ', @$chain ), $status ) } );
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("nextData $state->{path}: redirected to $next");

	if ( my $hit = _fresh( _nextKey($next), _ttl( {}, $state->{opts} ) ) ) {
		return $done->( { data => $hit->{data}, at => $hit->{at}, cacheKeys => [ map { _nextKey($_) } @$chain ] } );
	}

	_nextDataGet( $state, $buildId, $next );
}

# __N_REDIRECT target (site-relative, relative to the current page, or absolute) -> site path as
# served (_servedPath), or undef when it leaves the ABC site.
sub _redirectPath {
	my ( $from, $target ) = @_;
	return undef unless defined $target && !ref $target && length $target;

	if ( $target !~ m{\A(?:[A-Za-z][A-Za-z0-9+.-]*:|/)} ) {
		( my $dir = $from ) =~ s{[^/]*\z}{};
		$target = $dir . $target;
	}

	return _servedPath( sitePath($target) );
}

# F4: the target of an HTTP redirect that reached HTTP.pm's error callback unfollowed:
# ($target, $code, $nextjs), or () for anything else. LMS's Async::HTTP follows 301, 302, 303 and
# 307 when they have a Location, but treats a 308 as a plain response: its body (the target path,
# not JSON) fails to decode, and $http carries the code and headers. Its target is the Location
# header, else the x-nextjs-redirect header.
# F6: a 301/302/303/307 without a Location, which LMS fails ("Redirection without location"):
# $http has no code or headers then, but $response, LMS's HTTP::Response (HTTP.pm's third error
# callback argument), does. Its target is the x-nextjs-redirect header, with $nextjs true. A
# $response with a Location is never used: LMS has followed that redirect already (the error came
# later) or given up on it ("Redirection limit exceeded").
sub _redirectTarget {
	my ( $http, $response ) = @_;

	my $code = ref $response ? eval { $response->code } : undef;
	if ( defined $code && $code =~ /\A30[1237]\z/ && !defined _header( $response, 'Location' ) ) {
		my $target = _header( $response, 'X-Nextjs-Redirect' );
		return ( $target, $code + 0, 1 ) if defined $target;
	}

	return () unless ref $http;

	$code = eval { $http->code };
	return () unless defined $code && $code =~ /\A30[12378]\z/;

	for my $name (qw(Location X-Nextjs-Redirect)) {
		my $value = _header( $http, $name );
		return ( $value, $code + 0, 0 ) if defined $value;
	}

	return ();
}

# A non-empty header of $http (anything with ->headers), or undef.
sub _header {
	my ( $http, $name ) = @_;

	my $headers = eval { $http->headers } or return undef;
	my $value   = eval { $headers->header($name) };

	return defined $value && !ref $value && length $value ? $value : undef;
}

# F4: a site path spelled the way ABC serves its page data without a redirect: every character
# outside the RFC 3986 path characters %-encoded as UTF-8, then all lower-case ('/listen/x/
# El-Ni%C3%B1o' and '/listen/x/el-niño' -> '/listen/x/el-ni%c3%b1o'; '+' and other path
# characters kept). ABC answers any path that isn't all lower-case, upper-case %XX escapes
# included, with a 307 whose only pointer is an x-nextjs-redirect header to the lower-cased path
# (measured on /listen, /kidslisten and /news pages, 2026-10-19). That 307 has no Location, so LMS
# fails it ("Redirection without location"); since F6 its header could be followed (one hop, at
# most one per call), but asking for the served spelling saves the request and the hop. ABC's own
# links spell non-ASCII slugs with upper-case escapes (articleLink, canonicalURL, __N_REDIRECT),
# so they are requested lower-cased instead.
sub _servedPath {
	my $path = shift;
	return undef unless defined $path;

	utf8::encode($path);
	$path =~ s{([^A-Za-z0-9\-._~!\$&'()*+,;=:\@/%])}{sprintf( '%%%02x', ord $1 )}ge;

	return lc $path;
}

sub _refreshBuildId {
	my ( $state, $staleId, $path, $error ) = @_;
	my $done = $state->{done};

	_rediscover(
		sub { ( $_[0]->{buildId} || '' ) eq $staleId },
		_handler( $done, "nextData $state->{path}", sub {
			my ( $config, $reason ) = @_;

			if ( $config && $config->{buildId} ne $staleId ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("nextData $path: buildId $staleId -> $config->{buildId} ($reason), retrying");
				return _nextDataGet( $state, $config->{buildId}, $path );
			}

			$done->( { error => { %$error, message => "$error->{message} (buildId $staleId: $reason)" } } );
		} ),
	);
}

# Refresh siteConfig after the config in use ($isSame->($config) true) stopped working, at most
# once per REFRESH_INTERVAL across all callers. $cb->($config, $reason), or $cb->(undef, $reason).
sub _rediscover {
	my ( $isSame, $cb ) = @_;

	# someone else has refreshed it since
	my $known = _cacheGet(SITE_CONFIG_KEY);
	if ( $known && ref $known->{data} eq 'HASH' && !$isSame->( $known->{data} ) ) {
		return $cb->( $known->{data}, 'already refreshed' );
	}

	if ( !$inFlight{ +SITE_CONFIG_OP } ) {
		if ( defined $lastRefresh && time() - $lastRefresh < REFRESH_INTERVAL ) {
			return $cb->( undef, 'site config refreshed less than ' . REFRESH_INTERVAL . ' s ago' );
		}
		$lastRefresh = time();
	}

	siteConfig(
		sub { $cb->( $_[0], $_[1]->{stale} ? 'refresh failed, last-good config unchanged' : 'refreshed' ) },
		sub { $cb->( undef, "refresh failed: $_[0]->{message}" ) },
		{ force => 1, quiet => 1 },
	);
}

sub algolia {
	shift if _isClass( $_[0] );
	my ( $params, $cb, $ecb, $opts ) = @_;

	my $canonical = ref $params eq 'HASH' ? eval { $CANONICAL->encode($params) } : undef;
	return _invalid( $ecb, 'algolia: params must be a hash of JSON values' ) unless defined $canonical;

	_run( {
		key        => "algolia $canonical",
		cacheKey   => "api:algolia:$canonical",
		defaultTtl => ALGOLIA_TTL,
		what       => 'algolia',
		start      => sub {
			my ( $done, $o ) = @_;

			return $done->( { error => _budgetError() } ) unless _budgetLeft();

			siteConfig(
				_handler( $done, 'algolia', sub {
					my $config = shift;
					if ( !$config->{algolia} ) {
						return $done->( { error => _error( LOAD_FAILED, 'No Algolia search configuration found on ' . SEARCH_PAGE ) } );
					}
					_algoliaQuery( $params, $config->{algolia}, $done, $o, 0 );
				} ),
				sub { $done->( { error => $_[0] } ) },
				{ quiet => 1 },
			);
		},
	}, $cb, $ecb, $opts );
}

sub _algoliaQuery {
	my ( $params, $algolia, $done, $opts, $retried ) = @_;

	return $done->( { error => _budgetError() } ) unless _budgetLeft();
	push @algoliaSent, time();

	my $url = sprintf( 'https://%s-dsn.algolia.net/1/indexes/%s/query', $algolia->{appId}, $algolia->{indexName} );

	Plugins::ABCListen::HTTP::postJSON(
		$url,
		$params,
		sub { $done->( { data => $_[0] } ) },
		_handler( $done, 'algolia', sub {
			my ( $message, $http ) = @_;
			my $error  = _httpError( _redact( $message, $algolia ), $http );
			my $status = $error->{status} || 0;

			if ( ( $status == 401 || $status == 403 ) && !$retried ) {
				return _rediscover(
					sub { _sameAlgolia( $_[0]->{algolia}, $algolia ) },
					_handler( $done, 'algolia', sub {
						my ( $config, $reason ) = @_;
						my $new = $config && $config->{algolia};

						if ( $new && !_sameAlgolia( $new, $algolia ) ) {
							main::DEBUGLOG && $log->is_debug && $log->debug("algolia: new search credentials ($reason), retrying");
							return _algoliaQuery( $params, $new, $done, $opts, 1 );
						}

						$done->( { error => { %$error, message => "$error->{message} (search credentials: $reason)" } } );
					} ),
				);
			}

			$done->( { error => $error } );
		} ),
		_httpOpts( $opts, headers => [
			'X-Algolia-Application-Id' => $algolia->{appId},
			'X-Algolia-API-Key'        => $algolia->{apiKey},
		] ),
	);
}

sub _sameAlgolia {
	my ( $x, $y ) = @_;
	return 0 unless ref $x eq 'HASH' && ref $y eq 'HASH';
	return !grep { ( $x->{$_} || '' ) ne ( $y->{$_} || '' ) } qw(appId apiKey indexName);
}

sub _budgetLeft {
	my $now = time();
	@algoliaSent = grep { $_ > $now - ALGOLIA_WINDOW } @algoliaSent;
	return @algoliaSent < ALGOLIA_BUDGET;
}

sub _budgetError {
	return _error( RATE_LIMITED, sprintf(
		'Algolia query budget used up (%d queries per %d minutes); query not sent', ALGOLIA_BUDGET, ALGOLIA_WINDOW / 60,
	) );
}

# Messages from HTTP.pm name the URL, whose host name is the app id.
sub _redact {
	my ( $message, $algolia ) = @_;
	return $message unless defined $message;

	$message =~ s/\Q$algolia->{appId}\E/<appId>/gi;
	$message =~ s/\Q$algolia->{apiKey}\E/<apiKey>/g;

	return $message;
}

# ---------------------------------------------------------------------------
# Shared mechanics: cache, coalescing, last-good copies, callbacks
# ---------------------------------------------------------------------------

# Run one operation for one caller:
#   $op = { key (coalescing), cacheKey, defaultTtl, force, what (for logs), start => sub { ($done, $opts) } }
# start() eventually calls $done->({ data => $data, cacheKeys => [...], at => $epoch }) or
# $done->({ error => \%error }); later calls of $done are ignored.
sub _run {
	my ( $op, $cb, $ecb, $opts ) = @_;
	$opts = {} unless ref $opts eq 'HASH';

	my $waiter = { cb => $cb, ecb => $ecb, opts => $opts };

	if ( !$op->{force} ) {
		if ( my $hit = _fresh( $op->{cacheKey}, _ttl( $op, $opts ) ) ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("$op->{what}: from the cache");
			return _call( $cb, $hit->{data}, { stale => 0, at => $hit->{at} } );
		}
	}

	if ( my $flight = $inFlight{ $op->{key} } ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("$op->{what}: joining the request in flight");
		push @{ $flight->{waiters} }, $waiter;
		return;
	}

	my $flight = $inFlight{ $op->{key} } = { id => ++$flightId, waiters => [$waiter] };

	my $done = sub {
		my $result  = shift;
		my $current = $inFlight{ $op->{key} };
		return unless $current && $current->{id} == $flight->{id};    # settled already

		delete $inFlight{ $op->{key} };
		_settle( $op, $flight->{waiters}, $result );
		return;
	};

	eval { $op->{start}->( $done, $opts ); 1 }
		or $done->( { error => _error( LOAD_FAILED, "$op->{what}: request failed: " . _clean($@) ) } );

	return;
}

# Deliver one result to every waiter: store a success in the cache, or serve each waiter the
# last-good copy (stale_ok) or the error.
sub _settle {
	my ( $op, $waiters, $result ) = @_;

	if ( my $error = $result->{error} ) {
		my $lastGood = ( grep { $_->{opts}->{stale_ok} } @$waiters ) ? _cacheGet( $op->{cacheKey} ) : undef;
		my $isStale  = sub { $lastGood && $_[0]->{opts}->{stale_ok} };

		my @stale  = grep { $isStale->($_) } @$waiters;
		my @failed = grep { !$isStale->($_) } @$waiters;

		_logFailure( $op, $error, @failed ) if @failed;
		_logStale( $op, $error, @stale )    if @stale;

		for my $w (@$waiters) {
			if ( $isStale->($w) ) {
				_call( $w->{cb}, _copy( $lastGood->{data} ), { stale => 1, at => $lastGood->{at} } );
			}
			elsif ( ref $w->{ecb} eq 'CODE' ) {
				_call( $w->{ecb}, {%$error} );
			}
		}

		return;
	}

	my $data = $result->{data};
	my $at   = defined $result->{at} ? $result->{at} : time();

	# keep it as long as the longest-lived waiter wants it
	my $keep = 0;
	for my $w (@$waiters) {
		my $ttl = _ttl( $op, $w->{opts} );
		$keep = $ttl          if $ttl > $keep;
		$keep = LAST_GOOD_TTL if $w->{opts}->{stale_ok} && LAST_GOOD_TTL > $keep;
	}

	if ( $keep > 0 ) {
		my $entry = { data => $data, at => $at };
		for my $key ( @{ $result->{cacheKeys} || [ $op->{cacheKey} ] } ) {
			eval { _cache()->set( _bytes($key), $entry, $keep ); 1 }
				or $log->error( "$op->{what}: couldn't cache the result: " . _clean($@) );
		}
	}

	my $first = 1;
	for my $w (@$waiters) {
		_call( $w->{cb}, $first ? $data : _copy($data), { stale => 0, at => $at } );
		$first = 0;
	}

	return;
}

sub _logFailure {
	my ( $op, $error, @waiters ) = @_;
	my $message = "$op->{what}: $error->{message}";

	if ( grep { !$_->{opts}->{quiet} } @waiters ) {
		$log->warn($message);
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug($message);
	}

	return;
}

sub _logStale {
	my ( $op, $error, @waiters ) = @_;
	my $message = "$op->{what}: serving the last good copy ($error->{message})";

	if ( ( grep { !$_->{opts}->{quiet} } @waiters ) && !$staleWarned{ $op->{cacheKey} }++ ) {
		$log->warn($message);
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug($message);
	}

	return;
}

sub _cache { Slim::Utils::Cache->new(CACHE_NAMESPACE) }

# The cache entry { data, at } for $key, whatever its age, or undef.
sub _cacheGet {
	my $key = _bytes(shift);

	my $entry = eval { _cache()->get($key) };
	$log->error( "Cache read failed for $key: " . _clean($@) ) if $@;

	return ref $entry eq 'HASH' && exists $entry->{data} && defined $entry->{at} ? $entry : undef;
}

# The cache entry for $key if younger than $ttl seconds, else undef.
sub _fresh {
	my ( $key, $ttl ) = @_;
	return undef unless $ttl && $ttl > 0;

	my $entry = _cacheGet($key) or return undef;
	return time() - $entry->{at} < $ttl ? $entry : undef;
}

sub _ttl {
	my ( $op, $opts ) = @_;
	my $ttl = defined $opts->{ttl} ? $opts->{ttl} : $op->{defaultTtl};
	return defined $ttl && !ref $ttl && $ttl =~ /\A[0-9]+(?:\.[0-9]+)?\z/ ? $ttl : 0;
}

# A response handler that can't throw: an exception becomes a LOAD_FAILED result.
sub _handler {
	my ( $done, $what, $code ) = @_;

	return sub {
		my @args = @_;
		eval { $code->(@args); 1 }
			or $done->( { error => _error( LOAD_FAILED, "$what: error processing the response: " . _clean($@) ) } );
		return;
	};
}

sub _call {
	my ( $cb, @args ) = @_;
	return unless ref $cb eq 'CODE';

	eval { $cb->(@args); 1 } or $log->error( 'ABC listen data callback failed: ' . _clean($@) );
	return;
}

# Bad arguments from the caller: logged, and the error callback is called straight away.
sub _invalid {
	my ( $ecb, $message ) = @_;

	$log->warn($message);
	_call( $ecb, _error( LOAD_FAILED, $message ) ) if ref $ecb eq 'CODE';

	return;
}

sub _error {
	my ( $token, $message, $status ) = @_;
	return { error => $token, message => $message, status => $status };
}

# HTTP.pm error callback arguments ($message, $http) -> error hash. 429 is RATE_LIMITED.
sub _httpError {
	my ( $message, $http ) = @_;
	$message = 'unknown error' unless defined $message && length $message;

	my $status = _status( $message, $http );
	return _error( ( $status || 0 ) == 429 ? RATE_LIMITED : LOAD_FAILED, $message, $status );
}

# HTTP status of a failed request: from the status line in HTTP.pm's message ("HTTP request
# failed: 404 Not Found (url)"), or the code of a 2xx response whose body couldn't be decoded.
# undef for transport errors.
sub _status {
	my ( $message, $http ) = @_;

	if ( $message =~ /\AHTTP request failed: ([1-5][0-9][0-9])\b/ ) {
		return $1 + 0;
	}
	return undef if $message =~ /\AHTTP request failed/;

	my $code = ref $http ? eval { $http->code } : undef;
	return defined $code && $code =~ /\A[0-9]{3}\z/ ? $code + 0 : undef;
}

sub _isNotJSON {
	my $message = shift;
	return defined $message && $message =~ /\A(?:Invalid JSON response|Empty response|Unexpected JSON response)/;
}

sub _httpOpts {
	my ( $opts, %extra ) = @_;

	# failures are logged here (once, at the right level), so HTTP.pm logs them at DEBUG only
	my %http = ( quiet => 1, %extra );
	$http{timeout} = $opts->{timeout} if ref $opts eq 'HASH' && $opts->{timeout};

	return \%http;
}

sub _url {
	my ( $base, $path, $query ) = @_;

	$path = '' unless defined $path && !ref $path;
	$path =~ s{\A/+}{};

	my @pairs;
	if ( ref $query eq 'HASH' ) {
		for my $key ( sort keys %$query ) {
			my $value = $query->{$key};
			for my $v ( ref $value eq 'ARRAY' ? @$value : ($value) ) {
				push @pairs, uri_escape_utf8($key) . '=' . uri_escape_utf8( defined $v ? $v : '' );
			}
		}
	}

	return $base . $path . ( @pairs ? '?' . join( '&', @pairs ) : '' );
}

sub _copy {
	my $data = shift;
	return $data unless ref $data;

	my $copy = eval { Storable::dclone($data) };
	return defined $copy ? $copy : $data;
}

# Cache keys are hashed by LMS (MD5), which needs bytes.
sub _bytes {
	my $key = shift;
	utf8::encode($key) if utf8::is_utf8($key);
	return $key;
}

sub _clean {
	my $error = shift;
	$error = 'unknown error' unless defined $error && length $error;
	$error =~ s/\s+at \S+ line \d+.*//s;
	$error =~ s/\s+\z//;
	return $error;
}

sub _show { defined $_[0] ? ( ref $_[0] ? ref $_[0] : "'$_[0]'" ) : 'undef' }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# Forget all state except the cache (for tests).
sub _reset {
	%inFlight    = ();
	@algoliaSent = ();
	%staleWarned = ();
	undef $lastRefresh;
	return;
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

use constant WCMS_HOST   => 'live-production.wcms.abc-cdn.net.au';
use constant RESIZE_HOST => 'resize.abcradio.net.au';

sub imageUrl {
	shift if _isClass( $_[0] );
	my ( $image, $px ) = @_;

	my ( $url, $srcSet ) = ref $image eq 'HASH' ? ( $image->{imgSrc}, $image->{srcSet} ) : ( $image, undef );
	return undef unless defined $url && !ref $url && length $url;
	return $url unless defined $px && $px =~ /\A[1-9][0-9]*\z/;

	my ($host) = $url =~ m{\Ahttps?://([^/?#]+)}i or return $url;
	$host = lc $host;

	return _wcmsSized( $url, $px ) if $host eq WCMS_HOST;

	if ( $host eq RESIZE_HOST ) {
		my $picked = _pickSrcSet( $srcSet, $px );
		return defined $picked ? $picked : $url;
	}

	return $url;
}

# wcms: keep every param (the crop ones above all), set width and height for $px.
sub _wcmsSized {
	my ( $url, $px ) = @_;

	my ( $base, $query, $fragment ) = $url =~ /\A([^?#]*)\?([^#]*)(#.*)?\z/s or return $url;

	my @pairs = map { [ split /=/, $_, 2 ] } split /&/, $query, -1;
	my %param = map { $_->[0] => $_->[1] } grep { defined $_->[1] } @pairs;

	my ( $cropW, $cropH ) = @param{qw(cropW cropH)};
	return $url unless defined $param{impolicy} && length $param{impolicy} && _isPositive($cropW) && _isPositive($cropH);

	my %size = ( width => $px, height => int( $px * $cropH / $cropW + 0.5 ) );

	my ( %set, @out );
	for my $pair (@pairs) {
		my ( $key, $value ) = @$pair;
		if ( exists $size{$key} ) {
			push @out, "$key=$size{$key}" unless $set{$key}++;
		}
		else {
			push @out, defined $value ? "$key=$value" : $key;
		}
	}
	push @out, map {"$_=$size{$_}"} grep { !$set{$_} } qw(width height);

	return $base . '?' . join( '&', @out ) . ( defined $fragment ? $fragment : '' );
}

sub _isPositive { defined $_[0] && $_[0] =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $_[0] > 0 }

# srcSet ([ "<url> <n>w", ... ] or an HTML srcset string) -> the URL with the smallest width >= $px,
# else the widest; undef without usable entries.
sub _pickSrcSet {
	my ( $srcSet, $px ) = @_;

	my @entries = ref $srcSet eq 'ARRAY' ? @$srcSet
		: defined $srcSet && !ref $srcSet ? split( /\s*,\s+/, $srcSet )
		: ();

	my @candidates;
	for my $entry (@entries) {
		next unless defined $entry && !ref $entry;
		my ( $url, $width ) = $entry =~ /\A\s*(\S+)(?:\s+([0-9]+)w)?\s*\z/ or next;
		($width) = $url =~ m{/([0-9]+)x[0-9]+/} unless defined $width;
		push @candidates, [ $url, $width ] if defined $width;
	}

	my ($best) = sort { $a->[1] <=> $b->[1] } grep { $_->[1] >= $px } @candidates;
	($best) = sort { $b->[1] <=> $a->[1] } @candidates unless $best;

	return $best ? $best->[0] : undef;
}

my %BLOCK = map { $_ => 1 } qw(p div @@standfirst li h1 h2 h3 h4 h5 h6 blockquote br);

sub richText {
	shift if _isClass( $_[0] );
	my $x = shift;

	return '' unless defined $x;

	if ( !ref $x ) {
		my $text = decodeEntities($x);
		$text =~ s/\A\s+|\s+\z//g;
		return $text;
	}

	return '' unless ref $x eq 'HASH';

	my $node = exists $x->{type} ? $x
		: ref $x->{descriptor} eq 'HASH' ? $x->{descriptor}
		: ref $x->{descriptionPrepared} eq 'HASH' && ref $x->{descriptionPrepared}->{descriptor} eq 'HASH' ? $x->{descriptionPrepared}->{descriptor}
		: undef;
	return '' unless $node;

	my $state = { paragraphs => [], buffer => '' };
	_richWalk( $node, $state, 0 );
	_richFlush($state);

	return join( "\n\n", @{ $state->{paragraphs} } );
}

sub _richWalk {
	my ( $node, $state, $depth ) = @_;
	return unless ref $node eq 'HASH' && $depth < 100;

	if ( ( $node->{type} || '' ) eq 'text' ) {
		$state->{buffer} .= $node->{content} if defined $node->{content} && !ref $node->{content};
		return;
	}

	my $block = defined $node->{key} && !ref $node->{key} && $BLOCK{ lc $node->{key} };

	_richFlush($state) if $block;
	_richWalk( $_, $state, $depth + 1 ) for ref $node->{children} eq 'ARRAY' ? @{ $node->{children} } : ();
	_richFlush($state) if $block;

	return;
}

sub _richFlush {
	my $state = shift;

	my $text = decodeEntities( $state->{buffer} );
	$text =~ s/\s+/ /g;
	$text =~ s/\A | \z//g;

	push @{ $state->{paragraphs} }, $text if length $text;
	$state->{buffer} = '';

	return;
}

sub coreMediaRef {
	shift if _isClass( $_[0] );
	my $uri = shift;
	return () unless defined $uri && !ref $uri;

	my ( $type, $id ) = $uri =~ m{\Acoremedia://([A-Za-z][A-Za-z0-9_]*)/([0-9]+)\z} or return ();
	return ( lc $type, $id );
}

sub sitePath {
	shift if _isClass( $_[0] );
	my $url = shift;
	return undef unless defined $url && !ref $url;

	$url =~ s/\A\s+|\s+\z//g;

	my $path;
	if ( $url =~ m{\A(?:https?:)?//([^/?#]*)(.*)\z}is ) {
		my ( $host, $rest ) = ( lc $1, $2 );
		return undef unless $host eq 'www.abc.net.au' || $host eq 'abc.net.au';
		$path = $rest;
	}
	elsif ( $url =~ m{\A/} ) {
		$path = $url;
	}
	else {
		return undef;
	}

	$path =~ s/[?#].*\z//s;
	$path =~ s{/+\z}{};

	return length $path ? $path : '/';
}

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);
my $NOT_A_NAME = qr/\b(?:logo|image|illustration|photo|graphic|stylised|stylized|square|featuring)\b/i;

sub cardRef {
	shift if _isClass( $_[0] );
	my $card = shift;
	return undef unless ref $card eq 'HASH';

	my ( $type, $uriId ) = coreMediaRef( $card->{contentUri} ) or return undef;

	# curated cards often carry a teaser id in contentUri: prefer the document's own id
	my $id = _digits( $card->{cardId} );
	$id = _lastNumericSegment( $card->{articleLink} ) if !defined $id && ( $AUDIO_TYPE{$type} || $type eq 'dynamiccollection' );
	$id = $uriId unless defined $id;

	# FQ4: program cards' cardTitle is often an editorial tagline; the image alt text is sometimes the
	# name, sometimes an image description, a file name or another program's name (F5). A cardTitle
	# that spells the page slug is the name; else the part of a name-like alt text that spells it.
	my $cardTitle = _cleanText( $card->{cardTitle} );
	my ( $title, $tagline ) = ( $cardTitle, undef );
	if ( $type eq 'program' && !_spellsSlug( $cardTitle, $card->{articleLink} ) ) {
		my $alt  = _cleanText( ref $card->{cardImagePrepared} eq 'HASH' ? $card->{cardImagePrepared}->{alt} : undef );
		my $name = _looksLikeName($alt) ? _slugName( $alt, $card->{articleLink} ) : undef;
		( $title, $tagline ) = ( $name, defined $cardTitle && lc $cardTitle ne lc $name ? $cardTitle : undef ) if defined $name;
	}

	my $media    = ref $card->{cardMediaIndicatorPrepared} eq 'HASH' ? $card->{cardMediaIndicatorPrepared} : {};
	my $duration = $media->{duration};
	$duration = undef unless defined $duration && !ref $duration && $duration =~ /\A[0-9]+\z/ && $duration > 0;

	my $attribution = ref $card->{cardAttributionPrepared} eq 'HASH' ? $card->{cardAttributionPrepared} : {};

	my $docType = _cleanText( $card->{docType} );
	$docType = $type if !defined $docType && $AUDIO_TYPE{$type};

	return {
		type        => $type,
		id          => $id,
		uriId       => $uriId,
		title       => $title,
		tagline     => $tagline,
		path        => sitePath( $card->{articleLink} ),
		image       => imageUrl( $card->{cardImagePrepared}, CARD_IMAGE_PX ),
		date        => parseISO8601( _cleanText( $attribution->{publishedDate} ) ),
		duration    => defined $duration ? $duration + 0 : undef,
		programId   => _digits( defined $card->{programID} ? $card->{programID} : $card->{programId} ),
		docType     => $docType,
		description => _cleanText( $card->{description} ),
	};
}

sub _looksLikeName {
	my $text = shift;
	return defined $text && length $text && length $text <= 50 && $text !~ /\b[0-9]+x[0-9]+\b/i && $text !~ $NOT_A_NAME;
}

# True when $title starts with the slug of $link (see _slugPrefix).
sub _spellsSlug { defined _slugPrefix(@_) ? 1 : 0 }

# The alt-text name that spells the slug of $link: _slugPrefix, file-name underscores as spaces.
sub _slugName {
	my $name = _slugPrefix(@_);
	return undef unless defined $name;

	$name =~ s/[\s_]+/ /g;
	return $name;
}

# The start of $text that spells the last segment of $link (minus a trailing '-page'), or undef:
# the slug's letters and digits in order (any case, accents ignored, nothing but punctuation and
# spaces between them), ending at a word boundary, plus any '?' or '!' right after it. Leading
# punctuation is not part of it. ('Global Roaming podcast', /global-roaming/ -> 'Global Roaming')
sub _slugPrefix {
	my ( $text, $link ) = @_;
	return undef unless defined $text && !ref $text && defined $link && !ref $link;

	$link =~ s/[?#].*\z//s;
	$link =~ s{/+\z}{};
	my ($slug) = $link =~ m{/([^/]+)\z} or return undef;

	$slug = lc $slug;
	$slug =~ s/-page\z//;
	$slug =~ s/[^a-z0-9]+//g;
	return undef unless length $slug;

	$text = Unicode::Normalize::NFD($text) if $HAS_NORMALIZE;
	my $spelled = join '\P{Alnum}*', split //, $slug;
	my ($prefix) = $text =~ /\A\P{Alnum}*($spelled\p{M}*+(?!\p{Alnum})[?!]*)/i or return undef;

	return $HAS_NORMALIZE ? Unicode::Normalize::NFC($prefix) : $prefix;
}

sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }

sub _lastNumericSegment {
	my $link = shift;
	return undef unless defined $link && !ref $link;

	$link =~ s/[?#].*\z//s;
	$link =~ s{/+\z}{};

	return $link =~ m{/([0-9]+)\z} ? $1 : undef;
}

# Entity-decoded, trimmed string, or undef if empty.
sub _cleanText {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;

	return length $text ? $text : undef;
}

1;
