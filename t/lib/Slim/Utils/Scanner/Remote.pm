package Slim::Utils::Scanner::Remote;

# Test stub for LMS Slim::Utils::Scanner::Remote.
# Real API: Slim::Utils::Scanner::Remote->scanURL($url, \%args) with args { client, song, cb,
# pt, title }; when done it calls $args->{cb}->($track, $error, @{ $args->{pt} }) where $track is
# undef on failure and $error an error string token.
#
# The stub records calls in @SCANS. If a test set $HANDLER (a coderef), scanURL returns
# $HANDLER->($url, $args) and the handler is responsible for the callback; otherwise it fails
# at once so nothing waits for a scan that can't happen.

use strict;
use warnings;

our @SCANS;
our $HANDLER;

sub scanURL {
	my ( $class, $url, $args ) = @_;
	$args ||= {};

	push @SCANS, { url => $url, args => $args };

	return $HANDLER->( $url, $args ) if $HANDLER;

	my $cb = $args->{cb} || sub { };
	return $cb->( undef, 'SCANNER_REMOTE_TEST_NO_HANDLER', @{ $args->{pt} || [] } );
}

# test helper
sub reset { @SCANS = (); $HANDLER = undef; return }

1;
