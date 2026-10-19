package Slim::Menu::TrackInfo;

# Test stub for LMS Slim::Menu::TrackInfo (song info menu).
# Real API (Slim::Menu::Base): registerInfoProvider($name, after|before => ..., func => \&cb),
# called as a class method; func->($client, $url, $track, $remoteMeta, $tags) returns an item
# or arrayref of items. deregisterInfoProvider($name).
# Providers are kept in %PROVIDERS{$name} = \%details.

use strict;
use warnings;

our %PROVIDERS;

sub registerInfoProvider {
	my ( $class, $name, %details ) = @_;
	$details{name} = $name;
	$PROVIDERS{$name} = \%details;
	return;
}

sub deregisterInfoProvider {
	my ( $class, $name ) = @_;
	delete $PROVIDERS{$name};
	return;
}

# test helper
sub reset { %PROVIDERS = (); return }

1;
