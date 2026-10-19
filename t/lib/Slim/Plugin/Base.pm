package Slim::Plugin::Base;

# Test stub for LMS Slim::Plugin::Base.
# Real API: initPlugin (registers modes/menus/web pages), getDisplayName (install.xml name),
# playerMenu (install.xml playerMenu or 'PLUGINS'), condition, _pluginDataFor($key) (install.xml
# data from Slim::Utils::PluginManager). Tests can fill %PLUGIN_DATA{$class}{$key}.

use strict;
use warnings;

use constant PLUGINMENU => 'PLUGINS';

our %PLUGIN_DATA;

sub initPlugin { return }

sub getDisplayName {
	my $class = shift;
	return $class->_pluginDataFor('name') || $class;
}

sub playerMenu {
	my $class = shift;
	return $class->_pluginDataFor('playerMenu') || PLUGINMENU;
}

sub modeName  { $_[0] }
sub condition { 1 }

sub _pluginDataFor {
	my ( $class, $key ) = @_;
	$class = ref $class || $class;
	return $PLUGIN_DATA{$class} ? $PLUGIN_DATA{$class}->{$key} : undef;
}

1;
