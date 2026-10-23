#!/usr/bin/perl
# O4 episode extras, offline (SimpleAsyncHTTP stub, fake clock, server time zone Australia/Sydney).
#
# Data part (Plugins::ABCListen::Tracklist and the derivations the menus use):
#   parse() on the Classic Drive document (3 rows: artist, title, time; pagination.total 31 > 3
#   logged at DEBUG) and on the edge cases (tracklistPrepared null / [] / missing; a page without
#   an episode document, as an audiobook chapter's book page; missing timestamps, entities, missing
#   or non-text titles, a bogus time); formatRow(); fetch(): the request path, ttl and timeout equal
#   O1's resolver's (one shared F3 cache entry, in either order), cached() before and after, the
#   1 h TTL on the fake clock, errors (404 after the buildId refresh, transport error, bad JSON, the
#   8 s deadline via a deferred response, an API call that dies) answered exactly once with WARN
#   once per episode (again after a success), a failure cached for 90 s (no API call, no wait) and
#   removed by a late success, no path, a dying callback, coalesced concurrent fetches, no timer
#   left, the parsed rows answering without any API call; formatRow decoding nothing twice; the
#   program-path table (Follow's programPathFor, which O4 calls); presenters de-duplication and
#   joining.
# Menu part (OnDemand::_episodeMenu and its O4 rows; Episode.pm's song info):
#   the Science Show episode submenu reached through the program menu, exact rows and order; each
#   extra present or absent; Segments -> rows (exact keys, names "1 of 5 – …", meta-cache writes,
#   fallbacks, invalid segments, no recursion, a stale id); the lazy tracklist fetch on opening
#   (present, empty, error, 8 s timeout, a fetch or API call that dies) answering once, a failure
#   as the "Tracklist unavailable" row so the rows keep their indexes (a stale "More from" index
#   after a late document); a second open makes no request; "More
#   from" present/absent per the rules (own program, Lab Notes before and after O1's resolve, a
#   caller's programPath, no path) and opening it shows O2's program menu; the song-info provider
#   (registered by Episode->init after 'top', before M2's Follow rows; full, partial, absent and
#   corrupt cache; inline vs lazy Tracklist and the lazy link's feed; undef for live and foreign
#   URLs; no HTTP; exceptions contained); readable names everywhere (no raw token, no empty row).
#
# Fixtures: t/data/ondemand/ - nextdata-episode-classic-drive-aac.trimmed.json (tracklist, 3 of
# 31 items), nextdata-episode-scienceshow-mp3.trimmed.json (tracklistPrepared null),
# nextdata-program-scienceshow.trimmed.json (episode 107266790 with 2 segments labelled "1 of 5",
# "2 of 5", no docType; a Lab Notes episode), nextdata-program-audiobook.trimmed.json (a book page:
# no episode document), nextdata-episode-nonascii-107267360.trimmed.json (F4 lower-cased path);
# synthetic: nextdata-episode-tracklist-{edge,null,empty}.synthetic.json,
# bff-episodesWithSegments-segments.synthetic.json (segments with missing fields, no parseable id,
# an empty label; duplicate presenters). The F3 search page gives buildId build-3afcd04f.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Menu::TrackInfo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::Follow;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Tracklist;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $OD   = 'Plugins::ABCListen::OnDemand';
my $TL   = 'Plugins::ABCListen::Tracklist';
my $SITE = 'https://www.abc.net.au';
my $BFF  = "$SITE/core-next/api";
my $EPS  = "$BFF/episodesWithSegments/x";
my $NEXT = "$SITE/_next/data/build-3afcd04f";
my $T0   = 1_792_400_000;    # Mon 19 Oct 2026, 19:53 in Sydney
my $ICON = Plugins::ABCListen::Util::ICON;
my $WCMS = 'https://live-production.wcms.abc-cdn.net.au';
my $JSON = { 'Content-Type' => 'application/json' };

my $SCIENCE      = '/listen/programs/scienceshow';
my $TREES_ID     = '107266790';
my $TREES_PATH   = "$SCIENCE/trees-potatoes-brendan-may-step/107266790";
my $LABNOTES_ID  = '107232984';
my $LABNOTES     = '/listen/programs/lab-notes';
my $DRIVE_ID     = '107174638';
my $DRIVE_PATH   = '/listen/programs/classic-drive/classic-drive/107174638';
my $DRIVE_URL    = "$NEXT$DRIVE_PATH.json";
my $TREES_URL    = "$NEXT$TREES_PATH.json";
my $EDGE_PATH    = '/listen/programs/edgecases/tracklist-edge-cases/90000101';
my $SEGMENT1     = '107277426';
my $SEGMENT1_IMG = "$WCMS/94a92a15e5ff2b781070e1ba2c874596?impolicy=wcms_crop_resize&cropH=683&cropW=683&xPos=171&yPos=0&width=300&height=300";

my $SCIENCE_IMG     = "$WCMS/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862";
my $SCIENCE_IMG_300 = "$WCMS/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300";

my $LOAD_FAILED  = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $NO_TRACKLIST = string('PLUGIN_ABCLISTEN_NO_TRACKLIST');
my $NO_EPISODES  = string('PLUGIN_ABCLISTEN_NO_EPISODES');
my $UNAVAILABLE  = string('PLUGIN_ABCLISTEN_TRACKLIST_UNAVAILABLE');

my $EPISODE_MENU  = \&Plugins::ABCListen::OnDemand::_episodeMenu;
my $PROGRAM_MENU  = \&Plugins::ABCListen::OnDemand::_programMenu;
my $SEGMENTS_MENU = \&Plugins::ABCListen::OnDemand::_segmentsMenu;
my $SONG_FEED     = \&Plugins::ABCListen::Episode::_trackInfoTracklistFeed;

my $ROSSINI = "00:55 \x{B7} Rossini, Gioachino \x{2013} The Barber of Seville: Overture";
my @DRIVE_ROWS = (
	$ROSSINI,
	"09:42 \x{B7} Schumann, Clara \x{2013} Sonata in G minor: III. Scherzo & Trio",
	"13:18 \x{B7} Wieniawski, Henryk \x{2013} Fantasia on Themes from Gounod's Faust, Op. 20: V. Tempo di valse. Allegro non troppo",
);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' } );

# ---- API spy: every nextData call with its path and options ----

my @NEXT_CALLS;
{
	no warnings 'redefine';
	my $nextData = \&Plugins::ABCListen::API::nextData;
	*Plugins::ABCListen::API::nextData = sub { push @NEXT_CALLS, { path => $_[0], opts => { %{ $_[3] || {} } } }; goto &$nextData };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::OnDemand::_resetProviders();
	Plugins::ABCListen::Tracklist::_reset();
	@NEXT_CALLS = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture("ondemand/$_[0]") ) }

sub doc_requests { grep {m{/_next/data/}} map { $_->{url} } requests() }

sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item {
	my ( $item, $client ) = @_;
	return feed( $item->{url}, $client, @{ $item->{passthrough} || [] } );
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] || [] } ] }

sub text_item { { name => $_[0], type => 'text' } }

sub find_named {
	my ( $items, $re ) = @_;
	my ($item) = grep { defined $_->{name} && $_->{name} =~ $re } @{ $items || [] };
	return $item;
}

# Every item (and inline sub-item) has a readable, non-empty name and no raw string token.
sub check_names {
	my ( $items, $label ) = @_;
	my @all = map { ( $_, @{ ref $_->{items} eq 'ARRAY' ? $_->{items} : [] } ) } @$items;
	my $bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @all;
	is( $bad, 0, "$label: every item has a readable, non-empty name" );
	ok( !( grep { exists $_->{description} && $_->{type} ne 'audio' } @all ), "$label: no browse item has a description" );
}

sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub errors_logged   { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub debug_logged    { grep { $_->{level} eq 'DEBUG' && $_->{message} =~ $_[0] } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

sub route_doc {
	my ( $path, $file, %extra ) = @_;
	route( "$NEXT$path.json", file => "ondemand/$file", headers => $JSON, %extra );
}

# The Science Show: the program page, and its episode collection (2885458) holding the page's own
# first episodes (107266790 with 2 segments, then the Lab Notes episode).
sub route_science {
	route_doc( $SCIENCE, 'nextdata-program-scienceshow.trimmed.json' );
	my $items = json_file('nextdata-program-scienceshow.trimmed.json')->{pageProps}->{programCollectionPrepared}->{items};
	route( qr{\Q$EPS\E\?collectionId=2885458&}, content => to_json( { collection => { id => '2885458', items => $items, pagination => { offset => 0, size => 50, total => scalar @$items } } } ), headers => $JSON );
}

# The Science Show program menu (needs route_science) -> its episode rows by id.
sub science_rows {
	my $c = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } );
	my %rows = map { ( $_->{play} =~ m{/([0-9]+)\z} ? ( $1 => $_ ) : () ) } grep { $_->{play} } @{ items_of($c) || [] };
	return \%rows;
}

sub fetch_tl {
	my ($episode) = @_;
	my $c = collector();
	$TL->fetch( $episode, $c->cb );
	return $c;
}

sub provider { $Slim::Menu::TrackInfo::PROVIDERS{ $_[0] || 'abclistenepisode' } }

sub song_info {
	my ( $client, $url ) = @_;
	return provider()->{func}->( $client, $url, undef, {}, {} );
}

# ===========================================================================
# Data: Tracklist
# ===========================================================================

subtest 'parse: the Classic Drive document -> 3 rows (artist, title, time); total 31 > 3 at DEBUG' => sub {
	fresh();
	my $rows = $TL->parse( json_file('nextdata-episode-classic-drive-aac.trimmed.json')->{pageProps} );
	is_deeply(
		$rows,
		[
			{ title => 'The Barber of Seville: Overture', artist => 'Rossini, Gioachino', time => '00:55' },
			{ title => 'Sonata in G minor: III. Scherzo & Trio', artist => 'Schumann, Clara', time => '09:42' },
			{ title => "Fantasia on Themes from Gounod's Faust, Op. 20: V. Tempo di valse. Allegro non troppo", artist => 'Wieniawski, Henryk', time => '13:18' },
		],
		'3 rows in ABC\'s order: { title, artist (the composer), time = timestampRelative }'
	);
	is_deeply( [ map { $TL->formatRow($_) } @$rows ], \@DRIVE_ROWS, 'formatRow: "<time> · <artist> – <title>"' );
	is( $TL->formatRow( $rows->[0] ), $ROSSINI, 'e.g. 00:55 · Rossini, Gioachino – The Barber of Seville: Overture' );
	ok( scalar debug_logged(qr/ABC lists 31 items but sent 3/), 'pagination.total 31 > 3 items: logged at DEBUG' );
	is( scalar warnings_logged(), 0, '... and nothing at WARN' );
};

subtest 'parse: edge cases (null, [], missing, no document, timestamps, entities, titles)' => sub {
	fresh();
	my $edge = $TL->parse( json_file('nextdata-episode-tracklist-edge.synthetic.json')->{pageProps} );
	is_deeply(
		$edge,
		[
			{ title => "Air on the G String \x{2013} arr. for strings", artist => 'Bach, Johann Sebastian & sons', time => '00:12' },
			{ title => 'No timestamp', artist => 'The Whitespace Band' },
			{ title => 'No artist', time => '1:02:38' },
			{ title => 'A bogus timestamp', artist => 'Clock Skew' },
			{ title => 'No Time to Die', artist => "O'Connell, Finneas & O'Connell, Billie Eilish", time => '41:45' },
			{ title => 'Only separators', time => '42:00' },
			{ title => "Caf\x{E9} con le\x{F1}a", artist => "Ni\x{F1}o & Co Ltd", time => '59:59' },
		],
		'entities decoded, whitespace collapsed, ABC\'s " | " between artists -> " & "; no timestampRelative (or a bogus one): no time; no artist: no key; empty, missing or non-text titles and non-hash items skipped'
	);
	is_deeply(
		[ map { $TL->formatRow($_) } @$edge ],
		[
			"00:12 \x{B7} Bach, Johann Sebastian & sons \x{2013} Air on the G String \x{2013} arr. for strings",
			"The Whitespace Band \x{2013} No timestamp",
			"1:02:38 \x{B7} No artist",
			"Clock Skew \x{2013} A bogus timestamp",
			"41:45 \x{B7} O'Connell, Finneas & O'Connell, Billie Eilish \x{2013} No Time to Die",
			"42:00 \x{B7} Only separators",
			"59:59 \x{B7} Ni\x{F1}o & Co Ltd \x{2013} Caf\x{E9} con le\x{F1}a",
		],
		'formatRow: without a time "<artist> – <title>"; without an artist "<time> · <title>"'
	);

	is_deeply( $TL->parse( json_file('nextdata-episode-tracklist-null.synthetic.json')->{pageProps} ),  [], 'tracklistPrepared null: []' );
	is_deeply( $TL->parse( json_file('nextdata-episode-tracklist-empty.synthetic.json')->{pageProps} ), [], 'items []: []' );
	is_deeply( $TL->parse( json_file('nextdata-episode-scienceshow-mp3.trimmed.json')->{pageProps} ),  [], 'a talk episode (The Science Show): []' );
	is_deeply( $TL->parse( json_file('nextdata-program-audiobook.trimmed.json')->{pageProps} ),         [], 'a page without an episode document (a book page): []' );
	is_deeply( $TL->parse( { data => { documentProps => { id => 1 } } } ),                               [], 'tracklistPrepared missing: []' );
	is_deeply( $TL->parse( { data => { documentProps => { tracklistPrepared => { items => 'x' } } } } ), [], 'items not a list: []' );
	is_deeply( $TL->parse(undef),  [], 'undef: []' );
	is_deeply( $TL->parse('junk'), [], 'not a hash: []' );

	is( $TL->formatRow( { artist => 'Nobody' } ), undef, 'formatRow: no title -> undef' );
	is( $TL->formatRow( { title => '  ' } ),      undef, 'formatRow: blank title -> undef' );
	is( $TL->formatRow('junk'),                   undef, 'formatRow: not a hash -> undef' );
	is( $TL->formatRow( { title => 'Only' } ),    'Only', 'formatRow: the title alone' );
	is( Plugins::ABCListen::Tracklist::formatRow( { title => 'Plain', time => '01:00' } ), "01:00 \x{B7} Plain", 'formatRow also as a plain function' );
	is( $TL->formatRow( { title => 'R&amp;B', artist => ' Tom  &lt;3 ' } ), "Tom &lt;3 \x{2013} R&amp;B", 'formatRow never decodes a second time (parse decoded once; a literal "&amp;" stays)' );
	is( $TL->formatRow( $TL->parse( { data => { documentProps => { tracklistPrepared => { items => [ { title => 'R&amp;amp;B' } ] } } } } )->[0] ), 'R&amp;B', 'parse + formatRow: one decoding in all' );
};

subtest 'fetch: O1\'s path and TTL (shared F3 cache), cached() before/after, 1 h TTL, no second request' => sub {
	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );

	is( $TL->cached($DRIVE_ID), undef, 'cached() before any fetch: undef' );

	my $c = fetch_tl( { id => $DRIVE_ID, path => "$SITE$DRIVE_PATH/" } );
	is( $c->count, 1, 'one callback' );
	my ($result) = $c->args(0);
	is( scalar @{ $result->{items} }, 3, '{ items => 3 rows }' );
	is_deeply( [ doc_requests() ], [$DRIVE_URL], 'one request: the episode document at its canonical path' );
	is_deeply( $NEXT_CALLS[0], { path => $DRIVE_PATH, opts => { ttl => 3600, timeout => 8, quiet => 1 } }, 'API::nextData(path, ..., { ttl => 3600, timeout => 8, quiet => 1 })' );
	is( $NEXT_CALLS[0]->{opts}->{ttl}, Plugins::ABCListen::Episode::DOCUMENT_TTL, 'ttl = Episode.pm DOCUMENT_TTL (O1\'s resolver)' );
	my ($request) = grep { $_->{url} eq $DRIVE_URL } requests();
	is( $request->{params}->{timeout}, 8, 'the request times out after 8 s' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'answered: the 8 s deadline timer is cancelled' );

	is_deeply( $TL->cached($DRIVE_ID), $result->{items}, 'cached(): the parsed rows' );
	is( $TL->cached('nope'), undef, 'cached(bad id): undef' );

	my $before = () = requests();
	my $calls  = @NEXT_CALLS;
	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is( $c->count, 1, 'second fetch: answered synchronously' );
	is( scalar( () = requests() ), $before, '... with no request' );
	is( scalar @NEXT_CALLS, $calls, '... and no API call at all (the parsed rows, not F3\'s document)' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... and no timer' );

	advanceTime(3601);
	is( $TL->cached($DRIVE_ID), undef, 'after 1 h: the parsed rows have expired' );

	# O1 first, then the tracklist: one request
	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	Plugins::ABCListen::Util::setEpisodeMeta( $DRIVE_ID, { path => $DRIVE_PATH, title => 'Classic Drive' } );
	my $resolved = collector();
	Plugins::ABCListen::Episode->resolve( $DRIVE_ID, $resolved->cb );
	is( $resolved->count, 1, 'O1 resolved the episode' );
	ok( ( $resolved->args(0) )[0]->{url}, '... to a URL' );
	is( scalar doc_requests(), 1, '... with one document request' );
	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is( scalar @{ ( $c->args(0) )[0]->{items} }, 3, 'then the tracklist: 3 rows' );
	is( scalar doc_requests(), 1, '... and no second request (F3\'s cache entry is shared)' );
	is( $NEXT_CALLS[0]->{path}, $NEXT_CALLS[1]->{path}, 'the same nextData path as O1' );
	is( $NEXT_CALLS[0]->{opts}->{ttl}, $NEXT_CALLS[1]->{opts}->{ttl}, 'the same ttl as O1' );

	# the tracklist first, then O1: one request
	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	Plugins::ABCListen::Util::setEpisodeMeta( $DRIVE_ID, { path => $DRIVE_PATH, title => 'Classic Drive' } );
	fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	$resolved = collector();
	Plugins::ABCListen::Episode->resolve( $DRIVE_ID, $resolved->cb );
	ok( ( $resolved->args(0) )[0]->{url}, 'tracklist first, then O1 resolves' );
	is( scalar doc_requests(), 1, '... from the same single request' );

	# F4: a non-ASCII path is requested lower-cased, like O1's
	fresh();
	my $served = '/listen/programs/if-youre-listening/the-apocalyptic-el-ni%c3%b1o-we-didn-t-see-coming/107267360';
	route_doc( $served, 'nextdata-episode-nonascii-107267360.trimmed.json' );
	$c = fetch_tl( { id => '107267360', path => "/listen/programs/if-youre-listening/the-apocalyptic-el-ni\x{F1}o-we-didn-t-see-coming/107267360" } );
	is_deeply( ( $c->args(0) )[0], { items => [] }, 'a non-ASCII path (F4: served lower-cased): fetched; no tracklist' );
};

subtest 'fetch: failures answer once with { error }, WARN once per episode; no path; dying callback' => sub {
	fresh();
	route( $DRIVE_URL, code => 404, content => 'Not found', headers => { 'Content-Type' => 'text/html' } );
	my $c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is( $c->count, 1, '404 (after the buildId refresh): one callback' );
	is_deeply( ( $c->args(0) )[0], { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, '... { error => LOAD_FAILED }' );
	is( scalar warnings_logged(), 1, '... one WARN' );
	like( ( warnings_logged() )[0]->{message}, qr/Tracklist of episode $DRIVE_ID/, '... naming the episode' );
	is( $TL->cached($DRIVE_ID), undef, '... nothing cached' );

	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is_deeply( ( $c->args(0) )[0], { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'the same episode again (the cached failure)' );
	is( scalar warnings_logged(), 1, '... no second WARN (once per episode)' );

	fresh();
	route( $DRIVE_URL, error => 'Connect timed out' );
	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'transport error: one { error } callback' );

	fresh();
	route( $DRIVE_URL, content => '{ not json', headers => $JSON );
	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'bad JSON: one { error } callback' );
	is( scalar warnings_logged(), 1, '... one WARN' );

	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON, defer => 1 );
	$c = fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } );
	is( $c->count, 0, 'a slow ABC: no answer yet' );
	advanceTime(7.9);
	is( $c->count, 0, '... not after 7.9 s' );
	advanceTime(0.1);
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], '... after 8 s: { error }, once' );
	is( scalar warnings_logged(), 1, '... WARN once' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late document: no second callback' );
	is( scalar errors_logged(), 0, '... and no error (nothing is answered twice)' );
	is( scalar @{ $TL->cached($DRIVE_ID) }, 3, '... but its rows are cached for the next open' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timer left behind' );

	fresh();
	$c = fetch_tl( { id => $DRIVE_ID } );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'no path: { error }, once' );
	is( scalar requests(), 0, '... and nothing requested' );
	is( scalar warnings_logged(), 0, '... and no WARN' );
	$c = fetch_tl(undef);
	is( $c->count, 1, 'not a hash: one callback' );
	ok( eval { $TL->fetch( { id => 1, path => '/x' } ); 1 }, 'no callback: no crash' );

	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	my $calls = 0;
	ok( eval { $TL->fetch( { id => $DRIVE_ID, path => $DRIVE_PATH }, sub { $calls++; die "LMS exploded\n" } ); 1 }, 'a callback that dies: fetch does not die' );
	is( $calls, 1, '... called once' );
	ok( scalar( grep { $_->{message} =~ /callback died/ } errors_logged() ), '... and logged at ERROR' );
	$calls = 0;
	$TL->fetch( { id => $DRIVE_ID, path => $DRIVE_PATH }, sub { $calls++; die "again\n" } );
	is( $calls, 1, 'a dying callback on a cache hit: called once too' );
};

subtest 'fetch: a failure is cached for 90 s (no new request, no wait); WARN once; a success resets both' => sub {
	fresh();
	my $mode = 'down';
	Slim::Networking::SimpleAsyncHTTP->addRoute( $DRIVE_URL, sub {
		return $mode eq 'down' ? { error => 'Connect timed out' } : { code => 200, headers => $JSON, content => fixture('ondemand/nextdata-episode-classic-drive-aac.trimmed.json') };
	} );
	my $episode = { id => $DRIVE_ID, path => $DRIVE_PATH };

	my $c = fetch_tl($episode);
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'a transport error: { error }' );
	is( scalar @NEXT_CALLS,     1, '... one API call' );
	is( scalar doc_requests(),  1, '... one request' );
	is( scalar warnings_logged(), 1, '... WARN' );

	$c = fetch_tl($episode);
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'opened again at once: the cached failure, answered synchronously' );
	is( scalar @NEXT_CALLS,    1, '... no API call' );
	is( scalar doc_requests(), 1, '... no request' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... no deadline to wait for' );

	advanceTime(89);
	fetch_tl($episode);
	is( scalar @NEXT_CALLS, 1, 'after 89 s: still the cached failure' );

	advanceTime(2);
	$c = fetch_tl($episode);
	is( scalar @NEXT_CALLS,    2, 'after 91 s: ABC is asked again' );
	is( scalar doc_requests(), 2, '... one more request' );
	is_deeply( ( $c->args(0) )[0], { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, '... still down: { error }' );
	is( scalar warnings_logged(), 1, '... and still one WARN for the episode' );

	$mode = 'up';
	advanceTime(91);
	$c = fetch_tl($episode);
	is( scalar @{ ( $c->args(0) )[0]->{items} }, 3, 'ABC is back (after the 90 s): the rows' );

	# fail -> success -> fail: the success reset the warn-once state
	advanceTime(3601);    # the rows and F3's document expire
	$mode = 'down';
	$c = fetch_tl($episode);
	is_deeply( ( $c->args(0) )[0], { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'down again an hour later: { error }' );
	is( scalar warnings_logged(), 2, '... WARN again (fail, success, fail: two WARNs)' );

	# the deadline is a failure too; a late success removes the cached failure (an episode without an id: no rows cache)
	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON, defer => 1 );
	my $byPath = { path => $DRIVE_PATH };
	$c = fetch_tl($byPath);
	advanceTime(8);
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], 'no answer within 8 s: { error }' );
	$c = fetch_tl($byPath);
	is( $c->count, 1, 'within 90 s: answered at once from the cached failure' );
	is( scalar doc_requests(), 1, '... no new request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	$c = fetch_tl($byPath);
	is( scalar @{ ( $c->args(0) )[0]->{items} }, 3, 'the late document removed the cached failure: the rows (from F3\'s cache)' );
	is( scalar doc_requests(), 1, '... still one request' );
};

subtest 'fetch: an API call that dies is a failure: one { error } callback, fetch never dies' => sub {
	fresh();
	no warnings 'redefine';
	local *Plugins::ABCListen::API::nextData = sub { die "API exploded\n" };
	my $c = collector();
	ok( eval { $TL->fetch( { id => $DRIVE_ID, path => $DRIVE_PATH }, $c->cb ); 1 }, 'fetch does not die' ) or diag $@;
	is_deeply( [ map { $_->[0] } $c->calls ], [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ], '... one { error } callback' );
	ok( scalar( grep { $_->{message} =~ /API exploded/ } warnings_logged() ), '... logged at WARN' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... no timer left' );
};

subtest 'fetch: an audiobook chapter (its page is the book page) -> no tracklist, no WARN; concurrent opens coalesce' => sub {
	fresh();
	my $chapter = '/listen/audiobooks/the-dictionary-of-lost-words-page/chapter-1/106353760';
	route_doc( $chapter, 'nextdata-program-audiobook.trimmed.json' );
	my $c = fetch_tl( { id => '106353760', path => $chapter } );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { items => [] } ], 'no episode document: { items => [] }, once' );
	is( scalar warnings_logged(), 0, '... and no WARN' );
	is_deeply( $TL->cached('106353760'), [], '... cached as an empty list' );

	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON, defer => 1 );
	my @c = map { fetch_tl( { id => $DRIVE_ID, path => $DRIVE_PATH } ) } 1 .. 3;
	is( scalar doc_requests(), 1, 'three opens at once: one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { $_->count } @c ], [ 1, 1, 1 ], '... each answered once' );
	is_deeply( [ map { scalar @{ ( $_->args(0) )[0]->{items} } } @c ], [ 3, 3, 3 ], '... with the rows' );
};

subtest 'program path for "More from" (Follow::programPathFor, the issue\'s table)' => sub {
	my @table = (
		[ '/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790',            '/listen/programs/scienceshow' ],
		[ '/listen/programs/classic-drive/classic-drive/107174638',                            '/listen/programs/classic-drive' ],
		[ '/listen/programs/lab-notes/lab-notes-when-astronomers-make-mistakes/107232984',     '/listen/programs/lab-notes' ],
		[ '/triplej/programs/hack/hack-15-october/107400001',                                  '/triplej/programs/hack' ],
		[ '/kidslisten/programs/bedtime-stories/the-gruffalo/107500001',                       '/kidslisten/programs/bedtime-stories' ],
		[ '/listen/audiobooks/the-dictionary-of-lost-words-page/chapter-1/106353760',          '/listen/audiobooks/the-dictionary-of-lost-words-page' ],
		[ '/news/2026-10-19/a-news-story/107600001',                                            undef ],
		[ '/listen/live/triplej',                                                               undef ],
		[ '/listen/programs',                                                                   undef ],
		[ undef,                                                                                undef ],
	);
	for my $row (@table) {
		my ( $in, $want ) = @$row;
		is( Plugins::ABCListen::Follow::programPathFor($in), $want, ( defined $in ? $in : 'undef' ) . ' -> ' . ( defined $want ? $want : 'undef (no row)' ) );
	}
};

subtest 'presenters: de-duplicated (case-insensitive), joined "A", "A and B", "A, B and C"' => sub {
	my $join = sub { Plugins::ABCListen::OnDemand::_presenterList( undef, @_ ) };
	is( $join->( ['Robyn Williams'] ), 'Robyn Williams', 'one name' );
	is( $join->( [ 'Ann', 'Bob' ] ), 'Ann and Bob', 'two names' );
	is( $join->( [ 'Ann', 'Bob', 'Cat' ] ), 'Ann, Bob and Cat', 'three names' );
	is( $join->( [ 'Ann Example', 'Bob  Example', 'ann example', ' Cat Example ', 'ANN EXAMPLE' ] ), 'Ann Example, Bob Example and Cat Example', 'duplicates (any case) dropped, the first spelling kept; whitespace collapsed' );
	is( $join->( [ '', undef, ' ', ['x'], 'Solo' ] ), 'Solo', 'blanks, undef and references skipped' );
	is( $join->( [] ), undef, 'none: undef' );
	is( $join->(undef), undef, 'not a list: undef' );
	is( $join->('Robyn'), undef, 'a string, not a list: undef' );
};

# ===========================================================================
# Menu: the episode submenu
# ===========================================================================

subtest 'episode submenu (The Science Show, 107266790): exact rows and order' => sub {
	fresh();
	route_science();
	route_doc( $TREES_PATH, 'nextdata-episode-scienceshow-mp3.trimmed.json' );

	my $rows = science_rows();
	ok( $rows->{$TREES_ID}, 'the episode is listed in the program menu' );

	my $c = open_item( $rows->{$TREES_ID} );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	my $url   = "abclisten://episode/$TREES_ID";

	is_deeply(
		[ map { [ $_->{type}, $_->{name} ] } @$items ],
		[
			[ textarea => $rows->{$TREES_ID}->{passthrough}->[0]->{description} ],
			[ audio    => 'Play episode' ],
			[ text     => "Broadcast Sat 17 Oct \x{B7} 55 min" ],
			[ text     => 'Presented by Robyn Williams and Belinda Smith' ],
			[ link     => 'Segments (2)' ],
			[ text     => $NO_TRACKLIST ],
			[ link     => 'More from The Science Show' ],
		],
		'synopsis, Play episode, Broadcast (O2\'s, unchanged), Presented by, Segments (2), No tracklist, More from The Science Show'
	);

	is_deeply(
		$items->[4],
		{ name => 'Segments (2)', type => 'link', url => $SEGMENTS_MENU, passthrough => [ $rows->{$TREES_ID}->{passthrough}->[0] ] },
		'Segments (N): exact keys (a link; N = the list length, though ABC labels them "of 5"; no description)'
	);
	is_deeply(
		$items->[6],
		{
			name        => 'More from The Science Show',
			line1       => 'More from The Science Show',
			type        => 'link',
			url         => $PROGRAM_MENU,
			passthrough => [ { title => 'The Science Show', path => $SCIENCE, id => '2885500', image => $SCIENCE_IMG } ],
			image       => $SCIENCE_IMG_300,
		},
		'More from: programItem({ title, path, id, image }) with name/line1 overridden'
	);
	is_deeply( [ map { $_->{path} } @NEXT_CALLS[ -1 .. -1 ] ], [$TREES_PATH], 'the tracklist was fetched from the episode\'s own page' );
	check_names( $items, 'episode submenu' );

	# menu mode is not involved here; the same with a client
	$c = open_item( $rows->{$TREES_ID}, ABCListenTest::FakeClient->new('00:00:00:00:00:01') );
	is( scalar @{ items_of($c) }, 7, 'with a client: the same 7 rows' );
};

subtest 'episode submenu: each extra only when its data exists' => sub {
	fresh();
	my $base = { id => '90000300', title => 'Bare', date => timegm( 0, 0, 1, 17, 9, 2026 ), duration => 600 };

	my $c = feed( $EPISODE_MENU, undef, {%$base} );
	is_deeply( names( items_of($c) ), [ 'Play episode', "Broadcast Sat 17 Oct \x{B7} 10 min" ], 'no presenters, segments, path or program: O2\'s rows only' );
	is( scalar @NEXT_CALLS, 0, 'no path: no tracklist fetch' );
	is( scalar requests(), 0, '... and no request' );

	$c = feed( $EPISODE_MENU, undef, { %$base, presenters => [], segments => [] } );
	is( scalar @{ items_of($c) }, 2, 'presenters [] and segments []: no rows' );
	$c = feed( $EPISODE_MENU, undef, { %$base, presenters => undef, segments => undef } );
	is( scalar @{ items_of($c) }, 2, 'presenters and segments null: no rows' );
	$c = feed( $EPISODE_MENU, undef, { %$base, segments => [ { title => 'no id' }, 'junk', { id => 'x1' } ] } );
	is( scalar @{ items_of($c) }, 2, 'only segments without a parseable id: no Segments row' );
	$c = feed( $EPISODE_MENU, undef, { %$base, segments => [ { id => '1', title => 'one' }, { title => 'no id' }, { id => '2', title => 'two' } ] } );
	is( items_of($c)->[-1]->{name}, 'Segments (2)', 'N counts only the valid segments' );

	$c = feed( $EPISODE_MENU, undef, { %$base, presenters => [ 'Ann', 'ann' ] } );
	is( items_of($c)->[-1]->{name}, 'Presented by Ann', 'presenters de-duplicated' );

	# path, but no program title anywhere: a tracklist row, no More from
	route_doc( '/listen/programs/edgecases/tracklist-null/90000102', 'nextdata-episode-tracklist-null.synthetic.json' );
	$c = feed( $EPISODE_MENU, undef, { %$base, id => '90000102', path => '/listen/programs/edgecases/tracklist-null/90000102' } );
	is_deeply( names( items_of($c) ), [ 'Play episode', "Broadcast Sat 17 Oct \x{B7} 10 min", $NO_TRACKLIST ], 'a path but no program title: No tracklist, no More from' );
	is( items_of($c)->[-1]->{type}, 'text', 'No tracklist is a text item, not an empty submenu' );

	# a program title but a path that names no program
	$c = feed( $EPISODE_MENU, undef, { %$base, programTitle => 'ABC News', path => '/news/2026-10-19/a-story/90000301' } );
	ok( !find_named( items_of($c), qr/^More from/ ), 'an unrecognised path shape: no More from (never "More from undef")' );
	ok( !( grep { $_->{name} =~ /undef/ } @{ items_of($c) } ), '... nothing reads "undef"' );
};

subtest 'segments: rows with exact keys, names "<label> – <title>", meta-cache writes, fallbacks, no recursion' => sub {
	fresh();
	route_science();
	route_doc( $TREES_PATH, 'nextdata-episode-scienceshow-mp3.trimmed.json' );
	my $episode = science_rows()->{$TREES_ID}->{passthrough}->[0];
	@NEXT_CALLS = ();
	my $requests = () = requests();

	my $c = feed( $SEGMENTS_MENU, undef, $episode );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply(
		names($items),
		[ "1 of 5 \x{2013} Some success with palm oil. Nickel mines the next challenge", "2 of 5 \x{2013} London street trees threatened by changing climate" ],
		'2 rows in ABC\'s order, named with ABC\'s labels ("1 of 5": the text keeps ABC\'s label)'
	);
	is( scalar @NEXT_CALLS, 0, 'listing segments needs no API call' );
	is( scalar( () = requests() ), $requests, '... and no request' );

	my $row = $items->[0];
	is_deeply( [ sort keys %$row ], [ sort qw(name line1 line2 type url passthrough play image duration) ], 'segment row: episodeItem\'s keys' );
	is( $row->{line1}, $row->{name}, 'line1 = name (overridden)' );
	is( $row->{play},  "abclisten://episode/$SEGMENT1", 'play = the segment\'s own abclisten:// URL' );
	is( $row->{type},  'link', 'a link that also plays (no on_select)' );
	ok( !exists $row->{on_select}, '... no on_select' );
	is( $row->{url},      $EPISODE_MENU, 'opens the episode menu' );
	is( $row->{line2},    "Sat 17 Oct \x{B7} 9 min", 'line2: date · duration' );
	is( $row->{duration}, 558, 'duration: the segment\'s (558 s), not the episode\'s' );
	is( $row->{image},    $SEGMENT1_IMG, 'the segment\'s own image' );
	my $pass = $row->{passthrough}->[0];
	is_deeply(
		{ map { $_ => $pass->{$_} } qw(id docType programTitle programId programImage path segments) },
		{ id => $SEGMENT1, docType => 'audiosegment', programTitle => 'The Science Show', programId => '2885500', programImage => $SCIENCE_IMG, path => "$SCIENCE/some-success-with-palm-oil-nickel-mines-the-next-challenge/107277426", segments => [] },
		'passthrough: docType audiosegment (from contentUri), the parent\'s program fields, no segments of its own'
	);

	my $meta = Plugins::ABCListen::Util::getEpisodeMeta($SEGMENT1);
	is_deeply(
		{ map { $_ => $meta->{$_} } qw(path docType programTitle programId title duration) },
		{ path => $pass->{path}, docType => 'audiosegment', programTitle => 'The Science Show', programId => '2885500', title => 'Some success with palm oil. Nickel mines the next challenge', duration => 558 },
		'meta cache: path, docType, programTitle (O1 resolves the segment by path like any episode)'
	);
	ok( Plugins::ABCListen::Util::getEpisodeMeta('107277432'), 'the second segment is cached too' );

	$c = open_item($row);
	my @names = @{ names( items_of($c) ) };
	ok( !( grep {/^Segments/} @names ), 'a segment\'s own menu: no Segments row (no recursion)' );
	ok( ( grep { $_ eq 'More from The Science Show' } @names ), '... but More from its program' );

	# synthetic: missing fields, no parseable id, an empty label, duplicate presenters
	fresh();
	route( qr{\Q$EPS\E\?collectionId=90000200&}, file => 'ondemand/bff-episodesWithSegments-segments.synthetic.json', headers => $JSON );
	my $list = collector();
	Plugins::ABCListen::Programs::episodes( '90000200', 0, 50, $list->cb );
	my $show = { %{ ( $list->args(0) )[0]->{items}->[0] }, programImage => $SCIENCE_IMG, programTitle => 'Edge Cases', programId => '1' };

	$c = feed( $EPISODE_MENU, undef, { %$show, path => undef } );
	is( find_named( items_of($c), qr/^Presented by/ )->{name}, 'Presented by Ann Example, Bob Example and Cat Example', 'presenters from the card: de-duplicated, "A, B and C"' );
	is( find_named( items_of($c), qr/^Segments/ )->{name}, 'Segments (3)', 'Segments (3): the segment without a parseable id is not counted' );

	$items = items_of( feed( $SEGMENTS_MENU, undef, $show ) );
	is_deeply(
		names($items),
		[ "1 of 4 \x{2013} The first part & more", "2 of 3 \x{2013} No image, duration, date or label", "3 of 3 \x{2013} An empty label" ],
		'ABC\'s label when given; else "<i> of <N>" (N = the valid segments)'
	);
	is( $items->[1]->{image}, Plugins::ABCListen::API::imageUrl( $show->{image}, 300 ), 'no segment image: the parent episode\'s' );
	ok( !exists $items->[1]->{duration}, 'no duration: no duration key' );
	ok( !exists $items->[1]->{line2},    '... and (no date either) no line2' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('90000203')->{docType}, 'audiosegment', 'docType null -> audiosegment' );

	my $noImage = { %$show, image => undef };
	$items = items_of( feed( $SEGMENTS_MENU, undef, $noImage ) );
	is( $items->[1]->{image}, Plugins::ABCListen::API::imageUrl( $SCIENCE_IMG, 300 ), 'neither segment nor episode image: programImage' );

	$items = items_of( feed( $SEGMENTS_MENU, undef, { id => '1', segments => [ { id => '7', title => 'Given', docType => 'audio' } ] } ) );
	is( Plugins::ABCListen::Util::getEpisodeMeta('7')->{docType}, 'audio', 'a segment\'s own docType is kept' );
	is( $items->[0]->{name}, "1 of 1 \x{2013} Given", 'one segment: "1 of 1"' );

	is_deeply( items_of( feed( $SEGMENTS_MENU, undef, { id => '1', segments => [] } ) ), [ text_item($NO_EPISODES) ], 'a stale id (no segments now): one readable text item' );
	is_deeply( items_of( feed( $SEGMENTS_MENU, undef, undef ) ), [ text_item($NO_EPISODES) ], 'no passthrough: one readable text item' );
	check_names( $items, 'segments' );
};

subtest 'tracklist on opening: present, [], error, timeout; each answered once; a second open makes no request; stable rows' => sub {
	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	my $drive = { id => $DRIVE_ID, title => 'Classic Drive', path => $DRIVE_PATH, programTitle => 'Classic Drive', programImage => $SCIENCE_IMG };

	my $c = feed( $EPISODE_MENU, undef, $drive );
	is( $c->count, 1, 'one callback' );
	my $tracklist = find_named( items_of($c), qr/^Tracklist/ );
	is_deeply(
		$tracklist,
		{ name => 'Tracklist (3)', type => 'link', items => [ map { text_item($_) } @DRIVE_ROWS ] },
		'Tracklist (3): a link with the rows inline as text items'
	);
	is( $tracklist->{items}->[0]->{name}, $ROSSINI, 'e.g. ' . $ROSSINI );
	is_deeply( names( items_of($c) ), [ 'Play episode', $tracklist->{name}, 'More from Classic Drive' ], 'Tracklist before More from' );
	check_names( items_of($c), 'Classic Drive episode' );

	my $okNames = names( items_of($c) );

	my $before = () = requests();
	my $calls  = @NEXT_CALLS;
	$c = feed( $EPISODE_MENU, undef, $drive );
	is( $c->count, 1, 'a second open: one callback' );
	is( scalar( () = requests() ), $before, '... and no request' );
	is( scalar @NEXT_CALLS, $calls, '... and no API call (the parsed rows)' );
	is( find_named( items_of($c), qr/^Tracklist/ )->{name}, 'Tracklist (3)', '... the same rows' );

	fresh();
	route_doc( '/listen/programs/edgecases/tracklist-empty/90000103', 'nextdata-episode-tracklist-empty.synthetic.json' );
	$c = feed( $EPISODE_MENU, undef, { id => '90000103', title => 'Empty', path => '/listen/programs/edgecases/tracklist-empty/90000103' } );
	is_deeply( items_of($c)->[-1], text_item($NO_TRACKLIST), 'items []: the "No tracklist" text item' );

	my $failedNames = [ 'Play episode', $UNAVAILABLE, 'More from Classic Drive' ];

	fresh();
	route( $DRIVE_URL, code => 500 );
	$c = feed( $EPISODE_MENU, undef, $drive );
	is( $c->count, 1, 'the fetch fails: one callback' );
	is_deeply( names( items_of($c) ), $failedNames, '... the "Tracklist unavailable" row in the tracklist\'s place; the rest of the menu' );
	is_deeply( items_of($c)->[1], text_item($UNAVAILABLE), '... a text item' );
	is( scalar @{ items_of($c) }, scalar @$okNames, '... as many rows as when the fetch works' );
	is( items_of($c)->[2]->{name}, $okNames->[2], '... More from at the same index' );
	is( scalar warnings_logged(), 1, '... WARN once' );

	$calls = @NEXT_CALLS;
	$c     = feed( $EPISODE_MENU, undef, $drive );
	is( $c->count, 1, 're-walked at once (LMS re-opens item ids from the top): answered synchronously' );
	is( scalar @NEXT_CALLS, $calls, '... from the cached failure, without asking ABC' );
	is_deeply( names( items_of($c) ), $failedNames, '... the same rows' );

	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON, defer => 1 );
	$c = feed( $EPISODE_MENU, undef, $drive );
	is( $c->count, 0, 'a slow ABC: the menu waits' );
	advanceTime(8);
	is( $c->count, 1, '... and answers within the 8 s fetch timeout, once' );
	is_deeply( names( items_of($c) ), $failedNames, '... with "Tracklist unavailable"' );
	my $moreId = 2;    # the index a client keeps for "More from"
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late document: still one callback' );
	$c = feed( $EPISODE_MENU, undef, $drive );
	is( find_named( items_of($c), qr/^Tracklist/ )->{name}, 'Tracklist (3)', 'the next open shows the tracklist (cached when it arrived)' );
	is( items_of($c)->[$moreId]->{name}, 'More from Classic Drive', '... and the stale "More from" index still opens More from, not the tracklist' );
	is_deeply( names( items_of($c) ), $okNames, '... the same rows as a menu that never failed' );

	fresh();
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	my $calls = 0;
	$EPISODE_MENU->( undef, sub { $calls++; die "LMS exploded\n" }, {}, $drive );
	is( $calls, 1, 'an LMS callback that dies: called once' );

	fresh();
	$calls = 0;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Tracklist::fetch = sub { die "tracklist exploded\n" };
		$EPISODE_MENU->( undef, sub { $calls++; is_deeply( names( $_[0]->{items} ), $failedNames, 'a fetch that dies: the menu, with "Tracklist unavailable" (not LOAD_FAILED)' ) }, {}, $drive );
	}
	is( $calls, 1, '... once' );

	fresh();
	$calls = 0;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::nextData = sub { die "API exploded\n" };
		$EPISODE_MENU->( undef, sub { $calls++; is_deeply( names( $_[0]->{items} ), $failedNames, 'an API call that dies: the menu, with "Tracklist unavailable" (not LOAD_FAILED)' ) }, {}, $drive );
	}
	is( $calls, 1, '... once' );
};

subtest 'More from: own program, Lab Notes before/after O1\'s resolve, programPath, opening it' => sub {
	fresh();
	route_science();
	route_doc( $TREES_PATH, 'nextdata-episode-scienceshow-mp3.trimmed.json' );
	my $rows = science_rows();
	route( qr{/_next/data/build-3afcd04f/listen/programs/lab-notes/}, file => 'ondemand/nextdata-episode-tracklist-null.synthetic.json', headers => $JSON );

	my $lab = $rows->{$LABNOTES_ID};
	ok( !defined $lab->{passthrough}->[0]->{programTitle}, 'the Lab Notes episode in The Science Show\'s menu has no programTitle (O2\'s rule)' );
	my $c = open_item($lab);
	ok( !find_named( items_of($c), qr/^More from/ ), 'before O1 knows its program: no More from row' );

	Plugins::ABCListen::Util::setEpisodeMeta( $LABNOTES_ID, { programTitle => 'Lab Notes', programId => '107000001' } );    # as O1's resolve writes it
	$c = open_item($lab);
	my $more = find_named( items_of($c), qr/^More from/ );
	is_deeply(
		$more,
		{
			name        => 'More from Lab Notes',
			line1       => 'More from Lab Notes',
			type        => 'link',
			url         => $PROGRAM_MENU,
			passthrough => [ { title => 'Lab Notes', path => $LABNOTES, id => '107000001' } ],
			image       => $ICON,
		},
		'after: "More from Lab Notes" (path derived from the episode path; no Science Show artwork)'
	);

	# the program's own episode, opened from its program: still offered (harmless)
	$c = open_item( $rows->{$TREES_ID} );
	$more = find_named( items_of($c), qr/^More from/ );
	is( $more->{name}, 'More from The Science Show', 'an episode opened from its own program still shows the row' );

	# opening it: O2's program menu with episodes
	$c = open_item($more);
	is( $c->count, 1, 'opening More from: one callback' );
	my $menu = items_of($c);
	is( $menu->[0]->{type}, 'textarea', '... O2\'s program menu (description first)' );
	is( scalar( grep { ( $_->{play} || '' ) =~ m{\Aabclisten://episode/} } @$menu ), 2, '... with the program\'s episodes' );

	# a caller's programPath wins over the derived one
	my $item = Plugins::ABCListen::OnDemand::_moreFromItem( undef, { id => '5', path => $TREES_PATH, programTitle => 'Hottest 100', programPath => 'https://www.abc.net.au/triplej/hottest-100/' } );
	is_deeply( $item->{passthrough}, [ { title => 'Hottest 100', path => '/triplej/hottest-100' } ], 'programPath given by the caller: used (canonical)' );

	is( Plugins::ABCListen::OnDemand::_moreFromItem( undef, { id => '6', programTitle => 'No path' } ), undef, 'no path anywhere: undef' );
	is( Plugins::ABCListen::OnDemand::_moreFromItem( undef, { id => '7', path => $TREES_PATH } ), undef, 'no title anywhere: undef' );
	is( Plugins::ABCListen::OnDemand::_moreFromItem( undef, undef ), undef, 'not a hash: undef' );

	Plugins::ABCListen::Util::setEpisodeMeta( '8', { path => $TREES_PATH, programTitle => 'The Science Show' } );
	is( Plugins::ABCListen::OnDemand::_moreFromItem( undef, { id => '8' } )->{name}, 'More from The Science Show', 'no path or title in the episode: both from the meta cache (e.g. a Home card)' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is( Plugins::ABCListen::OnDemand::_moreFromItem( $client, { id => '8' } )->{name}, 'More from The Science Show', 'with a client' );
};

subtest 'More from on an episode reached through Search (D3)' => sub {
	fresh();
	my $hit = {
		id           => '107266790',
		docType      => 'audioepisode',
		title        => 'Trees',
		programTitle => 'The Science Show',
		programId    => '2885500',
		path         => "$SITE$TREES_PATH",
	};
	my $row = $OD->episodeItem( undef, $hit );    # what Search builds from an Algolia hit
	route_doc( $TREES_PATH, 'nextdata-episode-scienceshow-mp3.trimmed.json' );
	my $c = open_item($row);
	is( find_named( items_of($c), qr/^More from/ )->{name}, 'More from The Science Show', 'a search result\'s episode menu: More from <program>' );
};

# ===========================================================================
# Song info (Episode.pm)
# ===========================================================================

sub seed_drive {
	Plugins::ABCListen::Util::setEpisodeMeta( $DRIVE_ID, {
		title        => 'Classic Drive',
		description  => 'Your ultimate drive time companion.',
		programTitle => 'Classic Drive',
		programId    => '8812254',
		path         => $DRIVE_PATH,
		image        => $SCIENCE_IMG,
	} );
}

subtest 'song info: registered by Episode->init after top; full cache -> notes, More from, Tracklist link; no HTTP' => sub {
	fresh();
	Plugins::ABCListen::Episode->init;
	my $p = provider();
	ok( $p, 'Episode->init registers the abclistenepisode song-info provider' );
	is( $p->{after}, 'top', '... after top' );
	is( $p->{func}, \&Plugins::ABCListen::Episode::_trackInfo, '... with _trackInfo' );

	seed_drive();
	my $url   = "abclisten://episode/$DRIVE_ID";
	my $items = song_info( undef, $url );
	is( scalar requests(), 0, 'no HTTP during the provider call' );
	is( scalar @NEXT_CALLS, 0, '... and no API call' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... and no timer' );

	is_deeply(
		$items,
		[
			{ name => 'Episode notes', items => [ { type => 'text', wrap => 1, name => 'Your ultimate drive time companion.' } ], unfold => 1 },
			{
				name        => 'More from Classic Drive',
				line1       => 'More from Classic Drive',
				type        => 'link',
				url         => $PROGRAM_MENU,
				passthrough => [ { title => 'Classic Drive', path => '/listen/programs/classic-drive', id => '8812254' } ],
				image       => $ICON,
			},
			{ name => 'Tracklist', type => 'link', url => $SONG_FEED, passthrough => [ { id => $DRIVE_ID, path => $DRIVE_PATH } ] },
		],
		'Episode notes (shaped like core\'s COMMENT item), More from Classic Drive, a lazy "Tracklist" link'
	);
	check_names( $items, 'song info' );

	# the lazy link
	route( $DRIVE_URL, file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => $JSON );
	my $c = open_item( $items->[2] );
	is( $c->count, 1, 'opening Tracklist: one callback' );
	is_deeply( items_of($c), [ map { text_item($_) } @DRIVE_ROWS ], '... the 3 rows as text items' );

	# now cached: inline
	$items = song_info( undef, $url );
	is_deeply( $items->[2], { name => 'Tracklist (3)', type => 'link', items => [ map { text_item($_) } @DRIVE_ROWS ] }, 'cached rows: Tracklist (3) inline' );
	is( scalar @$items, 3, '... still three rows (only the tracklist row changed form)' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is( scalar @{ song_info( $client, $url ) }, 3, 'with a client: the same rows' );
};

subtest 'song info: partial, empty-list, absent and corrupt cache; live and foreign URLs; the lazy feed\'s answers' => sub {
	fresh();
	Plugins::ABCListen::Episode->init;

	Plugins::ABCListen::Util::setEpisodeMeta( '90000102', { path => '/listen/programs/edgecases/tracklist-null/90000102' } );
	my $items = song_info( undef, 'abclisten://episode/90000102' );
	is_deeply( names($items), ['Tracklist'], 'only a path: no notes, no More from (no title), the Tracklist link' );

	route_doc( '/listen/programs/edgecases/tracklist-null/90000102', 'nextdata-episode-tracklist-null.synthetic.json' );
	my $c = open_item( $items->[0] );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { items => [ text_item($NO_TRACKLIST) ] } ], 'the link\'s feed, no tracklist: "No tracklist", once' );
	is_deeply( song_info( undef, 'abclisten://episode/90000102' ), [ text_item($NO_TRACKLIST) ], 'the cache holds []: "No tracklist" (a text item)' );

	Plugins::ABCListen::Util::setEpisodeMeta( '90000104', { path => '/listen/programs/edgecases/broken/90000104', title => 'Broken' } );
	route( qr{/broken/90000104\.json}, code => 500 );
	$c = open_item( song_info( undef, 'abclisten://episode/90000104' )->[0] );
	is_deeply( [ map { $_->[0] } $c->calls ], [ { items => [ text_item($LOAD_FAILED) ] } ], 'the link\'s feed, fetch failed: LOAD_FAILED, once' );

	Plugins::ABCListen::Util::setEpisodeMeta( '90000105', { title => 'No path', description => 'Notes only.' } );
	is_deeply( names( song_info( undef, 'abclisten://episode/90000105' ) ), ['Episode notes'], 'notes but no path: no tracklist row' );

	is( song_info( undef, 'abclisten://episode/424242' ), undef, 'no cache entry: undef' );
	Slim::Utils::Cache->new('abclisten')->set( 'episode-meta:424243', 'corrupt', 3600 );
	is( song_info( undef, 'abclisten://episode/424243' ), undef, 'a corrupt (non-hash) entry: undef, no crash' );
	Slim::Utils::Cache->new('abclisten')->set( 'episode-meta:424244', { renditions => 'corrupt', path => $DRIVE_PATH }, 3600 );
	is( song_info( undef, 'abclisten://episode/424244' ), undef, 'a corrupt entry (renditions not a list): undef' );
	Slim::Utils::Cache->new('abclisten')->set( 'episode-meta:424245', { description => { x => 1 }, programTitle => ['x'], path => ['y'] }, 3600 );
	is( song_info( undef, 'abclisten://episode/424245' ), undef, 'non-text fields: nothing to show, undef' );

	is( song_info( undef, 'abclisten://live/TRIPLEJ' ), undef, 'a live station: undef' );
	is( song_info( undef, 'https://example.test/a.mp3' ), undef, 'a foreign URL: undef' );
	is( song_info( undef, undef ), undef, 'no URL: undef' );
	is( scalar doc_requests(), 2, 'only the two Tracklist links opened above requested documents' );

	my $feed = collector();
	$SONG_FEED->( undef, $feed->cb, {}, undef );
	is_deeply( [ map { $_->[0] } $feed->calls ], [ { items => [ text_item($LOAD_FAILED) ] } ], 'the feed without an episode: LOAD_FAILED, once' );

	Slim::Utils::Log->resetMessages;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Tracklist::cached = sub { die "cache exploded\n" };
		seed_drive();
		is( song_info( undef, "abclisten://episode/$DRIVE_ID" ), undef, 'an exception: contained, undef' );
	}
	ok( scalar( grep { $_->{message} =~ /Song info .* failed: cache exploded/ } warnings_logged() ), '... and logged at WARN' );
};

subtest 'song info: order with M2\'s Follow rows; a stable row count' => sub {
	fresh();
	Plugins::ABCListen::Episode->init;
	Plugins::ABCListen::MyABC->init;
	ok( provider('abclistenfollow'), 'M2\'s abclistenfollow provider is registered too' );

	# Slim::Menu::Base orders providers that share an anchor by name (sort { $a cmp $b })
	my @afterTop = sort grep { ( $Slim::Menu::TrackInfo::PROVIDERS{$_}->{after} || '' ) eq 'top' } keys %Slim::Menu::TrackInfo::PROVIDERS;
	is_deeply( \@afterTop, [qw(abclistenepisode abclistenfollow)], 'both after top: the episode rows come before the Follow rows' );

	seed_drive();
	my $url  = "abclisten://episode/$DRIVE_ID";
	my $menu = sub { [ map { my $r = provider($_)->{func}->( undef, $url, undef, {}, {} ); ref $r eq 'ARRAY' ? @$r : ref $r eq 'HASH' ? $r : () } @afterTop ] };

	is_deeply( names( $menu->() ), [ 'Episode notes', 'More from Classic Drive', 'Tracklist', 'Follow "Classic Drive"', 'Follow to see its new episodes in My ABC listen' ], 'Episode notes · More from · Tracklist · Follow · hint' );

	Slim::Utils::Cache->new('abclisten')->set( "tracklist-rows:$DRIVE_ID", [ { title => 'One' } ], 3600 );
	my $rows = $menu->();
	is( scalar @$rows, 5, 'tracklist cached: the same number of rows (the Follow rows keep their index)' );
	is( $rows->[2]->{name}, 'Tracklist (1)', '... the row now inline: Tracklist (1)' );
	Slim::Utils::Cache->new('abclisten')->set( "tracklist-rows:$DRIVE_ID", [], 3600 );
	$rows = $menu->();
	is( scalar @$rows, 5, 'empty tracklist cached: the same number of rows' );
	is( $rows->[2]->{name}, $NO_TRACKLIST, '... the row now "No tracklist"' );
};

done_testing();
