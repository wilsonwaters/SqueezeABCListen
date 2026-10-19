package Slim::Formats::RemoteMetadata;

# Test stub for LMS Slim::Formats::RemoteMetadata.
# Real API:
#   registerProvider(match => qr/.../, func => sub { my ($client, $url) = @_; return {...} })
#   registerParser(match => qr/.../, func => sub { my ($client, $url, $metadata) = @_; return 0|1 })
#   getProviderFor($url) / getParserFor($url): the func of the first registered regex that
#   matches (Tie::RegexpHash, registration order), or undef.
# Both register calls return undef (and log an error) unless match is a Regexp and func a CODE ref.

use strict;
use warnings;

our @PROVIDERS;    # [ $regex, $func ] in registration order
our @PARSERS;

sub init { }

sub registerProvider {
	my ( $class, %params ) = @_;
	return undef unless ref $params{match} eq 'Regexp' && ref $params{func} eq 'CODE';
	push @PROVIDERS, [ $params{match}, $params{func} ];
	return 1;
}

sub registerParser {
	my ( $class, %params ) = @_;
	return undef unless ref $params{match} eq 'Regexp' && ref $params{func} eq 'CODE';
	push @PARSERS, [ $params{match}, $params{func} ];
	return 1;
}

sub getProviderFor { _find( \@PROVIDERS, $_[1] ) }
sub getParserFor   { _find( \@PARSERS,   $_[1] ) }

# test helper
sub reset { @PROVIDERS = (); @PARSERS = (); return }

sub _find {
	my ( $list, $url ) = @_;
	return undef unless defined $url;
	for my $entry (@$list) {
		return $entry->[1] if $url =~ $entry->[0];
	}
	return undef;
}

1;
