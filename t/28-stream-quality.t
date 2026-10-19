#!/usr/bin/perl
# L5 (#14): the liveQuality pref and the live stream order, offline.
#   * the pref: Live->init default 'standard' (stored values kept), the validator truth table (named
#     sub and through the prefs stub's set: exactly 'standard' and 'mediahub'; 'hls' is rejected, there
#     is no HLS option until L6), HTML-escaped forms of rejected values rejected too, and the effective
#     quality (undef and any other stored value, e.g. a hand-edited 'hls', play as 'standard');
#   * Stations->streamCandidates per quality x {network with mediahub, variant without, Wide Bay,
#     HLS-only with and without mediahub, event-only on air / off air, unknown}; over the whole
#     catalogue x every quality: never .m3u8/.f4m/.pls, https only, unknown values = 'standard';
#   * listing: playable, Radio -> Sport and stationItem are the same in every quality (HLS-only and
#     Kids listen versions hidden); favourites keep abclisten://live/<ID>;
#   * the live kind: resolve order in 'mediahub'; onStream's fallback INFO line, once per play, through
#     ProtocolHandler->onStream (none when the first candidate plays, after a redirect, or within a
#     family; nothing written to the song); one onStream also starts L2's metadata poll, and onStop
#     still stops it;
#   * the settings page: Settings->prefs (homeState, then liveQuality), saves and partial POSTs, rejected
#     and HTML values; the template's L5 section (name/id, aria-label, 2 options, no HLS), every token
#     defined;
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

my @QUALITIES = qw(standard mediahub);
my @INVALID   = ( 'hls', 'HLS', 'Standard', 'STANDARD', 'MediaHub', ' mediahub', 'mediahub ', "mediahub\n", 'foo', '', '0', 'standard,mediahub', '<script>alert(1)</script>', 'mediahub"><b>', q{mediahub'&}, 'standard&' );
my @INVALID_REFS = ( [], {}, ['mediahub'], { mediahub => 1 }, \'mediahub' );

my @L5_TOKENS = map {"PLUGIN_ABCLISTEN_LIVE_QUALITY$_"} ( '', qw(_DESC _STANDARD _MEDIAHUB) );

my %MH = (
	RN      => 'https://live-radio01.mediahubaustralia.com/2RNW/aac/',
	TRIPLEJ => 'https://live-radio01.mediahubaustralia.com/2TJW/aac/',
	WIDEBAY => 'https://live-radio03.mediahubaustralia.com/4BBGW/aac/',
	TENNIS  => 'https://live-radio02.mediahubaustralia.com/TENW/aac/',
	ITONE   => 'https://live-radio01.mediahubaustralia.com/IT1W/aac/',
);

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
	if ( defined $q && !ref $q && grep { $_ eq $q } @QUALITIES ) {
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
	is( $prefs->get('liveQuality'), 'hls', 'init does not touch a stored unknown value (hand-edited hls)' );
	is( $S->liveQuality, 'standard', '... which plays as standard' );
	is( scalar( logged('ERROR') ) + scalar( logged('WARN') ), 0, 'nothing logged at WARN or ERROR' );
};

subtest 'validator truth table (named sub): standard and mediahub only; escaped forms rejected too' => sub {
	my $v = \&Plugins::ABCListen::Stations::validateLiveQuality;
	ok( $v->( 'liveQuality', $_ ), "valid: '$_'" ) for @QUALITIES;
	ok( !$v->( 'liveQuality', $_ ), 'invalid: ' . show($_) ) for @INVALID, @INVALID_REFS, undef;

	my @escaped = grep { $_ ne html_escape($_) } @INVALID;
	is( scalar @escaped, 4, 'four rejected values change when HTML-escaped' );
	ok( !$v->( 'liveQuality', html_escape($_) ), 'escaped form rejected too: ' . show( html_escape($_) ) ) for @escaped;
	ok( !$v->( 'liveQuality', html_escape( html_escape($_) ) ), 'twice-escaped form rejected: ' . show($_) ) for @escaped;
};

subtest 'validator through the prefs layer (set: JSON-RPC pref command, settings form)' => sub {
	reset_all();

	for my $q (@QUALITIES) {
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
	for my $q (@QUALITIES) {
		set_quality($q);
		is( $S->liveQuality, $q, "stored '$q' -> $q" );
	}
	for my $q ( undef, 'hls', 'foo', '', 'MEDIAHUB', ['mediahub'], { mediahub => 1 } ) {
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

subtest 'candidates: HLS-only services (with and without mediahub) in every quality' => sub {
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

	for my $q ( @QUALITIES, 'unset', 'hls (hand-edited)' ) {
		reset_all();
		set_quality( $q eq 'unset' ? undef : $q =~ /^hls/ ? 'hls' : $q );
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

	is_deeply( $answers{$_}, $answers{standard}, "$_: the same candidates as standard" ) for 'unset', 'hls (hand-edited)';

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
	return map { ( $_->{url} // '' ) =~ m{\Aabclisten://live/(\w+)\z} ? $1 : '?' } @{ ( $c->args(0) )[0]->{items} };
}

subtest 'listing: playable, Radio -> Sport and stationItem are the same in every quality' => sub {
	my %playable;
	for my $q ( @QUALITIES, 'hls (hand-edited)' ) {
		reset_all();
		events_off_air();
		set_quality( $q =~ /^hls/ ? 'hls' : $q );
		$playable{$q} = { map { $_->{id} => $S->playable( $_->{id} ) } @RECORDS };

		my @sport = sport_ids();
		is_deeply( \@sport, [qw(GRANDSTAND ITINERANT_THREE ITINERANT_ONE ITINERANT_TWO)], "$q: Radio -> Sport lists the four Icecast sport services" );
		for my $id ( @HLS_ONLY_SPORT, @KIDS_VERSIONS ) {
			is( $S->playable($id), 0, "$q, $id: not playable" );
			is( Plugins::ABCListen::Live->stationItem( undef, $id ), undef, "$q, $id: no stationItem (D4's Sport and Kids listen)" );
		}

		my $item = Plugins::ABCListen::Live->stationItem( undef, 'TRIPLEJ' );
		is( $item->{url},           'abclisten://live/TRIPLEJ', "$q: the row plays abclisten://live/TRIPLEJ" );
		is( $item->{favorites_url}, 'abclisten://live/TRIPLEJ', "$q: favourites keep abclisten://live/TRIPLEJ" );
		is( scalar( grep { !ref && /streamguys1|mediahubaustralia|streaming\.abc-cdn|\.m3u8|\.pls/ } values %$item ), 0, "$q: no stream URL in the row" );
	}
	is_deeply( $playable{$_}, $playable{standard}, "$_: playable as in standard for every station" ) for 'mediahub', 'hls (hand-edited)';
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

	set_quality('hls');
	$c = collector();
	Plugins::ABCListen::Live::_resolve( undef, 'RN', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => ice('rnnsw'), alternates => [ $MH{RN} ], failToken => $LIVE_FAILED } ], 'a hand-edited hls: as standard' );
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

	for my $bad ( 'hls', 'foo', 'Mediahub', q{<script>alert("x")</script>&'}, 'mediahub"><img src=x>' ) {
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
	is_deeply( [ map { /\bvalue="([^"]*)"/ ? $1 : '?' } @opts ], [@QUALITIES], '2 options in order: standard, mediahub (no HLS until L6)' );
	is_deeply( [ map { /\[% '(PLUGIN_ABCLISTEN_\w+)' \| string \| html %\]/ ? $1 : '?' } @opts ], [ map {"PLUGIN_ABCLISTEN_LIVE_QUALITY_\U$_"} @QUALITIES ], 'their labels (HTML-escaped strings)' );
	for my $q (@QUALITIES) {
		like( $options, qr/<option value="$q"\[% IF prefs\.pref_liveQuality == '$q' %\] selected="selected"\[% END %\]>/, "$q selected from prefs.pref_liveQuality (an unknown value selects nothing)" );
	}
	( my $markup = $l5 ) =~ s/\[%#.*?%\]//gs;    # without template comments
	unlike( $markup, qr/\bdisabled\b|\bhls\b|PlayHLS|aria-describedby/i, 'no HLS option, note or disabled state' );

	my %tokens = map { $_ => 1 } $l5 =~ /\b(PLUGIN_ABCLISTEN\w*)/g;
	is_deeply( [ sort keys %tokens ], [ sort @L5_TOKENS ], 'the section uses the four L5 tokens' );
	ok( Slim::Utils::Strings::stringExists($_) && length Slim::Utils::Strings::string($_), "$_ has EN text" ) for @L5_TOKENS;
	ok( !Slim::Utils::Strings::stringExists($_), "$_ is gone from strings.txt" ) for qw(PLUGIN_ABCLISTEN_LIVE_QUALITY_HLS PLUGIN_ABCLISTEN_LIVE_QUALITY_NO_PLAYHLS);
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
my (undef, $setHls) = $p->set( liveQuality => 'hls' );
my (undef, $setMh)  = $p->set( liveQuality => 'mediahub' );
print join( "\n", "initOk=$ok", "default=$default", "setHls=$setHls", "setMh=$setMh", 'value=' . $p->get('liveQuality') ), "\n";
PERL
	open( my $ph, '-|', $^X, "-I$lib", '-e', $code ) or die "Can't run $^X: $!";
	my %out = map { chomp; split /=/, $_, 2 } <$ph>;
	close $ph;
	is( $?, 0, 'child perl exited cleanly' );
	is( $out{initOk},  1,          'Live->init does not die' );
	is( $out{default}, 'standard', 'liveQuality initialised to standard' );
	is( $out{setHls},  0,          'hls rejected' );
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
