package Plugins::ABCListen::Search;

# Search hook (hook API: see Plugin.pm): "Search ABC listen" and the LMS global search provider.
# F1 stub: no menu items yet. Owned by the discovery stream (D3) after F1.

use strict;
use warnings;

sub init { return }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;
	$cb->( [] );
}

1;
