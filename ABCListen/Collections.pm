package Plugins::ABCListen::Collections;

# The discovery collection engine (ai-state/streams/discovery/master-plan.md, D1): turns an ABC
# listen page's Next data and ABC's BFF collections into OPML items. Data and card dispatcher only:
# no top-level menu code (Discover.pm owns Home; D4's Sections.pm owns News, Sport, Kids listen and
# Audiobooks). Every program, episode and station row comes from the shared builders
# (OnDemand->programItem / episodeItem, Live->stationItem), so playback, favourites and Follow
# behave the same everywhere. All I/O goes through Plugins::ABCListen::API (async).
#
# ---- Callbacks ------------------------------------------------------------------------------------
#   page, home, items, aggregationItems, menuPage, itemsFor, checkOnAir, podcasts, categories (D7),
#   recommendations and withImages call $cb EXACTLY ONCE, on every path. Failures are { error => TOKEN }, the API
#   token passed through ('PLUGIN_ABCLISTEN_LOAD_FAILED' or 'PLUGIN_ABCLISTEN_RATE_LIMITED'). Cache
#   hits call back synchronously, other calls later: code must work either way. A callback that
#   dies is logged and never leads to a second call.
#   Every public function works as a class method (Plugins::ABCListen::Collections->page(...)) or as
#   a plain function (Plugins::ABCListen::Collections::itemFor($client, $ref, $depth)).
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
#         RecommendationsExperiment, ExperimentEnroller, AppStoreCTA, AppOnwardJourney: ignored;
#         any other component (Promo, TeaserNavigator, Tracklist, ...): ignored, logged once per
#         name at DEBUG.
#       A handler that dies is logged (WARN, once per component name) and skipped.
#       Extending: add an entry to %COMPONENTS, sub { my ($component, $page) = @_; ... }, that
#       pushes onto $page (new keys are fine: callers ignore keys they don't know).
#     D4 (section pages: News, Sport, Kids listen, Audiobooks) adds these components and keys; Home
#     ignores the new keys:
#         MetaCollection      componentProps.items[] (sub-collections) -> collections { id, title,
#                             image => undef } in order; a sub-collection whose itemsCount is 0 is
#                             omitted (a missing itemsCount is kept). They page with items(), no
#                             rootMetaCollectionId needed.
#         ProgramAggregationCollection
#                             { id (componentProps.id, else the contentUri id, else key), title
#                             (title, else heading), image (first supported embedded card),
#                             kind => 'aggregation' } -> collections, paged by aggregationItems
#                             (see %FETCHERS); omitted like a StandardCollection without a
#                             supported embedded card.
#         MiniEPG             { serviceId => uc(papiServiceId), title, start, end (epochs or undef),
#                             component => 'MiniEPG' } -> stations
#         LiveRadioCarousel   componentProps.cards[] -> stations, each as MiniEPG's plus
#                             component => 'LiveRadioCarousel' and heading => componentProps.heading
#                             (undef when empty). Entries without a papiServiceId are dropped.
#         stationCards        { <collection id> => [card refs] } for each kept StandardCollection whose
#                             supported embedded cards all map to live stations (Sport's "Radio
#                             Stations"), so a section can list them inline.
#       An untitled StandardCollection keeps title undef; collectionItem names it Featured.
#     D6 adds one key (callers that don't use it ignore it):
#         categoriesId        the id of the page's categories collection: the first
#                             StandardCollection that is a categories collection by podcasts()'s
#                             rule (D7, _categoriesCollection: every supported embedded card is a
#                             podcast category card, i.e. a dynamiccollection card whose path ends
#                             in a numeric page id, and they name at least 2 different pages; a
#                             category card in a mixed collection does not count); undef when that
#                             collection has no id (a later one is not looked at); absent when no
#                             StandardCollection qualifies. Home leaves it out.
#   home($cb)  = page('/listen', $cb).
#
#   items($collectionId, $offset, $size, $cb, \%extraQuery)
#       -> $cb->({ title, total, count, cards => [refs] }) | $cb->({ error => TOKEN })
#       API::bff('collection/x', { collectionId, offset, size }) (ttl 30 min, stale_ok, timeout 8 s).
#       title = collection.title, else collection.heading; total = collection.pagination.total
#       (undef when missing); count = how many cards ABC sent (for paging; cards without a parseable
#       contentUri are dropped from cards). A null or empty collection is { total => undef or 0,
#       count => 0, cards => [] }. offset defaults to 0, size to PAGE_SIZE (20).
#       \%extraQuery (optional, D2): its plain-text values are merged into the query (e.g. a
#       MetaCollection sub-collection's { rootMetaCollectionId, metaInMeta => 'false' });
#       collectionId, offset and size always win. Without it the request is unchanged.
#
#   aggregationItems($collectionId, $offset, $size, $cb, \%extraQuery)                         (D4)
#       As items(), from API::bff('programAggregationCollection/x', { collectionId, offset, size })
#       (same response shape; ttl 6 h, stale_ok, timeout 8 s). E.g. All Kids listen programs, 9317914.
#
#   checkOnAir(\@serviceIds, $cb) -> $cb->()                                                    (D4)
#       Makes sure Live->stationItem knows whether the event-only services among the ids are on air:
#       Stations->checkOnAir for those, then $cb->() once - when all are known, at the NAME_DEADLINE
#       (3 s), or at once when there are none (or L1's Stations->checkOnAir / get are absent).
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
#         channel / externallink whose path Stations->byPageSlug maps to a service (contract 7: live
#         pages, network homes, /listen/news; not /news, the ABC News website)
#                                          -> Live->stationItem($client, Stations->byPageSlug($path));
#                                             L1 owns the path rules. undef while Stations->byPageSlug
#                                             or Live->stationItem don't exist, or when the path maps
#                                             to nothing (other links).
#         teaser, unknown (hero)           -> by path: a /programs/ path whose last segment is all
#                                             digits -> episode (that id, docType audioepisode);
#                                             '.../programs/<slug>' -> program (no id); else undef
#         anything else (article, video, person, ...) -> undef, logged at DEBUG.
#       A builder that dies: undef, logged at WARN once per card type.
#
#   itemsFor($client, \@refs, $depth, $cb) -> $cb->(\@items)  (never an error)
#       A page of cards -> items: drops duplicates (same type + id), resolves program names (below)
#       and, at the same time, the on-air status of the event-only services that station cards name
#       (checkOnAir, same 3 s deadline: an event station is listed only while it is on air), then
#       itemFor on each; refs that map to nothing are left out (\@items may be empty).
#       Program names (FQ4): every program ref with a path that is not from the hero is looked up
#       with Programs->program($path) (cached 6 h), at most NAME_CONCURRENCY (4) at a time, within
#       NAME_DEADLINE (3 s) for the whole page: cardRef's title is either cardTitle (often an
#       editorial tagline) or the image alt text, which is often a file or tile name
#       ('BackgroundBriefing_3000x3000.jpg', 'Dr Karl Podcast Tile') or another program's name.
#       Found: title = the program's own name (heroImageWithCTAPrepared.heading), and the card's
#       cardTitle becomes the description (tagline) if it differs. Error or deadline: cardRef's
#       title and tagline are kept. Lookups still queued or in flight at the deadline carry on
#       and warm the cache for the next open. Without lookups or event checks it calls back
#       synchronously.
#       U2: an optional 5th argument { names => [ $from, $to ] } looks up only the program refs at
#       positions $from .. $to - 1 of \@refs (after de-duplication); the others keep cardRef's
#       title. A collection menu passes the rows LMS asks for (see collectionItem): LMS shows only
#       those, so the rest are never seen with their card titles.
#
#   collectionItem($client, { id, title, image, kind? }, $depth) -> link | undef
#       A link listed at level $depth (0 at a page root) to the collection's menu at $depth + 1;
#       undef when that passes MAX_DEPTH or without a numeric id. name = title, else
#       PLUGIN_ABCLISTEN_FEATURED (never blank); image = imageUrl(image, 300), else the plugin icon.
#       The menu (U2, #84): the whole collection as one list, itemsFor of every card, no "More…"
#       row (before U2: one page per menu, then "More…"). The cards come from a bounded full
#       fetch (_collectionCards): the first page (menuPage), then, while ABC's total says there is
#       more, the following pages, at most COLLECTION_CONCURRENCY (4) requests at a time, to
#       MAX_COLLECTION_CARDS (200) cards, within COLLECTION_DEADLINE (4 s) of the first page; a
#       page that failed, was empty or was late ends the list there (never a gap; late pages carry
#       on and are cached for the next open). Collections are small (the largest seen, Music and
#       Looking For Something New?, 97 and 100 cards), and itemsFor drops and de-duplicates cards,
#       so a row's index can't be mapped to an ABC page without the pages before it: no partial
#       feed here (the program menu has one). The program names (itemsFor, FQ4) are looked up only
#       for the rows LMS asks for (XMLBrowser's index/quantity, + NAME_SLACK cards for the ones
#       dropped before them): opening one row (quantity 1) looks up at most 1 + NAME_SLACK names,
#       not the whole collection's. Nothing to list: one PLUGIN_ABCLISTEN_EMPTY_COLLECTION
#       text item; first page error: the error token's text item. Every feed answers exactly once.
#       The collection hash travels in the passthrough; its kind (D4) picks the fetcher (menuPage).
#       Optional collection keys (D2):
#         query        => \%extraQuery for the fetcher (MetaCollection sub-collections);
#         fallbackPath => a site page (a podcast category's page): when the first page (offset 0)
#                         fails or has no cards, the menu lists the first collection of
#                         page(fallbackPath) instead, if its id differs (its later pages too).
#                         Otherwise the first result stands.
#
#   menuPage(\%collection, $offset, $cb)                                                         (D4)
#       One page of a collection's menu: the fetcher and page size of its kind in %FETCHERS
#       (kind aggregation: aggregationItems, 50 per page, so All Kids listen programs (34) is one
#       A–Z list; no or an unknown kind: items, PAGE_SIZE (20)), with the collection's query (D2).
#       A new kind of collection needs a %FETCHERS entry, not a _collectionMenu edit. Callers that
#       want a menu's first page ahead of time (D4's Sections) use this, so they share its request
#       and cache. The menu itself adds D2's fallbackPath on top (_menuPage).
#
# ---- D2 additions (Podcasts menu, Popular now / Popular in sport) ---------------------------------
#
#   podcasts($cb) -> $cb->({ collections => [{ id, title, query }], categories => [{ id, title,
#                    image, fallbackPath }], categoriesId => id | undef, stale => 0|1 })
#                    | $cb->({ error => TOKEN })
#       API::nextData('/listen/podcasts') (ttl 1 h, stale_ok, timeout 8 s), componentsContent[]:
#         the first MetaCollection -> collections: its componentProps.items[] { id, title } in
#             order (no numeric id, or itemsCount 0: left out), each with query =>
#             { rootMetaCollectionId => the MetaCollection's id, metaInMeta => 'false' };
#         the first StandardCollection that is a categories collection (D7: page()'s
#             categoriesId rule, _categoriesCollection) -> categories: per category card
#             id = the numeric last segment of articleLink, title = cardTitle, image = the card
#             image, fallbackPath = articleLink's site path; duplicates (same id) dropped, ABC's
#             order kept; categoriesId = that collection's id (componentProps.id, else its key;
#             undef without one). The page renders only the collection's first 8 cards
#             (2026-10-19: 8 of 18), so menus take the full list from categories() below.
#             categoriesId is absent when no collection qualifies.
#       Missing parts are empty lists (callers decide: Discover shows LOAD_FAILED / the static list).
#   staticCategories() -> the 18 podcast categories of 2026-10-19 as above (image undef), in ABC's
#       order: the last fallback of categories().
#
#   categories(\%podcasts, $cb) -> $cb->(\@categories, $source)  (never an error)              (D7)
#       Every podcast category for Browse by category, from podcasts()'s result (or its error):
#         1. the whole categories collection: items-style BFF requests (collection/x, the
#            same URLs and cache entries as items(); ttl PAGE_TTL, stale_ok, timeout 8 s) for
#            categoriesId, CATEGORY_PAGE_SIZE (PAGE_SIZE, 20) cards a page from offset 0, paged to
#            pagination.total (at most CATEGORY_MAX_PAGES pages), the category cards of every page
#            (_categoryCards) in ABC's order, duplicate page ids dropped; source 'collection';
#         2. else the podcasts page's categories (source 'page') - if the collection paging stopped
#            part-way (a page failed, or the deadline), the cards it found first, then the page's
#            cards it had not found (source 'collection+page');
#         3. else staticCategories() (source 'static').
#       Same shape as podcasts()'s categories. No categoriesId (or a podcasts() error): 2 or 3 at
#       once, without a request. Answers at most CATEGORY_DEADLINE (3 s, the Podcasts menu's
#       withImages wait) after the call; pages still in flight then carry on (and go on paging)
#       to warm the cache for the next open. D8: at the deadline, before 2, the whole collection
#       as cached (source 'last-good'): after PAGE_TTL a page is fetched again, and when ABC
#       hangs instead of failing, stale_ok's last-good copy would come only after the request's
#       8 s timeout, so the cached pages are read instead (_cachedCategories: the copy API.pm keeps
#       7 days, whatever its age; used only when it holds every page). Exactly one callback, also
#       if paging or (D8) building the list dies (then the static list).
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
#       and cache entry, as opening it), at most IMAGE_CONCURRENCY (4) at a time, in order (D6).
#       Waits at most IMAGE_DEADLINE (3 s); fetch errors and late answers leave the image undef
#       (collectionItem then uses the plugin icon). Lookups still queued or in flight at the
#       deadline carry on and warm the cache for the menus.
#
# Owned by the discovery stream (D1 creates; D2, D4, D6, D7 and D8 extend additively; U2 made the
# collection menu one list).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util qw(decodeEntities parseISO8601);

use constant PAGE_TTL         => 3600;    # page() Next data
use constant ITEMS_TTL        => 1800;    # items() BFF collections
use constant AGGREGATION_TTL  => 6 * 3600;    # aggregationItems() (D4)
use constant API_TIMEOUT      => 8;       # seconds per request (menu paths; HTTP.pm's default is 15)
use constant PAGE_SIZE        => 20;
use constant AGGREGATION_PAGE_SIZE => 50;    # D4: program aggregations (All Kids listen programs: 34)
use constant MAX_DEPTH        => 3;
use constant NAME_CONCURRENCY => 4;
use constant NAME_DEADLINE    => 3;       # seconds per page
use constant NAME_SLACK       => 10;      # U2: names looked up past a collection menu's window (see collectionItem)
use constant IMAGE_PX         => 300;

use constant PODCASTS_PATH       => '/listen/podcasts';    # D2
use constant RECOMMENDATIONS_TTL => 3600;                  # D2 recommendations()
use constant IMAGE_DEADLINE      => 3;                     # D2 withImages(), seconds
use constant IMAGE_CONCURRENCY   => 4;                     # D6 withImages(): first pages loading at once

use constant CATEGORY_DEADLINE  => IMAGE_DEADLINE;    # D7 categories(): seconds (runs alongside withImages)
use constant CATEGORY_MAX_PAGES => 10;                # D7 categories(): collection pages at most
use constant MIN_CATEGORIES     => 2;                 # D7: category cards a categories collection has at least
use constant LAST_GOOD_TTL      => 7 * 86400;         # D8: API.pm keeps a last-good copy (stale_ok) 7 days

# D7 categories(): cards per collection page (PAGE_SIZE; tests page smaller)
our $CATEGORY_PAGE_SIZE = PAGE_SIZE;

use constant MAX_COLLECTION_CARDS   => 200;    # U2: a collection menu lists at most this many cards
use constant COLLECTION_CONCURRENCY => 4;      # U2: its pages loading at once
use constant COLLECTION_DEADLINE    => 4;      # U2: seconds after the first page for the others

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant EMPTY       => 'PLUGIN_ABCLISTEN_EMPTY_COLLECTION';
use constant FEATURED    => 'PLUGIN_ABCLISTEN_FEATURED';

my $log = logger('plugin.abclisten');

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);

# page() component handlers by component name; undef = ignored without a log line.
my %COMPONENTS = (
	HeroCarousel              => \&_heroCarousel,
	StandardCollection        => \&_standardCollection,
	RecommendationsExperiment => undef,    # D2 (Popular now, Popular in sport)
	ExperimentEnroller        => undef,
	AppStoreCTA               => undef,
	AppOnwardJourney          => undef,

	# ---- D4: section pages (Home ignores the keys these add) ----
	MetaCollection               => \&_metaCollection,
	ProgramAggregationCollection => \&_programAggregation,
	MiniEPG                      => \&_liveStations,
	LiveRadioCarousel            => \&_liveStations,
);

# ---- D4: paging by collection kind (collectionItem's passthrough hash): fetcher and page size ----
# The fetchers look items / aggregationItems up when called (not \&items at load time), so a
# replaced Collections::items (tests, a later redefinition) is the one menus use.
my %FETCHERS = (
	aggregation => { fetch => sub { aggregationItems(@_) }, size => AGGREGATION_PAGE_SIZE },    # one A–Z list
);
my $DEFAULT_FETCHER = { fetch => sub { items(@_) }, size => PAGE_SIZE };

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

	# D6/D7: the first categories collection (podcasts()'s rule) is the page's; decided before the
	# id check, so one without an id makes categoriesId undef rather than naming a later one
	$page->{categoriesId} = $id if !exists $page->{categoriesId} && _categoriesCollection($props);

	return unless defined $id;

	my ($first) = grep { _target($_) } grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( $props->{items} );
	return unless $first;

	push @{ $page->{collections} }, { id => $id, title => _text( $props->{title} ), image => $first->{image} };

	_stationCards( $id, $props, $page );    # D4
	return;
}

# ---- D4: section page components ------------------------------------------------------------------

# A kept StandardCollection whose supported embedded cards are all live stations -> stationCards.
sub _stationCards {
	my ( $id, $props, $page ) = @_;

	my @refs = grep { _target($_) } grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( $props->{items} );
	return if !@refs || grep { _target($_)->{kind} ne 'station' } @refs;

	$page->{stationCards}->{$id} = \@refs;
	return;
}

sub _metaCollection {
	my ( $component, $page ) = @_;

	for my $sub ( _list( _hash( $component->{componentProps} )->{items} ) ) {
		next unless ref $sub eq 'HASH';

		my $id = _digits( $sub->{id} );
		next unless defined $id;

		my $count = _int( $sub->{itemsCount} );
		next if defined $count && $count == 0;    # ABC lists empty sub-collections (Audiobooks "Live Events")

		push @{ $page->{collections} }, { id => $id, title => _text( $sub->{title} ), image => undef };
	}

	return;
}

sub _programAggregation {
	my ( $component, $page ) = @_;
	my $props = _hash( $component->{componentProps} );

	my $id = _digits( $props->{id} );
	if ( !defined $id ) {
		my ( undef, $uriId ) = Plugins::ABCListen::API::coreMediaRef( $props->{contentUri} );
		$id = _digits($uriId);
	}
	$id = _digits( $component->{key} ) unless defined $id;
	return unless defined $id;

	my ($first) = grep { _target($_) } grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( $props->{items} );
	return unless $first;

	my $title = _text( $props->{title} );
	$title = _text( $props->{heading} ) unless defined $title;

	push @{ $page->{collections} }, { id => $id, title => $title, image => $first->{image}, kind => 'aggregation' };
	return;
}

# MiniEPG (its own props) and LiveRadioCarousel (componentProps.cards[]) -> stations.
sub _liveStations {
	my ( $component, $page ) = @_;
	my $props = _hash( $component->{componentProps} );
	my $name  = $component->{component};

	my $carousel = $name eq 'LiveRadioCarousel';
	my $heading  = $carousel ? _text( $props->{heading} ) : undef;

	for my $entry ( grep { ref $_ eq 'HASH' } $carousel ? _list( $props->{cards} ) : ($props) ) {
		my $serviceId = _text( $entry->{papiServiceId} );
		next unless defined $serviceId && $serviceId =~ /\A[A-Za-z0-9_]+\z/;    # 'itinerant_four' happens

		push @{ $page->{stations} }, {
			serviceId => uc $serviceId,
			title     => _text( $entry->{title} ),
			start     => _isText( $entry->{start} ) ? parseISO8601( $entry->{start} ) : undef,
			end       => _isText( $entry->{end} )   ? parseISO8601( $entry->{end} )   : undef,
			component => $name,
			( $carousel ? ( heading => $heading ) : () ),
		};
	}

	return;
}

# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------

sub items {
	shift if _isClass( $_[0] );
	return _bffCollection( 'collection/x', ITEMS_TTL, @_ );
}

# D4: a program aggregation (e.g. All Kids listen programs), same shape as items().
sub aggregationItems {
	shift if _isClass( $_[0] );
	return _bffCollection( 'programAggregationCollection/x', AGGREGATION_TTL, @_ );
}

sub _bffCollection {
	my ( $endpoint, $ttl, $id, $offset, $size, $cb, $extra ) = @_;
	my $once = _once($cb);

	$id = _digits($id);
	return $once->( { error => LOAD_FAILED } ) unless defined $id;

	$offset = _int($offset) || 0;
	$size   = _int($size)   || PAGE_SIZE;

	my %extra = ref $extra eq 'HASH' ? map { $_ => $extra->{$_} } grep { _isText( $extra->{$_} ) } keys %$extra : ();

	Plugins::ABCListen::API::bff(
		$endpoint,
		{ %extra, collectionId => $id, offset => $offset, size => $size },
		sub {
			my $data = shift;
			_guard( $once, sub { $once->( _collectionPage($data) ) } );
		},
		sub { $once->( { error => _token(shift) } ) },
		{ ttl => $ttl, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub _collectionPage {
	my $collection = _hash( _hash(shift)->{collection} );
	my @cards      = _list( $collection->{items} );

	my $title = _text( $collection->{title} );
	$title = _text( $collection->{heading} ) unless defined $title;    # program aggregations have only a heading

	return {
		title => $title,
		total => _int( _hash( $collection->{pagination} )->{total} ),
		count => scalar @cards,
		cards => [ grep {defined} map { Plugins::ABCListen::API::cardRef($_) } @cards ],
	};
}

sub collectionItem {
	shift if _isClass( $_[0] );
	my ( $client, $collection, $depth ) = @_;
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

# A collection's menu (feed): the whole collection as one list (U2: _collectionCards, then itemsFor).
# The passthrough's offset (0 from collectionItem) is where the list starts.
sub _collectionMenu {
	my ( $client, $cb, $args, $collection, $offset, $depth ) = @_;
	my $once = _once($cb);

	$collection = {} unless ref $collection eq 'HASH';
	$offset     = _int($offset) || 0;
	$depth      = _level( $depth, 1 );

	_try( $client, $once, sub {
		_collectionCards( $collection, $offset, sub {
			my $result = shift;

			return _textFeed( $client, $once, $result->{error} ) if $result->{error};

			_try( $client, $once, sub {
				__PACKAGE__->itemsFor( $client, $result->{cards}, $depth, sub {
					my $items = shift;
					_respond( $client, $once, sub { @$items ? $items : [ _textItem( $client, EMPTY ) ] } );
				}, { names => _nameWindow($args) } );
			} );
		} );
	} );

	return;
}

# U2: the cards of a whole collection, from $offset, for one continuous list (no "More…" rows):
# its first page (_menuPage: its kind's fetcher and page size, D2's fallbackPath), then, while
# ABC's total says there is more, the next pages of the collection that page came from, at
# offsets first count + k * page size, until MAX_COLLECTION_CARDS cards, at most
# COLLECTION_CONCURRENCY requests at a time (the same requests and cache entries as the menus'
# pages before). $cb->({ cards }) once: the first page's cards, then each next page's in order up
# to the first page that failed, had no cards or had not answered COLLECTION_DEADLINE seconds after
# the first page did (anything after it is left out, so the list never has a gap; the late pages
# carry on and are cached for the next open); or the first page's { error }.
sub _collectionCards {
	my ( $collection, $offset, $cb ) = @_;
	my $once = _once($cb);

	_menuPage( $collection, $offset, sub {
		my ( $first, $source ) = @_;

		return $once->($first) if $first->{error};

		my @cards = @{ $first->{cards} || [] };
		my $end   = $first->{count} > 0 && defined $first->{total} ? $first->{total} : 0;
		$end = $offset + MAX_COLLECTION_CARDS if $end > $offset + MAX_COLLECTION_CARDS;

		my @offsets;
		for ( my $next = $offset + $first->{count}; $next < $end; $next += _pageSize($source) ) {
			push @offsets, $next;
		}

		return $once->( { cards => \@cards } ) unless @offsets;

		my ( %pages, $timer );
		my ( $active, $finished, $pumping, $pump ) = ( 0, 0, 0 );
		my @queue = @offsets;

		my $finish = sub {
			return if $finished++;

			Slim::Utils::Timers::killSpecific($timer) if $timer;
			undef $timer;

			for my $next (@offsets) {
				my $page = $pages{$next};
				last unless $page && !$page->{error} && $page->{count};
				push @cards, @{ $page->{cards} || [] };
			}
			splice @cards, MAX_COLLECTION_CARDS if @cards > MAX_COLLECTION_CARDS;

			$once->( { cards => \@cards } );
		};

		$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + COLLECTION_DEADLINE, sub {
			undef $timer;
			main::INFOLOG && $log->is_info && $log->info( "ABC listen: collection $source->{id}: pages not all loaded within " . COLLECTION_DEADLINE . " s; listing the pages before the first missing one" );
			$finish->();
		} );

		$pump = sub {
			return if $pumping;
			$pumping = 1;

			while ( $active < COLLECTION_CONCURRENCY && @queue ) {
				my $next    = shift @queue;
				my $settled = 0;
				$active++;

				my $done = sub {
					return if $settled++;
					$pages{$next} = ref $_[0] eq 'HASH' ? $_[0] : { error => LOAD_FAILED };
					$active--;
					$pump->() if $pump;
				};

				eval { menuPage( $source, $next, $done ); 1 } or do {
					$log->error( "ABC listen: loading collection $source->{id} from $next failed: " . ( $@ || 'unknown error' ) );
					$done->( { error => LOAD_FAILED } );
				};
			}

			$pumping = 0;

			if ( !$active && !@queue ) {
				undef $pump;    # every page answered: break the closure's reference to itself
				$finish->();
			}

			return;
		};

		$pump->();
	} );

	return;
}

# U2: the card positions whose program names a collection menu looks up: the rows XMLBrowser asks
# for (index/quantity args: the rows a client lists, or the row it opens with quantity 1), plus
# NAME_SLACK cards (cards dropped before them push the rows later); undef (all) without them.
sub _nameWindow {
	my $args = _hash(shift);
	my $index    = _isText( $args->{index} )    && $args->{index}    =~ /\A([0-9]+)/   ? $1 + 0 : undef;
	my $quantity = _isText( $args->{quantity} ) && $args->{quantity} =~ /\A([0-9]+)\z/ ? $1 + 0 : undef;
	return undef unless defined $index && $quantity;
	return [ $index, $index + $quantity + NAME_SLACK ];
}

# The page size of a collection's kind (%FETCHERS).
sub _pageSize {
	my $kind = _hash(shift)->{kind};
	return ( ( _isText($kind) && $FETCHERS{$kind} ) || $DEFAULT_FETCHER )->{size};
}

# D4: one page of a collection's menu, from $offset: its kind's fetcher and page size.
sub menuPage {
	shift if _isClass( $_[0] );
	my ( $collection, $offset, $cb ) = @_;
	$collection = _hash($collection);

	my $kind    = $collection->{kind};
	my $fetcher = ( _isText($kind) && $FETCHERS{$kind} ) || $DEFAULT_FETCHER;

	return $fetcher->{fetch}->( $collection->{id}, $offset, $fetcher->{size}, $cb, $collection->{query} );
}

# One page of a collection for its menu: menuPage() (its kind's fetcher, its query); at offset 0, when
# that fails or has no cards and the collection has a fallbackPath, the first collection of
# page(fallbackPath) if its id differs (D2: podcast categories). $cb->($result, $collection) once,
# with the collection the result belongs to (U2: _collectionCards loads its later pages).
sub _menuPage {
	my ( $collection, $offset, $cb ) = @_;

	menuPage( $collection, $offset, sub {
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

					menuPage( \%next, 0, sub { $cb->( shift, \%next ) unless $settled++ } );
				} );
			} );
		} );
	} );

	return;
}

# ---------------------------------------------------------------------------
# D2: the podcasts page, recommendations, collection images
# ---------------------------------------------------------------------------

# The podcast categories, ABC's order: [ page id, name, page slug ]. All 18 cards of ABC's categories
# collection 14123152 (collection/x?collectionId=14123152, 2026-10-19; D7): ids and slugs from each
# card's articleLink (/listen/listenapp/<slug>/<id>). The podcasts page renders only the first 8.
my @STATIC_CATEGORIES = (
	[ 104142082 => 'News & Analysis',              'news-and-analysis' ],
	[ 104142226 => 'True Crime',                   'true-crime' ],
	[ 104142200 => 'Sport',                        'sport' ],
	[ 104141842 => 'Kids & Families',              'kids-and-families' ],
	[ 104141924 => 'History',                      'history' ],
	[ 104142164 => 'Society & Culture',            'society-and-culture' ],
	[ 104142058 => 'Music',                        'music' ],
	[ 104141814 => 'Conversations & Storytelling', 'conversations-storytelling' ],
	[ 104141870 => 'Health & Wellbeing',           'health-and-wellbeing' ],
	[ 104142140 => 'Science & Environment',        'science-and-environment' ],
	[ 104141660 => 'Arts & Pop Culture',           'arts-pop-culture' ],
	[ 104141762 => 'Business & Technology',        'business-and-technology' ],
	[ 104141798 => 'Comedy',                       'comedy' ],
	[ 104141952 => 'Indigenous',                   'indigenous' ],
	[ 104141980 => 'Leisure & Lifestyle',          'leisure-and-lifestyle' ],
	[ 104142014 => 'Life Improvement',             'life-improvement' ],
	[ 104142104 => 'Parenting',                    'parenting' ],
	[ 104142128 => 'Religion & Ethics',            'religion-and-ethics' ],
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

	my ( $collections, $categories, $categoriesId );

	for my $component ( _list( _hash( _hash($pageProps)->{data} )->{componentsContent} ) ) {
		next unless ref $component eq 'HASH' && _isText( $component->{component} );

		if ( $component->{component} eq 'MetaCollection' ) {
			$collections ||= _subCollections($component);
		}
		elsif ( $component->{component} eq 'StandardCollection' && !$categories ) {
			# D7: page()'s categoriesId rule (_standardCollection), so both name the same collection
			my $props = _hash( $component->{componentProps} );
			my @cards = _categoriesCollection($props) or next;

			$categories   = [ _categoryList(@cards) ];
			$categoriesId = _digits( $props->{id} );
			$categoriesId = _digits( $component->{key} ) unless defined $categoriesId;
		}
	}

	return {
		collections => $collections || [],
		categories  => $categories  || [],
		$categories ? ( categoriesId => $categoriesId ) : (),
		stale => _hash($info)->{stale} ? 1 : 0,
	};
}

# Podcast category cards: the card refs that are dynamiccollection cards whose path ends in a
# numeric page id (the category's page id). D7: categories() keeps these from the full collection.
sub _categoryCards {
	return grep { ref $_ eq 'HASH' && _isText( $_->{type} ) && $_->{type} eq 'dynamiccollection' && defined _leaf( $_->{path} ) } @_;
}

# D7: a StandardCollection's componentProps -> its category card refs when it is a categories
# collection: every supported embedded card (_target) a category card, naming at least
# MIN_CATEGORIES different page ids; else (). podcasts() lists the first such collection's cards;
# page() names it categoriesId (D6).
sub _categoriesCollection {
	my $props     = shift;
	my @supported = grep { _target($_) } grep {defined} map { Plugins::ABCListen::API::cardRef($_) } _list( $props->{items} );
	my @cards     = _categoryCards(@supported);
	my %pages     = map { _leaf( $_->{path} ) => 1 } @cards;

	return keys %pages >= MIN_CATEGORIES && @cards == @supported ? @cards : ();
}

# Category card refs -> categories { id, title, image, fallbackPath }, the first of each page id.
sub _categoryList {
	my %seen;
	return grep { !$seen{ $_->{id} }++ }
		map { { id => _leaf( $_->{path} ), title => $_->{title}, image => $_->{image}, fallbackPath => $_->{path} } } _categoryCards(@_);
}

# The first of each category id, in order (categories() merging collection and page cards).
sub _uniqueCategories {
	my %seen;
	return grep { ref $_ eq 'HASH' && defined _digits( $_->{id} ) && !$seen{ $_->{id} }++ } @_;
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

# D7: every podcast category (see the header): the whole categories collection, else the podcasts
# page's cards, else the static list; $cb->(\@categories, $source) once, within CATEGORY_DEADLINE.
sub categories {
	shift if _isClass( $_[0] );
	my ( $podcasts, $cb ) = @_;
	my $once = _once($cb);

	$podcasts = _hash($podcasts);

	my @pageCards = $podcasts->{error} ? () : _uniqueCategories( map { {%$_} } grep { ref $_ eq 'HASH' } _list( $podcasts->{categories} ) );
	my $id        = $podcasts->{error} ? undef : _digits( $podcasts->{categoriesId} );
	my $size      = _int($CATEGORY_PAGE_SIZE) || PAGE_SIZE;

	my ( @found, $finished, $timer );

	# $complete: the collection was paged to its end. Else (D8): the cached collection ($lastGood,
	# the deadline's), else what it gave first, then the page's cards. The list is built inside an
	# eval (D8): if building it dies, the static list, so $cb is always called.
	my $finish = sub {
		my ( $complete, $why, $lastGood ) = @_;
		return if $finished++;

		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;

		my ( $list, $source ) = eval { _categoriesList( $complete, \@found, \@pageCards, $lastGood ) };
		if ( ref $list ne 'ARRAY' ) {
			$log->error( 'ABC listen: Browse by category: building the list failed: ' . ( $@ || 'unknown error' ) );
			( $list, $source, $why ) = ( [ staticCategories() ], 'static', 'building the list failed' );
		}

		my $note = 'ABC listen: Browse by category: ' . scalar(@$list) . " categories ($source" . ( defined $why ? "; $why" : '' ) . ')';
		if ( $source eq 'collection' ) { main::DEBUGLOG && $log->is_debug && $log->debug($note) }
		else                           { main::INFOLOG && $log->is_info && $log->info($note) }

		$once->( [ map { {%$_} } @$list ], $source );
	};

	if ( !defined $id ) {
		$finish->( 0, $podcasts->{error} ? 'podcasts page failed' : exists $podcasts->{categoriesId} ? 'no collection id' : 'no categories collection' );
		return;
	}

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + CATEGORY_DEADLINE, sub {
		undef $timer;
		my $why      = "collection $id not loaded within " . CATEGORY_DEADLINE . ' s';
		my $lastGood = eval { _cachedCategories( $id, $size ) };
		$log->error("ABC listen: reading the cached categories collection $id failed: $@") if $@;
		$finish->( 0, $why, $lastGood );
	} );

	my $state = {
		id     => $id,
		size   => $size,
		pages  => 0,
		found  => \@found,
		done   => sub { $finished },
		finish => $finish,
	};

	eval { _categoryPage( $state, 0 ); 1 } or do {
		$log->error( "ABC listen: loading the categories collection $id failed: " . ( $@ || 'unknown error' ) );
		$finish->( 0, 'paging failed' );
	};

	return;
}

# categories()' list: ($list, $source) (see the header). $found: the collection's categories paged
# so far; $pageCards: the podcasts page's; $lastGood: the cached collection (D8) or undef.
sub _categoriesList {
	my ( $complete, $found, $pageCards, $lastGood ) = @_;

	my @collection = _uniqueCategories(@$found);

	return ( \@collection, 'collection' ) if $complete && @collection;
	return ( $lastGood, 'last-good' ) if ref $lastGood eq 'ARRAY' && @$lastGood;    # D8

	my @merged = _uniqueCategories( @collection, @$pageCards );
	return ( \@merged, @collection ? 'collection+page' : 'page' ) if @merged;

	return ( [ staticCategories() ], 'static' );
}

# D8: the whole categories collection from the cache, at the deadline: its pages read from offset 0
# with a LAST_GOOD_TTL ttl, so the copy API.pm keeps (7 days with stale_ok) answers synchronously
# whatever its age. -> [categories] (ABC's order, each page id once) when the cached pages reach the
# collection's end (as _categoryPage pages it, CATEGORY_MAX_PAGES at most), else undef: a page
# without a copy ends the walk (its request joins the one in flight, or starts one that only warms
# the cache; its answer is not used).
sub _cachedCategories {
	my ( $id, $size ) = @_;

	my @found;
	my $offset = 0;
	for ( 1 .. CATEGORY_MAX_PAGES ) {
		my $result;
		_bffCollection( 'collection/x', LAST_GOOD_TTL, $id, $offset, $size, sub { $result = shift } );
		return undef unless ref $result eq 'HASH' && !$result->{error};    # no cached copy: not answered yet

		push @found, _categoryList( _list( $result->{cards} ) );

		my $next = $offset + $result->{count};
		if ( !( $result->{count} > 0 && defined $result->{total} && $next < $result->{total} ) ) {
			my @list = _uniqueCategories(@found);
			return @list ? \@list : undef;
		}
		$offset = $next;
	}

	return undef;    # longer than CATEGORY_MAX_PAGES: not the whole collection
}

# categories(): one page of the categories collection from $offset, then the next while ABC has more
# (CATEGORY_MAX_PAGES at most). Pages answered after the deadline only warm the cache.
sub _categoryPage {
	my ( $state, $offset ) = @_;
	$state->{pages}++;

	_bffCollection( 'collection/x', PAGE_TTL, $state->{id}, $offset, $state->{size}, sub {
		my $result = shift;

		eval {
			if ( $result->{error} ) {
				$state->{finish}->( 0, "collection $state->{id} failed at offset $offset" );
				return 1;
			}

			push @{ $state->{found} }, _categoryList( _list( $result->{cards} ) ) unless $state->{done}->();

			my $next = $offset + $result->{count};
			my $more = $result->{count} > 0 && defined $result->{total} && $next < $result->{total};

			if ( $more && $state->{pages} < CATEGORY_MAX_PAGES ) {
				_categoryPage( $state, $next );
			}
			else {
				$state->{finish}->( $more ? 0 : 1, $more ? "collection $state->{id} longer than " . CATEGORY_MAX_PAGES . ' pages' : undef );
			}

			1;
		} or do {
			$log->error( "ABC listen: paging the categories collection $state->{id} failed: " . ( $@ || 'unknown error' ) );
			$state->{finish}->( 0, 'paging failed' );
		};
	} );

	return;
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
	shift if _isClass( $_[0] );
	my ( $collections, $cb ) = @_;
	my $once = _once($cb);

	my @copies  = map { {%$_} } grep { ref $_ eq 'HASH' } _list($collections);
	my @pending = grep { !defined $_->{image} && defined _digits( $_->{id} ) } @copies;

	return $once->( \@copies ) unless @pending;

	my ( $active, $finished, $pumping, $timer, $pump ) = ( 0, 0, 0 );

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

	# D6: at most IMAGE_CONCURRENCY first pages at a time (as _resolveNames' NAME_CONCURRENCY);
	# lookups still queued at the deadline carry on and warm the cache the menus use.
	$pump = sub {
		return if $pumping;
		$pumping = 1;

		while ( $active < IMAGE_CONCURRENCY && @pending ) {
			my $collection = shift @pending;
			my $settled    = 0;
			$active++;

			my $done = sub {
				my $result = shift;
				return if $settled++;
				$active--;

				my ($card) = grep { defined $_->{image} && _target($_) } _list( _hash($result)->{cards} );
				$collection->{image} = $card->{image} if $card && !$finished;

				$pump->() if $pump;
			};

			eval { items( $collection->{id}, 0, PAGE_SIZE, $done, $collection->{query} ); 1 } or do {
				$log->warn( "ABC listen: collection image lookup for $collection->{id} failed: " . ( $@ || 'unknown error' ) );
				$done->( {} );
			};
		}

		$pumping = 0;

		if ( !$active && !@pending ) {
			undef $pump;    # no more lookups: break the closure's reference to itself
			$finish->();
		}

		return;
	};

	$pump->();
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
	shift if _isClass( $_[0] );
	my ( $client, $ref, $depth ) = @_;
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
# Stations carry their service id.
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

	if ( $type eq 'channel' || $type eq 'externallink' ) {
		my $id = _serviceId($path);
		return defined $id ? { kind => 'station', id => $id } : undef;
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
	my ( $client, $ref, $target ) = @_;

	my $item = Plugins::ABCListen::Live->stationItem( $client, $target->{id} );
	main::DEBUGLOG && $log->is_debug && !$item && $log->debug("ABC listen: station $target->{id} ($ref->{path}) is not listed (hidden, HLS-only or off air)");

	return $item;
}

# The live service a station card's path names (contract 7: L1's Stations->byPageSlug owns the
# rules), or undef - also while L1's live API is absent.
sub _serviceId {
	my $path = shift;
	return undef unless _hasText($path) && _stationsAvailable();

	my $id = Plugins::ABCListen::Stations->byPageSlug($path);
	return _hasText($id) ? $id : undef;
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
	shift if _isClass( $_[0] );
	my ( $client, $refs, $depth, $cb, $opts ) = @_;
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

		# program names and (D4) event stations' on-air status, in parallel; then build
		my ( $named, $pending ) = ( undef, 2 );
		my $build = sub {
			return if --$pending;
			my $items = eval { [ grep {defined} map { __PACKAGE__->itemFor( $client, $_, $depth ) } @$named ] };
			$items ? $once->($items) : $fail->($@);
		};

		my @stations = map { $_->{id} } grep { $_ && $_->{kind} eq 'station' } map { _target($_) } @refs;

		_resolveNames( \@refs, sub { $named = shift; $build->() }, _hash($opts)->{names} );
		checkOnAir( \@stations, $build );

		1;
	} or $fail->($@);

	return;
}

# ---- D4: event-only live services --------------------------------------------------------------------

sub checkOnAir {
	shift if _isClass( $_[0] );
	my ( $ids, $cb ) = @_;
	my $once = _once($cb);

	my %seen;
	my @events = grep { !$seen{$_}++ && _isEventOnly($_) } grep { _hasText($_) } @{ ref $ids eq 'ARRAY' ? $ids : [] };

	return $once->() unless @events && Plugins::ABCListen::Stations->can('checkOnAir');

	my $timer;
	my $finish = sub {
		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;
		$once->();
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + NAME_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( 'ABC listen: event services not all known within ' . NAME_DEADLINE . " s (@events); listing the ones known on air" );
		$once->();
	} );

	eval { Plugins::ABCListen::Stations->checkOnAir( \@events, $finish ); 1 } or do {
		$log->error( 'ABC listen: checking the event services failed: ' . ( $@ || 'unknown error' ) );
		$finish->();
	};

	return;
}

sub _isEventOnly {
	my $id = shift;
	return 0 unless _stationsAvailable() && Plugins::ABCListen::Stations->can('get');

	my $rec = eval { Plugins::ABCListen::Stations->get($id) };
	return ref $rec eq 'HASH' && $rec->{eventOnly} ? 1 : 0;
}

# Look up the names of the program refs that may carry a tagline (see itemsFor);
# $cb->(\@refs) once, with copies renamed where a lookup succeeded before the deadline.
sub _resolveNames {
	my ( $refs, $cb, $window ) = @_;
	my ( $from, $to ) = ref $window eq 'ARRAY' ? @$window : ( 0, scalar @$refs );

	my ( @queue, %queued );
	for my $ref ( @$refs[ grep { $_ >= $from && $_ < $to } 0 .. $#$refs ] ) {
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
