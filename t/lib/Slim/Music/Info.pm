package Slim::Music::Info;

# Test stub for LMS Slim::Music::Info: the remote-stream metadata helpers.
# Real API:
#   setCurrentTitle($url, $title, $client)   getCurrentTitle($client, $url)
#   setRemoteMetadata($url, \%meta)          (ignored for non-remote URLs)
#   setDelayedCallback($client, $cb, $outputDelayOnly)  (runs $cb after the player's buffer delay)
#   isRemoteURL($url)
#   setCurrentTitleChangeCallback(\&cb) / clearCurrentTitleChangeCallback(\&cb)
# Values are kept in %CURRENT_TITLE / %REMOTE_METADATA; delayed callbacks run at once.
# As in LMS, setCurrentTitle calls every change callback as cb->($url, $title) when the title
# changes, before storing it; the arguments alias setCurrentTitle's own variables. Each
# setCurrentTitle call is recorded in @TITLE_CALLS as { url, title, client } (title as called).

use strict;
use warnings;

our %CURRENT_TITLE;
our %REMOTE_METADATA;
our %TITLE_CALLBACKS;
our @TITLE_CALLS;

sub setCurrentTitle {
	my ( $url, $title, $client ) = @_;
	push @TITLE_CALLS, { url => $url, title => $title, client => $client };

	my $old = getCurrentTitle( $client, $url );
	if ( ( defined $old ? $old : '' ) ne ( $title || '' ) ) {
		for my $cb ( values %TITLE_CALLBACKS ) {
			&$cb( $url, $title );
		}
	}

	$CURRENT_TITLE{$url} = $title;
	return;
}

sub setCurrentTitleChangeCallback {
	my $cb = shift;
	return 0 unless ref $cb eq 'CODE';
	$TITLE_CALLBACKS{$cb} = $cb;
	return 1;
}

sub clearCurrentTitleChangeCallback {
	my $cb = shift or return;
	delete $TITLE_CALLBACKS{$cb};
	return;
}

sub getCurrentTitle {
	my ( $client, $url ) = @_;
	return undef unless $url;
	return $CURRENT_TITLE{$url};
}

sub setRemoteMetadata {
	my ( $url, $meta ) = @_;
	return unless isRemoteURL($url);
	$REMOTE_METADATA{$url} = { %{ $REMOTE_METADATA{$url} || {} }, %{ $meta || {} } };
	return;
}

sub setDelayedCallback {
	my ( $client, $cb ) = @_;
	$cb->() if $cb;
	return;
}

sub isRemoteURL {
	my $url = shift;
	return defined $url && $url =~ m{^[a-z][a-z0-9+.\-]*://}i && $url !~ m{^(?:file|db|tmp)://}i ? 1 : 0;
}

# test helper
sub reset { %CURRENT_TITLE = (); %REMOTE_METADATA = (); %TITLE_CALLBACKS = (); @TITLE_CALLS = (); return }

1;
