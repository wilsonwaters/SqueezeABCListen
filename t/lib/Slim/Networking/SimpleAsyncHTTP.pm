package Slim::Networking::SimpleAsyncHTTP;

# Test stub for LMS Slim::Networking::SimpleAsyncHTTP. It never touches the network.
#
# Real API (Slim/Networking/SimpleAsyncHTTP.pm, SimpleHTTP/Base.pm):
#   my $http = Slim::Networking::SimpleAsyncHTTP->new(\&onSuccess, \&onError, \%params);
#   $http->get($url, 'Header' => 'value', ...);
#   $http->post($url, 'Header' => 'value', ..., $body);   # odd arg count: last one is the body
#   onSuccess->($http)                 for 2xx/3xx responses
#   onError->($http, $error, $response) for transport errors and non-2xx/3xx ($error = "403 Forbidden")
#   $http->content, ->contentRef, ->code, ->mess, ->headers, ->url, ->error, ->params($key)
#
# Here each request is matched against routes registered with addRoute() (first match wins;
# the match is an exact URL string, a regex or a coderef), recorded in @REQUESTS with its
# method, URL, headers, body and params, and answered synchronously:
#   { code => 200, content => '...', headers => { 'Content-Type' => '...' } }   # response
#   { error => 'Timed out waiting for data' }                                 # transport error
# A request with no matching route fails like a network error.
# A response with defer => 1 is not answered straight away: the request is recorded and waits
# until the test calls completeDeferred(), like a slow server (deferred() lists what waits).

use strict;
use warnings;

our @REQUESTS;
our @ROUTES;
our @DEFERRED;    # requests waiting for completeDeferred(), each [ $http, $method, $url, $response ]

my %MESSAGES = (
	200 => 'OK', 204 => 'No Content', 301 => 'Moved Permanently', 302 => 'Found', 304 => 'Not Modified',
	400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found', 429 => 'Too Many Requests',
	500 => 'Internal Server Error', 502 => 'Bad Gateway', 503 => 'Service Unavailable',
);

# ---- test helpers ----

sub addRoute {
	my ( $class, $match, $response ) = @_;
	push @ROUTES, [ $match, $response ];
	return;
}

sub reset {
	@REQUESTS = ();
	@ROUTES   = ();
	@DEFERRED = ();
	return;
}

sub requests { return @REQUESTS }

# Requests waiting for completeDeferred() (URLs, oldest first).
sub deferred { return map { $_->[2] } @DEFERRED }

# Answer the waiting requests, oldest first, with their routed response (defer removed), or
# with %override merged into it, e.g. completeDeferred(error => 'Timed out waiting for data').
# Requests deferred by those callbacks wait for the next call. Returns how many were answered.
sub completeDeferred {
	my ( $class, %override ) = @_;

	my @pending = @DEFERRED;
	@DEFERRED = ();

	for my $entry (@pending) {
		my ( $http, $method, $url, $response ) = @$entry;
		my %merged = ( %$response, %override );
		delete $merged{defer};
		$http->_respond( $method, $url, \%merged );
	}

	return scalar @pending;
}

# ---- real API ----

sub new {
	my ( $class, $cb, $ecb, $params ) = @_;
	return bless { cb => $cb, ecb => $ecb, _params => $params || {} }, $class;
}

sub hasSSL { 1 }

sub get    { shift->_request( GET    => @_ ) }
sub post   { shift->_request( POST   => @_ ) }
sub put    { shift->_request( PUT    => @_ ) }
sub delete { shift->_request( DELETE => @_ ) }
sub head   { shift->_request( HEAD   => @_ ) }

sub params {
	my ( $self, $key, $value ) = @_;
	return $self->{_params} unless defined $key;
	$self->{_params}->{$key} = $value if defined $value;
	return $self->{_params}->{$key};
}

sub cb         { $_[0]->{cb} }
sub ecb        { $_[0]->{ecb} }
sub url        { $_[0]->{url} }
sub type       { $_[0]->{type} }
sub code       { $_[0]->{code} }
sub mess       { $_[0]->{mess} }
sub error      { $_[0]->{error} }
sub headers    { $_[0]->{headers} }
sub contentRef { $_[0]->{contentRef} }
sub content    { ${ $_[0]->{contentRef} || \'' } }
sub close      { }

sub _request {
	my ( $self, $method, $url, @args ) = @_;

	$self->{type} = $method;
	$self->{url}  = $url;

	my $body = @args % 2 ? pop @args : undef;

	push @REQUESTS, {
		method  => $method,
		url     => $url,
		headers => Slim::Networking::SimpleAsyncHTTP::Headers->new(@args),
		body    => $body,
		params  => { %{ $self->{_params} } },
	};

	my $response = _route( $url, $method, $body );

	if ( $response && $response->{defer} ) {
		push @DEFERRED, [ $self, $method, $url, $response ];
		return;
	}

	return $self->_respond( $method, $url, $response );
}

# Deliver $response (undef: no matching route) to the request's callbacks.
sub _respond {
	my ( $self, $method, $url, $response ) = @_;

	if ( !$response ) {
		$self->{error} = "No test fixture for $method $url";
		return $self->{ecb}->( $self, $self->{error}, undef );
	}

	if ( defined $response->{error} ) {
		$self->{error} = $response->{error};
		return $self->{ecb}->( $self, $self->{error}, undef );
	}

	my $code = $response->{code} || 200;
	my $mess = $response->{mess} || $MESSAGES{$code} || 'Unknown';
	my $headers = Slim::Networking::SimpleAsyncHTTP::Headers->new( %{ $response->{headers} || {} } );
	my $content = defined $response->{content} ? $response->{content} : '';
	my $res = Slim::Networking::SimpleAsyncHTTP::Response->new( $code, $mess, $headers, $content );

	if ( $code !~ /^[23]\d\d$/ ) {
		# Slim::Networking::Async::HTTP reports non-2xx/3xx codes as errors (status line), and
		# SimpleAsyncHTTP::onError doesn't fill in code/headers/content.
		$self->{error} = "$code $mess";
		return $self->{ecb}->( $self, $self->{error}, $res );
	}

	$self->{code}       = $code;
	$self->{mess}       = $mess;
	$self->{headers}    = $headers;
	$self->{contentRef} = \$content;

	return $self->{cb}->($self);
}

sub _route {
	my ( $url, $method, $body ) = @_;

	for my $route (@ROUTES) {
		my ( $match, $response ) = @$route;

		my $hit = ref $match eq 'Regexp' ? $url =~ $match
			: ref $match eq 'CODE' ? $match->( $url, $method, $body )
			: $url eq $match;

		return ref $response eq 'CODE' ? $response->( $url, $method, $body ) : $response if $hit;
	}

	return;
}

# Minimal HTTP::Headers stand-in (case-insensitive header lookup).
package Slim::Networking::SimpleAsyncHTTP::Headers;

sub new {
	my ( $class, @pairs ) = @_;
	my $self = bless { order => [], values => {} }, $class;
	while ( my ( $k, $v ) = splice( @pairs, 0, 2 ) ) {
		push @{ $self->{order} }, $k unless exists $self->{values}->{ lc $k };
		$self->{values}->{ lc $k } = $v;
	}
	return $self;
}

sub header       { $_[0]->{values}->{ lc $_[1] } }
sub header_field_names { @{ $_[0]->{order} } }
sub content_type { my $ct = $_[0]->header('Content-Type'); return '' unless defined $ct; $ct =~ s/;.*//; return lc $ct }

# Minimal HTTP::Response stand-in, passed as the error callback's third argument.
package Slim::Networking::SimpleAsyncHTTP::Response;

sub new {
	my ( $class, $code, $mess, $headers, $content ) = @_;
	return bless { code => $code, message => $mess, headers => $headers, content => $content }, $class;
}

sub code        { $_[0]->{code} }
sub message     { $_[0]->{message} }
sub status_line { "$_[0]->{code} $_[0]->{message}" }
sub headers     { $_[0]->{headers} }
sub header      { $_[0]->{headers}->header( $_[1] ) }
sub content     { $_[0]->{content} }
sub content_ref { \$_[0]->{content} }

1;
