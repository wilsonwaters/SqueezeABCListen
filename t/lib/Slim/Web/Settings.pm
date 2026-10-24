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
#       with saveSettings set, stores each $paramRef->{"pref_<name>"} through the prefs object
#       (for EVERY name in prefs(), so a field the POST leaves out is set to undef), falling back
#       to an unprefixed $paramRef->{<name>} (logged as a template error); a value set() rejects
#       adds 'Invalid value "<value>" for <name><br/>' (SETTINGS_INVALIDVALUE, the value not
#       escaped) to $paramRef->{warning} and validated-><name> = 0, an accepted one sets
#       validated-><name> = 1; then fills $paramRef->{prefs}->{"pref_<name>"} and renders page()
#       with $paramRef
# Class->new registers the page with the web server (Slim::Web::Pages->addPageFunction /
# addPageLinks) and returns nothing useful. Plugins call it from initPlugin under main::WEBUI.
#
# Here new() records the class in @REGISTERED, and handler() does the pref round trip above
# (warning in the EN text; an undef value shows as "") and returns page() instead of rendered
# HTML. Core's "Changes saved" message and the rescan prompt are not modelled.

use strict;
use warnings;

our @REGISTERED;    # classes that called new(), in order
our @LEGACY;        # pref names handler() took from an unprefixed field (core logs an error)

my $INVALID_VALUE = 'Invalid value "%s" for %s';    # core's SETTINGS_INVALIDVALUE (EN)

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
		if ( $paramRef->{saveSettings} ) {
			if ( !defined $paramRef->{"pref_$name"} && defined $paramRef->{$name} ) {
				push @LEGACY, $name;
				$paramRef->{"pref_$name"} = $paramRef->{$name};
			}

			my ( undef, $ok ) = $prefs->set( $name, $paramRef->{"pref_$name"} );

			if ($ok) {
				$paramRef->{validated}->{$name} = 1;
			}
			else {
				$paramRef->{warning} .= sprintf( $INVALID_VALUE, $paramRef->{"pref_$name"} // '', $name ) . '<br/>';
				$paramRef->{validated}->{$name} = 0;
			}
		}
		$paramRef->{prefs}->{"pref_$name"} = $prefs->get($name);
	}

	$paramRef->{page} = $class->name;

	return $class->page;
}

# test helper
sub reset { @REGISTERED = (); @LEGACY = (); return }

1;
