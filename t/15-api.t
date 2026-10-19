#!/usr/bin/perl
# Plugins::ABCListen::API network functions, offline (SimpleAsyncHTTP stub, fake clock): URL
# building per function; siteConfig parse, 6 h cache, force and coalescing; nextData buildId
# refresh (one refresh per 60 s, one retry only if the buildId changed) and __N_REDIRECT handling;
# F4: page paths spelled as ABC serves them (lower-case, escapes lower-case, non-ASCII encoded), a
# 307 that LMS can't follow, and HTTP 308 (legacy program paths) followed by its Location;
# Algolia headers, cache, rolling budget, 401/403 re-discovery, 429, no-config and no-key logging;
# coalescing with deferred responses; ttl / stale_ok / quiet; exactly one callback on every path.
#
# Fixtures in t/data/foundation/ are raw response bodies as served. Copied from
# ai-state/research/abc-samples/ (trimmed there; shapes unedited; the research {_fixture_note, data}
# wrapper stripped, _next/data subtrees re-wrapped as {"pageProps": ...} at the path the note names):
#   bff-collection-home-most-popular-podcasts.json   GET /core-next/api/collection/listen?collectionId=103194120&offset=0&size=10
#   bff-collection-audiobooks-most-popular.json      GET /core-next/api/collection/x?collectionId=105672994&rootMetaCollectionId=105894152&metaInMeta=false&offset=0&size=20
#   bff-collection-local-stations-nsw.json           GET /core-next/api/collection/listen/radio?collectionId=14126370&rootMetaCollectionId=14123276&metaInMeta=false
#   bff-collection-national-networks.json            GET /core-next/api/collection/listen/radio?collectionId=12872264&rootMetaCollectionId=14139428&metaInMeta=false
#   bff-programAggregationCollection-rn.json         GET /core-next/api/programAggregationCollection/listen/radionational/programs?collectionId=11474038&offset=20&size=20&total=56
#   bff-episodesWithSegments-scienceshow.json        GET /core-next/api/episodesWithSegments/listen/programs/scienceshow?collectionId=2885458&offset=240&size=10&total=250&programTemplate=audio
#   bff-recommendations-homepagePopularNow.json      GET /core-next/api/recommendations/listen/homepagePopularNow
#   nextdata-program-scienceshow.trimmed.json        GET /_next/data/<buildId>/listen/programs/scienceshow.json (research kept pageProps -> {"pageProps": ...};
#                                                    profilesProviderPrepared.APIKey (Gigya site key) replaced by a dummy)
#   nextdata-episode-scienceshow-mp3.trimmed.json    GET /_next/data/<buildId>/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790.json
#                                                    (research kept pageProps.data -> {"pageProps": {"data": ...}})
#   nextdata-listen-home.components.trimmed.json     GET /_next/data/build-3afcd04f/listen.json (research summary of pageProps.data -> {"pageProps": {"data": ...}};
#                                                    profilesProviderPrepared.APIKey (Gigya site key) replaced by a dummy)
#   nextdata-section-news.trimmed.json               GET /_next/data/build-3afcd04f/listen/news.json
#   nextdata-section-kidslisten-programs.trimmed.json GET /_next/data/build-3afcd04f/kidslisten/programs.json
#   nextdata-section-sport.programs.trimmed.json     GET /_next/data/build-3afcd04f/listen/sport.json (only the 'Programs'
#                                                    collection kept from the research copy's componentsContent)
#   algolia-listen_prod_all-query.json               POST https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query {"query":"science show","hitsPerPage":3,"facets":["*"]}
#   papi-services.trimmed.json                       GET https://program.abcradio.net.au/api/v1/services.json
#   music-abcradio-plays-search-triplej.json         GET https://music.abcradio.net.au/api/v1/plays/search.json?station=triplej&order=desc&limit=3
#   triplejnsw.pls (F1)                              GET https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls
# Recorded for F3 (2026-10-19, through $HTTPS_PROXY):
#   listen-search.trimmed.html     GET https://www.abc.net.au/listen/search, trimmed to "buildId" and the __NEXT_DATA__
#                                  Search component + masthead query-suggestions config; the real Algolia app id
#                                  and key replaced by TESTAPPID / testsearchkey
#   next-data-404.html             GET https://www.abc.net.au/_next/data/build-00000000/listen.json (404 text/html, trimmed)
#   nextdata-redirect-relative.json GET https://www.abc.net.au/_next/data/build-3afcd04f/listen/programs/scienceshow/x/107266790.json
#   music-400.json                 GET https://music.abcradio.net.au/api/v1/plays/rn/now.json (400 application/json)
# Recorded for F4 (2026-10-19, buildId build-3afcd04f), shared with t/30-episode.t:
#   ondemand/nextdata-generic-107267360.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/107267360.json
#                                              (__N_REDIRECT to the canonical path, spelled with upper-case %C3%B1)
#   ondemand/nextdata-episode-nonascii-107267360.trimmed.json  GET .../if-youre-listening/the-apocalyptic-el-ni%c3%b1o-we-didn-t-see-coming/107267360.json
#                                              (documentProps keys Episode.pm reads; the upper-case %C3%B1 spelling of the same
#                                              URL answers 307 with only an x-nextjs-redirect header to this one, no Location)
# Synthetic: html-page-200.html (HTML from a JSON endpoint), nextdata-redirect-absolute.json,
#   nextdata-redirect-loop-a/b.json, bad.json (truncated), algolia-401/403/429.json,
#   bff-collection-empty.json, listen-search-no-algolia.html, listen-search-no-buildid.html.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use Encode ();
use JSON::PP ();
use Scalar::Util qw(refaddr);

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::ABCListen::API;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# plugin.abclisten at DEBUG, so DEBUG lines (HTTP.pm's request lines included) are logged
Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' } );

my $SITE        = 'https://www.abc.net.au';
my $SEARCH      = "$SITE/listen/search";
my $BFF         = "$SITE/core-next/api";
my $BUILD       = 'build-3afcd04f';
my $NEW_BUILD   = 'build-0newdeploy';
my $ALGOLIA     = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $PLS         = 'https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls';
my $SCIENCE     = '/listen/programs/scienceshow';
my $EPISODE     = '/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790';
my $T0          = 1_792_400_000;
my $LOAD_FAILED = 'PLUGIN_ABCLISTEN_LOAD_FAILED';
my $RATE_LIMITED = 'PLUGIN_ABCLISTEN_RATE_LIMITED';

my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $HTML_TYPE = { 'Content-Type' => 'text/html; charset=utf-8' };

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	setTime( shift || $T0 );
}

sub clear_requests { @Slim::Networking::SimpleAsyncHTTP::REQUESTS = () }
sub clear_routes   { @Slim::Networking::SimpleAsyncHTTP::ROUTES   = () }
sub urls           { map { $_->{url} } requests() }
sub json_file      { JSON::PP::decode_json( fixture("foundation/$_[0]") ) }
sub data_url       { "$SITE/_next/data/$_[0]$_[1].json" }

# Responses in turn for one route (the last one repeats).
sub route_seq {
	my ( $match, @responses ) = @_;
	for my $r (@responses) {
		$r = { %$r };
		$r->{content} = fixture( delete $r->{file} ) if $r->{file};
	}
	Slim::Networking::SimpleAsyncHTTP->addRoute( $match, sub { @responses > 1 ? shift @responses : $responses[0] } );
}

# The recorded search page, optionally with another buildId or key.
sub search_page {
	my %with = @_;
	my $html = fixture('foundation/listen-search.trimmed.html');
	$html =~ s/build-3afcd04f/$with{buildId}/g if $with{buildId};
	$html =~ s/testsearchkey/$with{apiKey}/g   if $with{apiKey};
	return { code => 200, content => $html, headers => $HTML_TYPE };
}

sub serve_search { route_seq( $SEARCH, map { search_page(%$_) } @_ ? @_ : ( {} ) ) }

# Load siteConfig into the cache (one request), then forget the requests.
sub prime {
	my $c = collector();
	Plugins::ABCListen::API::siteConfig( $c->cb, $c->cb );
	die 'priming siteConfig failed' unless $c->count == 1 && ref( ( $c->args )[0] ) eq 'HASH' && ( $c->args )[0]->{buildId};
	clear_requests();
}

# Call API::<fn>(@leading, $cb, $ecb, $opts); returns the success and error collectors.
sub api {
	my ( $fn, $leading, $opts ) = @_;
	my ( $ok, $err ) = ( collector(), collector() );
	no strict 'refs';
	&{"Plugins::ABCListen::API::$fn"}( @$leading, $ok->cb, $err->cb, $opts );
	return ( $ok, $err );
}

sub one_ok {
	my ( $ok, $err, $name ) = @_;
	is( $ok->count + $err->count, 1, "$name: exactly one callback" );
	is( $ok->count, 1, "$name: the success callback" ) or diag explain [ $err->args ];
	return ( $ok->args );
}

sub one_err {
	my ( $ok, $err, $name, $token, $status ) = @_;
	is( $ok->count + $err->count, 1, "$name: exactly one callback" );
	is( $err->count, 1, "$name: the error callback" ) or return;
	my ($e) = $err->args;
	is( ref $e, 'HASH', "$name: error is a hash" );
	is_deeply( [ sort keys %$e ], [qw(error message status)], "$name: keys error, message, status" );
	is( $e->{error},  $token,  "$name: $token" );
	is( $e->{status}, $status, "$name: status " . ( defined $status ? $status : 'undef' ) );
	ok( defined $e->{message} && length $e->{message}, "$name: readable message" );
	return $e;
}

sub log_messages { Slim::Utils::Log->messages( category => 'plugin.abclisten', @_ ) }
sub warns        { log_messages( level => 'WARN' ) }

# ---------------------------------------------------------------------------
# bff / papi / music / text: URLs, results, errors
# ---------------------------------------------------------------------------

subtest 'bff: URL building with canonical, escaped queries' => sub {
	fresh();
	route( qr{^\Q$BFF/\E}, file => 'foundation/bff-collection-home-most-popular-podcasts.json', headers => $JSON_TYPE );

	my @cases = (
		[ [ 'collection/x', { size => 2, offset => 0, collectionId => 103194120 } ], "$BFF/collection/x?collectionId=103194120&offset=0&size=2" ],
		[ [ '/epgNowPlaying/RN/now', { imageRatio => '1x1' } ],                     "$BFF/epgNowPlaying/RN/now?imageRatio=1x1" ],
		[ [ 'recommendations/listen/homepagePopularNow', undef ],                   "$BFF/recommendations/listen/homepagePopularNow" ],
		[ [ 'schedule', {} ],                                                       "$BFF/schedule" ],
		[ [ 'schedule', { tz => 'Australia/Sydney', service => 'RN', date => '2026-10-19' } ], "$BFF/schedule?date=2026-10-19&service=RN&tz=Australia%2FSydney" ],
		[ [ 'search', { q => 'a b&c/d=e?', 'x y' => 'Café', z => undef } ],         "$BFF/search?q=a%20b%26c%2Fd%3De%3F&x%20y=Caf%C3%A9&z=" ],
		[ [ 'tracklist', { station => [ 'triplej', 'doublej' ] } ],                 "$BFF/tracklist?station=triplej&station=doublej" ],
	);

	for my $case (@cases) {
		my ( $args, $url ) = @$case;
		clear_requests();
		my ( $ok, $err ) = api( bff => $args );
		one_ok( $ok, $err, $url );
		is_deeply( [ urls() ], [$url], "requested $url" );
	}

	clear_requests();
	my ( $ok, $err ) = api( bff => ['recommendations/listen/homepagePopularNow'] );
	one_ok( $ok, $err, 'query left out: bff($path, $cb, $ecb)' );
	is_deeply( [ urls() ], ["$BFF/recommendations/listen/homepagePopularNow"], 'query left out: no query string' );

	clear_requests();
	( $ok, $err ) = api( bff => [ 'collection/x', { b => 1, a => 2 } ] );
	my $req = ( requests() )[0];
	is( $req->{method}, 'GET', 'GET' );
	is( $req->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), "LMS's User-Agent (through HTTP.pm)" );
	is( $req->{params}->{timeout}, 15, 'default timeout' );
	ok( !exists $req->{params}->{quiet}, 'quiet is not a SimpleAsyncHTTP param' );

	clear_requests();
	api( bff => [ 'collection/x', undef ], { timeout => 4 } );
	is( ( requests() )[0]->{params}->{timeout}, 4, 'opts timeout passed through' );
};

subtest 'bff: success callback gets the decoded data and { stale => 0 }' => sub {
	fresh();
	route( "$BFF/collection/x?collectionId=103194120", file => 'foundation/bff-collection-home-most-popular-podcasts.json', headers => { 'Content-Type' => 'text/plain' } );

	my ( $ok, $err ) = api( bff => [ 'collection/x', { collectionId => 103194120 } ] );
	my ( $data, $info ) = one_ok( $ok, $err, 'collection' );
	is_deeply( $data, json_file('bff-collection-home-most-popular-podcasts.json'), 'the decoded body' );
	is_deeply( $info, { stale => 0 }, 'info: stale 0' );

	clear_routes();
	route( "$BFF/collection/x?collectionId=1", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE );
	( $ok, $err ) = api( bff => [ 'collection/x', { collectionId => 1 } ] );
	($data) = one_ok( $ok, $err, 'empty collection' );
	is_deeply( $data->{collection}->{items}, [], 'an empty collection is a success with no items' );
};

subtest 'papi, music and text URLs and results' => sub {
	fresh();
	route( 'https://program.abcradio.net.au/api/v1/services.json?offset=100', file => 'foundation/papi-services.trimmed.json', headers => $JSON_TYPE );
	route( 'https://music.abcradio.net.au/api/v1/plays/search.json?limit=1&order=desc&station=triplej', file => 'foundation/music-abcradio-plays-search-triplej.json', headers => $JSON_TYPE );
	route( $PLS, file => 'foundation/triplejnsw.pls', headers => { 'Content-Type' => 'audio/x-scpls' } );

	my ( $ok, $err ) = api( papi => [ 'services.json', { offset => 100 } ] );
	my ($data) = one_ok( $ok, $err, 'papi' );
	is( $data->{items}->[0]->{service_id}, 'doublej', 'papi: decoded' );

	( $ok, $err ) = api( music => [ '/plays/search.json', { station => 'triplej', order => 'desc', limit => 1 } ] );
	($data) = one_ok( $ok, $err, 'music' );
	is( $data->{items}->[0]->{recording}->{title}, 'AAAHHH!!!', 'music: decoded' );

	( $ok, $err ) = api( text => [$PLS] );
	($data) = one_ok( $ok, $err, 'text' );
	is( $data, fixture('foundation/triplejnsw.pls'), 'text: the raw body' );

	is_deeply( [ map { $_->{method} } requests() ], [qw(GET GET GET)], 'all GET' );

	for my $bad ( undef, '', 'ftp://example.com/x', '/listen', [] ) {
		clear_requests();
		my $sync;
		my ( $ok2, $err2 ) = ( collector(), collector() );
		Plugins::ABCListen::API::text( $bad, $ok2->cb, $err2->cb );
		$sync = $err2->count;
		one_err( $ok2, $err2, 'text(' . ( defined $bad ? "'$bad'" : 'undef' ) . ')', $LOAD_FAILED, undef );
		is( $sync, 1, 'invalid URL: error callback before text() returns' );
		is( scalar requests(), 0, 'invalid URL: no request' );
	}
};

subtest 'errors: tokens, status and one WARN' => sub {
	my $url = "$BFF/collection/x";
	my @cases = (
		[ 'HTTP 500',          { code => 500, content => 'oops' },                                      $LOAD_FAILED,  500,   qr/500 Internal Server Error/ ],
		[ 'HTTP 404',          { code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE }, $LOAD_FAILED, 404, qr/404 Not Found/ ],
		[ 'HTTP 429',          { code => 429, content => '{}' },                                        $RATE_LIMITED, 429,   qr/429 Too Many Requests/ ],
		[ 'transport error',   { error => 'Timed out waiting for data' },                               $LOAD_FAILED,  undef, qr/Timed out/ ],
		[ 'bad JSON',          { code => 200, file => 'foundation/bad.json', headers => $JSON_TYPE },   $LOAD_FAILED,  200,   qr/Invalid JSON/ ],
		[ 'HTML for JSON',     { code => 200, file => 'foundation/html-page-200.html', headers => $HTML_TYPE }, $LOAD_FAILED, 200, qr/Invalid JSON/ ],
		[ 'empty body',        { code => 200, content => '' },                                          $LOAD_FAILED,  200,   qr/Empty response/ ],
	);

	for my $case (@cases) {
		my ( $name, $response, $token, $status, $message ) = @$case;
		fresh();
		route( $url, %$response );
		my ( $ok, $err ) = api( bff => [ 'collection/x', undef ] );
		my $e = one_err( $ok, $err, $name, $token, $status );
		like( $e->{message}, $message, "$name: message says what went wrong" );
		like( $e->{message}, qr/\Q$url\E/, "$name: message names the URL" );
		my @w = warns();
		is( scalar @w, 1, "$name: one WARN" );
		like( $w[0]->{message}, $message, "$name: the WARN has the reason" ) if @w;
	}

	fresh();
	my ( $ok, $err ) = api( bff => ['nothing/here'] );
	one_err( $ok, $err, 'no route (network failure)', $LOAD_FAILED, undef );

	fresh();
	route( 'https://music.abcradio.net.au/api/v1/plays/rn/now.json', code => 400, file => 'foundation/music-400.json', headers => $JSON_TYPE );
	( $ok, $err ) = api( music => ['plays/rn/now.json'] );
	my $e = one_err( $ok, $err, 'music API 400', $LOAD_FAILED, 400 );
	like( $e->{message}, qr/400 Bad Request/, 'music 400: message' );

	fresh();
	route( $url, code => 500 );
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { quiet => 1 } );
	one_err( $ok, $err, 'quiet 500', $LOAD_FAILED, 500 );
	is( scalar warns(), 0, 'quiet: no WARN' );
	ok( scalar( grep { $_->{message} =~ /500 Internal Server Error/ } log_messages( level => 'DEBUG' ) ), 'quiet: logged at DEBUG' );
};

subtest 'a missing callback does not crash' => sub {
	fresh();
	route( "$BFF/bad", code => 500 );
	route( "$BFF/good", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE );

	my $ok = collector();
	ok( eval { Plugins::ABCListen::API::bff( 'bad', undef, $ok->cb, undef ); 1 }, 'error without $ecb: no crash' ) or diag $@;
	is( $ok->count, 0, 'error without $ecb: success callback not called' );
	is( scalar warns(), 1, 'error without $ecb: the error is logged' );

	ok( eval { Plugins::ABCListen::API::bff( 'good', undef, undef, undef ); 1 }, 'success without $cb: no crash' ) or diag $@;
	ok( eval { Plugins::ABCListen::API::nextData( 'https://example.com/', undef, undef ); 1 }, 'invalid arguments without $ecb: no crash' ) or diag $@;
	ok( eval { Plugins::ABCListen::API::algolia( 'not a hash', undef ); 1 }, 'invalid algolia params without callbacks: no crash' ) or diag $@;
};

# ---------------------------------------------------------------------------
# ttl, stale_ok, quiet
# ---------------------------------------------------------------------------

subtest 'ttl: no request within it, one after it; no ttl, no cache; cache hits are synchronous' => sub {
	fresh();
	route( "$BFF/collection/x", file => 'foundation/bff-collection-home-most-popular-podcasts.json', headers => $JSON_TYPE, defer => 1 );

	my ( $ok, $err ) = api( bff => [ 'collection/x', undef ], { ttl => 300 } );
	is( $ok->count, 0, 'network call: no callback before the response' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	my ($first) = one_ok( $ok, $err, 'first call' );
	$first->{collection}->{title} = 'changed by the caller';

	advanceTime(299);
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { ttl => 300 } );
	is( $ok->count, 1, 'cache hit: called back before bff() returned (synchronously)' );
	my ( $data, $info ) = one_ok( $ok, $err, 'within the TTL' );
	is( scalar requests(), 1, 'within the TTL: no request' );
	is( $data->{collection}->{title}, 'Most Popular Podcasts', "the cached copy isn't changed by a caller" );
	is_deeply( $info, { stale => 0 }, 'cache hit: stale 0' );

	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { ttl => 1000 } );
	is( scalar requests(), 1, "a caller's longer TTL also hits (age 299 s)" );
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { ttl => 100 } );
	is( scalar requests(), 2, "a caller's shorter TTL misses (age 299 s > 100 s)" );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( $ok, $err, 'shorter TTL' );

	advanceTime(300);
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { ttl => 300 } );
	is( scalar requests(), 3, 'after the TTL: a new request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( $ok, $err, 'after the TTL' );

	for my $opts ( undef, {}, { ttl => 0 }, { ttl => 'soon' } ) {
		clear_requests();
		api( bff => [ 'collection/x', undef ], $opts );
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		api( bff => [ 'collection/x', undef ], $opts );
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		is( scalar requests(), 2, 'no cache with ttl ' . ( $opts && defined $opts->{ttl} ? $opts->{ttl} : 'absent' ) );
	}
};

subtest 'stale_ok: last-good copy on error, WARN once then DEBUG; quiet; no copy -> error' => sub {
	fresh();
	route_seq( "$BFF/collection/x", { file => 'foundation/bff-collection-home-most-popular-podcasts.json', headers => $JSON_TYPE }, { code => 503 } );

	my ( $ok, $err ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	my ($good) = one_ok( $ok, $err, 'first call' );

	advanceTime(600);
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	my ( $data, $info ) = one_ok( $ok, $err, 'error after an earlier success' );
	is_deeply( $data, $good, 'the old data' );
	is_deeply( $info, { stale => 1 }, 'info: stale 1' );
	my @w = warns();
	is( scalar @w, 1, 'one WARN' );
	like( $w[0]->{message}, qr/last good copy.*503 Service Unavailable/, 'WARN: serving the last good copy, and why' ) if @w;

	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	one_ok( $ok, $err, 'second stale serve' );
	is( scalar warns(), 1, 'second stale serve: no new WARN' );
	ok( scalar( grep { $_->{message} =~ /last good copy/ } log_messages( level => 'DEBUG' ) ), 'second stale serve: logged at DEBUG' );

	( $ok, $err ) = api( bff => [ 'collection/x', undef ] );
	one_err( $ok, $err, 'same error without stale_ok', $LOAD_FAILED, 503 );

	( $ok, $err ) = api( bff => [ 'collection/y', undef ], { stale_ok => 1 } );
	one_err( $ok, $err, 'stale_ok with no last-good copy', $LOAD_FAILED, undef );

	advanceTime( 7 * 86400 );
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	one_err( $ok, $err, 'last-good copy older than 7 days', $LOAD_FAILED, 503 );

	# quiet: no WARN at all
	fresh();
	route_seq( "$BFF/collection/x", { file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE }, { code => 500 } );
	api( bff => [ 'collection/x', undef ], { stale_ok => 1, quiet => 1 } );
	( $ok, $err ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1, quiet => 1 } );
	( undef, $info ) = one_ok( $ok, $err, 'quiet stale serve' );
	is( $info->{stale}, 1, 'quiet: stale' );
	is( scalar warns(), 0, 'quiet: no WARN' );
};

# ---------------------------------------------------------------------------
# coalescing
# ---------------------------------------------------------------------------

subtest 'coalescing: identical requests in flight share one HTTP request' => sub {
	fresh();
	route( qr{^\Q$BFF/collection/\E}, file => 'foundation/bff-collection-home-most-popular-podcasts.json', headers => $JSON_TYPE, defer => 1 );

	my ( $ok1, $err1 ) = api( bff => [ 'collection/x', { a => 1, b => 2 } ] );
	my ( $ok2, $err2 ) = api( bff => [ '/collection/x', { b => 2, a => 1 } ] );
	is( scalar requests(), 1, 'two identical deferred requests: 1 HTTP request' );
	is( $ok1->count + $ok2->count, 0, 'nothing yet' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	my ($d1) = one_ok( $ok1, $err1, 'first caller' );
	my ($d2) = one_ok( $ok2, $err2, 'second caller' );
	is_deeply( $d1, $d2, 'same data' );
	isnt( refaddr($d1), refaddr($d2), 'each caller has its own copy' );

	clear_requests();
	api( bff => [ 'collection/x', { a => 1 } ] );
	api( bff => [ 'collection/x', { a => 2 } ] );
	is( scalar requests(), 2, 'different URLs: 2 requests' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;

	clear_requests();
	api( bff => [ 'collection/x', undef ] );
	api( text => ["$BFF/collection/x"] );
	is( scalar requests(), 2, 'same URL, JSON and text: 2 requests' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
};

subtest "coalescing: a dying callback doesn't stop the others; errors and stale per caller" => sub {
	fresh();
	route( "$BFF/collection/x", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE, defer => 1 );

	my ( $calls, $err1 ) = ( 0, collector() );
	Plugins::ABCListen::API::bff( 'collection/x', undef, sub { $calls++; die "consumer bug\n" }, $err1->cb );
	my ( $ok2, $err2 ) = api( bff => [ 'collection/x', undef ] );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;

	is( $calls, 1, 'the first callback ran once (and died)' );
	is( $err1->count, 0, 'its error callback was not called as well' );
	one_ok( $ok2, $err2, 'the second caller still got its callback' );
	ok( scalar( grep { $_->{message} =~ /consumer bug/ } log_messages( level => 'ERROR' ) ), 'the exception is logged at ERROR' );

	# an error shared by three waiters: one with a last-good copy (stale_ok), one without, one quiet
	clear_requests();
	my ( $okA, $errA ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( $okA, $errA, 'seed a last-good copy' );
	Slim::Utils::Log->resetMessages;

	( $okA, $errA ) = api( bff => [ 'collection/x', undef ], { stale_ok => 1 } );
	my ( $okB, $errB ) = api( bff => [ 'collection/x', undef ] );
	my ( $okC, $errC ) = api( bff => [ 'collection/x', undef ], { quiet => 1 } );
	is( scalar requests(), 2, 'three callers, one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred( error => 'Timed out waiting for data' );
	my ( undef, $info ) = one_ok( $okA, $errA, 'stale_ok caller' );
	is( $info->{stale}, 1, 'stale_ok caller: stale copy' );
	one_err( $okB, $errB, 'plain caller', $LOAD_FAILED, undef );
	one_err( $okC, $errC, 'quiet caller', $LOAD_FAILED, undef );
	is( scalar( grep { $_->{message} =~ /Timed out/ && $_->{message} !~ /last good/ } warns() ), 1, 'the failure is logged once at WARN' );
};

# ---------------------------------------------------------------------------
# siteConfig
# ---------------------------------------------------------------------------

subtest 'siteConfig: buildId and the Search component Algolia config' => sub {
	fresh();
	serve_search();

	my ( $ok, $err ) = api( siteConfig => [] );
	my ( $config, $info ) = one_ok( $ok, $err, 'siteConfig' );
	is_deeply(
		$config,
		{ buildId => $BUILD, algolia => { appId => 'TESTAPPID', apiKey => 'testsearchkey', indexName => 'listen_prod_all' } },
		'buildId and the listen_prod_all config (not the masthead query-suggestions index)'
	);
	is_deeply( $info, { stale => 0 }, 'fresh' );
	is_deeply( [ urls() ], [$SEARCH], 'GET /listen/search' );
	is( ( requests() )[0]->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), 'User-Agent' );

	# ranking without relying on key order
	my $page = sub {
		my $json = shift;
		return { code => 200, headers => $HTML_TYPE, content => qq{<html><body><script id="__NEXT_DATA__" type="application/json">$json</script></body></html>} };
	};
	my $client = '"client":{"appId":"APP1","apiKey":"key1"}';
	my @ranking = (
		[ qq({"buildId":"b1","props":{"a":{$client,"indexName":"listen_prod_all_query_suggestions"},"b":{"component":"Search","componentProps":{$client,"indexName":"zz_index"}}}}), 'zz_index', 'Search component first' ],
		[ qq({"buildId":"b1","props":{"a":{$client,"indexName":"aa_main_index"},"b":{"component":"Search","componentProps":{$client,"indexName":"zz_index"}}}}), 'zz_index', 'Search component beats an earlier non-suggestions index' ],
		[ qq({"buildId":"b1","props":{"a":{$client,"indexName":"aa_query_suggestions"},"b":{$client,"indexName":"main_index"}}}), 'main_index', 'then a non-suggestions index' ],
		[ qq({"buildId":"b1","props":{"a":{$client,"indexName":"only_query_suggestions"}}}), 'only_query_suggestions', 'then anything' ],
		[ qq({"buildId":"b1","props":{"a":{"client":{"appId":"bad id!","apiKey":"k"},"indexName":"x"}}}), undef, 'an unusable app id is ignored' ],
	);
	for my $case (@ranking) {
		my ( $json, $index, $name ) = @$case;
		fresh();
		route( $SEARCH, %{ $page->($json) } );
		( $ok, $err ) = api( siteConfig => [] );
		($config) = one_ok( $ok, $err, $name );
		is( $config->{algolia} ? $config->{algolia}->{indexName} : undef, $index, "$name: " . ( $index || 'no config' ) );
	}
};

subtest 'siteConfig: no Algolia config -> success with algolia undef, and nextData still works' => sub {
	fresh();
	route( $SEARCH, file => 'foundation/listen-search-no-algolia.html', headers => $HTML_TYPE );
	route( data_url( $BUILD, $SCIENCE ), file => 'foundation/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );

	my ( $ok, $err ) = api( siteConfig => [] );
	my ($config) = one_ok( $ok, $err, 'no Algolia config' );
	is_deeply( $config, { buildId => $BUILD, algolia => undef }, 'buildId, algolia undef' );

	( $ok, $err ) = api( nextData => [$SCIENCE] );
	my ($props) = one_ok( $ok, $err, 'nextData' );
	is( $props->{programCollectionPrepared}->{id}, '2885458', 'nextData works without Algolia config' );
};

subtest 'siteConfig: no buildId -> LOAD_FAILED, or the last-good config (stale)' => sub {
	fresh();
	route( $SEARCH, file => 'foundation/listen-search-no-buildid.html', headers => $HTML_TYPE );
	my ( $ok, $err ) = api( siteConfig => [] );
	my $e = one_err( $ok, $err, 'no buildId, no last-good', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/No buildId/, 'message' );

	fresh();
	route_seq( $SEARCH, search_page(), { file => 'foundation/listen-search-no-buildid.html', headers => $HTML_TYPE } );
	api( siteConfig => [] );
	( $ok, $err ) = api( siteConfig => [], { force => 1 } );
	my ( $config, $info ) = one_ok( $ok, $err, 'no buildId with a last-good config' );
	is( $config->{buildId}, $BUILD, 'the last-good config' );
	is( $info->{stale}, 1, 'stale' );
	is( scalar requests(), 2, 'force made a request' );

	fresh();
	route_seq( $SEARCH, search_page(), { code => 500 } );
	api( siteConfig => [] );
	( $ok, $err ) = api( siteConfig => [], { force => 1 } );
	( $config, $info ) = one_ok( $ok, $err, 'HTTP 500 with a last-good config' );
	is( $info->{stale}, 1, 'HTTP 500: stale' );

	fresh();
	route( $SEARCH, code => 500 );
	( $ok, $err ) = api( siteConfig => [] );
	one_err( $ok, $err, 'HTTP 500 without a last-good config', $LOAD_FAILED, 500 );
};

subtest 'siteConfig: 6 h TTL (fake clock), force, and concurrent callers -> one request' => sub {
	fresh();
	serve_search();

	api( siteConfig => [] );
	advanceTime( 6 * 3600 - 1 );
	my ( $ok, $err ) = api( siteConfig => [], { ttl => 1 } );
	one_ok( $ok, $err, 'at 6 h - 1 s' );
	is( scalar requests(), 1, 'within 6 h: no request (opts ttl ignored)' );

	( $ok, $err ) = api( siteConfig => [], { force => 1 } );
	one_ok( $ok, $err, 'force' );
	is( scalar requests(), 2, 'force: a request despite the cache' );

	advanceTime( 6 * 3600 );
	api( siteConfig => [] );
	is( scalar requests(), 3, 'after 6 h: a request' );

	fresh();
	route( $SEARCH, %{ search_page() }, defer => 1 );
	my @callers = map { [ api( siteConfig => [], $_ ) ] } undef, undef, { force => 1 };
	is( scalar requests(), 1, 'three concurrent callers (one with force): one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( @$_, 'concurrent caller' ) for @callers;
};

# ---------------------------------------------------------------------------
# nextData
# ---------------------------------------------------------------------------

subtest 'nextData: path forms, data URL, pageProps' => sub {
	fresh();
	serve_search();
	route( qr{^\Q$SITE/_next/data/$BUILD/\E}, file => 'foundation/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );

	my ( $ok, $err ) = api( nextData => [$SCIENCE] );
	my ($props) = one_ok( $ok, $err, 'first call' );
	is_deeply( [ urls() ], [ $SEARCH, data_url( $BUILD, $SCIENCE ) ], 'discovers the buildId, then GET the page data' );
	is_deeply( $props, json_file('nextdata-program-scienceshow.trimmed.json')->{pageProps}, 'returns pageProps' );

	for my $form ( $SCIENCE, "$SCIENCE/", "$SITE$SCIENCE/", "https://abc.net.au$SCIENCE?x=1#y", "http://www.abc.net.au$SCIENCE" ) {
		clear_requests();
		( $ok, $err ) = api( nextData => [$form] );
		one_ok( $ok, $err, $form );
		is_deeply( [ urls() ], [ data_url( $BUILD, $SCIENCE ) ], "$form -> $SCIENCE.json" );
	}

	for my $path ( '/listen', '/kidslisten', '/listen/news', '/listen/audiobooks', '/news/2026-10-19/work-begins/107282192' ) {
		clear_requests();
		( $ok, $err ) = api( nextData => [$path] );
		one_ok( $ok, $err, $path );
		is_deeply( [ urls() ], [ data_url( $BUILD, $path ) ], "$path: any page path" );
	}

	clear_requests();
	api( nextData => ["$SITE/"] );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/index' ) ], 'the home page is /index.json' );

	for my $bad ( undef, '', 'listen/programs', 'https://example.com/listen', 'https://iview.abc.net.au/x' ) {
		clear_requests();
		( $ok, $err ) = api( nextData => [$bad] );
		is( $err->count, 1, 'invalid path: error callback before nextData() returned' );
		one_err( $ok, $err, 'nextData(' . ( defined $bad ? "'$bad'" : 'undef' ) . ')', $LOAD_FAILED, undef );
		is( scalar requests(), 0, 'no request' );
	}
};

subtest 'nextData: the cache key is the path, not the buildId' => sub {
	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( data_url( $BUILD, '/listen/news' ), file => 'foundation/nextdata-section-news.trimmed.json', headers => $JSON_TYPE );
	prime();

	my ( $ok, $err ) = api( nextData => ['/listen/news'], { ttl => 600 } );
	my ($props) = one_ok( $ok, $err, 'news page' );
	is( $props->{data}->{title}, 'News', 'news section pageProps' );

	( $ok, $err ) = api( siteConfig => [], { force => 1 } );
	my ($config) = one_ok( $ok, $err, 'forced refresh' );
	is( $config->{buildId}, $NEW_BUILD, 'the buildId changed' );
	clear_requests();

	( $ok, $err ) = api( nextData => ["$SITE/listen/news/"], { ttl => 600 } );
	one_ok( $ok, $err, 'after a new buildId' );
	is( scalar requests(), 0, 'cache hit across buildIds (no request)' );
};

subtest 'nextData: 404 -> refresh -> new buildId -> retry, in exactly 3 requests' => sub {
	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( data_url( $BUILD, $SCIENCE ), code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
	route( data_url( $NEW_BUILD, $SCIENCE ), file => 'foundation/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	prime();
	advanceTime(3600);

	my ( $ok, $err ) = api( nextData => [$SCIENCE] );
	my ( $props, $info ) = one_ok( $ok, $err, 'stale buildId' );
	is( $props->{programCollectionPrepared}->{id}, '2885458', 'the retried page' );
	is( $info->{stale}, 0, 'not stale' );
	is_deeply( [ urls() ], [ data_url( $BUILD, $SCIENCE ), $SEARCH, data_url( $NEW_BUILD, $SCIENCE ) ], 'data, search page, data' );

	clear_requests();
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	one_ok( $ok, $err, 'next call' );
	is_deeply( [ urls() ], [ data_url( $NEW_BUILD, $SCIENCE ) ], 'the next call uses the new buildId' );
};

subtest 'nextData: same buildId after the refresh -> LOAD_FAILED 404; refreshes limited to one per 60 s' => sub {
	fresh();
	serve_search();
	route( qr{^\Q$SITE/_next/data/\E}, code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
	prime();
	advanceTime(3600);

	my ( $ok, $err ) = api( nextData => ['/listen/programs/nope'] );
	my $e = one_err( $ok, $err, 'missing page', $LOAD_FAILED, 404 );
	like( $e->{message}, qr/404 Not Found.*buildId $BUILD: refreshed/, 'message: 404, buildId unchanged after the refresh' );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/listen/programs/nope' ), $SEARCH ], 'data, search page; no retry' );

	clear_requests();
	advanceTime(59);
	( $ok, $err ) = api( nextData => ['/listen/programs/other'] );
	$e = one_err( $ok, $err, 'second 404 within 60 s', $LOAD_FAILED, 404 );
	like( $e->{message}, qr/less than 60 s ago/, 'message: refresh limited' );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/listen/programs/other' ) ], 'no new discovery' );

	clear_requests();
	advanceTime(1);
	( $ok, $err ) = api( nextData => ['/listen/programs/other'] );
	one_err( $ok, $err, '404 60 s after the refresh', $LOAD_FAILED, 404 );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/listen/programs/other' ), $SEARCH ], 'after 60 s: discovery again' );
};

subtest 'nextData: the refresh fails, a retry 404s, a 500, non-JSON pages' => sub {
	fresh();
	route_seq( $SEARCH, search_page(), { code => 500 } );
	route( qr{^\Q$SITE/_next/data/\E}, code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
	prime();
	advanceTime(3600);
	my ( $ok, $err ) = api( nextData => [$SCIENCE] );
	my $e = one_err( $ok, $err, 'refresh fails', $LOAD_FAILED, 404 );
	like( $e->{message}, qr/refresh failed/, 'message: refresh failed' );
	is( scalar requests(), 2, 'data, search page' );

	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( qr{^\Q$SITE/_next/data/\E}, code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
	prime();
	advanceTime(3600);
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	one_err( $ok, $err, 'new buildId still 404', $LOAD_FAILED, 404 );
	is_deeply( [ urls() ], [ data_url( $BUILD, $SCIENCE ), $SEARCH, data_url( $NEW_BUILD, $SCIENCE ) ], 'retried once only' );

	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( qr{^\Q$SITE/_next/data/\E}, code => 500 );
	prime();
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	one_err( $ok, $err, 'HTTP 500', $LOAD_FAILED, 500 );
	is( scalar requests(), 1, 'HTTP 500: no refresh' );

	# non-JSON 200 (HTML) is a stale buildId too
	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( data_url( $BUILD, $SCIENCE ), file => 'foundation/html-page-200.html', headers => $HTML_TYPE );
	route( data_url( $NEW_BUILD, $SCIENCE ), file => 'foundation/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	prime();
	advanceTime(3600);
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	one_ok( $ok, $err, 'HTML 200 -> refresh -> retry' );
	is_deeply( [ urls() ], [ data_url( $BUILD, $SCIENCE ), $SEARCH, data_url( $NEW_BUILD, $SCIENCE ) ], 'HTML: data, search page, data' );

	fresh();
	serve_search();
	route( qr{^\Q$SITE/_next/data/\E}, file => 'foundation/html-page-200.html', headers => $HTML_TYPE );
	prime();
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	$e = one_err( $ok, $err, 'HTML 200 and the same buildId', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/Invalid JSON/, 'message: not JSON' );

	fresh();
	serve_search();
	route( qr{^\Q$SITE/_next/data/\E}, content => '{"notFound":true}', headers => $JSON_TYPE );
	prime();
	( $ok, $err ) = api( nextData => [$SCIENCE] );
	one_err( $ok, $err, 'JSON without pageProps', $LOAD_FAILED, 200 );
	is( scalar requests(), 1, 'no pageProps: no refresh' );
};

subtest 'nextData: two pages 404 at once -> one discovery, both retried' => sub {
	fresh();
	serve_search( {}, { buildId => $NEW_BUILD } );
	route( qr{^\Q$SITE/_next/data/$BUILD/\E}, code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE, defer => 1 );
	route( qr{^\Q$SITE/_next/data/$NEW_BUILD/\E}, file => 'foundation/nextdata-section-news.trimmed.json', headers => $JSON_TYPE );
	prime();
	advanceTime(3600);

	my @a = api( nextData => ['/listen/news'] );
	my @b = api( nextData => ['/listen/sport'] );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( @a, 'first page' );
	one_ok( @b, 'second page' );
	is( scalar( grep { $_ eq $SEARCH } urls() ), 1, 'one search page request' );
	is( scalar requests(), 5, '2 stale data requests, 1 discovery, 2 retries' );
};

subtest 'nextData: __N_REDIRECT (relative, absolute, 2 hops, 3rd hop, loop, off-site)' => sub {
	my $from = '/listen/programs/scienceshow/x/107266790';
	my $redirect = sub { { content => qq({"pageProps":{"__N_REDIRECT":"$_[0]","__N_REDIRECT_STATUS":308},"__N_SSP":true}), headers => $JSON_TYPE } };

	for my $kind (qw(relative absolute)) {
		fresh();
		serve_search();
		route( data_url( $BUILD, $from ), file => "foundation/nextdata-redirect-$kind.json", headers => $JSON_TYPE );
		route( data_url( $BUILD, $EPISODE ), file => 'foundation/nextdata-episode-scienceshow-mp3.trimmed.json', headers => $JSON_TYPE );
		prime();
		my ( $ok, $err ) = api( nextData => [$from] );
		my ($props) = one_ok( $ok, $err, "$kind redirect" );
		is( $props->{data}->{documentProps}->{id}, '107266790', "$kind: the target's pageProps" );
		is_deeply( [ urls() ], [ data_url( $BUILD, $from ), data_url( $BUILD, $EPISODE ) ], "$kind: followed" );
	}

	# two hops are fine (one of them relative to the current page), a third is not
	fresh();
	serve_search();
	route( data_url( $BUILD, '/listen/a' ),      %{ $redirect->('/listen/hop/b') } );
	route( data_url( $BUILD, '/listen/hop/b' ),  %{ $redirect->('c') } );
	route( data_url( $BUILD, '/listen/hop/c' ),  file => 'foundation/nextdata-episode-scienceshow-mp3.trimmed.json', headers => $JSON_TYPE );
	route( data_url( $BUILD, '/listen/three' ),  %{ $redirect->('/listen/a') } );
	prime();
	my ( $ok, $err ) = api( nextData => ['/listen/a'], { ttl => 600 } );
	one_ok( $ok, $err, '2 hops' );
	is( scalar requests(), 3, '2 hops: 3 requests' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/a'], { ttl => 600 } );
	one_ok( $ok, $err, 'redirecting path again' );
	( $ok, $err ) = api( nextData => ['/listen/hop/c'], { ttl => 600 } );
	one_ok( $ok, $err, 'final path' );
	is( scalar requests(), 0, 'cached under the final path and the path asked for' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/three'] );
	my $e = one_err( $ok, $err, '3rd hop', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/Too many redirects/, '3rd hop: message' );
	is( scalar requests(), 3, '3rd hop: the 4th page is not fetched' );

	fresh();
	serve_search();
	route( data_url( $BUILD, '/listen/programs/loop-a' ), file => 'foundation/nextdata-redirect-loop-a.json', headers => $JSON_TYPE );
	route( data_url( $BUILD, '/listen/programs/loop-b' ), file => 'foundation/nextdata-redirect-loop-b.json', headers => $JSON_TYPE );
	route( data_url( $BUILD, '/listen/off' ), %{ $redirect->('https://www.example.com/listen') } );
	prime();
	( $ok, $err ) = api( nextData => ['/listen/programs/loop-a'] );
	$e = one_err( $ok, $err, 'A -> B -> A', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/Redirect loop/, 'loop: message' );
	is( scalar requests(), 2, 'loop: 2 requests' );

	( $ok, $err ) = api( nextData => ['/listen/off'] );
	$e = one_err( $ok, $err, 'off-site redirect', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/off the ABC site/, 'off-site: message' );
};

# ---------------------------------------------------------------------------
# F4: page paths that ABC only serves after a redirect LMS can't follow
# ---------------------------------------------------------------------------

my $NONASCII_ID    = '107267360';
my $NONASCII_UPPER = "/listen/programs/if-youre-listening/the-apocalyptic-el-ni%C3%B1o-we-didn-t-see-coming/$NONASCII_ID";
my $NONASCII       = "/listen/programs/if-youre-listening/the-apocalyptic-el-ni%c3%b1o-we-didn-t-see-coming/$NONASCII_ID";
my $NONASCII_DOC   = 'ondemand/nextdata-episode-nonascii-107267360.trimmed.json';

# The _next/data routes as ABC answers them (measured 2026-10-19): a path that isn't all lower-case
# (an upper-case letter or %XX escape) gets a 307 whose only pointer is an x-nextjs-redirect header
# to the lower-case path, with no Location. LMS's Async::HTTP fails that with "Redirection without
# location". A lower-case path serves %pages (path => response; file => fixture), else a small page.
sub serve_like_abc {
	my %pages = @_;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{^\Q$SITE/_next/data/$BUILD/\E}, sub {
		my ($path) = $_[0] =~ m{^\Q$SITE/_next/data/$BUILD\E(/.*)\.json\z};
		return { error => 'Redirection without location' } if $path ne lc $path;

		my $page = $pages{$path} or return { content => qq({"pageProps":{"page":"$path"}}), headers => $JSON_TYPE };
		my %response = ( headers => $JSON_TYPE, %$page );
		$response{content} = fixture( delete $response{file} ) if $response{file};
		return \%response;
	} );
}

sub n_redirect { { content => qq({"pageProps":{"__N_REDIRECT":"$_[0]","__N_REDIRECT_STATUS":308},"__N_SSP":true}) } }

subtest 'nextData (F4): the path is requested lower-case, escapes lower-case, non-ASCII %-encoded as UTF-8' => sub {
	my @cases = (
		[ 'upper-case escapes (as ABC links the page)', $NONASCII_UPPER,                                                  $NONASCII ],
		[ 'mixed-case escape %c3%B1',                   '/listen/programs/if-youre-listening/the-apocalyptic-el-ni%c3%B1o-we-didn-t-see-coming/107267360', $NONASCII ],
		[ 'mixed-case escape %C3%b1',                   '/listen/programs/if-youre-listening/the-apocalyptic-el-ni%C3%b1o-we-didn-t-see-coming/107267360', $NONASCII ],
		[ 'a raw non-ASCII character',                  '/listen/programs/if-youre-listening/the-apocalyptic-el-niño-we-didn-t-see-coming/107267360',      $NONASCII ],
		[ 'an absolute URL with a trailing /',          "$SITE$NONASCII_UPPER/",                                          $NONASCII ],
		[ 'upper-case letters (ABC lower-cases them too)', '/listen/programs/If-Youre-Listening/The-Apocalyptic-El-Ni%C3%B1o-we-didn-t-see-coming/107267360', $NONASCII ],
		[ 'already lower-case: unchanged',              $NONASCII,                                                        $NONASCII ],
		[ 'ASCII only: unchanged',                      $SCIENCE,                                                         $SCIENCE ],
		[ 'several non-ASCII characters',               '/listen/programs/x/café-über-niño/1',                            '/listen/programs/x/caf%c3%a9-%c3%bcber-ni%c3%b1o/1' ],
		[ 'several escapes, mixed case',                '/listen/programs/x/CAF%C3%A9-%c3%BCber-ni%C3%b1o/1',             '/listen/programs/x/caf%c3%a9-%c3%bcber-ni%c3%b1o/1' ],
		[ 'a character outside the BMP',                '/listen/programs/x/a-🎧-b/1',                                    '/listen/programs/x/a-%f0%9f%8e%a7-b/1' ],
		[ '+ kept, a space encoded, %2B lower-cased',   '/listen/programs/x/a+b c%2Bd/1',                                 '/listen/programs/x/a+b%20c%2bd/1' ],
		[ 'path characters kept, others encoded',       q{/listen/programs/x/a:b@c!$&'()*,;=-._~d"e<f>g`h/1},             q{/listen/programs/x/a:b@c!$&'()*,;=-._~d%22e%3cf%3eg%60h/1} ],
	);

	for my $case (@cases) {
		my ( $name, $asked, $requested ) = @$case;
		fresh();
		serve_search();
		serve_like_abc( $NONASCII => { file => $NONASCII_DOC } );
		prime();

		my ( $ok, $err ) = api( nextData => [$asked] );
		my ($props) = one_ok( $ok, $err, $name );
		is_deeply( [ urls() ], [ data_url( $BUILD, $requested ) ], "$name: requested $requested" );

		if ( $requested eq $NONASCII ) {
			is( $props->{data}->{documentProps}->{id}, $NONASCII_ID, "$name: the episode document" );
		}
		else {
			is( $props->{page}, $requested, "$name: the page" );
		}
	}

	# one cache entry for every spelling of a page
	fresh();
	serve_search();
	serve_like_abc( $NONASCII => { file => $NONASCII_DOC } );
	prime();
	my ( $ok, $err ) = api( nextData => [$NONASCII_UPPER], { ttl => 600 } );
	one_ok( $ok, $err, 'upper-case escapes, ttl 600' );
	clear_requests();
	for my $spelling ( $NONASCII, "$SITE/listen/programs/if-youre-listening/the-apocalyptic-el-niño-we-didn-t-see-coming/107267360" ) {
		( $ok, $err ) = api( nextData => [$spelling], { ttl => 600 } );
		one_ok( $ok, $err, "then $spelling" );
	}
	is( scalar requests(), 0, 'other spellings of the same page: cache hits, no request' );
};

subtest 'nextData (F4): __N_REDIRECT to an upper-case-escaped path (recorded generic path of 107267360) is followed lower-case' => sub {
	my $generic = "/listen/programs/x/x/$NONASCII_ID";

	fresh();
	serve_search();
	serve_like_abc( $generic => { file => 'ondemand/nextdata-generic-107267360.json' }, $NONASCII => { file => $NONASCII_DOC } );
	prime();

	my ( $ok, $err ) = api( nextData => [$generic], { ttl => 600 } );
	my ($props) = one_ok( $ok, $err, 'generic path' );
	is( $props->{data}->{documentProps}->{id}, $NONASCII_ID, 'the episode document' );
	is_deeply( [ urls() ], [ data_url( $BUILD, $generic ), data_url( $BUILD, $NONASCII ) ], 'the generic path, then the redirect target lower-case' );

	clear_requests();
	( $ok, $err ) = api( nextData => [$NONASCII_UPPER], { ttl => 600 } );
	one_ok( $ok, $err, 'the target as ABC links it' );
	is( scalar requests(), 0, 'cached under the lower-case target' );
};

subtest 'nextData (F4): a 307 that LMS cannot follow (x-nextjs-redirect only, no Location) -> one LOAD_FAILED, no refresh, no retry' => sub {
	# HTTP.pm hands its error callback the message and the SimpleAsyncHTTP object only: LMS passes
	# the 307 response as a third argument, which HTTP.pm drops, and SimpleAsyncHTTP fills in
	# headers only on success. So x-nextjs-redirect can't be read; a 307 that remains (to another
	# page, say) is an error. Episode.pm falls back to the id-based lookup for episodes.
	fresh();
	serve_search();
	route( data_url( $BUILD, '/listen/programs/renamed/some-episode/1' ), error => 'Redirection without location' );
	prime();

	my ( $ok, $err ) = api( nextData => ['/listen/programs/renamed/some-episode/1'] );
	my $e = one_err( $ok, $err, '307 without Location', $LOAD_FAILED, undef );
	like( $e->{message}, qr/Redirection without location/, 'message: LMS\'s reason' );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/listen/programs/renamed/some-episode/1' ) ], 'one request: no buildId refresh, no retry' );
};

subtest 'nextData (F4): redirect loops and the 2-hop limit hold across spellings' => sub {
	fresh();
	serve_search();
	serve_like_abc(
		'/listen/programs/loop-%c3%a9'  => n_redirect('/listen/programs/b'),
		'/listen/programs/b'            => n_redirect('/listen/programs/LOOP-%C3%A9'),    # the first page, spelled differently
		'/listen/programs/self'         => n_redirect('/listen/programs/Self'),
		'/listen/programs/h%c3%a91'     => n_redirect('/listen/programs/H%C3%A92'),
		'/listen/programs/h%c3%a92'     => n_redirect('h%C3%A93'),                           # relative
		'/listen/programs/h%c3%a93'     => n_redirect('h%C3%A94'),                           # relative; h%c3%a94 is a page
		'/listen/programs/two-%c3%a9'   => n_redirect('/listen/programs/H%C3%A93'),
		'/listen/programs/off-%c3%a9'   => n_redirect('https://www.example.com/listen/programs/%C3%A9'),
	);
	prime();

	my ( $ok, $err ) = api( nextData => ['/listen/programs/loop-%C3%A9'] );
	my $e = one_err( $ok, $err, 'A -> B -> A (another spelling)', $LOAD_FAILED, 200 );
	like( $e->{message}, qr{Redirect loop: /listen/programs/loop-%c3%a9 -> /listen/programs/b -> /listen/programs/loop-%c3%a9}, 'loop: message, lower-case paths' );
	is( scalar requests(), 2, 'loop: 2 requests' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/programs/self'] );
	$e = one_err( $ok, $err, 'a page redirecting to its own upper-case spelling', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/Redirect loop/, 'self: a loop' );
	is( scalar requests(), 1, 'self: 1 request' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/programs/two-%C3%A9'] );
	my ($props) = one_ok( $ok, $err, '2 hops with escapes' );
	is( $props->{page}, '/listen/programs/h%c3%a94', '2 hops (one relative): the target' );
	is_deeply( [ urls() ], [ map { data_url( $BUILD, $_ ) } qw(/listen/programs/two-%c3%a9 /listen/programs/h%c3%a93 /listen/programs/h%c3%a94) ], '2 hops: every request lower-case' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/programs/H%C3%A91'] );
	$e = one_err( $ok, $err, '3rd hop with escapes', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/Too many redirects/, '3rd hop: message' );
	is( scalar requests(), 3, '3rd hop: the 4th page is not fetched' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/listen/programs/off-%C3%A9'] );
	$e = one_err( $ok, $err, 'off-site with escapes', $LOAD_FAILED, 200 );
	like( $e->{message}, qr/off the ABC site/, 'off-site: message' );
	is( scalar requests(), 1, 'off-site: not followed' );
};

# Legacy program paths (Algolia's canonicalURL, e.g. /radionational/programs/futuretense) answer
# HTTP 308 with a Location to the /listen page, recorded 2026-10-19:
#   GET /_next/data/build-3afcd04f/radionational/programs/futuretense.json
#   -> 308, location: /listen/programs/futuretense, refresh: 0;url=/listen/programs/futuretense,
#      body "/listen/programs/futuretense" (28 bytes, not JSON)
#   GET /_next/data/build-3afcd04f/radionational/programs/futuretense/el-ni%C3%B1o/1.json
#   -> 308, location: /listen/programs/futuretense/el-ni%C3%B1o/1 (escapes kept as asked)
# LMS's Async::HTTP follows 301/302/303/307 with a Location but not 308: it reaches HTTP.pm as a
# response whose body isn't JSON, with its code and headers.
sub http_redirect {
	my ( $code, %headers ) = @_;
	my $target = $headers{Location} || $headers{'x-nextjs-redirect'} || '';
	return { code => $code, headers => { %headers, ( $headers{Location} ? ( Refresh => "0;url=$target" ) : () ) }, content => $target };
}

subtest 'nextData (F4): HTTP 308 (legacy /radionational/programs/... paths; LMS does not follow 308) -> Location followed' => sub {
	my $legacy = '/radionational/programs/futuretense';
	my $page   = '/listen/programs/futuretense';

	fresh();
	serve_search();
	serve_like_abc(
		$legacy                                       => http_redirect( 308, Location => $page ),
		'/radionational/programs/futuretense/el-ni%c3%b1o/1' => http_redirect( 308, Location => '/listen/programs/futuretense/el-ni%C3%B1o/1' ),
		'/radionational/programs/nextjs-only'         => http_redirect( 308, 'x-nextjs-redirect' => '/listen/programs/nextjs-only' ),
		'/radionational/programs/relative'            => http_redirect( 308, Location => 'futuretense' ),
	);
	prime();

	my ( $ok, $err ) = api( nextData => [$legacy], { ttl => 600 } );
	my ( $props, $info ) = one_ok( $ok, $err, 'legacy program path' );
	is( $props->{page}, $page, 'the /listen page' );
	is( $info->{stale}, 0, 'not stale' );
	is_deeply( [ urls() ], [ data_url( $BUILD, $legacy ), data_url( $BUILD, $page ) ], 'the legacy path, then the Location: no buildId refresh' );
	is( scalar( grep { $_->{level} eq 'WARN' } log_messages() ), 0, 'no WARN' );

	clear_requests();
	for my $path ( $legacy, $page ) {
		( $ok, $err ) = api( nextData => [$path], { ttl => 600 } );
		one_ok( $ok, $err, "again: $path" );
	}
	is( scalar requests(), 0, 'cached under the legacy path and the target' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/futuretense/el-ni%C3%B1o/1'] );
	($props) = one_ok( $ok, $err, '308 to a path with upper-case escapes' );
	is_deeply(
		[ urls() ],
		[ data_url( $BUILD, '/radionational/programs/futuretense/el-ni%c3%b1o/1' ), data_url( $BUILD, '/listen/programs/futuretense/el-ni%c3%b1o/1' ) ],
		'both requested lower-case'
	);

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/nextjs-only'] );
	($props) = one_ok( $ok, $err, '308 with only x-nextjs-redirect' );
	is( $props->{page}, '/listen/programs/nextjs-only', 'x-nextjs-redirect followed when the response reaches us' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/relative'] );
	($props) = one_ok( $ok, $err, '308 to a relative Location' );
	is( $props->{page}, $page, 'relative to the page (/radionational/programs/futuretense), then its 308 to the /listen page' );
	is( scalar requests(), 3, 'relative Location, then a second 308: 3 requests (2 hops)' );
};

subtest 'nextData (F4): HTTP 308 shares the loop, 2-hop, off-site rules with __N_REDIRECT; no target -> as before' => sub {
	fresh();
	serve_search();
	serve_like_abc(
		'/radionational/programs/a'    => http_redirect( 308, Location => '/listen/programs/b' ),
		'/listen/programs/b'           => n_redirect('/radionational/programs/A'),    # back to the first page
		'/radionational/programs/self' => http_redirect( 308, Location => '/radionational/programs/Self' ),
		'/radionational/programs/h1'   => http_redirect( 308, Location => '/listen/programs/h2' ),
		'/listen/programs/h2'          => n_redirect('/radionational/programs/h3'),
		'/radionational/programs/h3'   => http_redirect( 308, Location => '/listen/programs/h4' ),
		'/radionational/programs/off'  => http_redirect( 308, Location => 'https://www.example.com/listen/programs/off' ),
		'/radionational/programs/none' => { code => 308, content => '' },
	);
	prime();

	my ( $ok, $err ) = api( nextData => ['/radionational/programs/a'] );
	my $e = one_err( $ok, $err, '308 A -> __N_REDIRECT B -> A', $LOAD_FAILED, 200 );
	like( $e->{message}, qr{Redirect loop: /radionational/programs/a -> /listen/programs/b -> /radionational/programs/a}, 'mixed loop: message' );
	is( scalar requests(), 2, 'mixed loop: 2 requests' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/self'] );
	$e = one_err( $ok, $err, '308 to its own upper-case spelling', $LOAD_FAILED, 308 );
	like( $e->{message}, qr/Redirect loop/, '308 self: a loop' );
	is( scalar requests(), 1, '308 self: 1 request' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/h1'] );
	$e = one_err( $ok, $err, '308, __N_REDIRECT, 308: a 3rd hop', $LOAD_FAILED, 308 );
	like( $e->{message}, qr/Too many redirects/, '3rd hop: message' );
	is( scalar requests(), 3, '3rd hop: the 4th page is not fetched' );

	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/off'] );
	$e = one_err( $ok, $err, '308 off the site', $LOAD_FAILED, 308 );
	like( $e->{message}, qr/off the ABC site/, '308 off-site: message' );
	is( scalar requests(), 1, '308 off-site: not followed' );

	# a 308 without Location or x-nextjs-redirect is a page that isn't JSON, as before (buildId check)
	clear_requests();
	( $ok, $err ) = api( nextData => ['/radionational/programs/none'] );
	one_err( $ok, $err, '308 without a target', $LOAD_FAILED, 308 );
	is_deeply( [ urls() ], [ data_url( $BUILD, '/radionational/programs/none' ), $SEARCH ], '308 without a target: the buildId check, no retry (same buildId)' );
};

# ---------------------------------------------------------------------------
# algolia
# ---------------------------------------------------------------------------

my %QUERY = ( query => 'science', hitsPerPage => 20, filters => 'siteTitle:"Listen" AND (contentType:program OR contentType:audioepisode)' );

sub algolia_setup {
	fresh();
	serve_search(@_);
	route( $ALGOLIA, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE );
	prime();
}

subtest 'algolia: request URL, headers and body from the discovered config' => sub {
	algolia_setup();

	my ( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	my ( $data, $info ) = one_ok( $ok, $err, 'query' );
	is_deeply( $data, json_file('algolia-listen_prod_all-query.json'), 'the decoded response' );
	is_deeply( $info, { stale => 0 }, 'not stale' );

	my ($req) = requests();
	is( $req->{method}, 'POST', 'POST' );
	is( $req->{url}, $ALGOLIA, 'https://<appId>-dsn.algolia.net/1/indexes/<indexName>/query' );
	is( $req->{headers}->header('X-Algolia-Application-Id'), 'TESTAPPID',     'X-Algolia-Application-Id' );
	is( $req->{headers}->header('X-Algolia-API-Key'),        'testsearchkey', 'X-Algolia-API-Key' );
	is( $req->{headers}->header('Content-Type'),             'application/json', 'Content-Type: application/json' );
	is( $req->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), 'User-Agent' );
	is_deeply( JSON::PP::decode_json( $req->{body} ), \%QUERY, 'body = JSON of the params' );

	fresh();
	route( $SEARCH, file => 'foundation/listen-search.trimmed.html', headers => $HTML_TYPE );
	route( $ALGOLIA, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE );
	( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	one_ok( $ok, $err, 'cold start' );
	is_deeply( [ urls() ], [ $SEARCH, $ALGOLIA ], 'cold start: discovers the config first' );
};

subtest 'algolia: cached by canonical params (default 3600 s), ttl override' => sub {
	algolia_setup();

	api( algolia => [ { query => 'x', hitsPerPage => 5, facets => ['*'], nested => { b => 1, a => 2 } } ] );
	my $params = { nested => { a => 2, b => 1 } };
	$params->{facets} = ['*'];
	$params->{hitsPerPage} = 5;
	$params->{query} = 'x';
	my ( $ok, $err ) = api( algolia => [$params] );
	one_ok( $ok, $err, 'same params, built in another order' );
	is( scalar requests(), 1, 'same canonical params: cache hit' );

	api( algolia => [ { query => 'x', hitsPerPage => 6, facets => ['*'], nested => { b => 1, a => 2 } } ] );
	is( scalar requests(), 2, 'different params: a request' );

	advanceTime(3599);
	api( algolia => [$params] );
	is( scalar requests(), 2, 'within 3600 s: cached' );
	advanceTime(1);
	api( algolia => [$params] );
	is( scalar requests(), 3, 'after 3600 s: a request' );

	api( algolia => [$params], { ttl => 0 } );
	is( scalar requests(), 4, 'ttl 0: no cache' );
	advanceTime(30);
	api( algolia => [$params], { ttl => 10 } );
	is( scalar requests(), 5, 'ttl 10 at age 30 s: a request' );
};

subtest 'algolia: a non-ASCII query is sent as UTF-8 JSON with a stable cache key' => sub {
	algolia_setup();

	my ( $ok, $err ) = api( algolia => [ { query => 'Café', hitsPerPage => 1 } ] );
	one_ok( $ok, $err, 'Café' );
	my $body = ( requests() )[0]->{body};
	ok( !utf8::is_utf8($body), 'body is bytes' );
	like( $body, qr/Caf\xC3\xA9/, 'body has the UTF-8 bytes of é' );
	is( JSON::PP::decode_json($body)->{query}, 'Café', 'decodes back to Café' );

	( $ok, $err ) = api( algolia => [ { hitsPerPage => 1, query => "Caf\x{e9}" } ] );
	one_ok( $ok, $err, 'Café again' );
	is( scalar requests(), 1, 'same key: cache hit' );
};

subtest 'algolia: coalescing (identical bodies share, different bodies do not)' => sub {
	fresh();
	serve_search();
	route( $ALGOLIA, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE, defer => 1 );
	prime();

	my @a = api( algolia => [ { query => 'a' } ] );
	my @b = api( algolia => [ { query => 'a' } ] );
	my @c = api( algolia => [ { query => 'c' } ] );
	is( scalar requests(), 2, "two identical bodies + one other: 2 requests" );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( @$_, 'caller' ) for \@a, \@b, \@c;
	is_deeply( [ sort map { JSON::PP::decode_json( $_->{body} )->{query} } requests() ], [qw(a c)], 'bodies a and c' );
};

subtest 'algolia: rolling budget of 300 network queries per 60 min' => sub {
	fresh();
	serve_search();
	route( $ALGOLIA, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE, defer => 1 );
	prime();

	# a coalesced pair counts once
	my @pair = ( [ api( algolia => [ { query => 'q0' } ] ) ], [ api( algolia => [ { query => 'q0' } ] ) ] );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( @$_, 'coalesced q0' ) for @pair;

	for my $i ( 1 .. 299 ) {
		api( algolia => [ { query => "q$i" } ] );
	}
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar requests(), 300, '300 network queries sent' );

	my ( $ok, $err ) = api( algolia => [ { query => 'q300' } ] );
	my $e = one_err( $ok, $err, 'the 301st query', $RATE_LIMITED, undef );
	like( $e->{message}, qr/budget/, 'message: budget' );
	is( scalar requests(), 300, 'the 301st query: no request' );
	is( scalar Slim::Networking::SimpleAsyncHTTP->deferred, 0, 'nothing waiting either' );

	( $ok, $err ) = api( algolia => [ { query => 'q7' } ] );
	one_ok( $ok, $err, 'cached query while over budget' );
	is( scalar requests(), 300, 'cache hit: no request' );

	( $ok, $err ) = api( algolia => [ { query => 'q300' } ], { quiet => 1 } );
	one_err( $ok, $err, 'still over budget (quiet)', $RATE_LIMITED, undef );

	Slim::Utils::Cache->new('abclisten')->remove('api:siteConfig');
	( $ok, $err ) = api( algolia => [ { query => 'q300' } ] );
	one_err( $ok, $err, 'over budget, site config not cached', $RATE_LIMITED, undef );
	is( scalar requests(), 300, 'over budget: no request at all (not even the search page)' );

	advanceTime(3599);
	( $ok, $err ) = api( algolia => [ { query => 'q300' } ] );
	one_err( $ok, $err, 'at 59:59', $RATE_LIMITED, undef );

	advanceTime(1);
	( $ok, $err ) = api( algolia => [ { query => 'q300' } ] );
	is( scalar( grep { $_ eq $ALGOLIA } urls() ), 301, 'after the oldest query ages past 60 min: queries flow again' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	one_ok( $ok, $err, 'at 60:00' );
};

subtest 'algolia: 403/401 -> re-discover -> new key -> retry; twice -> LOAD_FAILED; unchanged key -> no retry' => sub {
	for my $code ( 403, 401 ) {
		fresh();
		serve_search( {}, { apiKey => 'newsearchkey' } );
		route_seq( $ALGOLIA, { code => $code, file => "foundation/algolia-$code.json", headers => $JSON_TYPE }, { file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE } );
		prime();

		my ( $ok, $err ) = api( algolia => [ {%QUERY} ] );
		my ($data) = one_ok( $ok, $err, "$code then OK" );
		is( $data->{nbHits}, 14875, "$code: the retried result" );
		is_deeply( [ urls() ], [ $ALGOLIA, $SEARCH, $ALGOLIA ], "$code: query, search page, query" );
		my @keys = map { $_->{headers}->header('X-Algolia-API-Key') } grep { $_->{url} eq $ALGOLIA } requests();
		is_deeply( \@keys, [qw(testsearchkey newsearchkey)], "$code: the retry carries the new key" );
	}

	fresh();
	serve_search( {}, { apiKey => 'newsearchkey' } );
	route( $ALGOLIA, code => 403, file => 'foundation/algolia-403.json', headers => $JSON_TYPE );
	prime();
	my ( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	my $e = one_err( $ok, $err, '403 twice', $LOAD_FAILED, 403 );
	is_deeply( [ urls() ], [ $ALGOLIA, $SEARCH, $ALGOLIA ], '403 twice: one retry only' );
	unlike( $e->{message}, qr/TESTAPPID/, 'error message has no app id' );

	fresh();
	serve_search();
	route( $ALGOLIA, code => 403, file => 'foundation/algolia-403.json', headers => $JSON_TYPE );
	prime();
	( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	$e = one_err( $ok, $err, '403 with an unchanged key', $LOAD_FAILED, 403 );
	like( $e->{message}, qr/refreshed/, 'message says the config was refreshed' );
	is_deeply( [ urls() ], [ $ALGOLIA, $SEARCH ], 'unchanged key: no retry' );

	clear_requests();
	( $ok, $err ) = api( algolia => [ { query => 'other' } ] );
	one_err( $ok, $err, 'another 403 within 60 s', $LOAD_FAILED, 403 );
	is_deeply( [ urls() ], [$ALGOLIA], 'within 60 s: no new discovery' );
};

subtest 'algolia: 429 -> RATE_LIMITED; no config or no site config -> LOAD_FAILED without a query' => sub {
	fresh();
	serve_search();
	route( $ALGOLIA, code => 429, file => 'foundation/algolia-429.json', headers => $JSON_TYPE );
	prime();
	my ( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	one_err( $ok, $err, '429', $RATE_LIMITED, 429 );
	is( scalar requests(), 1, '429: no retry' );

	fresh();
	route( $SEARCH, file => 'foundation/listen-search-no-algolia.html', headers => $HTML_TYPE );
	route( qr/algolia/, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE );
	( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	my $e = one_err( $ok, $err, 'no Algolia config', $LOAD_FAILED, undef );
	like( $e->{message}, qr/No Algolia search configuration/, 'message' );
	is_deeply( [ urls() ], [$SEARCH], 'no Algolia request' );

	fresh();
	route( $SEARCH, code => 500 );
	route( qr/algolia/, file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE );
	( $ok, $err ) = api( algolia => [ {%QUERY} ] );
	one_err( $ok, $err, 'site config unavailable', $LOAD_FAILED, 500 );
	is_deeply( [ urls() ], [$SEARCH], 'no Algolia request' );

	for my $bad ( undef, 'science', [ 'query', 'x' ] ) {
		fresh();
		( $ok, $err ) = api( algolia => [$bad] );
		one_err( $ok, $err, 'params ' . ( defined $bad ? ( ref $bad || "'$bad'" ) : 'undef' ), $LOAD_FAILED, undef );
		is( scalar requests(), 0, 'bad params: no request' );
	}
};

subtest 'algolia: the API key is never logged; API.pm never logs the app id' => sub {
	my $captured = '';
	{
		local $ENV{ABCLISTEN_TEST_LOG} = 1;
		open( my $saved, '>&', \*STDERR ) or die "dup STDERR: $!";
		close STDERR;
		open( STDERR, '>', \$captured ) or die "capture STDERR: $!";

		# success, 403 -> new key -> 403, 500, stale, budget refusal
		fresh();
		serve_search( {}, { apiKey => 'newsearchkey' } );
		route_seq( $ALGOLIA,
			{ file => 'foundation/algolia-listen_prod_all-query.json', headers => $JSON_TYPE },
			{ code => 403, file => 'foundation/algolia-403.json', headers => $JSON_TYPE },
			{ code => 403, file => 'foundation/algolia-403.json', headers => $JSON_TYPE },
			{ code => 500, content => 'oops' },
		);
		api( siteConfig => [] );
		api( algolia => [ { query => 'a' } ], { stale_ok => 1 } );
		api( algolia => [ { query => 'b' } ] );
		advanceTime(4000);
		api( algolia => [ { query => 'a' } ], { stale_ok => 1 } );
		api( algolia => [ { query => 'c' } ] );

		close STDERR;
		open( STDERR, '>&', $saved ) or die "restore STDERR: $!";
	}

	my @messages = log_messages();
	ok( scalar( grep { $_->{level} eq 'DEBUG' } @messages ), 'DEBUG lines were logged' );
	ok( length $captured, 'ABCLISTEN_TEST_LOG output captured' );
	unlike( $captured, qr/testsearchkey|newsearchkey/, 'no API key in the captured log' );
	ok( !( grep { $_->{message} =~ /searchkey/ } @messages ), 'no API key in any log message' );

	# HTTP.pm logs the request URL (whose host name is the app id); API.pm's own lines never do
	my @own = grep { $_->{message} !~ /\A(?:POST|GET) https:/ && $_->{message} !~ /\AHTTP request failed: / } @messages;
	ok( scalar @own, 'API.pm logged its own lines' );
	ok( !( grep { $_->{message} =~ /TESTAPPID/ } @own ), "no app id in API.pm's log lines" ) or diag explain [ map { $_->{message} } grep { $_->{message} =~ /TESTAPPID/ } @own ];
};

# ---------------------------------------------------------------------------
# exactly one callback on every path
# ---------------------------------------------------------------------------

subtest 'exactly one callback: the matrix' => sub {
	my %scenarios = (
		'success' => sub {
			algolia_setup();
			return ( 'ok', api( algolia => [ {%QUERY} ] ) );
		},
		'cache hit' => sub {
			algolia_setup();
			api( algolia => [ {%QUERY} ] );
			return ( 'ok', api( algolia => [ {%QUERY} ] ) );
		},
		'coalesced (second caller)' => sub {
			fresh();
			route( "$BFF/x", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE, defer => 1 );
			my @first = api( bff => [ 'x', undef ] );
			my @second = api( bff => [ 'x', undef ] );
			Slim::Networking::SimpleAsyncHTTP->completeDeferred;
			return ( 'ok', @second );
		},
		'stale' => sub {
			fresh();
			route_seq( "$BFF/x", { file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE }, { code => 500 } );
			api( bff => [ 'x', undef ], { stale_ok => 1 } );
			return ( 'ok', api( bff => [ 'x', undef ], { stale_ok => 1 } ) );
		},
		'budget refusal' => sub {
			algolia_setup();
			api( algolia => [ { query => "q$_" } ] ) for 1 .. 300;
			return ( 'err', api( algolia => [ { query => 'q301' } ] ) );
		},
		'rediscovery failure' => sub {
			fresh();
			route_seq( $SEARCH, search_page(), { error => 'Connect timed out' } );
			route( qr{_next/data}, code => 404 );
			prime();
			advanceTime(3600);
			return ( 'err', api( nextData => [$SCIENCE] ) );
		},
		'redirect overflow' => sub {
			fresh();
			serve_search();
			for my $i ( 1 .. 4 ) {
				route( data_url( $BUILD, "/listen/r$i" ), content => sprintf( '{"pageProps":{"__N_REDIRECT":"/listen/r%d"}}', $i + 1 ), headers => $JSON_TYPE );
			}
			prime();
			return ( 'err', api( nextData => ['/listen/r1'] ) );
		},
		'bad JSON' => sub {
			fresh();
			route( "$BFF/x", file => 'foundation/bad.json', headers => $JSON_TYPE );
			return ( 'err', api( bff => [ 'x', undef ] ) );
		},
		'transport error' => sub {
			fresh();
			route( "$BFF/x", error => 'Connect timed out: Connection refused' );
			return ( 'err', api( bff => [ 'x', undef ] ) );
		},
		'exception while processing a response (redirect)' => sub {
			fresh();
			serve_search();
			route( qr{_next/data}, file => 'foundation/nextdata-redirect-relative.json', headers => $JSON_TYPE );
			prime();
			no warnings 'redefine';
			local *Plugins::ABCListen::API::_redirectPath = sub { die "unexpected\n" };
			return ( 'err', api( nextData => ['/listen/programs/scienceshow/x/107266790'] ) );
		},
		'exception while processing a response (search page)' => sub {
			fresh();
			serve_search();
			no warnings 'redefine';
			local *Plugins::ABCListen::API::_parseSiteConfig = sub { die "parser bug\n" };
			return ( 'err', api( siteConfig => [] ) );
		},
		'exception while caching a response' => sub {
			fresh();
			route( "$BFF/x", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE );
			no warnings 'redefine';
			local *Slim::Utils::Cache::set = sub { die "disk full\n" };
			return ( 'ok', api( bff => [ 'x', undef ], { ttl => 60 } ) );
		},
		'exception while sending a request' => sub {
			fresh();
			no warnings 'redefine';
			local *Plugins::ABCListen::HTTP::getJSON = sub { die "socket bug\n" };
			return ( 'err', api( bff => [ 'x', undef ] ) );
		},
		'success callback dies' => sub {
			fresh();
			route( "$BFF/x", file => 'foundation/bff-collection-empty.json', headers => $JSON_TYPE );
			my ( $ok, $err ) = ( collector(), collector() );
			my $cb = $ok->cb;
			Plugins::ABCListen::API::bff( 'x', undef, sub { $cb->(@_); die "consumer bug\n" }, $err->cb );
			return ( 'ok', $ok, $err );
		},
	);

	for my $name ( sort keys %scenarios ) {
		my ( $which, $ok, $err ) = $scenarios{$name}->();
		is( $ok->count + $err->count, 1, "$name: exactly one callback" );
		is( ( $which eq 'ok' ? $ok : $err )->count, 1, "$name: the " . ( $which eq 'ok' ? 'success' : 'error' ) . ' callback' )
			or diag explain [ $ok->calls, $err->calls ];
	}
};

subtest 'API.pm makes every request through HTTP.pm; fixtures carry dummy Algolia credentials only' => sub {
	open( my $fh, '<', 'ABCListen/API.pm' ) or die "API.pm: $!";
	my $source = do { local $/; <$fh> };
	close $fh;
	unlike( $source, qr/SimpleAsyncHTTP|LWP|SimpleHTTP/, 'no SimpleAsyncHTTP, LWP or SimpleHTTP in API.pm' );

	my $html = fixture('foundation/listen-search.trimmed.html');
	my @clients = $html =~ /"client":\{"appId":"([^"]*)","apiKey":"([^"]*)"\}/g;
	is_deeply( \@clients, [qw(TESTAPPID testsearchkey TESTAPPID testsearchkey)], 'search page fixture: dummy app id and key' );
};

done_testing();
