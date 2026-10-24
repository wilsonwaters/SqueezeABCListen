#!/usr/bin/perl
# Plugins::ABCListen::Search (D3), offline (SimpleAsyncHTTP stub, fake clock, server time zone
# Australia/Sydney): the top-level "Search" item (exact keys, weight, menuWeights, its place in the
# top level); the two Algolia request bodies (filters, hitsPerPage, attributesToRetrieve,
# normalised query, no filter injection); API.pm's result cache for repeated and differently
# cased queries; program and episode mapping through O2's builders; episode meta-cache seeding
# (and O1 playing a result without a request); the DQ4 status filter; group names with counts;
# no results / only programs / only episodes; missing thumbnails, malformed objectIDs, duplicates,
# highlight markup; RATE_LIMITED, LOAD_FAILED and partial failures; empty queries; exactly one
# feed callback on every path, also with responses arriving in either order.
# D9: both queries filtered by the A–Z's site rule (site or URL segments, ProgramIndex::siteFilter)
# and the programs query with distinct 0, against a fake of ABC's index (D8's recorded program
# hits): "AM" lists AM (siteSegment adelaide) and its episode, "persuasion" both Persuasions
# (named by network, as in the A–Z), Big Ideas' legacy and current documents merged by D8's rule
# (ProgramIndex::mergeTwins), the 4 Mornings kept apart; D3's own queries reproduce the gaps; still
# 2 queries per uncached search.
#
# Fixtures (t/data/discovery/, raw response bodies as served, the research {_fixture_note, data}
# wrapper stripped; shapes unedited):
#   algolia-listen_prod_all-query.json  POST https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query
#       {"query":"science show","hitsPerPage":3,"facets":["*"]} (2026-10-19; hits trimmed to 2 in research):
#       two Science Show audiosegments, statuses AVAILABLE/NONE, one defaultThumbnail a plain URL, one ratios
#   algolia-programs-list.json          POST .../listen_prod_all/query {"filters":"contentType:program AND
#       (<DQ3 site segments>)","hitsPerPage":1000} (2026-10-19; 724 programs trimmed to 3 in research)
# Synthetic: algolia-search-empty.synthetic.json (no hits),
#   algolia-search-episodes-edge.synthetic.json (status matrix, missing thumbnails/renditions/dates,
#   a window that opens later, /geo-001/, malformed objectIDs, a non-audio hit, a duplicate, entities,
#   _highlightResult), algolia-search-programs-edge.synthetic.json (no canonicalURL, off-site page,
#   malformed objectID, duplicate, description fallback, non-program hit, _highlightResult).
# The search page is F3's t/data/foundation/listen-search.trimmed.html (app id TESTAPPID, key
# testsearchkey: never a real Algolia key).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use Encode ();
use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::ProgramIndex;
use Plugins::ABCListen::Search;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $SEARCH_CLASS = 'Plugins::ABCListen::Search';
my $SEARCH_FEED  = \&Plugins::ABCListen::Search::_search;
my $SITE         = 'https://www.abc.net.au';
my $ALGOLIA      = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $T0           = 1_792_400_000;    # Mon 19 Oct 2026, 08:53 UTC (19:53 in Sydney)
my $ICON         = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE    = { 'Content-Type' => 'application/json' };
my $WCMS         = 'https://live-production.wcms.abc-cdn.net.au';
my $OPEN_END     = 4_102_444_800;    # an open window end in the episode meta cache (Episode.pm)

my $LOAD_FAILED  = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $RATE_LIMITED = string('PLUGIN_ABCLISTEN_RATE_LIMITED');

my $D3_SEGMENTS = '(siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)';
# D9: the A–Z's site rule (D8): the site segments or a URL segment naming an ABC listen site
my $SEGMENTS = '(siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific'
	. ' OR canonicalURI_fragments:listen OR canonicalURI_fragments:triplej OR canonicalURI_fragments:kidslisten'
	. ' OR canonicalURI_fragments:triplejunearthed OR canonicalURI_fragments:pacific)';
my $PROGRAM_FILTER = "contentType:program AND $SEGMENTS";
my $EPISODE_FILTER = "(contentType:audioepisode OR contentType:audio OR contentType:audiosegment) AND $SEGMENTS";
my @ATTRIBUTES = qw(objectID title canonicalURL contentType defaultThumbnail programDefaultThumbnail infoSource
	shortTeaserText description teaserText synopsis programTitle programID duration dates mediaRenditions
	mediaDownloadStatus mediaStreamingStatus programType);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub group_of {
	my $body = shift;
	my $params = eval { JSON::PP::decode_json($body) } || {};
	return ( $params->{filters} || '' ) =~ /\AcontentType:program / ? 'programs' : 'episodes';
}

# Answer the Algolia POSTs by query kind: programs => { file | content | code | error | defer }, episodes => {...}
sub serve {
	my %by = @_;
	Slim::Networking::SimpleAsyncHTTP->addRoute( $ALGOLIA, sub {
		my ( $url, $method, $body ) = @_;
		my $response = $by{ group_of($body) } or return { error => 'no test response for this query' };
		my %r = ( headers => $JSON_TYPE, %$response );
		$r{content} = fixture( delete $r{file} ) if $r{file};
		return \%r;
	} );
}

sub serve_science {
	serve(
		programs => { file => 'discovery/algolia-programs-list.json' },
		episodes => { file => 'discovery/algolia-listen_prod_all-query.json' },
		@_,
	);
}

sub algolia_requests { grep { $_->{url} eq $ALGOLIA } requests() }
sub bodies           { map { JSON::PP::decode_json( $_->{body} ) } algolia_requests() }

# Run the search feed as XMLBrowser does: ($client, $cb, $args, @passthrough). Returns the collector.
sub search {
	my ( $args, $client, @passthrough ) = @_;
	my $c = collector();
	$SEARCH_FEED->( $client, $c->cb, $args, @passthrough );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] || [] } ] }

sub group {
	my ( $items, $prefix ) = @_;
	my ($group) = grep { ( $_->{name} || '' ) =~ /\A\Q$prefix\E \(/ } @{ $items || [] };
	return $group;
}

sub ids { [ map { $_->{passthrough}->[0]->{id} } @{ $_[0] || [] } ] }

sub text_item { { name => $_[0], type => 'text' } }
sub no_results { text_item( string( 'PLUGIN_ABCLISTEN_NO_RESULTS', $_[0] ) ) }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && !ref $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty name" );
}

sub errors_logged   { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

sub epoch { my ( $y, $mo, $d, $h, $mi ) = @_; return timegm( 0, $mi, $h, $d, $mo - 1, $y ) }

my $EPISODE_NAME = qr/\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2}(?: \d{4})? \x{2013} \S/;

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

subtest 'top level: one "Search" item of type search, with the search weight; menuWeights' => sub {
	fresh();
	my $c = collector();
	$SEARCH_CLASS->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'one callback' );

	my ($items) = $c->args(0);
	is_deeply(
		$items,
		[ { name => 'Search', type => 'search', url => $SEARCH_FEED, image => $ICON, weight => 80 } ],
		'exact keys: name "Search", type search, url _search, icon, weight'
	);
	is( $items->[0]->{name},   string('PLUGIN_ABCLISTEN_SEARCH'),                   'from PLUGIN_ABCLISTEN_SEARCH (the name is the input prompt)' );
	is( $items->[0]->{weight}, Plugins::ABCListen::Util::topWeight('search'), 'weight = Util::topWeight("search")' );
	is_deeply( [ $SEARCH_CLASS->menuWeights ], [ Plugins::ABCListen::Util::topWeight('search') ], 'menuWeights = (topWeight("search"))' );
	is( scalar requests(), 0, 'no network access for the top level' );

	$c = collector();
	$SEARCH_CLASS->menuItems( ABCListenTest::FakeClient->new('00:00:00:00:00:01'), $c->cb, {} );
	is( ( $c->args(0) )[0]->[0]->{name}, 'Search', 'with a client too' );
};

subtest 'top level: Search sorts after Programs and before My ABC listen' => sub {
	fresh();
	no warnings qw(redefine once);
	my $top = sub { my $name = shift; return { name => "Top $name", type => 'link', url => 'https://example.test/', weight => Plugins::ABCListen::Util::topWeight($name) } };
	local *Plugins::ABCListen::Live::menuItems     = sub { $_[2]->( [ $top->('radio') ] ) };
	local *Plugins::ABCListen::OnDemand::menuItems = sub { $_[2]->( [ $top->('programs') ] ) };
	local *Plugins::ABCListen::Discover::menuItems = sub { $_[2]->( [ map { $top->($_) } qw(home podcasts news sport kids audiobooks) ] ) };
	local *Plugins::ABCListen::MyABC::menuItems    = sub { $_[2]->( [ $top->('myabc') ] ) };

	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( undef, $c->cb, { params => {} } );
	is( $c->count, 1, 'one callback' );
	my ($result) = $c->args(0);
	is_deeply(
		names( $result->{items} ),
		[ 'Top home', 'Top radio', 'Top podcasts', 'Top news', 'Top sport', 'Top kids', 'Top audiobooks', 'Top programs', 'Search', 'Top myabc' ],
		'Home · Radio · Podcasts · News · Sport · Kids listen · Audiobooks · Programs · Search · My ABC listen'
	);
	my ($search) = grep { $_->{name} eq 'Search' } @{ $result->{items} };
	is( $search->{type}, 'search', 'the Search item is a search (text input) item' );
	ok( !exists $search->{weight}, 'its weight was used for sorting and removed' );
	is( scalar requests(), 0, 'no request for the top level' );
};

# ---------------------------------------------------------------------------
# Requests, normalisation and the cache
# ---------------------------------------------------------------------------

subtest 'two Algolia queries: exact bodies (filters, hitsPerPage 20/40, attributes, normalised query)' => sub {
	fresh();
	serve_science();

	my $c = search( { search => "  Science \t SHOW \n" } );
	is( $c->count, 1, 'one feed callback' );

	my @posts = algolia_requests();
	is( scalar @posts, 2, 'two POSTs to the discovered Algolia URL' );
	is_deeply( [ map { $_->{method} } @posts ], [ 'POST', 'POST' ], 'both POST' );

	my %body = map { group_of( $_->{body} ) => JSON::PP::decode_json( $_->{body} ) } @posts;
	is_deeply(
		$body{programs},
		{ query => 'science show', hitsPerPage => 20, distinct => 0, filters => $PROGRAM_FILTER, attributesToRetrieve => \@ATTRIBUTES },
		'programs: query, hitsPerPage 20, distinct 0 (D9), contentType:program AND the ABC listen sites (D9: site or URL segments), attributesToRetrieve'
	);
	is_deeply(
		$body{episodes},
		{ query => 'science show', hitsPerPage => 40, filters => $EPISODE_FILTER, attributesToRetrieve => \@ATTRIBUTES },
		'episodes: query, hitsPerPage 40, the three audio content types AND the ABC listen sites (D9: site or URL segments), attributesToRetrieve; the index\'s distinct'
	);
	like( $posts[0]->{body}, qr/"hitsPerPage":(?:20|40)[,}]/, 'hitsPerPage sent as a JSON number' );
	like( ( grep { group_of( $_->{body} ) eq 'programs' } @posts )[0]->{body}, qr/"distinct":0[,}]/, 'distinct sent as the JSON number 0' );
	is( $posts[0]->{headers}->header('X-Algolia-API-Key'), 'testsearchkey', 'the key discovered from the search page (API.pm)' );
};

subtest 'query normalisation: trimmed, whitespace collapsed, lower-cased, cut to 100 characters' => sub {
	my @cases = (
		[ 'Science Show',               'science show',  'lower-cased' ],
		[ "\x{a0} science\x{a0}\x{a0}show ", 'science show', 'no-break spaces collapse too' ],
		[ 'CAFÉ Négritude',             'café négritude', 'non-ASCII lower-cased' ],
		[ ( 'abcdefghij' x 10 ) . 'KLMNOP', 'abcdefghij' x 10, 'more than 100 characters: the first 100' ],
		[ ( 'x' x 99 ) . ' yz',         'x' x 99,        'cut at 100, then trailing whitespace trimmed' ],
	);

	for my $case (@cases) {
		my ( $in, $want, $label ) = @$case;
		fresh();
		serve_science();
		search( { search => $in } );
		is_deeply( [ map { $_->{query} } bodies() ], [ $want, $want ], "$label: '$want'" );
	}

	# the same text as UTF-8 bytes (a web request) and as characters: one query and one cache key
	fresh();
	serve_science();
	search( { search => Encode::encode( 'UTF-8', 'Café Science' ) } );
	is_deeply( [ map { $_->{query} } bodies() ], [ 'café science', 'café science' ], 'UTF-8 bytes are decoded first' );
	search( { search => 'CAFÉ science' } );
	is( scalar algolia_requests(), 2, 'the same query as characters: served from the cache, no new request' );
};

subtest 'quotes, &, :, emoji: sent JSON-encoded in query only, never in filters' => sub {
	fresh();
	serve_science();

	my $q = q{science" OR contentType:article & "café" 🎧};
	search( { search => $q } );

	my @bodies = bodies();
	is( scalar @bodies, 2, 'two requests' );
	is_deeply( [ sort map { $_->{filters} } @bodies ], [ sort $EPISODE_FILTER, $PROGRAM_FILTER ], 'filters are exactly the fixed filters (no injection)' );
	is_deeply( [ map { $_->{query} } @bodies ], [ ( lc $q ) x 2 ], 'the whole text is the query' );
	like( Encode::decode( 'UTF-8', ( algolia_requests() )[0]->{body} ), qr/"query":"science\\" or contenttype:article & \\"café\\" 🎧"/, 'sent as UTF-8 JSON, quotes escaped' );

	search( { search => uc $q } );
	is( scalar algolia_requests(), 2, 'same query differently cased: cache hit, stable key for non-ASCII text' );
};

subtest 'cache: a repeated, re-cased or re-spaced query makes no request (1 h, API.pm)' => sub {
	fresh();
	serve_science();

	my $first = search( { search => 'science show' } );
	is( scalar algolia_requests(), 2, 'first search: two requests' );

	my $again = search( { search => 'science show' } );
	is( scalar algolia_requests(), 2, 'identical query: no new request' );
	is_deeply( items_of($again), items_of($first), 'same results' );

	search( { search => 'Science  Show' } );
	search( { search => ' SCIENCE SHOW ' } );
	is( scalar algolia_requests(), 2, '"Science  Show" and " SCIENCE SHOW ": no new request' );

	search( { search => 'science' } );
	is( scalar algolia_requests(), 4, 'a different query: two new requests' );

	advanceTime(3601);
	search( { search => 'science show' } );
	is( scalar algolia_requests(), 6, 'after an hour: asked again' );
};

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

subtest 'result menu: "Programs (N)" and "Episodes (M)" links with the rows inline' => sub {
	fresh();
	serve_science();

	my $c = search( { search => 'science show' } );
	my $items = items_of($c);
	is_deeply( names($items), [ 'Programs (3)', 'Episodes (2)' ], 'group names carry the counts, programs first' );
	is( $items->[0]->{name}, string( 'PLUGIN_ABCLISTEN_SEARCH_PROGRAMS', 3 ), 'from PLUGIN_ABCLISTEN_SEARCH_PROGRAMS' );
	is( $items->[1]->{name}, string( 'PLUGIN_ABCLISTEN_SEARCH_EPISODES', 2 ), 'from PLUGIN_ABCLISTEN_SEARCH_EPISODES' );

	for my $g (@$items) {
		is_deeply( [ sort keys %$g ], [qw(items name type)], "$g->{name}: exact keys name, type, items" );
		is( $g->{type}, 'link', "$g->{name}: a link (no description: LMS menu rule 1)" );
		is( scalar @{ $g->{items} }, $g->{name} =~ /\((\d+)\)/ ? $1 : -1, "$g->{name}: the count is the number of rows" );
	}

	check_names( $items, 'groups' );
	check_names( $_->{items}, $_->{name} ) for @$items;
	is( scalar errors_logged() + scalar warnings_logged(), 0, 'nothing logged at WARN or ERROR' );
};

subtest 'program hits -> OnDemand->programItem (path, id, image, description, network)' => sub {
	fresh();
	serve_science();

	my $programs = group( items_of( search( { search => 'science show' } ) ), 'Programs' )->{items};
	is_deeply( names($programs), [ 'Saturday Night Country', 'The Walkers: The Real Salt Path', 'The Making of an Autocrat' ], 'relevance order; titles trimmed' );

	my $first = {
		title       => 'Saturday Night Country',
		path        => '/listen/programs/saturdaynightcountry',
		id          => '7462314',
		image       => "$WCMS/0af840be01308fcdc934b82c3cf0336e?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=862&height=862",
		description => q{For over 30 years, Saturday Night Country has been Australia's home of country music.},
		network     => 'ABC Country',
	};
	is_deeply( $programs->[0]->{passthrough}, [$first], 'program: title, canonical path, objectID digits, defaultThumbnail 1x1, shortTeaserText, infoSource' );
	is_deeply( $programs->[0], Plugins::ABCListen::OnDemand->programItem( undef, $first ), 'the row is exactly what programItem builds' );
	is( $programs->[0]->{url},   \&Plugins::ABCListen::OnDemand::_programMenu, 'opens O2\'s program menu' );
	is( $programs->[0]->{line2}, 'ABC Country',                                 'line2 = network' );
	is( $programs->[0]->{image}, "$WCMS/0af840be01308fcdc934b82c3cf0336e?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=300&height=300", 'artwork at 300 px' );
	ok( !exists $programs->[0]->{description}, 'no description key on the row (LMS menu rule 1)' );
	is_deeply( ids($programs), [qw(7462314 107242394 107221908)], 'ids' );
};

subtest 'episode hits -> OnDemand->episodeItem with the contract-3 meta (+ renditions, windows, seenAt)' => sub {
	fresh();
	serve_science();

	my $episodes = group( items_of( search( { search => 'science show' } ) ), 'Episodes' )->{items};
	is_deeply( ids($episodes), [qw(107277458 107277436)], 'relevance order' );

	my $meta = {
		id                  => '107277458',
		docType             => 'audiosegment',
		title               => 'Crossing the language barrier teaching astronomy and physics',
		programTitle        => 'The Science Show',
		programId           => '2885500',
		path                => '/listen/programs/scienceshow/crossing-the-language-barrier-teaching-astronomy-and-physics/107277458',
		image               => "$WCMS/635483aa4bc93d52bf082b08c57a4419?impolicy=wcms_crop_resize&cropH=1414&cropW=1414&xPos=404&yPos=0&width=862&height=862",
		description         => "As a professor in astrophysics, Katherine Blundell studies variable objects in the night sky. These are colliding or exploding objects. She uses spectroscopy to infer the dynamics of the objects.\n\nIn addition to her astronomy, Professor Blundell has established the STEP initiative which offers science to students where science literature is unavailable in their native languages.  A monthly online magazine presents information about astronomy and physics.",
		date                => epoch( 2026, 10, 17, 1, 5 ),
		duration            => 550,
		renditions          => [ { url => 'https://mediacore-live-production.akamaized.net/audio/02/pg/Z/m0.mp3', mime => 'audio/mpeg', bitrate => 192, fileSize => 13207926 } ],
		availableTo         => epoch( 2026, 11, 14, 1, 5 ),
		downloadAvailableTo => $OPEN_END,
		seenAt              => $T0,
	};
	is_deeply( $episodes->[0]->{passthrough}, [$meta], 'meta: id, docType, title, program, path, image (a plain-URL defaultThumbnail), teaserText, date, duration, renditions (with fileSize, O6), windows, seenAt' );
	is( $episodes->[0]->{passthrough}->[0]->{downloadAvailableTo}, Plugins::ABCListen::Episode::OPEN_END(), 'ABC\'s "permanent" 2200-01-01 download end: stored as an open end, exactly as Episode.pm stores one' );

	my $row = $episodes->[0];
	is( $row->{play},     'abclisten://episode/107277458', 'play: the stable abclisten://episode URL' );
	is( $row->{type},     'link',                          'a link to the episode menu' );
	is( $row->{url},      \&Plugins::ABCListen::OnDemand::_episodeMenu, 'opens O2\'s episode menu' );
	is( $row->{name},     "Sat 17 Oct \x{2013} Crossing the language barrier teaching astronomy and physics", 'name: date and title (Sydney time)' );
	is( $row->{line1},    'Crossing the language barrier teaching astronomy and physics', 'line1: title' );
	is( $row->{line2},    "Sat 17 Oct \x{b7} 9 min", 'line2: date and duration' );
	is( $row->{duration}, 550, 'duration' );

	is(
		$episodes->[1]->{passthrough}->[0]->{image},
		"$WCMS/f0ef4305f35395f9e8d1554ea08f8c4d?impolicy=wcms_crop_resize&cropH=683&cropW=683&xPos=105&yPos=0&width=862&height=862",
		'a defaultThumbnail with ratios: its 1x1 crop'
	);
	like( $_->{name}, $EPISODE_NAME, "episode row name has text (date and title): $_->{name}" ) for @$episodes;
};

subtest 'meta-cache seeding: renditions, availableTo, seenAt stored; O1 plays a result without a request' => sub {
	fresh();
	serve_science();
	search( { search => 'science show' } );

	my $cached = Plugins::ABCListen::Util::getEpisodeMeta('107277436');
	ok( $cached, 'the episode is in the metadata cache' );
	is_deeply(
		$cached->{renditions},
		[ { url => 'https://mediacore-live-production.akamaized.net/audio/02/pg/Z/lv.mp3', mime => 'audio/mpeg', bitrate => 192, fileSize => 17910966 } ],
		'renditions, with fileSize (O6: AAC seeking derives the bitrate from it)'
	);
	is( $cached->{availableTo}, epoch( 2026, 11, 14, 1, 3 ), 'availableTo (streaming window end)' );
	is( $cached->{seenAt},      $T0,                       'seenAt = now' );
	is( $cached->{title},       'Breeding potatoes is like herding cats', 'title' );
	is( $cached->{programTitle}, 'The Science Show', 'programTitle' );
	is( $cached->{path}, '/listen/programs/scienceshow/breeding-potatoes-is-like-herding-cats/107277436', 'canonical path' );
	is( $cached->{duration}, 746, 'duration' );

	@Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
	my $c = collector();
	Plugins::ABCListen::Episode->resolve( '107277436', $c->cb );
	is( $c->count, 1, 'O1 answers at once' );
	is( ( $c->args(0) )[0]->{url}, 'https://mediacore-live-production.akamaized.net/audio/02/pg/Z/lv.mp3', 'with the seeded MP3' );
	is( scalar requests(), 0, 'no episode page fetch, no request at all' );
};

subtest 'status filter (DQ4): hidden only when download and streaming are both EXPIRED/NONE' => sub {
	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { file => 'discovery/algolia-search-episodes-edge.synthetic.json' },
	);

	my $episodes = group( items_of( search( { search => 'edge' } ) ), 'Episodes' )->{items};
	is_deeply(
		ids($episodes),
		[qw(900004 900005 900006 900007 900012)],
		'kept: AVAILABLE/EXPIRED, AVAILABLE/NONE, PENDING/PENDING, no statuses, AVAILABLE/AVAILABLE (in relevance order)'
	);
	is( scalar( grep { /\A9000(?:01|02|03|13|14)\z/ } @{ ids($episodes) } ), 0, 'hidden: EXPIRED/EXPIRED, NONE/NONE, EXPIRED/NONE, NONE/EXPIRED, expired/none (any case)' );
	is( group( items_of( search( { search => 'edge' } ) ), 'Episodes' )->{name}, 'Episodes (5)', 'M counts the rows after filtering' );
};

subtest 'only episodes: no Programs link; only programs: no Episodes link' => sub {
	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { file => 'discovery/algolia-listen_prod_all-query.json' },
	);
	is_deeply( names( items_of( search( { search => 'potatoes' } ) ) ), ['Episodes (2)'], 'only episodes' );

	fresh();
	serve(
		programs => { file => 'discovery/algolia-programs-list.json' },
		episodes => { file => 'discovery/algolia-search-empty.synthetic.json' },
	);
	is_deeply( names( items_of( search( { search => 'country' } ) ) ), ['Programs (3)'], 'only programs' );

	# every episode hit filtered out, no programs -> no results
	fresh();
	my $expired = JSON::PP::decode_json( fixture('discovery/algolia-search-episodes-edge.synthetic.json') );
	$expired->{hits} = [ grep { ( $_->{mediaDownloadStatus} || '' ) =~ /\A(?:EXPIRED|NONE)\z/ && ( $_->{mediaStreamingStatus} || '' ) =~ /\A(?:EXPIRED|NONE)\z/ } @{ $expired->{hits} } ];
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { content => JSON::PP::encode_json($expired) },
	);
	is_deeply( items_of( search( { search => 'Old Stuff' } ) ), [ no_results('Old Stuff') ], 'only expired episodes: "No results for \'Old Stuff\'"' );
};

subtest 'no results: exactly one text item "No results for \'<query>\'" (the text as typed)' => sub {
	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { file => 'discovery/algolia-search-empty.synthetic.json' },
	);

	my $c = search( { search => 'zzqxvbnm' } );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ text_item(q{No results for 'zzqxvbnm'}) ], 'one text item' );
	is( scalar algolia_requests(), 2, 'after both queries' );

	is_deeply( items_of( search( { search => '  ZzQX  vbnm ' } ) ), [ text_item(q{No results for 'ZzQX vbnm'}) ], 'the query as typed (case kept, whitespace tidied)' );
};

subtest 'programs: no canonicalURL, off-site page, malformed objectID, non-program hit -> skipped; duplicates once' => sub {
	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-programs-edge.synthetic.json' },
		episodes => { file => 'discovery/algolia-search-empty.synthetic.json' },
	);

	my $programs = group( items_of( search( { search => 'edge' } ) ), 'Programs' )->{items};
	is_deeply( ids($programs), [qw(800001 800006)], 'Edge Show once, then Science Friction' );
	is_deeply( names($programs), [ 'Edge Show', 'Science Friction' ], 'names from title, never _highlightResult' );
	unlike( join( ' ', map { $_->{name}, $_->{line1} } @$programs ), qr/<em>/, 'no highlight markup' );

	is_deeply(
		$programs->[0]->{passthrough},
		[ { title => 'Edge Show', path => '/listen/programs/edgeshow', id => '800001', description => 'The long description, used when there is no short teaser.' } ],
		'no thumbnail, no network: left out; description falls back to description'
	);
	is( $programs->[0]->{image}, $ICON, 'no thumbnail: the plugin icon (builder default)' );
	ok( !exists $programs->[0]->{line2}, 'no network: no line2' );
	is( $programs->[1]->{line2}, 'ABC Radio National', 'network' );
	is( $programs->[1]->{image}, "$WCMS/friction1x1?impolicy=wcms_crop_resize&cropH=1400&cropW=1400&xPos=0&yPos=0&width=300&height=300", '1x1 thumbnail at 300 px' );
};

subtest 'episodes: missing thumbnails, renditions, dates; malformed objectIDs; duplicates; highlight' => sub {
	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { file => 'discovery/algolia-search-episodes-edge.synthetic.json' },
	);

	my $episodes = group( items_of( search( { search => 'edge' } ) ), 'Episodes' )->{items};
	my %meta = map { $_->{passthrough}->[0]->{id} => $_->{passthrough}->[0] } @$episodes;
	my %row  = map { $_->{passthrough}->[0]->{id} => $_ } @$episodes;

	is( scalar( grep { $_ eq '900004' } @{ ids($episodes) } ), 1, 'a duplicate hit is listed once (the first)' );
	is( $meta{900004}->{title}, 'Permanent MP3, expired AAC', 'the first hit wins' );
	ok( !( grep { !/\A[0-9]+\z/ } @{ ids($episodes) } ), 'malformed objectIDs (letters, no scheme) skipped' );
	ok( !exists $meta{900010}, 'a non-audio hit (article) skipped' );

	# thumbnails
	is( $meta{900004}->{image}, "$WCMS/edgeprogram1x1?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=862&height=862", 'no defaultThumbnail: programDefaultThumbnail 1x1' );
	ok( !exists $meta{900005}->{image}, 'neither thumbnail: no image' );
	is( $row{900005}->{image}, $ICON, '... and the row gets the plugin icon' );
	is( $meta{900006}->{image}, "$WCMS/edgeepisode6?impolicy=wcms_crop_resize&cropH=1000&cropW=1000&xPos=0&yPos=0&width=862&height=862", 'a plain-URL defaultThumbnail' );

	# text
	is( $meta{900004}->{description}, 'The synopsis, used when there is no teaser text.', 'empty teaserText: synopsis' );
	is( $meta{900012}->{title}, 'Q&A: science', 'title: entities decoded, trimmed; never _highlightResult' );
	is( $meta{900012}->{description}, 'Questions & answers.', 'teaserText decoded' );
	unlike( join( ' ', map { $_->{name} } @$episodes ), qr/<em>/, 'no highlight markup in any name' );

	# renditions and windows
	is_deeply(
		$meta{900004}->{renditions},
		[
			{ url => 'https://mediacore-live-production.akamaized.net/audio/01/aa/Z/e4.aac', mime => 'audio/aac',  bitrate => 96, fileSize => 39600000 },
			{ url => 'https://mediacore-live-production.akamaized.net/audio/01/aa/Z/e4.mp3', mime => 'audio/mpeg', bitrate => 128 },
		],
		'renditions as {url, mime, bitrate, fileSize when the hit has one}, in order; an entry without a URL dropped'
	);
	is( $meta{900004}->{availableTo}, epoch( 2025, 6, 28, 23, 30 ), 'availableTo: the past streaming end (O1 then plays the MP3 only)' );
	is( $meta{900004}->{downloadAvailableTo}, $OPEN_END, '"permanent" download end: open' );
	is( $meta{900004}->{path}, '/listen/programs/edgeshow/permanent-mp3/900004', 'path: canonical (no trailing slash)' );
	is( $meta{900004}->{date}, epoch( 2025, 5, 31, 23, 30 ), 'date: the publication date with its offset' );
	like( $row{900004}->{name}, qr/\ASun 1 Jun 2025 \x{2013} Permanent MP3/, 'an older year is shown' );

	is_deeply(
		$meta{900005}->{renditions},
		[ { url => 'https://mediacore-live-production.akamaized.net/geo-001/audio/01/aa/Z/e5.mp3', mime => 'audio/mpeg', bitrate => 192 } ],
		'/geo-001/ rendition passed through unchanged (O1 gives the geo message)'
	);
	is( $meta{900005}->{downloadAvailableTo}, epoch( 2027, 10, 10, 20, 0 ), 'a finite download end: downloadAvailableTo' );
	is( $meta{900005}->{programId}, '800001', 'programID as a string: digits' );
	is( $meta{900005}->{path}, '/listen/programs/edgeshow/australia-only/900005', 'abc.net.au host, query and fragment: canonical path' );
	is( $meta{900005}->{docType}, 'audiosegment', 'docType = contentType' );

	is_deeply(
		$meta{900007},
		{ id => '900007', docType => 'audio', title => 'No statuses, renditions or dates', path => '/news/audio/no-statuses/900007' },
		'no renditions, dates, thumbnails: only what is known (no renditions, windows or seenAt)'
	);
	is( $row{900007}->{name}, 'No statuses, renditions or dates', 'no date: the name is the title' );

	ok( !exists $meta{900012}->{date},     'an unparseable date: no date' );
	ok( !exists $meta{900012}->{duration}, 'duration 0: left out' );
	is( $meta{900012}->{docType}, 'audioepisode', 'docType' );
	ok( exists $meta{900012}->{renditions}, 'renditions without window dates: seeded' );
	is_deeply( [ @{ $meta{900012} }{qw(availableTo downloadAvailableTo)} ], [ $OPEN_END, $OPEN_END ], '... with open windows (a missing end is open, ABC §4.3)' );

	ok( !exists $meta{900006}->{renditions} && !exists $meta{900006}->{seenAt}, 'a window that opens later (PENDING): not seeded, O1 checks the page at play time' );
	is( $meta{900006}->{date}, epoch( 2026, 10, 25, 20, 0 ), '... but listed, with its date' );

	my $cached = Plugins::ABCListen::Util::getEpisodeMeta('900007');
	ok( $cached && !exists $cached->{renditions} && !exists $cached->{seenAt}, 'meta cache: no renditions or seenAt without renditions' );
	check_names( $episodes, 'episode rows' );
};

subtest 'windows O1 closed earlier (not yet released then) are reopened by a seed, so the result plays' => sub {
	fresh();
	serve_science();

	# O1 saw the episode before its release: windows closed (both = then), no renditions
	Plugins::ABCListen::Util::setEpisodeMeta( '107277436', { title => 'Breeding potatoes', availableTo => $T0 - 86400 * 3, downloadAvailableTo => $T0 - 86400 * 3 } );

	search( { search => 'science show' } );
	my $cached = Plugins::ABCListen::Util::getEpisodeMeta('107277436');
	is( $cached->{downloadAvailableTo}, $OPEN_END,                  'the permanent download window is open again' );
	is( $cached->{availableTo},         epoch( 2026, 11, 14, 1, 3 ), 'the streaming window end from the hit' );

	@Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
	my $c = collector();
	Plugins::ABCListen::Episode->resolve( '107277436', $c->cb );
	is( ( $c->args(0) )[0]->{url}, 'https://mediacore-live-production.akamaized.net/audio/02/pg/Z/lv.mp3', 'O1 plays the seeded MP3 (not EPISODE_EXPIRED)' );
	is( scalar requests(), 0, 'without a request' );
};

subtest 'a cached entry with older renditions is not refreshed by a hit without renditions' => sub {
	fresh();
	Plugins::ABCListen::Util::setEpisodeMeta( '900007', { title => 'Old', renditions => [ { url => 'https://example.test/old.mp3', mime => 'audio/mpeg' } ], seenAt => $T0 - 86400 } );
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { file => 'discovery/algolia-search-episodes-edge.synthetic.json' },
	);
	search( { search => 'edge' } );
	my $cached = Plugins::ABCListen::Util::getEpisodeMeta('900007');
	is( $cached->{seenAt}, $T0 - 86400, 'seenAt unchanged, so O1 does not trust the old renditions as fresh' );
	is( $cached->{title}, 'No statuses, renditions or dates', 'the rest is merged (F1 merge rule)' );
};

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

subtest 'RATE_LIMITED (HTTP 429) and LOAD_FAILED (HTTP 500): one text item' => sub {
	fresh();
	serve(
		programs => { code => 429, file => 'foundation/algolia-429.json' },
		episodes => { code => 429, file => 'foundation/algolia-429.json' },
	);
	my $c = search( { search => 'science' } );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ text_item($RATE_LIMITED) ], '429 for both: one RATE_LIMITED text item' );

	fresh();
	serve(
		programs => { code => 500, content => '{}' },
		episodes => { code => 500, content => '{}' },
	);
	$c = search( { search => 'science' } );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], '500 for both: one LOAD_FAILED text item' );

	fresh();
	serve(
		programs => { code => 500, content => '{}' },
		episodes => { code => 429, file => 'foundation/algolia-429.json' },
	);
	is_deeply( items_of( search( { search => 'science' } ) ), [ text_item($RATE_LIMITED) ], 'one of each: still one item, RATE_LIMITED' );

	fresh();
	serve(
		programs => { error => 'Timed out waiting for data' },
		episodes => { content => '{"message":"not what we expected"}' },
	);
	is_deeply( items_of( search( { search => 'science' } ) ), [ text_item($LOAD_FAILED) ], 'a transport error, and a response without hits: LOAD_FAILED' );

	fresh();
	@Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
	route( "$SITE/listen/search", file => 'foundation/listen-search-no-algolia.html', headers => { 'Content-Type' => 'text/html' } );
	is_deeply( items_of( search( { search => 'science' } ) ), [ text_item($LOAD_FAILED) ], 'no Algolia config on the site (no key found): LOAD_FAILED' );
	is( scalar algolia_requests(), 0, '... without an Algolia request' );
};

subtest 'key rotation: 403 -> re-discovered key -> retried; still 403 with the same key -> LOAD_FAILED' => sub {
	fresh();
	serve(
		programs => { code => 403, file => 'foundation/algolia-403.json' },
		episodes => { code => 403, file => 'foundation/algolia-403.json' },
	);
	my $c = search( { search => 'science' } );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'the key stays the same and Algolia still refuses: LOAD_FAILED' );
	is( scalar algolia_requests(), 2, 'no retry with the same key' );

	# ABC rotated the key: the first query is refused, the search page has a new key, the retry works
	fresh();
	@Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
	my $page  = fixture('foundation/listen-search.trimmed.html');
	my $pages = 0;
	Slim::Networking::SimpleAsyncHTTP->addRoute( "$SITE/listen/search", sub {
		my $html = $page;
		$html =~ s/testsearchkey/rotatedkey/g if $pages++;
		return { code => 200, headers => { 'Content-Type' => 'text/html' }, content => $html };
	} );
	my $posts = 0;
	Slim::Networking::SimpleAsyncHTTP->addRoute( $ALGOLIA, sub {
		my ( $url, $method, $body ) = @_;
		return { code => 403, headers => $JSON_TYPE, content => fixture('foundation/algolia-403.json') } unless $posts++;
		return { code => 200, headers => $JSON_TYPE, content => fixture( group_of($body) eq 'programs' ? 'discovery/algolia-programs-list.json' : 'discovery/algolia-listen_prod_all-query.json' ) };
	} );
	$c = search( { search => 'science show' } );
	is( $c->count, 1, 'one callback' );
	is_deeply( names( items_of($c) ), [ 'Programs (3)', 'Episodes (2)' ], 'full results after the retry' );
	is_deeply( [ map { $_->{headers}->header('X-Algolia-API-Key') } algolia_requests() ], [qw(testsearchkey rotatedkey rotatedkey)], 'refused, retried with the new key, then the second query with it' );
};

subtest 'partial failure: the successful group plus one text item' => sub {
	fresh();
	serve_science( episodes => { code => 429, file => 'foundation/algolia-429.json' } );
	my $c = search( { search => 'science show' } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply( names($items), [ 'Programs (3)', $RATE_LIMITED ], 'programs OK, episodes rate-limited' );
	is_deeply( $items->[1], text_item($RATE_LIMITED), 'the failure is a text item' );

	fresh();
	serve_science( programs => { code => 502, content => 'Bad gateway' } );
	$items = items_of( search( { search => 'science show' } ) );
	is_deeply( names($items), [ 'Episodes (2)', $LOAD_FAILED ], 'programs failed, episodes OK' );

	fresh();
	serve(
		programs => { file => 'discovery/algolia-search-empty.synthetic.json' },
		episodes => { code => 500, content => '{}' },
	);
	is_deeply( items_of( search( { search => 'science show' } ) ), [ text_item($LOAD_FAILED) ], 'no programs and episodes failed: just the failure (never "No results")' );
};

subtest 'plugin budget used up: RATE_LIMITED without a request; cached queries still work' => sub {
	fresh();
	serve_science();
	my $cached = items_of( search( { search => 'science show' } ) );
	is( scalar algolia_requests(), 2, 'two queries sent' );

	# use up the rest of API.pm's 300 queries per hour
	Plugins::ABCListen::API::algolia( { query => "filler $_" }, sub { }, sub { } ) for 1 .. 298;
	is( scalar algolia_requests(), 300, '300 queries sent this hour' );

	my $c = search( { search => 'something new' } );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ text_item($RATE_LIMITED) ], 'a new query: RATE_LIMITED' );
	is( scalar algolia_requests(), 300, '... without a request' );

	is_deeply( items_of( search( { search => 'Science Show' } ) ), $cached, 'a cached query still answers in full' );
	is( scalar algolia_requests(), 300, '... from the cache' );
};

# ---------------------------------------------------------------------------
# Empty queries, passthrough, callbacks
# ---------------------------------------------------------------------------

subtest 'empty or whitespace query: no request, one NO_RESULTS text item' => sub {
	for my $case ( [ {}, 'no search' ], [ { search => '' }, 'empty' ], [ { search => " \t\n " }, 'whitespace' ], [ undef, 'no args' ], [ { search => undef }, 'undef' ] ) {
		fresh();
		serve_science();
		my $c = search( $case->[0] );
		is( $c->count, 1, "$case->[1]: one callback" );
		is_deeply( items_of($c), [ no_results('') ], "$case->[1]: one NO_RESULTS text item" );
		is( scalar requests(), 0, "$case->[1]: no request at all" );
	}
};

subtest 'the query from the passthrough (global search link); args win over the passthrough' => sub {
	fresh();
	serve_science();
	my $own = items_of( search( { search => 'science show' } ) );

	my $c = search( {}, undef, { search => 'Science Show' } );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), $own, 'passthrough search: the same results' );
	is( scalar algolia_requests(), 2, 'from the shared cache' );

	search( { search => 'potatoes' }, undef, { search => 'science show' } );
	is_deeply( [ map { $_->{query} } ( bodies() )[ 2, 3 ] ], [ 'potatoes', 'potatoes' ], 'args->{search} wins' );
};

subtest 'exactly one callback: deferred responses in either order, synchronous cache hits' => sub {
	for my $reverse ( 0, 1 ) {
		my $label = $reverse ? 'episodes answer first' : 'programs answer first';
		fresh();
		serve_science( programs => { file => 'discovery/algolia-programs-list.json', defer => 1 }, episodes => { file => 'discovery/algolia-listen_prod_all-query.json', defer => 1 } );

		my $c = search( { search => 'science show' } );
		is( $c->count, 0, "$label: no callback while both queries are out" );
		is( scalar Slim::Networking::SimpleAsyncHTTP->deferred, 2, "$label: both queries started at once" );

		@Slim::Networking::SimpleAsyncHTTP::DEFERRED = reverse @Slim::Networking::SimpleAsyncHTTP::DEFERRED if $reverse;
		my $first = shift @Slim::Networking::SimpleAsyncHTTP::DEFERRED;
		my @rest  = @Slim::Networking::SimpleAsyncHTTP::DEFERRED;
		@Slim::Networking::SimpleAsyncHTTP::DEFERRED = ($first);
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		is( $c->count, 0, "$label: still waiting after one answer" );

		@Slim::Networking::SimpleAsyncHTTP::DEFERRED = @rest;
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		is( $c->count, 1, "$label: one callback after both" );
		is_deeply( names( items_of($c) ), [ 'Programs (3)', 'Episodes (2)' ], "$label: programs first either way" );
	}

	my $c = search( { search => 'science show' } );
	is( $c->count, 1, 'from the cache: one (synchronous) callback' );
};

subtest 'exactly one callback when building the results dies, or LMS\'s callback dies' => sub {
	fresh();
	serve_science();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub { die "builder exploded\n" };
		my $c = search( { search => 'science show' } );
		is( $c->count, 1, 'a dying builder: one callback' );
		is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], '... with the LOAD_FAILED text item' );
		ok( ( grep { $_->{message} =~ /builder exploded/ } errors_logged() ), '... and the error logged' );
	}

	fresh();
	serve_science();
	my $calls = 0;
	ok( eval { $SEARCH_FEED->( undef, sub { $calls++; die "LMS callback exploded\n" }, { search => 'science show' } ); 1 }, 'a dying LMS callback does not escape' ) or diag $@;
	is( $calls, 1, 'called once, never again with an error item' );

	fresh();
	serve_science();
	$calls = 0;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::algolia = sub { die "algolia exploded\n" };
		my $c = search( { search => 'science show' } );
		is( $c->count, 1, 'API::algolia dies: one callback' );
		is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], '... LOAD_FAILED' );
	}
};

# ---------------------------------------------------------------------------
# D9: programs filed under other site segments (AM) or sharing a title (Persuasion)
# ---------------------------------------------------------------------------

# A fake of ABC's index, answering both queries as ABC's index does (D8, t/34's fake): a hit
# matches when its siteSegment, or one of its canonicalURI_fragments, is named in the filter, and
# every word of the query starts a word of its title (or, for episodes, its programTitle); then,
# unless the query sets distinct to 0, only the first hit of each title (the index's distinct).
# Programs: the 34 recorded hits of t/data/ondemand/algolia-programs-d8.trimmed.json (D8,
# 2026-10-23: AM and The World Today under siteSegment adelaide, both Persuasions, Big Ideas at its
# legacy and current path, 4 Mornings, ...). Episodes: @D9_EPISODES (synthetic, shaped like the
# recorded audiosegment hits of algolia-listen_prod_all-query.json).
my $D9_PROGRAMS = 'ondemand/algolia-programs-d8.trimmed.json';

sub d9_episode {
	my ( $id, $title, $program, $path, $segment ) = @_;
	return {
		objectID               => "coremedia://audioepisode/$id",
		title                  => $title,
		programTitle           => $program,
		canonicalURL           => "https://www.abc.net.au$path/$id",
		canonicalURI_fragments => [ grep {length} split m{/}, "$path/$id" ],
		siteSegment            => $segment,
		contentType            => 'audioepisode',
		duration               => 1200,
		dates                  => { publicationDate => '2026-10-23T22:00:00+00:00' },
		mediaDownloadStatus    => 'AVAILABLE',
		mediaStreamingStatus   => 'AVAILABLE',
	};
}

my @D9_EPISODES = (
	d9_episode( 107300001, 'AM: the morning news', 'AM', '/listen/programs/am/am-24-october', 'adelaide' ),
	d9_episode( 107300002, 'Persuasion: chapter 1', 'Persuasion', '/listen/audiobooks/persuasion-page/chapter-1', 'listen' ),
);

sub d9_matches {
	my ( $query, @texts ) = @_;
	my @words = map {lc} grep {length} split /\s+/, $query;
	my @have  = map { lc } map { split /[^\w']+/, $_ } grep {defined} @texts;
	for my $w (@words) {
		return 0 unless grep { index( $_, $w ) == 0 } @have;
	}
	return 1;
}

sub d9_answer {
	my $params  = shift;
	my $filters = defined $params->{filters} ? $params->{filters} : '';
	my $episode = $filters !~ /\AcontentType:program /;
	my @hits    = $episode ? @D9_EPISODES : @{ JSON::PP::decode_json( fixture($D9_PROGRAMS) )->{hits} };

	my %segment  = map { $_ => 1 } $filters =~ /\bsiteSegment:([\w.-]+)/g;
	my %fragment = map { $_ => 1 } $filters =~ /\bcanonicalURI_fragments:([\w.-]+)/g;

	@hits = grep {
		my $hit = $_;
		( $segment{ defined $hit->{siteSegment} ? $hit->{siteSegment} : '' } || grep { $fragment{$_} } @{ $hit->{canonicalURI_fragments} || [] } )
			&& d9_matches( $params->{query}, $hit->{title}, $episode ? $hit->{programTitle} : () );
	} @hits;

	if ( !( exists $params->{distinct} && !$params->{distinct} ) ) {
		my %seen;
		@hits = grep { !$seen{ $_->{title} }++ } @hits;
	}

	# only the attributes asked for (and objectID), as Algolia answers; all without attributesToRetrieve
	my %want = map { $_ => 1 } 'objectID', @{ $params->{attributesToRetrieve} || [] };
	my @page = map { my $hit = $_; +{ map { $_ => $hit->{$_} } grep { !$params->{attributesToRetrieve} || $want{$_} } keys %$hit } } grep {defined} @hits[ 0 .. $params->{hitsPerPage} - 1 ];

	return { hits => \@page, nbHits => scalar @hits, page => 0, nbPages => 1, hitsPerPage => $params->{hitsPerPage} };
}

sub serve_d9_index {
	Slim::Networking::SimpleAsyncHTTP->addRoute( $ALGOLIA, sub {
		my ( $url, $method, $body ) = @_;
		return { content => JSON::PP::encode_json( d9_answer( JSON::PP::decode_json($body) ) ), headers => $JSON_TYPE };
	} );
}

sub program_paths { [ map { $_->{passthrough}->[0]->{path} } @{ $_[0] || [] } ] }

subtest 'D9: the cause, on the fake index - D3\'s queries miss AM (siteSegment adelaide) and the audiobook Persuasion (distinct)' => sub {
	my $d3 = sub { d9_answer( { query => $_[0], hitsPerPage => 20, filters => "contentType:program AND $D3_SEGMENTS" } ) };
	is_deeply( $d3->('am')->{hits}, [], 'D3 filter, "am": no AM' );
	is_deeply( [ map { $_->{canonicalURL} } @{ $d3->('persuasion')->{hits} } ], ['https://www.abc.net.au/listen/programs/persuasion/'], 'D3 (distinct on), "persuasion": only the podcast' );
	is_deeply( [ map { $_->{canonicalURL} } @{ $d3->('big ideas')->{hits} } ], ['http://www.abc.net.au/radionational/programs/bigideas/'], 'D3, "big ideas": only the legacy document (the first of the title)' );
	is_deeply( d9_answer( { query => 'am', hitsPerPage => 40, filters => "(contentType:audioepisode OR contentType:audio OR contentType:audiosegment) AND $D3_SEGMENTS" } )->{hits}, [], 'D3 episodes filter, "am": no AM episode either' );
};

subtest 'D9: Search "AM" lists the AM program (and its episode), filed under siteSegment adelaide; 2 queries, cached' => sub {
	fresh();
	serve_d9_index();

	my $c = search( { search => 'AM' } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply( names($items), [ 'Programs (1)', 'Episodes (1)' ], 'Programs (1), Episodes (1)' );

	my $programs = group( $items, 'Programs' )->{items};
	is_deeply( names($programs), ['AM'], 'Programs: AM' );
	my ($hit) = grep { $_->{title} eq 'AM' } @{ JSON::PP::decode_json( fixture($D9_PROGRAMS) )->{hits} };
	is_deeply(
		$programs->[0],
		Plugins::ABCListen::OnDemand->programItem( undef, {
			title       => 'AM',
			path        => '/listen/programs/am',
			id          => '8437680',
			image       => $hit->{defaultThumbnail}->{'1x1'},
			description => "AM is Australia's most informative morning current affairs program.",
			network     => 'ABC News Podcasts',
		} ),
		'AM: the programItem row for /listen/programs/am (no programType passed on)'
	);
	is_deeply( ids( group( $items, 'Episodes' )->{items} ), ['107300001'], 'Episodes: the AM episode (siteSegment adelaide, a /listen/ URL)' );

	is( scalar algolia_requests(), 2, 'two Algolia queries (D3\'s budget)' );
	search( { search => 'am' } );
	search( { search => ' AM ' } );
	is( scalar algolia_requests(), 2, 'repeated: from the 1 h cache, no new query' );
	is( scalar errors_logged() + scalar warnings_logged(), 0, 'nothing at WARN or ERROR' );
};

subtest 'D9: Search "persuasion" lists both programs called Persuasion (the audiobook and the podcast), named by network' => sub {
	fresh();
	serve_d9_index();

	my $items    = items_of( search( { search => 'persuasion' } ) );
	my $programs = group( $items, 'Programs' )->{items};
	is( scalar @$programs, 2, 'Programs (2): two hits called Persuasion, both listed' );
	is_deeply( program_paths($programs), [ '/listen/programs/persuasion', '/listen/audiobooks/persuasion-page' ], 'the podcast and the audiobook, in relevance order' );
	is_deeply( names($programs), [ 'Persuasion (ABC Listen)', 'Persuasion (Audio Books)' ], 'named "<title> (<network>)" as in the A–Z' );
	is_deeply( [ map { $_->{line1} } @$programs ], names($programs), 'line1 as name' );
	is_deeply( [ map { $_->{line2} } @$programs ], [ 'ABC Listen', 'Audio Books' ], 'line2: the networks' );
	is_deeply( [ map { $_->{passthrough}->[0]->{title} } @$programs ], [ 'Persuasion', 'Persuasion' ], 'the programs keep their title (the menu header)' );
	is_deeply( ids( group( $items, 'Episodes' )->{items} ), ['107300002'], 'Episodes: the chapter' );
};

subtest 'D9: one program\'s two documents merged by D8\'s rule (Big Ideas once, at its current path); other same-title programs kept apart' => sub {
	fresh();
	serve_d9_index();

	my $programs = group( items_of( search( { search => 'big ideas' } ) ), 'Programs' )->{items};
	is_deeply( program_paths($programs), ['/listen/programs/bigideas'], 'Big Ideas once, at /listen/programs/bigideas (not the legacy /radionational/ page)' );
	is( $programs->[0]->{name}, 'Big Ideas', '... named Big Ideas (no repeat left)' );
	is( $programs->[0]->{line2}, 'ABC Radio National', '... the current document (network, programType)' );

	$programs = group( items_of( search( { search => 'mornings' } ) ), 'Programs' )->{items};
	is_deeply(
		names($programs),
		[ 'Mornings (ABC South East SA)', 'Mornings (Double J)', 'Mornings (ABC Classic)', 'Mornings (triple j)' ],
		'the 4 programs called Mornings: all listed, named by network'
	);

	# synthetic: twins only when they can be one program (t/34's D8 cases, through Search)
	fresh();
	my $hit = sub { my %f = @_; return { contentType => 'program', defaultThumbnail => {}, %f } };
	serve(
		programs => { content => JSON::PP::encode_json( { hits => [
			$hit->( objectID => 'coremedia://program/901', title => 'The Secret Keeper', canonicalURL => 'https://www.abc.net.au/listen/audiobooks/the-secret-keeper/', programType => 'audiobook', infoSource => 'Audio Books' ),
			$hit->( objectID => 'coremedia://program/902', title => 'The Secret Keeper', canonicalURL => 'https://www.abc.net.au/listen/programs/the-secret-keeper/', programType => 'podcast' ),
			$hit->( objectID => 'coremedia://program/903', title => 'RN Breakfast', canonicalURL => 'https://www.abc.net.au/listen/programs/radionational-breakfast/', programType => 'catch-up' ),
			$hit->( objectID => 'coremedia://program/904', title => 'Radio National Breakfast', canonicalURL => 'https://www.abc.net.au/listen/programs/radionational-breakfast/', programType => 'podcast', infoSource => 'ABC News Podcasts' ),
			$hit->( objectID => 'coremedia://program/905', title => 'Download This Show', canonicalURL => 'http://www.abc.net.au/radionational/programs/downloadthisshow/', infoSource => 'ABC Radio National' ),
			$hit->( objectID => 'coremedia://program/906', title => 'Download This Show', canonicalURL => 'https://www.abc.net.au/listen/programs/downloadthisshow/', programType => 'podcast', infoSource => 'ABC Radio National' ),
		] } ) },
		episodes => { file => 'discovery/algolia-search-empty.synthetic.json' },
	);
	$programs = group( items_of( search( { search => 'synthetic twins' } ) ), 'Programs' )->{items};
	is_deeply(
		[ map { "$_->{passthrough}->[0]->{id} $_->{passthrough}->[0]->{path}" } @$programs ],
		[ '901 /listen/audiobooks/the-secret-keeper', '902 /listen/programs/the-secret-keeper', '903 /listen/programs/radionational-breakfast', '906 /listen/programs/downloadthisshow' ],
		'an audiobook and a podcast of one title and slug: two; the same path: one (the first); a legacy and a current copy: one (the current, typed one, in the first one\'s place)'
	);
	is_deeply( names($programs), [ 'The Secret Keeper (Audio Books)', 'The Secret Keeper', 'RN Breakfast', 'Download This Show' ], 'repeated titles named by network only where the network tells them apart' );
	ok( !( grep { exists $_->{passthrough}->[0]->{programType} } @$programs ), 'programType only used for the merge (rows unchanged from D3)' );
};

subtest 'D9: the rules are the A–Z\'s own (ProgramIndex::siteFilter, ProgramIndex::mergeTwins), not copies' => sub {
	fresh();
	serve_d9_index();

	my @merged;
	{
		no warnings 'redefine';
		my $merge = \&Plugins::ABCListen::ProgramIndex::mergeTwins;
		local *Plugins::ABCListen::ProgramIndex::mergeTwins = sub { push @merged, [ map { $_->{path} } @{ $_[0] } ]; goto &$merge };
		search( { search => 'big ideas' } );
	}
	is_deeply( \@merged, [ [ '/radionational/programs/bigideas', '/listen/programs/bigideas' ] ], 'Search merges its program refs with ProgramIndex::mergeTwins, once per search' );

	my %body = map { group_of( $_->{body} ) => JSON::PP::decode_json( $_->{body} ) } algolia_requests();
	is( $body{programs}->{filters}, 'contentType:program AND ' . Plugins::ABCListen::ProgramIndex::siteFilter(), 'programs: contentType:program AND ProgramIndex::siteFilter()' );
	is( $body{programs}->{filters}, Plugins::ABCListen::ProgramIndex::FILTERS(), '... exactly the A–Z index\'s filter' );
	like( $body{episodes}->{filters}, qr/\) AND \Q${\ Plugins::ABCListen::ProgramIndex::siteFilter() }\E\z/, 'episodes: the same site clause' );
	is( Plugins::ABCListen::ProgramIndex->siteFilter, $SEGMENTS, 'siteFilter(): the site and URL segments of the 5 ABC listen sites (class method too)' );
};

done_testing();
