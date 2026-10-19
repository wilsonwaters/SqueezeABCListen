package Slim::Player::ProtocolHandlers;

# Test stub for LMS Slim::Player::ProtocolHandlers.
# Real API: registerHandler($protocol => $class), handlerForProtocol($protocol),
# handlerForURL($url) (scheme lookup; returns the class only if it contains '::'),
# registeredHandlers(), isValidHandler($protocol).

use strict;
use warnings;

my %DEFAULTS = (
	http  => 'Slim::Player::Protocols::HTTP',
	https => 'Slim::Player::Protocols::HTTPS',
	icy   => 'Slim::Player::Protocols::HTTP',
);

our %HANDLERS = %DEFAULTS;

sub registerHandler {
	my ( $class, $protocol, $classToRegister ) = @_;
	$HANDLERS{$protocol} = $classToRegister;
}

sub handlerForProtocol { $HANDLERS{ $_[1] } }

sub handlerForURL {
	my ( $class, $url ) = @_;
	return undef unless $url;

	my ($protocol) = $url =~ /^([a-zA-Z0-9\-]+):/;
	return undef unless $protocol;

	my $handler = $HANDLERS{ lc $protocol };
	return $handler && $handler =~ /::/ ? $handler : undef;
}

sub registeredHandlers { keys %HANDLERS }

sub isValidHandler {
	my ( $class, $protocol ) = @_;
	return undef unless defined $protocol;
	return $HANDLERS{$protocol} ? 1 : exists $HANDLERS{$protocol} ? 0 : undef;
}

# test helper
sub reset { %HANDLERS = %DEFAULTS; return }

1;
