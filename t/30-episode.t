#!/usr/bin/perl
# Plugins::ABCListen::Episode->resolve, offline (SimpleAsyncHTTP stub, fake clock): episode document
# parsing (the three recorded documents: title, program via the attribution link, programId, path,
# image fallback order, date, duration, normalised renditions, entities); the rendition matrix at
# fixed instants (MP3 permanent, AAC inside/after/at the end of its window, MP3 + AAC, MP3 closed
# with AAC open, bitrate order, restricted, only m3u8/f4m, no renditions, legacy abcmedia MP3,
# geo-001 failToken, open and future window bounds, de-duplication, unknown MIME types); the
# resolution paths (seeded shortcut without HTTP, stale seenAt, cached path, generic path and its
# redirect, Algolia objectID lookup with and without renditions, audiobook chapters, not found,
# rate limiting, transport errors with and without cached renditions, the 18 s deadline with a
# late result cached, invalid ids, concurrent resolves, stale buildId, non-audio documents); the
# metadata cache write (contract-3 keys only, epochs, seenAt, merged); exactly one callback.
# O6: AAC bitrates derived from fileSize and duration (and not without them), an AAC-only Algolia
# hit with different download and streaming windows, a restricted or not yet released document
# closing the cached windows (the fallback answers EXPIRED), the chapter cover from the hit's
# defaultThumbnail, a non-geo primary with a geo alternate, the request options on every path.
# F4: a non-ASCII cached path (upper-case escapes, as O2 caches it) and the generic path of a non-ASCII
# episode play; a cached path that fails (any error) falls back once to the id chain (generic path,
# then the lookup) within the deadline and caches the corrected path; RATE_LIMITED over budget.
# F6: when that fallback finds nothing (no hit, a hit with neither audio nor a page, a document that
# isn't audio, a second lookup), the renditions cached earlier are tried before NOT_FOUND.
#
# Fixtures in t/data/ondemand/ are raw response bodies as served:
#   nextdata-episode-scienceshow-mp3.trimmed.json   GET /_next/data/<buildId>/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790.json
#   nextdata-episode-classic-drive-aac.trimmed.json GET /_next/data/<buildId>/listen/programs/classic-drive/classic-drive/107174638.json
#   nextdata-episode-old-2024.trimmed.json          GET /_next/data/<buildId>/listen/programs/scienceshow/the-science-show/103022914.json
#       (research copies in ai-state/research/abc-samples/: the {_fixture_note, data} wrapper stripped,
#        data re-wrapped as {"pageProps": {"data": ...}}, shapes unedited. One value edited for O6:
#        the 2024 hero image's xPos 134 -> 684, so it differs from the thumbnail's large 1x1 crop)
#   nextdata-program-audiobook.trimmed.json         GET /_next/data/build-3afcd04f/listen/audiobooks/the-dictionary-of-lost-words-page.json
#       (research copy; its pageProps re-wrapped as {"pageProps": ...})
# Recorded for O1 (2026-10-19, OQ1 spike, buildId build-3afcd04f):
#   nextdata-generic-107266790.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/107266790.json (a 200 with __N_REDIRECT to the canonical path)
#   nextdata-generic-106353760.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/106353760.json (audiobook chapter: a 200 with __N_REDIRECT to its book)
#   nextdata-generic-1-404.json       GET /_next/data/build-3afcd04f/listen/programs/x/x/1.json (404 {"notFound":true})
# Recorded for O6 (2026-10-19), POST .../1/indexes/listen_prod_all/query, the objectID lookup O6 sends
# (attributesToRetrieve with defaultThumbnail), pretty-printed:
#   algolia-objectid-106353760.json   the Prologue chapter of algolia-audiobook-chapters.trimmed.json, with
#                                     programTitle and defaultThumbnail (re-recorded; O1's had no defaultThumbnail)
#   algolia-objectid-107174638.json   Classic Drive: AAC only (bitrate 0, fileSize), download window to 2200,
#                                     streaming window 28 days
# Recorded for F4 (2026-10-19, buildId build-3afcd04f), If You're Listening, "The apocalyptic El Niño we
# didn't see coming" (107267360, MP3, download window to 2200):
#   nextdata-generic-107267360.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/107267360.json (a 200 with
#                                     __N_REDIRECT to the canonical path, spelled with upper-case %C3%B1)
#   nextdata-episode-nonascii-107267360.trimmed.json  GET .../if-youre-listening/the-apocalyptic-el-ni%c3%b1o-we-didn-t-see-coming/107267360.json
#                                     (lower-case escapes: the upper-case spelling answers 307 with only x-nextjs-redirect;
#                                     documentProps cut to the keys this module reads, heroImageWithCTAPrepared and
#                                     thumbnailLink to their images)
# Shared: foundation/listen-search.trimmed.html (F3's recorded search page: buildId build-3afcd04f, Algolia TESTAPPID).
# Synthetic cases are built in this file from the recorded documents (edit_doc).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use JSON::PP ();
use Storable qw(dclone);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::Util qw(parseISO8601 getEpisodeMeta setEpisodeMeta CACHE_NAMESPACE);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# record INFO and DEBUG calls too
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

my $E = 'Plugins::ABCListen::Episode';

my $SITE    = 'https://www.abc.net.au';
my $SEARCH  = "$SITE/listen/search";
my $BUILD   = 'build-3afcd04f';
my $ALGOLIA = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $MEDIA   = 'https://mediacore-live-production.akamaized.net';

my $SCIENCE      = '107266790';
my $SCIENCE_PATH = '/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790';
my $SCIENCE_MP3  = "$MEDIA/audio/02/pg/Z/ai.mp3";
my $SCIENCE_IMG  = 'https://live-production.wcms.abc-cdn.net.au/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862';
my $SCIENCE_TITLE = '72 per cent of UK trees threatened by changing climate, plus the simple spud’s complex genetics';

my $DRIVE      = '107174638';
my $DRIVE_PATH = '/listen/programs/classic-drive/classic-drive/107174638';
my $DRIVE_AAC  = "$MEDIA/audio/02/pj/Z/2j.aac";
my $DRIVE_IMG  = 'https://live-production.wcms.abc-cdn.net.au/1a5e40456cd704992f3f4fd7252a97b6?impolicy=wcms_crop_resize&cropH=1688&cropW=1688&xPos=656&yPos=0&width=862&height=862';
my $DRIVE_SIZE = 353_025_904;    # the AAC's fileSize (bytes); duration 10,799 s
my $DRIVE_KBPS = 261.525;        # 353,025,904 x 8 / 10,799 / 1000, 3 decimals

my $OLD       = '103022914';
my $OLD_PATH  = '/listen/programs/scienceshow/the-science-show/103022914';
my $OLD_MP3   = "$MEDIA/audio/01/pp/Z/3i.mp3";
my $OLD_HERO  = 'https://live-production.wcms.abc-cdn.net.au/23b56445f570798642596347fe3a35f9?impolicy=wcms_crop_resize&cropH=1362&cropW=1362&xPos=684&yPos=0&width=862&height=862';
my $OLD_THUMB = 'https://live-production.wcms.abc-cdn.net.au/23b56445f570798642596347fe3a35f9?impolicy=wcms_crop_resize&cropH=1362&cropW=1362&xPos=134&yPos=0&width=862&height=862';

my $CHAPTER      = '106353760';
my $CHAPTER_PATH = '/listen/audiobooks/the-dictionary-of-lost-words-page/prologue-february-1886/106353760';
my $BOOK_PATH    = '/listen/audiobooks/the-dictionary-of-lost-words-page';
my $CHAPTER_MP3  = "$MEDIA/geo-001/audio/02/j6/Z/rr.mp3";
my $CHAPTER_IMG  = 'https://live-production.wcms.abc-cdn.net.au/d69f290a96e32fb4674bad70b4211043?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862';
my $CHAPTER_COVER = 'https://live-production.wcms.abc-cdn.net.au/d69f290a96e32fb4674bad70b4211043?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=600&height=600';

my $EXPIRED      = 'PLUGIN_ABCLISTEN_EPISODE_EXPIRED';
my $RESTRICTED   = 'PLUGIN_ABCLISTEN_EPISODE_RESTRICTED';
my $GEO          = 'PLUGIN_ABCLISTEN_EPISODE_GEO';
my $NOT_FOUND    = 'PLUGIN_ABCLISTEN_EPISODE_NOT_FOUND';
my $LOAD_FAILED  = 'PLUGIN_ABCLISTEN_LOAD_FAILED';
my $RATE_LIMITED = 'PLUGIN_ABCLISTEN_RATE_LIMITED';

my $OPEN_END = 4_102_444_800;    # 2100-01-01T00:00:00Z: Episode.pm's stored open window bound

my $JSON      = JSON::PP->new->utf8->canonical;
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $HTML_TYPE = { 'Content-Type' => 'text/html; charset=utf-8' };

sub iso { parseISO8601(shift) }

my $T = iso('2026-10-20T00:00:00Z');    # "now" unless a test says otherwise

my @META_KEYS = sort qw(id docType title programTitle programId path image description date duration renditions availableTo downloadAvailableTo seenAt);

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	setTime( shift || $T );
	route( $SEARCH, file => 'foundation/listen-search.trimmed.html', headers => $HTML_TYPE );
	return;
}

sub data_url { "$SITE/_next/data/$BUILD$_[0].json" }

sub doc { $JSON->decode( fixture("ondemand/$_[0]") ) }

# A recorded document (default: the Science Show MP3 episode) with $edit applied to its documentProps.
sub edit_doc {
	my ( $edit, $file ) = @_;
	my $doc = doc( $file || 'nextdata-episode-scienceshow-mp3.trimmed.json' );
	$edit->( $doc->{pageProps}->{data}->{documentProps} ) if $edit;
	return $doc;
}

sub serve {
	my ( $path, $body, %extra ) = @_;
	route( data_url($path), code => 200, content => ( ref $body ? $JSON->encode($body) : $body ), headers => $JSON_TYPE, %extra );
}

sub serve_algolia {
	my ( $body, %extra ) = @_;
	route( $ALGOLIA, code => 200, content => ( ref $body ? $JSON->encode($body) : $body ), headers => $JSON_TYPE, %extra );
}

sub resolve_id {
	my $id = shift;
	my $c  = collector();
	$E->resolve( $id, $c->cb );
	return $c;
}

# The single answer of collector $c (fails the test unless there is exactly one).
sub answer {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	return ( $c->args(0) )[0] || {};
}

# Resolve episode $id (default the Science Show) whose cached path serves $doc.
sub resolve_doc {
	my ( $doc, $id, $path ) = @_;
	$id   ||= $SCIENCE;
	$path ||= $SCIENCE_PATH;
	setEpisodeMeta( $id, { path => $path } );
	serve( $path, $doc );
	return resolve_id($id);
}

# url + alternates of a result
sub candidates { my $r = shift; return [ grep {defined} $r->{url}, @{ $r->{alternates} || [] } ] }

sub data_requests    { grep { $_->{url} =~ m{/_next/data/} } requests() }
sub algolia_requests { grep { $_->{url} eq $ALGOLIA } requests() }

sub logged_like {
	my ( $level, $re ) = @_;
	return scalar grep { $_->{message} =~ $re } Slim::Utils::Log->messages( category => 'plugin.abclisten', level => $level );
}

sub rendition { my ( $url, $mime, $bitrate ) = @_; return { url => $url, MIMEType => $mime, bitrate => $bitrate, codec => 'x', fileSize => 1 } }

# ---- document parsing (recorded documents) ----

subtest 'parse: Science Show MP3 episode -> metadata cache entry' => sub {
	fresh();
	my $r = answer( resolve_doc( doc('nextdata-episode-scienceshow-mp3.trimmed.json') ), 'science' );

	is_deeply( candidates($r), [$SCIENCE_MP3], 'plays the MP3' );
	is_deeply(
		getEpisodeMeta($SCIENCE),
		{
			id                  => $SCIENCE,
			docType             => 'audioepisode',
			title               => $SCIENCE_TITLE,
			programTitle        => 'The Science Show',
			programId           => '2885500',
			path                => $SCIENCE_PATH,
			image               => $SCIENCE_IMG,
			description         => 'And palm oil producers in South-East Asia have changed their ways, considering the environment more than they did. Brendan May is turning his attention now to nickel mines in tropical countries.',
			date                => iso('2026-10-17T01:00:00+00:00'),
			duration            => 3276,
			renditions          => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192, fileSize => 78642070 } ],
			availableTo         => iso('2026-11-14T01:00:00+00:00'),
			downloadAvailableTo => $OPEN_END,
			seenAt              => $T,
		},
		'exact cache entry: no hero image or thumbnail -> program image; 2200-01-01 -> open end'
	);
};

subtest 'parse: Classic Drive AAC episode (duplicate mpegurl entry kept in the cache, ignored for play)' => sub {
	fresh( iso('2026-10-20T12:00:00Z') );
	my $r = answer( resolve_doc( doc('nextdata-episode-classic-drive-aac.trimmed.json'), $DRIVE, $DRIVE_PATH ), 'drive' );

	is( $r->{url}, $DRIVE_AAC, 'AAC primary' );
	is_deeply( $r->{alternates}, [], 'no alternate: the mpegurl entry with the same .aac URL is ignored' );

	my $m = getEpisodeMeta($DRIVE);
	is_deeply( [ @$m{qw(title programTitle programId path image duration date)} ],
		[ 'Classic Drive', 'Classic Drive', '8812254', $DRIVE_PATH, $DRIVE_IMG, 10799, iso('2026-10-19T04:00:00+00:00') ], 'title, program, id, path, program image, duration, date' );
	is_deeply(
		$m->{renditions},
		[
			{ url => $DRIVE_AAC, mime => 'audio/aac',                     bitrate => $DRIVE_KBPS, fileSize => $DRIVE_SIZE },
			{ url => $DRIVE_AAC, mime => 'application/vnd.apple.mpegurl', bitrate => 0,           fileSize => $DRIVE_SIZE },
		],
		'renditions normalised to {url, mime, bitrate, fileSize}; the AAC\'s bitrate 0 derived (O6), the mpegurl entry\'s left'
	);
	is( $m->{availableTo}, iso('2026-11-16T04:00:00+00:00'), 'availableTo as an epoch' );
};

subtest 'parse: 2024 episode (hero image wins; MP3 after availableTo)' => sub {
	fresh();
	my $r = answer( resolve_doc( doc('nextdata-episode-old-2024.trimmed.json'), $OLD, $OLD_PATH ), 'old' );

	is_deeply( candidates($r), [$OLD_MP3], 'MP3 still plays (downloadAvailableTo 2200) although availableTo passed in 2024' );
	my $m = getEpisodeMeta($OLD);
	my $thumbnail = edit_doc( undef, 'nextdata-episode-old-2024.trimmed.json' )->{pageProps}->{data}->{documentProps}->{thumbnailLink}->{cropInfo}->[0]->{value}->[0];
	is_deeply( [ @$thumbnail{qw(ratio url)} ], [ '1x1', $OLD_THUMB ], 'the fixture has a large 1x1 thumbnail crop ...' );
	isnt( $OLD_HERO, $OLD_THUMB, '... that differs from its hero image (O6 fixture edit)' );
	is( $m->{image},        $OLD_HERO,                               'hero image first' );
	is( $m->{title},        'H. G. Wells – father of science fiction', 'title' );
	is( $m->{programTitle}, 'The Science Show',                      'program' );
	is( $m->{duration},     3247,                                    'duration' );
	is( $m->{date},         iso('2024-01-20T01:00:00+00:00'),        'date' );
};

subtest 'parse: image fallback order hero -> thumbnail large 1x1 -> program image -> none' => sub {
	my $thumb = 'https://live-production.wcms.abc-cdn.net.au/thumb1x1?impolicy=wcms_crop_resize&cropH=10&cropW=10&xPos=0&yPos=0&width=862&height=862';

	fresh();
	resolve_doc( edit_doc( sub {
		$_[0]->{heroImageWithCTAPrepared}->{heroImagePrepared} = undef;
		$_[0]->{thumbnailLink}->{cropInfo}->[0]->{value}->[0]->{url} = $thumb;
	}, 'nextdata-episode-old-2024.trimmed.json' ), $OLD, $OLD_PATH );
	is( getEpisodeMeta($OLD)->{image}, $thumb, 'no hero: the thumbnail large 1x1 crop' );

	fresh();
	resolve_doc( edit_doc( sub {
		$_[0]->{heroImageWithCTAPrepared}->{heroImagePrepared} = undef;
		$_[0]->{thumbnailLink} = undef;
	}, 'nextdata-episode-old-2024.trimmed.json' ), $OLD, $OLD_PATH );
	is( getEpisodeMeta($OLD)->{image}, $SCIENCE_IMG, 'no hero, no thumbnail: the program image' );

	fresh();
	resolve_doc( edit_doc( sub { delete $_[0]->{heroImageWithCTAPrepared} } ) );
	ok( !exists getEpisodeMeta($SCIENCE)->{image}, 'no image at all: none stored' );
};

subtest 'parse: program via the "Program:" attribution link, else the first link; entities decoded' => sub {
	fresh();
	resolve_doc( edit_doc( sub {
		$_[0]->{attributionLinksPrepared}->{links} = [ { title => 'Radio National', screenReaderText => 'Network:' }, { title => 'Science &amp; Society', screenReaderText => 'Program:' } ];
		$_[0]->{title}    = 'Spuds &amp; trees &#8217;round the world';
		$_[0]->{synopsis} = ' Palm oil&nbsp;&lt;and&gt; nickel ';
	} ) );
	my $m = getEpisodeMeta($SCIENCE);
	is( $m->{programTitle}, 'Science & Society',               'the Program: link, entity-decoded' );
	is( $m->{title},        "Spuds & trees \x{2019}round the world", 'title entity-decoded' );
	is( $m->{description},  'Palm oil <and> nickel',           'synopsis entity-decoded and trimmed' );

	fresh();
	resolve_doc( edit_doc( sub { $_[0]->{attributionLinksPrepared}->{links} = [ { title => 'First Link' }, { title => 'Second' } ] } ) );
	is( getEpisodeMeta($SCIENCE)->{programTitle}, 'First Link', 'no Program: link: the first link' );

	fresh();
	resolve_doc( edit_doc( sub { delete $_[0]->{attributionLinksPrepared}; delete $_[0]->{title}; $_[0]->{duration} = 0 } ) );
	my $bare = getEpisodeMeta($SCIENCE);
	ok( !exists $bare->{programTitle} && !exists $bare->{title} && !exists $bare->{duration}, 'no links, title or duration: none stored' );
};

# ---- the rendition matrix ----

subtest 'matrix: MP3 permanent, AAC inside / after / at the end of its window' => sub {
	fresh();
	my $r = answer( resolve_doc( doc('nextdata-episode-scienceshow-mp3.trimmed.json') ), 'MP3' );
	is_deeply( [ $r->{url}, $r->{alternates} ], [ $SCIENCE_MP3, [] ], 'MP3 permanent: MP3, no alternates' );
	ok( !exists $r->{failToken}, 'no failToken' );

	for my $case (
		[ '2026-10-20T12:00:00Z', [$DRIVE_AAC], 'AAC inside its window' ],
		[ '2026-11-16T03:59:59Z', [$DRIVE_AAC], 'AAC one second before availableTo' ],
		[ '2026-11-16T04:00:00Z', $EXPIRED,     'AAC at availableTo (boundary: not playable)' ],
		[ '2026-11-17T00:00:00Z', $EXPIRED,     'AAC after its window' ],
		[ '2026-10-19T03:59:59Z', $EXPIRED,     'AAC before availableFrom' ],
	) {
		my ( $when, $want, $name ) = @$case;
		fresh( iso($when) );
		my $r = answer( resolve_doc( doc('nextdata-episode-classic-drive-aac.trimmed.json'), $DRIVE, $DRIVE_PATH ), $name );
		if ( ref $want ) { is_deeply( candidates($r), $want, "$name: the AAC" ) }
		else             { is_deeply( $r, { error => $want }, "$name: $want, no URL" ) }
	}
};

subtest 'matrix: MP3 + AAC, MP3 closed with AAC open, bitrate order, de-duplication' => sub {
	my $aac = "$MEDIA/audio/x/y.aac";

	fresh();
	my $r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $aac, 'audio/aac', 260 ), rendition( $SCIENCE_MP3, 'audio/mpeg', 192 ) ] } ) ), 'both' );
	is_deeply( candidates($r), [ $SCIENCE_MP3, $aac ], 'MP3 + AAC both open: MP3 primary, AAC alternate (OQ2)' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub {
		$_[0]->{renditions}          = [ rendition( $SCIENCE_MP3, 'audio/mpeg', 192 ), rendition( $aac, 'audio/aac', 260 ) ];
		$_[0]->{downloadAvailableTo} = '2026-10-19T00:00:00+00:00';
	} ) ), 'MP3 closed' );
	is_deeply( candidates($r), [$aac], 'MP3 window closed, AAC open: AAC primary' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub {
		$_[0]->{renditions} = [
			rendition( "$MEDIA/a.mp3", 'audio/mpeg', 64 ),  rendition( "$MEDIA/b.mp3", 'audio/mpeg', 0 ),
			rendition( "$MEDIA/c.mp3", 'audio/mpeg', 192 ), rendition( "$MEDIA/d.mp3", 'audio/mpeg', undef ),
			rendition( "$MEDIA/e.mp3", 'audio/mpeg', 128 ), rendition( "$MEDIA/c.mp3", 'audio/mpeg', 192 ),
		];
	} ) ), 'bitrates' );
	is_deeply( candidates($r), [ map {"$MEDIA/$_.mp3"} qw(c e a b d) ], 'highest bitrate first, 0 and missing last, each URL once' );
};

subtest 'matrix: no renditions, only m3u8/f4m, legacy abcmedia MP3, unknown MIME types' => sub {
	for my $case ( [ 'missing', sub { delete $_[0]->{renditions} } ], [ 'null', sub { $_[0]->{renditions} = undef } ], [ 'empty', sub { $_[0]->{renditions} = [] } ] ) {
		fresh();
		my $r = answer( resolve_doc( edit_doc( $case->[1] ) ), "renditions $case->[0]" );
		is_deeply( $r, { error => $EXPIRED }, "renditions $case->[0]: EXPIRED" );
	}

	my $m3u8 = 'https://abcradiomodhls-vh.akamaihd.net/i/radio/local_darwin/audio/202204/acl-2022-04-14.mp3/master.m3u8';
	my $f4m  = 'https://abcradiomodhls-vh.akamaihd.net/z/radio/local_darwin/audio/202204/acl-2022-04-14.mp3/manifest.f4m';
	my $legacy = 'https://abcmedia.akamaized.net/radio/local_darwin/audio/202204/acl-2022-04-14.mp3';

	fresh();
	my $r = answer( resolve_doc( edit_doc( sub {
		$_[0]->{renditions} = [
			rendition( $m3u8, 'application/vnd.apple.mpegurl', 0 ), rendition( $f4m, 'application/f4m+xml', 0 ),
			rendition( "$m3u8?x=1", 'audio/mpeg', 128 ), rendition( "$f4m#x", 'audio/mp3', 64 ), rendition( "$MEDIA/hls.M3U8", 'audio/aac', 0 ),
		];
	} ) ), 'legacy only' );
	is_deeply( $r, { error => $EXPIRED }, 'only .m3u8/.f4m (whatever the MIME type): EXPIRED' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub {
		$_[0]->{renditions} = [ rendition( $m3u8, 'application/vnd.apple.mpegurl', 0 ), rendition( $f4m, 'application/f4m+xml', 0 ), rendition( $legacy, 'audio/mp3', 128 ) ];
	} ) ), 'legacy MP3' );
	is_deeply( candidates($r), [$legacy], 'legacy abcmedia MP3 (audio/mp3): MP3 primary' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub {
		$_[0]->{renditions} = [ rendition( "$MEDIA/v.mp4", 'video/mp4', 999 ), rendition( "$MEDIA/n.mp3", undef, 999 ), rendition( "$MEDIA/w.wav", 'audio/vnd.wave', 999 ), rendition( $SCIENCE_MP3, 'Audio/MPEG', 192 ) ];
	} ) ), 'unknown MIME' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'other or missing MIME types are ignored (MIME compared case-insensitively)' );
};

subtest 'matrix: window bounds (missing/null open, future From not playable)' => sub {
	fresh();
	my $r = answer( resolve_doc( edit_doc( sub { delete $_[0]->{downloadAvailableFrom}; $_[0]->{downloadAvailableTo} = undef } ) ), 'open bounds' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'missing From, null To: open on both sides' );
	is( getEpisodeMeta($SCIENCE)->{downloadAvailableTo}, $OPEN_END, 'an open To is stored as the open end' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub { $_[0]->{availableFrom} = $_[0]->{downloadAvailableFrom} = '2026-10-21T00:00:00+00:00' } ) ), 'future' );
	is_deeply( $r, { error => $EXPIRED }, 'published but not released yet: EXPIRED' );
	my $m = getEpisodeMeta($SCIENCE);
	ok( !exists $m->{renditions} && !exists $m->{seenAt}, '... and no renditions or seenAt cached for the shortcut' );
	is( $m->{title}, $SCIENCE_TITLE, '... the metadata is cached' );
};

subtest 'matrix: restricted and geo-001' => sub {
	fresh();
	my $r = answer( resolve_doc( edit_doc( sub { $_[0]->{webDistributionRestricted} = JSON::PP::true } ) ), 'restricted' );
	is_deeply( $r, { error => $RESTRICTED }, 'webDistributionRestricted: RESTRICTED although an MP3 exists' );
	ok( !exists getEpisodeMeta($SCIENCE)->{renditions}, '... and no renditions cached for the shortcut' );

	my $geoMp3 = "$MEDIA/geo-001/audio/02/oq/Z/0v.mp3";
	my $geoAac = "$MEDIA/geo-001/audio/02/oq/Z/0v.aac";

	fresh();
	$r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $geoMp3, 'audio/mpeg', 192 ) ] } ) ), 'geo' );
	is_deeply( [ @$r{qw(url alternates failToken)} ], [ $geoMp3, [], $GEO ], 'geo-001 MP3: the URL is still returned, failToken EPISODE_GEO' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $geoAac, 'audio/aac', 0 ), rendition( $geoMp3, 'audio/mpeg', 192 ) ] } ) ), 'geo both' );
	is_deeply( [ candidates($r), $r->{failToken} ], [ [ $geoMp3, $geoAac ], $GEO ], 'MP3 + AAC both geo: both tried, then the geo message' );

	fresh();
	$r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $geoAac, 'audio/aac', 0 ), rendition( $SCIENCE_MP3, 'audio/mpeg', 192 ) ] } ) ), 'non-geo + geo' );
	is_deeply( [ candidates($r), $r->{failToken} ], [ [ $SCIENCE_MP3, $geoAac ], $GEO ],
		'non-geo MP3 primary, geo AAC alternate: both tried; if both fail, the geo message (the alternate may have failed for being geo)' );

	# D5: some audiobooks (The Secret Keeper) and Bluey Book Reads are on abcmedia's /radio/geo/ path
	my $radioGeo = 'https://abcmedia.akamaized.net/radio/geo/listen-audio-books/the-secret-keeper/01.mp3';
	fresh();
	$r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $radioGeo, 'audio/mp3', 128 ) ] } ) ), 'radio/geo' );
	is_deeply( [ @$r{qw(url alternates failToken)} ], [ $radioGeo, [], $GEO ], 'abcmedia /radio/geo/ MP3 (audio/mp3): failToken EPISODE_GEO' );

	for my $url ( 'https://abcmedia.akamaized.net/radio/kidslisten/bluey/01.mp3', "$MEDIA/audio/geography/02/x.mp3", 'https://abcmedia.akamaized.net/radio/geology/01.mp3' ) {
		fresh();
		$r = answer( resolve_doc( edit_doc( sub { $_[0]->{renditions} = [ rendition( $url, 'audio/mpeg', 128 ) ] } ) ), "not geo: $url" );
		ok( $r->{url} && !exists $r->{failToken}, "not a geo path ($url): no failToken" );
	}
};

# ---- resolution paths ----

subtest 'seeded shortcut (Search shape, seenAt < 6 h): no HTTP at all' => sub {
	fresh();
	setEpisodeMeta( $SCIENCE, {
		title => 'Seeded', programTitle => 'The Science Show', path => $SCIENCE_PATH,
		renditions => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192 } ],
		availableTo => $T + 86400, downloadAvailableTo => iso('2099-01-01T00:00:00Z'), seenAt => $T - 3600,
	} );

	my $r = answer( resolve_id($SCIENCE), 'seeded' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'chosen from the seeded renditions' );
	is( $r->{meta}->{title}, 'Seeded', 'meta from the cache' );
	is( scalar( requests() ), 0, 'the stub recorded no request' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no deadline timer left' );
};

subtest 'seeded shortcut: closed window, ISO-8601 windows, unknown MIME types' => sub {
	fresh();
	setEpisodeMeta( $DRIVE, { renditions => [ { url => $DRIVE_AAC, mime => 'audio/aac', bitrate => 0 } ], availableTo => $T - 1, seenAt => $T - 60 } );
	is_deeply( answer( resolve_id($DRIVE), 'closed' ), { error => $EXPIRED }, 'AAC window already closed: EXPIRED' );
	is( scalar( requests() ), 0, '... without HTTP' );

	fresh();
	setEpisodeMeta( $SCIENCE, {
		renditions => [ { url => $DRIVE_AAC, mime => 'audio/aac' }, { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192 } ],
		availableTo => '2026-10-19T00:00:00+00:00', downloadAvailableTo => '2200-01-01T00:00:00+00:00', seenAt => $T - 60,
	} );
	is_deeply( candidates( answer( resolve_id($SCIENCE), 'iso' ) ), [$SCIENCE_MP3], 'windows stored as ISO-8601 strings: MP3 open (2200), AAC closed' );

	fresh();
	setEpisodeMeta( $SCIENCE, {
		renditions => [ { url => "$MEDIA/x.mp3" }, { url => "$MEDIA/y.mp4", mime => 'video/mp4' }, { url => $SCIENCE_MP3, mime => 'audio/mpeg' } ],
		seenAt => $T - 60,
	} );
	is_deeply( candidates( answer( resolve_id($SCIENCE), 'mime' ) ), [$SCIENCE_MP3], 'renditions with a missing or unknown mime are ignored' );
	is( scalar( requests() ), 0, '... without HTTP' );
};

subtest 'stale seenAt (> 6 h) -> the cached path is fetched: exactly one _next/data request' => sub {
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH, renditions => [ { url => "$MEDIA/old.mp3", mime => 'audio/mpeg' } ], seenAt => $T - 7 * 3600 } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );

	my $r = answer( resolve_id($SCIENCE), 'stale' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'chosen from the fetched document' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url($SCIENCE_PATH) ], 'one _next/data request, for the cached path' );
	is( scalar( algolia_requests() ), 0, 'no Algolia request' );
	is( getEpisodeMeta($SCIENCE)->{seenAt}, $T, 'seenAt refreshed' );
	is_deeply( getEpisodeMeta($SCIENCE)->{renditions}, [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192, fileSize => 78642070 } ], 'renditions replaced' );
};

subtest 'no cached path (OQ1): the generic path, redirected by ABC to the canonical page' => sub {
	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-107266790.json') );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );

	my $r = answer( resolve_id($SCIENCE), 'generic' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'plays the MP3' );
	is( $r->{meta}->{title}, $SCIENCE_TITLE, 'meta from the fetched document' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url("/listen/programs/x/x/$SCIENCE"), data_url($SCIENCE_PATH) ], 'the generic path, then the redirect target (followed by API.pm)' );
	is( getEpisodeMeta($SCIENCE)->{path}, $SCIENCE_PATH, 'the canonical path is cached' );
	is( scalar( algolia_requests() ), 0, 'no Algolia request' );

	# F6: what the header says of the recorded generic paths: page data (served 200) whose
	# pageProps carry __N_REDIRECT, not an HTTP 308
	for my $case (
		[ $SCIENCE,    $SCIENCE_PATH ],
		[ $CHAPTER,    "$BOOK_PATH/" ],
		[ '107267360', '/listen/programs/if-youre-listening/the-apocalyptic-el-ni%C3%B1o-we-didn-t-see-coming/107267360' ],
	) {
		my ( $id, $target ) = @$case;
		my $props = $JSON->decode( fixture("ondemand/nextdata-generic-$id.json") )->{pageProps};
		is_deeply( [ @$props{qw(__N_REDIRECT __N_REDIRECT_STATUS)} ], [ $target, 308 ], "nextdata-generic-$id.json: __N_REDIRECT to $target in the page data" );
	}
};

subtest 'generic path fails -> one Algolia objectID lookup -> its page -> the document' => sub {
	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$SCIENCE_PATH" } ], nbHits => 1 } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );

	my $r = answer( resolve_id($SCIENCE), 'lookup' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'plays the MP3 from the document' );

	my @algolia = algolia_requests();
	is( scalar @algolia, 1, 'exactly one Algolia request' );
	is_deeply(
		$JSON->decode( $algolia[0]->{body} ),
		{
			query                => '',
			filters              => qq{objectID:"coremedia://audioepisode/$SCIENCE" OR objectID:"coremedia://audio/$SCIENCE" OR objectID:"coremedia://audiosegment/$SCIENCE"},
			hitsPerPage          => 1,
			attributesToRetrieve => [qw(objectID canonicalURL title programTitle programID duration dates mediaRenditions defaultThumbnail)],
		},
		'the POST body holds the three-objectID filter, one hit, the attributes needed (defaultThumbnail: O6)'
	);
	is( ( data_requests() )[-1]->{url}, data_url($SCIENCE_PATH), 'then the page the hit names' );
};

subtest 'not found: generic 404 and no Algolia hit; non-audio documents' => sub {
	fresh();
	serve( '/listen/programs/x/x/1', fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( { hits => [], nbHits => 0 } );
	is_deeply( answer( resolve_id(1), 'id 1' ), { error => $NOT_FOUND }, 'id 1: NOT_FOUND' );
	is( scalar( algolia_requests() ), 1, '... after one Algolia request' );

	fresh();
	my $r = answer( resolve_doc( edit_doc( sub { $_[0]->{docType} = 'article'; $_[0]->{renditions} = [] } ) ), 'article' );
	is_deeply( $r, { error => $NOT_FOUND }, 'an article document: NOT_FOUND' );
	ok( logged_like( INFO => qr/\Q$SCIENCE_PATH\E/ ), '... with the path logged at INFO' );
	is( scalar( algolia_requests() ), 0, '... and no Algolia request' );

	fresh();
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE" } ] } );
	$r = answer( resolve_doc( { pageProps => { data => { title => 'Not an episode page' } } } ), 'no documentProps, hit without page' );
	is_deeply( $r, { error => $NOT_FOUND }, 'no documentProps and a hit with neither renditions nor page: NOT_FOUND' );

	fresh();
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$SCIENCE_PATH" } ] } );
	$r = answer( resolve_doc( { pageProps => { data => {} } } ), 'still no document' );
	is_deeply( $r, { error => $NOT_FOUND }, 'the page the hit names has no document either: NOT_FOUND' );
	is( scalar( algolia_requests() ), 1, '... with one Algolia request' );
};

subtest 'audio and audiosegment documents resolve like audioepisode; a document for another id is looked up' => sub {
	for my $type (qw(audio audiosegment)) {
		fresh();
		my $r = answer( resolve_doc( edit_doc( sub { $_[0]->{docType} = $type } ) ), $type );
		is_deeply( candidates($r), [$SCIENCE_MP3], "$type: plays" );
		is( getEpisodeMeta($SCIENCE)->{docType}, $type, "$type: docType cached" );
	}

	fresh();
	serve_algolia( { hits => [] } );
	my $r = answer( resolve_doc( edit_doc( sub { $_[0]->{id} = '999' } ) ), 'other id' );
	is_deeply( $r, { error => $NOT_FOUND }, 'the cached path holds document 999: looked up instead (no hit: NOT_FOUND)' );
	ok( !getEpisodeMeta($SCIENCE)->{renditions}, "... document 999's renditions are not cached for $SCIENCE" );
};

subtest 'audiobook chapter (#12 amendment): cached chapter path -> book page -> one Algolia lookup -> geo MP3' => sub {
	fresh();
	setEpisodeMeta( $CHAPTER, { path => $CHAPTER_PATH } );
	serve( $CHAPTER_PATH, fixture('ondemand/nextdata-generic-106353760.json') );
	serve( $BOOK_PATH,    fixture('ondemand/nextdata-program-audiobook.trimmed.json') );
	serve_algolia( fixture('ondemand/algolia-objectid-106353760.json') );

	my $r = answer( resolve_id($CHAPTER), 'chapter' );
	is_deeply( [ @$r{qw(url alternates failToken)} ], [ $CHAPTER_MP3, [], $GEO ], 'the geo MP3 with failToken EPISODE_GEO (not RESTRICTED: the book flag is not the chapter\'s)' );
	is( $r->{meta}->{cover}, $CHAPTER_COVER, 'the metadata cover is the hit\'s defaultThumbnail (1x1, at 600 px), not the plugin icon (O6)' );
	is( scalar( algolia_requests() ), 1, 'exactly one Algolia request' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url($CHAPTER_PATH), data_url($BOOK_PATH) ], 'the chapter page redirected to the book; the canonicalURL is not fetched again' );

	is_deeply(
		getEpisodeMeta($CHAPTER),
		{
			id                  => $CHAPTER,
			docType             => 'audioepisode',
			title               => 'Prologue: February 1886',
			programTitle        => 'The Dictionary of Lost Words',
			programId           => '106353766',
			path                => $CHAPTER_PATH,
			image               => $CHAPTER_IMG,
			date                => iso('2026-04-01T13:00:00+00:00'),
			duration            => 257,
			renditions          => [ { url => $CHAPTER_MP3, mime => 'audio/mpeg', bitrate => 320, fileSize => 10547937 } ],
			availableTo         => iso('2027-04-01T13:00:00+00:00'),
			downloadAvailableTo => iso('2027-04-01T13:00:00+00:00'),
			seenAt              => $T,
		},
		'the meta cache is seeded from the hit'
	);

	# within 6 h: no request at all
	fresh();
	setEpisodeMeta( $CHAPTER, { renditions => [ { url => $CHAPTER_MP3, mime => 'audio/mpeg', bitrate => 320 } ], seenAt => $T - 60, downloadAvailableTo => iso('2027-04-01T13:00:00+00:00') } );
	is( answer( resolve_id($CHAPTER), 'seeded chapter' )->{failToken}, $GEO, 'seeded chapter: geo failToken without HTTP' );
	is( scalar( requests() ), 0, '... no request' );

	# no cached path: the generic path also lands on the book
	fresh();
	serve( "/listen/programs/x/x/$CHAPTER", fixture('ondemand/nextdata-generic-106353760.json') );
	serve( $BOOK_PATH, fixture('ondemand/nextdata-program-audiobook.trimmed.json') );
	serve_algolia( fixture('ondemand/algolia-objectid-106353760.json') );
	is( answer( resolve_id($CHAPTER), 'generic chapter' )->{url}, $CHAPTER_MP3, 'no cached path: generic path -> book -> lookup -> the MP3' );
	is( scalar( algolia_requests() ), 1, '... with one Algolia request' );
};

subtest 'Algolia rate limited (429, or the budget used up) -> RATE_LIMITED; unavailable -> LOAD_FAILED' => sub {
	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( fixture('foundation/algolia-429.json'), code => 429 );
	is_deeply( answer( resolve_id($SCIENCE), '429' ), { error => $RATE_LIMITED }, 'HTTP 429: RATE_LIMITED' );

	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	route( $ALGOLIA, error => 'Connect timed out' );
	is_deeply( answer( resolve_id($SCIENCE), 'Algolia down' ), { error => $LOAD_FAILED }, 'Algolia unreachable: LOAD_FAILED' );

	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( { hits => [] } );
	Plugins::ABCListen::API::algolia( { query => "q$_" }, sub { }, sub { } ) for 1 .. 300;
	my $before = algolia_requests();
	is_deeply( answer( resolve_id($SCIENCE), 'budget' ), { error => $RATE_LIMITED }, 'budget used up: RATE_LIMITED' );
	is( scalar( algolia_requests() ), $before, '... without an Algolia request' );
};

subtest 'transport errors: cached renditions (any age) or LOAD_FAILED' => sub {
	# F4: a failed cached path falls back to the generic path and the lookup; here everything fails
	my $down = sub { route( qr{/_next/data/|\.algolia\.net/}, error => 'Timed out waiting for data' ) };

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH, title => 'Cached', renditions => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg' } ], seenAt => $T - 30 * 86400 } );
	$down->();

	my $r = answer( resolve_id($SCIENCE), 'cached' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'network error with cached renditions: chosen from the cache' );
	is( $r->{meta}->{title}, 'Cached', '... with the cached metadata' );
	is( logged_like( WARN => qr/\Q$SCIENCE\E.*cached earlier/ ), 1, '... and one WARN' );
	is_deeply(
		[ map { $_->{url} } requests() ],
		[ $SEARCH, data_url($SCIENCE_PATH), data_url("/listen/programs/x/x/$SCIENCE"), $ALGOLIA ],
		'... after the cached path, the generic path and the lookup failed'
	);

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	$down->();
	is_deeply( answer( resolve_id($SCIENCE), 'none' ), { error => $LOAD_FAILED }, 'without cached renditions: LOAD_FAILED' );

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, '{"pageProps": {"data": ' );
	$down->();
	is_deeply( answer( resolve_id($SCIENCE), 'bad JSON' ), { error => $LOAD_FAILED }, 'bad JSON: LOAD_FAILED' );

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, '{}', code => 500 );
	$down->();
	is_deeply( answer( resolve_id($SCIENCE), 'HTTP 500' ), { error => $LOAD_FAILED }, 'HTTP 500: LOAD_FAILED' );
};

# ---- F4: non-ASCII paths, and the fallback when a cached path fails ----

my $NONASCII        = '107267360';
my $NONASCII_LINKED = "/listen/programs/if-youre-listening/the-apocalyptic-el-ni%C3%B1o-we-didn-t-see-coming/$NONASCII";    # as ABC links it
my $NONASCII_SERVED = "/listen/programs/if-youre-listening/the-apocalyptic-el-ni%c3%b1o-we-didn-t-see-coming/$NONASCII";    # as ABC serves it
my $NONASCII_DOC    = 'ondemand/nextdata-episode-nonascii-107267360.trimmed.json';
my $NONASCII_MP3    = "$MEDIA/audio/02/pe/Z/6l.mp3";
my $STALE_PATH      = '/listen/programs/old-name/trees-potatoes-brendan-may-step/107266790';    # a cached path that no longer works

# The other spellings of a page answer ABC's 307 (only x-nextjs-redirect, no Location), as LMS fails it.
sub abc_307_otherwise { route( qr{/_next/data/}, error => 'Redirection without location' ) }

subtest 'F4: a non-ASCII episode plays from the path O2 cached (upper-case escapes), and from the generic path' => sub {
	fresh();
	setEpisodeMeta( $NONASCII, { path => $NONASCII_LINKED, title => 'From the episode list' } );
	route( data_url($NONASCII_SERVED), file => $NONASCII_DOC, headers => $JSON_TYPE );
	abc_307_otherwise();

	my $r = answer( resolve_id($NONASCII), 'cached path' );
	is_deeply( [ @$r{qw(url alternates)} ], [ $NONASCII_MP3, [] ], 'cached path: plays the MP3' );
	is( $r->{meta}->{title}, "The apocalyptic El Niño we didn't see coming", '... with the title from the document' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url($NONASCII_SERVED) ], '... after one _next/data request, lower-case' );
	is( scalar( algolia_requests() ), 0, '... and no Algolia request' );
	is( getEpisodeMeta($NONASCII)->{path}, $NONASCII_LINKED, 'the canonical path is cached as ABC links it' );

	fresh();
	serve( "/listen/programs/x/x/$NONASCII", fixture('ondemand/nextdata-generic-107267360.json') );
	route( data_url($NONASCII_SERVED), file => $NONASCII_DOC, headers => $JSON_TYPE );
	abc_307_otherwise();

	$r = answer( resolve_id($NONASCII), 'generic path' );
	is( $r->{url}, $NONASCII_MP3, 'no cached path: plays the MP3' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url("/listen/programs/x/x/$NONASCII"), data_url($NONASCII_SERVED) ], '... the generic path, then its redirect target lower-case' );
};

subtest 'F4: a cached path that fails (any error) falls back to the generic path and plays; the corrected path is cached' => sub {
	for my $case (
		[ 'a 307 LMS cannot follow', error => 'Redirection without location' ],
		[ 'HTTP 404',                code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE ],
		[ 'HTTP 500',                code => 500, content => '{}' ],
		[ 'a transport error',       error => 'Timed out waiting for data' ],
		[ 'not JSON',                code => 200, file => 'foundation/html-page-200.html', headers => $HTML_TYPE ],
	) {
		my ( $name, %response ) = @$case;

		fresh();
		setEpisodeMeta( $SCIENCE, { path => $STALE_PATH, title => 'From the episode list' } );
		route( data_url($STALE_PATH), %response );
		serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-107266790.json') );
		serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );

		my $r = answer( resolve_id($SCIENCE), $name );
		is_deeply( candidates($r), [$SCIENCE_MP3], "$name: plays the MP3" );
		is( $r->{meta}->{title}, $SCIENCE_TITLE, "$name: with the document's metadata" );
		is_deeply(
			[ map { $_->{url} } data_requests() ],
			[ data_url($STALE_PATH), data_url("/listen/programs/x/x/$SCIENCE"), data_url($SCIENCE_PATH) ],
			"$name: the cached path, then the generic path and its redirect"
		);
		is( scalar( algolia_requests() ), 0, "$name: no Algolia request" );
		is( getEpisodeMeta($SCIENCE)->{path}, $SCIENCE_PATH, "$name: the corrected path is cached" );
		is( scalar( Slim::Utils::Timers::pending() ), 0, "$name: answered before the deadline (no timer left)" );
	}
};

subtest 'F4: the fallback runs inside the 18 s deadline: one callback; a late document still caches the corrected path' => sub {
	my $setup = sub {
		fresh();
		setEpisodeMeta( $SCIENCE, { path => $STALE_PATH } );
		route( data_url($STALE_PATH), error => 'Timed out waiting for data', defer => 1 );
		serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-107266790.json'), defer => 1 );
		serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json'), defer => 1 );
		return resolve_id($SCIENCE);
	};

	# each request takes 6 s (its timeout): cached path, generic path, then the canonical page
	my $c = $setup->();
	advanceTime(6);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;    # the cached path times out: the generic path
	advanceTime(6);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;    # the generic path redirects: the canonical page
	is( $c->count, 0, 'no answer at 12 s' );
	advanceTime(5.9);
	is( $c->count, 0, 'none at 17.9 s' );
	advanceTime(0.1);
	is_deeply( [ $c->count, ( $c->args(0) )[0] ], [ 1, { error => $LOAD_FAILED } ], 'LOAD_FAILED at 18 s' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;    # the document arrives late
	is( $c->count, 1, 'still exactly one callback' );
	is( getEpisodeMeta($SCIENCE)->{path}, $SCIENCE_PATH, 'the late document caches the corrected path' );
	is( getEpisodeMeta($SCIENCE)->{seenAt}, $T + 18, '... and its renditions' );

	# faster answers: played within the deadline
	$c = $setup->();
	advanceTime(6);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(1);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(1);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ $c->count, candidates( ( $c->args(0) )[0] ) ], [ 1, [$SCIENCE_MP3] ], 'answered at 8 s: plays' );
	advanceTime(20);
	is( $c->count, 1, 'no second callback when the deadline would have passed' );
};

subtest 'F4: the generic path fails too -> one Algolia lookup; over budget RATE_LIMITED; cached renditions; one fallback only' => sub {
	my $setup = sub {
		my %with = @_;
		fresh();
		setEpisodeMeta( $SCIENCE, { path => $STALE_PATH, %{ $with{meta} || {} } } );
		route( data_url($STALE_PATH), error => 'Redirection without location' );
		serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
		serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );
	};

	$setup->();
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$SCIENCE_PATH" } ] } );
	my $r = answer( resolve_id($SCIENCE), 'lookup' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'the lookup names the page: plays' );
	is( scalar( algolia_requests() ), 1, '... after exactly one Algolia request' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url($STALE_PATH), data_url("/listen/programs/x/x/$SCIENCE"), data_url($SCIENCE_PATH) ], '... the cached path, the generic path, the page the hit names' );
	is( getEpisodeMeta($SCIENCE)->{path}, $SCIENCE_PATH, '... and the corrected path is cached' );

	$setup->();
	serve_algolia( { hits => [] } );
	Plugins::ABCListen::API::algolia( { query => "q$_" }, sub { }, sub { } ) for 1 .. 300;
	my $before = algolia_requests();
	is_deeply( answer( resolve_id($SCIENCE), 'budget' ), { error => $RATE_LIMITED }, 'Algolia budget used up: RATE_LIMITED' );
	is( scalar( algolia_requests() ), $before, '... without an Algolia request' );

	$setup->( meta => { renditions => [ { url => "$MEDIA/cached.mp3", mime => 'audio/mpeg' } ], seenAt => $T - 86400 } );
	route( $ALGOLIA, error => 'Connect timed out' );
	is_deeply( candidates( answer( resolve_id($SCIENCE), 'all fail' ) ), ["$MEDIA/cached.mp3"], 'everything fails: chosen from the renditions cached earlier' );

	$setup->();
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$STALE_PATH" } ] } );
	is_deeply( answer( resolve_id($SCIENCE), 'hit names the failing path' ), { error => $LOAD_FAILED }, 'the hit names the failing path: LOAD_FAILED' );
	is_deeply(
		[ map { $_->{url} } data_requests() ],
		[ data_url($STALE_PATH), data_url("/listen/programs/x/x/$SCIENCE"), data_url($STALE_PATH) ],
		'... one fallback only: the generic path is not tried again'
	);
	is( scalar( algolia_requests() ), 1, '... and one Algolia request' );
};

# ---- F6: the fallback from a failed cached path finds nothing -> the renditions cached earlier ----

subtest 'F6: cached path fails, then the id chain finds nothing -> the renditions cached earlier (any age), else NOT_FOUND' => sub {
	my $CACHED_MP3 = "$MEDIA/cached.mp3";
	my %STALE      = ( renditions => [ { url => $CACHED_MP3, mime => 'audio/mpeg' } ], seenAt => $T - 86400 );
	my $generic    = "/listen/programs/x/x/$SCIENCE";

	# the cached path answers 404; the generic path and the lookup as each case says
	my $setup = sub {
		my (%with) = @_;
		fresh();
		setEpisodeMeta( $SCIENCE, { path => $STALE_PATH, title => 'From the episode list', %{ $with{meta} || {} } } );
		route( data_url($STALE_PATH), code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
		if   ( $with{generic} ) { serve( $generic, $with{generic} ) }
		else                    { serve( $generic, fixture('ondemand/nextdata-generic-1-404.json'), code => 404 ) }
		serve_algolia( $with{algolia} || { hits => [], nbHits => 0 } );
		serve( $SCIENCE_PATH, $with{page} ) if $with{page};
		return resolve_id($SCIENCE);
	};

	my @cases = (
		[ 'generic 404, Algolia hits: [] (no hit)', [], [ $generic ], 1 ],
		[ 'generic 404, a hit for another id', [ algolia => { hits => [ { objectID => 'coremedia://audioepisode/999', canonicalURL => "$SITE$SCIENCE_PATH" } ] } ], [ $generic ], 1 ],
		[ 'generic 404, a hit with neither audio nor a page', [ algolia => { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE" } ] } ], [ $generic ], 1 ],
		[ 'the generic path serves a document that is not audio', [ generic => edit_doc( sub { $_[0]->{docType} = 'article'; $_[0]->{renditions} = [] } ) ], [ $generic ], 0 ],
		[
			'a second lookup needed (no document at the generic path, nor at the page the hit names)',
			[
				generic => { pageProps => { data => {} } },
				algolia => { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$SCIENCE_PATH" } ] },
				page    => { pageProps => { data => {} } },
			],
			[ $generic, $SCIENCE_PATH ],
			1,
		],
	);

	for my $case (@cases) {
		my ( $name, $with, $after, $lookups ) = @$case;

		my $r = answer( $setup->( @$with, meta => \%STALE ), $name );
		is_deeply( candidates($r), [$CACHED_MP3], "$name: plays cached.mp3" );
		is( $r->{meta}->{title}, 'From the episode list', "$name: with the cached metadata" );
		is( logged_like( WARN => qr/\Q$SCIENCE\E.*episode not found.*cached earlier/ ), 1, "$name: one WARN saying why" );
		is_deeply( [ map { $_->{url} } data_requests() ], [ map { data_url($_) } $STALE_PATH, @$after ], "$name: the cached path, then the id chain" );
		is( scalar( algolia_requests() ), $lookups, "$name: $lookups Algolia request(s)" );
		is( scalar( Slim::Utils::Timers::pending() ), 0, "$name: answered before the deadline (no timer left)" );

		# without cached renditions it is still NOT_FOUND (not LOAD_FAILED)
		is_deeply( answer( $setup->(@$with), "$name, nothing cached" ), { error => $NOT_FOUND }, "$name, no cached renditions: NOT_FOUND" );
		ok( logged_like( INFO => qr/\Q$SCIENCE\E.*episode not found/ ), "$name, no cached renditions: logged at INFO" );
	}

	# the cached renditions are chosen as always: closed windows answer EXPIRED
	my $r = answer( $setup->( meta => { %STALE, downloadAvailableTo => $T - 3600 } ), 'closed window' );
	is_deeply( $r, { error => $EXPIRED }, 'cached renditions whose window has closed: EXPIRED' );

	# NOT_FOUND without a failed cached path is unchanged: a cached path that serves a document
	# that isn't audio, and an episode with no cached path
	fresh();
	setEpisodeMeta( $SCIENCE, { %STALE, path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, edit_doc( sub { $_[0]->{docType} = 'article'; $_[0]->{renditions} = [] } ) );
	is_deeply( answer( resolve_id($SCIENCE), 'the cached path works' ), { error => $NOT_FOUND }, 'the cached path works but is not audio: NOT_FOUND' );
	is_deeply( [ map { $_->{url} } data_requests() ], [ data_url($SCIENCE_PATH) ], '... from that one request' );

	fresh();
	setEpisodeMeta( $SCIENCE, {%STALE} );
	serve( $generic, fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( { hits => [] } );
	is_deeply( answer( resolve_id($SCIENCE), 'no cached path' ), { error => $NOT_FOUND }, 'no cached path, generic 404, no hit: NOT_FOUND' );
};

subtest 'the 18 s deadline: one callback, the late result is cached' => sub {
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json'), defer => 1 );

	my $c = resolve_id($SCIENCE);
	is( $c->count, 0, 'no answer while the document is on its way' );
	advanceTime(17.9);
	is( $c->count, 0, 'none after 17.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered at 18 s (before the handler\'s 20 s)' );
	is_deeply( ( $c->args(0) )[0], { error => $LOAD_FAILED }, '... with LOAD_FAILED' );
	ok( logged_like( WARN => qr/18 s/ ), '... and a WARN' );

	is( Slim::Networking::SimpleAsyncHTTP->completeDeferred, 1, 'the document arrives late' );
	is( $c->count, 1, 'still exactly one callback' );
	is( getEpisodeMeta($SCIENCE)->{title}, $SCIENCE_TITLE, 'the late document is cached' );
	is( getEpisodeMeta($SCIENCE)->{seenAt}, $T + 18, '... with its renditions and seenAt' );

	# with renditions cached earlier, the deadline chooses from them
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH, renditions => [ { url => "$MEDIA/cached.mp3", mime => 'audio/mpeg' } ], seenAt => $T - 86400 } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json'), defer => 1 );
	$c = resolve_id($SCIENCE);
	advanceTime(18);
	is_deeply( candidates( ( $c->args(0) )[0] ), ["$MEDIA/cached.mp3"], 'deadline with cached renditions: chosen from them' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, '... one callback after the late document too' );

	# the slow chain: generic path, then the lookup, both slow
	fresh();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404, defer => 1 );
	serve_algolia( { hits => [] }, defer => 1 );
	$c = resolve_id($SCIENCE);
	advanceTime(10);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;    # the generic path fails at 10 s: lookup starts
	advanceTime(8);
	is_deeply( [ $c->count, ( $c->args(0) )[0] ], [ 1, { error => $LOAD_FAILED } ], 'slow chain: LOAD_FAILED at 18 s' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, '... and no second callback when the lookup ends' );

	# answered in time: the deadline timer is gone
	fresh();
	resolve_doc( doc('nextdata-episode-scienceshow-mp3.trimmed.json') );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'answered in time: no timer left' );
};

subtest 'invalid ids: NOT_FOUND at once, no HTTP' => sub {
	for my $id ( undef, '', 'abc', '12a', ' 1', "1\n", [] ) {
		fresh();
		my $label = defined $id ? ( ref $id ? 'a ref' : "'$id'" ) : 'undef';
		$label =~ s/\n/\\n/;
		is_deeply( answer( resolve_id($id), $label ), { error => $NOT_FOUND }, "$label: NOT_FOUND" );
		is( scalar( requests() ), 0, "$label: no request" );
	}
};

subtest 'two players resolve the same id at once: one request, each callback once' => sub {
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json'), defer => 1 );

	my ( $a, $b ) = ( resolve_id($SCIENCE), resolve_id($SCIENCE) );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;

	is( scalar( data_requests() ), 1, 'one _next/data request (coalesced by API.pm)' );
	is_deeply( [ map { candidates( answer( $_, 'player' ) ) } $a, $b ], [ [$SCIENCE_MP3], [$SCIENCE_MP3] ], 'both players get the MP3' );
};

subtest 'stale buildId: API.pm refreshes and retries; Episode makes one nextData call' => sub {
	fresh();
	@Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
	my $page = fixture('foundation/listen-search.trimmed.html');
	( my $newPage = $page ) =~ s/build-3afcd04f/build-0newdeploy/g;
	my @pages = ( $page, $newPage );
	Slim::Networking::SimpleAsyncHTTP->addRoute( $SEARCH, sub { { code => 200, content => ( @pages > 1 ? shift @pages : $pages[0] ), headers => $HTML_TYPE } } );
	route( data_url($SCIENCE_PATH), code => 404, file => 'foundation/next-data-404.html', headers => $HTML_TYPE );
	route( "$SITE/_next/data/build-0newdeploy$SCIENCE_PATH.json", content => $JSON->encode( doc('nextdata-episode-scienceshow-mp3.trimmed.json') ), headers => $JSON_TYPE );
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );

	is_deeply( candidates( answer( resolve_id($SCIENCE), 'buildId' ) ), [$SCIENCE_MP3], 'plays after the refresh' );
	is( scalar( data_requests() ), 2, 'two _next/data requests (old buildId, new buildId): the retry is API.pm\'s' );
};

subtest 'metadata cache write: contract-3 keys only, epochs, seenAt, merged over an existing entry' => sub {
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH, title => 'Old title', network => 'ABC Radio National', seenAt => $T - 99999 } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );
	answer( resolve_id($SCIENCE), 'write' );

	my $m = getEpisodeMeta($SCIENCE);
	is_deeply( [ sort grep { $_ ne 'network' } keys %$m ], \@META_KEYS, 'exactly the contract-3 keys (plus what others wrote)' );
	is( $m->{network}, 'ABC Radio National', 'a field written by someone else is kept' );
	is( $m->{title},   $SCIENCE_TITLE,       'a new value replaces the old one' );
	is( $m->{seenAt},  $T,                   'seenAt = now' );
	ok( ( !grep { defined $m->{$_} && $m->{$_} !~ /\A[0-9]+\z/ } qw(date availableTo downloadAvailableTo seenAt) ), 'times are epoch seconds' );
};

# ---- O6: AAC bitrates, stale renditions, request options ----

subtest 'O6 bitrate: AAC without one -> fileSize x 8 / duration / 1000 kbps; nothing derived otherwise' => sub {
	my $size = 117_936_000;    # x 8 / 3276 s (the Science Show's duration) / 1000 = 288 kbps

	fresh();
	resolve_doc( edit_doc( sub {
		$_[0]->{renditions} = [
			{ url => "$MEDIA/a.aac", MIMEType => 'audio/aac',  fileSize => $size },                  # no bitrate
			{ url => "$MEDIA/b.aac", MIMEType => 'audio/aac',  fileSize => $size, bitrate => 0 },
			{ url => "$MEDIA/c.aac", MIMEType => 'audio/aac',  fileSize => $size, bitrate => 96 },   # ABC's own: kept
			{ url => "$MEDIA/d.aac", MIMEType => 'audio/aac',  bitrate  => 0 },                      # no fileSize
			{ url => "$MEDIA/e.aac", MIMEType => 'audio/aac',  fileSize => 0, bitrate => 0 },        # zero fileSize
			{ url => "$MEDIA/f.mp3", MIMEType => 'audio/mpeg', fileSize => $size, bitrate => 0 },    # MP3: never derived
		];
	} ) );
	is_deeply( [ map { $_->{bitrate} } @{ getEpisodeMeta($SCIENCE)->{renditions} } ], [ 288, 288, 96, 0, 0, 0 ], 'derived for AAC with a fileSize only; ABC\'s bitrate and MP3s untouched' );
	is_deeply( [ map { $_->{fileSize} } @{ getEpisodeMeta($SCIENCE)->{renditions} } ], [ ($size) x 3, undef, undef, $size ], 'fileSize cached when positive' );

	for my $case ( [ 'duration 0', sub { $_[0]->{duration} = 0 } ], [ 'no duration', sub { delete $_[0]->{duration} } ] ) {
		fresh( iso('2026-10-20T12:00:00Z') );
		my $r = answer( resolve_doc( edit_doc( $case->[1], 'nextdata-episode-classic-drive-aac.trimmed.json' ), $DRIVE, $DRIVE_PATH ), $case->[0] );
		is( $r->{url}, $DRIVE_AAC, "$case->[0]: the AAC still plays" );
		is( getEpisodeMeta($DRIVE)->{renditions}->[0]->{bitrate}, 0, "$case->[0]: no bitrate derived (it stays unseekable, no error)" );
	}
};

subtest 'O6 Algolia: an AAC-only hit with different download and streaming windows (recorded Classic Drive hit)' => sub {
	for my $case (
		[ '2026-10-20T12:00:00Z', [$DRIVE_AAC], 'inside the streaming window' ],
		[ '2026-11-16T04:00:00Z', $EXPIRED,     'streaming window over: the download window (to 2200) is not the AAC\'s' ],
		[ '2026-10-19T03:59:59Z', $EXPIRED,     'before the windows open' ],
	) {
		my ( $when, $want, $name ) = @$case;
		fresh( iso($when) );
		serve( "/listen/programs/x/x/$DRIVE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
		serve_algolia( fixture('ondemand/algolia-objectid-107174638.json') );

		my $r = answer( resolve_id($DRIVE), $name );
		if ( ref $want ) { is_deeply( candidates($r), $want, "$name: the AAC" ) }
		else             { is_deeply( $r, { error => $want }, "$name: $want" ) }
		is( scalar( data_requests() ), 1, "$name: chosen from the hit (the page it names is not fetched)" );
	}

	fresh( iso('2026-10-20T12:00:00Z') );
	serve( "/listen/programs/x/x/$DRIVE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( fixture('ondemand/algolia-objectid-107174638.json') );
	answer( resolve_id($DRIVE), 'cached' );
	my $m = getEpisodeMeta($DRIVE);
	is_deeply( $m->{renditions}->[0], { url => $DRIVE_AAC, mime => 'audio/aac', bitrate => $DRIVE_KBPS, fileSize => $DRIVE_SIZE }, 'the hit\'s AAC: bitrate derived from its fileSize and duration' );
	is_deeply( [ @$m{qw(availableTo downloadAvailableTo image)} ], [ iso('2026-11-16T04:00:00+00:00'), $OPEN_END, $DRIVE_IMG ], 'both windows cached; the image is the defaultThumbnail 1x1' );
};

subtest 'O6 stale renditions: a restricted or not yet released document closes the cached windows -> fallback EXPIRED' => sub {
	my $seeded = {
		path        => $SCIENCE_PATH,
		renditions  => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192 } ],
		availableTo => $OPEN_END, downloadAvailableTo => $OPEN_END, seenAt => $T - 7 * 3600,    # seeded by Search, > 6 h ago
	};

	for my $case (
		[ 'restricted',       sub { $_[0]->{webDistributionRestricted} = JSON::PP::true },                                     $RESTRICTED ],
		[ 'not released yet', sub { $_[0]->{availableFrom} = $_[0]->{downloadAvailableFrom} = '2026-10-21T00:00:00+00:00' }, $EXPIRED ],
	) {
		my ( $name, $edit, $token ) = @$case;

		fresh();
		setEpisodeMeta( $SCIENCE, dclone($seeded) );
		serve( $SCIENCE_PATH, edit_doc($edit) );
		is_deeply( answer( resolve_id($SCIENCE), $name ), { error => $token }, "$name: $token" );

		my $entry = getEpisodeMeta($SCIENCE);
		is_deeply( [ @$entry{qw(availableTo downloadAvailableTo seenAt)} ], [ $T, $T, $T - 7 * 3600 ], "$name: both cached windows closed (now); seenAt kept" );

		# later, the document request fails: the cached renditions answer EXPIRED instead of playing
		fresh( $T + 60 );
		setEpisodeMeta( $SCIENCE, $entry );
		route( data_url($SCIENCE_PATH), error => 'Timed out waiting for data' );
		is_deeply( answer( resolve_id($SCIENCE), "$name, then a failed request" ), { error => $EXPIRED }, "$name, then a failed request: EXPIRED, not the seeded MP3" );

		# ... and so does the 18 s deadline
		fresh( $T + 60 );
		setEpisodeMeta( $SCIENCE, $entry );
		serve( $SCIENCE_PATH, edit_doc(), defer => 1 );
		my $c = resolve_id($SCIENCE);
		advanceTime(18);
		is_deeply( [ $c->count, ( $c->args(0) )[0] ], [ 1, { error => $EXPIRED } ], "$name, then no answer within 18 s: EXPIRED" );
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	}
};

subtest 'request options on every path: documents ttl 3600 + timeout 6 (the generic guess quiet), the lookup timeout 6' => sub {
	my @calls;
	my ( $nextData, $algolia ) = ( \&Plugins::ABCListen::API::nextData, \&Plugins::ABCListen::API::algolia );
	no warnings 'redefine';
	local *Plugins::ABCListen::API::nextData = sub { push @calls, [ nextData => $_[0], { %{ $_[3] || {} } } ]; goto &$nextData };
	local *Plugins::ABCListen::API::algolia  = sub { push @calls, [ algolia  => undef, { %{ $_[3] || {} } } ]; goto &$algolia };

	my %document = ( ttl => 3600, timeout => 6 );

	fresh();
	answer( resolve_doc( doc('nextdata-episode-scienceshow-mp3.trimmed.json') ), 'cached path' );
	is_deeply( \@calls, [ [ nextData => $SCIENCE_PATH, {%document} ] ], 'the cached path: ttl 3600, timeout 6, not quiet' );

	fresh();
	@calls = ();
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-1-404.json'), code => 404 );
	serve_algolia( { hits => [ { objectID => "coremedia://audioepisode/$SCIENCE", canonicalURL => "$SITE$SCIENCE_PATH" } ] } );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );
	answer( resolve_id($SCIENCE), 'generic, lookup, page' );
	is_deeply(
		\@calls,
		[
			[ nextData => "/listen/programs/x/x/$SCIENCE", { %document, quiet => 1 } ],
			[ algolia  => undef,                           { timeout => 6 } ],
			[ nextData => $SCIENCE_PATH,                   {%document} ],
		],
		'the generic path: ttl 3600, timeout 6, quiet; the Algolia lookup: timeout 6; the page the hit names: ttl 3600, timeout 6'
	);

	fresh();
	@calls = ();
	setEpisodeMeta( $SCIENCE, { path => $STALE_PATH } );
	route( data_url($STALE_PATH), error => 'Redirection without location' );
	serve( "/listen/programs/x/x/$SCIENCE", fixture('ondemand/nextdata-generic-107266790.json') );
	serve( $SCIENCE_PATH, doc('nextdata-episode-scienceshow-mp3.trimmed.json') );
	answer( resolve_id($SCIENCE), 'F4 fallback' );
	is_deeply(
		\@calls,
		[ [ nextData => $STALE_PATH, {%document} ], [ nextData => "/listen/programs/x/x/$SCIENCE", { %document, quiet => 1 } ] ],
		'F4 fallback: the cached path not quiet (a WARN), then the generic path quiet, both ttl 3600, timeout 6'
	);
};

done_testing();
