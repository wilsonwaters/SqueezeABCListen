package ABCListenTest::FakeClient;

# A fake LMS player (Slim::Player::Client) for tests, with the methods the live metadata code
# uses, and its playing song (ABCListenTest::FakeSong).
#
#   my $player = ABCListenTest::FakeClient->new('00:00:00:00:00:01');   # playing, with a song
#   my $slave  = $player->makeSlave('00:00:00:00:00:02');           # $slave->master == $player
#   $player->mode('pause');            # 'play' (default), 'pause' or 'stop'
#   $player->setSong(undef);           # no playing song
#
# Real API (Slim/Player/Client.pm): id, master (the sync group's master, or the player
# itself), isPlaying, isPaused, isStopped, playingSong, currentPlaylistUpdateTime([$time]),
# pluginData($key[, $value]) namespaced by the calling plugin (Plugins::<Name>::...).
# A slave answers isPlaying/isPaused/playingSong for its master, as in LMS.
#
# Recorded for tests:
#   @ABCListenTest::FakeClient::EVENTS   [ currentPlaylistUpdateTime => $client, $time ] and
#                                    [ pluginData => $song, $key, $value ] (song writes), in order
#   $player->updateTimes             every currentPlaylistUpdateTime($time) value set
#   $song->calls('duration')         every call of $song->duration / startOffset (with args)

use strict;
use warnings;

our @EVENTS;

sub new {
	my ( $class, $id, %args ) = @_;

	return bless {
		id          => $id,
		mode        => $args{mode} || 'play',
		song        => exists $args{song} ? $args{song} : ABCListenTest::FakeSong->new,
		masterOf    => undef,
		pluginData  => {},
		updateTimes => [],
		updateTime  => undef,
	}, $class;
}

sub makeSlave {
	my ( $self, $id ) = @_;
	my $slave = ref($self)->new( $id, song => undef );
	$slave->{masterOf} = $self;
	return $slave;
}

sub id     { $_[0]->{id} }
sub master { $_[0]->{masterOf} || $_[0] }

sub mode {
	my ( $self, $mode ) = @_;
	$self->{mode} = $mode if defined $mode;
	return $self->master->{mode};
}

sub isPlaying { $_[0]->mode eq 'play' ? 1 : 0 }
sub isPaused  { $_[0]->mode eq 'pause' ? 1 : 0 }
sub isStopped { $_[0]->mode eq 'stop' ? 1 : 0 }

sub setSong     { $_[0]->{song} = $_[1]; return }
sub playingSong { $_[0]->master->{song} }

sub currentPlaylistUpdateTime {
	my $self = shift;
	if (@_) {
		$self->{updateTime} = shift;
		push @{ $self->{updateTimes} }, $self->{updateTime};
		push @EVENTS, [ currentPlaylistUpdateTime => $self, $self->{updateTime} ];
	}
	return $self->{updateTime};
}

sub updateTimes { @{ $_[0]->{updateTimes} } }

# namespaced like Slim::Player::Client::pluginData
sub pluginData {
	my ( $self, $key, $value ) = @_;

	my ($namespace) = caller(0) =~ /^(?:Slim::Plugin|Plugins)::(\w+)/;
	my $store = $namespace ? ( $self->{pluginData}{$namespace} ||= {} ) : $self->{pluginData};

	return $store unless defined $key;
	$store->{$key} = $value if defined $value;
	return $store->{$key};
}

sub resetEvents { @EVENTS = (); return }

package ABCListenTest::FakeSong;

# A fake Slim::Player::Song: pluginData($key[, $value]) (not namespaced, as in LMS), and
# duration/startOffset calls recorded (the live metadata must never make them).

sub new { bless { pluginData => {}, calls => {} }, shift }

sub pluginData {
	my ( $self, $key, $value ) = @_;
	return $self->{pluginData} unless defined $key;
	if ( defined $value ) {
		$self->{pluginData}{$key} = $value;
		push @ABCListenTest::FakeClient::EVENTS, [ pluginData => $self, $key, $value ];
	}
	return $self->{pluginData}{$key};
}

sub duration    { my $self = shift; push @{ $self->{calls}{duration} },    [@_]; return undef }
sub startOffset { my $self = shift; push @{ $self->{calls}{startOffset} }, [@_]; return undef }

sub calls { @{ $_[0]->{calls}{ $_[1] } || [] } }

1;
