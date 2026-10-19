package Slim::Player::Protocols::HTTP;

# Test stub for LMS Slim::Player::Protocols::HTTP (remote stream protocol handler base class).
# Only the class-level methods plugins override or call are here, with the real signatures:
#   new(\%args) {url, song, client, redir}        isRemote()
#   scanUrl($url, \%args) -> Slim::Utils::Scanner::Remote->scanURL($url, \%args)
#   getMetadataFor($client, $url, $forceCurrent) -> provider result or {}
#   canSeek($client, $song) -> true when the song has bitrate and duration
#   canDirectStream($client, $url, $inType)      getIcon($url, $noFallback)
# No sockets are opened.

use strict;
use warnings;

use Slim::Formats::RemoteMetadata;
use Slim::Utils::Scanner::Remote;

sub new {
	my ( $class, $args ) = @_;
	return undef unless $args && $args->{song};
	return bless { %$args }, $class;
}

sub isRemote { 1 }

sub scanUrl {
	my ( $class, $url, $args ) = @_;
	Slim::Utils::Scanner::Remote->scanURL( $url, $args );
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	if ( my $provider = Slim::Formats::RemoteMetadata->getProviderFor($url) ) {
		my $meta = $provider->( $client, $url );
		return $meta if $meta && ref $meta eq 'HASH' && keys %$meta;
	}

	return {};
}

sub canSeek {
	my ( $class, $client, $song ) = @_;
	return ( $song && $song->bitrate && $song->duration ) ? 1 : 0;
}

sub canDirectStream {
	my ( $class, $client, $url ) = @_;
	return $url;
}

sub getIcon {
	my ( $class, $url, $noFallback ) = @_;
	return $noFallback ? '' : 'html/images/radio.png';
}

1;
