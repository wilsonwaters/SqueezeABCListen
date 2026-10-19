package Slim::Control::Request;

# Test stub for LMS Slim::Control::Request.
# Real API: addDispatch(\@command, \@data) registers a CLI/JSON-RPC command;
# notifyFromArray($client, \@request) sends a notification such as ['newmetadata'];
# subscribe(\&cb, \@filter) / unsubscribe(\&cb).
# Calls are recorded in @DISPATCHES, @NOTIFICATIONS and @SUBSCRIPTIONS.

use strict;
use warnings;

our @DISPATCHES;
our @NOTIFICATIONS;
our @SUBSCRIPTIONS;

sub addDispatch {
	my ( $command, $data ) = @_;
	push @DISPATCHES, { command => $command, data => $data };
	return undef;
}

sub notifyFromArray {
	my ( $client, $request ) = @_;
	push @NOTIFICATIONS, { client => $client, request => $request };
	return;
}

sub subscribe {
	my ( $cb, $filter ) = @_;
	push @SUBSCRIPTIONS, { cb => $cb, filter => $filter };
	return;
}

sub unsubscribe {
	my $cb = shift;
	@SUBSCRIPTIONS = grep { $_->{cb} != $cb } @SUBSCRIPTIONS;
	return;
}

# test helper
sub reset { @DISPATCHES = (); @NOTIFICATIONS = (); @SUBSCRIPTIONS = (); return }

1;
