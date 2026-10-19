#!/usr/bin/perl
# Plugins::ABCListen::HTTP: explicit non-libwww User-Agent on every request, 15 s default timeout,
# cache options passed through, JSON decoded whatever the Content-Type, form encoding, postJSON,
# the headers option, header values never logged, and exactly one callback per request on every
# path. All HTTP goes through the SimpleAsyncHTTP stub: no network.

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
		like( $message, qr/\Q$target\E/, "quiet $name: message names the URL" );
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
		like( ( $err->args(0) )[0], qr/\Q$ALGOLIA\E/, "postJSON with a $label body: message names the URL" );
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

done_testing();
