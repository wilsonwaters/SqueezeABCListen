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
#
# Fixtures in t/data/ondemand/ are raw response bodies as served:
#   nextdata-episode-scienceshow-mp3.trimmed.json   GET /_next/data/<buildId>/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790.json
#   nextdata-episode-classic-drive-aac.trimmed.json GET /_next/data/<buildId>/listen/programs/classic-drive/classic-drive/107174638.json
#   nextdata-episode-old-2024.trimmed.json          GET /_next/data/<buildId>/listen/programs/scienceshow/the-science-show/103022914.json
#       (research copies in ai-state/research/abc-samples/: the {_fixture_note, data} wrapper stripped,
#        data re-wrapped as {"pageProps": {"data": ...}}, shapes unedited)
#   nextdata-program-audiobook.trimmed.json         GET /_next/data/build-3afcd04f/listen/audiobooks/the-dictionary-of-lost-words-page.json
#       (research copy; its pageProps re-wrapped as {"pageProps": ...})
# Recorded for O1 (2026-10-19, OQ1 spike, buildId build-3afcd04f):
#   nextdata-generic-107266790.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/107266790.json (308 to the canonical page)
#   nextdata-generic-106353760.json   GET /_next/data/build-3afcd04f/listen/programs/x/x/106353760.json (audiobook chapter: 308 to its book)
#   nextdata-generic-1-404.json       GET /_next/data/build-3afcd04f/listen/programs/x/x/1.json (404 {"notFound":true})
#   algolia-objectid-106353760.json   POST .../1/indexes/listen_prod_all/query, the objectID lookup O1 sends for 106353760
#                                     (the Prologue chapter of algolia-audiobook-chapters.trimmed.json, with programTitle)
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

my $OLD      = '103022914';
my $OLD_PATH = '/listen/programs/scienceshow/the-science-show/103022914';
my $OLD_MP3  = "$MEDIA/audio/01/pp/Z/3i.mp3";
my $OLD_HERO = 'https://live-production.wcms.abc-cdn.net.au/23b56445f570798642596347fe3a35f9?impolicy=wcms_crop_resize&cropH=1362&cropW=1362&xPos=134&yPos=0&width=862&height=862';

my $CHAPTER      = '106353760';
my $CHAPTER_PATH = '/listen/audiobooks/the-dictionary-of-lost-words-page/prologue-february-1886/106353760';
my $BOOK_PATH    = '/listen/audiobooks/the-dictionary-of-lost-words-page';
my $CHAPTER_MP3  = "$MEDIA/geo-001/audio/02/j6/Z/rr.mp3";

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
			renditions          => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192 } ],
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
		[ { url => $DRIVE_AAC, mime => 'audio/aac', bitrate => 0 }, { url => $DRIVE_AAC, mime => 'application/vnd.apple.mpegurl', bitrate => 0 } ],
		'renditions normalised to {url, mime, bitrate}'
	);
	is( $m->{availableTo}, iso('2026-11-16T04:00:00+00:00'), 'availableTo as an epoch' );
};

subtest 'parse: 2024 episode (hero image wins; MP3 after availableTo)' => sub {
	fresh();
	my $r = answer( resolve_doc( doc('nextdata-episode-old-2024.trimmed.json'), $OLD, $OLD_PATH ), 'old' );

	is_deeply( candidates($r), [$OLD_MP3], 'MP3 still plays (downloadAvailableTo 2200) although availableTo passed in 2024' );
	my $m = getEpisodeMeta($OLD);
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
	is_deeply( getEpisodeMeta($SCIENCE)->{renditions}, [ { url => $SCIENCE_MP3, mime => 'audio/mpeg', bitrate => 192 } ], 'renditions replaced' );
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
			attributesToRetrieve => [qw(objectID canonicalURL title programTitle programID duration dates mediaRenditions)],
		},
		'the POST body holds the three-objectID filter, one hit, the attributes needed'
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
			date                => iso('2026-04-01T13:00:00+00:00'),
			duration            => 257,
			renditions          => [ { url => $CHAPTER_MP3, mime => 'audio/mpeg', bitrate => 320 } ],
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
	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH, title => 'Cached', renditions => [ { url => $SCIENCE_MP3, mime => 'audio/mpeg' } ], seenAt => $T - 30 * 86400 } );
	route( data_url($SCIENCE_PATH), error => 'Timed out waiting for data' );

	my $r = answer( resolve_id($SCIENCE), 'cached' );
	is_deeply( candidates($r), [$SCIENCE_MP3], 'network error with cached renditions: chosen from the cache' );
	is( $r->{meta}->{title}, 'Cached', '... with the cached metadata' );
	is( logged_like( WARN => qr/\Q$SCIENCE\E.*cached earlier/ ), 1, '... and one WARN' );

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	route( data_url($SCIENCE_PATH), error => 'Timed out waiting for data' );
	is_deeply( answer( resolve_id($SCIENCE), 'none' ), { error => $LOAD_FAILED }, 'without cached renditions: LOAD_FAILED' );

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, '{"pageProps": {"data": ' );
	is_deeply( answer( resolve_id($SCIENCE), 'bad JSON' ), { error => $LOAD_FAILED }, 'bad JSON: LOAD_FAILED' );

	fresh();
	setEpisodeMeta( $SCIENCE, { path => $SCIENCE_PATH } );
	serve( $SCIENCE_PATH, '{}', code => 500 );
	is_deeply( answer( resolve_id($SCIENCE), 'HTTP 500' ), { error => $LOAD_FAILED }, 'HTTP 500: LOAD_FAILED' );
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

done_testing();
