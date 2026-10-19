package Plugins::ABCListen::OnDemand;

# Programs and episodes hook (hook API: see Plugin.pm). F1 stub: no menu items yet.
#
# init loads and initialises Plugins::ABCListen::Episode (episode playback), so the episode task
# (O1) fills Episode.pm and never edits this file. Owned by the ondemand stream (O2) after F1.

use strict;
use warnings;

sub init {
	require Plugins::ABCListen::Episode;
	Plugins::ABCListen::Episode->init();
}

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;
	$cb->( [] );
}

1;
