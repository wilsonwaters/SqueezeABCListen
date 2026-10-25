#!/usr/bin/perl
# L6 (#80): Plugins::ABCListen::HLS, offline.
#   * handles(): HLS playlist URLs only;
#   * playlists: ABC's master (captured) -> variants, chooseVariant (AAC only, highest bandwidth, video
#     skipped, relative URIs); ABC's media playlist (captured); EXT-X-DISCONTINUITY, EXT-X-ENDLIST,
#     EXT-X-KEY (AES-128 / SAMPLE-AES: encrypted; NONE: not), EXT-X-BYTERANGE, EXT-X-MAP, LL-HLS parts
#     ignored, CRLF and BOM, not a playlist;
#   * demuxers on recorded segment fixtures: MPEG-TS -> ADTS (ffmpeg-made sine segments and the first 40
#     packets of a triple j segment: byte for byte what `ffmpeg -c:a copy -f adts` gives), fed in odd
#     slices, resync after garbage, reset at a discontinuity, a TS without AAC; fragmented MP4 -> ADTS
#     (the same sine as fMP4: byte for byte), encrypted/broken init segments, HE-AAC / HE-AACv2 configs;
#     packed ADTS with ID3 tags; adtsInfo (bitrate, rate, channels);
#   * the stream (stub HTTP, fake clock): scanUrl prepares master -> variant -> media -> first segment
#     (LIVE_EDGE from the end), answers a remote track (aac, measured bitrate, rate, channels) and keeps
#     the stream for new(); scan failures (403, encrypted, byte ranges, no AAC variant, no AAC audio,
#     not a playlist, an unknown segment format, a master inside a master) answer (undef, error) at once
#     and keep nothing; playback: sysread (EINTR while waiting), at most one request at a time, the
#     next segment only below BUFFER_LOW, the playlist reloaded at the target duration (half of it when
#     unchanged), skipping ahead when the next segment left the window, a discontinuity resets the
#     demuxer, EXT-X-ENDLIST ends it, a failing segment is retried then skipped, failed reloads back off
#     (2, 4, 8 s) and end the stream after MAX_FAILURES; close drops the buffers and ignores a response
#     still in flight; no timers ever; the prepared streams are bounded (PREPARED_MAX, PREPARED_TTL);
#     every request has a timeout; an fMP4 stream end to end.
# Fixtures (t/data/hls): master-triplejnsw.m3u8 and media-triplejnsw-v0-221.m3u8 as ABC served them on
# 2026-10-25; triplejnsw-head.ts, the first 40 TS packets (0.2 s of audio) of one triple j segment;
# sine-*, a synthetic 440 Hz tone made with `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100:duration=3
# -ac 2 -c:a aac -b:a 48k -f hls -hls_time 1 -hls_segment_type mpegts` (and `fmp4`, init sine-init.mp4), 1 s
# per segment.

use strict;
use warnings;

use ABCListenTest qw(:all);
use Test::More;

use Digest::SHA qw(sha1_hex);
use Errno ();

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Schema;

use Plugins::ABCListen::HLS;

my $HLS = 'Plugins::ABCListen::HLS';

# what `ffmpeg -c:a copy -f adts` gives for the fixtures (sine-0..2 as TS or as fMP4: the same audio)
my $SINE_ADTS_SHA1 = 'd2095e16c954998ffdd9daa59955fe6a6099bfd2';
my $HEAD_ADTS_SHA1 = '7c0e0b394e22bc72a2ecf72dc335c6070eb1e2b0';    # triplejnsw-head.ts

my $MASTER = 'https://streaming.abc-cdn.net.au/audio/hls/triplejnsw.m3u8';
my $MEDIA  = 'https://mediaserviceslive.akamaized.net/hls/live/2109456/triplejnsw/v0-221.m3u8';
my $BASE   = 'https://mediaserviceslive.akamaized.net/hls/live/2109456/triplejnsw/';

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }
sub logged_like { my ( $level, $re ) = @_; return scalar grep { $_->{message} =~ $re } logged($level) }

sub sine_ts { fixture("hls/sine-$_[0].ts") }

sub concat_feed {
	my ( $demux, @chunks ) = @_;
	my $out = '';
	$out .= $demux->feed($_) for @chunks;
	return $out;
}

# Feed $data in odd-sized slices.
sub slices {
	my ( $data, @sizes ) = @_;
	my @out;
	my $i = 0;
	while ( length $data ) {
		push @out, substr( $data, 0, $sizes[ $i++ % @sizes ], '' );
	}
	return @out;
}

# A live media playlist: segments $first..$last as seg<N>.ts (relative URIs), target duration 1.
sub media {
	my ( $first, $last, %opts ) = @_;
	my $m = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:" . ( $opts{target} // 1 ) . "\n#EXT-X-MEDIA-SEQUENCE:$first\n";
	$m .= "#EXT-X-KEY:METHOD=$opts{key},URI=\"key.bin\"\n" if $opts{key};
	for my $n ( $first .. $last ) {
		$m .= "#EXT-X-DISCONTINUITY\n" if $opts{discontinuity} && $opts{discontinuity} == $n;
		$m .= "#EXTINF:1.0,\nseg$n.ts\n";
	}
	$m .= "#EXT-X-ENDLIST\n" if $opts{endList};
	return $m;
}

# Route the master, the media playlist (a code ref for live changes, or text) and seg<N>.ts -> sine-(N % 3).ts.
sub route_stream {
	my %opts = @_;
	route( $MASTER, file => 'hls/master-triplejnsw.m3u8' ) unless $opts{noMaster};
	my $media = $opts{media};
	route( $MEDIA, ref $media eq 'CODE' ? ( content => '' ) : ( content => $media ) ) if !ref $media;
	Slim::Networking::SimpleAsyncHTTP->addRoute( $MEDIA, sub { { code => 200, content => $media->() } } ) if ref $media eq 'CODE';
	for my $fail ( @{ $opts{failSegments} || [] } ) {
		route( "${BASE}seg$fail.ts", code => 404 );
	}
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\A\Q$BASE\Eseg(\d+)\.ts\z}, sub { my ($n) = $_[0] =~ /seg(\d+)\.ts/; { code => 200, content => sine_ts( $n % 3 ) } } );
	return;
}

sub urls { map { $_->{url} } requests() }
sub segment_requests { grep {/seg\d+\.ts\z/} urls() }
sub seq_of { map { /seg(\d+)\.ts\z/ ? $1 : () } @_ }

sub reset_all {
	resetStubs();
	Slim::Schema->reset;
	$HLS->_reset;
	setTime(1_792_900_000);
	Slim::Utils::Log->resetMessages;
	return;
}

# scanUrl($url) -> (collector, the prepared stream's track or undef)
sub scan {
	my $url = shift // $MASTER;
	my $c   = collector();
	$HLS->scanUrl( $url, { cb => $c->cb } );
	return $c;
}

# Read everything sysread gives now: (bytes, the last return value, $! after it)
sub drain {
	my ( $stream, $max ) = @_;
	my ( $all, $ret, $err ) = ('');
	for ( 1 .. 1000 ) {
		my $buf = '';
		$ret = $stream->sysread( $buf, $max || 4096 );
		$err = $! + 0;
		last unless $ret;
		$all .= $buf;
	}
	return ( $all, $ret, $err );
}

# ---- handles ----

subtest 'handles: HLS playlist URLs only' => sub {
	ok( $HLS->handles($_), "yes: $_" ) for $MASTER, "$MASTER?source=web", 'http://example.test/a/b.M3U8', 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8#x';
	ok( !$HLS->handles($_), 'no: ' . ( defined $_ ? ( ref $_ ? 'a ref' : "'$_'" ) : 'undef' ) ) for undef, '', [], 'abclisten://live/TRIPLEJ', 'https://abc.streamguys1.com/live/triplejnsw/icecast.audio', 'https://example.test/x.m3u8.aac', 'https://example.test/?a=x.m3u8', 'ftp://example.test/x.m3u8', 'https://example.test/m3u8/x.aac';
};

# ---- playlists ----

subtest 'master playlist (ABC, captured): variants and chooseVariant' => sub {
	my $p = Plugins::ABCListen::HLS::parsePlaylist( fixture('hls/master-triplejnsw.m3u8'), $MASTER );
	is( $p->{type}, 'master', 'a master playlist' );
	is_deeply(
		$p->{variants},
		[
			{ url => "${BASE}v0-221.m3u8", bandwidth => 246000, codecs => 'mp4a.40.2' },
			{ url => "${BASE}v0-222.m3u8", bandwidth => 112000, codecs => 'mp4a.40.29' },
		],
		'two variants: URL, AVERAGE-BANDWIDTH, CODECS'
	);
	is( Plugins::ABCListen::HLS::chooseVariant( $p->{variants} )->{url}, "${BASE}v0-221.m3u8", 'chooseVariant: AAC LC 246 kbps over HE-AACv2 112 kbps' );

	my $relative = Plugins::ABCListen::HLS::parsePlaylist( qq{#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=66981,CODECS="mp4a.40.2"\naudio.m3u8?nimblesessionid=801608\n}, 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8' );
	is_deeply( $relative->{variants}, [ { url => 'https://abc-hls.streamguys1.com/hls/sport-sync/audio.m3u8?nimblesessionid=801608', bandwidth => 66981, codecs => 'mp4a.40.2' } ], 'relative URI resolved (query kept); BANDWIDTH without AVERAGE-BANDWIDTH' );

	my $choose = sub { my $v = Plugins::ABCListen::HLS::chooseVariant(shift); $v && $v->{url} };
	is( $choose->( [ { url => 'v', bandwidth => 900000, codecs => 'avc1.4d401f,mp4a.40.2' }, { url => 'a', bandwidth => 64000, codecs => 'mp4a.40.2' } ] ), 'a', 'video variants skipped' );
	is( $choose->( [ { url => 'n', bandwidth => 1000 }, { url => 'm', bandwidth => 500, codecs => 'mp4a.40.5' } ] ), 'n', 'a variant without CODECS counts as audio' );
	is( $choose->( [ { url => 'v', bandwidth => 1, codecs => 'avc1.4d401f' }, { url => 'o', bandwidth => 1, codecs => 'opus' } ] ), undef, 'no AAC variant: undef' );
	is( $choose->( [] ), undef, 'no variants: undef' );
	is( $choose->(undef), undef, 'undef: undef' );
};

subtest 'media playlist (ABC, captured): live window' => sub {
	my $p = Plugins::ABCListen::HLS::parsePlaylist( fixture('hls/media-triplejnsw-v0-221.m3u8'), $MEDIA );
	is( $p->{type},           'media',   'a media playlist' );
	is( $p->{targetDuration}, 11,        'target duration 11' );
	is( $p->{sequence},       5621861,   'media sequence' );
	is( $p->{endList},        0,         'live: no EXT-X-ENDLIST' );
	is( $p->{encrypted},      undef,     'not encrypted' );
	is( $p->{byteRange},      0,         'no byte ranges' );
	is( scalar @{ $p->{segments} }, 6, '6 segments (a 60 s window)' );
	is_deeply( $p->{segments}->[0], { seq => 5621861, url => "${BASE}v0_221_d5621861.ts", duration => 9.9846, discontinuity => 0, map => undef }, 'first segment: seq, absolute URL, duration' );
	is_deeply( [ map { $_->{seq} } @{ $p->{segments} } ], [ 5621861 .. 5621866 ], 'sequence numbers' );
};

subtest 'media playlist tags: discontinuity, endlist, keys, byte ranges, map, LL-HLS parts, CRLF/BOM' => sub {
	my $parse = sub { Plugins::ABCListen::HLS::parsePlaylist( shift, 'https://h.example.test/live/media.m3u8' ) };

	my $p = $parse->( media( 10, 13, discontinuity => 12, endList => 1 ) );
	is_deeply( [ map { $_->{discontinuity} } @{ $p->{segments} } ], [ 0, 0, 1, 0 ], 'EXT-X-DISCONTINUITY flags the next segment only' );
	is( $p->{endList}, 1, 'EXT-X-ENDLIST' );

	is( $parse->( media( 1, 2, key => 'AES-128' ) )->{encrypted},    'AES-128',    'EXT-X-KEY AES-128: encrypted' );
	is( $parse->( media( 1, 2, key => 'SAMPLE-AES' ) )->{encrypted}, 'SAMPLE-AES', 'EXT-X-KEY SAMPLE-AES: encrypted' );
	is( $parse->( media( 1, 2, key => 'NONE' ) )->{encrypted},       undef,        'EXT-X-KEY METHOD=NONE: not encrypted' );
	is( $parse->("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:1,\na.ts\n")->{encrypted}, undef, 'a key turned off before the first segment: not encrypted' );
	is( $parse->( "#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:1000" . '@0' . "\nall.ts\n" )->{byteRange}, 1, 'EXT-X-BYTERANGE: byte ranges' );

	my $ll = $parse->( join "\n", '#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-TARGETDURATION:7', '#EXT-X-MEDIA-SEQUENCE:250404', '#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=6.06', '#EXT-X-PART-INF:PART-TARGET=2.021',
		'#EXT-X-MAP:URI="audio_1.fmp4?nimblesessionid=1"', '#EXT-X-PROGRAM-DATE-TIME:2026-10-25T00:30:36.691Z', '#EXTINF:6.014,', 'a_250404.fmp4?nimblesessionid=1', '#EXTINF:5.99,', 'a_250405.fmp4?nimblesessionid=1',
		'#EXT-X-PART:DURATION=2.021,URI="a_250406_0.fmp4?nimblesessionid=1"', '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="a_250406_1.fmp4?nimblesessionid=1"', '' );
	is_deeply( [ map { $_->{url} } @{ $ll->{segments} } ], [ map {"https://h.example.test/live/a_$_.fmp4?nimblesessionid=1"} 250404, 250405 ], 'LL-HLS (StreamGuys Sport Rapid): full segments only, parts and hints ignored' );
	is_deeply( [ map { $_->{map} } @{ $ll->{segments} } ], [ ('https://h.example.test/live/audio_1.fmp4?nimblesessionid=1') x 2 ], 'EXT-X-MAP: the init segment of the following segments (absolute)' );

	my $crlf = $parse->( "\xEF\xBB\xBF#EXTM3U\r\n#EXT-X-TARGETDURATION:10\r\n#EXTINF:10,\r\n  a.ts  \r\n" );
	is_deeply( [ map { $_->{url} } @{ $crlf->{segments} } ], ['https://h.example.test/live/a.ts'], 'BOM, CRLF and blanks around a URI' );

	is( $parse->($_), undef, 'not a playlist: ' . ( defined $_ ? "'$_'" : 'undef' ) ) for undef, '', "<html>Access Denied</html>", "EXTM3U\n#EXTINF:1,\na.ts\n";
	is_deeply( $parse->("#EXTM3U\n#EXT-X-TARGETDURATION:10\n")->{segments}, [], 'no segments: an empty list' );
};

# ---- demuxers ----

subtest 'TS -> ADTS: ffmpeg-made sine segments, fed in odd slices' => sub {
	my $ts  = join '', map { sine_ts($_) } 0 .. 2;
	my $d   = Plugins::ABCListen::HLS::TS->new;
	my $out = concat_feed( $d, slices( $ts, 1, 187, 189, 1000, 5000, 3 ) );
	is( $d->error, undef, 'no error' );
	is( sha1_hex($out), $SINE_ADTS_SHA1, 'byte for byte what ffmpeg -c:a copy -f adts gives' );

	my $info = Plugins::ABCListen::HLS::adtsInfo($out);
	is( $info->{sampleRate}, 44100, '44100 Hz' );
	is( $info->{channels},   2,     'stereo' );
	is( $info->{frames},     130,   '130 frames (3 s)' );
	is( $info->{bitrate},    48000, 'about 48 kbps' );

	is( concat_feed( Plugins::ABCListen::HLS::TS->new, "\x00garbage" . substr( $ts, 0, 3 ) . $ts ), $out, 'garbage and a broken packet before the stream: resynced, the same audio' );
};

subtest 'TS -> ADTS: a recorded triple j segment (first 40 packets: PAT, PMT, PCR PID, ADTS on PID 0xDD)' => sub {
	my $d   = Plugins::ABCListen::HLS::TS->new;
	my $out = $d->feed( fixture('hls/triplejnsw-head.ts') );
	is( $d->error, undef, 'no error' );
	is( $d->{pmt},   0x100, 'PMT on PID 0x100' );
	is( $d->{audio}, 0xDD,  'ADTS AAC (stream type 0x0F) on PID 0xDD' );
	is( sha1_hex($out), $HEAD_ADTS_SHA1, 'byte for byte what ffmpeg gives' );
	my $info = Plugins::ABCListen::HLS::adtsInfo($out);
	is( $info->{frames}, 9, '9 whole AAC frames (the 10th is cut off with the packets)' );
	is( $info->{sampleRate} . '/' . $info->{channels}, '44100/2', '44100 Hz stereo' );
};

subtest 'TS: reset (a discontinuity) forgets the layout and starts at an ADTS frame; a TS without AAC' => sub {
	my $d = Plugins::ABCListen::HLS::TS->new;
	$d->feed( sine_ts(0) );
	my $partial = substr( sine_ts(1), 0, 188 * 7 + 50 );
	$d->feed($partial);
	$d->reset;
	is_deeply( [ @$d{qw(buf pmt audio)} ], [ '', undef, undef ], 'reset: no partial packet, no PIDs' );
	my $out = $d->feed( sine_ts(2) );
	like( $out, qr/\A\xFF[\xF0-\xF1]/, 'after a reset the output starts at an ADTS frame' );
	ok( Plugins::ABCListen::HLS::adtsInfo($out), 'and is whole AAC frames' );

	# rewrite the PMT's stream type 0x0F (PID 0x100) -> 0x03 (MPEG audio): no AAC
	my $mp3 = sine_ts(0);
	my $at  = index( $mp3, "\x0F\xE1\x00" );
	ok( $at > 0 && $at < 188 * 4, 'the fixture\'s PMT lists stream type 0x0F for PID 0x100' ) or return;
	substr( $mp3, $at, 1, "\x03" );
	$d = Plugins::ABCListen::HLS::TS->new;
	is( $d->feed($mp3), '', 'no AAC stream: no output' );
	like( $d->error, qr/no ADTS AAC stream .*0x03/, 'error names the stream types' );
};

subtest 'fMP4 -> ADTS: the same sine as fragmented MP4 (init + 3 segments)' => sub {
	my $d = Plugins::ABCListen::HLS::FMP4->new( fixture('hls/sine-init.mp4') );
	is( $d->error, undef, 'init segment parsed' );
	is_deeply( $d->{config}, { profile => 1, rateIndex => 4, channels => 2 }, 'AAC LC, 44100 Hz (index 4), 2 channels' );
	is( $d->{track}, 1, 'track 1' );

	my $out = concat_feed( $d, map { fixture("hls/sine-$_.m4s") } 0 .. 2 );
	is( sha1_hex($out), $SINE_ADTS_SHA1, 'byte for byte what ffmpeg gives (and the same audio as the TS)' );
	is( $d->feed(''), '', 'an empty segment: nothing' );
	is( $d->feed('junk'), '', 'not boxes: nothing' );
};

subtest 'fMP4: unsupported init segments, HE-AAC configs' => sub {
	my $init = fixture('hls/sine-init.mp4');
	like( Plugins::ABCListen::HLS::FMP4->new(undef)->error, qr/no initialisation segment/, 'no init segment' );
	like( Plugins::ABCListen::HLS::FMP4->new('not mp4')->error, qr/no moov/, 'not MP4' );
	( my $enca = $init ) =~ s/mp4a/enca/;
	like( Plugins::ABCListen::HLS::FMP4->new($enca)->error, qr/'enca'/, 'an encrypted sample entry (enca)' );
	( my $video = $init ) =~ s/soun/vide/;
	like( Plugins::ABCListen::HLS::FMP4->new($video)->error, qr/no AAC sound track/, 'no sound track' );
	is( Plugins::ABCListen::HLS::FMP4->new($enca)->feed( fixture('hls/sine-0.m4s') ), '', 'a broken demuxer outputs nothing' );

	my $config = sub { Plugins::ABCListen::HLS::FMP4::_audioConfig( pack 'B*', shift ) };
	is_deeply( $config->('0001001000010000'),            { profile => 1, rateIndex => 4, channels => 2 }, 'AAC LC 44.1 kHz stereo (0x1210)' );
	# aot (5 bits), rate index (4), channels (4), extension rate index (4), core aot (5)
	is_deeply( $config->( '00101' . '0110' . '0010' . '0011' . '00010' . '000' ), { profile => 1, rateIndex => 6, channels => 2 }, 'HE-AAC (SBR, 5), 24 kHz core / 48 kHz: signalled as its AAC LC core' );
	is_deeply( $config->( '11101' . '0110' . '0001' . '0011' . '00010' . '000' ), { profile => 1, rateIndex => 6, channels => 1 }, 'HE-AACv2 (PS, 29), mono core: AAC LC core' );
	is( $config->('0001011110000000000000000000000000000000'), undef, 'an explicit 24-bit sample rate: unsupported' );
	is( $config->('0001001000000000'), undef, 'channel configuration 0 (PCE): unsupported' );
	is( $config->('00010'), undef, 'too short' );
};

subtest 'packed audio: ID3 tags dropped, ADTS passed through' => sub {
	my $adts = Plugins::ABCListen::HLS::TS->new->feed( sine_ts(0) );
	my $id3  = 'ID3' . pack( 'C3', 4, 0, 0 ) . pack( 'C4', 0, 0, 0, 5 ) . 'xxxxx';
	my $id3f = 'ID3' . pack( 'C3', 4, 0, 0x10 ) . pack( 'C4', 0, 0, 0, 2 ) . 'yy' . ( '3DI' . "\0" x 7 );
	my $p    = Plugins::ABCListen::HLS::Packed->new;
	is( $p->feed( $id3 . $adts ), $adts, 'an ID3v2 tag before the frames is dropped' );
	is( $p->feed( $id3 . $id3f . $adts ), $adts, 'two tags, one with a footer' );
	is( $p->feed($adts), $adts, 'no tag: unchanged' );
	is( Plugins::ABCListen::HLS::_format( $id3 . $adts ), 'packed', 'format: packed (ID3)' );
	is( Plugins::ABCListen::HLS::_format($adts),          'packed', 'format: packed (ADTS)' );
	is( Plugins::ABCListen::HLS::_format( sine_ts(0) ),   'ts',     'format: ts' );
	is( Plugins::ABCListen::HLS::_format($_),             undef,    'format: unknown' ) for '', undef, fixture('hls/sine-0.m4s'), '<html>';
};

subtest 'adtsInfo' => sub {
	is( Plugins::ABCListen::HLS::adtsInfo($_), undef, 'no frames: undef' ) for undef, '', 'garbage', "\xFF\xF1\x50\x80";
	my $frame = Plugins::ABCListen::HLS::_adtsHeader( 1, 4, 2, 100 ) . ( "\0" x 100 );
	my $info  = Plugins::ABCListen::HLS::adtsInfo( $frame x 43 );
	is( $info->{frames}, 43, 'whole frames counted' );
	is( $info->{bitrate}, 34000, 'payload bitrate, rounded to kbps (4300 bytes in 43 x 1024 / 44100 s: 34.45 kbps)' );
	is( Plugins::ABCListen::HLS::adtsInfo( ( $frame x 2 ) . substr( $frame, 0, 50 ) )->{frames}, 2, 'a cut-off last frame is not counted' );
};

# ---- the stream ----

subtest 'scanUrl: master -> variant -> media -> first segment (3 from the end); a remote track; kept for new()' => sub {
	reset_all();
	route_stream( media => media( 100, 105 ) );

	my $c = scan();
	is( $c->count, 1, 'one callback' );
	my ( $track, $error ) = $c->args(0);
	is( $error, undef, 'no error' );
	isa_ok( $track, 'Slim::Schema::RemoteTrack' );
	is( $track->url,          $MASTER, 'the track of the master URL' );
	is( $track->content_type, 'aac',   'content type aac' );
	is( $track->bitrate,      48000,   'bitrate measured from the first segment (48 kbps)' );
	is( $track->samplerate,   44100,   'sample rate' );
	is( $track->channels,     2,       'channels' );
	is_deeply( [ ( urls() )[ 0 .. 2 ] ], [ $MASTER, $MEDIA, "${BASE}seg103.ts" ], 'master, the 246 kbps variant, then segment 103 (LIVE_EDGE 3 before the end)' );
	is( $HLS->_prepared, 1, 'one prepared stream kept' );
	is_deeply( [ map { $_->{params}->{timeout} } requests() ], [ 10, 10, map {20} 3 .. scalar( requests() ) ], 'timeouts: 10 s for playlists, 20 s for segments' );
	ok( logged_like( INFO => qr/plays ts AAC, 44100 Hz, 2 channel\(s\), 48 kbps/ ), 'the format logged at INFO' );

	my $stream = $HLS->new( { url => $MASTER } );
	isa_ok( $stream, $HLS );
	is( $HLS->_prepared, 0, 'new() took the prepared stream' );
	is( $stream->contentType, 'aac', 'contentType aac' );
	is( $stream->bitrate, 48000, 'bitrate' );
	ok( !$stream->opened, 'no file descriptor' );

	my ($audio) = drain($stream);
	like( $audio, qr/\A\xFF\xF1/, 'sysread gives ADTS, from the prepared segment on' );
	is( Plugins::ABCListen::HLS::adtsInfo($audio)->{frames}, 130, 'segments 103-105: 3 s of audio' );
	is_deeply( [ seq_of( segment_requests() ) ], [ 103, 104, 105 ], 'each segment fetched once, in order' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timers' );
	is( $HLS->new( { url => 'https://example.test/x.aac' } ), undef, 'new() of a URL that is not HLS: undef' );
};

subtest 'scan failures answer (undef, error) at once, keep nothing, and log no WARN' => sub {
	my %cases = (
		'geo-blocked media playlist (403)' => [ [ media => sub { } ], qr/403/ ],
		'encrypted (AES-128)'              => [ [ media => media( 1, 6, key => 'AES-128' ) ], qr/encrypted stream \(EXT-X-KEY AES-128\) not supported/ ],
		'byte ranges'                      => [ [ media => "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n#EXT-X-BYTERANGE:100\nseg1.ts\n" ], qr/byte-range segments not supported/ ],
		'no segments'                      => [ [ media => "#EXTM3U\n#EXT-X-TARGETDURATION:1\n" ], qr/the playlist has no segments/ ],
		'not a playlist'                   => [ [ media => '<html>Access Denied</html>' ], qr/not an HLS playlist/ ],
		'a master inside the master'       => [ [ media => fixture('hls/master-triplejnsw.m3u8') ], qr/a master playlist inside a master playlist/ ],
		'segment 404'                      => [ [ media => media( 1, 6 ), failSegments => [4] ], qr/404/ ],
		'unknown segment format'           => [ [ media => media( 1, 6 ), segment => '<html>' ], qr/unsupported segment format/ ],
		'no AAC audio in the segment'      => [ [ media => media( 1, 6 ), segment => "\x47" . ( "\xFF" x 187 ) ], qr/no AAC audio in the first segment/ ],
	);

	for my $case ( sort keys %cases ) {
		my ( $opts, $re ) = @{ $cases{$case} };
		my %opts = @$opts;
		reset_all();
		if ( ref $opts{media} eq 'CODE' ) {
			route( $MASTER, file => 'hls/master-triplejnsw.m3u8' );
			route( $MEDIA, code => 403 );
		}
		else {
			route( "${BASE}seg4.ts", content => $opts{segment} ) if defined $opts{segment};
			route_stream(%opts);
		}

		my $c = scan();
		is( $c->count, 1, "$case: one callback" );
		my ( $track, $error ) = $c->args(0);
		is( $track, undef, "$case: no track" );
		like( $error, qr/\AHLS: .*$re/, "$case: the error says why" );
		is( $HLS->_prepared, 0, "$case: nothing kept" );
		is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, "$case: no WARN or ERROR (the protocol handler logs the fallback)" );
		ok( logged_like( INFO => qr/can't be played/ ), "$case: logged at INFO" );
	}

	reset_all();
	route( $MASTER, content => qq{#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401f,mp4a.40.2"\nvideo.m3u8\n} );
	my ( undef, $error ) = scan()->args(0);
	like( $error, qr/no AAC audio variant/, 'a master without an AAC variant' );
	is( scalar( requests() ), 1, '... nothing else fetched' );

	reset_all();
	my ( $t, $e ) = scan('https://example.test/stream.aac')->args(0);
	like( $e, qr/not an HLS URL/, 'scanUrl of a URL that is not HLS' );
	is( scalar( requests() ), 0, '... no request' );
};

subtest 'live playback: buffer bound, playlist reloads at the target duration, EINTR while waiting' => sub {
	reset_all();
	my ( $first, $last ) = ( 100, 105 );
	route_stream( media => sub { media( $first, $last ) } );
	scan();
	my $stream = $HLS->new( { url => $MASTER } );

	my ( undef, $ret, $err ) = drain($stream);
	is( $ret, undef, 'all known segments read: sysread returns undef' );
	is( $err, Errno::EINTR(), '... with $! = EINTR (LMS tries again)' );
	my $loads = sub { scalar grep { $_ eq $MEDIA } urls() };
	is( $loads->(), 1, 'the playlist is not reloaded before its target duration' );

	advanceTime(0.5);
	drain($stream);
	is( $loads->(), 1, 'still not at 0.5 s' );

	advanceTime(0.6);
	drain($stream);
	is( $loads->(), 2, 'reloaded after the target duration (1 s)' );
	is( scalar( segment_requests() ), 3, 'unchanged: no new segment' );

	advanceTime(0.4);
	drain($stream);
	is( $loads->(), 2, 'unchanged: not reloaded before half the target duration' );
	$last = 106;
	advanceTime(0.2);
	my ($audio) = drain($stream);
	is( $loads->(), 3, 'reloaded after half the target duration' );
	is_deeply( [ seq_of( segment_requests() ) ], [ 103 .. 106 ], 'the new segment 106 fetched' );
	ok( length $audio, '... and read' );

	# the buffer bound: with large segments, one is fetched only when the audio buffered runs low
	reset_all();
	my $big = join '', map { sine_ts( $_ % 3 ) } 1 .. 30;    # about 64 KB of ADTS per segment... in 214 KB of TS
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{seg\d+\.ts\z}, { code => 200, content => $big } );
	route_stream( media => media( 1, 6 ) );
	scan();
	$stream = $HLS->new( { url => $MASTER } );
	my $v = Plugins::ABCListen::HLS::_v($stream);
	my ( $maxOut, $maxPending, $reads ) = ( 0, 0, 0 );
	for ( 1 .. 400 ) {
		my $buf = '';
		my $n   = $stream->sysread( $buf, 2048 );
		$reads++;
		$maxOut     = length $v->{out}     if length $v->{out} > $maxOut;
		$maxPending = length $v->{pending} if length $v->{pending} > $maxPending;
		last unless $n;
	}
	ok( $maxOut <= Plugins::ABCListen::HLS::BUFFER_LOW + length($big), "audio buffered stays below BUFFER_LOW + one segment ($maxOut bytes)" );
	ok( $maxPending <= length $big, "at most one segment waiting to be demuxed ($maxPending bytes)" );
	is_deeply( [ seq_of( segment_requests() ) ], [ 4, 5, 6 ], 'segments fetched one at a time as the buffer drained' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timers' );
};

subtest 'a long pause: the next segment has left the window -> skip ahead (INFO), demuxer reset' => sub {
	reset_all();
	my ( $first, $last ) = ( 100, 105 );
	route_stream( media => sub { media( $first, $last ) } );
	scan();
	my $stream = $HLS->new( { url => $MASTER } );
	drain($stream);

	( $first, $last ) = ( 200, 205 );    # paused for minutes
	advanceTime(5);
	my ($audio) = drain($stream);
	is_deeply( [ seq_of( segment_requests() ) ], [ 103, 104, 105, 203, 204, 205 ], 'skipped to 203 (3 before the end)' );
	ok( logged_like( INFO => qr/segment 106 of .* is not in the playlist \(200-205\); skipping to 203/ ), 'logged at INFO' );
	like( $audio, qr/\A\xFF\xF1/, 'the audio after the skip starts at an ADTS frame' );

	( $first, $last ) = ( 0, 5 );    # the server restarted its numbering
	advanceTime(5);
	drain($stream);
	is_deeply( [ ( seq_of( segment_requests() ) )[ -3 .. -1 ] ], [ 3, 4, 5 ], 'numbering restarted: skipped to 3' );
};

subtest 'discontinuity resets the demuxer; EXT-X-ENDLIST ends the stream' => sub {
	reset_all();
	route_stream( media => media( 1, 5, discontinuity => 4, endList => 1 ) );
	scan();
	my $stream = $HLS->new( { url => $MASTER } );
	my $frames = 0;
	$frames += Plugins::ABCListen::HLS::adtsInfo( Plugins::ABCListen::HLS::TS->new->feed( sine_ts( $_ % 3 ) ) )->{frames} for 1 .. 5;

	my $resets = 0;
	my ( $audio, $ret );
	{
		no warnings 'redefine';
		my $orig = \&Plugins::ABCListen::HLS::TS::reset;
		local *Plugins::ABCListen::HLS::TS::reset = sub { $resets++; $orig->(@_) };
		( $audio, $ret ) = drain($stream);
	}
	is( $ret, 0, 'EXT-X-ENDLIST: sysread returns 0 after the last segment' );
	is_deeply( [ seq_of( segment_requests() ) ], [ 1 .. 5 ], 'a finished playlist plays from its first segment' );
	is( Plugins::ABCListen::HLS::adtsInfo($audio)->{frames}, $frames, "all five segments read ($frames frames)" );
	is( $resets, 1, 'the discontinuity before segment 4 reset the demuxer once' );
	ok( logged_like( INFO => qr/end of .*: end of the playlist/ ), 'the end logged at INFO' );
	my $buf;
	is( $stream->sysread( $buf, 10 ), 0, 'and stays at 0' );
};

subtest 'failures while playing: a segment retried then skipped; reloads back off and end the stream' => sub {
	reset_all();
	my ( $first, $last ) = ( 1, 6 );
	route_stream( media => sub { media( $first, $last ) }, failSegments => [5] );
	scan();
	my $stream = $HLS->new( { url => $MASTER } );
	drain($stream);
	is_deeply( [ seq_of( segment_requests() ) ], [ 4, 5 ], 'segment 5 failed once' );
	my $loads = sub { scalar grep { $_ eq $MEDIA } urls() };
	is( $loads->(), 1, '... the playlist loaded once so far' );
	advanceTime(2.1);
	drain($stream);
	is_deeply( [ seq_of( segment_requests() ) ], [ 4, 5, 5 ], 'after 2 s: the playlist reloaded first, then segment 5 retried (failed again: skipped)' );
	is( $loads->(), 2, '... the playlist reloaded before the retry' );
	ok( logged_like( INFO => qr/skipping segment 5/ ), 'the skip logged at INFO' );
	advanceTime(2.1);
	drain($stream);
	is_deeply( [ seq_of( segment_requests() ) ], [ 4, 5, 5, 6 ], 'then segment 6' );

	# the playlists go away (an outage)
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( $_, error => 'Timed out waiting for data' ) for $MEDIA, $MASTER;
	my $tries = sub { [ grep { $_ eq $MEDIA || $_ eq $MASTER } urls() ] };
	advanceTime(1.1);
	drain($stream);
	is_deeply( $tries->(), [$MEDIA], 'reload 1 (the media playlist) failed' );
	advanceTime(1.9);
	drain($stream);
	is( scalar @{ $tries->() }, 1, '... next try not before 2 s' );
	advanceTime(0.2);
	drain($stream);
	is_deeply( $tries->(), [ $MEDIA, $MASTER ], 'try 2 after 2 s, through the master playlist (failed)' );
	advanceTime(4.1);
	drain($stream);
	is( scalar @{ $tries->() }, 3, 'try 3 after 4 s (failed)' );
	advanceTime(8.1);
	my ( undef, $ret ) = drain($stream);
	is_deeply( $tries->(), [ $MEDIA, $MASTER, $MASTER, $MASTER ], 'try 4 after 8 s (failed)' );
	is( $ret, 0, 'after MAX_FAILURES (4) failed requests in a row the stream ends: sysread 0' );
	advanceTime(60);
	drain($stream);
	is( scalar @{ $tries->() }, 4, 'no more requests' );
	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'no WARN or ERROR' );
};

subtest 'a failed reload goes through the master playlist again: a new session (StreamGuys Nimble)' => sub {
	reset_all();
	my $master  = 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8';
	my $base    = 'https://abc-hls.streamguys1.com/hls/sport-sync/';
	my $session = 0;
	my %dead;
	Slim::Networking::SimpleAsyncHTTP->addRoute( $master, sub { $session++; { code => 200, content => qq{#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=66981,CODECS="mp4a.40.2"\naudio.m3u8?nimblesessionid=$session\n} } } );
	my ( $first, $last ) = ( 1, 6 );
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{audio\.m3u8\?nimblesessionid=(\d+)\z}, sub {
		my ($s) = $_[0] =~ /=(\d+)\z/;
		return { code => 403 } if $dead{$s};
		{ code => 200, content => join( '', "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:$first\n", map {"#EXTINF:1.0,\nseg$_.ts?nimblesessionid=$s\n"} $first .. $last ) };
	} );
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{seg(\d+)\.ts\?nimblesessionid=(\d+)\z}, sub {
		my ( $n, $s ) = $_[0] =~ /seg(\d+)\.ts\?nimblesessionid=(\d+)/;
		return { code => 403 } if $dead{$s};
		{ code => 200, content => sine_ts( $n % 3 ) };
	} );

	scan($master);
	my $stream = $HLS->new( { url => $master } );
	drain($stream);
	is( $session, 1, 'one session' );

	$dead{1} = 1;    # the session expires
	$last = 7;
	advanceTime(1.1);
	drain($stream);
	advanceTime(2.1);
	my ($audio) = drain($stream);
	is( $session, 2, 'after the failed reload: the master playlist again, a new session' );
	ok( ( grep {/seg7\.ts\?nimblesessionid=2\z/} urls() ), 'segment 7 fetched with the new session' );
	ok( length $audio, '... and played' );
	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'no WARN or ERROR' );
};

subtest 'close: buffers dropped, a response in flight ignored, no further requests' => sub {
	reset_all();
	route_stream( media => media( 1, 6 ) );
	scan();
	my $stream = $HLS->new( { url => $MASTER } );
	my $v      = Plugins::ABCListen::HLS::_v($stream);

	Slim::Networking::SimpleAsyncHTTP->reset;
	route( qr{seg\d+\.ts\z}, content => sine_ts(0), defer => 1 );
	drain($stream);    # reads the prepared audio (4, and 5 fetched right after the scan), then waits for 6
	is_deeply( [ Slim::Networking::SimpleAsyncHTTP->deferred ], ["${BASE}seg6.ts"], 'segment 6 in flight' );

	ok( $stream->close, 'close' );
	is( $v->{out} . $v->{pending}, '', 'buffers dropped' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $v->{out} . $v->{pending}, '', 'the late response is ignored' );
	my $buf;
	is( $stream->sysread( $buf, 100 ), 0, 'sysread after close: 0' );
	is( scalar( requests() ), 1, 'no request after close' );
	ok( $stream->close, 'close again: fine' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timers' );
};

subtest 'prepared streams: one per URL, at most PREPARED_MAX, for PREPARED_TTL; others start afresh' => sub {
	reset_all();
	my @masters = map {"https://streaming.abc-cdn.net.au/audio/hls/s$_.m3u8"} 1 .. 5;
	route( $_, file => 'hls/master-triplejnsw.m3u8' ) for @masters;
	route_stream( media => media( 1, 6 ), noMaster => 1 );

	for (@masters) { scan($_); advanceTime(1) }
	is( $HLS->_prepared, Plugins::ABCListen::HLS::PREPARED_MAX, 'at most 4 kept: the oldest was closed' );
	my $s1 = $HLS->new( { url => $masters[0] } );
	ok( !Plugins::ABCListen::HLS::_v($s1)->{mediaUrl}, 'the evicted URL starts afresh (nothing loaded yet)' );

	my $s2 = $HLS->new( { url => $masters[1] } );
	ok( Plugins::ABCListen::HLS::_v($s2)->{mediaUrl}, 'a kept one is used' );
	advanceTime(61);
	my $s5 = $HLS->new( { url => $masters[4] } );
	ok( !Plugins::ABCListen::HLS::_v($s5)->{mediaUrl}, 'a prepared stream older than 60 s is not used' );

	reset_all();
	route_stream( media => media( 1, 6 ) );
	scan();
	scan();
	is( $HLS->_prepared, 1, 'the same URL scanned twice: one kept' );

	# a fresh stream (e.g. LMS opens the song again after a long pause) loads everything itself
	reset_all();
	route_stream( media => media( 1, 6 ) );
	my $fresh = $HLS->new( { url => $MASTER } );
	my ($audio) = drain($fresh);
	is_deeply( [ ( urls() )[ 0 .. 1 ] ], [ $MASTER, $MEDIA ], 'a fresh stream loads the master and the media playlist' );
	ok( Plugins::ABCListen::HLS::adtsInfo($audio), '... and plays' );
	is_deeply( [ seq_of( segment_requests() ) ], [ 4, 5, 6 ], '... from 3 segments before the end' );
};

subtest 'an fMP4 stream end to end (StreamGuys style: relative URIs, EXT-X-MAP)' => sub {
	reset_all();
	my $master = 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8';
	my $base   = 'https://abc-hls.streamguys1.com/hls/sport-sync/';
	route( $master, content => qq{#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:BANDWIDTH=66981,CODECS="mp4a.40.2"\naudio.m3u8?nimblesessionid=7\n} );
	route( "${base}audio.m3u8?nimblesessionid=7", content => join "\n", '#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-TARGETDURATION:1', '#EXT-X-MEDIA-SEQUENCE:40', '#EXT-X-MAP:URI="audio_1.fmp4?nimblesessionid=7"',
		( map { ( '#EXTINF:1.0,', "a_$_.fmp4?nimblesessionid=7" ) } 40 .. 42 ), '#EXT-X-PART:DURATION=0.5,URI="a_43_0.fmp4?nimblesessionid=7"', '' );
	route( "${base}audio_1.fmp4?nimblesessionid=7", file => 'hls/sine-init.mp4' );
	route( "${base}a_$_.fmp4?nimblesessionid=7", file => 'hls/sine-' . ( $_ - 40 ) . '.m4s' ) for 40 .. 42;

	my ( $track, $error ) = scan($master)->args(0);
	is( $error, undef, 'prepared' );
	is( $track && $track->bitrate, 46000, 'bitrate measured (the first segment: 46 kbps)' );
	my $stream = $HLS->new( { url => $master } );
	my ($audio) = drain($stream);
	is( sha1_hex($audio), $SINE_ADTS_SHA1, 'the three fMP4 segments as ADTS, byte for byte' );
	is( scalar( grep {/audio_1\.fmp4/} urls() ), 1, 'the init segment fetched once' );
	ok( !( grep {/a_43_0/} urls() ), 'LL-HLS parts never fetched' );
};

done_testing();
