package Plugins::ABCListen::Live;

# Live radio hook (hook API: see Plugin.pm). F1 vertical slice: one "Live radio" link holding the
# five national networks, played from ABC's plain StreamGuys Icecast streams (HE-AAC). These are
# the live streams Lyrion plays natively everywhere; ABC's HLS streams need a third-party plugin.
#
# The stations are a small table keyed by PAPI/BFF service id, so F2 can switch the URLs to
# Plugins::ABCListen::Util::liveUrl(<ID>); L1 replaces the table with the full station catalogue.
# Logos: only a crop-param wcms URL is usable (a bare wcms hash returns a 1x1 image), and only
# Radio National has one at hand before L1, so the others use the plugin icon.
#
# Owned by the live stream (L1) after F1; F2 edits this stub first.

use strict;
use warnings;

use Slim::Utils::Strings qw(cstring);

use Plugins::ABCListen::Util;

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

sub init { return }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name  => cstring( $client, 'PLUGIN_ABCLISTEN_LIVE_RADIO' ),
		type  => 'link',
		image => Plugins::ABCListen::Util::ICON,
		items => [ map { _stationItem($_) } @ORDER ],
	} ] );
}

# A playable station; favourites keep the stream URL and the station's image.
sub _stationItem {
	my $id      = shift;
	my $station = $STATIONS{$id};
	my $url     = sprintf( ICECAST_URL, $station->{mount} );
	my $image   = $station->{logo} || Plugins::ABCListen::Util::ICON;

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

1;
