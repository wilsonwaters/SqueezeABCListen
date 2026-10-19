package Plugins::ABCListen::Plugin;

# ABC listen for Lyrion Music Server: registers the "ABC listen" entry in the Radio menu and the
# abclisten:// protocol handler (Plugins::ABCListen::ProtocolHandler).
#
# Hook API (frozen: feature tasks never edit this file). The hook classes, in menu order, are
#   Plugins::ABCListen::Live, ::OnDemand, ::Discover, ::Search, ::MyABC
# and each implements:
#
#   Class->init()
#       Called once from initPlugin, in hook order. The module is loaded with require just before,
#       so a module that fails to compile only breaks its own items. If loading or init dies, the
#       error is logged and the plugin still loads; the other hooks are initialised as usual.
#
#   Class->menuItems($client, $cb, $args)
#       Called for every top-level menu request, for all hooks at once, in hook order. $client may
#       be undef (web UI without a player, CLI "-"). Must call $cb->(\@items) exactly once,
#       synchronously or later, even on error. The top-level menu is the hooks' items
#       concatenated in hook order. A hook that dies (or has no menuItems because its module did
#       not load) or calls back with anything but an array ref contributes a single error text
#       item (PLUGIN_ABCLISTEN_ERROR) instead; a second call back is ignored. A hook that has not
#       called back within HOOK_TIMEOUT (25) seconds also contributes a single error text item, so
#       the menu still loads; its late call back is ignored. Every request has its own join state.
#
# Each hook owns its module, its strings.txt section and its t/ tests (see ai-state/streams.md).

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Time::HiRes ();

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

# Seconds to wait for the hooks before answering the top-level menu without the missing ones.
# Must stay below the 35 s timeout Slim::Control::XMLBrowser gives a feed.
use constant HOOK_TIMEOUT => 25;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.abclisten',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_ABCLISTEN',
} );

# Hook classes, in menu order. Loaded at runtime so a broken module only breaks its own items.
my @HOOKS = map {"Plugins::ABCListen::$_"} qw(Live OnDemand Discover Search MyABC);

sub initPlugin {
	my $class = shift;

	# abclisten://live/<ID> and abclisten://episode/<id> (Plugins::ABCListen::Util URL contract)
	eval {
		require Plugins::ABCListen::ProtocolHandler;
		Slim::Player::ProtocolHandlers->registerHandler( abclisten => 'Plugins::ABCListen::ProtocolHandler' );
		1;
	} or $log->error( 'Could not register the abclisten:// protocol handler: ' . ( $@ || 'unknown error' ) );

	for my $hook (@HOOKS) {
		eval {
			( my $file = "$hook.pm" ) =~ s{::}{/}g;
			require $file;
			$hook->init();
			1;
		} or $log->error( "$hook init failed: " . ( $@ || 'unknown error' ) );
	}

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'abclisten',
		menu   => 'radios',
		is_app => 0,
		weight => 10,
	);
}

sub getDisplayName { 'PLUGIN_ABCLISTEN' }

sub playerMenu { 'RADIO' }

# Top-level feed: ask every hook for its items (all requests start at once), wait for all of
# them (at most HOOK_TIMEOUT seconds), then call $cb once with the items in hook order.
# $cb is never called from inside a hook call, so an error in $cb is not blamed on a hook.
sub toplevel {
	my ( $client, $cb, $args ) = @_;

	my @results;
	my $pending     = scalar @HOOKS;
	my $dispatching = 1;    # still inside the loop that calls the hooks
	my $done        = 0;    # $cb has been called
	my $timer;

	my $finish = sub {
		return if $done++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		$cb->( { items => [ map { @$_ } @results ] } );
	};

	for my $i ( 0 .. $#HOOKS ) {
		my $hook   = $HOOKS[$i];
		my $called = 0;

		my $hookCb = sub {
			my $items = shift;

			if ( $called++ ) {
				$log->warn("$hook->menuItems called back more than once; ignoring the extra call");
				return;
			}

			if ($done) {
				$log->warn( "$hook->menuItems called back after the " . HOOK_TIMEOUT . ' s timeout; ignoring it' );
				return;
			}

			if ( ref $items ne 'ARRAY' ) {
				$log->error( "$hook->menuItems called back with " . ( defined $items ? ( ref $items || 'a scalar' ) : 'undef' ) . ' instead of an array ref' );
				$items = [ _errorItem($client) ];
			}

			$results[$i] = $items;

			$finish->() if --$pending == 0 && !$dispatching;
		};

		eval {
			$hook->menuItems( $client, $hookCb, $args );
			1;
		} or do {
			my $error = $@ || 'unknown error';
			$log->error("$hook->menuItems failed: $error");
			$hookCb->( [ _errorItem($client) ] ) unless $called;
		};
	}

	$dispatching = 0;

	if ( $pending == 0 ) {
		$finish->();
		return;
	}

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + HOOK_TIMEOUT, sub {
		undef $timer;

		for my $i ( grep { !$results[$_] } 0 .. $#HOOKS ) {
			$log->error( "$HOOKS[$i]->menuItems did not call back within " . HOOK_TIMEOUT . ' s' );
			$results[$i] = [ _errorItem($client) ];
		}

		$finish->();
	} );

	return;
}

sub _errorItem {
	my $client = shift;

	return {
		name => cstring( $client, 'PLUGIN_ABCLISTEN_ERROR' ),
		type => 'text',
	};
}

1;
