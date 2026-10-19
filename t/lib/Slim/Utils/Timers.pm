package Slim::Utils::Timers;

# Test stub for LMS Slim::Utils::Timers.
# Real API: setTimer($obj, $when, \&code, @args) (also setHighTimer) schedules
# code->($obj, @args) at hi-res epoch $when; killTimers($obj, \&code) cancels every timer for
# that object/code pair and returns how many; killSpecific($timer) cancels one; forgetTimer($obj)
# cancels every timer for that object (Slim::Player::Client::forgetClient does this).
#
# Nothing fires by itself here. Tests call ABCListenTest::advanceTime()/runTimers(), or
# Slim::Utils::Timers->fireDue($now) directly, to run the timers that are due.

use strict;
use warnings;

our @TIMERS;    # pending timers, each { obj, when, code, args }

sub setTimer {
	my ( $obj, $when, $code, @args ) = @_;

	my $timer = bless { obj => $obj, when => $when, code => $code, args => \@args }, 'Slim::Utils::Timers::Timer';
	push @TIMERS, $timer;

	return $timer;
}

*setHighTimer = \&setTimer;

sub killTimers {
	my ( $obj, $code ) = @_;
	return 0 unless $code;

	$obj = '' unless defined $obj;

	my $before = @TIMERS;
	@TIMERS = grep { !( _sameObj( $_->{obj}, $obj ) && $_->{code} == $code ) } @TIMERS;

	return $before - @TIMERS;
}

sub forgetTimer {
	my $obj = shift;

	@TIMERS = grep { !_sameObj( $_->{obj}, $obj ) } @TIMERS;

	return;
}

sub killSpecific {
	my $timer = shift or return 0;

	my $before = @TIMERS;
	@TIMERS = grep { $_ != $timer } @TIMERS;

	return $before - @TIMERS;
}

# test helpers

sub pending { return @TIMERS }

sub reset { @TIMERS = () }

# Fire every timer due at or before $now, earliest first. Timers scheduled by a callback run in
# the same call if they are due too.
sub fireDue {
	my ( $class, $now ) = @_;
	my $fired = 0;

	while (1) {
		my ($next) = sort { $a->{when} <=> $b->{when} } grep { $_->{when} <= $now } @TIMERS;
		last unless $next;

		@TIMERS = grep { $_ != $next } @TIMERS;
		$next->{code}->( $next->{obj}, @{ $next->{args} } );
		$fired++;
	}

	return $fired;
}

sub _sameObj {
	my ( $x, $y ) = @_;
	$x = '' unless defined $x;
	return ref $x ? ( ref $y && $x == $y ) : ( !ref $y && $x eq $y );
}

package Slim::Utils::Timers::Timer;

sub when { $_[0]->{when} }

1;
