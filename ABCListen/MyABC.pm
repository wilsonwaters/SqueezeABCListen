package Plugins::ABCListen::MyABC;

# My ABC listen hook (hook API: see Plugin.pm): settings page, home state, followed programs.
# F1 stub: no menu items yet. Owned by the myabc stream (M1, then M2) after F1.

use strict;
use warnings;

sub init { return }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;
	$cb->( [] );
}

1;
