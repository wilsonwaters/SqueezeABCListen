package Plugins::ABCListen::Discover;

# Discover hook (hook API: see Plugin.pm): featured collections, categories, popular now.
# F1 stub: no menu items yet. Owned by the discovery stream (D1, then D2) after F1.

use strict;
use warnings;

sub init { return }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;
	$cb->( [] );
}

1;
