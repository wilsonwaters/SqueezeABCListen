package Slim::Utils::Prefs;

# Test stub for LMS Slim::Utils::Prefs.
# Real API: preferences($namespace) returns a Slim::Utils::Prefs::Namespace with
# get/set/init/exists/remove, client($client), setChange, setValidate and migrate.
# This stub keeps values in memory, one hash per namespace.
#
# Validators work as in core (Slim/Utils/Prefs/Namespace.pm setValidate, Base.pm validate/set):
# setValidate({ validator => \&code, ... }, @prefs) or setValidate(\&code, @prefs) registers a
# callback, called as $code->($pref, $new, \%params, $old, undef). set() skips validation when a
# scalar value is unchanged, otherwise stores the value only if the validator accepts it and, in
# list context, returns ($new, 1) when stored or ($old, 0) when rejected. hasValidator($pref),
# validate($pref, $new) and namespace() as in core. (Only CODE validators, not core's named ones.)

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
	my $old = $self->{prefs}->{$pref};

	# unchanged scalar: nothing to do (core does not validate it either)
	if ( ( !defined $value && !defined $old ) || ( !ref $value && defined $value && defined $old && $value eq $old ) ) {
		return wantarray ? ( $value, 1 ) : $value;
	}

	return wantarray ? ( $old, 0 ) : $old unless $self->validate( $pref, $value );

	$self->{prefs}->{$pref} = $value;
	return wantarray ? ( $value, 1 ) : $value;
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

sub setChange { return }
sub migrate   { return }

sub setValidate {
	my ( $self, $args, @prefs ) = @_;
	my ( $validator, $params ) = ref $args eq 'HASH' ? ( $args->{validator}, $args ) : ( $args, undef );
	return unless ref $validator eq 'CODE';
	for my $pref (@prefs) {
		$self->{validators}->{$pref} = $validator;
		$self->{validparam}->{$pref} = $params if $params;
	}
	return;
}

sub hasValidator { $_[0]->{validators}->{ $_[1] } ? 1 : 0 }

sub validate {
	my ( $self, $pref, $new ) = @_;
	my $validator = $self->{validators}->{$pref} or return 1;
	return $validator->( $pref, $new, $self->{validparam}->{$pref}, $self->{prefs}->{$pref}, undef );
}

sub namespace { $_[0]->{namespace} }

1;
