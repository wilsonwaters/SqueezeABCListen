package Plugins::ABCListen::Collections;

# The discovery collection engine (ai-state/streams/discovery/master-plan.md, D1): turns an ABC
# listen page's Next data and ABC's BFF collections into OPML items. Data and card dispatcher only:
# no top-level menu code (Discover.pm owns Home; D4's Sections.pm owns News, Sport, Kids listen and
# Audiobooks). Every program, episode and station row comes from the shared builders
# (OnDemand->programItem / episodeItem, Live->stationItem), so playback, favourites and Follow
# behave the same everywhere. All I/O goes through Plugins::ABCListen::API (async).
#
# ---- Callbacks ------------------------------------------------------------------------------------
#   page, home, items and itemsFor call $cb EXACTLY ONCE, on every path. Failures are
#   { error => TOKEN }, the API token passed through ('PLUGIN_ABCLISTEN_LOAD_FAILED' or
#   'PLUGIN_ABCLISTEN_RATE_LIMITED'). Cache hits call back synchronously, other calls later: code
#   must work either way. A callback that dies is logged and never leads to a second call.
#   Functions work as class methods (Plugins::ABCListen::Collections->page(...)) or plain functions.
#
# ---- Card refs ------------------------------------------------------------------------------------
#   API::cardRef's shape: { type, id, uriId, title, tagline, path, image, date, duration, programId,
#   docType, description }. ids are the card's cardId (document id), never a teaser contentUri id.
#   Hero items (HeroCarousel) are normalised to the same shape plus programTitle and hero => 1:
#   type/uriId from itemUri; id = uriId, or for audio types the numeric last segment of
#   buttonProps.canonicalURL when there is one; path = sitePath(buttonProps.canonicalURL); image
#   = imageUrl(imgSrc, 300); duration = buttonProps.duration when > 0; title, description and
#   programTitle entity-decoded and trimmed; tagline, date, programId undef.
#
# ---- Public interface (D1; reused by D2 Home/Podcasts, D4 sections, D5 and later features) --------
#
#   page($path, $cb) -> $cb->({ hero => [refs], collections => [{ id, title, image }], stale => 0|1 })
#                     | $cb->({ error => TOKEN })
#       API::nextData($path) (ttl 1 h, stale_ok: stale => 1 when the last-good page is served;
#       timeout 8 s) -> pageProps.data.componentsContent[] in page order, each component handled by
#       its entry in %COMPONENTS (by `component` name):
#         HeroCarousel        componentProps.items[] -> hero refs, in carousel order
#         StandardCollection  { id => componentProps.id (else key), title => componentProps.title
#                             (undef when empty), image => the first supported embedded card's
#                             image } - omitted without a numeric id, or when no embedded card
#                             (componentProps.items[]) is supported (e.g. video-only collections)
#         LiveRadioCarousel, RecommendationsExperiment, ExperimentEnroller, AppStoreCTA,
#         AppOnwardJourney: ignored; any other component: ignored, logged once per name at DEBUG.
#       A handler that dies is logged (WARN, once per component name) and skipped.
#       Extending (D4): add an entry to %COMPONENTS, sub { my ($component, $page) = @_; ... }, that
#       pushes onto $page (new keys, e.g. stations, are fine: callers ignore keys they don't know).
#   home($cb)  = page('/listen', $cb).
#
#   items($collectionId, $offset, $size, $cb, \%extraQuery)
#       -> $cb->({ title, total, count, cards => [refs] }) | $cb->({ error => TOKEN })
#       API::bff('collection/x', { collectionId, offset, size }) (ttl 30 min, stale_ok, timeout 8 s).
#       total = collection.pagination.total (undef when missing); count = how many cards ABC sent
#       (for paging; cards without a parseable contentUri are dropped from cards). A null or empty
#       collection is { total => undef or 0, count => 0, cards => [] }. offset defaults to 0, size
#       to PAGE_SIZE (20).
#       \%extraQuery (optional, D2): its plain-text values are merged into the query (e.g. a
#       MetaCollection sub-collection's { rootMetaCollectionId, metaInMeta => 'false' });
#       collectionId, offset and size always win. Without it the request is unchanged.
#
#   itemFor($client, $ref, $depth) -> \%item | undef  (synchronous, no I/O)
#       $depth is the level of the menu the item is listed in (a page root such as Home = 0, a
#       collection opened from it = 1, ...); undef counts as 1. Above MAX_DEPTH (3): undef.
#         program                          -> OnDemand->programItem($client, { title, path, id, image,
#                                             description => tagline // description })
#         audioepisode / audio / audiosegment -> OnDemand->episodeItem($client, { id, docType, title,
#                                             programTitle, programId, path, image, description,
#                                             date, duration }) (undef values passed as undef)
#         collection                       -> collectionItem (id = the card's id)
#         dynamiccollection                -> collectionItem with the numeric last segment of the
#                                             card's path (articleLink), else undef
#         channel; externallink with a 'live' path segment
#                                          -> Live->stationItem($client, Stations->byPageSlug($slug))
#                                             for the first slug that maps: the segment after 'live',
#                                             then the first segment that is not 'listen' or 'live'.
#                                             undef while Stations->byPageSlug or Live->stationItem
#                                             don't exist (L1), or when no slug maps.
#         teaser, unknown (hero)           -> by path: a /programs/ path whose last segment is all
#                                             digits -> episode (that id, docType audioepisode);
#                                             '.../programs/<slug>' -> program (no id); else undef
#         anything else (article, video, person, ...) -> undef, logged at DEBUG.
#       A builder that dies: undef, logged at WARN once per card type.
#
#   itemsFor($client, \@refs, $depth, $cb) -> $cb->(\@items)  (never an error)
#       A page of cards -> items: drops duplicates (same type + id), resolves program names (below),
#       then itemFor on each; refs that map to nothing are left out (\@items may be empty).
#       Program names (FQ4): every program ref with a path that is not from the hero is looked up
#       with Programs->program($path) (cached 6 h), at most NAME_CONCURRENCY (4) at a time, within
#       NAME_DEADLINE (3 s) for the whole page: cardRef's title is either cardTitle (often an
#       editorial tagline) or the image alt text, which is often a file or tile name
#       ('BackgroundBriefing_3000x3000.jpg', 'Dr Karl Podcast Tile') or another program's name.
#       Found: title = the program's own name (heroImageWithCTAPrepared.heading), and the card's
#       cardTitle becomes the description (tagline) if it differs. Error or deadline: cardRef's
#       title and tagline are kept. Lookups still queued or in flight at the deadline carry on
#       and warm the cache for the next open. Without lookups it calls back synchronously.
#
#   collectionItem($client, { id, title, image }, $depth) -> link | undef
#       A link listed at level $depth (0 at a page root) to the collection's menu at $depth + 1;
#       undef when that passes MAX_DEPTH or without a numeric id. name = title, else
#       PLUGIN_ABCLISTEN_FEATURED (never blank); image = imageUrl(image, 300), else the plugin icon.
#       The menu: PAGE_SIZE items per page (items + itemsFor), then "More…" (PLUGIN_ABCLISTEN_MORE)
#       while the page had cards and offset + count < total. Nothing to list: one
#       PLUGIN_ABCLISTEN_EMPTY_COLLECTION text item; fetch error: the error token's text item.
#       Every feed answers exactly once. The collection hash travels in the passthrough (D4 may add
#       keys such as kind => 'aggregation' and page those with its own fetcher).
#       Optional collection keys (D2):
#         query        => \%extraQuery for items() (MetaCollection sub-collections);
#         fallbackPath => a site page (a podcast category's page): when the first page (offset 0)
#                         fails or has no cards, the menu pages the first collection of
#                         page(fallbackPath) instead, if its id differs (More… then pages that id).
#                         Otherwise the first result stands.
#
# ---- D2 additions (Podcasts menu, Popular now / Popular in sport) ---------------------------------
#
#   podcasts($cb) -> $cb->({ collections => [{ id, title, query }], categories => [{ id, title,
#                    image, fallbackPath }], stale => 0|1 }) | $cb->({ error => TOKEN })
#       API::nextData('/listen/podcasts') (ttl 1 h, stale_ok, timeout 8 s), componentsContent[]:
#         the first MetaCollection -> collections: its componentProps.items[] { id, title } in
#             order (no numeric id, or itemsCount 0: left out), each with query =>
#             { rootMetaCollectionId => the MetaCollection's id, metaInMeta => 'false' };
#         the first StandardCollection with dynamiccollection cards -> categories: per card
#             id = the numeric last segment of articleLink (none: left out), title = cardTitle,
#             image = the card image, fallbackPath = articleLink's site path.
#       Missing parts are empty lists (callers decide: Discover shows LOAD_FAILED / the static list).
#   staticCategories() -> the 8 podcast categories of 2026-10-19 as above (image undef), in ABC's
#       order: the fallback when the podcasts page fails or lists none.
#
#   recommendations($name, $cb) -> $cb->({ title, cards => [refs], stale => 0|1 }) | $cb->({ error => TOKEN })
#       API::bff("recommendations/listen/$name") (ttl 1 h, stale_ok, timeout 8 s); $name is
#       letters and digits ('homepagePopularNow', 'homepageSports'), else LOAD_FAILED without a
#       request. cards = API::cardRef of items[] (none, {} or no items: []). Recommendation cards
#       carry no date (no cardAttributionPrepared): date stays undef.
#
#   withImages(\@collections, $cb) -> $cb->(\@copies)  (never an error)
#       Copies of the collections; each one without an image gets the image of the first
#       supported card of its first page (items($id, 0, PAGE_SIZE, ..., query): the same request,
#       and cache entry, as opening it). Waits at most IMAGE_DEADLINE (3 s); fetch errors and late
#       answers leave the image undef (collectionItem then uses the plugin icon).
#
# Owned by the discovery stream (D1 creates; D2 and D4 extend additively).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util qw(decodeEntities);

use constant PAGE_TTL         => 3600;    # page() Next data
use constant ITEMS_TTL        => 1800;    # items() BFF collections
use constant API_TIMEOUT      => 8;       # seconds per request (menu paths; HTTP.pm's default is 15)
use constant PAGE_SIZE        => 20;
use constant MAX_DEPTH        => 3;
use constant NAME_CONCURRENCY => 4;
use constant NAME_DEADLINE    => 3;       # seconds per page
use constant IMAGE_PX         => 300;

use constant PODCASTS_PATH       => '/listen/podcasts';    # D2
use constant RECOMMENDATIONS_TTL => 3600;                  # D2 recommendations()
use constant IMAGE_DEADLINE      => 3;                     # D2 withImages(), seconds

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant EMPTY       => 'PLUGIN_ABCLISTEN_EMPTY_COLLECTION';
use constant MORE        => 'PLUGIN_ABCLISTEN_MORE';
use constant FEATURED    => 'PLUGIN_ABCLISTEN_FEATURED';

my $log = logger('plugin.abclisten');

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);

# page() component handlers by component name; undef = ignored without a log line.
my %COMPONENTS = (
	HeroCarousel              => \&_heroCarousel,
	StandardCollection        => \&_standardCollection,
	LiveRadioCarousel         => undef,    # Radio covers live stations (L1)
	RecommendationsExperiment => undef,    # D2 (Popular now, Popular in sport)
	ExperimentEnroller        => undef,
	AppStoreCTA               => undef,
	AppOnwardJourney          => undef,
);

my %loggedComponent;    # component name => 1 once logged (unknown at DEBUG, failing at WARN)
my %warnedType;         # card type => 1 once a dying builder was logged
my $stationsLoaded;     # undef: not tried; 1/0: whether Plugins::ABCListen::Stations loaded

# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

sub page {
	shift if _isClass( $_[0] );
	my ( $path, $cb ) = @_;
	my $once = _once($cb);

	Plugins::ABCListen::API::nextData(
		$path,
		sub {
			my ( $pageProps, $info ) = @_;
			_guard( $once, sub { $once->( _parsePage( $pageProps, $info ) ) } );
		},
		sub { $once->( { error => _token(shift) } ) },
		{ ttl => PAGE_TTL, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub home {
	shift if _isClass( $_[0] );
	return page( '/listen', @_ );
}

sub _parsePage {
	my ( $pageProps, $info ) = @_;

	my $page = { hero => [], collections => [], stale => _hash($info)->{stale} ? 1 : 0 };

	for my $component ( _list( _hash( _hash($pageProps)->{data} )->{componentsContent} ) ) {
		next unless ref $component eq 'HASH';

		my $name = _isText( $component->{component} ) ? $component->{component} : '(none)';

		if ( !exists $COMPONENTS{$name} ) {
			main::DEBUGLOG && $log->is_debug && !$loggedComponent{$name}++ && $log->debug("ABC listen page: ignoring component $name");
			next;
		}

		my $handler = $COMPONENTS{$name} or next;

		eval { $handler->( $component, $page ); 1 } or do {
			$log->warn( "ABC listen page: skipped a $name component: " . ( $@ || 'unknown error' ) ) unless $loggedComponent{"fail:$name"}++;
		};
	}

	return $page;
}

sub _heroCarousel {
	my ( $component, $page ) = @_;
	push @{ $page->{hero} }, grep {defined} map { _heroRef($_) } _list( _hash( $component->{componentProps} )->{items} );
	return;
}

# A HeroCarousel item -> a card ref (see "Card refs" above), or undef without a coremedia itemUri.
sub _heroRef {
	my $item = shift;
	return undef unless ref $item eq 'HASH';

	my ( $type, $uriId ) = Plugins::ABCListen::API::coreMediaRef( $item->{itemUri} ) or return undef;

	my $button = _hash( $item->{buttonProps} );
	my $path   = Plugins::ABCListen::API::sitePath( $button->{canonicalURL} );

	my $id = $uriId;
	if ( $AUDIO_TYPE{$type} ) {
		my $leaf = _leaf($path);
		$id = $leaf if defined $leaf;
	}

	my $duration = _int( $button->{duration} );

	return {
		type         => $type,
		id           => $id,
		uriId        => $uriId,
		title        => _text( $item->{title} ),
		tagline      => undef,
		path         => $path,
		image        => Plugins::ABCListen::API::imageUrl( $item->{imgSrc}, IMAGE_PX ),
		date         => undef,
		duration     => $duration ? $duration : undef,
		programId    => undef,
		docType      => $AUDIO_TYPE{$type} ? $type : undef,
		description  => _text( $item->{description} ),
		programTitle => _text( $item->{programTitle} ),
		hero         => 1,
	};
}

sub _standardCollection {
	my ( $component, $page ) = @_;
	my $props = _hash( $component->{componentProps} );

	my $id = _digits( $props->{id} );
	$id = _digits( $component->{key} ) unless defined $id;
	return unless defined $id;

	my ($first) = grep { _target($_) } grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( $props->{items} );
	return unless $first;

	push @{ $page->{collections} }, { id => $id, title => _text( $props->{title} ), image => $first->{image} };
	return;
}

# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------

sub items {
	shift if _isClass( $_[0] );
	my ( $id, $offset, $size, $cb, $extra ) = @_;
	my $once = _once($cb);

	$id = _digits($id);
	return $once->( { error => LOAD_FAILED } ) unless defined $id;

	$offset = _int($offset) || 0;
	$size   = _int($size)   || PAGE_SIZE;

	my %extra = ref $extra eq 'HASH' ? map { $_ => $extra->{$_} } grep { _isText( $extra->{$_} ) } keys %$extra : ();

	Plugins::ABCListen::API::bff(
		'collection/x',
		{ %extra, collectionId => $id, offset => $offset, size => $size },
		sub {
			my $data = shift;
			_guard( $once, sub { $once->( _collectionPage($data) ) } );
		},
		sub { $once->( { error => _token(shift) } ) },
		{ ttl => ITEMS_TTL, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub _collectionPage {
	my $collection = _hash( _hash(shift)->{collection} );
	my @cards      = _list( $collection->{items} );

	return {
		title => _text( $collection->{title} ),
		total => _int( _hash( $collection->{pagination} )->{total} ),
		count => scalar @cards,
		cards => [ grep {defined} map { Plugins::ABCListen::API::cardRef($_) } @cards ],
	};
}

sub collectionItem {
	my ( $class, $client, $collection, $depth ) = @_;
	return undef unless ref $collection eq 'HASH' && defined _digits( $collection->{id} );

	my $level = _level( $depth, 0 ) + 1;
	return undef if $level > MAX_DEPTH;

	my $title = _isText( $collection->{title} ) && $collection->{title} =~ /\S/ ? $collection->{title} : cstring( $client, FEATURED );

	return {
		name        => $title,
		type        => 'link',
		url         => \&_collectionMenu,
		passthrough => [ { %$collection }, 0, $level ],
		image       => Plugins::ABCListen::API::imageUrl( $collection->{image}, IMAGE_PX ) || Plugins::ABCListen::Util::ICON,
	};
}

# A collection's menu (feed): PAGE_SIZE items from $offset, then "More…" while ABC has more.
sub _collectionMenu {
	my ( $client, $cb, $args, $collection, $offset, $depth ) = @_;
	my $once = _once($cb);

	$collection = {} unless ref $collection eq 'HASH';
	$offset     = _int($offset) || 0;
	$depth      = _level( $depth, 1 );

	_try( $client, $once, sub {
		_menuPage( $collection, $offset, sub {
			my ( $result, $source ) = @_;

			return _textFeed( $client, $once, $result->{error} ) if $result->{error};

			_try( $client, $once, sub {
				__PACKAGE__->itemsFor( $client, $result->{cards}, $depth, sub {
					my $items = shift;

					_respond( $client, $once, sub {
						my @items = @$items;

						my $next = $offset + $result->{count};
						my $more = $result->{count} > 0 && defined $result->{total} && $next < $result->{total};

						push @items, _textItem( $client, EMPTY ) unless @items || $more;

						push @items, {
							name        => cstring( $client, MORE ),
							type        => 'link',
							url         => \&_collectionMenu,
							passthrough => [ $source, $next, $depth ],
						} if $more;

						return \@items;
					} );
				} );
			} );
		} );
	} );

	return;
}

# One page of a collection for its menu: items() with the collection's query; at offset 0, when
# that fails or has no cards and the collection has a fallbackPath, the first collection of
# page(fallbackPath) if its id differs (D2: podcast categories). $cb->($result, $collection) once,
# with the collection the result belongs to (More… pages it).
sub _menuPage {
	my ( $collection, $offset, $cb ) = @_;

	items( $collection->{id}, $offset, PAGE_SIZE, sub {
		my $result = shift;
		my $path   = $collection->{fallbackPath};

		return $cb->( $result, $collection ) unless $offset == 0 && _hasText($path) && ( $result->{error} || !$result->{count} );

		my $settled = 0;
		my $keep    = sub { $cb->( $result, $collection ) unless $settled++ };

		_guard( $keep, sub {
			page( $path, sub {
				my $page = shift;

				_guard( $keep, sub {
					my ($first) = _list( $page->{collections} );
					return $keep->() if $page->{error} || ref $first ne 'HASH' || $first->{id} eq ( $collection->{id} // '' );

					my %next = ( %$collection, id => $first->{id} );
					delete @next{qw(fallbackPath query)};

					main::INFOLOG && $log->is_info && $log->info("ABC listen: collection $collection->{id} has nothing; paging $next{id} from $path");

					items( $next{id}, 0, PAGE_SIZE, sub { $cb->( shift, \%next ) unless $settled++ } );
				} );
			} );
		} );
	}, $collection->{query} );

	return;
}

# ---------------------------------------------------------------------------
# D2: the podcasts page, recommendations, collection images
# ---------------------------------------------------------------------------

# The podcast categories (2026-10-19), ABC's order: [ page id, name, page slug ].
my @STATIC_CATEGORIES = (
	[ 104142082 => 'News & Analysis',              'news-and-analysis' ],
	[ 104142226 => 'True Crime',                   'true-crime' ],
	[ 104142200 => 'Sport',                        'sport' ],
	[ 104141842 => 'Kids & Families',              'kids-and-families' ],
	[ 104141924 => 'History',                      'history' ],
	[ 104142164 => 'Society & Culture',            'society-and-culture' ],
	[ 104142058 => 'Music',                        'music' ],
	[ 104141814 => 'Conversations & Storytelling', 'conversations-storytelling' ],
);

sub podcasts {
	shift if _isClass( $_[0] );
	my ($cb) = @_;
	my $once = _once($cb);

	Plugins::ABCListen::API::nextData(
		PODCASTS_PATH,
		sub {
			my ( $pageProps, $info ) = @_;
			_guard( $once, sub { $once->( _parsePodcasts( $pageProps, $info ) ) } );
		},
		sub { $once->( { error => _token(shift) } ) },
		{ ttl => PAGE_TTL, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub _parsePodcasts {
	my ( $pageProps, $info ) = @_;

	my ( $collections, $categories );

	for my $component ( _list( _hash( _hash($pageProps)->{data} )->{componentsContent} ) ) {
		next unless ref $component eq 'HASH' && _isText( $component->{component} );

		if ( $component->{component} eq 'MetaCollection' ) {
			$collections ||= _subCollections($component);
		}
		elsif ( $component->{component} eq 'StandardCollection' && !( $categories && @$categories ) ) {
			$categories = [
				map { { id => _leaf( $_->{path} ), title => $_->{title}, image => $_->{image}, fallbackPath => $_->{path} } }
				grep { $_->{type} eq 'dynamiccollection' && defined _leaf( $_->{path} ) }
				grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( _hash( $component->{componentProps} )->{items} )
			];
		}
	}

	return { collections => $collections || [], categories => $categories || [], stale => _hash($info)->{stale} ? 1 : 0 };
}

# A MetaCollection's sub-collections: [{ id, title, query }], those with itemsCount 0 left out.
sub _subCollections {
	my $component = shift;
	my $props     = _hash( $component->{componentProps} );

	my $metaId = _digits( $props->{rootMetaCollectionId} );
	$metaId = _digits( $component->{key} ) unless defined $metaId;

	my @collections;
	for my $item ( grep { ref $_ eq 'HASH' } _list( $props->{items} ) ) {
		my $id = _digits( $item->{id} );
		next unless defined $id;

		my $count = _int( $item->{itemsCount} );
		next if defined $count && !$count;

		push @collections, {
			id    => $id,
			title => _text( $item->{title} ),
			defined $metaId ? ( query => { rootMetaCollectionId => $metaId, metaInMeta => 'false' } ) : (),
		};
	}

	return \@collections;
}

sub staticCategories {
	return map { { id => "$_->[0]", title => $_->[1], image => undef, fallbackPath => "/listen/listenapp/$_->[2]/$_->[0]" } } @STATIC_CATEGORIES;
}

sub recommendations {
	shift if _isClass( $_[0] );
	my ( $name, $cb ) = @_;
	my $once = _once($cb);

	return $once->( { error => LOAD_FAILED } ) unless _isText($name) && $name =~ /\A[A-Za-z0-9]+\z/;

	Plugins::ABCListen::API::bff(
		"recommendations/listen/$name",
		undef,
		sub {
			my ( $data, $info ) = @_;
			_guard( $once, sub {
				$once->( {
					title => _text( _hash($data)->{title} ),
					cards => [ grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( _hash($data)->{items} ) ],
					stale => _hash($info)->{stale} ? 1 : 0,
				} );
			} );
		},
		sub { $once->( { error => _token(shift) } ) },
		{ ttl => RECOMMENDATIONS_TTL, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub withImages {
	my ( $class, $collections, $cb ) = @_;
	my $once = _once($cb);

	my @copies  = map { {%$_} } grep { ref $_ eq 'HASH' } _list($collections);
	my @pending = grep { !defined $_->{image} && defined _digits( $_->{id} ) } @copies;

	return $once->( \@copies ) unless @pending;

	my ( $left, $finished, $timer ) = ( scalar @pending, 0 );

	my $finish = sub {
		return if $finished++;
		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;
		$once->( [ map { {%$_} } @copies ] );
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + IMAGE_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( 'ABC listen: collection images not all found within ' . IMAGE_DEADLINE . ' s' );
		$finish->();
	} );

	for my $collection (@pending) {
		my $settled = 0;
		my $done    = sub {
			my $result = shift;
			return if $settled++;
			my ($card) = grep { defined $_->{image} && _target($_) } _list( _hash($result)->{cards} );
			$collection->{image} = $card->{image} if $card && !$finished;
			$finish->() unless --$left;
		};

		eval { items( $collection->{id}, 0, PAGE_SIZE, $done, $collection->{query} ); 1 } or do {
			$log->warn( "ABC listen: collection image lookup for $collection->{id} failed: " . ( $@ || 'unknown error' ) );
			$done->( {} );
		};
	}

	return;
}

# ---------------------------------------------------------------------------
# Card dispatcher
# ---------------------------------------------------------------------------

my %BUILDERS = (
	program    => \&_programItem,
	episode    => \&_episodeItem,
	collection => \&_nestedCollectionItem,
	station    => \&_stationItem,
);

sub itemFor {
	my ( $class, $client, $ref, $depth ) = @_;
	return undef unless ref $ref eq 'HASH';

	$depth = _level( $depth, 1 );
	return undef if $depth > MAX_DEPTH;

	my $type   = _isText( $ref->{type} ) ? $ref->{type} : 'unknown';
	my $target = _target($ref);

	if ( !$target ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "ABC listen: skipped card $type/" . ( defined $ref->{id} ? $ref->{id} : '?' ) );
		return undef;
	}

	my $item = eval { $BUILDERS{ $target->{kind} }->( $client, $ref, $target, $depth ) };

	if ($@) {
		$log->warn("ABC listen: couldn't build an item for a $type card: $@") unless $warnedType{$type}++;
		return undef;
	}

	return ref $item eq 'HASH' ? $item : undef;
}

# What a card ref maps to: { kind => program | episode | collection | station, id? }, or undef.
sub _target {
	my $ref  = shift;
	my $type = $ref->{type};
	return undef unless _isText($type);

	my $path = $ref->{path};

	if ( $type eq 'program' ) {
		return defined $path ? { kind => 'program', id => $ref->{id} } : undef;
	}

	if ( $AUDIO_TYPE{$type} ) {
		my $id = _digits( $ref->{id} );
		return defined $id ? { kind => 'episode', id => $id, docType => $ref->{docType} || $type } : undef;
	}

	if ( $type eq 'collection' ) {
		my $id = _digits( $ref->{id} );
		return defined $id ? { kind => 'collection', id => $id } : undef;
	}

	if ( $type eq 'dynamiccollection' ) {
		# the category page id (articleLink leaf); the contentUri id pages nothing
		my $id = _leaf($path);
		return defined $id ? { kind => 'collection', id => $id } : undef;
	}

	if ( $type eq 'channel' || ( $type eq 'externallink' && grep { $_ eq 'live' } _segments($path) ) ) {
		return defined $path && _stationsAvailable() ? { kind => 'station' } : undef;
	}

	if ( $type eq 'teaser' || $type eq 'unknown' ) {
		return undef unless defined $path && $path =~ m{/programs/};

		my $leaf = _leaf($path);
		return { kind => 'episode', id => $leaf, docType => 'audioepisode' } if defined $leaf;
		return { kind => 'program', id => undef } if $path =~ m{/programs/[^/]+\z};
	}

	return undef;
}

sub _programItem {
	my ( $client, $ref, $target ) = @_;

	return Plugins::ABCListen::OnDemand->programItem( $client, {
		title       => $ref->{title},
		path        => $ref->{path},
		id          => $target->{id},
		image       => $ref->{image},
		description => defined $ref->{tagline} ? $ref->{tagline} : $ref->{description},
	} );
}

sub _episodeItem {
	my ( $client, $ref, $target ) = @_;

	return Plugins::ABCListen::OnDemand->episodeItem( $client, {
		id           => $target->{id},
		docType      => $target->{docType},
		title        => $ref->{title},
		programTitle => $ref->{programTitle},
		programId    => $ref->{programId},
		path         => $ref->{path},
		image        => $ref->{image},
		description  => $ref->{description},
		date         => $ref->{date},
		duration     => $ref->{duration},
	} );
}

sub _nestedCollectionItem {
	my ( $client, $ref, $target, $depth ) = @_;
	return __PACKAGE__->collectionItem( $client, { id => $target->{id}, title => $ref->{title}, image => $ref->{image} }, $depth );
}

sub _stationItem {
	my ( $client, $ref ) = @_;

	for my $slug ( _slugCandidates( $ref->{path} ) ) {
		my $id = Plugins::ABCListen::Stations->byPageSlug($slug);
		return Plugins::ABCListen::Live->stationItem( $client, $id ) if defined $id && length $id;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug( "ABC listen: no station for $ref->{type} card " . $ref->{path} );
	return undef;
}

# Live-page slugs to try for a station card's path, in order: the segment after 'live', then the
# first segment that is not 'listen' or 'live' ('/listen/live/sport' -> sport; '/pacific/live' ->
# pacific; '/listen/radionational' -> radionational).
sub _slugCandidates {
	my @segments = _segments(shift);
	my @slugs;

	for my $i ( 0 .. $#segments - 1 ) {
		if ( $segments[$i] eq 'live' ) {
			push @slugs, $segments[ $i + 1 ];
			last;
		}
	}

	my ($first) = grep { $_ ne 'listen' && $_ ne 'live' } @segments;
	push @slugs, $first if defined $first && !grep { $_ eq $first } @slugs;

	return @slugs;
}

# Whether L1's live API is there: Stations->byPageSlug and Live->stationItem.
sub _stationsAvailable {
	$stationsLoaded = ( eval { require Plugins::ABCListen::Stations; 1 } ? 1 : 0 ) unless defined $stationsLoaded;

	return $stationsLoaded
		&& Plugins::ABCListen::Stations->can('byPageSlug')
		&& ( eval { require Plugins::ABCListen::Live; 1 } )
		&& Plugins::ABCListen::Live->can('stationItem') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# A page of cards
# ---------------------------------------------------------------------------

sub itemsFor {
	my ( $class, $client, $refs, $depth, $cb ) = @_;
	my $once = _once($cb);

	my $fail = sub {
		$log->error( 'Building ABC listen collection items failed: ' . ( shift || 'unknown error' ) );
		$once->( [] );
	};

	eval {
		my ( %seen, @refs );
		for my $ref ( grep { ref $_ eq 'HASH' } @{ ref $refs eq 'ARRAY' ? $refs : [] } ) {
			my $key = join '/', map { defined $_ ? $_ : '' } $ref->{type}, $ref->{id};
			push @refs, $ref unless $seen{$key}++;
		}

		_resolveNames( \@refs, sub {
			my $named = shift;
			my $items = eval { [ grep {defined} map { $class->itemFor( $client, $_, $depth ) } @$named ] };
			$items ? $once->($items) : $fail->($@);
		} );

		1;
	} or $fail->($@);

	return;
}

# Look up the names of the program refs that may carry a tagline (see itemsFor);
# $cb->(\@refs) once, with copies renamed where a lookup succeeded before the deadline.
sub _resolveNames {
	my ( $refs, $cb ) = @_;

	my ( @queue, %queued );
	for my $ref (@$refs) {
		next if $ref->{hero};
		my $target = _target($ref) or next;
		next unless $target->{kind} eq 'program';
		push @queue, $ref->{path} unless $queued{ $ref->{path} }++;
	}

	return $cb->($refs) unless @queue;

	my %names;
	my ( $active, $finished, $pumping, $timer, $pump ) = ( 0, 0, 0 );

	my $finish = sub {
		return if $finished++;

		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;

		$cb->( [ map { _renamed( $_, \%names ) } @$refs ] );
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + NAME_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( 'ABC listen: program names not all found within ' . NAME_DEADLINE . ' s; the rest keep their card titles' );
		$finish->();
	} );

	$pump = sub {
		return if $pumping;
		$pumping = 1;

		while ( $active < NAME_CONCURRENCY && @queue ) {
			my $path    = shift @queue;
			my $settled = 0;
			$active++;

			my $done = sub {
				my $detail = shift;
				return if $settled++;
				$active--;

				# found after the deadline: the lookup only warmed the cache
				$names{$path} = $detail->{title} if !$finished && ref $detail eq 'HASH' && !$detail->{error} && _hasText( $detail->{title} );

				$pump->() if $pump;
			};

			eval { Plugins::ABCListen::Programs::program( $path, $done ); 1 } or do {
				$log->warn( "ABC listen: program name lookup for $path failed: " . ( $@ || 'unknown error' ) );
				$done->( { error => LOAD_FAILED } );
			};
		}

		$pumping = 0;

		if ( !$active && !@queue ) {
			undef $pump;    # no more lookups: break the closure's reference to itself
			$finish->();
		}

		return;
	};

	$pump->();
	return;
}

# The ref named with its program's own name; the card's cardTitle (tagline, else title) becomes
# the tagline if it differs.
sub _renamed {
	my ( $ref, $names ) = @_;

	return $ref if $ref->{hero} || !defined $ref->{path};

	my $name = $names->{ $ref->{path} };
	return $ref unless defined $name;

	my $target = _target($ref);
	return $ref unless $target && $target->{kind} eq 'program';

	my $cardTitle = defined $ref->{tagline} ? $ref->{tagline} : $ref->{title};

	return { %$ref, title => $name, tagline => _hasText($cardTitle) && !_same( $cardTitle, $name ) ? $cardTitle : undef };
}

# ---------------------------------------------------------------------------
# Feed helpers (every feed calls back exactly once)
# ---------------------------------------------------------------------------

# Run $code (which answers $cb itself); if it dies, answer $cb with the LOAD_FAILED item.
sub _try {
	my ( $client, $cb, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Building the ABC listen collection menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen collection menu failed: ' . ( $@ || 'unknown error' ) );
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
	$token = LOAD_FAILED unless _isText($token) && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/;
	return { name => cstring( $client, $token ), type => 'text' };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A callback wrapper that passes on only the first call and logs (never propagates) a death.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub {
		return if $called++;
		eval { $cb->(@_) if ref $cb eq 'CODE'; 1 } or $log->error( 'ABC listen collections callback failed: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# Run $code; if it dies, log and answer $fail with LOAD_FAILED (ignored if it has answered).
sub _guard {
	my ( $fail, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Processing ABC listen collection data failed: ' . ( $@ || 'unknown error' ) );
		$fail->( { error => LOAD_FAILED } );
	};
	return;
}

sub _token {
	my $error = shift;
	my $token = ref $error eq 'HASH' ? $error->{error} : undef;
	return _isText($token) && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/ ? $token : LOAD_FAILED;
}

# Entity-decoded, trimmed text, or undef when empty.
sub _text {
	my $text = shift;
	return undef unless _isText($text);
	$text = decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;
	return length $text ? $text : undef;
}

sub _same { lc( $_[0] =~ s/\A\s+|\s+\z//gr ) eq lc( $_[1] =~ s/\A\s+|\s+\z//gr ) }

# The path's segments ('/listen/live/sport' -> listen, live, sport); () for undef.
sub _segments {
	my $path = shift;
	return () unless _isText($path);
	$path =~ s/[?#].*\z//s;
	return grep {length} split m{/}, $path;
}

# The numeric last segment of a path, or undef.
sub _leaf {
	my @segments = _segments(shift);
	return @segments && $segments[-1] =~ /\A[0-9]+\z/ ? $segments[-1] : undef;
}

# A menu level: digits, else $default.
sub _level { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? $_[0] + 0 : $_[1] }

sub _hash    { ref $_[0] eq 'HASH'  ? $_[0]    : {} }
sub _list    { ref $_[0] eq 'ARRAY' ? @{ $_[0] } : () }
sub _isText  { defined $_[0] && !ref $_[0] }
sub _hasText { _isText( $_[0] ) && $_[0] =~ /\S/ }
sub _digits  { _isText( $_[0] ) && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }
sub _int     { _isText( $_[0] ) && $_[0] =~ /\A[0-9]+\z/ ? $_[0] + 0 : undef }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# Forget what was logged once and whether L1's live API loaded (for tests).
sub _reset {
	%loggedComponent = ();
	%warnedType      = ();
	undef $stationsLoaded;
	return;
}

1;
