package Plugins::ABCListen::HTTP;

# Non-blocking HTTP helpers for talking to ABC's web services, on top of
# Slim::Networking::SimpleAsyncHTTP.
#
#   getJSON($url, $cb, $ecb, \%opts)                 GET, decode the body as JSON
#   postFormJSON($url, \%form, $cb, $ecb, \%opts)    POST form-encoded fields, decode JSON
#   postJSON($url, \%body, $cb, $ecb, \%opts)        POST a JSON body (hash or array ref), decode JSON
#   get($url, $cb, $ecb, \%opts)                     GET, raw body string (e.g. HTML, .pls)
#
# Contract (every function):
#   - Every request sends an explicit User-Agent: LMS's own user agent string, never the
#     "libwww-perl/..." default that CDNs and WAFs tend to block.
#   - Timeout defaults to 15 seconds (opts: timeout). opts cache/expires are passed through to
#     SimpleAsyncHTTP (cache => 1, expires => seconds or '1h').
#   - opts headers => [ Name => value, ... ] adds request headers (e.g. API keys). Header values
#     are never logged, at any level. A malformed list (odd length) is ignored with a warning.
#   - A failed request is logged at WARN, or at DEBUG with opts quiet => 1 (for callers that log
#     failures themselves); the error callback is called either way.
#   - JSON is decoded whatever the Content-Type (ABC serves some JSON as text/plain or
#     text/html); a UTF-8 byte-order mark and surrounding whitespace are ignored. The decoded
#     value must be an object or an array.
#   - Exactly one callback is called per request:
#       $cb->($data, $http)     $data = decoded JSON (getJSON/postFormJSON/postJSON) or body string (get)
#       $ecb->($message, $http) $message is readable, e.g. "HTTP request failed: 403 Forbidden (<url>)"
#       $ecb->($message, $http, $response)
#                               F6: LMS's SimpleAsyncHTTP passes its error callback the request's
#                               HTTP::Response whenever LMS had read response headers, and it comes
#                               third here, with their code and headers ($http has neither on that
#                               path): a status other than 2xx/3xx; a redirect LMS can't follow
#                               ("Redirection without location") or gave up on ("Redirection limit
#                               exceeded"); an error reading the body; or a transport error after
#                               LMS followed a redirect (the response is then that 30x, Location
#                               included). Without one (e.g. a connect error or a timeout before any
#                               headers), and for a body that isn't JSON, two arguments. (The
#                               t/lib SimpleAsyncHTTP stub never passes a response with a
#                               transport error.)
#     If $cb itself dies, the exception propagates; $ecb is not called as well.
#
# Owned by the foundation stream: other streams may only append to it (and must say so in their PR).

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Misc;

use constant DEFAULT_TIMEOUT => 15;

my $log = logger('plugin.abclisten');

sub getJSON {
	my ( $url, $cb, $ecb, $opts ) = @_;

	_request( GET => $url, [], undef, _jsonHandler( $url, $cb, $ecb, $opts ), $ecb, $opts );
}

sub postFormJSON {
	my ( $url, $form, $cb, $ecb, $opts ) = @_;

	_request(
		POST => $url,
		[ 'Content-Type' => 'application/x-www-form-urlencoded' ],
		_encodeForm($form),
		_jsonHandler( $url, $cb, $ecb, $opts ),
		$ecb, $opts
	);
}

sub get {
	my ( $url, $cb, $ecb, $opts ) = @_;

	_request( GET => $url, [], undef, sub { $cb->( $_[0]->content, $_[0] ) }, $ecb, $opts );
}

sub _request {
	my ( $method, $url, $headers, $body, $onSuccess, $ecb, $opts ) = @_;
	$opts ||= {};

	my $onError = sub {
		my ( $http, $error, $response ) = @_;
		_fail( $ecb, sprintf( 'HTTP request failed: %s (%s)', $error || 'unknown error', $url ), $http, $opts->{quiet}, $response );
	};

	my %params = ( timeout => $opts->{timeout} || DEFAULT_TIMEOUT );
	for my $key (qw(cache expires)) {
		$params{$key} = $opts->{$key} if defined $opts->{$key};
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new( $onSuccess, $onError, \%params );

	my @args = ( 'User-Agent' => Slim::Utils::Misc::userAgentString(), @$headers, _extraHeaders( $opts, $url ) );
	push @args, $body if defined $body;

	main::DEBUGLOG && $log->is_debug && $log->debug("$method $url");

	if ( $method eq 'POST' ) {
		$http->post( $url, @args );
	}
	else {
		$http->get( $url, @args );
	}

	return;
}

# Success callback for JSON requests: decode, then call exactly one of $cb / $ecb.
sub _jsonHandler {
	my ( $url, $cb, $ecb, $opts ) = @_;
	my $quiet = $opts && $opts->{quiet};

	return sub {
		my $http = shift;
		my ( $data, $error ) = _decodeJSON( $http->content );

		if ( defined $error ) {
			return _fail( $ecb, "$error ($url)", $http, $quiet );
		}

		$cb->( $data, $http );
	};
}

sub _decodeJSON {
	my $content = shift;
	$content = '' unless defined $content;

	$content =~ s/^(?:\xEF\xBB\xBF|\x{FEFF})//;
	$content =~ s/^\s+//;
	$content =~ s/\s+$//;

	return ( undef, 'Empty response' ) unless length $content;

	my $data = eval { from_json($content) };

	if ($@) {
		( my $error = $@ ) =~ s/\s+at \S+ line \d+.*//s;
		return ( undef, "Invalid JSON response: $error" );
	}

	if ( !ref $data || ( ref $data ne 'HASH' && ref $data ne 'ARRAY' ) ) {
		return ( undef, 'Unexpected JSON response (not an object or array)' );
	}

	return ($data);
}

# $response (F6): the HTTP::Response LMS's SimpleAsyncHTTP passes its error callback, if any. It
# goes on to $ecb as a third argument; without one $ecb gets two arguments, as before.
sub _fail {
	my ( $ecb, $message, $http, $quiet, $response ) = @_;

	if ($quiet) {
		main::DEBUGLOG && $log->is_debug && $log->debug($message);
	}
	else {
		$log->warn($message);
	}
	$ecb->( $message, $http, ( ref $response ? $response : () ) ) if $ecb;

	return;
}

sub _encodeForm {
	my $form = shift || {};

	my @pairs;
	for my $key ( sort keys %$form ) {
		my $value = $form->{$key};
		for my $v ( ref $value eq 'ARRAY' ? @$value : ($value) ) {
			push @pairs, uri_escape_utf8($key) . '=' . uri_escape_utf8( defined $v ? $v : '' );
		}
	}

	return join( '&', @pairs );
}

# ---------------------------------------------------------------------------
# Appended by F1 (ABC listen): postJSON and the headers option.
# ---------------------------------------------------------------------------

# POST $body (a hash or array ref) as JSON (UTF-8), decode the JSON answer. A body that isn't a
# hash or array ref sends nothing and calls $ecb once.
sub postJSON {
	my ( $url, $body, $cb, $ecb, $opts ) = @_;

	my $json = ( ref $body eq 'HASH' || ref $body eq 'ARRAY' ) ? eval { encode_json($body) } : undef;

	if ( !defined $json ) {
		return _fail( $ecb, "Could not encode the request body as JSON ($url)", undef, $opts && $opts->{quiet} );
	}

	_request(
		POST => $url,
		[ 'Content-Type' => 'application/json' ],
		$json,
		_jsonHandler( $url, $cb, $ecb, $opts ),
		$ecb, $opts
	);
}

# The caller's extra headers (opts headers => [ Name => value, ... ]). Header values may be API
# keys: they are never logged.
sub _extraHeaders {
	my ( $opts, $url ) = @_;
	my $headers = $opts->{headers};

	return () unless defined $headers;

	if ( ref $headers ne 'ARRAY' || @$headers % 2 ) {
		$log->warn("Ignoring malformed headers option (expected [ Name => value, ... ]) for $url");
		return ();
	}

	return @$headers;
}

1;
