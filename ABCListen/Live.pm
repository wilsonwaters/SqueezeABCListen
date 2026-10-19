package Plugins::ABCListen::Live;

# Live radio hook (hook API: see Plugin.pm). F1 vertical slice: one top-level "Radio" link holding
# the five national networks.
#
# Since F2 the station items (url and favorites_url) are the stable abclisten://live/<ID> URLs
# (Plugins::ABCListen::Util::liveUrl), and init registers the `live` kind with the protocol handler
# (Plugins::ABCListen::ProtocolHandler->registerKind): at play time it resolves the id to ABC's
# plain StreamGuys Icecast stream (HE-AAC), the live stream Lyrion plays natively everywhere (ABC's
# HLS streams need a third-party plugin), and its metadata is the station name and image.
#
# The stations are a small table keyed by PAPI/BFF service id; L1 replaces the table, the live
# kind's resolve/metadata and its registration with the full station catalogue.
# Logos: only a crop-param wcms URL is usable (a bare wcms hash returns a 1x1 image), and only
# Radio National has one at hand before L1, so the others use the plugin icon.
#
# Owned by the live stream (L1) after F2.

use strict;
use warnings;

use Slim::Utils::Strings qw(cstring);

use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Util;

# The stream for a station's mount, used only by the live kind's resolve.
use constant ICECAST_URL => 'https://abc.streamguys1.com/live/%s/icecast.audio';

my %STATIONS = (
	TRIPLEJ => { name => 'triple j',       mount => 'triplejnsw' },
	DOUBLEJ => { name => 'Double J',       mount => 'doublejnsw' },
	RN      => {
		name  => 'Radio National',
		mount => 'rnnsw',
		logo  => 'https://live-production.wcms.abc-cdn.net.au/556166359443f9aaa26ce7b905c4a29f?impolicy=wcms_crop_resize&cropH=500&cropW=500&xPos=0&yPos=0&width=862&height=862',
	},
	CLASSIC => { name => 'ABC Classic',    mount => 'classicfmnsw' },    # not the HLS slug "classicnsw"
	JAZZ    => { name => 'ABC Jazz',       mount => 'abcjazz' },
);

# Menu order
my @ORDER = qw(TRIPLEJ DOUBLEJ RN CLASSIC JAZZ);

sub init {
	Plugins::ABCListen::ProtocolHandler->registerKind(
		live => {
			resolve  => \&_resolve,
			metadata => \&_metadata,
		}
	);

	return;
}

# live kind: abclisten://live/<ID> -> the station's Icecast stream.
sub _resolve {
	my ( $client, $id, $cb ) = @_;

	my $station = defined $id && $STATIONS{$id} or return $cb->( { error => 'PLUGIN_ABCLISTEN_UNAVAILABLE' } );

	$cb->( { url => sprintf( ICECAST_URL, $station->{mount} ) } );
}

# live kind: the station name and image (synchronous, no network).
sub _metadata {
	my ( $client, $url, $id ) = @_;

	my $station = defined $id && $STATIONS{$id} or return {};

	return {
		title  => $station->{name},
		artist => Plugins::ABCListen::Util::DISPLAY_NAME,
		cover  => _image($station),
	};
}

# The top-level "Radio" item sorts at the "radio" weight (see Plugin.pm, Util::topWeight).
sub menuWeights { Plugins::ABCListen::Util::topWeight('radio') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_RADIO' ),
		type   => 'link',
		image  => Plugins::ABCListen::Util::ICON,
		items  => [ map { _stationItem($_) } @ORDER ],
		weight => Plugins::ABCListen::Util::topWeight('radio'),
	} ] );
}

# A playable station; favourites keep the abclisten:// URL and the station's image.
sub _stationItem {
	my $id      = shift;
	my $station = $STATIONS{$id};
	my $url     = Plugins::ABCListen::Util::liveUrl($id);
	my $image   = _image($station);

	return {
		name           => $station->{name},
		type           => 'audio',
		on_select      => 'play',
		url            => $url,
		favorites_url  => $url,
		image          => $image,
		favorites_icon => $image,
	};
}

sub _image { $_[0]->{logo} || Plugins::ABCListen::Util::ICON }

1;
