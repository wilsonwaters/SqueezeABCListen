package Slim::Web::Settings;

# Test stub for LMS Slim::Web::Settings, the base class of server and plugin settings pages.
# Real API (Slim/Web/Settings.pm), all class methods a subclass overrides:
#   name()                      string token of the page name (default '')
#   page()                      template path, e.g. 'plugins/<Name>/settings/basic.html' (default '')
#   prefs($client)              ($prefsNamespaceObject, @prefNames) handled by the page (default ())
#   needsClient()               1 for player settings pages (default 0)
#   validFor($client)           player pages: whether the page applies to $client (default 1)
#   beforeRender($paramRef, $client)
#   handler($client, $paramRef, $pageSetup, $httpClient, $response)
#       with saveSettings set, stores each $paramRef->{"pref_<name>"} through the prefs object;
#       then fills $paramRef->{prefs}->{"pref_<name>"} and renders page() with $paramRef
# Class->new registers the page with the web server (Slim::Web::Pages->addPageFunction /
# addPageLinks) and returns nothing useful. Plugins call it from initPlugin under main::WEBUI.
#
# Here new() records the class in @REGISTERED, and handler() does the simple pref round trip
# above and returns page() instead of rendered HTML.

use strict;
use warnings;

our @REGISTERED;    # classes that called new(), in order

sub new {
	my $class = shift;
	push @REGISTERED, $class;
	return;
}

sub name         { '' }
sub page         { '' }
sub prefs        { return () }
sub needsClient  { 0 }
sub validFor     { 1 }
sub beforeRender { return }

sub handler {
	my ( $class, $client, $paramRef ) = @_;
	$paramRef ||= {};

	my ( $prefs, @names ) = $class->prefs($client);

	for my $name (@names) {
		$prefs->set( $name, $paramRef->{"pref_$name"} ) if $paramRef->{saveSettings};
		$paramRef->{prefs}->{"pref_$name"} = $prefs->get($name);
	}

	$paramRef->{page} = $class->name;

	return $class->page;
}

# test helper
sub reset { @REGISTERED = (); return }

1;
