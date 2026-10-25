#!/usr/bin/perl
# Plugins::ABCListen::HTTP: explicit non-libwww User-Agent on every request, 15 s default timeout,
# cache options passed through, JSON decoded whatever the Content-Type, form encoding, postJSON,
# the headers option, header values never logged, and exactly one callback per request on every
# path; F6: LMS's HTTP::Response as the error callback's third argument when there is one. All
# HTTP goes through the SimpleAsyncHTTP stub: no network.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use Encode ();
use JSON::PP ();

use Plugins::ABCListen::HTTP;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $EPG     = 'https://www.abc.net.au/core-next/api/epgNowPlaying/RN/now?imageRatio=1x1';
my $PLS     = 'https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls';
my $ALGOLIA = 'https://TESTAPP-dsn.algolia.net/1/indexes/test_index/query';
my $SECRET  = 'k3y-VALUE-never-logged-0123456789';
my $ALGOLIA_LOGGED = 'https://<algolia>-dsn.algolia.net/1/indexes/test_index/query';    # F10: as log lines and messages name it

# Run one request; return (success collector, error collector, recorded request).
sub run_request {
	my ( $call, $leading, $opts ) = @_;
	my $ok  = collector();
	my $err = collector();
	my $before = () = requests();

	no strict 'refs';
	&{"Plugins::ABCListen::HTTP::$call"}( @$leading, $ok->cb, $err->cb, $opts );

	my @requests = requests();
	return ( $ok, $err, @requests > $before ? $requests[-1] : undef );
}

sub exactly_one {
	my ( $ok, $err, $which, $name ) = @_;
	is( $ok->count + $err->count, 1, "$name: exactly one callback" );
	is( ( $which eq 'ok' ? $ok : $err )->count, 1, "$name: the " . ( $which eq 'ok' ? 'success' : 'error' ) . ' callback' );
}

sub plugin_messages { Slim::Utils::Log->messages( category => 'plugin.abclisten', @_ ) }

subtest 'getJSON: success served as text/plain, User-Agent, default timeout' => sub {
	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json', headers => { 'Content-Type' => 'text/plain; charset=utf-8' } );

	my ( $ok, $err, $req ) = run_request( getJSON => [$EPG], undef );
	exactly_one( $ok, $err, 'ok', 'epgNowPlaying' );

	my ( $data, $http ) = $ok->args(0);
	is( ref $data, 'HASH', 'decoded to a hash' );
	is( $data->{data}->{title}, 'The Radio National Hour', 'decoded the program title' );
	ok( $http && $http->can('headers'), 'second argument is the HTTP object' );

	is( $req->{method}, 'GET', 'GET request' );
	my $ua = $req->{headers}->header('User-Agent');
	ok( defined $ua && length $ua, 'User-Agent header is set explicitly' );
	is( $ua, Slim::Utils::Misc::userAgentString(), "User-Agent is LMS's user agent string" );
	unlike( $ua, qr/libwww/i, 'User-Agent is not libwww-perl' );
	is( $req->{params}->{timeout}, 15, 'default timeout is 15 s' );
	ok( !exists $req->{params}->{cache}, 'no caching unless asked' );
	is( $req->{body}, undef, 'no body on GET' );
};

subtest 'getJSON: JSON served as text/html is still decoded' => sub {
	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json', headers => { 'Content-Type' => 'text/html' } );

	my ( $ok, $err ) = run_request( getJSON => [$EPG], undef );
	exactly_one( $ok, $err, 'ok', 'text/html' );
	is( ( $ok->args(0) )[0]->{data}->{papiServiceId}, 'RN', 'decoded' );
};

subtest 'options: timeout, cache and expires are passed through' => sub {
	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json' );

	my ( $ok, $err, $req ) = run_request( getJSON => [$EPG], { timeout => 5, cache => 1, expires => 3600 } );
	exactly_one( $ok, $err, 'ok', 'with options' );
	is( $req->{params}->{timeout}, 5,    'custom timeout' );
	is( $req->{params}->{cache},   1,    'cache passed through' );
	is( $req->{params}->{expires}, 3600, 'expires passed through' );
	ok( !exists $req->{params}->{headers}, 'headers option is not a SimpleAsyncHTTP param' );
};

subtest 'getJSON: JSON with a byte-order mark and whitespace' => sub {
	resetStubs();
	route( 'https://example.test/bom', file => 'foundation/bom-whitespace.json', headers => { 'Content-Type' => 'text/html' } );

	my ( $ok, $err ) = run_request( getJSON => ['https://example.test/bom'], undef );
	exactly_one( $ok, $err, 'ok', 'BOM' );
	is_deeply( ( $ok->args(0) )[0], { ok => JSON::PP::true(), data => { title => 'Saturday Extra', serviceId => 'RN' } }, 'decoded despite BOM, CRLF and whitespace' );
};

subtest 'getJSON: top-level array with UTF-8 text, no Content-Type' => sub {
	resetStubs();
	route( 'https://example.test/programs', file => 'foundation/array-utf8.json', headers => {} );

	my ( $ok, $err ) = run_request( getJSON => ['https://example.test/programs'], undef );
	exactly_one( $ok, $err, 'ok', 'array' );
	my ($data) = $ok->args(0);
	is( ref $data, 'ARRAY', 'decoded to an array' );
	is( $data->[1]->{title}, 'Café Society – Música …', 'UTF-8 decoded to characters' );
};

subtest 'getJSON: error paths call only the error callback, with a readable message' => sub {
	my @cases = (
		[ 'HTTP 403',    { code => 403, file => 'foundation/error-page.html', headers => { 'Content-Type' => 'text/html' } }, qr/403 Forbidden/ ],
		[ 'HTTP 404',    { code => 404, content => 'Not Found' },                qr/404 Not Found/ ],
		[ 'HTTP 500',    { code => 500, content => 'oops' },                     qr/500 Internal Server Error/ ],
		[ 'timeout',     { error => 'Timed out waiting for data' },              qr/Timed out waiting for data/ ],
		[ 'transport',   { error => 'Connect timed out: Connection refused' },   qr/Connection refused/ ],
		[ 'empty body',  { code => 200, content => '' },                         qr/Empty response/ ],
		[ 'blank body',  { code => 200, content => " \r\n " },                   qr/Empty response/ ],
		[ 'HTML page',   { code => 200, file => 'foundation/error-page.html', headers => { 'Content-Type' => 'text/html' } }, qr/Invalid JSON/ ],
		[ 'truncated',   { code => 200, content => '{"data":{"title":"The Ra' },  qr/Invalid JSON/ ],
		[ 'JSON scalar', { code => 200, content => '"just a string"' },          qr/not an object or array/ ],
	);

	for my $case (@cases) {
		my ( $name, $response, $expected ) = @$case;
		resetStubs();
		route( $EPG, %$response );

		my ( $ok, $err, $req ) = run_request( getJSON => [$EPG], undef );
		exactly_one( $ok, $err, 'err', $name );

		my ($message) = $err->args(0);
		like( $message, $expected, "$name: message says what went wrong" );
		like( $message, qr/\Q$EPG\E/, "$name: message names the URL" );
		unlike( $message, qr/ at \S+ line \d+/, "$name: no Perl file/line noise" );
		ok( defined $req->{headers}->header('User-Agent'), "$name: User-Agent sent" );
		ok( scalar plugin_messages( level => 'WARN' ), "$name: logged a warning" );
	}
};

subtest 'quiet => 1: failures logged at DEBUG instead of WARN, same callbacks and messages' => sub {
	# plugin.abclisten at DEBUG for this subtest, so DEBUG lines are logged
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

	my @cases = (
		[ 'getJSON HTTP 500',     getJSON      => [$EPG],                    { code => 500, content => 'oops' },          qr/500 Internal Server Error/ ],
		[ 'getJSON timeout',      getJSON      => [$EPG],                    { error => 'Timed out waiting for data' },   qr/Timed out waiting for data/ ],
		[ 'getJSON invalid JSON', getJSON      => [$EPG],                    { code => 200, content => '<html></html>' }, qr/Invalid JSON/ ],
		[ 'getJSON empty body',   getJSON      => [$EPG],                    { code => 200, content => '' },              qr/Empty response/ ],
		[ 'postFormJSON 403',     postFormJSON => [ $EPG, { a => 1 } ],      { code => 403, content => 'Forbidden' },     qr/403 Forbidden/ ],
		[ 'postJSON 429',         postJSON     => [ $ALGOLIA, { q => 1 } ],  { code => 429, content => '{}' },            qr/429 Too Many Requests/ ],
		[ 'get 404',              get          => [$PLS],                    { code => 404 },                             qr/404 Not Found/ ],
	);

	for my $case (@cases) {
		my ( $name, $call, $leading, $response, $expected ) = @$case;
		my $target = $leading->[0];

		resetStubs();
		route( $target, %$response );
		my ( $ok, $err, $req ) = run_request( $call => $leading, { quiet => 1 } );
		exactly_one( $ok, $err, 'err', "quiet $name" );
		my ($message) = $err->args(0);
		like( $message, $expected, "quiet $name: same readable message" );
		my $shown = $target eq $ALGOLIA ? $ALGOLIA_LOGGED : $target;
		like( $message, qr/\Q$shown\E/, "quiet $name: message names the URL" . ( $target eq $ALGOLIA ? ' (F10: without the Algolia app id)' : '' ) );
		is( scalar plugin_messages( level => 'WARN' ), 0, "quiet $name: no WARN" );
		ok( ( grep { $_->{message} eq $message } plugin_messages( level => 'DEBUG' ) ), "quiet $name: logged at DEBUG" );
		ok( !exists $req->{params}->{quiet}, "quiet $name: not passed to SimpleAsyncHTTP" );

		# the default is unchanged: the same failure without quiet logs a WARN
		resetStubs();
		route( $target, %$response );
		( $ok, $err ) = run_request( $call => $leading, { quiet => 0 } );
		exactly_one( $ok, $err, 'err', "not quiet $name" );
		is( scalar plugin_messages( level => 'WARN' ), 1, "quiet => 0 $name: one WARN" );
	}

	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json' );
	my ( $ok, $err ) = run_request( getJSON => [$EPG], { quiet => 1 } );
	exactly_one( $ok, $err, 'ok', 'quiet success' );
	is( ref( ( $ok->args(0) )[0] ), 'HASH', 'quiet success: decoded as usual' );
};

subtest 'no route (network failure) still calls back once' => sub {
	for my $call (qw(getJSON get)) {
		resetStubs();
		my ( $ok, $err ) = run_request( $call => ['https://nowhere.test/'], undef );
		exactly_one( $ok, $err, 'err', "$call: no route" );
	}
	resetStubs();
	my ( $ok, $err ) = run_request( postJSON => [ 'https://nowhere.test/', {} ], undef );
	exactly_one( $ok, $err, 'err', 'postJSON: no route' );
};

subtest 'an exception in the success callback does not also call the error callback' => sub {
	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json' );

	my $err = collector();
	my $died = !eval { Plugins::ABCListen::HTTP::getJSON( $EPG, sub { die "callback bug\n" }, $err->cb ); 1 };
	ok( $died, 'the exception propagates' );
	is( $err->count, 0, 'error callback not called' );
};

subtest 'a missing error callback is allowed' => sub {
	resetStubs();
	route( $EPG, code => 500 );
	ok( eval { Plugins::ABCListen::HTTP::getJSON( $EPG, sub { fail('success callback') } ); 1 }, 'no error callback: no exception' ) or diag $@;
};

subtest 'postFormJSON: form encoding, headers and JSON decoding' => sub {
	resetStubs();
	my $url = 'https://example.test/form';
	# response bodies are bytes, as on the wire
	route( $url, content => Encode::encode_utf8('{"ok":true,"data":{"items":"<div>…</div>"}}'), headers => { 'Content-Type' => 'application/json; charset=UTF-8' } );

	my ( $ok, $err, $req ) = run_request(
		postFormJSON => [ $url, { action => 'search', empty => '', 'types[]' => ['program'], page => 2, q => 'Café & Co' } ],
		undef
	);
	exactly_one( $ok, $err, 'ok', 'POST' );

	is( $req->{method}, 'POST', 'POST request' );
	is( $req->{body}, 'action=search&empty=&page=2&q=Caf%C3%A9%20%26%20Co&types%5B%5D=program', 'fields URL-encoded (UTF-8), sorted by name' );
	is( $req->{headers}->header('Content-Type'), 'application/x-www-form-urlencoded', 'form Content-Type' );
	my $ua = $req->{headers}->header('User-Agent');
	ok( defined $ua && $ua !~ /libwww/i, 'non-libwww User-Agent on POST' );
	is( $req->{params}->{timeout}, 15, 'default timeout on POST' );
	is( ( $ok->args(0) )[0]->{data}->{items}, '<div>…</div>', 'response decoded' );

	resetStubs();
	route( $url, content => '', headers => {} );
	( $ok, $err, $req ) = run_request( postFormJSON => [ $url, { 'a[]' => [ 1, 2 ] } ], undef );
	is( $req->{body}, 'a%5B%5D=1&a%5B%5D=2', 'array values repeat the field' );
	exactly_one( $ok, $err, 'err', 'POST with empty response' );
};

subtest 'postJSON: method, Content-Type, JSON body and extra headers' => sub {
	resetStubs();
	route( $ALGOLIA, content => '{"hits":[{"title":"The Science Show"}],"nbHits":1}', headers => { 'Content-Type' => 'application/json; charset=UTF-8' } );

	my $body = { query => 'Café science', hitsPerPage => 60, filters => 'contentType:program', attributesToRetrieve => [ 'title', 'canonicalURL' ] };
	my ( $ok, $err, $req ) = run_request(
		postJSON => [ $ALGOLIA, $body ],
		{ headers => [ 'X-Algolia-Application-Id' => 'TESTAPP', 'X-Algolia-API-Key' => $SECRET ] }
	);
	exactly_one( $ok, $err, 'ok', 'postJSON' );

	is( $req->{method}, 'POST', 'method POST' );
	is( $req->{url}, $ALGOLIA, 'URL' );
	is( $req->{headers}->header('Content-Type'), 'application/json', 'Content-Type: application/json' );
	is_deeply( JSON::PP::decode_json( $req->{body} ), $body, 'body is the JSON encoding of the hash (UTF-8 bytes)' );
	ok( !utf8::is_utf8( $req->{body} ), 'body is a byte string' );
	is( $req->{headers}->header('X-Algolia-Application-Id'), 'TESTAPP', 'extra header sent' );
	is( $req->{headers}->header('X-Algolia-API-Key'),        $SECRET,   'second extra header sent' );
	is( $req->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), 'User-Agent still set' );
	is( $req->{params}->{timeout}, 15, 'default timeout' );
	is( ( $ok->args(0) )[0]->{hits}->[0]->{title}, 'The Science Show', 'response decoded' );

	resetStubs();
	route( $ALGOLIA, content => '[]' );
	( $ok, $err, $req ) = run_request( postJSON => [ $ALGOLIA, [ 1, 'two' ] ], undef );
	exactly_one( $ok, $err, 'ok', 'postJSON with an array body' );
	is( $req->{body}, '[1,"two"]', 'array body encoded' );

	for my $bad ( [ 'undef', undef ], [ 'string', 'query=x' ], [ 'code ref', sub { } ] ) {
		resetStubs();
		route( $ALGOLIA, content => '{}' );
		my ( $label, $value ) = @$bad;
		( $ok, $err, $req ) = run_request( postJSON => [ $ALGOLIA, $value ], undef );
		exactly_one( $ok, $err, 'err', "postJSON with a $label body" );
		is( $req, undef, "postJSON with a $label body: no request sent" );
		like( ( $err->args(0) )[0], qr/\Q$ALGOLIA_LOGGED\E/, "postJSON with a $label body: message names the URL (F10: without the Algolia app id)" );
	}
};

subtest 'headers option on every request function' => sub {
	my @calls = (
		[ getJSON      => [$EPG],                 'foundation/epgNowPlaying-RN-now.json' ],
		[ get          => [$PLS],                 'foundation/triplejnsw.pls' ],
		[ postFormJSON => [ $EPG, { a => 1 } ],   'foundation/epgNowPlaying-RN-now.json' ],
		[ postJSON     => [ $EPG, { a => 1 } ],   'foundation/epgNowPlaying-RN-now.json' ],
	);

	for my $call (@calls) {
		my ( $name, $leading, $file ) = @$call;
		resetStubs();
		route( $leading->[0], file => $file );

		my ( $ok, $err, $req ) = run_request( $name => $leading, { headers => [ 'X-Test' => 'one', Accept => 'application/json' ] } );
		exactly_one( $ok, $err, 'ok', "$name with headers" );
		is( $req->{headers}->header('X-Test'), 'one',              "$name: X-Test sent" );
		is( $req->{headers}->header('Accept'), 'application/json', "$name: Accept sent" );
		ok( defined $req->{headers}->header('User-Agent'), "$name: User-Agent still sent" );
		ok( !defined $req->{body} || $req->{body} !~ /X-Test/, "$name: headers are not taken as the body" );
	}

	resetStubs();
	route( $EPG, file => 'foundation/epgNowPlaying-RN-now.json' );
	my ( $ok, $err, $req ) = run_request( getJSON => [$EPG], { headers => [ 'X-Odd' => 'a', 'X-Dangling' ] } );
	exactly_one( $ok, $err, 'ok', 'malformed headers option (odd length)' );
	is( $req->{headers}->header('X-Odd'), undef, 'malformed headers option is ignored' );
	is( $req->{body}, undef, '... and does not become a GET body' );
	ok( ( grep { $_->{message} =~ /headers/ } plugin_messages( level => 'WARN' ) ), '... with a warning' );
};

subtest 'header values never appear in log output, even at DEBUG' => sub {
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };
	local $ENV{ABCLISTEN_TEST_LOG} = 1;

	my $printed = '';
	{
		local *STDERR;
		open( STDERR, '>', \$printed ) or die "Can't capture STDERR: $!";

		my @runs = (
			[ getJSON      => [$EPG],                  { file => 'foundation/epgNowPlaying-RN-now.json' } ],
			[ getJSON      => [$EPG],                  { code => 403, content => 'denied' } ],
			[ getJSON      => [$EPG],                  { code => 200, content => 'not json' } ],
			[ get          => [$PLS],                  { error => 'Timed out waiting for data' } ],
			[ postFormJSON => [ $EPG, { a => 1 } ],    { code => 500 } ],
			[ postJSON     => [ $ALGOLIA, { q => 1 } ], { code => 200, content => '{}' } ],
			[ postJSON     => [ $ALGOLIA, { q => 1 } ], { code => 403, content => '{"message":"Invalid API key"}' } ],
		);

		resetStubs();
		for my $run (@runs) {
			my ( $call, $leading, $response ) = @$run;
			Slim::Networking::SimpleAsyncHTTP->reset;
			route( $leading->[0], %$response );
			for my $quiet ( 0, 1 ) {
				run_request( $call => $leading, { quiet => $quiet, headers => [ 'X-Algolia-API-Key' => $SECRET, Authorization => "Bearer $SECRET" ] } );
			}
		}
		close STDERR;
	}

	my @messages = Slim::Utils::Log->messages;
	ok( scalar( grep { $_->{level} eq 'DEBUG' } @messages ), 'DEBUG messages were logged (so the check means something)' );
	ok( scalar( grep { $_->{level} eq 'WARN' } @messages ),  'WARN messages were logged' );
	is( scalar( grep { index( $_->{message}, $SECRET ) >= 0 } @messages ), 0, 'no recorded log message contains a header value' );
	ok( length $printed, 'ABCLISTEN_TEST_LOG printed the log' );
	unlike( $printed, qr/\Q$SECRET\E/, 'the printed log does not contain a header value' );
};

subtest 'get: raw body' => sub {
	resetStubs();
	route( $PLS, file => 'foundation/triplejnsw.pls', headers => { 'Content-Type' => 'audio/x-scpls' } );

	my ( $ok, $err, $req ) = run_request( get => [$PLS], undef );
	exactly_one( $ok, $err, 'ok', 'raw get' );
	like( ( $ok->args(0) )[0], qr{^File1=https://abc\.streamguys1\.com/live/triplejnsw/icecast\.audio$}m, 'body returned as a string' );
	is( $req->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), 'User-Agent on raw get' );
	is( $req->{params}->{timeout}, 15, 'default timeout on raw get' );

	resetStubs();
	route( $PLS, code => 404 );
	( $ok, $err ) = run_request( get => [$PLS], undef );
	exactly_one( $ok, $err, 'err', 'raw get 404' );
	like( ( $err->args(0) )[0], qr/404 Not Found/, 'raw get error message' );

	resetStubs();
	route( $PLS, error => 'Timed out waiting for data' );
	( $ok, $err ) = run_request( get => [$PLS], undef );
	exactly_one( $ok, $err, 'err', 'raw get timeout' );
};

subtest "F6: the error callback gets LMS's response third (a 307 LMS can't follow, an HTTP error status)" => sub {
	my $NEXT  = 'https://www.abc.net.au/_next/data/build-test/listen/programs/old-name.json';
	my @calls = (
		[ getJSON      => [$NEXT] ],
		[ get          => [$NEXT] ],
		[ postFormJSON => [ $NEXT, { a => 1 } ] ],
		[ postJSON     => [ $NEXT, { a => 1 } ] ],
	);

	for my $call (@calls) {
		my ( $fn, $leading ) = @$call;

		for my $quiet ( 0, 1 ) {
			my $name = $fn . ( $quiet ? ' (quiet)' : '' );

			# ABC's 307 with only x-nextjs-redirect: LMS fails it ("Redirection without location")
			resetStubs();
			route( $NEXT, code => 307, headers => { 'x-nextjs-redirect' => '/listen/programs/new-name' } );
			my ( $ok, $err ) = run_request( $fn => $leading, { quiet => $quiet } );
			exactly_one( $ok, $err, 'err', "$name, 307" );
			my @args = $err->args(0);
			is( scalar @args, 3, "$name, 307: three arguments" );
			my ( $message, $http, $response ) = @args;
			is( $message, "HTTP request failed: Redirection without location ($NEXT)", "$name, 307: LMS's reason and the URL" );
			ok( ref $http && $http->can('code'), "$name, 307: the HTTP object second" );
			is( ref $response && $response->code, 307, "$name, 307: the response third, with its code" );
			is( ref $response && $response->headers->header('X-Nextjs-Redirect'), '/listen/programs/new-name', "$name, 307: ... and its headers" );

			# an HTTP error status: the response too
			resetStubs();
			route( $NEXT, code => 404, content => 'Not Found', headers => { 'Content-Type' => 'text/html' } );
			( $ok, $err ) = run_request( $fn => $leading, { quiet => $quiet } );
			exactly_one( $ok, $err, 'err', "$name, 404" );
			@args = $err->args(0);
			is( scalar @args, 3, "$name, 404: three arguments" );
			like( $args[0], qr/\AHTTP request failed: 404 Not Found/, "$name, 404: message as before" );
			is( ref $args[2] && $args[2]->code, 404, "$name, 404: the response third" );
		}
	}

	# no response read (the stub's transport errors model one before any headers: it never passes
	# a response with them; LMS does when it had read headers, e.g. a body timeout, and HTTP.pm then
	# passes it on as above), or an answer LMS passed to the success callback: two arguments
	my @two = (
		[ 'a transport error before any headers', getJSON => [$NEXT],         { error => 'Timed out waiting for data' } ],
		[ 'no route (no response read)',    get      => [$NEXT],              undef ],
		[ 'invalid JSON',                   getJSON  => [$NEXT],              { code => 200, content => '<html></html>' } ],
		[ 'a 308 (not JSON; code on $http)', getJSON => [$NEXT],              { code => 308, headers => { Location => '/listen/programs/new-name' }, content => '/listen/programs/new-name' } ],
		[ 'an unencodable body',            postJSON => [ $NEXT, 'not a ref' ], { code => 200, content => '{}' } ],
	);
	for my $case (@two) {
		my ( $name, $fn, $leading, $response ) = @$case;
		resetStubs();
		route( $NEXT, %$response ) if $response;
		my ( $ok, $err ) = run_request( $fn => $leading, undef );
		exactly_one( $ok, $err, 'err', $name );
		is( scalar( my @args = $err->args(0) ), 2, "$name: no response to pass on, so two arguments" );
	}

	# LMS's onError passes $http->response whatever the error, once it had read headers: e.g. a
	# timeout after LMS followed a redirect, with that 30x (Location included). The stub can't
	# produce one, so call the error handler as SimpleAsyncHTTP::onError would.
	resetStubs();
	route( $NEXT, code => 200, content => '{}', defer => 1 );
	my ( $ok, $err ) = run_request( getJSON => [$NEXT], undef );
	my ($http) = map { $_->[0] } @Slim::Networking::SimpleAsyncHTTP::DEFERRED;
	@Slim::Networking::SimpleAsyncHTTP::DEFERRED = ();
	my $followed = Slim::Networking::SimpleAsyncHTTP::Response->new( 307, 'Temporary Redirect', Slim::Networking::SimpleAsyncHTTP::Headers->new( Location => '/listen/programs/new-name' ), '' );
	$http->ecb->( $http, 'Timed out waiting for data', $followed );
	exactly_one( $ok, $err, 'err', 'a transport error after a followed redirect' );
	my @args = $err->args(0);
	is( $args[0], "HTTP request failed: Timed out waiting for data ($NEXT)", 'a transport error after a followed redirect: the message as before' );
	is( scalar @args, 3, '... and the response LMS passed, third' );
	is( ref $args[2] && $args[2]->header('Location'), '/listen/programs/new-name', '... unchanged (the 307 LMS followed)' );
};

subtest 'F10: no Algolia app id or key in any log line or message, at any level' => sub {
	# the request line (DEBUG), failures quiet (DEBUG) and not (WARN), a body that isn't JSON, a
	# body that can't be sent, malformed headers; plugin.abclisten at DEBUG
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';
	my @cases = (
		[ 'success', { content => '{"hits":[]}' }, [ { q => 1 } ], { headers => [ 'X-Algolia-Application-Id' => 'TESTAPP', 'X-Algolia-API-Key' => $SECRET ] } ],
		[ '403 quiet', { code => 403, content => '{"message":"Invalid API key"}' }, [ { q => 1 } ], { quiet => 1, headers => [ 'X-Algolia-Application-Id' => 'TESTAPP', 'X-Algolia-API-Key' => $SECRET ] } ],
		[ '500', { code => 500, content => 'oops' }, [ { q => 1 } ], {} ],
		[ 'not JSON', { content => 'oops, not JSON' }, [ { q => 1 } ], {} ],
		[ 'no body', { content => '{}' }, [undef], {} ],
		[ 'malformed headers', { content => '{}' }, [ { q => 1 } ], { headers => ['X-Algolia-API-Key'] } ],
	);
	for my $case (@cases) {
		my ( $name, $response, $args, $opts ) = @$case;
		resetStubs();
		route( $ALGOLIA, %$response );
		my ( $ok, $err ) = run_request( postJSON => [ $ALGOLIA, @$args ], $opts );
		my @lines = map { $_->{message} } plugin_messages();
		my @texts = ( @lines, map { defined $_ && !ref $_ ? $_ : () } $err->args(0) );
		ok( scalar @lines, "$name: logged (" . scalar(@lines) . ' lines)' );
		is( scalar( grep {/TESTAPP/} @texts ), 0, "$name: no app id in a log line or the error message" ) or diag explain \@texts;
		is( scalar( grep {/\Q$SECRET\E/} @texts ), 0, "$name: no API key" );
	}
	resetStubs();
	route( $ALGOLIA, content => '{}' );
	run_request( postJSON => [ $ALGOLIA, { q => 1 } ], undef );
	ok( ( grep { $_->{level} eq 'DEBUG' && $_->{message} eq "POST $ALGOLIA_LOGGED" } plugin_messages() ), 'the request line: "POST https://<algolia>-dsn.algolia.net/..."' );

	my %urls = (
		'https://TESTAPP-dsn.algolia.net/1/indexes/x/query'                                       => 'https://<algolia>-dsn.algolia.net/1/indexes/x/query',
		'https://TESTAPP.algolia.net/1/x'                                                         => 'https://<algolia>.algolia.net/1/x',
		'https://testapp-1.algolianet.com/1/x?x-algolia-api-key=K&x-algolia-application-id=A&q=1' => 'https://<algolia>-1.algolianet.com/1/x?x-algolia-api-key=<hidden>&x-algolia-application-id=<hidden>&q=1',
		'https://TESTAPP-DSN.ALGOLIA.NET:443/1/x'                                                 => 'https://<algolia>-DSN.ALGOLIA.NET:443/1/x',
		$EPG                                                                                      => $EPG,
		'https://www.abc.net.au/listen/search?q=algolia.net'                                      => 'https://www.abc.net.au/listen/search?q=algolia.net',
	);
	is( Plugins::ABCListen::HTTP::_logUrl($_), $urls{$_}, "_logUrl($_)" ) for sort keys %urls;
	is( Plugins::ABCListen::HTTP::_logUrl(undef), '', '_logUrl(undef): empty' );
};

done_testing();
