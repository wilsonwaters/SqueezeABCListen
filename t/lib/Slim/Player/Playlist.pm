package Slim::Player::Playlist;

# Test stub for LMS Slim::Player::Playlist.
# Real API: track($client, $index) returns the playlist entry at $index (default: the playing
# song), a track object or a URL string; url($client, $index) returns that entry's URL:
# $track->url for a track object, else the string itself; count($client).
# Tests set %PLAYLISTS{$clientId} = [ URLs and/or objects with a url method ] and optionally
# %INDEX{$clientId}.

use strict;
use warnings;

use Scalar::Util qw(blessed);

our %PLAYLISTS;
our %INDEX;

sub count {
	my $client = shift;
	return scalar @{ $PLAYLISTS{ _id($client) } || [] };
}

sub track {
	my ( $client, $index ) = @_;
	my $id = _id($client);
	$index = $INDEX{$id} || 0 unless defined $index;
	return ( $PLAYLISTS{$id} || [] )->[$index];
}

sub url {
	my $objOrUrl = track(@_);
	return blessed($objOrUrl) && $objOrUrl->can('url') ? $objOrUrl->url : $objOrUrl;
}

# test helper
sub reset { %PLAYLISTS = (); %INDEX = (); return }

sub _id {
	my $client = shift;
	return '' unless defined $client;
	return ref $client && $client->can('id') ? $client->id : "$client";
}

1;
