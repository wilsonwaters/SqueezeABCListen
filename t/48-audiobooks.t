#!/usr/bin/perl
# Plugins::ABCListen::Audiobooks (D5), offline (SimpleAsyncHTTP stub, fake clock, server time zone
# Australia/Sydney):
#   unit:      isAudiobook truth table; chapters(): the exact Algolia request (query, filter,
#              hitsPerPage, attributes; ttl 86400 = no second request within 24 h, also after a
#              "restart"; stale_ok; 8 s timeout), mapping to contract-3 refs (renditions with
#              fileSize, window ends, OPEN_END, seenAt), reading order (ascending numeric id),
#              DQ4 status filter, duplicates, malformed and non-audio hits, missing renditions and
#              dates, windows opening later, nbHits above the hits returned (WARN once),
#              coalescing, RATE_LIMITED (429, budget used up), LOAD_FAILED, exactly one callback;
#   component: the program-menu provider ([] for non-books and books without an id, the
#              Chapters link and Chapters (N), no HTTP request, never dies), registration in init
#              (only when the registry exists; Discover->init calls it), the Chapters feed (rows
#              via a recording episodeItem stub named "<n>. <title>", meta-cache seeding, empty /
#              error / stale-link text items, the 12 s deadline, a dying LMS callback), and with
#              O2's real builders and program menu: play URLs in reading order, O1 playing a
#              chapter from the seeded renditions without a request (geo failToken), the book menu
#              showing Chapters (and no "No episodes available") before M2's Follow, Octonauts
#              (template default, restricted), and no Chapters for The Science Show.
#
# Fixtures (t/data/discovery/, the research {_fixture_note} wrapper stripped; shapes unedited):
#   algolia-audiobook-chapters.trimmed.json  POST https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query
#       {"query":"","hitsPerPage":200,"filters":"contentType:audioepisode AND programID=106353766",...}
#       (2026-10-19): The Dictionary of Lost Words, nbHits 30, hits trimmed to the first 2 + last 2
#   nextdata-program-audiobook.trimmed.json  GET /_next/data/build-3afcd04f/listen/audiobooks/
#       the-dictionary-of-lost-words-page.json (2026-10-19): programTemplate audiobook,
#       webDistributionRestricted true, programCollectionPrepared null
# Synthetic: algolia-audiobook-chapters-edge.synthetic.json (unordered ids incl. a 10-digit one, a
#   later publication date, status matrix, missing renditions/dates, a window opening later, a
#   duplicate, malformed/missing objectIDs, a program hit, a non-hash hit, entities, an off-www
#   canonicalURL, a non-http rendition), nextdata-program-octonauts.synthetic.json (a book under
#   /listen/programs/: template default, restricted, no collection); discovery/
#   algolia-search-empty.synthetic.json (no hits, D3). The search page is F3's
#   t/data/foundation/listen-search.trimmed.html (app id TESTAPPID, key testsearchkey: never a real key).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Audiobooks;
use Plugins::ABCListen::Discover;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $AB        = 'Plugins::ABCListen::Audiobooks';
my $OD        = 'Plugins::ABCListen::OnDemand';
my $SITE      = 'https://www.abc.net.au';
my $NEXT      = "$SITE/_next/data/build-3afcd04f";
my $ALGOLIA   = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $T0        = 1_792_400_000;    # Mon 19 Oct 2026, 08:53 UTC (19:53 in Sydney)
my $DAY       = 86400;
my $OPEN_END  = 4_102_444_800;
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $GEO       = 'https://mediacore-live-production.akamaized.net/geo-001/audio';

my $BOOK_ID   = '106353766';
my $BOOK_PATH = '/listen/audiobooks/the-dictionary-of-lost-words-page';
my $BOOK_IMG  = 'https://live-production.wcms.abc-cdn.net.au/d69f290a96e32fb4674bad70b4211043?impolicy=wcms_crop_resize&cropH=862&cropW=862&xPos=0&yPos=0&width=862&height=862';
my %BOOK      = ( title => 'The Dictionary of Lost Words', path => $BOOK_PATH, id => $BOOK_ID, image => $BOOK_IMG );
my $EDGE_ID   = '900100';

my $LOAD_FAILED  = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $RATE_LIMITED = string('PLUGIN_ABCLISTEN_RATE_LIMITED');
my $NO_EPISODES  = string('PLUGIN_ABCLISTEN_NO_EPISODES');

my $EXTRAS   = \&Plugins::ABCListen::Audiobooks::_programMenuExtras;
my $CHAPTERS = \&Plugins::ABCListen::Audiobooks::_chaptersFeed;
my $PROGRAM  = \&Plugins::ABCListen::OnDemand::_programMenu;

my @ATTRIBUTES = qw(objectID title canonicalURL duration dates mediaRenditions mediaDownloadStatus mediaStreamingStatus programTitle programID);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::OnDemand::_resetProviders();
	Plugins::ABCListen::Audiobooks::_reset();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	return;
}

sub epoch { my ( $y, $mo, $d, $h, $mi ) = @_; timegm( 0, $mi || 0, $h || 0, $d, $mo - 1, $y ) }

# Answer the Algolia POSTs: by the book id in the filter => { file | content | code | error | defer }
sub serve {
	my %by = @_;
	Slim::Networking::SimpleAsyncHTTP->addRoute( $ALGOLIA, sub {
		my ( $url, $method, $body ) = @_;
		my $params = eval { JSON::PP::decode_json($body) } || {};
		my ($id) = ( $params->{filters} || '' ) =~ /programID=([0-9]+)/;
		my $response = $by{ $id || '' } or return { error => 'no test response for this book' };
		my %r = ( headers => $JSON_TYPE, %$response );
		$r{content} = fixture( delete $r{file} ) if $r{file};
		return \%r;
	} );
}

sub serve_book { serve( $BOOK_ID => { file => 'discovery/algolia-audiobook-chapters.trimmed.json' }, $EDGE_ID => { file => 'discovery/algolia-audiobook-chapters-edge.synthetic.json' }, @_ ) }

sub algolia_requests { grep { $_->{url} eq $ALGOLIA } requests() }
sub bodies           { map { JSON::PP::decode_json( $_->{body} ) } algolia_requests() }

sub chapters {
	my ($id) = @_;
	my $c = collector();
	$AB->chapters( $id, $c->cb );
	return $c;
}

sub result_of { my ($r) = $_[0]->args(0); $r }

sub ids_of { [ map { $_->{id} } @{ $_[0] || [] } ] }

sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub items_of {
	my ($result) = $_[0]->args(0);
	return ref $result eq 'HASH' ? $result->{items} : $result;
}

sub names { [ map { $_->{name} } @{ $_[0] || [] } ] }

sub text_item { { name => $_[0], type => 'text' } }

sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub errors_logged   { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# Every item has a readable, non-empty name and no raw token.
sub readable {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable name" );
}

# A recording stand-in for OnDemand->episodeItem that writes nothing to the meta cache.
sub with_recording_episodeItem {
	my ( $code, @calls ) = @_;
	no warnings 'redefine';
	local *Plugins::ABCListen::OnDemand::episodeItem = sub {
		my ( $class, $client, $episode ) = @_;
		push @calls, {%$episode};
		return { name => "row $episode->{id}", line1 => $episode->{title}, type => 'link', play => "abclisten://episode/$episode->{id}" };
	};
	$code->();
	return \@calls;
}

# ---- isAudiobook ----

subtest 'isAudiobook: truth table' => sub {
	my @cases = (
		[ { template => 'audiobook', restricted => 1, id => 1 },                               1, 'template audiobook, restricted, no collection (Dictionary of Lost Words)' ],
		[ { template => 'Audiobook', restricted => 0 },                                        1, 'template audiobook (any case), unrestricted' ],
		[ { template => 'audiobook', restricted => 1, episodeCollectionId => '9' },            1, 'template audiobook wins over a collection' ],
		[ { template => 'default', restricted => 1, path => '/listen/programs/octonauts' },     1, 'template default + restricted + no collection (Octonauts)' ],
		[ { template => 'default', restricted => 1, episodeCollectionId => '2885458' },        0, 'restricted with an episode collection: not a book' ],
		[ { template => 'default', restricted => 0 },                                          0, 'default, unrestricted' ],
		[ { template => 'audio', restricted => 0, path => '/listen/audiobooks/x-page' },        0, 'template passed: the path is not used' ],
		[ { path => '/listen/audiobooks/the-dictionary-of-lost-words-page' },                  1, 'no template: path under /listen/audiobooks/' ],
		[ { path => 'https://www.abc.net.au/listen/audiobooks/a-book-page/' },                1, 'no template: full URL under /listen/audiobooks/' ],
		[ { path => '/listen/audiobooks' },                                                    0, 'no template: the section page itself' ],
		[ { path => '/listen/audiobooks/x-page', episodeCollectionId => '7' },                 0, 'no template: path under audiobooks but with a collection' ],
		[ { path => '/listen/programs/scienceshow' },                                          0, 'no template: another path' ],
		[ { restricted => 1 },                                                                 1, 'no template: restricted without a collection' ],
		[ { template => 'default', restricted => JSON::PP::false() },                          0, 'restricted as a JSON false' ],
		[ undef,                                                                               0, 'undef' ],
		[ 'a string',                                                                          0, 'not a hash' ],
	);
	is( $AB->isAudiobook( $_->[0] ), $_->[1], $_->[2] ) for @cases;
	is( Plugins::ABCListen::Audiobooks::isAudiobook( { template => 'audiobook' } ), 1, 'works as a plain function too' );
};

# ---- chapters(): request ----

subtest 'chapters(): the Algolia request (filter, hitsPerPage, attributes, timeout) and the 24 h cache' => sub {
	fresh();
	serve_book();

	my $c = chapters($BOOK_ID);
	is( $c->count, 1, 'one callback' );
	my @requests = algolia_requests();
	is( scalar @requests, 1, 'one Algolia request' );
	is_deeply(
		[ bodies() ],
		[ { query => '', hitsPerPage => 1000, filters => "contentType:audioepisode AND programID=$BOOK_ID", attributesToRetrieve => \@ATTRIBUTES } ],
		'exact body: empty query, numeric programID filter, 1000 hits, the attributes D5 maps'
	);
	is( $requests[0]->{params}->{timeout}, 8, '8 s request timeout (menu path)' );
	is( $requests[0]->{method}, 'POST', 'POST' );

	advanceTime( 2 * 3600 );
	$c = chapters($BOOK_ID);
	is( scalar algolia_requests(), 1, '2 h later (past the API default of 1 h): served from the cache, no request' );
	is( scalar @{ result_of($c)->{items} }, 4, 'cached answer: the same chapters' );

	Plugins::ABCListen::API::_reset();    # an LMS restart: in-memory state gone, the cache kept
	setTime( $T0 + $DAY - 1 );
	my $sync = 0;
	$AB->chapters( $BOOK_ID, sub { $sync++ } );
	is( $sync, 1, 'after a restart, within 24 h: answered at once from the cache' );
	is( scalar algolia_requests(), 1, '... with no Algolia request' );

	setTime( $T0 + $DAY );
	chapters($BOOK_ID);
	is( scalar algolia_requests(), 2, 'after 24 h: one new request' );
};

subtest 'chapters(): mapping to contract-3 refs, reading order = ascending id' => sub {
	fresh();
	serve_book();

	my $result = result_of( chapters($BOOK_ID) );
	is_deeply( ids_of( $result->{items} ), [qw(106353760 106442258 106442598 106442610)], 'ascending numeric id (the index returns newest first)' );
	is_deeply(
		[ map { $_->{title} } @{ $result->{items} } ],
		[ 'Prologue: February 1886', 'PART ONE: 1887 - 1896', 'Timeline of the Oxford English Dictionary', 'Timeline of Major Historical Events Featured in the Novel' ],
		'titles in reading order'
	);
	is_deeply(
		$result->{items}->[0],
		{
			id                  => '106353760',
			docType             => 'audioepisode',
			title               => 'Prologue: February 1886',
			programId           => $BOOK_ID,
			path                => "$BOOK_PATH/prologue-february-1886/106353760",
			duration            => 257,
			date                => epoch( 2026, 4, 1, 13 ),
			renditions          => [ { url => "$GEO/02/j6/Z/rr.mp3", mime => 'audio/mpeg', bitrate => 320, fileSize => 10547937 } ],
			availableTo         => epoch( 2027, 4, 1, 13 ),
			downloadAvailableTo => epoch( 2027, 4, 1, 13 ),
			seenAt              => $T0,
		},
		'chapter 1: every contract-3 key (no programTitle: the fixture has none)'
	);
	is_deeply( [ sort keys %$result ], ['items'], 'success is { items }' );
	ok( ( grep { $_->{message} =~ /106353766: ABC's search index has 30 chapters, listing the 4 it returned/ } warnings_logged() ), 'nbHits 30 > 4 hits: WARN' );

	advanceTime(3 * 3600);
	Plugins::ABCListen::API::_reset();
	chapters($BOOK_ID);
	is( scalar( grep { $_->{message} =~ /search index has 30 chapters/ } warnings_logged() ), 1, 'the truncation WARN is logged once per book' );
};

subtest 'chapters(): status filter, duplicates, malformed hits, missing renditions/dates, later windows, numeric order' => sub {
	fresh();
	serve_book();

	my $items = result_of( chapters($EDGE_ID) )->{items};
	is_deeply(
		ids_of($items),
		[qw(900098 900101 900103 900104 900105 900107 900109 1000000001)],
		'kept in ascending numeric id order (a later publication date first; 10 digits last)'
	);
	my %by = map { $_->{id} => $_ } @$items;

	ok( !( grep { $by{$_} } qw(900102 900106 900108) ), 'hidden: EXPIRED/EXPIRED, NONE/EXPIRED, expired/none (any case)' );
	is( $by{900107}->{title}, 'Chapter Seven', 'PENDING/PENDING kept (index lag)' );
	is( $by{1000000001}->{title}, 'Epilogue & Notes', 'AVAILABLE/NONE kept; entities decoded' );
	is( $by{900101}->{title}, 'Chapter One', 'duplicate id: the first hit wins' );
	is( $by{900103}->{title}, 'Chapter Three', 'title trimmed' );
	is( scalar( grep { $_->{id} eq '900101' } @$items ), 1, 'duplicate id listed once' );

	ok( !exists $by{900103}->{$_}, "no mediaRenditions: no $_" ) for qw(renditions availableTo downloadAvailableTo seenAt);
	is( $by{900103}->{date}, epoch( 2026, 4, 1, 13 ), 'no mediaRenditions: still listed, with its date' );

	is_deeply(
		[ @{ $by{900104} }{qw(availableTo downloadAvailableTo seenAt)} ],
		[ $OPEN_END, $OPEN_END, $T0 ],
		'no dates: renditions seeded with open window ends (never undef), seenAt'
	);
	ok( !exists $by{900104}->{date}, 'no dates: no date' );
	is_deeply( $by{900104}->{renditions}, [ { url => "$GEO/90/01/Z/04.mp3", mime => 'audio/mpeg', bitrate => 128 } ], 'no fileSize in the hit: none in the rendition' );

	ok( !exists $by{900109}->{renditions} && !exists $by{900109}->{seenAt}, 'window opens later: listed, not seeded' );

	my $epilogue = $by{1000000001};
	is_deeply( $epilogue->{renditions}, [ { url => "$GEO/90/01/Z/99.mp3", mime => 'audio/mpeg' } ], 'non-http rendition dropped; bitrate 0 left out' );
	is_deeply( [ @$epilogue{qw(availableTo downloadAvailableTo)} ], [ $OPEN_END, $OPEN_END ], 'missing / 2200-01-01 window ends: OPEN_END' );
	is( $epilogue->{path},      '/listen/audiobooks/edge-book-page/epilogue/1000000001', 'canonical path (abc.net.au host, trailing slash)' );
	is( $epilogue->{duration},  600,                                                     'string duration -> number' );
	is( $epilogue->{programId}, '900100',                                                'string programID -> digits' );
	ok( !exists $epilogue->{programTitle}, 'no programTitle in the hit: none in the ref' );

	is( scalar( grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) ), 0, 'nbHits not above the hits: no WARN' );
};

subtest 'chapters(): errors, budget, coalescing, stale_ok, exactly one callback' => sub {
	fresh();
	serve_book( $BOOK_ID => { code => 429, content => '{"message":"Too many requests"}' } );
	my $c = chapters($BOOK_ID);
	is( $c->count, 1, '429: one callback' );
	is_deeply( result_of($c), { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' }, '429: RATE_LIMITED' );

	fresh();
	serve_book( $BOOK_ID => { code => 500, content => 'oops' } );
	is_deeply( result_of( chapters($BOOK_ID) ), { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, '500: LOAD_FAILED' );

	fresh();
	serve_book( $BOOK_ID => { content => '{"nbHits":0}' } );
	is_deeply( result_of( chapters($BOOK_ID) ), { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'no hits list: LOAD_FAILED' );
	ok( ( grep { $_->{message} =~ /no hits list/ } errors_logged() ), '... logged' );

	fresh();
	serve_book( $BOOK_ID => { file => 'discovery/algolia-search-empty.synthetic.json' } );
	is_deeply( result_of( chapters($BOOK_ID) ), { items => [] }, 'no hits: { items => [] }' );

	for my $bad ( undef, '', 'abc', '12 34', [1] ) {
		fresh();
		my $c = chapters($bad);
		is_deeply( [ $c->count, result_of($c) ], [ 1, { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'not a program id (' . ( defined $bad ? "'$bad'" : 'undef' ) . '): LOAD_FAILED once' );
		is( scalar requests(), 0, '... without a request' );
	}

	# the plugin's Algolia budget (300 queries an hour, shared with Search and the program index)
	fresh();
	route( $ALGOLIA, content => '{"hits":[],"nbHits":0}', headers => $JSON_TYPE );
	Plugins::ABCListen::API::algolia( { query => "q$_" }, sub { }, sub { } ) for 1 .. 300;
	is( scalar algolia_requests(), 300, '300 other queries used up the hour\'s budget' );
	$c = chapters($BOOK_ID);
	is_deeply( result_of($c), { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' }, 'over budget: RATE_LIMITED' );
	is( scalar algolia_requests(), 300, '... without a request' );

	# coalescing: two opens while the query is in flight -> one request, one answer each
	fresh();
	serve_book( $BOOK_ID => { file => 'discovery/algolia-audiobook-chapters.trimmed.json', defer => 1 } );
	my ( $c1, $c2 ) = ( chapters($BOOK_ID), chapters($BOOK_ID) );
	is( scalar algolia_requests(), 1, 'two calls in flight: one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ $c1->count, $c2->count ], [ 1, 1 ], 'one answer each' );
	is_deeply( ids_of( result_of($c2)->{items} ), ids_of( result_of($c1)->{items} ), 'the same chapters' );

	# stale_ok: after 24 h ABC fails -> the last good list, without seenAt, count not refreshed
	fresh();
	serve_book();
	chapters($BOOK_ID);
	setTime( $T0 + $DAY + 60 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( $ALGOLIA, code => 503, content => 'down' );
	$c = chapters($BOOK_ID);
	is( scalar algolia_requests(), 1, 'after 24 h: a new request' );
	my $items = result_of($c)->{items};
	is_deeply( ids_of($items), [qw(106353760 106442258 106442598 106442610)], 'ABC fails: the last good chapters (stale_ok)' );
	ok( $items->[0]->{renditions} && !exists $items->[0]->{seenAt}, 'stale: renditions kept, no seenAt (it would vouch for an old list)' );
	is( Plugins::ABCListen::Audiobooks::_cachedCount($BOOK_ID), undef, 'stale: the Chapters (N) count is not refreshed (it expired with the query)' );

	# a callback that dies: logged, never called again
	fresh();
	serve_book();
	my $calls = 0;
	$AB->chapters( $BOOK_ID, sub { $calls++; die "callback exploded\n" } );
	is( $calls, 1, 'dying callback: called once' );
	ok( ( grep { $_->{message} =~ /the callback died: callback exploded/ } errors_logged() ), '... and logged' );

	fresh();
	$AB->chapters($BOOK_ID);
	ok( ( grep { $_->{message} =~ /without a callback/ } errors_logged() ), 'no callback: logged, no request' );
	is( scalar requests(), 0, '... no request' );
};

# ---- provider ----

subtest 'provider: [] for non-books and books without an id; Chapters / Chapters (N); no HTTP; never dies' => sub {
	fresh();

	my $call = sub {
		my ( $program, $client ) = @_;
		my @calls;
		$EXTRAS->( $client, $program, sub { push @calls, [@_] } );
		is( scalar @calls, 1, 'one callback' );
		return $calls[0]->[0];
	};

	is_deeply( $call->( { title => 'The Science Show', path => '/listen/programs/scienceshow', id => '2885500', template => 'default', restricted => 0, episodeCollectionId => '2885458' } ), [], 'The Science Show: []' );
	is_deeply( $call->( { %BOOK, template => 'audiobook', restricted => 1, id => undef } ), [], 'a book without an id: []' );
	is_deeply( $call->( { %BOOK, template => 'audiobook', restricted => 1, id => 'coremedia://program/1' } ), [], 'a book with a non-numeric id: []' );
	is_deeply( $call->(undef), [], 'undef program: []' );

	my $book = { %BOOK, template => 'audiobook', restricted => 1, network => 'ABC listen' };
	my $rows = $call->($book);
	is_deeply(
		$rows,
		[ {
			name        => 'Chapters',
			type        => 'playlist',
			url         => $CHAPTERS,
			passthrough => [ { id => $BOOK_ID, title => 'The Dictionary of Lost Words', image => $BOOK_IMG } ],
		} ],
		'a book: one Chapters link, type playlist (Play all / Add all), no description'
	);
	is( scalar requests(), 0, 'the provider makes no HTTP request (not even when nothing is cached)' );

	my $player = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is( $call->( $book, $player )->[0]->{name}, 'Chapters', 'with a player: the same' );

	# once chapters() has answered (fresh), the count is known
	serve_book();
	chapters($BOOK_ID);
	@Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
	is( $call->($book)->[0]->{name}, 'Chapters (4)', 'cached: Chapters (N)' );
	is( scalar requests(), 0, '... read from the cache only' );

	setTime( $T0 + $DAY + 1 );
	is( $call->($book)->[0]->{name}, 'Chapters', 'after 24 h (the query expired): Chapters again' );

	is_deeply( $call->( { template => 'audiobook', id => '1', title => [], image => sub {1} } )->[0]->{passthrough}, [ { id => '1' } ], 'no usable title or image: passthrough { id }' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Audiobooks::isAudiobook = sub { die "isAudiobook exploded\n" };
		is_deeply( $call->($book), [], 'building the item dies: []' );
	}
	ok( ( grep { $_->{message} =~ /Chapters item failed: isAudiobook exploded/ } errors_logged() ), '... logged' );
};

subtest 'init: registers the provider when the registry exists; Discover->init calls it' => sub {
	fresh();
	$AB->init;
	my @rows;
	$OD->registerProgramMenuProvider( sub { $_[2]->( [] ) } );    # a later provider (M2) still works
	Plugins::ABCListen::OnDemand::_runProviders( undef, { %BOOK, template => 'audiobook', restricted => 1 }, sub { @rows = @{ $_[0] } } );
	is_deeply( names( \@rows ), ['Chapters'], 'Audiobooks->init registered the Chapters provider' );

	fresh();
	Plugins::ABCListen::Discover->init;
	Plugins::ABCListen::OnDemand::_runProviders( undef, { %BOOK, template => 'audiobook', restricted => 1 }, sub { @rows = @{ $_[0] } } );
	is_deeply( names( \@rows ), ['Chapters'], 'Discover->init calls Audiobooks->init' );

	fresh();
	{
		no strict 'refs';
		local *{'Plugins::ABCListen::OnDemand::registerProgramMenuProvider'};
		ok( !$OD->can('registerProgramMenuProvider'), '(registry removed)' );
		ok( eval { $AB->init; 1 }, 'without the registry: init does not die' );
	}
	ok( ( grep { $_->{message} =~ /no provider registry/ } warnings_logged() ), '... and says so' );
	Plugins::ABCListen::OnDemand::_runProviders( undef, { %BOOK, template => 'audiobook', restricted => 1 }, sub { @rows = @{ $_[0] } } );
	is_deeply( \@rows, [], '... nothing registered' );
};

# ---- the Chapters feed ----

subtest 'Chapters feed: rows via episodeItem named "<n>. <title>", book image, meta-cache seeding' => sub {
	fresh();
	serve_book();

	my $c;
	my $calls = with_recording_episodeItem( sub { $c = feed( $CHAPTERS, undef, { id => $BOOK_ID, title => 'The Dictionary of Lost Words', image => $BOOK_IMG } ) } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply(
		names($items),
		[ '1. Prologue: February 1886', '2. PART ONE: 1887 - 1896', '3. Timeline of the Oxford English Dictionary', '4. Timeline of Major Historical Events Featured in the Novel' ],
		'names carry the reading position'
	);
	is_deeply( [ map { $_->{line1} } @$items ], names($items), 'line1 = name' );
	is_deeply( ids_of($calls), [qw(106353760 106442258 106442598 106442610)], 'episodeItem called in reading order' );
	is_deeply( [ map { $_->{programImage} } @$calls ], [ ($BOOK_IMG) x 4 ], 'programImage = the book image' );
	is_deeply( [ map { $_->{programTitle} } @$calls ], [ ('The Dictionary of Lost Words') x 4 ], 'programTitle from the book (the hits have none)' );
	is( $calls->[0]->{renditions}->[0]->{url}, "$GEO/02/j6/Z/rr.mp3", 'the ref passes its renditions' );

	my $meta = Plugins::ABCListen::Util::getEpisodeMeta('106353760');
	is_deeply(
		{ map { $_ => $meta->{$_} } qw(renditions availableTo downloadAvailableTo seenAt) },
		{ renditions => [ { url => "$GEO/02/j6/Z/rr.mp3", mime => 'audio/mpeg', bitrate => 320, fileSize => 10547937 } ], availableTo => epoch( 2027, 4, 1, 13 ), downloadAvailableTo => epoch( 2027, 4, 1, 13 ), seenAt => $T0 },
		'an episodeItem that stores nothing: the feed seeds renditions, windows, seenAt itself'
	);

	# with the real builder
	fresh();
	serve_book();
	my $player = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	$items = items_of( feed( $CHAPTERS, $player, { id => $EDGE_ID, title => 'Edge Book' } ) );
	is_deeply(
		names($items),
		[ '1. Prologue', '2. Chapter One', '3. Chapter Three', '4. Chapter Four', '5. Chapter Five', '6. Chapter Seven', '7. Chapter Nine', '8. Epilogue & Notes' ],
		'O2\'s episodeItem rows, renamed "<n>. <title>"'
	);
	is_deeply(
		[ map { $_->{play} } @$items ],
		[ map {"abclisten://episode/$_"} qw(900098 900101 900103 900104 900105 900107 900109 1000000001) ],
		'play URLs (abclisten://episode/<id>) in reading order: what Play all / Add all queue'
	);
	is( scalar( grep { $_->{type} eq 'link' && $_->{url} == \&Plugins::ABCListen::OnDemand::_episodeMenu } @$items ), 8, 'rows open O2\'s episode page' );
	ok( !( grep { exists $_->{description} } @$items ), 'no description on the rows' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('1000000001')->{programTitle}, 'Edge Book', 'meta cache: programTitle from the book when the hit has none' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('900101')->{seenAt}, $T0, 'meta cache: seenAt (written by episodeItem)' );
	ok( !Plugins::ABCListen::Util::getEpisodeMeta('900103')->{renditions}, 'meta cache: no renditions for a chapter without them (O1 looks it up)' );
	readable( $items, 'chapter rows' );
};

subtest 'Chapters feed: O1 plays chapter 1 from the seeded renditions, without a request (geo)' => sub {
	fresh();
	serve_book();
	my $items = items_of( feed( $CHAPTERS, undef, { %BOOK } ) );

	Slim::Networking::SimpleAsyncHTTP->reset;
	my $c = collector();
	Plugins::ABCListen::Episode->resolve( '106353760', $c->cb );
	is( $c->count, 1, 'O1 answers at once' );
	my ($answer) = $c->args(0);
	is( $answer->{url},       "$GEO/02/j6/Z/rr.mp3",              'with the seeded /geo-001/ MP3' );
	is( $answer->{failToken}, 'PLUGIN_ABCLISTEN_EPISODE_GEO', 'and the "only available in Australia" message if it fails' );
	is( scalar requests(), 0, 'no _next/data page fetch, no Algolia lookup: no request at all' );
	is( $answer->{meta}->{title}, 'Prologue: February 1886', 'Now Playing title: the chapter title' );
	is( $answer->{meta}->{artist}, 'The Dictionary of Lost Words', 'Now Playing artist: the book' );
};

subtest 'Chapters feed: empty, errors, stale links, deadline, dying callback - one readable item, once' => sub {
	fresh();
	serve( 1 => { file => 'discovery/algolia-search-empty.synthetic.json' } );
	my $c = feed( $CHAPTERS, undef, { id => '1' } );
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($NO_EPISODES) ] ], 'no chapters: No episodes available' );

	fresh();
	serve( 1 => { code => 429, content => '{}' } );
	$c = feed( $CHAPTERS, undef, { id => '1' } );
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($RATE_LIMITED) ] ], '429: the busy text' );

	fresh();
	serve( 1 => { error => 'Timed out waiting for data' } );
	$c = feed( $CHAPTERS, undef, { id => '1' } );
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($LOAD_FAILED) ] ], 'network error: LOAD_FAILED' );

	for my $pt ( undef, {}, { id => 'x' }, 'junk' ) {
		fresh();
		$c = feed( $CHAPTERS, undef, $pt );
		is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($LOAD_FAILED) ] ], 'stale or malformed passthrough (' . ( ref $pt ? '{' . join( ',', %$pt ) . '}' : defined $pt ? $pt : 'undef' ) . '): one LOAD_FAILED item' );
		is( scalar requests(), 0, '... no request' );
	}

	# deadline: ABC doesn't answer within 12 s
	fresh();
	serve_book( $BOOK_ID => { file => 'discovery/algolia-audiobook-chapters.trimmed.json', defer => 1 } );
	$c = feed( $CHAPTERS, undef, { %BOOK } );
	is( $c->count, 0, 'waiting for ABC' );
	advanceTime(11.9);
	is( $c->count, 0, 'not before 12 s' );
	advanceTime(0.2);
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($LOAD_FAILED) ] ], 'at 12 s: one LOAD_FAILED item' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late answer is not passed on' );
	ok( Plugins::ABCListen::Util::getEpisodeMeta('106353760'), '... but it seeded the meta cache' );
	@Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
	$c = feed( $CHAPTERS, undef, { %BOOK } );
	is( scalar @{ items_of($c) }, 4, 'next open: the cached chapters at once' );
	is( scalar requests(), 0, '... without a request' );
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timer left behind' );

	# LMS's callback dies
	fresh();
	serve_book();
	my $n = 0;
	$CHAPTERS->( undef, sub { $n++; die "LMS exploded\n" }, {}, { %BOOK } );
	advanceTime(20);
	is( $n, 1, 'a dying callback is called once (not again at the deadline)' );
	ok( ( grep { $_->{message} =~ /menu callback died: LMS exploded/ } errors_logged() ), '... and logged' );

	# building the rows dies
	fresh();
	serve_book();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub { die "builder exploded\n" };
		$c = feed( $CHAPTERS, undef, { %BOOK } );
	}
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($LOAD_FAILED) ] ], 'building the rows dies: one LOAD_FAILED item' );

	# episodeItem refuses every ref
	fresh();
	serve_book();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub {undef};
		$c = feed( $CHAPTERS, undef, { %BOOK } );
	}
	is_deeply( items_of($c), [ text_item($NO_EPISODES) ], 'no row could be built: No episodes available' );
};

# ---- with O2's program menu ----

subtest 'program menu: Chapters in the book menu (before Follow, no "No episodes available"); not for The Science Show' => sub {
	my $setup = sub {
		fresh();
		%{ preferences('plugin.abclisten') } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
		Plugins::ABCListen::Discover->init;
		Plugins::ABCListen::MyABC->init;
		route( "$NEXT$BOOK_PATH.json", file => 'discovery/nextdata-program-audiobook.trimmed.json', headers => $JSON_TYPE );
		route( "$NEXT/listen/programs/octonauts.json", file => 'discovery/nextdata-program-octonauts.synthetic.json', headers => $JSON_TYPE );
		route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
		route( qr{/core-next/api/episodesWithSegments/x\?collectionId=2885458&}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );
		serve_book();
	};

	$setup->();
	my $menu = items_of( feed( $PROGRAM, undef, { title => 'The Dictionary of Lost Words', path => $BOOK_PATH, image => $BOOK_IMG } ) );
	my @names = @{ names($menu) };
	my ($chapters) = grep { $_->{name} =~ /\AChapters/ } @$menu;
	ok( $chapters, 'the book menu has a Chapters item' );
	is( $chapters->{name}, 'Chapters', 'first open: "Chapters"' );
	is( $chapters->{type}, 'playlist', '... type playlist' );
	is_deeply( $chapters->{passthrough}, [ { id => $BOOK_ID, title => 'The Dictionary of Lost Words', image => $BOOK_IMG } ], '... with the book id from the page' );
	ok( !( grep { $_ eq $NO_EPISODES } @names ), 'no "No episodes available" row' );
	my ($ci) = grep { $names[$_] =~ /\AChapters/ } 0 .. $#names;
	my ($fi) = grep { $names[$_] =~ /\AFollow/ } 0 .. $#names;
	ok( defined $fi && $ci < $fi, 'Chapters comes before M2\'s Follow' ) or diag explain \@names;
	is( scalar algolia_requests(), 0, 'opening the book menu sends no Algolia query' );

	my $rows = items_of( feed( $chapters->{url}, undef, @{ $chapters->{passthrough} } ) );
	is( scalar @$rows, 4, 'Chapters opens the chapter list' );
	is( scalar algolia_requests(), 1, '... with one Algolia query' );

	$menu = items_of( feed( $PROGRAM, undef, { title => 'The Dictionary of Lost Words', path => $BOOK_PATH } ) );
	is( scalar( grep { $_->{name} eq 'Chapters (4)' } @$menu ), 1, 'reopened: "Chapters (4)"' );
	is( scalar algolia_requests(), 1, '... still one Algolia query in all' );

	$setup->();
	$menu = items_of( feed( $PROGRAM, undef, { title => 'Octonauts', path => '/listen/programs/octonauts' } ) );
	is_deeply( [ grep {/\AChapters/} @{ names($menu) } ], ['Chapters'], 'Octonauts (template default, restricted, no collection): Chapters' );

	$setup->();
	$menu = items_of( feed( $PROGRAM, undef, { title => 'The Science Show', path => '/listen/programs/scienceshow' } ) );
	ok( scalar @$menu > 5, 'The Science Show menu lists its episodes' );
	is( scalar( grep { $_->{name} =~ /\AChapters/ } @$menu ), 0, 'The Science Show: no Chapters item' );
	is( scalar algolia_requests(), 0, '... and no Algolia query' );
};

subtest 'strings' => sub {
	is( string('PLUGIN_ABCLISTEN_CHAPTERS'), 'Chapters', 'PLUGIN_ABCLISTEN_CHAPTERS' );
	is( string( 'PLUGIN_ABCLISTEN_CHAPTERS_N', 30 ), 'Chapters (30)', 'PLUGIN_ABCLISTEN_CHAPTERS_N' );
};

done_testing();
