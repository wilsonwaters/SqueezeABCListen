package Slim::Menu::GlobalSearch;

# Test stub for LMS Slim::Menu::GlobalSearch (the "Search" menu on the LMS home screen; a
# Slim::Menu::Base subclass).
# Real API (Slim/Menu/GlobalSearch.pm, Slim/Menu/Base.pm):
#   Slim::Menu::GlobalSearch->registerInfoProvider($name, after|before|isa => ..., func => \&cb)
#       class method; func->($client, $tags) returns an item hash (or undef to add nothing), where
#       $tags->{search} is the query and $tags->{apps} the player's enabled apps;
#       with no after/before/isa the provider is placed with isa => 'middle'.
#   Slim::Menu::GlobalSearch->deregisterInfoProvider($name)
#   Slim::Menu::GlobalSearch->getInfoProvider   { $name => \%details }
#   Slim::Menu::GlobalSearch->name              'GLOBAL_SEARCH'
# Providers are kept in %PROVIDERS{$name} = \%details (with name => $name, as in LMS).

use strict;
use warnings;

our %PROVIDERS;

sub name { 'GLOBAL_SEARCH' }

sub registerInfoProvider {
	my ( $class, $name, %details ) = @_;
	$details{name} = $name;
	$details{isa} = 'middle' unless defined $details{after} || defined $details{before} || defined $details{isa};
	$PROVIDERS{$name} = \%details;
	return;
}

sub deregisterInfoProvider {
	my ( $class, $name ) = @_;
	delete $PROVIDERS{$name};
	return;
}

sub getInfoProvider { \%PROVIDERS }

# test helper
sub reset { %PROVIDERS = (); return }

1;
