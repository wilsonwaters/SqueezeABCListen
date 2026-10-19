package Plugins::ABCListen::Sections;

# Section menus (D4, ai-state/streams/discovery/master-plan.md): the top-level News, Sport, Kids
# listen and Audiobooks items of the ABC listen app, each rendered from its abc.net.au section page
# by the collection engine (Plugins::ABCListen::Collections), plus a few static extras. Every row is
# the shared program / episode / station item (OnDemand builders, Live->stationItem), so playback,
# favourites and Follow behave as everywhere else. Discover.pm lists the four items (its menuItems /
# menuWeights call topItems / menuWeights); this module owns their menus.
#
#   topItems($client) -> the four links, in this order, without network I/O:
#       News         PLUGIN_ABCLISTEN_NEWS         weight topWeight('news')        page /listen/news
#       Sport        PLUGIN_ABCLISTEN_SPORT        weight topWeight('sport')       page /listen/sport
#       Kids listen  PLUGIN_ABCLISTEN_KIDS         weight topWeight('kids')        page /kidslisten
#       Audiobooks   PLUGIN_ABCLISTEN_AUDIOBOOKS   weight topWeight('audiobooks')  page /listen/audiobooks
#     each exactly { name, type => 'link', url => <the section menu>, image => plugin icon, weight }.
#   menuWeights -> the four weights (40, 50, 60, 70).
#
#   A section menu (a feed) lists, in order:
#     1. Live stations: Live->stationItem rows for the page's MiniEPG services, then the section's
#        static ids (News: NEWS, only when the page has no MiniEPG; Kids listen: KIDSLISTEN, then
#        KIDSLISTEN_NT / _QLD / _SA / _WA), then the cards of the page's station-only collections
#        (Collections page key stationCards: Sport's "Radio Stations"), inline instead of as a link
#        (Collections->itemsFor). A service stationItem returns undef for (unknown, hidden, HLS-only,
#        off-air event service) is left out; each station once (by url).
#     2. One link per LiveRadioCarousel heading (Sport's "Live & Upcoming Events") listing copies of
#        the stationItem rows of its events, each service once, with line2 = the event title and
#        description = "<title> (<start>–<end>)" (Util::friendlyTime); no link when none is playable.
#        Carousel entries without a heading are station rows (1.) with the same text.
#        The event-only services among 1. and 2. are checked first (Collections->checkOnAir, ≤ 3 s).
#     3. One link per page collection, in page order (Collections->collectionItem at level 0: ABC's
#        title, an untitled one is "Featured"; the first card's image, else the plugin icon; menus of
#        20 + More…). Collections whose embedded cards are all unsupported were dropped by page().
#     4. The static extras:
#          Kids listen  All Kids listen programs (program aggregation 9317914, A–Z as ABC orders it),
#                       Kids & Families podcasts (collection 104141842), Books for Kids (collection
#                       106510880, named with ABC's title), News Time (OnDemand->programItem,
#                       /kidslisten/programs/news-time, with the artwork of its card in the extras'
#                       first pages - All Kids listen programs lists it - else the plugin icon).
#                       The three collections' first pages are fetched together with the page
#                       (Collections->menuPage: the request and cache their menus use) for their
#                       first card's image and ABC's title. The menu waits for them at
#                       most EXTRAS_DEADLINE (3 s, like D2's withImages; the page itself has the
#                       API's 8 s): one that fails or is late gets the plugin icon and the
#                       PLUGIN_ABCLISTEN_KIDS_PROGRAMS / _KIDS_PODCASTS / _BOOKS_FOR_KIDS name (a late
#                       answer still warms the cache its menu uses). A collection the page lists
#                       itself is not repeated.
#          Audiobooks   All audiobooks A–Z (OnDemand->programsByType($client, $cb, 'audiobook'),
#                       only when O3's programsByType exists), then the text item
#                       PLUGIN_ABCLISTEN_AUDIOBOOKS_AU_ONLY (ABC serves audiobook audio to
#                       Australia only). Books open O2's program menu (chapters: D5).
#     5. When the page failed with no last-good copy: one text item with the error token's text
#        (LOAD_FAILED, RATE_LIMITED) after 1.-4.; with nothing at all to list: one
#        PLUGIN_ABCLISTEN_EMPTY_COLLECTION text item. Never an empty list.
#   Pages come from Collections->page (API::nextData, ttl 1 h, stale_ok): one _next/data request per
#   section per hour. Every feed calls back exactly once, on every path; if building dies, with one
#   LOAD_FAILED text item; a callback that dies is logged and never called again. $client may be
#   undef (web UI without a player, CLI).
#
# Owned by the discovery stream (D4).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant EMPTY       => 'PLUGIN_ABCLISTEN_EMPTY_COLLECTION';
use constant ENDASH      => "\x{2013}";

use constant EXTRAS_DEADLINE => 3;    # seconds a section waits for its extras' first pages

my $log = logger('plugin.abclisten');

my $COLLECTIONS = 'Plugins::ABCListen::Collections';
my $LIVE        = 'Plugins::ABCListen::Live';
my $ONDEMAND    = 'Plugins::ABCListen::OnDemand';

# key (= Util::topWeight name) => section
my %SECTIONS = (
	news => {
		token    => 'PLUGIN_ABCLISTEN_NEWS',
		path     => '/listen/news',
		fallback => ['NEWS'],    # ABC NewsRadio, when the page has no MiniEPG
	},
	sport => {
		token => 'PLUGIN_ABCLISTEN_SPORT',
		path  => '/listen/sport',
	},
	kids => {
		token       => 'PLUGIN_ABCLISTEN_KIDS',
		path        => '/kidslisten',    # /listen/kidslisten is 404
		live        => [qw(KIDSLISTEN KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA)],
		collections => [
			{ id => '9317914',   kind  => 'aggregation', token => 'PLUGIN_ABCLISTEN_KIDS_PROGRAMS' },    # /kidslisten/programs
			{ id => '104141842', token => 'PLUGIN_ABCLISTEN_KIDS_PODCASTS' },                       # podcast category
			{ id => '106510880', token => 'PLUGIN_ABCLISTEN_BOOKS_FOR_KIDS', abcTitle => 1 },       # Audiobooks sub-collection
		],
		programs => [ { title => 'News Time', path => '/kidslisten/programs/news-time' } ],
	},
	audiobooks => {
		token  => 'PLUGIN_ABCLISTEN_AUDIOBOOKS',
		path   => '/listen/audiobooks',
		extras => \&_audiobooksExtras,
	},
);

my @ORDER = qw(news sport kids audiobooks);

my %MENUS = (
	news       => \&_newsMenu,
	sport      => \&_sportMenu,
	kids       => \&_kidsMenu,
	audiobooks => \&_audiobooksMenu,
);

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

sub topItems {
	my ( $class, $client ) = @_;

	return map { +{
		name   => cstring( $client, $SECTIONS{$_}->{token} ),
		type   => 'link',
		url    => $MENUS{$_},
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight($_),
	} } @ORDER;
}

sub menuWeights { map { Plugins::ABCListen::Util::topWeight($_) } @ORDER }

sub _newsMenu       { _sectionMenu( 'news',       @_ ) }
sub _sportMenu      { _sectionMenu( 'sport',      @_ ) }
sub _kidsMenu       { _sectionMenu( 'kids',       @_ ) }
sub _audiobooksMenu { _sectionMenu( 'audiobooks', @_ ) }

# ---------------------------------------------------------------------------
# Section menus
# ---------------------------------------------------------------------------

# The page and the extras' first pages, in parallel; then the stations; then the rows. The page is
# always waited for; the extras at most EXTRAS_DEADLINE (late or failed ones use their fallbacks).
sub _sectionMenu {
	my ( $key, $client, $cb, $args ) = @_;
	my $section = $SECTIONS{$key};
	my $once    = _once($cb);

	_try( $client, $once, sub {
		my ( $page, $pageIn, %extras, $extrasIn, $timer, $started );
		my @extras = @{ $section->{collections} || [] };
		my $left   = @extras;
		$extrasIn = 1 unless $left;

		my $go = sub {
			return if $started || !$pageIn || !$extrasIn;
			$started = 1;
			_try( $client, $once, sub { _withStations( $client, $once, $section, $page, {%extras} ) } );
		};

		my $extrasDone = sub {
			return if $extrasIn;
			$extrasIn = 1;
			Slim::Utils::Timers::killSpecific($timer) if $timer;
			undef $timer;
			$go->();
		};

		$COLLECTIONS->page( $section->{path}, sub { $page = shift; $pageIn = 1; $go->() } );
		return unless @extras;

		$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + EXTRAS_DEADLINE, sub {
			undef $timer;
			main::DEBUGLOG && $log->is_debug && $log->debug( 'ABC listen: section extras not all fetched within ' . EXTRAS_DEADLINE . " s ($section->{path}); the rest use their fallbacks" );
			$extrasDone->();
		} );

		for my $extra (@extras) {
			my $settled = 0;
			my $answer  = sub {
				return if $settled++;
				$extras{ $extra->{id} } = shift unless $extrasIn;    # after the deadline: only warmed the cache
				$extrasDone->() unless --$left;
			};

			eval { $COLLECTIONS->menuPage( _extraHash($extra), 0, $answer ); 1 } or do {
				$log->warn( "ABC listen: fetching the section extra $extra->{id} failed: " . ( $@ || 'unknown error' ) );
				$answer->( { error => LOAD_FAILED } );
			};
		}
	} );

	return;
}

# Sort out the page; render the station-only collections and check the event services (in
# parallel); then answer with the rows.
sub _withStations {
	my ( $client, $once, $section, $page, $extras ) = @_;

	$page = { error => LOAD_FAILED } unless ref $page eq 'HASH';
	my $ok = !$page->{error};

	my @stations     = $ok ? grep { ref $_ eq 'HASH' && _hasText( $_->{serviceId} ) } _list( $page->{stations} ) : ();
	my $stationCards = $ok ? _hash( $page->{stationCards} ) : {};
	my @pageCollections = $ok ? grep { ref $_ eq 'HASH' && defined $_->{id} } _list( $page->{collections} ) : ();

	my @events = grep { _isCarousel($_) && defined $_->{heading} } @stations;

	# rows: { serviceId, event? }
	my @live = map { +{ serviceId => $_->{serviceId}, ( _isCarousel($_) ? ( event => $_ ) : () ) } } grep { !( _isCarousel($_) && defined $_->{heading} ) } @stations;
	push @live, map { +{ serviceId => $_ } } @{ $section->{live} || [] };
	@live = map { +{ serviceId => $_ } } @{ $section->{fallback} || [] } unless @live;

	my @inline      = map { @{ $stationCards->{ $_->{id} } } } grep { ref $stationCards->{ $_->{id} } eq 'ARRAY' } @pageCollections;
	my @collections = grep { !$stationCards->{ $_->{id} } } @pageCollections;

	my ( $inlineItems, $pending ) = ( [], 2 );
	my $ready = sub {
		return if --$pending;
		_respond( $client, $once, sub {
			_sectionItems( $client, $section, {
				live        => \@live,
				inline      => $inlineItems,
				events      => \@events,
				collections => \@collections,
				extras      => $extras,
				error       => $page->{error},
			} );
		} );
	};

	$COLLECTIONS->itemsFor( $client, \@inline, 0, sub { $inlineItems = shift; $ready->() } );
	$COLLECTIONS->checkOnAir( [ map { $_->{serviceId} } @live, @events ], $ready );

	return;
}

sub _sectionItems {
	my ( $client, $section, $s ) = @_;
	my ( @items, %seen );

	# 1. live stations
	for my $item ( ( map { _stationRow( $client, $_->{serviceId}, $_->{event} ) } @{ $s->{live} } ), @{ $s->{inline} || [] } ) {
		next unless ref $item eq 'HASH';
		push @items, $item unless $seen{ defined $item->{url} ? $item->{url} : '' }++;
	}

	# 2. live & upcoming events
	push @items, _eventLinks( $client, $s->{events} );

	# 3. the page's collections
	my %listed;
	for my $collection ( @{ $s->{collections} } ) {
		my $item = $COLLECTIONS->collectionItem( $client, $collection, 0 ) or next;
		$listed{ $collection->{id} } = 1;
		push @items, $item;
	}

	# 4. static extras
	for my $extra ( @{ $section->{collections} || [] } ) {
		next if $listed{ $extra->{id} };
		push @items, _extraCollection( $client, $extra, $s->{extras}->{ $extra->{id} } ) || ();
	}
	push @items, grep { ref $_ eq 'HASH' } map { $ONDEMAND->programItem( $client, _withArtwork( $_, $section, $s->{extras} ) ) } @{ $section->{programs} || [] };
	push @items, $section->{extras}->($client) if $section->{extras};

	# 5. failure / nothing at all
	push @items, _textItem( $client, $s->{error} ) if $s->{error};
	push @items, _textItem( $client, EMPTY ) unless @items;

	return \@items;
}

# A Kids listen extra collection: ABC's title (abcTitle) and first image from its prefetched first
# page, else the token's name and the plugin icon.
sub _extraCollection {
	my ( $client, $extra, $first ) = @_;
	$first = {} unless ref $first eq 'HASH' && !$first->{error};

	my ($image) = grep {defined} map { $_->{image} } grep { ref $_ eq 'HASH' } _list( $first->{cards} );
	my $title = $extra->{abcTitle} && _hasText( $first->{title} ) ? $first->{title} : cstring( $client, $extra->{token} );

	return $COLLECTIONS->collectionItem( $client, _extraHash( $extra, title => $title, image => $image ), 0 );
}

# A static program (News Time) with ABC's artwork: the image of its card in the extras' prefetched
# first pages (News Time is in All Kids listen programs), else none (programItem: the plugin icon).
sub _withArtwork {
	my ( $program, $section, $extras ) = @_;
	my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
	return {%$program} unless defined $path;

	my ($card) = grep { ( $_->{type} // '' ) eq 'program' && _hasText( $_->{image} ) && ( Plugins::ABCListen::API::sitePath( $_->{path} ) // '' ) eq $path }
		grep { ref $_ eq 'HASH' } map { _list( _hash( _hash($extras)->{ $_->{id} } )->{cards} ) } @{ $section->{collections} || [] };

	return { %$program, ( $card ? ( image => $card->{image} ) : () ) };
}

# The collection hash of an extra (what collectionItem passes to its menu, and menuPage reads).
sub _extraHash {
	my ( $extra, %more ) = @_;
	return { id => $extra->{id}, ( $extra->{kind} ? ( kind => $extra->{kind} ) : () ), %more };
}

# One link per carousel heading, listing its playable event stations (each service once).
sub _eventLinks {
	my ( $client, $events ) = @_;
	my ( @headings, %rows, %seen );

	for my $event ( @{ $events || [] } ) {
		my $heading = $event->{heading};
		push @headings, $heading unless $rows{$heading};
		$rows{$heading} ||= [];

		next if $seen{$heading}->{ $event->{serviceId} }++;

		my $item = _stationRow( $client, $event->{serviceId}, $event ) or next;
		push @{ $rows{$heading} }, $item;
	}

	return map { +{
		name  => $_,
		type  => 'link',
		items => $rows{$_},
		image => $rows{$_}->[0]->{image} || Plugins::ABCListen::Util::ICON,
	} } grep { @{ $rows{$_} } } @headings;
}

# Live->stationItem, or undef; with an event, a copy with its title as line2 and description.
sub _stationRow {
	my ( $client, $serviceId, $event ) = @_;
	return undef unless $LIVE->can('stationItem');

	my $item = eval { $LIVE->stationItem( $client, $serviceId ) };
	$log->error("ABC listen: building the station row for $serviceId failed: $@") if $@;
	return undef unless ref $item eq 'HASH';
	return $item unless ref $event eq 'HASH' && _hasText( $event->{title} );

	my @times = grep {defined} map { defined $_ ? Plugins::ABCListen::Util::friendlyTime($_) : undef } $event->{start}, $event->{end};

	return {
		%$item,
		line2       => $event->{title},
		description => @times == 2 ? "$event->{title} ($times[0]" . ENDASH . "$times[1])" : $event->{title},
	};
}

sub _audiobooksExtras {
	my $client = shift;
	my @items;

	push @items, {
		name  => cstring( $client, 'PLUGIN_ABCLISTEN_AUDIOBOOKS_AZ' ),
		type  => 'link',
		url   => \&_audiobooksAZ,
		image => Plugins::ABCListen::Util::ICON,
	} if $ONDEMAND->can('programsByType');    # O3

	push @items, _textItem( $client, 'PLUGIN_ABCLISTEN_AUDIOBOOKS_AU_ONLY' );
	return @items;
}

# All audiobooks A–Z: O3's list of audiobook programs (it answers an array ref, once).
sub _audiobooksAZ {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);
	_try( $client, $once, sub { $ONDEMAND->programsByType( $client, $once, 'audiobook' ) } );
	return;
}

sub _isCarousel { ( $_[0]->{component} || '' ) eq 'LiveRadioCarousel' }

# ---------------------------------------------------------------------------
# Feed helpers (every feed calls back exactly once)
# ---------------------------------------------------------------------------

# A callback wrapper that passes on only the first call and logs (never propagates) a death.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub {
		return if $called++;
		eval { $cb->(@_) if ref $cb eq 'CODE'; 1 } or $log->error( 'ABC listen section callback failed: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# Run $code (which answers $cb itself); if it dies, answer $cb with the LOAD_FAILED item.
sub _try {
	my ( $client, $cb, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Building the ABC listen section menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen section menu failed: ' . ( $@ || 'unknown error' ) );
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

sub _hash    { ref $_[0] eq 'HASH'  ? $_[0]      : {} }
sub _list    { ref $_[0] eq 'ARRAY' ? @{ $_[0] } : () }
sub _hasText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

1;
