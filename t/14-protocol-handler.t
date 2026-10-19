#!/usr/bin/perl
# Plugins::ABCListen::ProtocolHandler (abclisten://): the per-kind resolver registry
# (registerKind validation and replacement), scanUrl (URL parsing -> BAD_URL / UNAVAILABLE,
# resolve error tokens, the candidate list: order, alternates after a failed scan, dedupe,
# .m3u8 filter with the hls flag, failToken), the wrapped scan callback (streamUrl, title, cover,
# URL restore, playlist update time) without a reference cycle, resolver robustness (dies, double
# callback, 20 s timeout), containment (only the kind's code runs in resolve's eval; a dying
# scanner or LMS callback, sync or async resolve: LMS's callback runs exactly once and no resolve
# failure is reported), new() with and without redir, getMetadataFor layering (fallback <
# resolve meta < kind metadata), its bounded meta map and its rate-limited WARN for a dying kind
# metadata, getCurrentTitle/getIcon/isRemote, and onStream/onStop dispatch. Also Live->init registers the `live` kind
# (since L1 for the full catalogue, see t/20-stations.t): Icecast URL at play time, name, logo and bitrate as metadata.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use File::Spec;
use FindBin;
use Scalar::Util qw(weaken);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use ABCListenTest::FakeClient;

use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Util qw(ICON DISPLAY_NAME);
use Plugins::ABCListen::Live;

my $PH = 'Plugins::ABCListen::ProtocolHandler';

my $LIVE = 'abclisten://live/TRIPLEJ';
my $A    = 'https://abc.streamguys1.com/live/triplejnsw/icecast.audio';
my $B    = 'https://example.test/b.aac';
my $C    = 'https://example.test/c.mp3';

my $BAD_URL       = 'PLUGIN_ABCLISTEN_BAD_URL';
my $UNAVAILABLE   = 'PLUGIN_ABCLISTEN_UNAVAILABLE';
my $STREAM_FAILED = 'PLUGIN_ABCLISTEN_STREAM_FAILED';

# record INFO and DEBUG calls too (they are guarded by is_info / is_debug)
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub logged_like {
	my ( $level, $re ) = @_;
	return scalar grep { $_->{message} =~ $re } logged($level);
}

# ---- fakes and helpers ----

my @RESOLVES;    # [ $client, $id ] for every resolve call of a test kind

# Register $kind (default 'live') with a resolve that records its arguments and calls back
# synchronously with $result (a hash ref), or runs $result (a code ref) as resolve itself.
# %hooks: metadata (default: returns {}), onStream, onStop.
sub register_kind {
	my ( $result, %hooks ) = @_;
	my $kind = delete $hooks{kind} || 'live';

	my $resolve = ref $result eq 'CODE' ? $result : sub {
		my ( $client, $id, $cb ) = @_;
		push @RESOLVES, [ $client, $id ];
		$cb->($result);
	};

	$PH->registerKind( $kind => { resolve => $resolve, metadata => sub { +{} }, %hooks } );
	return;
}

# The fake remote scanner (Slim::Utils::Scanner::Remote stub handler hook): scanning fails with
# '404 Not Found' for the URLs in fail => [...] (or every URL with fail => 'all'); otherwise it
# answers a new track for the scanned URL, or for redirect => $url (as after an HTTP redirect),
# with cover art found in the stream (cover => 1).
sub scanner {
	my %opts = @_;

	$Slim::Utils::Scanner::Remote::HANDLER = sub {
		my ( $url, $args ) = @_;

		if ( $opts{fail} && ( !ref $opts{fail} || grep { $_ eq $url } @{ $opts{fail} } ) ) {
			return $args->{cb}->( undef, '404 Not Found' );
		}

		my $track = FakeTrack->new( url => $opts{redirect} || $url, title => $args->{song}->track->title, cover => 1 );
		return $args->{cb}->( $track, undef );
	};

	return;
}

sub scanned { map { $_->{url} } @Slim::Utils::Scanner::Remote::SCANS }

# scanUrl($url) with a fresh fake song and player; returns (collector, song, args).
sub scan {
	my $url  = shift;
	my $song = FakeSong->new($url);
	my $c    = collector();
	my $args = { client => $song->master, song => $song, cb => $c->cb };
	$PH->scanUrl( $url, $args );
	return ( $c, $song, $args );
}

sub reset_all {
	resetStubs();
	@RESOLVES = ();
	clearTime();
	return;
}

# ---- registry ----

subtest 'registerKind: bad kind names and implementations croak' => sub {
	reset_all();
	my %ok = ( resolve => sub { }, metadata => sub { +{} } );

	for my $name ( 'Live', 'live-1', '', undef, "live\n", 'live1', ' live', [] ) {
		my $label = defined $name ? ( ref $name ? 'an array ref' : "'$name'" ) : 'undef';
		$label =~ s/\n/\\n/;
		ok( !eval { $PH->registerKind( $name, {%ok} ); 1 }, "kind $label croaks" );
		like( $@, qr/registerKind/, "kind $label: the message names registerKind" );
	}

	my @bad = (
		[ 'no implementation',           undef ],
		[ 'an array ref',                [ resolve => sub { } ] ],
		[ 'missing resolve',             { metadata => sub { +{} } } ],
		[ 'missing metadata',            { resolve  => sub { } } ],
		[ 'resolve not a code ref',      { %ok, resolve  => 'resolve' } ],
		[ 'metadata a hash, not code',   { %ok, metadata => {} } ],
		[ 'onStream not a code ref',     { %ok, onStream => 1 } ],
		[ 'onStop undef',                { %ok, onStop   => undef } ],
		[ 'an unknown key',              { %ok, onSeek   => sub { } } ],
	);
	for my $case (@bad) {
		my ( $label, $impl ) = @$case;
		ok( !eval { $PH->registerKind( test => $impl ); 1 }, "$label croaks" );
		like( $@, qr/registerKind\('test'\)/, "$label: the message names the kind" );
	}

	ok( eval { $PH->registerKind( test => {%ok} ); 1 }, 'resolve + metadata: accepted' ) or diag $@;
	ok( eval { $PH->registerKind( test => { %ok, onStream => sub { }, onStop => sub { } } ); 1 }, 'with onStream + onStop: accepted' ) or diag $@;
	is( scalar logged('ERROR'), 0, 'nothing logged at ERROR' );
};

subtest 'registerKind: registering a kind again replaces it (INFO)' => sub {
	reset_all();
	scanner();
	register_kind( { url => $A } );
	register_kind( { url => $B } );
	ok( logged_like( INFO => qr/'live'.*replac|replac.*'live'/i ), 'the replacement is logged at INFO' );

	scan($LIVE);
	is_deeply( [ scanned() ], [$B], 'the second registration is used' );
	is( scalar @RESOLVES, 1, 'only the second resolve is called' );
};

# ---- scanUrl: parsing and resolve errors ----

subtest 'scanUrl: unparseable URLs -> BAD_URL, resolve never called, no scan' => sub {
	for my $url ( 'abclisten://', 'abclisten://live/', 'abclisten://live/triplej', 'abclisten://episode/abc', 'abclisten://bogus/1', 'abclisten://live/TRIPLEJ?x=1', undef ) {
		reset_all();
		scanner();
		register_kind( { url => $A } );
		my $label = defined $url ? $url : 'undef';

		my ( $c, $song ) = scan($url);
		is( $c->count, 1, "$label: one callback" );
		is_deeply( [ $c->args(0) ], [ undef, $BAD_URL ], "$label: cb->(undef, BAD_URL)" );
		is( scalar @RESOLVES, 0, "$label: resolve not called" );
		is( scalar( scanned() ), 0, "$label: nothing scanned" );
		ok( logged_like( INFO => qr/\Q$BAD_URL\E/ ), "$label: logged at INFO with the token" );
		ok( logged_like( INFO => qr/\Q$url\E/ ), "$label: ... and the URL" ) if defined $url;
	}
};

subtest 'scanUrl: a parseable URL whose kind is not registered -> UNAVAILABLE' => sub {
	reset_all();
	scanner();
	my $url = 'abclisten://episode/107266790';    # episode: registered by O1, not yet

	my ($c) = scan($url);
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, $UNAVAILABLE ], 'cb->(undef, UNAVAILABLE)' );
	is( scalar( scanned() ), 0, 'nothing scanned' );
	ok( logged_like( INFO => qr/\Q$url\E.*\Q$UNAVAILABLE\E/ ), 'logged at INFO with URL and token' );
};

subtest 'scanUrl: resolve error token -> exactly that token, no scan' => sub {
	reset_all();
	scanner();
	register_kind( { error => 'PLUGIN_X', url => $A } );

	my ( $c, $song ) = scan($LIVE);
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_X' ], 'cb->(undef, PLUGIN_X)' );
	is( scalar( scanned() ), 0, 'nothing scanned (url ignored when error is set)' );
	is( $song->streamUrl, $LIVE, 'streamUrl untouched' );
	ok( logged_like( INFO => qr/\Q$LIVE\E.*PLUGIN_X/ ), 'logged at INFO with URL and token' );

	for my $result ( { error => '' }, 'a string', undef, [ { url => $A } ] ) {
		reset_all();
		scanner();
		register_kind( sub { $_[2]->($result) } );
		my $label = !defined $result ? 'undef' : ref $result ? ref $result : "'$result'";
		$label = "{ error => '' }" if ref $result eq 'HASH';
		my ($c2) = scan($LIVE);
		is_deeply( [ $c2->args(0) ], [ undef, $STREAM_FAILED ], "resolve answers $label: STREAM_FAILED" );
		is( scalar( scanned() ), 0, "resolve answers $label: nothing scanned" );
	}
};

# ---- scanUrl: success and the wrapped callback ----

subtest 'scanUrl success: resolve arguments and what the wrapped callback sets' => sub {
	reset_all();
	setTime(1792400000.25);
	scanner();
	register_kind( { url => $A }, metadata => sub { +{ title => 'triple j' } } );

	my ( $c, $song, $args ) = scan($LIVE);

	is( scalar @RESOLVES, 1, 'resolve called once' );
	is( $RESOLVES[0][0], $song->master, '... with the client' );
	is( $RESOLVES[0][1], 'TRIPLEJ', '... and the id' );

	is_deeply( [ scanned() ], [$A], 'SUPER::scanUrl called once, with the resolved URL' );
	is( $c->count, 1, 'one callback' );
	my ( $track, $error ) = $c->args(0);
	ok( $track, 'callback gets the scanned track' ) or return;
	is( $error, undef, 'no error' );
	is( $song->streamUrl, $A, '$song->streamUrl is the stream URL' );
	is( $track->title, 'triple j', 'track title from getMetadataFor' );
	ok( defined $track->cover && !$track->cover, 'embedded cover cleared (cover(0))' );
	is( $track->url, $LIVE, 'track URL restored to the abclisten:// URL' );
	is( $song->master->currentPlaylistUpdateTime, 1792400000.25, 'currentPlaylistUpdateTime bumped' );
	is_deeply( [ $song->calls ], [], 'no duration/startOffset calls on the song' );
	is( scalar logged('WARN') + scalar logged('ERROR'), 0, 'no warnings or errors' );
};

subtest 'scanUrl success: the URL is restored byte for byte' => sub {
	reset_all();
	scanner();
	register_kind( { url => $A } );

	for my $url ( 'abclisten://live/TRIPLEJ_PERTH', 'abclisten://live/LOCAL_SYDNEY', 'abclisten://live/RN' ) {
		my ($c) = scan($url);
		my ($track) = $c->args(0);
		is( $track && $track->url, $url, "$url restored" );
	}
};

subtest 'scanUrl success after an HTTP redirect during the scan' => sub {
	reset_all();
	my $redirected = 'https://cdn.example.test/live/triplejnsw.aac';
	scanner( redirect => $redirected );
	register_kind( { url => $A } );

	my ( $c, $song ) = scan($LIVE);
	my ($track) = $c->args(0);
	is( $song->streamUrl, $redirected, 'streamUrl is the redirected URL' );
	is( $track && $track->url, $LIVE, 'the track URL is the abclisten:// URL' );
};

# ---- candidates ----

subtest 'no usable candidate -> failToken, or STREAM_FAILED without one' => sub {
	my @results = (
		[ 'no url, no alternates',            {} ],
		[ "url ''",                           { url => '' } ],
		[ 'url undef',                        { url => undef } ],
		[ 'url undef, alternates []',         { url => undef, alternates => [] } ],
		[ 'only undef/empty alternates',      { alternates => [ undef, '', { url => '' }, { url => undef }, {} ] } ],
		[ 'alternates not an array',          { url => '', alternates => $B } ],
		[ 'only unflagged .m3u8',             { url => 'https://example.test/x.m3u8', alternates => ['https://example.test/y.m3u8?a=1'] } ],
	);
	for my $case (@results) {
		my ( $label, $result ) = @$case;
		for my $failToken ( undef, 'PLUGIN_X_FAILED' ) {
			reset_all();
			scanner();
			register_kind( { %$result, ( $failToken ? ( failToken => $failToken ) : () ) } );

			my ($c) = scan($LIVE);
			my $want = $failToken || $STREAM_FAILED;
			is( $c->count, 1, "$label, failToken " . ( $failToken || 'none' ) . ': one callback' );
			is_deeply( [ $c->args(0) ], [ undef, $want ], "$label: cb->(undef, $want)" );
			is( scalar( scanned() ), 0, "$label: nothing scanned" );
			ok( logged_like( INFO => qr/\Q$LIVE\E.*\Q$want\E/ ), "$label: logged at INFO with URL and token" );
		}
	}
};

subtest 'a failed scan moves on to the alternates, in order' => sub {
	reset_all();
	scanner( fail => [$A] );
	register_kind( { url => $A, alternates => [ $B, $C ], failToken => 'PLUGIN_X_FAILED' } );

	my ( $c, $song ) = scan($LIVE);
	is_deeply( [ scanned() ], [ $A, $B ], 'url, then the first alternate' );
	is( $c->count, 1, 'one callback' );
	my ($track) = $c->args(0);
	ok( $track, 'the alternate plays' );
	is( $song->streamUrl, $B, 'streamUrl is the first alternate that scanned' );
	is( $track && $track->url, $LIVE, 'track URL restored' );

	reset_all();
	scanner( fail => [ $A, $B ] );
	register_kind( { url => $A, alternates => [ { url => $B }, $C ] } );
	( $c, $song ) = scan($LIVE);
	is_deeply( [ scanned() ], [ $A, $B, $C ], 'url and the first alternate fail: the second is scanned' );
	is( $song->streamUrl, $C, 'streamUrl is the second alternate' );
	is( $c->count, 1, 'one callback' );

	reset_all();
	scanner( fail => 'all' );
	register_kind( { url => $A, alternates => [ $B, $C ], failToken => 'PLUGIN_X_FAILED' } );
	( $c, $song ) = scan($LIVE);
	is_deeply( [ scanned() ], [ $A, $B, $C ], 'all fail: each candidate scanned once, in order' );
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_X_FAILED' ], 'cb->(undef, failToken)' );
	is( $song->streamUrl, $LIVE, 'streamUrl untouched' );
	ok( logged_like( INFO => qr/\Q$LIVE\E.*PLUGIN_X_FAILED/ ), 'logged at INFO with URL and token' );

	reset_all();
	scanner( fail => 'all' );
	register_kind( { url => $A, alternates => [$B] } );
	($c) = scan($LIVE);
	is( scalar( scanned() ), 2, 'all fail without failToken: 2 candidates, 2 scans' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], 'cb->(undef, STREAM_FAILED)' );
};

subtest '.m3u8 candidates are skipped unless flagged hls' => sub {
	reset_all();
	scanner( fail => 'all' );
	my @hls = ( 'https://example.test/x.m3u8', 'https://example.test/x.M3U8', 'https://example.test/x.m3u8?source=web' );
	my @ok  = ( 'https://example.test/d.m3u8', 'https://example.test/x.m3u8.aac', 'https://example.test/m3u8/x.aac' );
	register_kind( { url => $hls[0], alternates => [ $hls[1], { url => $ok[0], hls => 1 }, $hls[2], $ok[1], { url => $ok[2] } ] } );

	scan($LIVE);
	is_deeply( [ scanned() ], \@ok, 'only the hls-flagged .m3u8 and the non-HLS URLs are scanned, in order' );
	for my $url (@hls) {
		ok( !( grep { $_ eq $url } scanned() ), "$url never handed to SUPER::scanUrl" );
	}

	reset_all();
	scanner();
	register_kind( { url => { url => $ok[0], hls => 1 } } );
	my ( $c, $song ) = scan($LIVE);
	is_deeply( [ scanned() ], [ $ok[0] ], 'an hls-flagged url passes through' );
	is( $song->streamUrl, $ok[0], '... and becomes the streamUrl' );
};

subtest 'duplicate candidates are scanned once' => sub {
	reset_all();
	scanner( fail => 'all' );
	register_kind( { url => $A, alternates => [ $A, { url => $A }, $B, $B, { url => $B, hls => 1 } ] } );

	my ($c) = scan($LIVE);
	is_deeply( [ scanned() ], [ $A, $B ], 'each URL scanned once' );
	is( $c->count, 1, 'one callback' );
};

# ---- resolver robustness ----

subtest 'resolve dies -> STREAM_FAILED (WARN), the exception is contained' => sub {
	reset_all();
	scanner();
	register_kind( sub { die "resolver bug\n" } );

	my $c;
	ok( eval { ($c) = scan($LIVE); 1 }, 'scanUrl does not die' ) or diag $@;
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], 'cb->(undef, STREAM_FAILED)' );
	ok( logged_like( WARN => qr/resolver bug/ ), 'the exception is logged at WARN' );
	is( scalar( scanned() ), 0, 'nothing scanned' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer left' );

	reset_all();
	scanner();
	register_kind( sub { $_[2]->( { url => $A } ); die "after the callback\n" } );
	ok( eval { ($c) = scan($LIVE); 1 }, 'resolve dies after calling back: scanUrl does not die' );
	is( $c->count, 1, 'one callback' );
	ok( ( $c->args(0) )[0], '... the scanned track' );
	ok( logged_like( WARN => qr/after the callback/ ), 'the exception is logged at WARN' );
};

subtest 'resolve calls back twice -> only the first call counts (DEBUG)' => sub {
	reset_all();
	scanner();
	register_kind( sub { $_[2]->( { url => $A } ); $_[2]->( { error => 'PLUGIN_X' } ) } );

	my ( $c, $song ) = scan($LIVE);
	is( $c->count, 1, 'one callback' );
	ok( ( $c->args(0) )[0], 'the first answer (a stream) is used' );
	is_deeply( [ scanned() ], [$A], 'scanned once' );
	ok( logged_like( DEBUG => qr/more than once|ignor/i ), 'the second call is logged at DEBUG' );

	reset_all();
	setTime(1792400000);
	scanner();
	register_kind( sub {
		my $cb = $_[2];
		Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->( { error => 'PLUGIN_X' } ); $cb->( { url => $A } ) } );
	} );
	($c) = scan($LIVE);
	is( $c->count, 0, 'asynchronous: no callback yet' );
	advanceTime(1);
	is( $c->count, 1, 'asynchronous: one callback' );
	is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_X' ], 'asynchronous: the first answer (an error) is used' );
	is( scalar( scanned() ), 0, 'nothing scanned' );
	is( scalar Slim::Utils::Timers->pending, 0, 'the timeout timer is gone' );
};

subtest 'resolve never calls back -> STREAM_FAILED after 20 s; a late callback is ignored' => sub {
	reset_all();
	setTime(1792400000);
	scanner();
	my $late;
	register_kind( sub { $late = $_[2] } );

	my ( $c, $song ) = scan($LIVE);
	is( $c->count, 0, 'no callback at first' );
	advanceTime(19.9);
	is( $c->count, 0, 'none after 19.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'one callback at 20 s' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], 'cb->(undef, STREAM_FAILED)' );
	ok( logged_like( INFO => qr/\Q$LIVE\E.*\Q$STREAM_FAILED\E/ ), 'logged at INFO with URL and token' );

	$late->( { url => $A } );
	is( $c->count, 1, 'the late callback is ignored: still one callback' );
	is( scalar( scanned() ), 0, 'nothing scanned' );
	is( $song->streamUrl, $LIVE, 'streamUrl untouched' );

	reset_all();
	setTime(1792400000);
	scanner();
	register_kind( sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + 19, sub { $cb->( { url => $A } ) } ) } );
	($c) = scan($LIVE);
	is( scalar Slim::Utils::Timers->pending, 2, 'a slow resolve: its timer and the 20 s timeout' );
	advanceTime(19);
	is( $c->count, 1, 'answer at 19 s: one callback' );
	ok( ( $c->args(0) )[0], '... the scanned track' );
	is( scalar Slim::Utils::Timers->pending, 0, 'the timeout timer is killed' );
	advanceTime(5);
	is( $c->count, 1, 'still one callback after 24 s' );
};

# ---- containment: only the kind's code runs in resolve's eval; LMS's callback runs exactly once ----

# A fake remote scanner whose behaviour is chosen per URL ('*': any other URL; default ok):
#   ok    answers a track          fail   answers '404 Not Found'
#   die   dies before calling back late   calls back with a track, then dies
#   twice calls back with a track twice
sub scanner_by_url {
	my %how = @_;

	$Slim::Utils::Scanner::Remote::HANDLER = sub {
		my ( $url, $args ) = @_;
		my $how = $how{$url} || $how{'*'} || 'ok';

		return $args->{cb}->( undef, '404 Not Found' ) if $how eq 'fail';
		die "scanner bug\n" if $how eq 'die';

		$args->{cb}->( FakeTrack->new( url => $url, title => $url ), undef );
		$args->{cb}->( FakeTrack->new( url => $url, title => $url ), undef ) if $how eq 'twice';
		die "scanner bug after the callback\n" if $how eq 'late';
		return;
	};

	return;
}

# scanUrl($url) with an LMS callback that records its arguments and dies when $dying; returns
# (whether scanUrl returned normally, the recorded calls, song).
sub scan_dying_cb {
	my ( $url, $dying ) = @_;
	my $song  = FakeSong->new($url);
	my @calls;
	my $args = { client => $song->master, song => $song, cb => sub { push @calls, [@_]; die "song callback bug\n" if $dying } };
	my $ok   = eval { $PH->scanUrl( $url, $args ); 1 };
	diag $@ unless $ok;
	return ( $ok, \@calls, $song );
}

sub resolve_failure_logged { logged_like( WARN => qr/Resolve for .* died/ ) }

subtest 'the scanner dies after a synchronous resolve -> STREAM_FAILED once, logged as the scan, not the resolve' => sub {
	reset_all();
	scanner_by_url( '*' => 'die' );
	register_kind( { url => $A, alternates => [$B] } );

	my ( $c, $song );
	ok( eval { ( $c, $song ) = scan($LIVE); 1 }, 'scanUrl does not die' ) or diag $@;
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], 'cb->(undef, STREAM_FAILED)' );
	is_deeply( [ scanned() ], [$A], 'only the first candidate was scanned' );
	ok( logged_like( WARN => qr/Scanning \Q$A\E for \Q$LIVE\E died: scanner bug/ ), 'logged at WARN as the scan of the candidate' );
	ok( !resolve_failure_logged(), 'not reported as a resolve failure' );
	ok( logged_like( INFO => qr/\Q$LIVE\E.*\Q$STREAM_FAILED\E/ ), 'the failure is logged at INFO with URL and token' );
	is( $song->streamUrl, $LIVE, 'streamUrl untouched' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer left' );

	reset_all();
	scanner_by_url( $A => 'fail', $B => 'die' );
	register_kind( { url => $A, alternates => [$B] } );
	ok( eval { ($c) = scan($LIVE); 1 }, 'the scan of an alternate dies: scanUrl does not die' ) or diag $@;
	is_deeply( [ scanned() ], [ $A, $B ], '... after the first candidate failed' );
	is( $c->count, 1, '... one callback' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], '... cb->(undef, STREAM_FAILED)' );
	ok( logged_like( WARN => qr/Scanning \Q$B\E for \Q$LIVE\E died: scanner bug/ ), '... logged at WARN as the scan of the alternate' );
	ok( !resolve_failure_logged(), '... not reported as a resolve failure' );

	reset_all();
	scanner_by_url( '*' => 'late' );
	register_kind( { url => $A } );
	ok( eval { ( $c, $song ) = scan($LIVE); 1 }, 'the scanner dies after calling back: scanUrl does not die' ) or diag $@;
	is( $c->count, 1, '... one callback' );
	ok( ( $c->args(0) )[0], '... with the scanned track' );
	is( $song->streamUrl, $A, '... streamUrl set' );
	ok( logged_like( WARN => qr/Scanning \Q$A\E for \Q$LIVE\E died after the play callback: scanner bug after the callback/ ), '... logged at WARN as after the callback' );
	ok( !resolve_failure_logged(), '... not reported as a resolve failure' );
};

subtest "LMS's callback dies -> it ran once; contained, logged as LMS's, not as a resolve or scan failure" => sub {
	my @cases = (
		[ 'a scanned track',         { url => $A },                   undef,           'track' ],
		[ 'a resolve error token',   { error => 'PLUGIN_X' },         undef,           'PLUGIN_X' ],
		[ 'every candidate failing', { url => $A, alternates => [$B] }, [ '*' => 'fail' ], $STREAM_FAILED ],
	);
	for my $case (@cases) {
		my ( $label, $result, $scanner, $want ) = @$case;
		reset_all();
		scanner_by_url( @{ $scanner || [] } );
		register_kind($result);

		my ( $ok, $calls ) = scan_dying_cb( $LIVE, 1 );
		ok( $ok, "$label: scanUrl does not die" );
		is( scalar @$calls, 1, "$label: the callback ran once" );
		if ( $want eq 'track' ) {
			ok( $calls->[0][0], "$label: ... with the track" );
		}
		else {
			is_deeply( $calls->[0], [ undef, $want ], "$label: ... with (undef, $want)" );
		}
		ok( logged_like( WARN => qr/LMS's play callback for \Q$LIVE\E died: song callback bug/ ), "$label: logged at WARN as LMS's callback" );
		ok( !resolve_failure_logged(), "$label: not reported as a resolve failure" );
		ok( !logged_like( WARN => qr/Scanning|Handling the scan/ ), "$label: not reported as a scan failure" );
	}

	reset_all();
	my ( $ok, $calls ) = scan_dying_cb( 'abclisten://bogus/1', 1 );
	ok( $ok, 'BAD_URL: scanUrl does not die' );
	is_deeply( $calls, [ [ undef, $BAD_URL ] ], 'BAD_URL: the callback ran once' );

	reset_all();
	setTime(1792400000);
	register_kind( sub { } );
	( $ok, $calls ) = scan_dying_cb( $LIVE, 1 );
	ok( eval { advanceTime(20); 1 }, 'resolve timeout: the timer does not die' ) or diag $@;
	is_deeply( $calls, [ [ undef, $STREAM_FAILED ] ], 'resolve timeout: the callback ran once' );
};

subtest 'an asynchronous resolve still works; the play it starts never dies into the kind' => sub {
	my $async = sub {
		my $result = shift;
		return sub {
			my ( $client, $id, $cb ) = @_;
			push @RESOLVES, [ $client, $id ];
			Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->($result) } );
		};
	};

	reset_all();
	setTime(1792400000);
	scanner();
	register_kind( $async->( { url => $A, meta => { title => 'Async title' } } ) );

	my ( $c, $song ) = scan($LIVE);
	is( scalar @RESOLVES, 1, 'resolve called once' );
	is( $c->count, 0, 'no callback before the answer' );
	is( scalar( scanned() ), 0, 'nothing scanned before the answer' );
	is( scalar Slim::Utils::Timers->pending, 2, "the kind's timer and the 20 s timeout" );
	advanceTime(1);
	is( $c->count, 1, 'one callback after the answer' );
	my ($track) = $c->args(0);
	ok( $track, '... with the scanned track' );
	is_deeply( [ scanned() ], [$A], 'the answer is scanned' );
	is( $song->streamUrl, $A, 'streamUrl is the stream URL' );
	is( $track && $track->url,   $LIVE,         'track URL restored' );
	is( $track && $track->title, 'Async title', 'track title from the resolve meta' );
	is( scalar Slim::Utils::Timers->pending, 0, 'the timeout timer is killed' );
	advanceTime(30);
	is( $c->count, 1, 'still one callback after the timeout would have fired' );
	is( scalar logged('WARN') + scalar logged('ERROR'), 0, 'no warnings or errors' );

	reset_all();
	setTime(1792400000);
	scanner_by_url( '*' => 'die' );
	register_kind( $async->( { url => $A } ) );
	($c) = scan($LIVE);
	ok( eval { advanceTime(1); 1 }, "the scanner dies: the die does not reach the kind's code" ) or diag $@;
	is( $c->count, 1, '... one callback' );
	is_deeply( [ $c->args(0) ], [ undef, $STREAM_FAILED ], '... cb->(undef, STREAM_FAILED)' );
	ok( logged_like( WARN => qr/Scanning \Q$A\E for \Q$LIVE\E died: scanner bug/ ), '... logged at WARN as the scan' );
	ok( !resolve_failure_logged(), '... not reported as a resolve failure' );

	reset_all();
	setTime(1792400000);
	scanner();
	register_kind( $async->( { url => $A } ) );
	my ( $ok, $calls ) = scan_dying_cb( $LIVE, 1 );
	ok( eval { advanceTime(1); 1 }, "LMS's callback dies: the die does not reach the kind's code" ) or diag $@;
	is( scalar @$calls, 1, '... the callback ran once' );
	ok( $calls->[0][0], '... with the track' );
	ok( !resolve_failure_logged(), '... not reported as a resolve failure' );
};

subtest "exactly once: LMS's callback runs once on every resolve x scanner x callback path" => sub {
	my $answer    = { url => $A, alternates => [$B] };
	my %resolvers = (
		'answers synchronously'       => sub { $_[2]->($answer) },
		'answers asynchronously'      => sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->($answer) } ) },
		'answers, then dies'          => sub { $_[2]->($answer); die "resolver bug\n" },
		'dies'                        => sub { die "resolver bug\n" },
		'answers twice'               => sub { $_[2]->($answer); $_[2]->( { error => 'PLUGIN_X' } ) },
		'answers an error'            => sub { $_[2]->( { error => 'PLUGIN_X' } ) },
		'never answers'               => sub { },
	);
	my %scanners = (
		'scans'                    => [],
		'first candidate fails'    => [ $A => 'fail' ],
		'all fail'                 => [ '*' => 'fail' ],
		'dies'                     => [ '*' => 'die' ],
		'alternate dies'           => [ $A => 'fail', $B => 'die' ],
		'dies after calling back'  => [ '*' => 'late' ],
		'calls back twice'         => [ '*' => 'twice' ],
	);

	for my $r ( sort keys %resolvers ) {
		for my $s ( sort keys %scanners ) {
			for my $dying ( 0, 1 ) {
				my $label = "resolve $r, scanner $s" . ( $dying ? ", LMS's callback dies" : '' );
				reset_all();
				setTime(1792400000);
				scanner_by_url( @{ $scanners{$s} } );
				register_kind( $resolvers{$r} );

				my ( $ok, $calls ) = scan_dying_cb( $LIVE, $dying );
				ok( $ok && eval { advanceTime(25); 1 }, "$label: nothing dies" ) or diag $@;
				is( scalar @$calls, 1, "$label: LMS's callback ran exactly once" );
				is( scalar Slim::Utils::Timers->pending, 0, "$label: no timer left" );
				is( resolve_failure_logged() ? 1 : 0, $r =~ /dies/ ? 1 : 0, "$label: a resolve failure is reported only if resolve died" );
			}
		}
	}
};

# ---- new ----

subtest 'new(): streams $song->streamUrl unless redirected' => sub {
	my $song = FakeSong->new($LIVE);
	$song->streamUrl($A);

	my $sock = $PH->new( { url => $LIVE, song => $song, client => $song->master } );
	isa_ok( $sock, $PH );
	is( $sock && $sock->{url}, $A, 'without redir: url = $song->streamUrl' );

	my $redirected = 'https://cdn.example.test/triplejnsw.aac';
	$sock = $PH->new( { url => $redirected, redir => $A, song => $song, client => $song->master } );
	is( $sock && $sock->{url}, $redirected, 'with redir: url kept (no redirect loop)' );

	$sock = $PH->new( { url => $A } );
	is( $sock, undef, 'without a song: left to the base class' );
};

# ---- metadata ----

subtest 'getMetadataFor: fallback < resolve meta < kind metadata' => sub {
	reset_all();
	scanner();
	my $kindMeta = {};
	register_kind(
		{ url => $A, meta => { title => 'Meta title', artist => 'Meta artist', album => 'Meta album', cover => 'https://example.test/meta.jpg', duration => '' } },
		metadata => sub { $kindMeta }
	);
	my $url = 'abclisten://live/DOUBLEJ';

	is_deeply( $PH->getMetadataFor( undef, $url ), { title => 'ABC listen', cover => ICON, icon => ICON }, 'before any resolve: the fallback' );
	is( $PH->getMetadataFor( undef, $url )->{title}, string('PLUGIN_ABCLISTEN'), 'fallback title is PLUGIN_ABCLISTEN' );

	scan($url);
	is_deeply(
		$PH->getMetadataFor( undef, $url ),
		{ title => 'Meta title', artist => 'Meta artist', album => 'Meta album', cover => 'https://example.test/meta.jpg', icon => ICON },
		'after a resolve: its meta over the fallback (empty fields ignored)'
	);

	$kindMeta = { title => 'Kind title', cover => '', album => undef, artist => [], duration => 300 };
	is_deeply(
		$PH->getMetadataFor( undef, $url ),
		{ title => 'Kind title', artist => 'Meta artist', album => 'Meta album', cover => 'https://example.test/meta.jpg', icon => ICON, duration => 300 },
		'kind metadata wins; its empty, undef and non-scalar fields fall back'
	);

	$kindMeta = {};
	is_deeply( $PH->getMetadataFor( undef, 'abclisten://live/OTHER' ), { title => 'ABC listen', cover => ICON, icon => ICON }, 'resolve meta is per URL' );
	is( scalar logged('WARN') + scalar logged('ERROR'), 0, 'no warnings or errors' );
};

subtest 'getMetadataFor: a kind metadata that dies or returns a non-hash -> fallback; never dies' => sub {
	my $url = 'abclisten://live/CLASSIC';
	for my $case (
		[ 'dies',          sub { die "metadata bug\n" } ],
		[ 'returns undef', sub { undef } ],
		[ 'returns []',    sub { [ title => 'x' ] } ],
		[ 'returns a string', sub { 'x' } ],
		[ "returns '' fields", sub { +{ title => '', cover => '' } } ],
	) {
		my ( $label, $metadata ) = @$case;
		reset_all();
		register_kind( { url => $A }, metadata => $metadata );
		my $meta;
		ok( eval { $meta = $PH->getMetadataFor( undef, $url ); 1 }, "$label: does not die" ) or diag $@;
		is_deeply( $meta, { title => 'ABC listen', cover => ICON, icon => ICON }, "$label: the fallback" );
		ok( logged_like( WARN => qr/\Q$url\E.*metadata bug/ ), "$label: the exception is logged at WARN with the URL" ) if $label eq 'dies';
	}
};

subtest 'getMetadataFor: a dying kind metadata is logged at WARN at most once a minute per URL' => sub {
	reset_all();
	setTime(1792500000);
	register_kind( { url => $A }, metadata => sub { die "metadata bug\n" } );
	my ( $one, $two ) = ( 'abclisten://live/RATE_ONE', 'abclisten://live/RATE_TWO' );
	my $warns = sub { my $url = shift; logged_like( WARN => qr/\Q$url\E.*metadata bug/ ) };
	my $fallback = { title => 'ABC listen', cover => ICON, icon => ICON };

	is_deeply( $PH->getMetadataFor( undef, $one ), $fallback, 'the fallback' ) for 1 .. 5;
	is( $warns->($one), 1, '5 calls in a row: one WARN' );
	is( logged_like( DEBUG => qr/\Q$one\E.*metadata bug/ ), 4, '... the other 4 at DEBUG' );

	advanceTime(59);
	$PH->getMetadataFor( undef, $one );
	is( $warns->($one), 1, 'after 59 s: still one WARN' );
	$PH->getMetadataFor( undef, $two ) for 1 .. 2;
	is( $warns->($two), 1, 'another URL: its own WARN, once' );

	advanceTime(1);
	$PH->getMetadataFor( undef, $one ) for 1 .. 3;
	is( $warns->($one), 2, 'after 60 s: a second WARN, once' );
	is( $warns->($two), 1, 'the other URL: unchanged' );

	advanceTime(59);
	$PH->getMetadataFor( undef, $two );
	is( $warns->($two), 2, 'the other URL, 60 s after its WARN: a second WARN' );
	is( $warns->($one), 2, '... the first URL: unchanged' );
};

subtest 'getMetadataFor: arguments, client, foreign URLs' => sub {
	reset_all();
	my @calls;
	register_kind( { url => $A }, metadata => sub { push @calls, [@_]; +{ title => 'T' } } );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is( $PH->getMetadataFor( $client, $LIVE, 1 )->{title}, 'T', 'with a client and forceCurrent' );
	is( $PH->getMetadataFor( undef, $LIVE )->{title}, 'T', 'with $client undef' );
	is_deeply( \@calls, [ [ $client, $LIVE, 'TRIPLEJ' ], [ undef, $LIVE, 'TRIPLEJ' ] ], 'kind metadata gets ($client, $url, $id)' );

	for my $url ( undef, '', 'garbage', $A, 'http://abclisten/live/TRIPLEJ', 'podcast://abclisten://live/TRIPLEJ' ) {
		is_deeply( $PH->getMetadataFor( undef, $url ), {}, 'foreign URL ' . ( defined $url ? "'$url'" : 'undef' ) . ': {}' );
	}

	is_deeply( $PH->getMetadataFor( undef, 'abclisten://episode/1' ), { title => 'ABC listen', cover => ICON, icon => ICON }, 'kind not registered: the fallback' );
	is_deeply( $PH->getMetadataFor( undef, 'abclisten://bogus/1' ), { title => 'ABC listen', cover => ICON, icon => ICON }, 'unparseable abclisten:// URL: the fallback' );
	is( scalar( requests() ), 0, 'no HTTP requests' );
};

subtest 'getCurrentTitle, getIcon, isRemote' => sub {
	reset_all();
	register_kind( { url => $A }, metadata => sub { +{ title => 'triple j' } } );

	is( $PH->getCurrentTitle( undef, $LIVE ), 'triple j', 'getCurrentTitle: the getMetadataFor title' );
	is( $PH->getCurrentTitle( ABCListenTest::FakeClient->new('00:00:00:00:00:01'), $LIVE ), 'triple j', 'getCurrentTitle with a client' );
	is( $PH->getCurrentTitle( undef, 'abclisten://episode/1' ), 'ABC listen', 'getCurrentTitle: fallback title' );
	is( $PH->getCurrentTitle( undef, $A ), undef, 'getCurrentTitle: foreign URL -> undef (LMS default)' );

	is( $PH->getIcon($LIVE), ICON, 'getIcon: the plugin icon' );
	is( $PH->getIcon(undef), ICON, 'getIcon: without a URL' );
	is( $PH->isRemote, 1, 'isRemote' );
};

subtest 'the resolve meta map is bounded (100 URLs, oldest evicted)' => sub {
	reset_all();
	scanner();
	register_kind( sub { my ( $client, $id, $cb ) = @_; $cb->( { url => $A, meta => { title => "Title $id" } } ) } );

	scan("abclisten://live/S$_") for 1 .. 101;

	is( $PH->getMetadataFor( undef, 'abclisten://live/S1' )->{title}, 'ABC listen', 'the oldest entry is evicted' );
	is( scalar( grep { $PH->getMetadataFor( undef, "abclisten://live/S$_" )->{title} eq "Title S$_" } 2 .. 101 ), 100, 'the 100 newest are kept' );

	scan('abclisten://live/S2');    # resolved again: now the newest
	scan('abclisten://live/S102');
	is( $PH->getMetadataFor( undef, 'abclisten://live/S2' )->{title}, 'Title S2', 'a URL resolved again is refreshed, not evicted' );
	is( $PH->getMetadataFor( undef, 'abclisten://live/S3' )->{title}, 'ABC listen', 'the oldest one is evicted instead' );
};

# ---- onStream / onStop ----

subtest 'onStream/onStop: dispatch to the kind hooks with the id' => sub {
	reset_all();
	my @calls;
	register_kind(
		{ url => $A },
		onStream => sub { push @calls, [ onStream => @_ ] },
		onStop   => sub { push @calls, [ onStop => @_ ] },
	);

	my $song   = FakeSong->new($LIVE);
	my $client = $song->master;
	$PH->onStream( $client, $song );
	$PH->onStop($song);
	is_deeply( \@calls, [ [ onStream => $client, $song, 'TRIPLEJ' ], [ onStop => $song, 'TRIPLEJ' ] ], 'onStream($client, $song, $id), onStop($song, $id)' );

	# the kind comes from the current track's URL
	@calls = ();
	$song->currentTrack->url('abclisten://live/RN');
	$PH->onStream( $client, $song );
	is_deeply( \@calls, [ [ onStream => $client, $song, 'RN' ] ], "the current track's URL decides" );
};

subtest 'onStream/onStop: no-ops and contained exceptions' => sub {
	reset_all();
	register_kind( { url => $A } );    # no hooks

	my $song = FakeSong->new($LIVE);
	ok( eval { $PH->onStream( $song->master, $song ); $PH->onStop($song); 1 }, 'a kind without hooks: no-op' ) or diag $@;

	for my $url ( 'abclisten://bogus/1', 'abclisten://episode/1', $A ) {
		my $other = FakeSong->new($url);
		ok( eval { $PH->onStream( $other->master, $other ); $PH->onStop($other); 1 }, "current URL $url: no-op" ) or diag $@;
	}
	ok( eval { $PH->onStream( $song->master, undef ); $PH->onStop(undef); 1 }, 'undef song: no-op' ) or diag $@;

	register_kind( { url => $A }, onStream => sub { die "onStream bug\n" }, onStop => sub { die "onStop bug\n" } );
	ok( eval { $PH->onStream( $song->master, $song ); 1 }, 'a dying onStream is not propagated' ) or diag $@;
	ok( eval { $PH->onStop($song); 1 }, 'a dying onStop is not propagated' ) or diag $@;
	ok( logged_like( WARN => qr/onStream bug/ ), 'onStream exception logged at WARN' );
	ok( logged_like( WARN => qr/onStop bug/ ),   'onStop exception logged at WARN' );
	is_deeply( [ $song->calls ], [], 'no duration/startOffset calls on the song' );
};

# ---- leaks ----

subtest 'no reference cycle: args hash, callback and song are freed after the scan' => sub {
	for my $case ( [ 'first candidate', [] ], [ 'after failed candidates', [ $A, $B ] ] ) {
		my ( $label, $fail ) = @$case;
		reset_all();
		scanner( fail => $fail );
		register_kind( { url => $A, alternates => [ $B, $C ] } );

		my $song = FakeSong->new($LIVE);
		my $c    = collector();
		my $args = { client => $song->master, song => $song, cb => $c->cb };
		$PH->scanUrl( $LIVE, $args );
		is( $c->count, 1, "$label: scan callback ran" );
		ok( ( $c->args(0) )[0], "$label: with a track" );

		my $weakArgs = $args;
		my $weakCb   = $args->{cb};
		my $weakSong = $song;
		weaken($_) for $weakArgs, $weakCb, $weakSong;
		undef $args;
		undef $song;
		undef $c;
		Slim::Utils::Scanner::Remote->reset;    # the stub keeps each scan's args in @SCANS

		ok( !defined $weakArgs, "$label: args hash freed" );
		ok( !defined $weakCb,   "$label: wrapped callback freed" );
		ok( !defined $weakSong, "$label: song freed" );
	}
};

# ---- static rules ----

subtest 'the handler never sets duration/startOffset or calls setCurrentTitle with a client' => sub {
	my $file = File::Spec->catfile( $FindBin::Bin, '..', 'ABCListen', 'ProtocolHandler.pm' );
	open( my $fh, '<', $file ) or die "Can't open $file: $!";
	my @hits = grep { /->(?:duration|startOffset)\(|setCurrentTitle\([^)]*,[^)]*,/ } <$fh>;
	close $fh;
	is_deeply( \@hits, [], 'no ->duration( / ->startOffset( / setCurrentTitle(a, b, c) in ProtocolHandler.pm' );
};

subtest 'error tokens are defined strings' => sub {
	ok( Slim::Utils::Strings::stringExists($_), "$_ exists" ) for $BAD_URL, $UNAVAILABLE, $STREAM_FAILED;
};

# ---- the F2 slice: the live kind in Live.pm ----

subtest 'slice: Live->init registers the live kind (Icecast URL at play time, station metadata)' => sub {
	reset_all();
	scanner();
	ok( eval { Plugins::ABCListen::Live->init; 1 }, 'Live->init does not die' ) or diag $@;

	my %mounts = ( TRIPLEJ => 'triplejnsw', DOUBLEJ => 'doublejnsw', RN => 'rnnsw', CLASSIC => 'classicfmnsw', JAZZ => 'abcjazz' );
	my %names  = ( TRIPLEJ => 'triple j', DOUBLEJ => 'Double J', RN => 'Radio National', CLASSIC => 'ABC Classic', JAZZ => 'ABC Jazz' );

	for my $id (qw(TRIPLEJ DOUBLEJ RN CLASSIC JAZZ)) {
		resetStubs();
		scanner();
		my $url  = "abclisten://live/$id";
		my $want = "https://abc.streamguys1.com/live/$mounts{$id}/icecast.audio";

		my ( $c, $song ) = scan($url);
		is_deeply( [ scanned() ], [$want], "$id: resolves to its Icecast URL" );
		my ($track) = $c->args(0);
		is( $song->streamUrl, $want, "$id: streamUrl" );
		is( $track && $track->url,   $url,        "$id: track URL stays $url" );
		is( $track && $track->title, $names{$id}, "$id: track title = station name" );

		is_deeply(
			$PH->getMetadataFor( undef, $url ),
			{ title => $names{$id}, artist => DISPLAY_NAME, cover => Plugins::ABCListen::API::imageUrl( Plugins::ABCListen::Stations->get($id)->{logo}, 600 ), bitrate => '56kbps CBR', icon => ICON },
			"$id: metadata = station name, 'ABC listen', station logo, Icecast bitrate"
		);
		is( $PH->getCurrentTitle( undef, $url ), $names{$id}, "$id: current title" );
	}

	resetStubs();
	scanner();
	my ($c) = scan('abclisten://live/NOPE');
	is_deeply( [ $c->args(0) ], [ undef, $UNAVAILABLE ], 'unknown live id: UNAVAILABLE' );
	is( scalar( scanned() ), 0, 'unknown live id: nothing scanned' );
	is_deeply( $PH->getMetadataFor( undef, 'abclisten://live/NOPE' ), { title => 'ABC listen', cover => ICON, icon => ICON }, 'unknown live id: fallback metadata' );
	is( DISPLAY_NAME, 'ABC listen', 'the artist is the display name' );
};

done_testing();

# ---- fakes for Slim::Schema::RemoteTrack and Slim::Player::Song ----

package FakeTrack;

sub new { my ( $class, %args ) = @_; return bless {%args}, $class }

sub url   { my $self = shift; $self->{url}   = shift if @_; return $self->{url} }
sub title { my $self = shift; $self->{title} = shift if @_; return $self->{title} }
sub cover { my $self = shift; $self->{cover} = shift if @_; return $self->{cover} }

package FakeSong;

# Like Slim::Player::Song: streamUrl starts as the playlist track's URL; currentTrack is the
# track; master is the (fake) player. duration/startOffset calls are recorded.
sub new {
	my ( $class, $url ) = @_;
	return bless {
		track     => FakeTrack->new( url => $url, title => $url ),
		streamUrl => $url,
		master    => ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef ),
		calls     => [],
	}, $class;
}

sub track        { $_[0]->{track} }
sub currentTrack { $_[0]->{track} }
sub master       { $_[0]->{master} }

sub streamUrl {
	my $self = shift;
	$self->{streamUrl} = shift if @_;
	return $self->{streamUrl};
}

sub duration    { my $self = shift; push @{ $self->{calls} }, [ duration    => @_ ]; return undef }
sub startOffset { my $self = shift; push @{ $self->{calls} }, [ startOffset => @_ ]; return undef }

sub calls { @{ $_[0]->{calls} } }
