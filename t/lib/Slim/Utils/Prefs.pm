package Slim::Utils::Prefs;

# Test stub for LMS Slim::Utils::Prefs.
# Real API: preferences($namespace) returns a Slim::Utils::Prefs::Namespace with
# get/set/init/exists/remove, client($client), setChange, setValidate and migrate.
# This stub keeps values in memory, one hash per namespace.

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT = qw(preferences);

my %namespaces;

sub preferences {
	my $namespace = shift;
	return $namespaces{$namespace} ||= Slim::Utils::Prefs::Namespace->new($namespace);
}

# test helper: forget every namespace
sub reset { %namespaces = () }

package Slim::Utils::Prefs::Namespace;

sub new {
	my ( $class, $namespace ) = @_;
	return bless { namespace => $namespace, prefs => {}, clients => {} }, $class;
}

sub get    { $_[0]->{prefs}->{ $_[1] } }
sub exists { exists $_[0]->{prefs}->{ $_[1] } }
sub remove { delete $_[0]->{prefs}->{ $_[1] } }

sub set {
	my ( $self, $pref, $value ) = @_;
	$self->{prefs}->{$pref} = $value;
	return $value;
}

sub init {
	my ( $self, $defaults ) = @_;
	for my $pref ( keys %{ $defaults || {} } ) {
		$self->{prefs}->{$pref} = $defaults->{$pref} unless exists $self->{prefs}->{$pref};
	}
	return;
}

sub client {
	my ( $self, $client ) = @_;
	my $id = ref $client && $client->can('id') ? $client->id : "$client";
	return $self->{clients}->{$id} ||= Slim::Utils::Prefs::Namespace->new( $self->{namespace} . ":$id" );
}

sub setChange   { return }
sub setValidate { return }
sub migrate     { return }

1;
