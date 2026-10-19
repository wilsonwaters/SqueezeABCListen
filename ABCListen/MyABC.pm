package Plugins::ABCListen::MyABC;

# My ABC listen hook (hook API: see Plugin.pm): settings page, home state, followed programs.
# M1: the settings page (Plugins::ABCListen::Settings) and the homeState pref; no menu items yet (M2).
# Owned by the myabc stream (M1, then M2).
#
# homeState (contract 8 in ai-state/streams.md): '' (not set; consumers behave as NSW) or exactly
# one of ACT NSW NT QLD SA TAS VIC WA. Read by live radio (L1) and schedules (L4).

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

my %HOME_STATES = map { $_ => 1 } qw(ACT NSW NT QLD SA TAS VIC WA);

sub init {
	$prefs->init( { homeState => '' } );
	$prefs->setValidate( { validator => \&validateHomeState }, 'homeState' );

	if (main::WEBUI) {
		eval {
			require Plugins::ABCListen::Settings;
			Plugins::ABCListen::Settings->new;
			1;
		} or $log->error( 'Could not create the ABC listen settings page: ' . ( $@ || 'unknown error' ) );
	}

	return;
}

# Prefs validator for homeState, called by LMS as ($pref, $new, \%params, $old, $client): true for ''
# or one of the upper-case state codes. Anything else is rejected, including undef: the pref layer
# does not map undef to '', so a save without the field leaves homeState unchanged.
sub validateHomeState {
	my ( $pref, $new ) = @_;
	return 0 if !defined $new || ref $new;
	return ( $new eq '' || $HOME_STATES{$new} ) ? 1 : 0;
}

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;
	$cb->( [] );
}

1;
