#!/usr/bin/perl
# Plugins::ABCListen::Tracks (offline, fake clock): which services have song data (the 9 main music
# stations and the TRIPLEJ_/DOUBLEJ_/CLASSIC_ time-zone versions; talk, local, sport, RN and Kids
# listen versions never make a request); parsing the triple j and ABC Classic now.json fixtures
# (title, summary.artist incl. the composer in "Last, First" form, release + year, the cover nearest
# 580 px with square sizes first, epochs, duration) and BFF musicNowPlaying (the variant path:
# musicNowPlaying/<VARIANT_ID>?tz=<its tz>); synthetic edge cases (missing artwork, summary, artists,
# duration, next_updated; entities, '&' and non-ASCII); empty now; the cache (until next_updated,
# clamped 20-120 s, 60 s without it); HTTP 400 -> undef, 6 h, no WARN; a variant's mapiNow null and
# HTTP 500 -> undef, 6 h; 5xx/429/timeouts -> 30 s, WARN once; last-good (current); pollIn;
# recently played (parse, limit, 60 s cache, coalescing, main stations only); coalescing; exactly one
# callback on every path.
#
# Fixtures in t/data/live/ are raw response bodies (the research {_fixture_note, data} wrapper
# stripped; lists trimmed, shapes unedited):
#   music-abcradio-plays-triplej-now.json   GET https://music.abcradio.net.au/api/v1/plays/triplej/now.json
#                                           (research abc-samples, 2026-10-19 07:12 UTC; lists trimmed to 2)
#   bff-musicNowPlaying-TRIPLEJ.json         GET https://www.abc.net.au/core-next/api/musicNowPlaying/TRIPLEJ?tz=Australia%2FSydney
#                                           (research abc-samples; lists trimmed)
#   music-abcradio-plays-classic-now.json   GET https://music.abcradio.net.au/api/v1/plays/classic/now.json
#                                           (recorded for L3, 2026-10-19 23:27 UTC; links trimmed to 1)
#   music-abcradio-plays-search-triplej.json GET https://music.abcradio.net.au/api/v1/plays/search.json?limit=10&order=desc&station=triplej
#                                           (recorded for L3, 2026-10-19 23:33 UTC; artwork sizes trimmed to 1, links to 1)
#   bff-musicNowPlaying-TRIPLEJ_PERTH-500.json  GET https://www.abc.net.au/core-next/api/musicNowPlaying/TRIPLEJ_PERTH?tz=Australia%2FPerth
#                                           (recorded for L3, 2026-10-19 23:28 UTC: HTTP 500, every variant id)
#   foundation/music-400.json                GET https://music.abcradio.net.au/api/v1/plays/rn/now.json (400, F3)

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();
use POSIX ();

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Tracks;
use Plugins::ABCListen::Util qw(parseISO8601);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $T     = 'Plugins::ABCListen::Tracks';
my $MUSIC = 'https://music.abcradio.net.au/api/v1/';
my $BFF   = 'https://www.abc.net.au/core-next/api/';

my $TJ_NOW_URL  = "${MUSIC}plays/triplej/now.json";
my $TJ_PLAYED   = parseISO8601('2026-10-19T07:11:23+00:00');
my $TJ_NEXT     = parseISO8601('2026-10-19T07:14:45+00:00');
my $TJ_COVER    = 'https://resize.abcradio.net.au/n4TEe5BxO3t8HKtfGyqZUrvMkis=/160x160/center/middle/https%3A%2F%2Fwww.abc.net.au%2Ftriplej%2Falbums%2Fxivy-couldthisbelove.jpg';
my $PERTH_URL   = "${BFF}musicNowPlaying/TRIPLEJ_PERTH?tz=Australia%2FPerth";
my $CLASSIC_580 = 'https://resize.abcradio.net.au/yYlAKGOr9-21MUnkaFWRbjah6wg=/580x580/center/middle/https%3A%2F%2Fwww.abc.net.au%2Fclassic%2Falbumart%2Favie-av2698.jpg';

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub reset_all {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$T->_reset();
	setTime( $TJ_PLAYED + 60 );    # a minute into "Could This Be Love"
	return;
}

sub music_requests {
	my $re = shift || qr{music\.abcradio\.net\.au|/musicNowPlaying/};
	return scalar grep { $_->{url} =~ $re } requests();
}

sub json { JSON::PP->new->utf8->canonical->encode(shift) }
sub data { JSON::PP->new->utf8->decode( fixture(shift) ) }
sub iso  { POSIX::strftime( '%Y-%m-%dT%H:%M:%S+00:00', gmtime(shift) ) }

# A synthetic now.json body: %p title, artist (summary), artists ([name, type] pairs), release,
# year, artwork (release artwork list), played, duration, next.
sub now_body {
	my %p = @_;
	my %now = (
		played_time => iso( $p{played} // $TJ_PLAYED ),
		recording   => {
			title    => $p{title} // 'Song',
			duration => exists $p{duration} ? $p{duration} : 200,
			artists  => [ map { { name => $_->[0], type => $_->[1] } } @{ $p{artists} || [] } ],
			artwork  => $p{recordingArtwork} || [],
		},
		exists $p{release} ? ( release => $p{release} ) : ( release => { title => 'Album', release_year => $p{year}, artwork => $p{artwork} || [] } ),
	);
	$now{summary} = { artist => $p{artist} } if exists $p{artist};
	return json( { now => \%now, exists $p{next} ? ( next_updated => defined $p{next} ? iso( $p{next} ) : undef ) : ( next_updated => iso( $TJ_NEXT ) ) } );
}

sub now_cb {
	my $id = shift;
	my $c  = collector();
	$T->now( $id, $c->cb );
	return $c;
}

sub song_of { ( $_[0]->args(0) )[0] }

# ---- which services ----

subtest 'song data: the 9 main music stations and the music networks\' time-zone versions only' => sub {
	reset_all();
	my %map = (
		TRIPLEJ => 'triplej', DOUBLEJ => 'doublej', UNEARTHED => 'unearthed', JAZZ => 'jazz', COUNTRY => 'country',
		CLASSIC => 'classic', CLASSIC2 => 'classic2', H100 => 'h100', KIDSLISTEN => 'kidslisten',
	);
	is_deeply( { map { $_ => $T->station($_) } keys %map }, \%map, 'station map from the catalogue\'s musicStation' );
	is( scalar( grep { $T->hasSongs($_) } keys %map ), 9, '... all 9 have songs' );

	my @variants = map { my $n = $_; map {"${n}_$_"} qw(ADELAIDE BRISBANE DARWIN PERTH) } qw(TRIPLEJ DOUBLEJ CLASSIC);
	is( scalar( grep { $T->hasSongs($_) && !defined $T->station($_) } @variants ), 12, 'TRIPLEJ_*, DOUBLEJ_*, CLASSIC_*: songs (variant path), no station name' );

	my @none = qw(RN NEWS RA_ML RA RN_WA LOCAL_SYDNEY LOCAL_DARWIN GRANDSTAND SPORT_BBL KIDSLISTEN_WA NOPE);
	is( scalar( grep { $T->hasSongs($_) || defined $T->station($_) } @none, undef, '', 'triplej' ), 0, 'talk, local, sport, RN/RA/Kids listen versions, unknown: no song data' );

	my @calls = map { now_cb($_) } @none;
	is( music_requests(), 0, 'now() for them makes no request to any music endpoint' );
	is_deeply( [ map { [ $_->args(0) ] } @calls ], [ map { [undef] } @none ], '... and answers undef at once, once' );
	my $r = collector();
	$T->recent( 'RN', 10, $r->cb );
	$T->recent( 'TRIPLEJ_PERTH', 10, $r->cb );
	is( music_requests(), 0, 'recent() for a talk station or a time-zone version: no request' );
	is( scalar( grep { !defined( ( @$_ )[0] ) && defined( ( @$_ )[1] ) } $r->calls ), 2, '... (undef, error)' );
};

# ---- parsing ----

subtest 'parseNow: the triple j fixture' => sub {
	my $song = $T->parseNow( data('live/music-abcradio-plays-triplej-now.json'), 'triple j' );
	is_deeply(
		$song,
		{
			title       => 'Could This Be Love',
			artist      => 'X & Ivy',
			album       => 'Could This Be Love (2026)',
			cover       => $TJ_COVER,
			playedTime  => $TJ_PLAYED,
			duration    => 212,
			nextUpdated => $TJ_NEXT,
		},
		'title, summary.artist (with "&"), release + year, the size nearest 580 px, epochs, duration'
	);
	is( $T->songEnd($song), $TJ_PLAYED + 212, 'songEnd: playedTime + duration' );
};

subtest 'parseNow: ABC Classic (composer, performers, square 580 px cover)' => sub {
	my $data = data('live/music-abcradio-plays-classic-now.json');
	my $song = $T->parseNow( $data, 'ABC Classic' );
	is( $song->{artist}, $data->{now}->{summary}->{artist}, 'artist = summary.artist' );
	is( $song->{artist}, 'Boccherini, Luigi', '... the composer, "Last, First" (performers are type primary/performer)' );
	is( $song->{title},  'Sextet in E-flat major, Op. 38 No. 1, G467', 'title' );
	is( $song->{album},  'Boccherini: Chamber Works for Flute - Quintet, Op. 19 - Sextet, Op. 38 - Quintet in C Major (2024)', 'album + year' );
	is( $song->{cover},  $CLASSIC_580, 'cover: the 580x580 size' );
	is( $song->{duration}, 789, 'duration' );

	delete $data->{now}->{summary};
	is(
		$T->parseNow( $data, 'ABC Classic' )->{artist},
		'Sally Walker (flute) + Elizabeth Layton (violin) + Mark Gaydon (bassoon) + Robert Nairn (double bass) + Stephen King (viola) + Sarah Barrett (horn)',
		'no summary: the primary artists (whitespace collapsed), not performers or the composer'
	);
};

subtest 'parseMapiNow: the BFF fixture (variant path shape)' => sub {
	my $song = $T->parseMapiNow( data('live/bff-musicNowPlaying-TRIPLEJ.json'), 'triple j' );
	is_deeply(
		$song,
		{
			title       => 'AAAHHH!!!',
			artist      => 'Rachel Chinouriri',
			album       => 'I think I spoke too soon',
			cover       => 'https://resize.abcradio.net.au/GxkKCh6qu5IAP0upFgx0fO1HRO4=/160x160/center/middle/https%3A%2F%2Fwww.abc.net.au%2Ftriplej%2Falbums%2Frachelchinouriri-ithinkispoketoosoon.jpg',
			playedTime  => parseISO8601('2026-10-19T07:18:24+00:00'),
			duration    => 143,
			nextUpdated => parseISO8601('2026-10-19T07:20:37+00:00'),
		},
		'mapiNow mapped to the same shape'
	);
	is( $T->parseMapiNow( { mapiNow => undef, nextUpdated => undef } ), undef, 'mapiNow null: undef' );
	is( $T->parseMapiNow( { mapiNow => {} } ), undef, 'mapiNow {}: undef' );
	my $bare = $T->parseMapiNow( { mapiNow => { title => 'T', primaryImage => 'https://x/p.jpg' } }, 'triple j Perth' );
	is_deeply( [ @{$bare}{qw(artist cover album)} ], [ 'triple j Perth', 'https://x/p.jpg', undef ], 'no artist/release: station name, primaryImage, no album' );
};

subtest 'parseNow: missing and odd fields' => sub {
	is( $T->parseNow( { now => {} } ), undef, 'empty now (between songs): undef' );
	is( $T->parseNow( { now => undef } ), undef, 'now null: undef' );
	is( $T->parseNow( JSON::PP->new->utf8->decode( now_body( title => '  ' ) ) ), undef, 'no title: undef' );

	my $song = $T->parseNow( JSON::PP->new->utf8->decode( now_body( artists => [ [ 'A', 'primary' ], [ 'B', 'featured' ], [ 'C', 'primary' ] ] ) ), 'triple j' );
	is( $song->{artist}, 'A, C', 'no summary: primary artists joined with ", "' );
	is( $song->{cover},  undef,  'no release or recording artwork: no cover' );
	is( $song->{album},  'Album', 'release without release_year: no year suffix' );

	$song = $T->parseNow( JSON::PP->new->utf8->decode( now_body( artists => [] ) ), 'triple j' );
	is( $song->{artist}, 'triple j', 'no summary and no artists: the station name' );

	$song = $T->parseNow( JSON::PP->new->utf8->decode( now_body( artist => '', duration => 0, next => undef ) ), 'ABC Jazz' );
	is( $song->{artist}, 'ABC Jazz', 'empty summary.artist: falls through' );
	is( $song->{duration}, undef, 'duration 0: undef' );
	is( $song->{nextUpdated}, undef, 'next_updated null: undef' );
	is( $T->songEnd($song), undef, 'songEnd: unknown' );
	is( $T->songEnd( { %$song, nextUpdated => 1000 } ), 1030, 'no duration: nextUpdated + 30 s' );

	$song = $T->parseNow( JSON::PP->new->utf8->decode( now_body(
		title  => "Kei a  Wai\x{0101} &amp; Me \x{2014} &#8220;Live&#8221;",
		artist => 'Ng&#257;ti &amp; Ivy',
		recordingArtwork => [ { url => 'https://x/rec.jpg', sizes => [] } ],
		artwork => [ { sizes => [ { url => 'https://x/580w.jpg', width => 580, height => 326, aspect_ratio => '16x9' }, { url => 'https://x/340.jpg', width => 340, height => 340, aspect_ratio => '1x1' }, { url => 'https://x/1300.jpg', width => 1300, height => 1300 } ] } ],
	) ) );
	is( $song->{title},  "Kei a Wai\x{0101} & Me \x{2014} \x{201C}Live\x{201D}", 'entities decoded, non-ASCII kept, whitespace collapsed' );
	is( $song->{artist}, "Ng\x{0101}ti & Ivy", '... in the artist too' );
	is( $song->{cover},  'https://x/340.jpg', 'cover: square sizes first (340 px square beats a 580 px 16x9)' );

	$song = $T->parseNow( JSON::PP->new->utf8->decode( now_body( recordingArtwork => [ { url => 'https://x/rec.jpg' } ], artwork => [ { url => 'not a url' } ] ) ) );
	is( $song->{cover}, 'https://x/rec.jpg', 'no usable release artwork: the recording artwork\'s url' );
};

subtest 'parseRecent: the triple j recently played fixture' => sub {
	my $data  = data('live/music-abcradio-plays-search-triplej.json');
	my $plays = $T->parseRecent( $data, 10 );
	is( scalar @$plays, 10, '10 plays' );
	is_deeply( $plays->[0], { playedTime => parseISO8601('2026-10-19T23:32:16+00:00'), artist => 'Genesis Owusu & KYE', title => 'HUMAN AGAIN' }, 'newest first: { playedTime, artist, title }' );
	is_deeply(
		[ map {"$_->{artist} \x{2013} $_->{title}"} @$plays ],
		[ map { "$_->{summary}->{artist} \x{2013} $_->{recording}->{title}" } @{ $data->{items} }[ 0 .. 9 ] ],
		'Artist – Title of every item, in order'
	);
	is( scalar @{ $T->parseRecent( $data, 3 ) }, 3, 'up to $n' );
	is_deeply( $T->parseRecent( { items => [] } ), [], 'no items: []' );
	is_deeply( $T->parseRecent(undef), [], 'not a hash: []' );
};

subtest 'ttl: next_updated clamped to 20-120 s, 60 s without it' => sub {
	is( $T->ttl( 1045, 1000 ), 45,  '45 s ahead: 45 s' );
	is( $T->ttl( 1300, 1000 ), 120, '5 min ahead: 120 s' );
	is( $T->ttl( 1005, 1000 ), 20,  '5 s ahead: 20 s' );
	is( $T->ttl( 900,  1000 ), 20,  'in the past: 20 s' );
	is( $T->ttl( undef, 1000 ), 60, 'missing: 60 s' );
};

# ---- fetching ----

subtest 'now(): fetch, cache until next_updated, coalescing' => sub {
	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json', defer => 1 );

	my ( $a, $b ) = ( now_cb('TRIPLEJ'), now_cb('TRIPLEJ') );
	is( music_requests(), 1, 'two callers, one request' );
	is_deeply( [ map { $_->{url} } requests() ], [$TJ_NOW_URL], '... GET plays/triplej/now.json' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( song_of($a)->{title}, 'Could This Be Love', 'first caller: the song' );
	is( song_of($b)->{title}, 'Could This Be Love', 'second caller: the song' );
	is( $a->count + $b->count, 2, 'each answered once' );

	resetStubs();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	my $ttl = $TJ_NEXT - ( $TJ_PLAYED + 60 );    # 142 s -> 120
	is( $T->pollIn('TRIPLEJ'), 120, 'pollIn: next_updated 142 s away, clamped to 120 s' );
	advanceTime(119);
	now_cb('TRIPLEJ');
	is( music_requests(), 0, 'cached for 120 s' );
	advanceTime(1);
	now_cb('TRIPLEJ');
	is( music_requests(), 1, 'then fetched again' );
	ok( $ttl > 120, "(next_updated was $ttl s away)" );

	reset_all();
	route( $TJ_NOW_URL, content => now_body( next => undef ) );
	now_cb('TRIPLEJ');
	is( $T->pollIn('TRIPLEJ'), 60, 'no next_updated: 60 s' );
	advanceTime(59);
	now_cb('TRIPLEJ');
	is( music_requests(), 1, '... cached 60 s' );
};

subtest 'now(): empty now, HTTP 400 (6 h, no WARN), errors (30 s, WARN once)' => sub {
	reset_all();
	route( $TJ_NOW_URL, content => json( { now => {}, next_updated => iso( $TJ_PLAYED + 90 ) } ) );
	my $c = now_cb('TRIPLEJ');
	is_deeply( [ $c->args(0) ], [undef], 'empty now: undef, no error' );
	is( $T->pollIn('TRIPLEJ'), 30, '... refreshed at next_updated (30 s)' );

	reset_all();
	route( $TJ_NOW_URL, code => 400, content => fixture('foundation/music-400.json') );
	$c = now_cb('TRIPLEJ');
	is_deeply( [ $c->args(0) ], [undef], 'HTTP 400: undef, no error' );
	is( $T->pollIn('TRIPLEJ'), undef, '... no track delay (no song data)' );
	is( scalar( logged('WARN') ), 0, '... no WARN' );
	ok( scalar( grep { $_->{message} =~ /No song data for TRIPLEJ \(HTTP 400\)/ } logged('INFO') ), '... INFO' );
	advanceTime( 6 * 3600 - 1 );
	now_cb('TRIPLEJ');
	is( music_requests(), 1, '... not asked again for 6 h' );
	advanceTime(1);
	now_cb('TRIPLEJ');
	is( music_requests(), 2, '... then asked again' );

	for my $case ( [ '500', { code => 500 } ], [ '429', { code => 429 } ], [ 'a timeout', { error => 'Timed out waiting for data' } ], [ 'bad JSON', { content => '<html>' } ] ) {
		my ( $label, $response ) = @$case;
		reset_all();
		route( $TJ_NOW_URL, %$response );
		$c = now_cb('TRIPLEJ');
		ok( !defined( ( $c->args(0) )[0] ) && defined( ( $c->args(0) )[1] ), "$label: (undef, error)" );
		is( $T->pollIn('TRIPLEJ'), 30, "$label: retried in 30 s" );
		advanceTime(29);
		now_cb('TRIPLEJ');
		is( music_requests(), 1, "$label: negative cache for 30 s" );
		advanceTime(1);
		now_cb('TRIPLEJ');
		is( music_requests(), 2, "$label: then a new request" );
		is( scalar( grep { $_->{message} =~ /Song for TRIPLEJ unavailable/ } logged('WARN') ), 1, "$label: WARN once per run of failures" );
	}
};

subtest 'time-zone versions: musicNowPlaying/<VARIANT_ID>?tz=..., null and 500 -> 6 h, never the parent' => sub {
	reset_all();
	route( $PERTH_URL, content => json( { mapiNow => undef, nextUpdated => undef } ) );
	my $c = now_cb('TRIPLEJ_PERTH');
	is_deeply( [ map { $_->{url} } requests() ], [$PERTH_URL], 'upper-case variant id, its own tz' );
	is_deeply( [ $c->args(0) ], [undef], 'mapiNow null: undef' );
	is( $T->pollIn('TRIPLEJ_PERTH'), undef, '... no track delay' );
	advanceTime(3600);
	now_cb('TRIPLEJ_PERTH');
	is( music_requests(), 1, '... negatively cached (6 h)' );
	is( music_requests(qr{plays/triplej/|musicNowPlaying/TRIPLEJ\?}), 0, 'the parent\'s (Sydney) feed is never asked' );

	reset_all();
	route( $PERTH_URL, code => 500, content => fixture('live/bff-musicNowPlaying-TRIPLEJ_PERTH-500.json') );
	$c = now_cb('TRIPLEJ_PERTH');
	is_deeply( [ $c->args(0) ], [undef], 'HTTP 500 ("Query error", as BFF answers every variant id): undef, no error' );
	advanceTime( 6 * 3600 - 1 );
	now_cb('TRIPLEJ_PERTH');
	is( music_requests(), 1, '... not asked again for 6 h' );
	is( scalar( logged('WARN') ), 0, '... no WARN' );

	reset_all();
	route( $PERTH_URL, content => fixture('live/bff-musicNowPlaying-TRIPLEJ.json') );
	setTime( parseISO8601('2026-10-19T07:19:35+00:00') );
	$c = now_cb('TRIPLEJ_PERTH');
	is( song_of($c)->{title}, 'AAAHHH!!!', 'a variant with data: its song' );
	is( song_of($c)->{artist}, 'Rachel Chinouriri', '... artist' );
	is( $T->pollIn('TRIPLEJ_PERTH'), 62, '... refreshed at nextUpdated' );

	reset_all();
	route( "${BFF}musicNowPlaying/CLASSIC_ADELAIDE?tz=Australia%2FAdelaide", code => 503 );
	$c = now_cb('CLASSIC_ADELAIDE');
	ok( defined( ( $c->args(0) )[1] ), 'a variant\'s 503: an error (30 s), not "no data"' );
	is( $T->pollIn('CLASSIC_ADELAIDE'), 30, '... retried in 30 s' );
};

subtest 'current(): the song while current; last-good bridges one miss, not two' => sub {
	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	is( $T->current('TRIPLEJ'), undef, 'nothing fetched: undef' );
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ')->{title}, 'Could This Be Love', 'fetched: the song' );
	my $copy = $T->current('TRIPLEJ');
	$copy->{title} = 'x';
	is( $T->current('TRIPLEJ')->{title}, 'Could This Be Love', '... a copy' );

	resetStubs();
	route( $TJ_NOW_URL, content => json( { now => {}, next_updated => iso( $TJ_PLAYED + 200 ) } ) );
	advanceTime(120);
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ')->{title}, 'Could This Be Love', 'one empty answer while the song is current: still the song' );
	advanceTime(20);
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ'), undef, 'the second empty answer: undef (program mode)' );

	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	now_cb('TRIPLEJ');
	resetStubs();
	route( $TJ_NOW_URL, code => 502 );
	advanceTime(120);
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ')->{title}, 'Could This Be Love', 'one failure: still the song' );
	advanceTime(30);
	is( $T->current('TRIPLEJ')->{title}, 'Could This Be Love', '... until the song ends' );
	setTime( $TJ_PLAYED + 212 );
	is( $T->current('TRIPLEJ'), undef, 'playedTime + duration reached: undef' );

	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	setTime( $TJ_PLAYED + 300 );    # ABC not updated yet: the song is over
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ'), undef, 'a fresh answer whose song is already over: undef' );

	reset_all();
	route( $TJ_NOW_URL, content => now_body( played => $TJ_PLAYED + 600, duration => 100 ) );
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ')->{title}, 'Song', 'played_time in the future (clock skew): current' );

	reset_all();
	route( $TJ_NOW_URL, content => now_body( duration => undef, next => $TJ_PLAYED + 100 ) );
	now_cb('TRIPLEJ');
	setTime( $TJ_PLAYED + 129 );
	ok( $T->current('TRIPLEJ'), 'no duration: current until nextUpdated + 30 s' );
	setTime( $TJ_PLAYED + 130 );
	is( $T->current('TRIPLEJ'), undef, '... not after' );

	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	now_cb('TRIPLEJ');
	resetStubs();
	route( $TJ_NOW_URL, code => 400 );
	advanceTime(120);
	now_cb('TRIPLEJ');
	is( $T->current('TRIPLEJ'), undef, 'HTTP 400 (no song data) forgets the last song' );
};

subtest 'recent(): main stations, 60 s cache, coalesced, errors' => sub {
	reset_all();
	my $url = "${MUSIC}plays/search.json?limit=10&order=desc&station=triplej";
	route( $url, file => 'live/music-abcradio-plays-search-triplej.json', defer => 1 );

	my ( $a, $b ) = ( collector(), collector() );
	$T->recent( 'TRIPLEJ', 10, $a->cb );
	$T->recent( 'TRIPLEJ', 3,  $b->cb );
	is_deeply( [ map { $_->{url} } requests() ], [$url], 'one request: plays/search.json?station=triplej&order=desc&limit=10' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar @{ ( $a->args(0) )[0] }, 10, 'first caller: 10 plays' );
	is( scalar @{ ( $b->args(0) )[0] }, 3,  'second caller: its 3' );
	is( $a->count + $b->count, 2, 'each answered once' );

	advanceTime(59);
	my $c = collector();
	$T->recent( 'TRIPLEJ', 10, $c->cb );
	is( scalar( requests() ), 1, 'cached 60 s' );
	is( ( $c->args(0) )[0]->[0]->{title}, 'HUMAN AGAIN', '... the cached list' );
	advanceTime(1);
	resetStubs();
	route( $url, code => 503 );
	$c = collector();
	$T->recent( 'TRIPLEJ', 10, $c->cb );
	is( scalar( requests() ), 1, 'then fetched again' );
	ok( !defined( ( $c->args(0) )[0] ) && defined( ( $c->args(0) )[1] ), 'an error: (undef, error)' );
	$T->recent( 'TRIPLEJ', 10, sub { } );
	is( scalar( requests() ), 1, '... negatively cached' );
};

subtest 'exactly one callback, also when the callback dies' => sub {
	reset_all();
	route( $TJ_NOW_URL, file => 'live/music-abcradio-plays-triplej-now.json' );
	my $calls = 0;
	$T->now( 'TRIPLEJ', sub { $calls++; die "callback broke\n" } );
	is( $calls, 1, 'called once' );
	ok( scalar( grep { $_->{message} =~ /callback broke/ } logged('ERROR') ), 'the die is logged' );
	ok( eval { $T->now( 'TRIPLEJ', undef ); 1 }, 'no callback: no die' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::music = sub { die "api broke\n" };
		reset_all();
		my $c = now_cb('TRIPLEJ');
		is( $c->count, 1, 'API dies: one callback' );
		ok( defined( ( $c->args(0) )[1] ), '... with an error' );
	}
};

done_testing();
