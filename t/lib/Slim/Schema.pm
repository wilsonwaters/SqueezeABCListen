package Slim::Schema;

# Test stub for LMS Slim::Schema: only updateOrCreate({ url => $url }) for remote URLs, which in LMS
# returns the Slim::Schema::RemoteTrack for the URL (one object per URL, kept in an LRU cache).
# Here: a Slim::Schema::RemoteTrack stand-in with the accessors plugins set on a scanned remote
# track. Slim::Schema->reset forgets the tracks (ABCListenTest::resetStubs calls it).

use strict;
use warnings;

our %TRACKS;

sub updateOrCreate {
	my ( $class, $args ) = @_;
	my $url = ref $args eq 'HASH' ? $args->{url} : undef;
	return undef unless defined $url && !ref $url;
	return $TRACKS{$url} ||= Slim::Schema::RemoteTrack->new($url);
}

sub reset { %TRACKS = (); return }

package Slim::Schema::RemoteTrack;

sub new { my ( $class, $url ) = @_; return bless { url => $url }, $class }

for my $field (qw(url title cover content_type bitrate samplerate channels vbr_scale redir secs)) {
	no strict 'refs';
	*$field = sub {
		my $self = shift;
		$self->{$field} = shift if @_;
		return $self->{$field};
	};
}

sub remote { 1 }

1;
