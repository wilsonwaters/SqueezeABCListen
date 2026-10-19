package Slim::Utils::Cache;

# Test stub for LMS Slim::Utils::Cache.
# Real API: Slim::Utils::Cache->new($namespace, $version, $noPeriodicPurge) returns one shared
# instance per namespace (default namespace 'cache'); ->set($key, $data, $expires),
# ->get($key), ->remove($key), ->clear. Data is Storable-serialised, so get() returns a copy
# and coderefs can't be stored.
#
# This stub keeps entries in memory, deep-copies them on set and get (like the real
# serialisation) and honours expiry using time(), so the ABCListenTest fake clock works.

use strict;
use warnings;

use Storable qw(dclone);

use constant DEFAULT_NAMESPACE => 'cache';

my %caches;

my %UNITS = (
	s => 1, sec => 1, secs => 1, second => 1, seconds => 1,
	m => 60, min => 60, mins => 60, minute => 60, minutes => 60,
	h => 3600, hour => 3600, hours => 3600,
	d => 86400, day => 86400, days => 86400,
	w => 604800, week => 604800, weeks => 604800,
);

use constant DEFAULT_EXPIRES => 3600;

sub new {
	my ( $class, $namespace, $version ) = @_;
	$namespace ||= DEFAULT_NAMESPACE;

	return $caches{$namespace} ||= bless {
		namespace => $namespace,
		version   => $version || 0,
		data      => {},
	}, $class;
}

sub namespace { $_[0]->{namespace} }

sub set {
	my ( $self, $key, $data, $expires ) = @_;

	$self->{data}->{$key} = {
		value  => ref $data ? dclone($data) : $data,
		expiry => _expiry($expires),
	};

	return;
}

sub get {
	my ( $self, $key ) = @_;

	my $entry = $self->{data}->{$key} or return undef;

	if ( $entry->{expiry} >= 0 && $entry->{expiry} < time() ) {
		return undef;
	}

	return ref $entry->{value} ? dclone( $entry->{value} ) : $entry->{value};
}

sub remove { delete $_[0]->{data}->{ $_[1] }; return }
sub clear  { $_[0]->{data} = {}; return }
sub purge  { return }

# test helper: drop every namespace
sub resetAll { %caches = () }

# Same rules as Slim::Utils::DbCache::_canonicalize_expiration_time: 'now', 'never', seconds
# or "<n> <unit>"; values up to 30 days are relative to now, larger ones absolute epochs.
sub _expiry {
	my $expires = shift;
	$expires = DEFAULT_EXPIRES unless defined $expires;

	if    ( lc $expires eq 'now' )   { $expires = 0 }
	elsif ( lc $expires eq 'never' ) { $expires = -1 }
	elsif ( $expires =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*$/ ) { $expires = $1 }
	elsif ( $expires =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*(\w*)\s*$/ && $UNITS{$2} ) {
		$expires = time() + $UNITS{$2} * $1;
	}
	else { $expires = DEFAULT_EXPIRES }

	$expires += time() if $expires <= 2592000 && $expires > -1;

	return $expires;
}

1;
