package Plugins::ABCListen::Discover;

# Discover hook (hook API: see Plugin.pm): the top-level "Home" and "Podcasts" items, ABC listen's
# home and podcasts pages. Data and cards come from Plugins::ABCListen::Collections (the
# collection engine); this module only lays out the menus.
#
#   menuItems -> two links, then D4's News, Sport, Kids listen and Audiobooks links
#                (Sections->topItems, whose menus Sections.pm owns), no network I/O:
#                "Home"     (PLUGIN_ABCLISTEN_HOME,     weight Util::topWeight('home'))
#                "Podcasts" (PLUGIN_ABCLISTEN_PODCASTS, weight Util::topWeight('podcasts'))
#   menuWeights -> (topWeight('home'), topWeight('podcasts'), Sections->menuWeights).
#
#   Home (_homeRoot): Collections->home ->
#     1. "Featured" (PLUGIN_ABCLISTEN_FEATURED): the hero carousel's items in carousel order
#        (Collections->itemsFor at level 1, inline); omitted when no hero item maps to an item;
#     2. "Popular now" (PLUGIN_ABCLISTEN_POPULAR_NOW: ABC's "This Week's Most Listened",
#        recommendations homepagePopularNow) and
#     3. "Popular in sport" (PLUGIN_ABCLISTEN_POPULAR_SPORT, homepageSports): static links, nothing
#        is fetched until one is opened (_recommendationsMenu);
#     4. one link per home collection, in page order (Collections->collectionItem at level 0:
#        ABC's title, the first supported card's image, else the plugin icon), except the home
#        "Categories" collection (14123152): the categories live under Podcasts.
#     The page fails (and no last-good copy is cached): 2 and 3, then one text item with the
#     error token's text (LOAD_FAILED) in place of 1 and 4.
#   Popular now / Popular in sport (_recommendationsMenu): Collections->recommendations ->
#     itemsFor at level 1 (episode rows via OnDemand->episodeItem; recommendation cards have no
#     date, so rows are named by title). Nothing listable: PLUGIN_ABCLISTEN_EMPTY_COLLECTION; an
#     error: the token's text item.
#
#   Podcasts (_podcastsRoot): Collections->podcasts, then Collections->withImages on its
#   sub-collections (each link shows its first card's artwork; at most 3 s) ->
#     1. the podcasts page's collections in page order (New & Noteworthy, Most Popular Podcasts,
#        Award Winning Podcasts on 2026-10-19), as collectionItem links at level 0 (paged with
#        the MetaCollection query); none (page failed, MetaCollection missing): one text item
#        with the error token's text (LOAD_FAILED);
#     2. "Browse by category" (PLUGIN_ABCLISTEN_CATEGORIES), its items inline: one collectionItem
#        link per podcast category (level 1, image = the category card's, else the plugin icon),
#        from the podcasts page, else Collections->staticCategories. A category pages its page id
#        (collection/x), falling back to its page's first collection (fallbackPath);
#     3. "All podcasts A–Z" (PLUGIN_ABCLISTEN_PODCASTS_AZ): OnDemand->programsByType($client, $cb,
#        'podcast') (O3); only listed while OnDemand can('programsByType').
#   Every feed calls back exactly once. Keys the menus don't know in page results are ignored.
#
# Ownership (ai-state/streams.md rule 5): D1 creates this; D2 owns Home's root list and adds the
# Podcasts item; D4 appends Sections->topItems / Sections->menuWeights to menuItems / menuWeights;
# D5 adds an Audiobooks->init call to init.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::ABCListen::Collections;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Sections;
use Plugins::ABCListen::Util;

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant EMPTY       => 'PLUGIN_ABCLISTEN_EMPTY_COLLECTION';

# The home page's "Categories" collection: listed under Podcasts -> Browse by category instead.
use constant HOME_CATEGORIES_ID => '14123152';

my $log = logger('plugin.abclisten');

sub init { return }

# The top-level items sort at the "home" and "podcasts" weights (see Plugin.pm, Util::topWeight);
# D4's section items at theirs.
sub menuWeights { ( Plugins::ABCListen::Util::topWeight('home'), Plugins::ABCListen::Util::topWeight('podcasts'), Plugins::ABCListen::Sections->menuWeights ) }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	# D4: News, Sport, Kids listen, Audiobooks (no network I/O); Home and Podcasts stay if they fail
	my @sections = eval { Plugins::ABCListen::Sections->topItems($client) };
	$log->error( 'Building the ABC listen section items failed: ' . $@ ) if $@;

	$cb->( [
		{
			name   => cstring( $client, 'PLUGIN_ABCLISTEN_HOME' ),
			type   => 'link',
			url    => \&_homeRoot,
			image  => Plugins::ABCListen::Util::ICON,
			weight => Plugins::ABCListen::Util::topWeight('home'),
		},
		{
			name   => cstring( $client, 'PLUGIN_ABCLISTEN_PODCASTS' ),
			type   => 'link',
			url    => \&_podcastsRoot,
			image  => Plugins::ABCListen::Util::ICON,
			weight => Plugins::ABCListen::Util::topWeight('podcasts'),
		},
		@sections,
	] );
}

# ---------------------------------------------------------------------------
# Home
# ---------------------------------------------------------------------------

# Home: Featured, Popular now, Popular in sport, then the home collections.
sub _homeRoot {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::Collections->home( sub {
			my $page = shift;

			return _respond( $client, $once, sub { _homeItems( $client, $page, [] ) } ) if $page->{error};

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

	push @items, _recommendationsItem( $client, 'PLUGIN_ABCLISTEN_POPULAR_NOW',   'homepagePopularNow' );
	push @items, _recommendationsItem( $client, 'PLUGIN_ABCLISTEN_POPULAR_SPORT', 'homepageSports' );

	return [ @items, _textItem( $client, $page->{error} ) ] if $page->{error};

	push @items, grep {defined} map { Plugins::ABCListen::Collections->collectionItem( $client, $_, 0 ) }
		grep { ref $_ eq 'HASH' && ( $_->{id} // '' ) ne HOME_CATEGORIES_ID }
		@{ ref $page->{collections} eq 'ARRAY' ? $page->{collections} : [] };

	return \@items;
}

sub _recommendationsItem {
	my ( $client, $token, $name ) = @_;

	return {
		name        => cstring( $client, $token ),
		type        => 'link',
		url         => \&_recommendationsMenu,
		passthrough => [$name],
		image       => Plugins::ABCListen::Util::ICON,
	};
}

# Popular now / Popular in sport: ABC's recommendation cards as episode rows.
sub _recommendationsMenu {
	my ( $client, $cb, $args, $name ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::Collections->recommendations( $name, sub {
			my $result = shift;

			return _textFeed( $client, $once, $result->{error} ) if $result->{error};

			_try( $client, $once, sub {
				Plugins::ABCListen::Collections->itemsFor( $client, $result->{cards}, 1, sub {
					my $items = shift;
					_respond( $client, $once, sub { @$items ? [@$items] : [ _textItem( $client, EMPTY ) ] } );
				} );
			} );
		} );
	} );

	return;
}

# ---------------------------------------------------------------------------
# Podcasts
# ---------------------------------------------------------------------------

# Podcasts: the podcasts page's collections, Browse by category, All podcasts A–Z.
sub _podcastsRoot {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::Collections->podcasts( sub {
			my $page = shift;

			_try( $client, $once, sub {
				my $collections = $page->{error} || ref $page->{collections} ne 'ARRAY' ? [] : $page->{collections};

				Plugins::ABCListen::Collections->withImages( $collections, sub {
					my $withImages = shift;
					_respond( $client, $once, sub { _podcastsItems( $client, $page, $withImages ) } );
				} );
			} );
		} );
	} );

	return;
}

sub _podcastsItems {
	my ( $client, $page, $collections ) = @_;

	my @items = grep {defined} map { Plugins::ABCListen::Collections->collectionItem( $client, $_, 0 ) } @$collections;
	push @items, _textItem( $client, $page->{error} || LOAD_FAILED ) unless @items;

	my @categories = !$page->{error} && ref $page->{categories} eq 'ARRAY' ? @{ $page->{categories} } : ();
	@categories = Plugins::ABCListen::Collections->staticCategories unless @categories;

	my @links = grep {defined} map { Plugins::ABCListen::Collections->collectionItem( $client, $_, 1 ) } @categories;

	push @items, {
		name  => cstring( $client, 'PLUGIN_ABCLISTEN_CATEGORIES' ),
		type  => 'link',
		items => \@links,
		image => ( grep { $_ ne Plugins::ABCListen::Util::ICON } map { $_->{image} } @links )[0] || Plugins::ABCListen::Util::ICON,
	};

	if ( Plugins::ABCListen::OnDemand->can('programsByType') ) {
		push @items, {
			name  => cstring( $client, 'PLUGIN_ABCLISTEN_PODCASTS_AZ' ),
			type  => 'link',
			url   => \&_podcastsAZ,
			image => Plugins::ABCListen::Util::ICON,
		};
	}

	return \@items;
}

# All podcasts A–Z: O3's list of programs of type podcast (it answers $cb->(\@items) once).
sub _podcastsAZ {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub { Plugins::ABCListen::OnDemand->programsByType( $client, $once, 'podcast' ) } );

	return;
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
		$log->error( 'Building the ABC listen menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen menu failed: ' . ( $@ || 'unknown error' ) );
		return _textFeed( $client, $cb, LOAD_FAILED );
	}

	$cb->( { items => $items } );
	return;
}

sub _textFeed {
	my ( $client, $cb, $token ) = @_;
	$cb->( { items => [ _textItem( $client, $token ) ] } );
	return;
}

# One text item for a string token (unknown or malformed tokens read as LOAD_FAILED).
sub _textItem {
	my ( $client, $token ) = @_;
	$token = LOAD_FAILED unless defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/;
	return { name => cstring( $client, $token ), type => 'text' };
}

1;
