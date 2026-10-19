package Plugins::ABCListen::Discover;

# Discover hook (hook API: see Plugin.pm): the top-level "Home" item, ABC listen's home page.
# Data and cards come from Plugins::ABCListen::Collections (the collection engine); this module
# only lays out Home.
#
#   menuItems -> one link "Home" (PLUGIN_ABCLISTEN_HOME, weight Util::topWeight('home')), no
#                network I/O. menuWeights -> (topWeight('home')).
#   Home (_homeRoot): Collections->home ->
#     1. "Featured" (PLUGIN_ABCLISTEN_FEATURED): the hero carousel's items in carousel order
#        (Collections->itemsFor at level 1, inline); omitted when no hero item maps to an item;
#     2. one link per home collection, in page order (Collections->collectionItem at level 0:
#        ABC's title, the first supported card's image, else the plugin icon).
#     Nothing at all: one PLUGIN_ABCLISTEN_EMPTY_COLLECTION text item; the page fails (and no
#     last-good copy is cached): one text item with the error token's text (LOAD_FAILED).
#   Every feed calls back exactly once. Keys Home doesn't know in the page result are ignored.
#
# Ownership (ai-state/streams.md rule 5): D1 creates this; D2 owns Home's root list and adds the
# Podcasts item; D4 appends Sections->topItems / Sections->menuWeights to menuItems / menuWeights;
# D5 adds an Audiobooks->init call to init.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::ABCListen::Collections;
use Plugins::ABCListen::Util;

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

my $log = logger('plugin.abclisten');

sub init { return }

# The top-level "Home" item sorts at the "home" weight (see Plugin.pm, Util::topWeight).
sub menuWeights { Plugins::ABCListen::Util::topWeight('home') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_HOME' ),
		type   => 'link',
		url    => \&_homeRoot,
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight('home'),
	} ] );
}

# Home: Featured, then the home collections.
sub _homeRoot {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::Collections->home( sub {
			my $page = shift;

			return _textFeed( $client, $once, $page->{error} ) if $page->{error};

			_try( $client, $once, sub {
				Plugins::ABCListen::Collections->itemsFor( $client, $page->{hero}, 1, sub {
					my $featured = shift;
					_respond( $client, $once, sub { _homeItems( $client, $page, $featured ) } );
				} );
			} );
		} );
	} );

	return;
}

sub _homeItems {
	my ( $client, $page, $featured ) = @_;
	my @items;

	if (@$featured) {
		push @items, {
			name  => cstring( $client, 'PLUGIN_ABCLISTEN_FEATURED' ),
			type  => 'link',
			items => $featured,
			image => $featured->[0]->{image} || Plugins::ABCListen::Util::ICON,
		};
	}

	push @items, grep {defined} map { Plugins::ABCListen::Collections->collectionItem( $client, $_, 0 ) }
		@{ ref $page->{collections} eq 'ARRAY' ? $page->{collections} : [] };

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_ABCLISTEN_EMPTY_COLLECTION' ), type => 'text' } ];
}

# ---------------------------------------------------------------------------
# Feed helpers (every feed calls back exactly once)
# ---------------------------------------------------------------------------

# A callback wrapper that passes on only the first call.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub { $cb->(@_) unless $called++ };
}

# Run $code (which answers $cb itself); if it dies, answer $cb with the LOAD_FAILED item.
sub _try {
	my ( $client, $cb, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Building the ABC listen Home menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen Home menu failed: ' . ( $@ || 'unknown error' ) );
		return _textFeed( $client, $cb, LOAD_FAILED );
	}

	$cb->( { items => $items } );
	return;
}

# One text item for an error token (unknown or malformed tokens read as LOAD_FAILED).
sub _textFeed {
	my ( $client, $cb, $token ) = @_;
	$token = LOAD_FAILED unless defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/;
	$cb->( { items => [ { name => cstring( $client, $token ), type => 'text' } ] } );
	return;
}

1;
