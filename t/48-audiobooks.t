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
#   review (PR #58): restricted podcasts (template audio: Bluey Listen Along, Bluey Book Reads,
#              Midsomer Murders Mayhem, Odd Squadcast, In Concert, The Bomb) are not books but get
#              an Episodes link (newest first, episodeItem rows, same query and cache; The Bomb's 0
#              -> No episodes available); seenAt is the fetch time (API.pm info at), none after 6 h;
#              an older answer never overwrites newer audio data in the meta cache; per-program
#              counts that follow a new answer; an API that answers twice.
#
# Fixtures (t/data/discovery/, the research {_fixture_note} wrapper stripped; shapes unedited):
#   algolia-audiobook-chapters.trimmed.json  POST https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query
#       {"query":"","hitsPerPage":200,"filters":"contentType:audioepisode AND programID=106353766",...}
#       (2026-10-19): The Dictionary of Lost Words, nbHits 30, hits trimmed to the first 2 + last 2
#   t/data/ondemand/nextdata-program-audiobook.trimmed.json (O2's copy) GET /_next/data/build-3afcd04f/
#       listen/audiobooks/the-dictionary-of-lost-words-page.json (2026-10-19): programTemplate
#       audiobook, webDistributionRestricted true, programCollectionPrepared null
#   nextdata-program-<slug>.trimmed.json  GET /_next/data/build-85c7f6fd/listen/programs/<slug>.json
#       (2026-10-23) for bluey-listen-along, bluey-book-reads, midsomer-murders-mayhem,
#       odd-squadcast, in-concert, the-bomb: programTemplate audio, webDistributionRestricted true,
#       programCollectionPrepared null; pageProps cut to the keys Programs->program reads, arrays to
#       3, heroImageWithCTAPrepared without shareUtilityProps
#   algolia-program-episodes-bluey-listen-along.trimmed.json  D5's query for programID=104672698
#       (2026-10-23): nbHits 41, hits trimmed to the first 3 + last 5 as returned, _highlightResult
#       dropped (several share a publication date; a later id can be an older episode)
#   algolia-program-episodes-the-bomb.json  D5's query for programID=106126660 (2026-10-23): no hits
# Synthetic: algolia-audiobook-chapters-edge.synthetic.json (unordered ids incl. a 10-digit one, a
#   later publication date, status matrix, missing renditions/dates, a window opening later (both,
#   or only the download one), a hit without programID, a duplicate, malformed/missing objectIDs, a
#   program hit, a non-hash hit, entities, an off-www canonicalURL, a non-http rendition),
#   nextdata-program-octonauts.synthetic.json (a book under
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
use Plugins::ABCListen::Programs;
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
my $BLUEY_ID  = '104672698';
my $BOMB_ID   = '106126660';
my $BLUEY     = '/listen/programs/bluey-listen-along';
my $BOMB      = '/listen/programs/the-bomb';
my $HOUR      = 3600;

my $LOAD_FAILED  = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $RATE_LIMITED = string('PLUGIN_ABCLISTEN_RATE_LIMITED');
my $NO_EPISODES  = string('PLUGIN_ABCLISTEN_NO_EPISODES');

my $EXTRAS   = \&Plugins::ABCListen::Audiobooks::_programMenuExtras;
my $CHAPTERS = \&Plugins::ABCListen::Audiobooks::_chaptersFeed;
my $EPISODES = \&Plugins::ABCListen::Audiobooks::_episodesFeed;
my $PROGRAM  = \&Plugins::ABCListen::OnDemand::_programMenu;

# The six restricted podcasts the review found (template audio, no episode collection on the web)
my @PODCASTS = qw(bluey-listen-along bluey-book-reads midsomer-murders-mayhem odd-squadcast in-concert the-bomb);

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

sub serve_book {
	serve(
		$BOOK_ID  => { file => 'discovery/algolia-audiobook-chapters.trimmed.json' },
		$EDGE_ID  => { file => 'discovery/algolia-audiobook-chapters-edge.synthetic.json' },
		$BLUEY_ID => { file => 'discovery/algolia-program-episodes-bluey-listen-along.trimmed.json' },
		$BOMB_ID  => { file => 'discovery/algolia-program-episodes-the-bomb.json' },
		@_,
	);
}

# The provider input O2 builds for a program page fixture: the row merged with Programs->program's
# detail (OnDemand::_programMenuItems' merge).
sub provider_input {
	my ( $fixture, $path ) = @_;
	route( "$NEXT$path.json", file => $fixture, headers => $JSON_TYPE );
	my $detail;
	Plugins::ABCListen::Programs::program( $path, sub { $detail = shift } );
	my %merged = ( path => $path );
	for my $key (qw(id title template restricted episodeCollectionId)) {
		$merged{$key} = $detail->{$key} if defined $detail->{$key} && length $detail->{$key};
	}
	return \%merged;
}

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

subtest 'isAudiobook / isRestrictedProgram: truth table' => sub {
	# [ input, isAudiobook, isRestrictedProgram, label ]
	my @cases = (
		[ { template => 'audiobook', restricted => 1, id => 1 },                               1, 0, 'template audiobook, restricted, no collection (Dictionary of Lost Words)' ],
		[ { template => 'Audiobook', restricted => 0 },                                        1, 0, 'template audiobook (any case), unrestricted' ],
		[ { template => 'audiobook', restricted => 1, episodeCollectionId => '9' },            1, 0, 'template audiobook wins over a collection' ],
		[ { template => 'default', restricted => 1, path => '/listen/programs/octonauts' },     1, 0, 'template default + restricted + no collection (Octonauts)' ],
		[ { template => 'audio', restricted => 1, path => $BLUEY },                            0, 1, 'template audio + restricted + no collection (a restricted podcast): not a book' ],
		[ { template => 'Audio', restricted => 1 },                                            0, 1, 'template audio (any case) + restricted: not a book' ],
		[ { template => 'audio', restricted => 1, episodeCollectionId => '5' },                0, 0, 'template audio + restricted with a collection: neither (O2 lists it)' ],
		[ { template => 'default', restricted => 1, episodeCollectionId => '2885458' },        0, 0, 'restricted with an episode collection: not a book' ],
		[ { template => 'default', restricted => 0 },                                          0, 0, 'default, unrestricted' ],
		[ { template => 'audio', restricted => 0 },                                            0, 0, 'audio, unrestricted (a normal podcast)' ],
		[ { template => 'audio', restricted => 0, path => '/listen/audiobooks/x-page' },        0, 0, 'template passed: the path is not used' ],
		[ { path => '/listen/audiobooks/the-dictionary-of-lost-words-page' },                  1, 0, 'no template: path under /listen/audiobooks/' ],
		[ { path => 'https://www.abc.net.au/listen/audiobooks/a-book-page/' },                1, 0, 'no template: full URL under /listen/audiobooks/' ],
		[ { path => '/listen/audiobooks' },                                                    0, 0, 'no template: the section page itself' ],
		[ { path => '/listen/audiobooks/x-page', episodeCollectionId => '7' },                 0, 0, 'no template: path under audiobooks but with a collection' ],
		[ { path => '/listen/programs/scienceshow' },                                          0, 0, 'no template: another path' ],
		[ { restricted => 1 },                                                                 1, 0, 'no template: restricted without a collection' ],
		[ { template => 'default', restricted => JSON::PP::false() },                          0, 0, 'restricted as a JSON false' ],
		[ undef,                                                                               0, 0, 'undef' ],
		[ 'a string',                                                                          0, 0, 'not a hash' ],
	);
	for (@cases) {
		is( $AB->isAudiobook( $_->[0] ),         $_->[1], "isAudiobook: $_->[3]" );
		is( $AB->isRestrictedProgram( $_->[0] ), $_->[2], "isRestrictedProgram: $_->[3]" );
	}
	is( Plugins::ABCListen::Audiobooks::isAudiobook( { template => 'audiobook' } ), 1, 'works as a plain function too' );
	is( Plugins::ABCListen::Audiobooks::isRestrictedProgram( { template => 'audio', restricted => 1 } ), 1, 'isRestrictedProgram as a plain function' );
};

subtest 'truth table on live program pages: six restricted podcasts are not books; books still are' => sub {
	fresh();
	for my $slug (@PODCASTS) {
		my $input = provider_input( "discovery/nextdata-program-$slug.trimmed.json", "/listen/programs/$slug" );
		is_deeply( [ @$input{qw(template restricted)}, exists $input->{episodeCollectionId} ? 1 : 0 ], [ 'audio', 1, 0 ], "$slug: template audio, restricted, no collection (as ABC serves it)" );
		is( $AB->isAudiobook($input),         0, "$slug: not an audiobook (no numbered Chapters)" );
		is( $AB->isRestrictedProgram($input), 1, "$slug: a restricted program (Episodes from the index)" );
	}

	my $book = provider_input( 'ondemand/nextdata-program-audiobook.trimmed.json', $BOOK_PATH );
	is_deeply( [ $AB->isAudiobook($book), $AB->isRestrictedProgram($book) ], [ 1, 0 ], 'The Dictionary of Lost Words (template audiobook): a book' );
	my $octonauts = provider_input( 'discovery/nextdata-program-octonauts.synthetic.json', '/listen/programs/octonauts' );
	is_deeply( [ $AB->isAudiobook($octonauts), $AB->isRestrictedProgram($octonauts) ], [ 1, 0 ], 'Octonauts (template default, restricted): a book' );
	my $science = provider_input( 'ondemand/nextdata-program-scienceshow.trimmed.json', '/listen/programs/scienceshow' );
	is_deeply( [ $AB->isAudiobook($science), $AB->isRestrictedProgram($science) ], [ 0, 0 ], 'The Science Show: neither' );
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
	is_deeply( [ sort keys %$result ], [qw(fetchedAt items)], 'success is { items, fetchedAt }' );
	is( $result->{fetchedAt}, $T0, 'fetchedAt: when ABC answered' );
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
		[qw(900098 900101 900103 900104 900105 900107 900109 900110 1000000001)],
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
	ok( !exists $by{900110}->{$_}, "only the download window opens later: listed, no $_" ) for qw(renditions availableTo downloadAvailableTo seenAt);
	ok( !exists $by{900107}->{programId}, 'no programID in the hit: none in the ref (the feed takes the book id)' );

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
	is_deeply( result_of( chapters($BOOK_ID) ), { items => [], fetchedAt => $T0 }, 'no hits: { items => [] }' );

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
		[ '1. Prologue', '2. Chapter One', '3. Chapter Three', '4. Chapter Four', '5. Chapter Five', '6. Chapter Seven', '7. Chapter Nine', '8. Chapter Ten', '9. Epilogue & Notes' ],
		'O2\'s episodeItem rows, renamed "<n>. <title>"'
	);
	is_deeply(
		[ map { $_->{play} } @$items ],
		[ map {"abclisten://episode/$_"} qw(900098 900101 900103 900104 900105 900107 900109 900110 1000000001) ],
		'play URLs (abclisten://episode/<id>) in reading order: what Play all / Add all queue'
	);
	is( scalar( grep { $_->{type} eq 'link' && $_->{url} == \&Plugins::ABCListen::OnDemand::_episodeMenu } @$items ), 9, 'rows open O2\'s episode page' );
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
		route( "$NEXT$BOOK_PATH.json", file => 'ondemand/nextdata-program-audiobook.trimmed.json', headers => $JSON_TYPE );
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

# ---- review (PR #58): restricted podcasts, fetch-time seenAt, newer meta, counts, once-guard ----

subtest 'episodes(): newest first (date, then id); the same query and cache entry as chapters()' => sub {
	fresh();
	serve_book();

	my $c = collector();
	$AB->episodes( $BLUEY_ID, $c->cb );
	is( $c->count, 1, 'one callback' );
	my $result = result_of($c);
	is_deeply(
		ids_of( $result->{items} ),
		[qw(106452636 106452606 106452594 104717854 104717822 104718158 104717696 104692944)],
		'newest first: same-day episodes by id, then by date (The Dump, 104718158, is older than Piggyback, 104717854)'
	);
	is( $result->{items}->[0]->{title}, 'Army', 'newest: Army' );
	is( $result->{items}->[-1]->{title}, "Wackadoo! It's Bluey Listen Along", 'oldest last' );
	is( $result->{fetchedAt}, $T0, 'fetchedAt' );
	is_deeply( [ bodies() ], [ { query => '', hitsPerPage => 1000, filters => "contentType:audioepisode AND programID=$BLUEY_ID", attributesToRetrieve => \@ATTRIBUTES } ], 'the same Algolia query as for chapters' );
	ok( ( grep { $_->{message} =~ /104672698: ABC's search index has 41 episodes, listing the 8 it returned/ } warnings_logged() ), 'nbHits 41 > 8 hits: WARN' );

	my $chapters = result_of( chapters($BLUEY_ID) );
	is( scalar algolia_requests(), 1, 'chapters() of the same program: the same cache entry, no second request' );
	is_deeply( ids_of( $chapters->{items} ), [ sort { $a <=> $b } @{ ids_of( $result->{items} ) } ], '... in ascending id order' );

	fresh();
	serve( 7 => { content => '{"hits":[{"objectID":"coremedia://audioepisode/71","title":"Undated"},{"objectID":"coremedia://audioepisode/70","title":"Dated","dates":{"publicationDate":"2026-01-01T00:00:00Z"}}],"nbHits":2}' } );
	$c = collector();
	$AB->episodes( 7, $c->cb );
	is_deeply( ids_of( result_of($c)->{items} ), [qw(70 71)], 'an undated episode goes last' );
};

subtest 'Episodes link and feed (Bluey Listen Along): episodeItem rows, newest first, not numbered; seeding; geo' => sub {
	fresh();
	serve_book();

	my $call = sub {
		my @calls;
		$EXTRAS->( undef, shift, sub { push @calls, [@_] } );
		is( scalar @calls, 1, 'provider: one callback' );
		return $calls[0]->[0];
	};
	my $image = 'https://live-production.wcms.abc-cdn.net.au/bluey.jpg';
	my $input = { title => 'Bluey Listen Along', path => $BLUEY, id => $BLUEY_ID, image => $image, template => 'audio', restricted => 1 };

	is_deeply(
		$call->($input),
		[ { name => 'Episodes', type => 'link', url => $EPISODES, passthrough => [ { id => $BLUEY_ID, title => 'Bluey Listen Along', image => $image } ] } ],
		'a restricted podcast: one Episodes link (type link, no description), not Chapters'
	);
	is( scalar requests(), 0, '... and no request' );

	my $c     = feed( $EPISODES, undef, { id => $BLUEY_ID, title => 'Bluey Listen Along', image => $image } );
	my $items = items_of($c);
	is( $c->count, 1, 'feed: one callback' );
	my $date = sub { Plugins::ABCListen::Util::friendlyDate( Plugins::ABCListen::Util::parseISO8601(shift) ) . " \x{2013} " . shift };
	is_deeply(
		[ @{ names($items) }[ 0, 3, 5, 7 ] ],
		[ $date->( '2026-03-30T00:00:00+00:00', 'Army' ), $date->( '2024-12-12T13:33:00+00:00', 'Piggyback' ), $date->( '2024-12-12T13:31:00+00:00', 'The Dump' ), $date->( '2024-12-07T20:00:00+00:00', "Wackadoo! It's Bluey Listen Along" ) ],
		'rows named by episodeItem: "<date> – <title>", newest first'
	);
	is( scalar( grep { $_->{name} =~ /\A[0-9]+\. / } @$items ), 0, 'not numbered' );
	is_deeply(
		[ map { $_->{play} } @$items ],
		[ map {"abclisten://episode/$_"} qw(106452636 106452606 106452594 104717854 104717822 104718158 104717696 104692944) ],
		'play URLs newest first'
	);
	is( scalar( grep { $_->{url} == \&Plugins::ABCListen::OnDemand::_episodeMenu } @$items ), 8, 'rows open O2\'s episode page' );
	readable( $items, 'episode rows' );

	my $meta = Plugins::ABCListen::Util::getEpisodeMeta('106452636');
	is( $meta->{seenAt}, $T0, 'meta cache seeded (seenAt = fetch time)' );
	is( $meta->{programTitle}, 'Bluey Listen Along', 'meta cache: programTitle' );

	Slim::Networking::SimpleAsyncHTTP->reset;
	my $o1 = collector();
	Plugins::ABCListen::Episode->resolve( '106452636', $o1->cb );
	my ($answer) = $o1->args(0);
	like( $answer->{url}, qr{/geo-001/}, 'O1 plays the newest episode from the seeded renditions' );
	is( $answer->{failToken}, 'PLUGIN_ABCLISTEN_EPISODE_GEO', '... with the geo message if it fails' );
	is( scalar requests(), 0, '... without a request' );

	is( $call->($input)->[0]->{name}, 'Episodes (8)', 'once listed: "Episodes (N)"' );
};

subtest 'The Bomb (no hits): No episodes available, in the list and then in the program menu' => sub {
	fresh();
	serve_book( 1 => { file => 'discovery/algolia-search-empty.synthetic.json' } );
	my $input = { title => 'The Bomb', path => $BOMB, id => $BOMB_ID, template => 'audio', restricted => 1 };
	my $call  = sub { my @rows; $EXTRAS->( undef, shift, sub { @rows = @{ $_[0] } } ); return \@rows };

	is( $call->($input)->[0]->{name}, 'Episodes', 'first: the Episodes link (nothing known yet)' );
	my $c = feed( $EPISODES, undef, { id => $BOMB_ID, title => 'The Bomb' } );
	is_deeply( [ $c->count, items_of($c) ], [ 1, [ text_item($NO_EPISODES) ] ], 'opened: No episodes available' );
	is_deeply( $call->($input), [ text_item($NO_EPISODES) ], 'known to be empty: the provider shows No episodes available itself' );

	# the same for a book known to have no chapters
	chapters(1);
	is_deeply( $call->( { template => 'audiobook', restricted => 1, id => '1' } ), [ text_item($NO_EPISODES) ], 'a book known to have no chapters: No episodes available' );
};

subtest 'program menus: Bluey Listen Along gets Episodes before Follow; The Bomb says No episodes available' => sub {
	my $setup = sub {
		fresh();
		%{ preferences('plugin.abclisten') } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
		Plugins::ABCListen::Discover->init;
		Plugins::ABCListen::MyABC->init;
		route( "$NEXT$BLUEY.json", file => 'discovery/nextdata-program-bluey-listen-along.trimmed.json', headers => $JSON_TYPE );
		route( "$NEXT$BOMB.json",  file => 'discovery/nextdata-program-the-bomb.trimmed.json',          headers => $JSON_TYPE );
		serve_book();
	};

	$setup->();
	my $menu  = items_of( feed( $PROGRAM, undef, { title => 'Bluey Listen Along', path => $BLUEY } ) );
	my @names = @{ names($menu) };
	ok( !( grep {/\AChapters/} @names ), 'no Chapters item (not a book)' );
	ok( !( grep { $_ eq $NO_EPISODES } @names ), 'no "No episodes available"' );
	my ($ei) = grep { $names[$_] eq 'Episodes' } 0 .. $#names;
	my ($fi) = grep { $names[$_] =~ /\AFollow/ } 0 .. $#names;
	ok( defined $ei && defined $fi && $ei < $fi, 'an Episodes item, before M2\'s Follow' ) or diag explain \@names;
	is( $menu->[$ei]->{passthrough}->[0]->{id}, $BLUEY_ID, '... for the program id from the page' );
	is( scalar algolia_requests(), 0, 'opening the menu sends no Algolia query' );
	is( scalar @{ items_of( feed( $menu->[$ei]->{url}, undef, @{ $menu->[$ei]->{passthrough} } ) ) }, 8, 'Episodes lists the episodes' );
	$menu = items_of( feed( $PROGRAM, undef, { title => 'Bluey Listen Along', path => $BLUEY } ) );
	is( scalar( grep { $_->{name} eq 'Episodes (8)' } @$menu ), 1, 'reopened: "Episodes (8)"' );

	$setup->();
	$menu = items_of( feed( $PROGRAM, undef, { title => 'The Bomb', path => $BOMB } ) );
	my ($bomb) = grep { $_->{name} eq 'Episodes' } @$menu;
	ok( $bomb, 'The Bomb: Episodes first' );
	feed( $bomb->{url}, undef, @{ $bomb->{passthrough} } );
	$menu = items_of( feed( $PROGRAM, undef, { title => 'The Bomb', path => $BOMB } ) );
	is( scalar( grep { $_->{name} eq $NO_EPISODES } @$menu ), 1, 'once known to be empty: "No episodes available" in its place' );
	is( scalar( grep { $_->{name} =~ /\AEpisodes/ } @$menu ), 0, '... and no Episodes item' );
};

subtest 'seenAt is the fetch time (API.pm info at); none once the answer is 6 h old' => sub {
	fresh();
	serve_book();

	my $r = result_of( chapters($BOOK_ID) );
	is( $r->{items}->[0]->{seenAt}, $T0, 'network answer: seenAt = fetch time' );

	setTime( $T0 + 2 * $HOUR );
	$r = result_of( chapters($BOOK_ID) );
	is( scalar algolia_requests(), 1, '2 h later: from the cache' );
	is( $r->{fetchedAt}, $T0, '... fetchedAt is still the fetch time' );
	is( $r->{items}->[0]->{seenAt}, $T0, '... and so is seenAt (not now: O1 trusts it until 6 h after the fetch)' );

	setTime( $T0 + 6 * $HOUR - 1 );
	is( result_of( chapters($BOOK_ID) )->{items}->[0]->{seenAt}, $T0, 'just under 6 h after the fetch: seenAt' );

	setTime( $T0 + 6 * $HOUR );
	my $item = result_of( chapters($BOOK_ID) )->{items}->[0];
	ok( !exists $item->{seenAt}, '6 h after the fetch: no seenAt' );
	ok( $item->{renditions} && $item->{availableTo}, '... renditions and windows still listed' );

	# the feed seeds an answer that old without seenAt: O1 asks ABC before playing
	fresh();
	serve_book();
	chapters($BOOK_ID);    # fetched at T0; the meta cache is still empty
	setTime( $T0 + 7 * $HOUR );
	feed( $CHAPTERS, undef, {%BOOK} );
	my $meta = Plugins::ABCListen::Util::getEpisodeMeta('106353760');
	ok( $meta->{renditions} && !exists $meta->{seenAt}, '7 h old answer: renditions seeded, no seenAt' );
	is( scalar algolia_requests(), 1, '(still one query)' );

	# a last-good copy never vouches for its renditions, however young (API.pm decides when it serves one)
	fresh();
	{
		no warnings 'redefine';
		my $data = JSON::PP::decode_json( fixture('discovery/algolia-audiobook-chapters.trimmed.json') );
		local *Plugins::ABCListen::API::algolia = sub { $_[1]->( $data, { stale => 1, at => time() - 60 } ) };
		my $r = result_of( chapters($BOOK_ID) );
		ok( $r->{items}->[0]->{renditions} && !exists $r->{items}->[0]->{seenAt}, 'a stale copy fetched a minute ago: renditions, no seenAt' );
		is( $r->{fetchedAt}, $T0 - 60, '... fetchedAt is its fetch time' );
	}
	is( Plugins::ABCListen::Audiobooks::_cachedCount($BOOK_ID), undef, '... and no count is remembered from it' );
};

subtest 'an older answer never overwrites newer audio data in the meta cache' => sub {
	my $id    = '106353760';
	my $newer = [ { url => "$GEO/02/zz/Z/new.mp3", mime => 'audio/mpeg', bitrate => 128 } ];
	my $meta  = sub { my $m = Plugins::ABCListen::Util::getEpisodeMeta($id) || {}; return { map { $_ => $m->{$_} } grep { exists $m->{$_} } qw(renditions availableTo downloadAvailableTo seenAt) } };

	# O1 re-resolved the chapter after the answer was fetched
	fresh();
	serve_book();
	chapters($BOOK_ID);    # fetched at T0
	setTime( $T0 + $HOUR );
	Plugins::ABCListen::Util::setEpisodeMeta( $id, { renditions => $newer, availableTo => epoch( 2027, 5, 1 ), downloadAvailableTo => epoch( 2027, 5, 1 ), seenAt => $T0 + $HOUR } );
	setTime( $T0 + 2 * $HOUR );
	feed( $CHAPTERS, undef, {%BOOK} );
	is_deeply( $meta->(), { renditions => $newer, availableTo => epoch( 2027, 5, 1 ), downloadAvailableTo => epoch( 2027, 5, 1 ), seenAt => $T0 + $HOUR }, 'O1\'s newer renditions, windows and seenAt are kept' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('106442258')->{seenAt}, $T0, 'a chapter without newer data is seeded (seenAt = fetch time)' );

	# O1 closed the windows (restricted / not yet released) after the fetch, without seenAt
	fresh();
	serve_book();
	chapters($BOOK_ID);
	Plugins::ABCListen::Util::setEpisodeMeta( $id, { availableTo => $T0 + $HOUR, downloadAvailableTo => $T0 + $HOUR } );
	setTime( $T0 + 2 * $HOUR );
	feed( $CHAPTERS, undef, {%BOOK} );
	is_deeply( $meta->(), { availableTo => $T0 + $HOUR, downloadAvailableTo => $T0 + $HOUR }, 'windows O1 closed after the fetch stay closed (no renditions written)' );

	# ... but a closure before the fetch is replaced by the newer answer
	fresh();
	serve_book();
	Plugins::ABCListen::Util::setEpisodeMeta( $id, { availableTo => $T0 - $HOUR, downloadAvailableTo => $T0 - $HOUR } );
	feed( $CHAPTERS, undef, {%BOOK} );
	is( $meta->()->{downloadAvailableTo}, epoch( 2027, 4, 1, 13 ), 'a closure older than the answer: the answer\'s windows are written' );
	is( $meta->()->{seenAt}, $T0, '... with seenAt' );

	# a stale (last good) copy never overwrites what O1 found later
	fresh();
	serve_book();
	feed( $CHAPTERS, undef, {%BOOK} );    # seeded at T0
	setTime( $T0 + $DAY + $HOUR );
	Plugins::ABCListen::Util::setEpisodeMeta( $id, { renditions => $newer, seenAt => $T0 + $DAY + $HOUR } );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( $ALGOLIA, code => 503, content => 'down' );
	my $items = items_of( feed( $CHAPTERS, undef, {%BOOK} ) );
	is( scalar @$items, 4, 'ABC down after 24 h: the last good list' );
	is_deeply( [ @{ $meta->() }{qw(renditions seenAt)} ], [ $newer, $T0 + $DAY + $HOUR ], '... which does not overwrite O1\'s newer renditions' );
};

subtest 'counts: per program; follow a new answer; expire 24 h after the fetch' => sub {
	fresh();
	serve_book();
	my $name = sub { my @rows; $EXTRAS->( undef, shift, sub { @rows = @{ $_[0] } } ); return $rows[0] ? $rows[0]->{name} : undef };
	my $book = { %BOOK,                                template => 'audiobook', restricted => 1 };
	my $edge = { id => $EDGE_ID, title => 'Edge Book', template => 'audiobook', restricted => 1 };

	chapters($BOOK_ID);
	chapters($EDGE_ID);
	is_deeply( [ $name->($book), $name->($edge) ], [ 'Chapters (4)', 'Chapters (9)' ], 'two books, each its own count' );

	# the next day ABC lists 9 for the first book
	setTime( $T0 + $DAY + 1 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	serve( $BOOK_ID => { file => 'discovery/algolia-audiobook-chapters-edge.synthetic.json' } );
	is( $name->($book), 'Chapters', 'after 24 h: the count expired with the query' );
	chapters($BOOK_ID);
	is( $name->($book), 'Chapters (9)', 'a new answer with another count: the new count' );

	# the query's cache entry is evicted early (cache purge): the next answer replaces a count still valid
	setTime( $T0 + $DAY + 2 * $HOUR );
	my $queryKey = 'api:algolia:' . JSON::PP->new->canonical(1)->utf8(1)->encode( Plugins::ABCListen::Audiobooks::_query($BOOK_ID) );
	ok( Slim::Utils::Cache->new('abclisten')->get($queryKey), '(the query is cached under its canonical params)' );
	Slim::Utils::Cache->new('abclisten')->remove($queryKey);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	serve_book();
	chapters($BOOK_ID);
	is( scalar algolia_requests(), 1, 'evicted: one new request' );
	is( $name->($book), 'Chapters (4)', '... and the count follows the new answer at once' );

	# a count written from a cached answer still expires 24 h after that answer was fetched
	fresh();
	serve_book();
	chapters($BOOK_ID);    # fetched at T0
	Slim::Utils::Cache->new('abclisten')->remove("audiobooks:count:$BOOK_ID");
	setTime( $T0 + 23 * $HOUR );
	chapters($BOOK_ID);    # the cached answer
	is( $name->($book), 'Chapters (4)', '23 h later, from the cached answer: Chapters (4)' );
	setTime( $T0 + $DAY );
	is( $name->($book), 'Chapters', '24 h after the fetch: Chapters' );
};

subtest 'chapters(): an API that calls back twice (and errors) still answers once' => sub {
	fresh();
	my @answers;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::algolia = sub {
			my ( $params, $cb, $ecb ) = @_;
			$cb->( { hits => [] }, { stale => 0, at => time() } );
			$cb->( { hits => [ { objectID => 'coremedia://audioepisode/1' } ] }, { stale => 0, at => time() } );
			$ecb->( { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } );
		};
		$AB->chapters( $BOOK_ID, sub { push @answers, shift } );
		$AB->episodes( $BOOK_ID, sub { push @answers, shift } );
	}
	is_deeply( \@answers, [ { items => [], fetchedAt => $T0 }, { items => [], fetchedAt => $T0 } ], 'one answer each: the first' );
};

subtest 'Chapters feed: the book fills in programId when a hit has none' => sub {
	fresh();
	serve_book();
	my $calls = with_recording_episodeItem( sub { feed( $CHAPTERS, undef, { id => $EDGE_ID, title => 'Edge Book' } ) } );
	my ($seven) = grep { $_->{id} eq '900107' } @$calls;
	is( $seven->{programId}, $EDGE_ID, 'Chapter Seven (no programID in the hit): the book id' );
	my ($one) = grep { $_->{id} eq '900101' } @$calls;
	is( $one->{programId}, '900100', 'Chapter One: its own programID' );
};

subtest 'strings' => sub {
	is( string('PLUGIN_ABCLISTEN_CHAPTERS'), 'Chapters', 'PLUGIN_ABCLISTEN_CHAPTERS' );
	is( string( 'PLUGIN_ABCLISTEN_CHAPTERS_N', 30 ), 'Chapters (30)', 'PLUGIN_ABCLISTEN_CHAPTERS_N' );
	is( string('PLUGIN_ABCLISTEN_EPISODES'), 'Episodes', 'PLUGIN_ABCLISTEN_EPISODES (O2\'s, reused)' );
	is( string( 'PLUGIN_ABCLISTEN_EPISODES_N', 41 ), 'Episodes (41)', 'PLUGIN_ABCLISTEN_EPISODES_N' );
};

done_testing();
