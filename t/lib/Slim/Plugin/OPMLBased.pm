package Slim::Plugin::OPMLBased;

# Test stub for LMS Slim::Plugin::OPMLBased.
# Real initPlugin(%args): is_app => 1 forces menu 'apps'; installs class methods feed, tag,
# menu, weight (default 1000) and type (default 'link'); registers the CLI commands
# [<tag> items ...], [<tag> playlist ...] and [<menu> ...], the Jive menu and web pages; then
# calls Slim::Plugin::Base::initPlugin.
#
# The stub installs the same class methods and records each call's arguments in
# %INIT_ARGS{$class}, so tests can check what a plugin registered.

use strict;
use warnings;

use base 'Slim::Plugin::Base';

our %INIT_ARGS;

sub initPlugin {
	my ( $class, %args ) = @_;

	$INIT_ARGS{$class} = {%args};

	if ( $args{is_app} ) {
		$args{menu} = 'apps';
	}

	{
		no strict 'refs';
		no warnings 'redefine';
		*{ $class . '::feed' }   = sub { $args{feed} } if $args{feed};
		*{ $class . '::tag' }    = sub { $args{tag} };
		*{ $class . '::menu' }   = sub { $args{menu} };
		*{ $class . '::weight' } = sub { $args{weight} || 1000 };
		*{ $class . '::type' }   = sub { $args{type} || 'link' };
	}

	$class->SUPER::initPlugin();
}

1;
