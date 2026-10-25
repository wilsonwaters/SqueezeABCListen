#!/usr/bin/perl
# L5 (#14) and L6 (#80): the liveQuality pref and the live stream order, offline.
#   * the pref: Live->init default 'standard' (stored values kept), the validator truth table (named
#     sub and through the prefs stub's set: exactly 'standard', 'mediahub' and (L6) 'hls'),
#     HTML-escaped forms of rejected values rejected too, and the effective quality (undef and any
#     other stored value, e.g. a hand-edited 'HLS', play as 'standard');
#   * Stations->streamCandidates per quality x {network with mediahub, variant without, Wide Bay,
#     HLS-only with and without mediahub, event-only on air / off air, unknown}; over the whole
#     catalogue x every quality: never .m3u8/.f4m/.pls, https only, unknown values = 'standard';
#   * listing: playable, Radio -> Sport and stationItem are the same in standard and mediahub (HLS-only
#     and Kids listen versions hidden); favourites keep abclisten://live/<ID>;
#   * L6, liveQuality 'hls': the HLS stream first (flagged hls), then the standard candidates; HLS-only
#     services (Sport Rapid, RLWC Rapid, ABC Cricket, the four Kids listen versions) listed and
#     playable only in 'hls'; on-air events with hls sources; the whole catalogue (every station with an
#     HLS stream starts with it, never an unflagged .m3u8, no .m3u8 fetched while resolving); the
#     fallback line names HLS;
#   * the live kind: resolve order in 'mediahub'; onStream's fallback INFO line, once per play, through
#     ProtocolHandler->onStream (none when the first candidate plays, after a redirect, or within a
#     family; nothing written to the song); one onStream also starts L2's metadata poll, and onStop
#     still stops it; a LiveMetadata::onStream that dies is logged and doesn't skip the fallback
#     check (L3); M3 (#52): after a redirect the line names the candidate's family, and the
#     once-per-play guard holds songs weakly (a dropped song is freed, undef entries are pruned);
#   * the settings page: Settings->prefs (homeState, then liveQuality), saves and partial POSTs, rejected
#     and HTML values; the template's L5 section (name/id, aria-label, 3 options: standard, hls (L6),
#     mediahub; no PlayHLS note or disabled state), every token defined;
#   * main::WEBUI false: the pref is still initialised and validated.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Scalar::Util qw(weaken);

use Slim::Player::Playlist;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Timers;
use Slim::Web::Settings;

use ABCListenTest::FakeClient;

use Plugins::ABCListen::Stations;
use Plugins::ABCListen::StationData;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::LiveMetadata;
use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Settings;
use Plugins::ABCListen::MyABC;

my $S    = 'Plugins::ABCListen::Stations';
my $PH   = 'Plugins::ABCListen::ProtocolHandler';
my $BFF  = 'https://www.abc.net.au/core-next/api/';
my $ICE  = 'https://abc.streamguys1.com/live/%s/icecast.audio';
my $NOW  = 1_792_389_600;    # 2026-10-19 06:00 UTC
my $ROOT = abs_path( File::Spec->catdir( dirname(__FILE__), '..' ) );

my $TEMPLATE = File::Spec->catfile( $ROOT, qw(ABCListen HTML EN plugins ABCListen settings basic.html) );

# the namespace object the plugin modules hold (obtained before any resetStubs, as in t/21)
my $prefs = preferences('plugin.abclisten');

my $HLS_ONLY    = 'PLUGIN_ABCLISTEN_LIVE_HLS_ONLY';
my $OFF_AIR     = 'PLUGIN_ABCLISTEN_LIVE_OFF_AIR';
my $LIVE_FAILED = 'PLUGIN_ABCLISTEN_LIVE_FAILED';
my $UNAVAILABLE = 'PLUGIN_ABCLISTEN_UNAVAILABLE';

my @QUALITIES = qw(standard mediahub);         # L5's orders (L6's 'hls' has its own subtests)
my @VALID     = qw(standard hls mediahub);     # L6: every valid value, in the page's order
my @INVALID   = ( 'HLS', 'Hls', ' hls', 'hls ', 'Standard', 'STANDARD', 'MediaHub', ' mediahub', 'mediahub ', "mediahub\n", 'foo', '', '0', 'standard,mediahub', '<script>alert(1)</script>', 'mediahub"><b>', q{mediahub'&}, 'standard&' );
my @INVALID_REFS = ( [], {}, ['mediahub'], { mediahub => 1 }, \'mediahub' );

my @L5_TOKENS = map {"PLUGIN_ABCLISTEN_LIVE_QUALITY$_"} ( '', qw(_DESC _STANDARD _HLS _MEDIAHUB) );    # _HLS: L6

my %MH = (
	RN      => 'https://live-radio01.mediahubaustralia.com/2RNW/aac/',
	TRIPLEJ => 'https://live-radio01.mediahubaustralia.com/2TJW/aac/',
	WIDEBAY => 'https://live-radio03.mediahubaustralia.com/4BBGW/aac/',
	TENNIS  => 'https://live-radio02.mediahubaustralia.com/TENW/aac/',
	ITONE   => 'https://live-radio01.mediahubaustralia.com/IT1W/aac/',
);

# L6: HLS master playlists
my %HLS = (
	RN       => 'https://streaming.abc-cdn.net.au/audio/hls/rnnsw.m3u8',
	TRIPLEJ  => 'https://streaming.abc-cdn.net.au/audio/hls/triplejnsw.m3u8',
	CLASSIC2 => 'https://mediaserviceslive.akamaized.net/hls/live/2038317/classic2/index.m3u8',
	RAPID    => 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8',
	CRICKET  => 'https://streaming.abc-cdn.net.au/audio/hls/itinerantfour.m3u8',
	KIDS_NT  => 'https://streaming.abc-cdn.net.au/audio/hls/abckidsnt.m3u8',
	SPORT    => 'https://streaming.abc-cdn.net.au/audio/hls/sport.m3u8?source=web',
);

sub hls { +{ url => shift, hls => 1 } }

my @RECORDS = Plugins::ABCListen::StationData::records();
my %RECORD  = map { $_->{id} => $_ } @RECORDS;

my @HLS_ONLY_SPORT = qw(ABCSPORTSYNC ABC_AFL_RAPID ITINERANT_FOUR);
my @KIDS_VERSIONS  = qw(KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA);

# record INFO and DEBUG calls too
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }
sub fallback_lines { grep { $_->{message} =~ /instead of/ } logged('INFO') }

sub show { my $v = shift; return 'undef' unless defined $v; return ref $v ? ref($v) . ' ref' : "'" . ( $v =~ s/\n/\\n/gr ) . "'" }

sub html_escape {
	my $s = shift;
	my %e = ( '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;' );
	$s =~ s/([&<>"'])/$e{$1}/g;
	return $s;
}

sub ice { sprintf $ICE, shift }

# Fresh stubs and plugin state; liveQuality and homeState removed, then Live->init (default 'standard').
# Every .pls answers 404, so Icecast is the record's static mount.
sub reset_all {
	resetStubs();
	$S->_reset();
	$S->_setRecords();
	Plugins::ABCListen::NowPlaying->_reset();
	Plugins::ABCListen::LiveMetadata->_reset();
	setTime($NOW);
	$prefs->remove($_) for qw(liveQuality homeState);
	Plugins::ABCListen::Live->init;
	route( qr{\Ahttps://streaming\.abc-cdn\.net\.au/audio/ice/}, code => 404 );
	Slim::Utils::Log->resetMessages;
	return;
}

# every (other) event service off air (null); routes match in order, so call this after specific ones
sub events_off_air { route( qr{epgNowPlaying/}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' ) }

# Store a quality: valid values through the validator, anything else as a hand-edited prefs file would.
sub set_quality {
	my $q = shift;
	if ( defined $q && !ref $q && grep { $_ eq $q } @VALID ) {
		my ( undef, $ok ) = $prefs->set( liveQuality => $q );
		die "could not set liveQuality '$q'" unless $ok;
	}
	elsif ( !defined $q ) {
		$prefs->remove('liveQuality');
	}
	else {
		$prefs->{prefs}->{liveQuality} = $q;
	}
	return;
}

sub candidates {
	my $id = shift;
	my $c  = collector();
	$S->streamCandidates( $id, $c->cb );
	return $c;
}

sub answer { ( candidates(shift)->args(0) )[0] }

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	return scalar <$fh>;
}

# the event epg answer with an aac .pls, an aac mediahub and an hls source (on air)
my $EVENT_MIXED = JSON::PP->new->canonical->encode( {
	title   => 'An event',
	sources => [
		{ type => 'hls', file => 'https://streaming.abc-cdn.net.au/audio/hls/sport.m3u8?source=web' },
		{ type => 'aac', file => 'https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls?source=web' },
		{ type => 'aac', file => 'http:live-radio02.mediahubaustralia.com/TENW/aac/;*.mp3?source=web' },
	],
} );

# ---- the pref ----

subtest 'Live->init: liveQuality default standard, validator registered, stored values kept' => sub {
	reset_all();
	ok( $prefs->exists('liveQuality'), 'liveQuality initialised' );
	is( $prefs->get('liveQuality'), 'standard', '... to standard' );
	ok( $prefs->hasValidator('liveQuality'), 'validator registered for liveQuality' );
	is( $S->liveQuality, 'standard', 'effective quality: standard' );

	set_quality('mediahub');
	Plugins::ABCListen::Live->init;
	is( $prefs->get('liveQuality'), 'mediahub', 'init keeps a stored mediahub (upgrade, restart)' );

	set_quality('hls');
	Plugins::ABCListen::Live->init;
	is( $prefs->get('liveQuality'), 'hls', 'L6: init keeps a stored hls' );
	is( $S->liveQuality, 'hls', '... which plays as hls' );

	set_quality('HLS');
	Plugins::ABCListen::Live->init;
	is( $prefs->get('liveQuality'), 'HLS', 'init does not touch a stored unknown value (hand-edited HLS)' );
	is( $S->liveQuality, 'standard', '... which plays as standard' );
	is( scalar( logged('ERROR') ) + scalar( logged('WARN') ), 0, 'nothing logged at WARN or ERROR' );
};

subtest 'validator truth table (named sub): standard, hls (L6) and mediahub only; escaped forms rejected too' => sub {
	my $v = \&Plugins::ABCListen::Stations::validateLiveQuality;
	ok( $v->( 'liveQuality', $_ ), "valid: '$_'" ) for @VALID;
	ok( !$v->( 'liveQuality', $_ ), 'invalid: ' . show($_) ) for @INVALID, @INVALID_REFS, undef;

	my @escaped = grep { $_ ne html_escape($_) } @INVALID;
	is( scalar @escaped, 4, 'four rejected values change when HTML-escaped' );
	ok( !$v->( 'liveQuality', html_escape($_) ), 'escaped form rejected too: ' . show( html_escape($_) ) ) for @escaped;
	ok( !$v->( 'liveQuality', html_escape( html_escape($_) ) ), 'twice-escaped form rejected: ' . show($_) ) for @escaped;
};

subtest 'validator through the prefs layer (set: JSON-RPC pref command, settings form)' => sub {
	reset_all();

	for my $q (@VALID) {
		my ( $value, $ok ) = $prefs->set( liveQuality => $q );
		ok( $ok && $prefs->get('liveQuality') eq $q, "set '$q' is stored" );
	}

	$prefs->set( liveQuality => 'mediahub' );
	for my $bad ( @INVALID, @INVALID_REFS, undef ) {
		my ( undef, $ok ) = $prefs->set( liveQuality => $bad );
		ok( !$ok, 'set ' . show($bad) . ' is rejected' );
		is( $prefs->get('liveQuality'), 'mediahub', '... and liveQuality is still mediahub' );
	}
};

subtest 'effective quality: read at play time; undef and any other stored value play as standard' => sub {
	reset_all();
	for my $q (@VALID) {
		set_quality($q);
		is( $S->liveQuality, $q, "stored '$q' -> $q" );
	}
	for my $q ( undef, 'HLS', 'foo', '', 'MEDIAHUB', ['mediahub'], { mediahub => 1 }, ['hls'] ) {
		set_quality($q);
		is( $S->liveQuality, 'standard', 'stored ' . show($q) . ' -> standard' );
	}
};

# ---- stream candidates per quality ----

subtest 'candidates: network with mediahub, variant without, Wide Bay, unknown' => sub {
	my %want = (
		standard => { RN => [ ice('rnnsw'), $MH{RN} ], TRIPLEJ => [ ice('triplejnsw'), $MH{TRIPLEJ} ], ITINERANT_ONE => [ ice('afl'), $MH{ITONE} ], LOCAL_WIDEBAY => [ ice('localwidebay'), $MH{WIDEBAY} ] },
		mediahub => { RN => [ $MH{RN}, ice('rnnsw') ], TRIPLEJ => [ $MH{TRIPLEJ}, ice('triplejnsw') ], ITINERANT_ONE => [ $MH{ITONE}, ice('afl') ], LOCAL_WIDEBAY => [ $MH{WIDEBAY}, ice('localwidebay') ] },
	);

	for my $q (@QUALITIES) {
		reset_all();
		set_quality($q);
		for my $id ( sort keys %{ $want{$q} } ) {
			my $c = candidates($id);
			is( $c->count, 1, "$q, $id: one callback" );
			is_deeply( [ $c->args(0) ], [ $want{$q}->{$id} ], "$q, $id: " . ( $q eq 'mediahub' ? 'mediahub first, then Icecast' : 'Icecast first, then mediahub' ) );
		}

		my $perth = $RECORD{TRIPLEJ_PERTH};
		is_deeply( answer('TRIPLEJ_PERTH'), [ ice( $perth->{mount} ) ], "$q, TRIPLEJ_PERTH (no mediahub stream): Icecast only" );
		is_deeply( answer('GRANDSTAND'), [ ice('sport') ], "$q, GRANDSTAND (no mediahub stream): Icecast only" );
		is_deeply( answer($_), { error => $UNAVAILABLE }, "$q, unknown id " . show($_) . ': UNAVAILABLE' ) for 'NOPE', undef;
	}
};

subtest 'candidates: HLS-only services (with and without mediahub) in standard and mediahub' => sub {
	for my $q (@QUALITIES) {
		reset_all();
		set_quality($q);
		for my $id ( @HLS_ONLY_SPORT, @KIDS_VERSIONS ) {
			is_deeply( answer($id), { error => $HLS_ONLY }, "$q, $id: LIVE_HLS_ONLY" );
		}
		is( scalar( grep { $_->{url} =~ /\.m3u8/ } requests() ), 0, "$q: no .m3u8 request" );

		# an HLS-only service with a mediahub stream (as Wide Bay was in the research capture)
		$S->_setRecords( { %{ $RECORD{LOCAL_WIDEBAY} }, mount => undef, hlsSlug => undef, hlsOnly => 1 } );
		is_deeply( answer('LOCAL_WIDEBAY'), [ $MH{WIDEBAY} ], "$q, HLS-only with mediahub: mediahub only" );
		is( $S->playable('LOCAL_WIDEBAY'), 1, "$q, ... playable" );
		$S->_setRecords();
	}
};

subtest 'candidates: event-only services on air (.pls + mediahub sources) and off air' => sub {
	my %mixed = (
		standard => [ ice('sport'), $MH{TENNIS} ],
		mediahub => [ $MH{TENNIS}, ice('sport') ],
	);

	for my $q (@QUALITIES) {
		reset_all();
		set_quality($q);
		route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", content => $EVENT_MIXED );
		route( "${BFF}epgNowPlaying/SPORT_WBBL/now?imageRatio=1x1", file => 'live/epg-event-onair-pls.json' );
		route( "${BFF}epgNowPlaying/SPORT_TENNIS/now?imageRatio=1x1", file => 'live/epg-event-onair-mediahub.json' );
		route( 'https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls', content => "[playlist]\nFile1=" . ice('sport') . "\n" );
		events_off_air();

		is_deeply( answer('SPORT_BBL'),    $mixed{$q},       "$q, on air with .pls + mediahub sources: " . join( ', ', map { /streamguys/ ? 'Icecast' : 'mediahub' } @{ $mixed{$q} } ) );
		is_deeply( answer('SPORT_WBBL'),   [ ice('sport') ], "$q, on air with a .pls source only: Icecast only" );
		is_deeply( answer('SPORT_TENNIS'), [ $MH{TENNIS} ],  "$q, on air with a mediahub source only: mediahub only" );
		is_deeply( answer('SPORT_AFL'),    { error => $OFF_AIR }, "$q, off air: LIVE_OFF_AIR" );
		is( $S->playable('SPORT_BBL'), 1, "$q, on air: playable" );
		is( $S->playable('SPORT_AFL'), 0, "$q, off air: not playable" );
	}
};

subtest 'whole catalogue x every quality: direct streams only, never .m3u8; unknown values = standard' => sub {
	my %answers;

	for my $q ( @QUALITIES, 'unset', 'HLS (hand-edited)' ) {
		reset_all();
		set_quality( $q eq 'unset' ? undef : $q =~ /^HLS/ ? 'HLS' : $q );
		route( qr{epgNowPlaying/}, content => $EVENT_MIXED );    # every event service on air
		route( qr{grandstand\.pls}, content => "[playlist]\nFile1=" . ice('sport') . "\n" );

		my ( @bad, $once );
		for my $rec (@RECORDS) {
			my $c = candidates( $rec->{id} );
			$once++ if $c->count == 1;
			my ($r) = $c->args(0);
			$answers{$q}{ $rec->{id} } = $r;
			next unless ref $r eq 'ARRAY';
			push @bad, "$rec->{id}: empty" unless @$r;
			push @bad, map {"$rec->{id}: $_"} grep { /\.(?:m3u8|f4m|pls|m3u)(?:[?#]|\z)/i || !m{\Ahttps://} } @$r;
		}
		is( $once, scalar @RECORDS, "$q: every id answers exactly once" );
		is_deeply( \@bad, [], "$q: never .m3u8, .f4m or .pls; https only" );
		is( scalar( grep { $_->{url} =~ /\.m3u8/ } requests() ), 0, "$q: no .m3u8 request" );
	}

	is_deeply( $answers{$_}, $answers{standard}, "$_: the same candidates as standard" ) for 'unset', 'HLS (hand-edited)';

	my @wrong;
	for my $rec (@RECORDS) {
		my ( $std, $mh ) = ( $answers{standard}{ $rec->{id} }, $answers{mediahub}{ $rec->{id} } );
		if ( ref $std ne 'ARRAY' ) {
			push @wrong, "$rec->{id}: error differs" unless JSON::PP->new->canonical->encode($std) eq JSON::PP->new->canonical->encode($mh);
			next;
		}
		my @mhFirst = ( ( grep {/mediahubaustralia/} @$std ), ( grep { !/mediahubaustralia/ } @$std ) );
		push @wrong, "$rec->{id}: [@$mh] is not [@mhFirst]" unless "@$mh" eq "@mhFirst";
	}
	is_deeply( \@wrong, [], 'mediahub: the same streams as standard, mediahub streams first' );
	ok( scalar( grep { ref $_ eq 'ARRAY' && $_->[0] =~ /mediahubaustralia/ } values %{ $answers{mediahub} } ) > 20, 'mediahub: many stations start with mediahub' );
};

# ---- listing: the same in every quality ----

sub radio_items {
	my $client = shift;
	my $c      = collector();
	Plugins::ABCListen::Live->menuItems( $client, $c->cb, {} );
	my $radio = ( $c->args(0) )[0]->[0];
	my $r     = collector();
	$radio->{url}->( $client, $r->cb, {} );
	advanceTime(3);    # L2: the station lists wait up to 3 s for the programs on air
	return ( $r->args(0) )[0]->{items};
}

sub sport_ids {
	my ($sport) = grep { $_->{name} eq 'Sport' } @{ radio_items(undef) };
	my $c = collector();
	$sport->{url}->( undef, $c->cb, {} );
	advanceTime(3);
	return map { ( $_->{play} // $_->{url} // '' ) =~ m{\Aabclisten://live/(\w+)\z} ? $1 : '?' } @{ ( $c->args(0) )[0]->{items} };
}

subtest 'listing: playable, Radio -> Sport and stationItem are the same in standard and mediahub' => sub {
	my %playable;
	for my $q ( @QUALITIES, 'HLS (hand-edited)' ) {
		reset_all();
		events_off_air();
		set_quality( $q =~ /^HLS/ ? 'HLS' : $q );
		$playable{$q} = { map { $_->{id} => $S->playable( $_->{id} ) } @RECORDS };

		my @sport = sport_ids();
		is_deeply( \@sport, [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO)], "$q: Radio -> Sport lists the four Icecast sport services" );
		for my $id ( @HLS_ONLY_SPORT, @KIDS_VERSIONS ) {
			is( $S->playable($id), 0, "$q, $id: not playable" );
			is( Plugins::ABCListen::Live->stationItem( undef, $id ), undef, "$q, $id: no stationItem (D4's Sport and Kids listen)" );
		}

		my $item = Plugins::ABCListen::Live->stationItem( undef, 'TRIPLEJ' );
		is( $item->{play},          'abclisten://live/TRIPLEJ', "$q: the row plays abclisten://live/TRIPLEJ" );
		is( $item->{favorites_url}, 'abclisten://live/TRIPLEJ', "$q: favourites keep abclisten://live/TRIPLEJ" );
		is( scalar( grep { !ref && /streamguys1|mediahubaustralia|streaming\.abc-cdn|\.m3u8|\.pls/ } values %$item ), 0, "$q: no stream URL in the row" );
	}
	is_deeply( $playable{$_}, $playable{standard}, "$_: playable as in standard for every station" ) for 'mediahub', 'HLS (hand-edited)';
};

# ---- the live kind ----

subtest 'live kind resolve: mediahub first with Icecast as the alternate' => sub {
	reset_all();
	set_quality('mediahub');
	my $c = collector();
	Plugins::ABCListen::Live::_resolve( undef, 'RN', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => $MH{RN}, alternates => [ ice('rnnsw') ], failToken => $LIVE_FAILED } ], 'RN: url mediahub, alternates [Icecast], failToken LIVE_FAILED' );

	$c = collector();
	Plugins::ABCListen::Live::_resolve( undef, 'TRIPLEJ_PERTH', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => ice( $RECORD{TRIPLEJ_PERTH}->{mount} ), alternates => [], failToken => $LIVE_FAILED } ], 'no mediahub stream: Icecast, no alternate' );

	set_quality('HLS');
	$c = collector();
	Plugins::ABCListen::Live::_resolve( undef, 'RN', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => ice('rnnsw'), alternates => [ $MH{RN} ], failToken => $LIVE_FAILED } ], 'a hand-edited HLS: as standard' );

	set_quality('hls');
	$c = collector();
	Plugins::ABCListen::Live::_resolve( undef, 'RN', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => { url => $HLS{RN}, hls => 1 }, alternates => [ ice('rnnsw'), $MH{RN} ], failToken => $LIVE_FAILED } ], 'L6, hls: url the HLS stream (flagged hls), alternates Icecast then mediahub' );
};

# a song as LMS hands it to onStream after F2's scan: current track = the abclisten:// URL (redir: the
# candidate before a redirect), streamUrl = the stream that plays, master = the owning player
sub play_song {
	my ( $id, $streamUrl, %opts ) = @_;
	return L5Song->new( track => L5Track->new( url => "abclisten://live/$id", redir => $opts{redir} ), streamUrl => $streamUrl, owner => $opts{owner} );
}

subtest 'onStream: the fallback is logged once per play at INFO; never when the first candidate plays' => sub {
	reset_all();
	set_quality('mediahub');
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );
	my $slave  = $player->makeSlave('00:00:00:00:00:02');

	candidates('RN');
	my $song = play_song( RN => ice('rnnsw') );
	ok( eval { $PH->onStream( $player, $song ); 1 }, 'onStream does not die' ) or diag $@;
	my @lines = fallback_lines();
	is( scalar @lines, 1, 'mediahub failed, Icecast plays: one INFO line' );
	like( $lines[0] && $lines[0]->{message}, qr/using Icecast instead of mediahub for RN\b/, '... "using Icecast instead of mediahub for RN"' );
	is_deeply( $song->{pluginData}, {}, 'nothing is written to the song (pluginData untouched)' );

	$PH->onStream( $slave, $song );
	$PH->onStream( $player, $song );
	is( scalar( fallback_lines() ), 1, 'the same play again (a synced player, a reconnect): no second line' );

	$PH->onStream( $player, play_song( RN => $MH{RN} ) );
	is( scalar( fallback_lines() ), 1, 'a play where the first candidate (mediahub) plays: nothing logged' );

	set_quality('standard');
	candidates('RN');
	$PH->onStream( $player, play_song( RN => $MH{RN} ) );
	@lines = fallback_lines();
	is( scalar @lines, 2, 'standard, Icecast failed and mediahub plays: logged' );
	like( $lines[-1]->{message}, qr/using mediahub instead of Icecast for RN\b/, '... "using mediahub instead of Icecast for RN"' );

	my $next = play_song( RN => $MH{RN} );
	$PH->onStream( $player, $next );
	is( scalar( fallback_lines() ), 3, 'a new play (a new song) with the same fallback: logged again' );

	$PH->onStream( $player, play_song( RN => ice('rnnsw') ) );
	is( scalar( fallback_lines() ), 3, 'standard, Icecast plays: nothing logged' );

	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'nothing at WARN or ERROR' );
};

subtest 'onStream: no line for stations without an alternate, redirects, same family, unknown state' => sub {
	reset_all();
	set_quality('mediahub');
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );

	candidates('TRIPLEJ_PERTH');
	$PH->onStream( $player, play_song( TRIPLEJ_PERTH => ice( $RECORD{TRIPLEJ_PERTH}->{mount} ) ) );
	is( scalar( fallback_lines() ), 0, 'mediahub mode, no mediahub stream: Icecast only, no fallback line' );

	candidates('RN');
	$PH->onStream( $player, play_song( RN => 'https://edge.example.net/2RNW/aac/', redir => $MH{RN} ) );
	is( scalar( fallback_lines() ), 0, 'the first candidate after a redirect (track redir): nothing logged' );

	$PH->onStream( $player, play_song( RN => 'https://live-radio02.mediahubaustralia.com/2RNW/aac/' ) );
	is( scalar( fallback_lines() ), 0, 'another mediahub host (same family): nothing logged' );

	$S->_reset();
	$PH->onStream( $player, play_song( RN => ice('rnnsw') ) );
	is( scalar( fallback_lines() ), 0, 'no candidates known for the station: nothing logged' );

	my $bare = L5BareSong->new( streamUrl => ice('rnnsw') );
	ok( eval { $S->noteStream( $player, $bare, 'RN' ); $S->noteStream( $player, undef, 'RN' ); $S->noteStream( undef, play_song( RN => undef ), undef ); 1 }, 'odd songs and ids: no die' ) or diag $@;
	is( scalar( fallback_lines() ) + scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, '... and nothing logged' );
};

subtest 'onStream after a redirect: the family is the candidate\'s, not the redirected host\'s (M3, #52)' => sub {
	reset_all();
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );
	my $edge   = 'https://edge.example.net/live/rnnsw/icecast.audio';

	# as LMS's scanner leaves it: streamUrl = the redirected URL, track redir = the candidate
	set_quality('mediahub');
	candidates('RN');
	$PH->onStream( $player, play_song( RN => $edge, redir => ice('rnnsw') ) );
	my @lines = fallback_lines();
	is( scalar @lines, 1, 'mediahub failed, the Icecast candidate plays from another host: one line' );
	like( $lines[0] && $lines[0]->{message}, qr/using Icecast instead of mediahub for RN\b/, '... "using Icecast instead of mediahub" (not "another stream")' );
	like( $lines[0] && $lines[0]->{message}, qr/\Q$edge\E/, '... naming the stream that plays' );

	set_quality('standard');
	candidates('RN');
	$PH->onStream( $player, play_song( RN => 'https://cdn.example.net/2RNW/aac/', redir => $MH{RN} ) );
	@lines = fallback_lines();
	is( scalar @lines, 2, 'Icecast failed, the mediahub candidate plays from another host: logged' );
	like( $lines[-1]->{message}, qr/using mediahub instead of Icecast for RN\b/, '... "using mediahub instead of Icecast"' );

	set_quality('mediahub');
	candidates('RN');
	$PH->onStream( $player, play_song( RN => 'https://cdn.example.net/2RNW/aac/', redir => 'https://live-radio02.mediahubaustralia.com/2RNW/aac/' ) );
	is( scalar( fallback_lines() ), 2, 'a candidate of the first one\'s family (another mediahub host), redirected to another host: nothing logged' );

	$PH->onStream( $player, play_song( RN => ice('rnnsw'), redir => ['not a url'] ) );
	@lines = fallback_lines();
	is( scalar @lines, 3, 'an odd (ref) track redir is ignored: the stream that plays decides' );
	like( $lines[-1]->{message}, qr/using Icecast instead of mediahub for RN\b/, '... "using Icecast instead of mediahub"' );
	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'nothing at WARN or ERROR' );
};

subtest 'once-per-play guard: played songs are held weakly and forgotten once dropped (M3, #52)' => sub {
	reset_all();
	set_quality('mediahub');
	candidates('RN');
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );

	is_deeply( [ $S->_checked ], [ 0, 0 ], 'nothing remembered yet' );

	my $probe;
	{
		my $song = play_song( RN => ice('rnnsw') );
		$PH->onStream( $player, $song );
		is_deeply( [ $S->_checked ], [ 1, 1 ], 'a played song is remembered: one entry, holding it' );
		weaken( $probe = $song );
	}
	ok( !defined $probe, 'once the song goes out of scope it is freed: the guard does not keep it alive' );
	my ( $entries, $songs ) = $S->_checked;
	is( $songs, 0, '... no entry holds it any more' );
	ok( $entries <= 1, "... its entry is undef or gone ($entries left)" );

	# many songs dropped at once (distinct addresses): their undef entries are pruned on the next play
	my @dropped = map { play_song( RN => ice('rnnsw') ) } 1 .. 50;
	$S->noteStream( $player, $_, 'RN' ) for @dropped;
	is( ( $S->_checked )[1], 50, '50 songs playing: 50 entries holding them' );
	@dropped = ();
	is( ( $S->_checked )[1], 0, 'all 50 dropped: no entry holds a song' );

	my $playing = play_song( RN => ice('rnnsw') );
	$S->noteStream( $player, $playing, 'RN' );
	is_deeply( [ $S->_checked ], [ 1, 1 ], 'the next play prunes the undef entries: only the song playing is left' );

	my $lines = scalar fallback_lines();
	$S->noteStream( $player, play_song( RN => ice('rnnsw') ), 'RN' ) for 1 .. 3;
	$S->noteStream( $player, $playing, 'RN' );
	is( scalar( fallback_lines() ), $lines + 3, 'the song still playing is still checked only once per play (three new plays logged, it not again)' );
	is( ( $S->_checked )[1], 1, '... and it is the only song remembered' );
};

subtest 'one onStream: L2\'s metadata poll starts AND the fallback is logged; onStop stops the poll' => sub {
	reset_all();
	setTime( $NOW + 6900 );    # 07:55 UTC, inside the RN fixture's program (07:00-08:00 UTC)
	route( qr{/epgNowPlaying/RN/now\?}, file => 'live/bff-epgNowPlaying-RN-now.json' );
	set_quality('mediahub');
	candidates('RN');

	my $url    = 'abclisten://live/RN';
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );
	my $song   = play_song( RN => ice('rnnsw'), owner => $player );
	$player->setSong($song);
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$url];

	my $timers = sub { scalar grep { ref $_->{obj} && $_->{obj} == $player } Slim::Utils::Timers::pending() };

	ok( eval { $PH->onStream( $player, $song ); 1 }, 'onStream does not die' ) or diag $@;
	is( scalar( fallback_lines() ), 1, 'L5: the fallback line (using Icecast instead of mediahub for RN)' );
	is( scalar( grep { $_->{url} =~ m{/epgNowPlaying/RN/now} } requests() ), 1, 'L2: the program on air is fetched' );
	is( $timers->(), 1, 'L2: one poll timer for the player' );
	is( $PH->getMetadataFor( $player, $url )->{title}, 'The Radio National Hour', 'L2: Now Playing shows the program on air' );

	$PH->onStop($song);
	is( $timers->(), 0, 'onStop: L2\'s poll is stopped (no timer left)' );
	is( scalar( fallback_lines() ), 1, '... and no further fallback line' );
	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'nothing at WARN or ERROR' );
	delete $Slim::Player::Playlist::PLAYLISTS{ $player->id };
};

subtest 'onStream: a LiveMetadata::onStream that dies is logged and the fallback check still runs (L3)' => sub {
	reset_all();
	set_quality('mediahub');
	candidates('RN');
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::LiveMetadata::onStream = sub { die "metadata broke\n" };
		ok( eval { $PH->onStream( $player, play_song( RN => ice('rnnsw') ) ); 1 }, 'onStream does not die' ) or diag $@;
	}

	is( scalar( fallback_lines() ), 1, 'L5: the fallback line is still logged' );
	is( scalar( grep { $_->{message} =~ /Live metadata onStream failed: metadata broke/ } logged('WARN') ), 1, 'the die is logged at WARN' );
};

# ---- L6: liveQuality 'hls' ----

subtest 'L6 candidates: the HLS stream first (flagged hls), then the standard candidates' => sub {
	reset_all();
	set_quality('hls');

	is_deeply( answer('RN'),            [ hls( $HLS{RN} ), ice('rnnsw'), $MH{RN} ],                'RN: HLS, Icecast, mediahub' );
	is_deeply( answer('TRIPLEJ'),       [ hls( $HLS{TRIPLEJ} ), ice('triplejnsw'), $MH{TRIPLEJ} ], 'TRIPLEJ: HLS, Icecast, mediahub' );
	is_deeply( answer('CLASSIC2'),      [ hls( $HLS{CLASSIC2} ), ice('classic2'), 'https://live-radio01.mediahubaustralia.com/FM2W/aac/' ], 'CLASSIC2: StationData\'s own hls master first' );
	is_deeply( answer('TRIPLEJ_PERTH'), [ hls('https://streaming.abc-cdn.net.au/audio/hls/triplejwa.m3u8'), ice( $RECORD{TRIPLEJ_PERTH}->{mount} ) ], 'TRIPLEJ_PERTH (no mediahub): HLS, Icecast' );
	is_deeply( answer('NOPE'), { error => $UNAVAILABLE }, 'unknown id: UNAVAILABLE' );
	is( $S->hlsUrl('TRIPLEJ'), $HLS{TRIPLEJ}, 'hlsUrl: from hlsSlug' );
	is( $S->hlsUrl('ABCSPORTSYNC'), $HLS{RAPID}, 'hlsUrl: StationData\'s hls (StreamGuys)' );
	is( $S->hlsUrl($_), undef, 'hlsUrl ' . show($_) . ': undef' ) for 'SPORT_BBL', 'NOPE', undef;
	is( scalar( grep { $_->{url} =~ /\.m3u8/ } requests() ), 0, 'resolving fetches no .m3u8 (the protocol handler\'s HLS scan does)' );
};

subtest 'L6: HLS-only services are playable, resolvable and listed only with hls' => sub {
	my %want = (
		ABCSPORTSYNC   => [ hls( $HLS{RAPID} ) ],
		ABC_AFL_RAPID  => [ hls('https://abc-hls.streamguys1.com/hls/sport-sync-afl/playlist.m3u8') ],
		ITINERANT_FOUR => [ hls( $HLS{CRICKET} ) ],
		KIDSLISTEN_NT  => [ hls( $HLS{KIDS_NT} ) ],
		KIDSLISTEN_QLD => [ hls('https://streaming.abc-cdn.net.au/audio/hls/abckidsqld.m3u8') ],
		KIDSLISTEN_SA  => [ hls('https://streaming.abc-cdn.net.au/audio/hls/abckidssa.m3u8') ],
		KIDSLISTEN_WA  => [ hls('https://streaming.abc-cdn.net.au/audio/hls/abckidswa.m3u8') ],
	);

	reset_all();
	events_off_air();
	set_quality('hls');
	for my $id ( sort keys %want ) {
		is( $S->playable($id), 1, "hls, $id: playable" );
		is_deeply( answer($id), $want{$id}, "hls, $id: its HLS stream" );
		my $item = Plugins::ABCListen::Live->stationItem( undef, $id );
		is( $item && $item->{play}, "abclisten://live/$id", "hls, $id: a stationItem row (D4's Sport and Kids listen list it)" );
		is( $item && $item->{favorites_url}, "abclisten://live/$id", "hls, $id: favourites keep abclisten://live/$id" );
	}
	is_deeply( [ sport_ids() ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO ABCSPORTSYNC ABC_AFL_RAPID ITINERANT_FOUR)], 'hls: Radio -> Sport adds Sport Rapid, RLWC Rapid and ABC Cricket' );

	# an HLS-only record with a mediahub stream: HLS, then mediahub
	$S->_setRecords( { %{ $RECORD{LOCAL_WIDEBAY} }, mount => undef, hlsOnly => 1 } );
	is_deeply( answer('LOCAL_WIDEBAY'), [ hls( $RECORD{LOCAL_WIDEBAY}->{hls} ), $MH{WIDEBAY} ], 'hls, HLS-only with mediahub: HLS, then mediahub' );
	$S->_setRecords( { %{ $RECORD{KIDSLISTEN_NT} }, hlsSlug => undef } );
	is( $S->playable('KIDSLISTEN_NT'), 0, 'hls, an HLS-only record without an HLS stream: not playable' );
	is_deeply( answer('KIDSLISTEN_NT'), { error => $HLS_ONLY }, '... LIVE_HLS_ONLY' );
	$S->_setRecords();

	for my $q (@QUALITIES) {
		reset_all();
		events_off_air();
		set_quality($q);
		for my $id ( sort keys %want ) {
			is( $S->playable($id), 0, "$q, $id: not playable" );
			is( Plugins::ABCListen::Live->stationItem( undef, $id ), undef, "$q, $id: not listed" );
			is_deeply( answer($id), { error => $HLS_ONLY }, "$q, $id: LIVE_HLS_ONLY" );
		}
	}
	like( Slim::Utils::Strings::string($HLS_ONLY), qr/High quality \(HLS\)/, 'LIVE_HLS_ONLY tells the user which setting plays it' );
};

subtest 'L6 events: hls sources first; an event with only hls sources is on air only with hls' => sub {
	reset_all();
	set_quality('hls');
	route( "${BFF}epgNowPlaying/SPORT_BBL/now?imageRatio=1x1", content => $EVENT_MIXED );
	route( "${BFF}epgNowPlaying/SPORT_CRICKET/now?imageRatio=1x1", file => 'live/epg-event-hls-only.json' );
	route( 'https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls', content => "[playlist]\nFile1=" . ice('sport') . "\n" );
	events_off_air();

	is_deeply( answer('SPORT_BBL'), [ hls( $HLS{SPORT} ), ice('sport'), $MH{TENNIS} ], 'hls, on air (.pls + mediahub + hls): HLS, Icecast, mediahub' );
	my $sportitinerant = 'https://mediaserviceslive.akamaized.net/hls/live/2118991/sportitinerant/index.m3u8';
	is_deeply( answer('SPORT_CRICKET'), [ hls($sportitinerant) ], 'hls, hls (and hds) sources only: on air, the HLS stream (the .f4m ignored)' );
	is( $S->playable('SPORT_CRICKET'), 1, '... playable' );
	is_deeply( answer('SPORT_AFL'), { error => $OFF_AIR }, 'hls, no sources: LIVE_OFF_AIR' );

	set_quality('standard');
	is( $S->playable('SPORT_CRICKET'), 0, 'standard: the hls-only event is off air (cached status, no new request)' );
	is_deeply( answer('SPORT_CRICKET'), { error => $OFF_AIR }, 'standard: LIVE_OFF_AIR' );
	is_deeply( answer('SPORT_BBL'), [ ice('sport'), $MH{TENNIS} ], 'standard: no HLS candidate' );
	is( scalar( grep { $_->{url} =~ m{epgNowPlaying/SPORT_CRICKET} } requests() ), 1, 'one epg request for the event (cached across qualities)' );
};

subtest 'L6 whole catalogue with hls: the HLS stream first where there is one, then the standard candidates' => sub {
	my %answers;
	for my $q (qw(standard hls)) {
		reset_all();
		set_quality($q);
		route( qr{epgNowPlaying/}, content => $EVENT_MIXED );    # every event service on air
		route( qr{grandstand\.pls}, content => "[playlist]\nFile1=" . ice('sport') . "\n" );
		$answers{$q}{ $_->{id} } = answer( $_->{id} ) for @RECORDS;
		is( scalar( grep { $_->{url} =~ /\.m3u8/ } requests() ), 0, "$q: no .m3u8 request" );
	}

	my ( @wrong, $withHls );
	for my $rec (@RECORDS) {
		my ( $std, $hls ) = ( $answers{standard}{ $rec->{id} }, $answers{hls}{ $rec->{id} } );
		if ( ref $hls ne 'ARRAY' ) {
			push @wrong, "$rec->{id}: error in hls" ;
			next;
		}
		my @flagged = grep { ref $_ eq 'HASH' } @$hls;
		my @plain   = grep { !ref $_ } @$hls;
		push @wrong, "$rec->{id}: a flagged candidate after a plain one" if @flagged && ref $hls->[0] ne 'HASH';
		push @wrong, map {"$rec->{id}: bad hls candidate $_->{url}"} grep { !$_->{hls} || $_->{url} !~ m{\Ahttps://[^?#]+\.m3u8(?:\?|\z)} } @flagged;
		push @wrong, map {"$rec->{id}: unflagged $_"} grep { /\.(?:m3u8|f4m|pls|m3u)(?:[?#]|\z)/i || !m{\Ahttps://} } @plain;
		push @wrong, "$rec->{id}: [@plain] is not standard's" if ref $std eq 'ARRAY' && "@plain" ne "@$std";
		push @wrong, "$rec->{id}: no HLS stream" unless @flagged;
		$withHls++ if @flagged;
	}
	is_deeply( \@wrong, [], 'hls: every station starts with its HLS stream, then exactly the standard candidates' );
	is( $withHls, scalar @RECORDS, "hls: all $withHls stations (and on-air events) have an HLS stream" );
};

subtest 'L6 onStream: an HLS fallback is logged once per play ("using Icecast instead of HLS")' => sub {
	reset_all();
	set_quality('hls');
	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );

	candidates('TRIPLEJ');
	$PH->onStream( $player, play_song( TRIPLEJ => ice('triplejnsw') ) );
	my @lines = fallback_lines();
	is( scalar @lines, 1, 'HLS failed, Icecast plays: one INFO line' );
	like( $lines[0] && $lines[0]->{message}, qr/using Icecast instead of HLS for TRIPLEJ \(\Q$HLS{TRIPLEJ}\E could not be played/, '... "using Icecast instead of HLS for TRIPLEJ (<the .m3u8> could not be played"' );

	$PH->onStream( $player, play_song( TRIPLEJ => $HLS{TRIPLEJ} ) );
	is( scalar( fallback_lines() ), 1, 'HLS plays: nothing logged' );

	$PH->onStream( $player, play_song( TRIPLEJ => $MH{TRIPLEJ} ) );
	like( ( fallback_lines() )[-1]->{message}, qr/using mediahub instead of HLS for TRIPLEJ\b/, 'HLS and Icecast failed, mediahub plays: "using mediahub instead of HLS"' );
	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'nothing at WARN or ERROR' );
};

subtest 'L6 bitrate: the station fallback metadata claims no Icecast bitrate with hls' => sub {
	reset_all();
	is( Plugins::ABCListen::Live::_metadata( undef, 'abclisten://live/TRIPLEJ', 'TRIPLEJ' )->{bitrate}, '56kbps CBR', 'standard, not playing: 56kbps CBR (Icecast)' );
	set_quality('hls');
	is( Plugins::ABCListen::Live::_metadata( undef, 'abclisten://live/TRIPLEJ', 'TRIPLEJ' )->{bitrate}, undef, 'hls, not playing: no bitrate (HLS is tried first)' );

	my $player = ABCListenTest::FakeClient->new( '00:00:00:00:00:01', song => undef );
	my $song   = play_song( TRIPLEJ => $HLS{TRIPLEJ}, owner => $player );
	$player->setSong($song);
	is( Plugins::ABCListen::Live::_metadata( $player, 'abclisten://live/TRIPLEJ', 'TRIPLEJ' )->{bitrate}, undef, 'hls, playing HLS: none from the kind (LMS shows the track\'s measured bitrate)' );
	$song->{streamUrl} = ice('triplejnsw');
	is( Plugins::ABCListen::Live::_metadata( $player, 'abclisten://live/TRIPLEJ', 'TRIPLEJ' )->{bitrate}, '56kbps CBR', 'hls, fell back to Icecast: 56kbps CBR' );
};

# ---- the settings page ----

subtest 'Settings: prefs list, saves, partial POSTs, rejected and HTML values' => sub {
	reset_all();
	Plugins::ABCListen::MyABC->init;    # M1's homeState default and validator
	my $P = 'Plugins::ABCListen::Settings';

	my ( $ns, @names ) = $P->prefs;
	is( $ns, $prefs, 'prefs namespace is plugin.abclisten' );
	is_deeply( \@names, [qw(homeState liveQuality)], 'the page handles homeState, then (appended) liveQuality' );

	$prefs->set( homeState => 'WA' );
	my $params = { saveSettings => 1, pref_liveQuality => 'mediahub' };
	$P->handler( undef, $params );
	is( $prefs->get('liveQuality'), 'mediahub', 'POST pref_liveQuality=mediahub saves mediahub' );
	is( $prefs->get('homeState'), 'WA', '... and leaves homeState unchanged' );
	is( $params->{prefs}->{pref_liveQuality}, 'mediahub', '... and the page shows mediahub' );

	$P->handler( undef, { saveSettings => 1, pref_homeState => 'SA' } );
	is( $prefs->get('homeState'), 'SA', 'POST pref_homeState=SA saves SA' );
	is( $prefs->get('liveQuality'), 'mediahub', '... and leaves liveQuality unchanged' );

	$P->handler( undef, { saveSettings => 1, pref_homeState => 'SA', pref_liveQuality => 'standard' } );
	is( $prefs->get('liveQuality'), 'standard', 'POST of both fields (the browser form) saves both' );

	$params = { saveSettings => 1, pref_liveQuality => 'hls' };
	$P->handler( undef, $params );
	is( $prefs->get('liveQuality'), 'hls', 'L6: POST pref_liveQuality=hls saves hls' );
	is( $params->{prefs}->{pref_liveQuality}, 'hls', '... and the page shows hls' );
	$P->handler( undef, { saveSettings => 1, pref_liveQuality => 'standard' } );

	for my $bad ( 'HLS', 'foo', 'Mediahub', q{<script>alert("x")</script>&'}, 'mediahub"><img src=x>' ) {
		$params = { saveSettings => 1, pref_liveQuality => $bad };
		$P->handler( undef, $params );
		is( $prefs->get('liveQuality'), 'standard', 'POST ' . show($bad) . ' is rejected' );
		is( $params->{pref_liveQuality}, html_escape($bad), '... and the value LMS echoes is HTML-escaped' );

		my $escaped = { saveSettings => 1, pref_liveQuality => html_escape($bad) };
		$P->handler( undef, $escaped );
		is( $prefs->get('liveQuality'), 'standard', '... its escaped form posted as is is rejected too' );
	}
};

subtest 'template: the L5 section' => sub {
	my $html = slurp($TEMPLATE);
	my @markers = $html =~ /<!-- === (\/?\w+) === -->/g;
	is_deeply( \@markers, [qw(M1 /M1 L5 /L5)], 'owner sections M1, then L5' );

	my ($l5) = $html =~ m{<!-- === L5 === -->(.*?)<!-- === /L5 === -->}s;
	ok( defined $l5, 'the L5 section exists' ) or return;
	( my $outside = $html ) =~ s{<!-- === L5 === -->.*?<!-- === /L5 === -->}{}s;
	unlike( $outside, qr/liveQuality|LIVE_QUALITY/, 'nothing about liveQuality outside the L5 section' );

	like( $l5, qr/\[% WRAPPER setting title="PLUGIN_ABCLISTEN_LIVE_QUALITY" desc="PLUGIN_ABCLISTEN_LIVE_QUALITY_DESC" %\]/, 'setting WRAPPER with title and description' );

	my @select = $l5 =~ /(<select\b[^>]*>)/g;
	is( scalar @select, 1, 'one select' );
	my $select = $select[0] // '';
	like( $select, qr/\bname="pref_liveQuality"/, 'name="pref_liveQuality"' );
	like( $select, qr/\bid="liveQuality"/, 'id="liveQuality" (the pref name, as in M1: the settings footer binds its validator by id)' );
	like( $select, qr/\baria-label="\[% 'PLUGIN_ABCLISTEN_LIVE_QUALITY' \| string \| html %\]"/, 'explicit accessible name: aria-label from PLUGIN_ABCLISTEN_LIVE_QUALITY' );
	is( scalar( () = $html =~ /\bid="liveQuality"/g ), 1, 'the id is unique in the page' );

	my ($options) = $l5 =~ m{<select\b[^>]*>(.*?)</select>}s;
	my @opts = ( $options // '' ) =~ /(<option\b[^>]*>.*?<\/option>)/gs;
	is_deeply( [ map { /\bvalue="([^"]*)"/ ? $1 : '?' } @opts ], [@VALID], '3 options in order: standard, hls (L6), mediahub' );
	is_deeply( [ map { /\[% '(PLUGIN_ABCLISTEN_\w+)' \| string \| html %\]/ ? $1 : '?' } @opts ], [ map {"PLUGIN_ABCLISTEN_LIVE_QUALITY_\U$_"} @VALID ], 'their labels (HTML-escaped strings)' );
	is( Slim::Utils::Strings::string('PLUGIN_ABCLISTEN_LIVE_QUALITY_HLS'), 'High quality (HLS)', 'L6: the hls option reads "High quality (HLS)"' );
	for my $q (@VALID) {
		like( $options, qr/<option value="$q"\[% IF prefs\.pref_liveQuality == '$q' %\] selected="selected"\[% END %\]>/, "$q selected from prefs.pref_liveQuality (an unknown value selects nothing)" );
	}
	( my $markup = $l5 ) =~ s/\[%#.*?%\]//gs;    # without template comments
	unlike( $markup, qr/\bdisabled\b|PlayHLS/i, 'L6: the HLS option needs no PlayHLS note or disabled state (always offered)' );

	# M3 (#52): the select is described by a hidden, id-bearing copy of the setting's description,
	# and by nothing else (no PlayHLS note); core's description div (WRAPPER desc) is unchanged
	is_deeply( [ $markup =~ /\baria-describedby="([^"]*)"/g ], ['liveQuality-desc'], 'one aria-describedby, on the select: liveQuality-desc' );
	like( $select, qr/\baria-describedby="liveQuality-desc"/, '... the select is described by liveQuality-desc' );
	my @desc;
	push @desc, $1 while $markup =~ /(<(\w+)\b[^>]*\bid="liveQuality-desc"[^>]*>.*?<\/\2>)/gs;
	is( scalar @desc, 1, 'one element with id liveQuality-desc in the section' );
	like( $desc[0] // '', qr/\A<span id="liveQuality-desc" hidden>\[% 'PLUGIN_ABCLISTEN_LIVE_QUALITY_DESC' \| string \| html %\]<\/span>\z/, '... a hidden span with the description (HTML-escaped)' );
	unlike( $desc[0] // '', qr/\bclass=/, '... without a class (not hiddenDesc: core\'s and Material\'s help icon are unchanged)' );
	is( scalar( () = $html =~ /\bid="liveQuality-desc"/g ), 1, '... and its id is unique in the page' );
	my ($before) = $l5 =~ /\A(.*?)<span id="liveQuality-desc"/s;
	like( $before // '', qr/desc="PLUGIN_ABCLISTEN_LIVE_QUALITY_DESC" %\]\s*\z/, '... first in the WRAPPER content, which still passes desc to core' );

	my %tokens = map { $_ => 1 } $l5 =~ /\b(PLUGIN_ABCLISTEN\w*)/g;
	is_deeply( [ sort keys %tokens ], [ sort @L5_TOKENS ], 'the section uses the five tokens (L5\'s four, L6\'s _HLS)' );
	ok( Slim::Utils::Strings::stringExists($_) && length Slim::Utils::Strings::string($_), "$_ has EN text" ) for @L5_TOKENS;
	ok( !Slim::Utils::Strings::stringExists($_), "$_ is gone from strings.txt" ) for qw(PLUGIN_ABCLISTEN_LIVE_QUALITY_NO_PLAYHLS);
};

subtest 'main::WEBUI false (LMS --noweb): liveQuality still initialised and validated' => sub {
	my $lib  = File::Spec->catdir( $ROOT, 't', 'lib' );
	my $code = <<'PERL';
use strict;
use warnings;
use ABCListenTest;
BEGIN { no warnings 'redefine'; no strict 'refs'; *{'main::WEBUI'} = sub () { 0 }; }
use Slim::Utils::Prefs;
require Plugins::ABCListen::Live;
my $ok = eval { Plugins::ABCListen::Live->init(); 1 } ? 1 : 0;
my $p  = preferences('plugin.abclisten');
my $default = $p->get('liveQuality');
my (undef, $setBad) = $p->set( liveQuality => 'HLS' );
my (undef, $setHls) = $p->set( liveQuality => 'hls' );
my (undef, $setMh)  = $p->set( liveQuality => 'mediahub' );
print join( "\n", "initOk=$ok", "default=$default", "setBad=$setBad", "setHls=$setHls", "setMh=$setMh", 'value=' . $p->get('liveQuality') ), "\n";
PERL
	open( my $ph, '-|', $^X, "-I$lib", '-e', $code ) or die "Can't run $^X: $!";
	my %out = map { chomp; split /=/, $_, 2 } <$ph>;
	close $ph;
	is( $?, 0, 'child perl exited cleanly' );
	is( $out{initOk},  1,          'Live->init does not die' );
	is( $out{default}, 'standard', 'liveQuality initialised to standard' );
	is( $out{setBad},  0,          'HLS rejected' );
	is( $out{setHls},  1,          'L6: hls accepted' );
	is( $out{setMh},   1,          'mediahub accepted' );
	is( $out{value},   'mediahub', 'liveQuality is mediahub' );
};

done_testing();

# ---- fakes: a played song and its track ----

package L5Track;

sub new   { my ( $class, %args ) = @_; return bless {%args}, $class }
sub url   { $_[0]->{url} }
sub redir { $_[0]->{redir} }

package L5Song;

# Like Slim::Player::Song: streamUrl, currentTrack, master (the owner's master) and pluginData (not
# namespaced; recorded here only to show nothing writes to it).
sub new          { my ( $class, %args ) = @_; return bless { pluginData => {}, %args }, $class }
sub streamUrl    { $_[0]->{streamUrl} }
sub currentTrack { $_[0]->{track} }
sub master       { $_[0]->{owner} ? $_[0]->{owner}->master : undef }

sub pluginData {
	my ( $self, $key, $value ) = @_;
	return $self->{pluginData} unless defined $key;
	$self->{pluginData}->{$key} = $value if defined $value;
	return $self->{pluginData}->{$key};
}

package L5BareSong;

sub new       { my ( $class, %args ) = @_; return bless {%args}, $class }
sub streamUrl { $_[0]->{streamUrl} }
