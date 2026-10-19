package ABCListenTest;

# Shared test helpers for the ABC listen plugin. Load it first in every test (before any plugin
# module), because it:
#   * defines the LMS build constants main::DEBUGLOG, main::INFOLOG, main::WEBUI, main::SCANNER;
#   * installs a fake clock: time() and Time::HiRes::time() return real time until setTime() is
#     called, then the fake time (advanceTime() also fires due Slim::Utils::Timers timers);
#   * loads fixtures from t/data and registers them as SimpleAsyncHTTP responses (route());
#   * provides a callback collector that records every call and its arguments.
#
# Plugin modules load from ABCListen/ through the t/lib/Plugins/ABCListen symlink.
#
#   use ABCListenTest qw(:all);
#   route(qr{/core-next/api/collection}, file => 'foundation/collection.json', headers => { 'Content-Type' => 'text/plain' });
#   my $c = collector();
#   Plugins::ABCListen::HTTP::getJSON($url, $c->cb, $c->cb);

use strict;
use warnings;

BEGIN {
	package main;
	use constant DEBUGLOG => 1;
	use constant INFOLOG  => 1;
	use constant WEBUI    => 1;
	use constant SCANNER  => 0;
}

# ---- fake clock ----

our $NOW;    # undef: real time

BEGIN {
	no warnings 'redefine';
	*CORE::GLOBAL::time = sub () { defined $ABCListenTest::NOW ? int($ABCListenTest::NOW) : CORE::time() };

	require Time::HiRes;
	my $realHiRes = \&Time::HiRes::time;
	*Time::HiRes::time = sub () { defined $ABCListenTest::NOW ? $ABCListenTest::NOW : $realHiRes->() };
}

use File::Basename qw(dirname);
use File::Spec;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Timers;

use Exporter qw(import);
our @EXPORT_OK = qw(
	fixture fixturePath route requests
	collector
	setTime advanceTime clearTime runTimers
	resetStubs
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

my $DATA_DIR = File::Spec->catdir( dirname(__FILE__), '..', 'data' );

sub setTime   { $NOW = shift; return $NOW }
sub clearTime { $NOW = undef; return }

# Move the fake clock forward and fire the timers that became due. Returns how many fired.
sub advanceTime {
	my $secs = shift || 0;
	$NOW = CORE::time() unless defined $NOW;
	$NOW += $secs;
	return Slim::Utils::Timers->fireDue($NOW);
}

sub runTimers { Slim::Utils::Timers->fireDue( defined $NOW ? $NOW : Time::HiRes::time() ) }

# ---- fixtures and fake HTTP ----

sub fixturePath { File::Spec->catfile( $DATA_DIR, split m{/}, shift ) }

# Raw bytes of t/data/<relative path>.
sub fixture {
	my $path = fixturePath(shift);
	open( my $fh, '<:raw', $path ) or die "Can't open fixture $path: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# route($match, code => 200, headers => {...}, content => '...' | file => 'dir/name', error => '...')
sub route {
	my ( $match, %response ) = @_;
	$response{content} = fixture( delete $response{file} ) if $response{file};
	Slim::Networking::SimpleAsyncHTTP->addRoute( $match, \%response );
	return;
}

sub requests { Slim::Networking::SimpleAsyncHTTP->requests }

# Reset the recorded state of every stub that has been loaded.
sub resetStubs {
	for my $class (qw(
		Slim::Networking::SimpleAsyncHTTP Slim::Utils::Timers Slim::Formats::RemoteMetadata
		Slim::Player::ProtocolHandlers Slim::Player::Playlist Slim::Utils::Scanner::Remote
		Slim::Music::Info Slim::Control::Request Slim::Menu::TrackInfo Slim::Utils::Prefs
		Slim::Menu::GlobalSearch Slim::Web::Settings
	)) {
		$class->reset if $class->can('reset');
	}
	Slim::Utils::Cache->resetAll if Slim::Utils::Cache->can('resetAll');
	Slim::Utils::Log->resetMessages if Slim::Utils::Log->can('resetMessages');
	return;
}

# ---- callback collector ----

sub collector { ABCListenTest::Collector->new }

package ABCListenTest::Collector;

sub new { bless { calls => [] }, shift }

# A coderef that records its arguments each time it is called.
sub cb {
	my $self = shift;
	return sub { push @{ $self->{calls} }, [@_]; return };
}

sub count { scalar @{ $_[0]->{calls} } }
sub calls { @{ $_[0]->{calls} } }

# Arguments of call $i (default: the first call).
sub args {
	my ( $self, $i ) = @_;
	return @{ $self->{calls}->[ $i || 0 ] || [] };
}

1;
