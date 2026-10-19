#!/usr/bin/perl
# Plugins::ABCListen::LiveMetadata (offline, fake clock, FakeClient incl. a sync group), through the
# live kind as Live->init registers it: the first metadata call returns the station fallback and
# starts a fetch; program-mode fields; buildMeta and nextDelay (end + 30 s, clamped 60-900 s); the
# poll per master player started by onStream, its push sequence (setCurrentTitle without a client ->
# currentPlaylistUpdateTime -> newmetadata; no wmaMeta) only when the metadata changed; 30 s after a
# failed fetch or a push that dies; stop, URL change and onStop leave no timers; pause keeps polling;
# a station switch moves the poll; master-only polling; stale-poll recovery (forgotten timers, a
# reconnected player, LMS restart); one upstream request for many players; $song->duration and
# startOffset never called; the "Program info" song-info entry (with and without Next, the 3 s
# deadline, exactly one answer).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();
use POSIX ();

use Slim::Control::Request;
use Slim::Menu::TrackInfo;
use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use ABCListenTest::FakeClient;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::LiveMetadata;
use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util qw(parseISO8601);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $PH  = 'Plugins::ABCListen::ProtocolHandler';
my $LM  = 'Plugins::ABCListen::LiveMetadata';
my $NP  = 'Plugins::ABCListen::NowPlaying';
my $S   = 'Plugins::ABCListen::Stations';
my $BFF = 'https://www.abc.net.au/core-next/api/';

my $RN_URL    = 'abclisten://live/RN';
my $PERTH_URL = 'abclisten://live/TRIPLEJ_PERTH';
my $RN_START  = parseISO8601('2026-10-19T07:00:00Z');    # The Radio National Hour, 6:00pm-7:00pm AEDT
my $RN_END    = parseISO8601('2026-10-19T08:00:00Z');
my $RN_580    = 'https://resize.abcradio.net.au/KYPnLYzMajKvohTSDh2eooeqsU0=/580x580/center/middle/https%3A%2F%2Fwww.abc.net.au%2Fradio%2Fimages%2Fprograms-2026%2FTheRadioNationalHour_3000x3000.jpg';
my $LNL_IMAGE = 'https://resize.abcradio.net.au/sig=/580x580/center/middle/lnl.jpg';

my $RN_LOGO = Plugins::ABCListen::API::imageUrl( $S->get('RN')->{logo}, 600 );

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

# The EPG answer for epgNowPlaying/<id>/<variant>: a body (string), a fixture name or { code => ... }.
my %EPG;

sub epg_route {
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{/epgNowPlaying/}, sub {
		my ($url) = @_;
		my ( $id, $variant ) = $url =~ m{/epgNowPlaying/([A-Z0-9_]+)/(now|next)\?} or return;
		my $answer = $EPG{"$id/$variant"};
		return { code => 404 } unless defined $answer;
		return $answer if ref $answer eq 'HASH';
		return { content => $answer =~ /\A[\[{n]/ ? $answer : fixture($answer) };
	} );
	return;
}

sub epg {
	my %p = @_;
	return JSON::PP->new->utf8->canonical->encode( {
		title => $p{title},
		start => POSIX::strftime( '%Y-%m-%dT%H:%M:%S+00:00', gmtime( $p{start} ) ),
		end   => POSIX::strftime( '%Y-%m-%dT%H:%M:%S+00:00', gmtime( $p{end} ) ),
		preparedPresenters => [ map { { names => { full => $_ } } } @{ $p{presenters} || [] } ],
		$p{image} ? ( preparedImage => { imgSrc => $p{image} } ) : (),
	} );
}

my $LNL = epg( title => 'Late Night Live', start => $RN_END, end => $RN_END + 3600, presenters => ['David Marr'], image => $LNL_IMAGE );

my @TITLE_CALLS_ALL;    # every setCurrentTitle call, never reset
my @ORDER;    # setCurrentTitle / currentPlaylistUpdateTime / notifyFromArray calls, in order

{
	no warnings 'redefine';

	my $setTitle = \&Slim::Music::Info::setCurrentTitle;
	*Slim::Music::Info::setCurrentTitle = sub { push @ORDER, [ setCurrentTitle => @_ ]; push @TITLE_CALLS_ALL, [@_]; goto &$setTitle };

	my $notify = \&Slim::Control::Request::notifyFromArray;
	*Slim::Control::Request::notifyFromArray = sub { push @ORDER, [ notify => $_[0], @{ $_[1] } ]; goto &$notify };

	my $update = \&ABCListenTest::FakeClient::currentPlaylistUpdateTime;
	*ABCListenTest::FakeClient::currentPlaylistUpdateTime = sub { push @ORDER, [ updateTime => $_[0] ] if @_ > 1; goto &$update };
}

my @SONGS;    # every song made, to check duration/startOffset at the end

sub reset_all {
	resetStubs();
	$S->_reset();
	$NP->_reset();
	$LM->_reset();
	ABCListenTest::FakeClient->resetEvents;
	@ORDER = ();
	%EPG   = ( 'RN/now' => 'live/bff-epgNowPlaying-RN-now.json', 'RN/next' => 'live/bff-epgNowPlaying-RN-next.json' );
	epg_route();
	setTime( $RN_END - 300 );    # 6:55pm AEDT
	Plugins::ABCListen::Live->init();
	return;
}

# A player (or a slave of $master) playing $url.
sub player {
	my ( $mac, $url, $master ) = @_;
	my $player = $master ? $master->makeSlave($mac) : ABCListenTest::FakeClient->new($mac);
	play( $player->master, $url ) unless $master;

	# a sync group shares the master's playlist
	$Slim::Player::Playlist::PLAYLISTS{$mac} = $Slim::Player::Playlist::PLAYLISTS{ $master->id } if $master;
	return $player;
}

sub play {
	my ( $player, $url ) = @_;
	my $song = L2Song->new( $url, $player );
	push @SONGS, $song;
	$player->setSong($song);
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$url];
	return $song;
}

sub epg_requests {
	my $re = shift || qr{/epgNowPlaying/};
	return scalar grep { $_->{url} =~ $re } requests();
}

sub timers_for { my $p = shift; return grep { ref $_->{obj} && $_->{obj} == $p } Slim::Utils::Timers::pending() }

sub pushes { grep { $_->[0] eq 'notify' && $_->[2] eq 'newmetadata' } @ORDER }

sub next_poll_in {
	my $player = shift;
	my ($timer) = timers_for($player);
	return $timer ? $timer->when - Time::HiRes::time() : undef;
}

# ---- the hook, buildMeta, nextDelay ----

subtest 'metadata: station fallback and an async fetch first, then program mode' => sub {
	reset_all();
	$EPG{'RN/now'} = { content => fixture('live/bff-epgNowPlaying-RN-now.json'), defer => 1 };

	my $meta = $PH->getMetadataFor( undef, $RN_URL );
	is( $meta->{title},  'Radio National', 'first call: the station name' );
	is( $meta->{artist}, 'ABC listen',     '... "ABC listen"' );
	is( $meta->{cover},  $RN_LOGO,         '... the station logo' );
	is( $meta->{bitrate}, '56kbps CBR',    '... L1 bitrate kept' );
	is( epg_requests(), 1, 'the first call starts a fetch (asynchronous)' );

	$PH->getMetadataFor( undef, $RN_URL ) for 1 .. 3;
	is( epg_requests(), 1, 'further calls join the request in flight' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	$meta = $PH->getMetadataFor( undef, $RN_URL );
	is( $meta->{title},  'The Radio National Hour', 'program mode: title = program' );
	is( $meta->{artist}, 'Fran Kelly',              'artist = presenters' );
	is( $meta->{album},  'Radio National',          'album = station name' );
	is( $meta->{cover},  $RN_580,                   'cover = the program image (580 px)' );
	is( $meta->{bitrate}, '56kbps CBR', 'bitrate kept' );
	is( $PH->getCurrentTitle( undef, $RN_URL ), 'The Radio National Hour', 'getCurrentTitle: the program' );

	$PH->getMetadataFor( undef, $RN_URL ) for 1 .. 3;
	is( epg_requests(), 1, 'fresh: no more requests' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no player: nothing polls' );

	$EPG{'TRIPLEJ_PERTH/now'} = 'live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json';
	setTime( parseISO8601('2026-10-19T05:00:00Z') );
	$PH->getMetadataFor( undef, $PERTH_URL );
	$meta = $PH->getMetadataFor( undef, $PERTH_URL );
	is( $meta->{title},  'Drive',          'TRIPLEJ_PERTH: its own program' );
	is( $meta->{artist}, 'Jordan & Luka',  '... presenters' );
	is( $meta->{album},  'triple j Perth', '... its own station name' );
};

subtest 'buildMeta and nextDelay (pure)' => sub {
	my $station = { title => 'Radio National', artist => 'ABC listen', cover => 'logo', bitrate => '56kbps CBR' };

	is_deeply( $LM->buildMeta( $station, undef ), $station, 'no program: the station metadata' );
	is_deeply( $LM->buildMeta( $station, { presenters => 'x' } ), $station, 'a program without a title: the station metadata' );
	is_deeply(
		$LM->buildMeta( $station, { title => 'P', presenters => 'A, B', image => 'img' } ),
		{ title => 'P', artist => 'A, B', album => 'Radio National', cover => 'img', bitrate => '56kbps CBR' },
		'program mode'
	);
	is_deeply(
		$LM->buildMeta( $station, { title => 'P' } ),
		{ title => 'P', artist => 'Radio National', album => 'Radio National', cover => 'logo', bitrate => '56kbps CBR' },
		'no presenters: artist = station name; no image: the station cover'
	);
	is_deeply( $station, { title => 'Radio National', artist => 'ABC listen', cover => 'logo', bitrate => '56kbps CBR' }, 'the station metadata is not changed' );

	my $now = 1000;
	is( $LM->nextDelay( { end => $now + 300 },  $now ), 330, 'end in 5 min: end + 30 s' );
	is( $LM->nextDelay( { end => $now + 10 },   $now ), 60,  'end in 10 s: at least 60 s' );
	is( $LM->nextDelay( { end => $now - 600 },  $now ), 60,  'end passed (stale EPG): 60 s' );
	is( $LM->nextDelay( { end => $now + 7200 }, $now ), 900, 'end in 2 h: at most 15 min' );
	is( $LM->nextDelay( { title => 'x' },       $now ), 60,  'no end: 60 s' );
	is( $LM->nextDelay( undef,                  $now ), 60,  'no program: 60 s' );
};

# ---- the poll ----

subtest 'onStream: one poll per master, the push sequence, next poll at end + 30 s' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );

	$PH->onStream( $player, $player->playingSong );

	is( epg_requests(), 1, 'onStream fetches the program' );
	is_deeply(
		[ map { $_->[0] } @ORDER ],
		[qw(setCurrentTitle updateTime notify)],
		'push order: setCurrentTitle -> currentPlaylistUpdateTime -> newmetadata'
	);
	is_deeply( [ @{ $ORDER[0] }[ 1 .. $#{ $ORDER[0] } ] ], [ $RN_URL, 'The Radio National Hour' ], 'setCurrentTitle($url, $program): no client' );
	ok( $ORDER[1]->[1] == $player, 'currentPlaylistUpdateTime on the master' );
	ok( $ORDER[2]->[1] == $player && $ORDER[2]->[2] eq 'newmetadata', "notifyFromArray(\$master, ['newmetadata'])" );
	is( Slim::Music::Info::getCurrentTitle( undef, $RN_URL ), 'The Radio National Hour', 'the stored current title is the program' );
	is( $PH->getMetadataFor( $player, $RN_URL )->{title}, 'The Radio National Hour', 'Now Playing (the kind\'s metadata) shows the program' );

	is( scalar( grep { $_->[0] eq 'pluginData' } @ABCListenTest::FakeClient::EVENTS ), 0, 'no song pluginData written (no wmaMeta)' );
	is( scalar( timers_for($player) ), 1, 'one timer for the player' );
	is( next_poll_in($player), 330, 'next poll at the program end + 30 s (330 s)' );
	ok( scalar( grep { $_->{message} =~ /next poll for 00:00:00:00:00:01 in 330 s/ } logged('DEBUG') ), 'DEBUG "next poll for <player> in 330 s"' );

	$PH->onStream( $player, $player->playingSong );
	is( epg_requests(), 1, 'onStream again (a seek): the running poll is kept' );
	is( scalar( pushes() ), 1, '... no second push' );
};

subtest 'program change: exactly one push; unchanged data: none; finished program: every 60 s' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );
	@ORDER = ();

	$EPG{'RN/now'} = $LNL;
	advanceTime(330);
	is( epg_requests(), 2, 'the poll at end + 30 s fetches again' );
	is( scalar( pushes() ), 1, 'the program changed: one push' );
	is( $ORDER[0]->[2], 'Late Night Live', '... with the new title' );
	my $meta = $PH->getMetadataFor( $player, $RN_URL );
	is_deeply( [ @{$meta}{qw(title artist album cover)} ], [ 'Late Night Live', 'David Marr', 'Radio National', $LNL_IMAGE ], 'Now Playing: the new program' );
	is( next_poll_in($player), 900, 'next poll: end is 1 h away -> 15 min' );

	@ORDER = ();
	advanceTime(900);
	is( epg_requests(), 3, '15 min later: fetched again' );
	is( scalar( pushes() ), 0, 'unchanged: no push' );
	is( scalar( timers_for($player) ), 1, 'still polling' );

	reset_all();
	$player = player( '00:00:00:00:00:01', $RN_URL );
	setTime( $RN_END + 30 );
	$PH->onStream( $player, $player->playingSong );
	is( next_poll_in($player), 60, 'ABC still returns the finished program: next poll in 60 s' );
	advanceTime(60);
	advanceTime(60);
	is( epg_requests(), 3, '... one request a minute, no tight loop' );
	is( scalar( pushes() ), 1, '... pushed once' );
};

subtest 'ABC\'s EPG lags the schedule: no flicker to the station name while refreshing' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );    # 6:55pm: The Radio National Hour, until 7:00pm
	$EPG{'RN/now'} = { content => fixture('live/bff-epgNowPlaying-RN-now.json'), defer => 1 };    # slow, still the ended program

	my @titles;
	my $status = sub {    # two status calls, the (slow) refresh lands, another status call
		push @titles, map { $PH->getMetadataFor( $player, $RN_URL )->{title} } 1 .. 2;
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
		push @titles, $PH->getMetadataFor( $player, $RN_URL )->{title};
	};

	advanceTime(305);    # 7:00:05: the program ended and the cache expired; the poll comes at 7:00:30
	is( epg_requests(), 1, '(no refresh before the first status call)' );
	$status->();
	is( epg_requests(), 2, 'the status call starts the refresh' );
	advanceTime(25);     # 7:00:30: the poll, answered from the cache
	advanceTime(36);     # 7:01:06: expired again (60 s for an ended program): a status call refreshes
	$status->();
	advanceTime(84);     # 7:02:30: this time the poll (60 s after 7:01:30) starts the refresh
	$status->();
	is( epg_requests(), 4, '(3 refreshes: two from status calls, one from the poll)' );
	is_deeply( [ grep { $_ ne 'The Radio National Hour' } @titles ], [], 'every status call shows the last program ABC reported (' . scalar(@titles) . ' calls), never the station name' );
	is( scalar( pushes() ), 1, 'no push (unchanged)' );

	$EPG{'RN/now'} = $LNL;
	advanceTime(60);
	is( $PH->getMetadataFor( $player, $RN_URL )->{title}, 'Late Night Live', 'ABC catches up: the new program' );
	is( scalar( pushes() ), 2, '... pushed once' );
};

subtest 'a failed fetch or push: next poll in 30 s; logged at ERROR once' => sub {
	reset_all();
	$EPG{'RN/now'} = { code => 500 };
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );

	is( next_poll_in($player), 30, 'fetch failed: next poll in 30 s' );
	is( scalar( pushes() ), 0, 'no push' );
	advanceTime(30);
	is( epg_requests(), 1, 'at 30 s: the negative cache answers (no request)' );
	is( next_poll_in($player), 30, '... next poll in 30 s' );
	advanceTime(30);
	is( epg_requests(), 2, 'at 60 s: a new request' );

	$EPG{'RN/now'} = 'live/bff-epgNowPlaying-RN-now.json';
	{
		no warnings 'redefine';
		local *Slim::Control::Request::notifyFromArray = sub { die "notify broke\n" };
		advanceTime(30);    # served from the negative cache
		advanceTime(30);    # a new request, then the push dies
		is( next_poll_in($player), 30, 'the push dies: next poll in 30 s' );
		advanceTime(30);
	}
	is( scalar( grep { $_->{message} =~ /notify broke/ } logged('ERROR') ), 1, 'logged at ERROR once' );
	ok( scalar( grep { $_->{message} =~ /notify broke/ } logged('DEBUG') ), '... then at DEBUG' );
	advanceTime(30);
	is( scalar( pushes() ), 1, 'then pushed' );
	is( scalar( timers_for($player) ), 1, 'never a dead timer' );
};

subtest 'stop, onStop, URL change: no fetch and no timers left; pause keeps polling' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );

	$player->mode('pause');
	advanceTime(330);
	is( epg_requests(), 2, 'paused on the live URL: still polling' );

	$player->mode('stop');
	advanceTime(900);
	is( epg_requests(), 2, 'stopped: the poll makes no fetch' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... and leaves no timer' );
	ok( scalar( grep { $_->{message} =~ /stop polling for 00:00:00:00:00:01/ } logged('DEBUG') ), '"stop polling" logged' );

	reset_all();
	$player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );
	$PH->onStop( L2Song->new( 'abclisten://live/NEWS', $player ) );
	is( scalar( timers_for($player) ), 1, 'onStop of another service: the poll is kept' );
	$PH->onStop( $player->playingSong );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'onStop: timer killed at once' );
	advanceTime(900);
	is( epg_requests(), 1, '... no more fetches' );

	reset_all();
	$player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );
	play( $player, 'abclisten://episode/1234' );
	advanceTime(330);
	is( epg_requests(), 1, 'another URL plays: no fetch' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... no timer' );

	reset_all();
	$EPG{'RN/now'} = { content => fixture('live/bff-epgNowPlaying-RN-now.json'), defer => 1 };
	$player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );
	$player->mode('stop');
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( pushes() ), 0, 'stopped while the fetch was in flight: no push' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, '... no timer' );
};

subtest 'station switch: the poll moves to the new service' => sub {
	reset_all();
	$EPG{'TRIPLEJ_PERTH/now'} = 'live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json';
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->onStream( $player, $player->playingSong );

	my $song = play( $player, $PERTH_URL );
	$PH->onStream( $player, $song );
	is( epg_requests(qr{TRIPLEJ_PERTH/now}), 1, 'the new service is fetched' );
	is( scalar( timers_for($player) ), 1, 'one timer' );
	is( ( grep { $_->[0] eq 'setCurrentTitle' } @ORDER )[-1]->[1], $PERTH_URL, 'pushed for the new URL' );

	advanceTime(3600);
	is( epg_requests(qr{/RN/}), 1, 'the old service is not polled any more' );
	ok( epg_requests(qr{TRIPLEJ_PERTH/now}) > 1, 'the new one is' );
};

subtest 'sync group: only the master polls and pushes' => sub {
	reset_all();
	my $master = player( '00:00:00:00:00:01', $RN_URL );
	my $slave  = player( '00:00:00:00:00:02', undef, $master );

	$PH->onStream( $slave,  $master->playingSong );
	$PH->onStream( $master, $master->playingSong );
	$PH->getMetadataFor( $slave, $RN_URL );

	is( epg_requests(), 1, 'one fetch for the group' );
	is( scalar( Slim::Utils::Timers::pending() ), 1, 'one timer' );
	is( scalar( timers_for($master) ), 1, '... keyed on the master' );
	is_deeply( [ map { $_->[1]->id } pushes() ], ['00:00:00:00:00:01'], 'pushed to the master only, once' );
};

subtest 'stale-poll recovery and LMS restarts' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );

	$PH->getMetadataFor( $player, $RN_URL );
	is( scalar( timers_for($player) ), 1, 'no poll yet (LMS restarted while playing): the first metadata call starts it' );
	is( scalar( pushes() ), 1, '... and pushes' );

	Slim::Utils::Timers::forgetTimer($player);    # Slim::Player::Client::forgetClient
	$PH->getMetadataFor( $player, $RN_URL );
	is( scalar( timers_for($player) ), 1, 'timers forgotten: the next metadata call restarts the poll' );

	my $again = ABCListenTest::FakeClient->new('00:00:00:00:00:01');    # reconnected: new object, same id
	play( $again, $RN_URL );
	$PH->getMetadataFor( $again, $RN_URL );
	is( scalar( timers_for($again) ),  1, 'a reconnected player: the poll is replaced' );
	is( scalar( timers_for($player) ), 0, '... the old object has no timer' );

	reset_all();
	my $idle = player( '00:00:00:00:00:03', $RN_URL );
	$idle->mode('stop');
	$PH->getMetadataFor( $idle, $RN_URL );
	my $other = player( '00:00:00:00:00:04', 'abclisten://live/NEWS' );
	$PH->getMetadataFor( $other, $RN_URL );    # RN merely queued
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'a stopped player, or one playing another URL: no poll' );

	$PH->onStream( $other, $other->playingSong );
	$PH->getMetadataFor( $other, $RN_URL );
	is( epg_requests(qr{/RN/now}), 1, 'a queued station is fetched for its metadata only' );
	is( scalar( timers_for($other) ), 1, '... the poll keeps the station that plays' );
	advanceTime(900);
	is( epg_requests(qr{/RN/now}), 1, 'services nobody plays are never polled' );
};

subtest 'many players on one station: one upstream request per refresh' => sub {
	reset_all();
	my @players = map { player( "00:00:00:00:00:1$_", $RN_URL ) } 1 .. 3;
	$PH->onStream( $_, $_->playingSong ) for @players;
	is( epg_requests(), 1, '3 players: one request' );
	is( scalar( pushes() ), 3, 'each player gets its push' );

	$EPG{'RN/now'} = $LNL;
	advanceTime(330);
	is( epg_requests(), 2, 'the next refresh: one request for all' );
	is( scalar( pushes() ), 6, '... and a push each' );
};

subtest 'exceptions are contained' => sub {
	reset_all();
	my $player = player( '00:00:00:00:00:01', $RN_URL );
	$PH->getMetadataFor( undef, $RN_URL );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::NowPlaying::cached = sub { die "cache broke\n" };
		my $meta = eval { Plugins::ABCListen::LiveMetadata::metadata( undef, $RN_URL, 'RN' ) };
		is( $meta->{title}, 'Radio National', 'metadata dies inside: the station fallback, no exception' );
		Plugins::ABCListen::LiveMetadata::metadata( undef, $RN_URL, 'RN' );
	}
	is( scalar( grep { $_->{message} =~ /cache broke/ } logged('ERROR') ), 1, 'ERROR once' );
	ok( scalar( grep { $_->{message} =~ /cache broke/ } logged('DEBUG') ), '... then DEBUG' );

	ok( eval { Plugins::ABCListen::LiveMetadata::onStream( undef, undef, 'RN' ); 1 }, 'onStream without a player: no die' );
	ok( eval { Plugins::ABCListen::LiveMetadata::onStop( undef, 'RN' ); 1 },          'onStop without a song: no die' );
	is_deeply( Plugins::ABCListen::LiveMetadata::metadata( undef, 'abclisten://live/NOPE', 'NOPE' ), {}, 'an unknown station: {}' );
};

# ---- song info ----

sub program_info {
	my ( $client, $url ) = @_;
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{abclistenProgramInfo} or return;
	return $provider->{func}->( $client, $url, undef, {}, {} );
}

sub open_info {
	my ( $client, $item ) = @_;
	my $c = collector();
	$item->{url}->( $client, $c->cb, {}, @{ $item->{passthrough} || [] } );
	return $c;
}

subtest 'song info: a "Program info" link for live stations only' => sub {
	reset_all();
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{abclistenProgramInfo};
	ok( $provider, 'registered by Live->init' );
	is( $provider->{after}, 'top', '... after "top"' );

	my $item = program_info( undef, $RN_URL );
	is( $item->{name}, 'Program info', 'named "Program info"' );
	is( $item->{name}, string('PLUGIN_ABCLISTEN_PROGRAM_INFO'), '(PLUGIN_ABCLISTEN_PROGRAM_INFO)' );
	is( $item->{type}, 'link', 'a link' );
	ok( !exists $item->{description}, 'no description on the link' );
	is( epg_requests(), 0, 'the entry itself makes no request' );

	for my $url ( 'abclisten://episode/123', 'https://abc.streamguys1.com/live/rnnsw/icecast.audio', 'abclisten://live/NOPE', undef ) {
		is( program_info( undef, $url ), undef, 'no entry for ' . ( $url // 'undef' ) );
	}
};

subtest 'song info: synopsis, On air, presenters, Next' => sub {
	reset_all();
	$PH->getMetadataFor( undef, $RN_URL );    # RN now cached
	my $synopsis = $S->get('RN')->{synopsis};
	ok( $synopsis, '(RN has a synopsis)' );

	my $c = open_info( undef, program_info( undef, $RN_URL ) );
	is( $c->count, 1, 'answers once' );
	is_deeply(
		( $c->args(0) )[0]->{items},
		[
			{ type => 'textarea', wrap => 1, name => $synopsis },
			{ type => 'text', name => "On air: The Radio National Hour \x{B7} 6:00pm\x{2013}7:00pm" },
			{ type => 'text', name => 'Presented by Fran Kelly' },
			{ type => 'text', name => "Next: ABC News Daily and Radio National Hour Highlights \x{B7} 5:30am\x{2013}6:00am" },
		],
		'synopsis (first), "On air: <program> · <slot>", presenters, "Next: <program> · <slot>"'
	);
	is( epg_requests(qr{/next\?}), 1, '/next fetched for song info' );

	reset_all();
	$EPG{'RN/next'} = '{}';
	$c = open_info( undef, program_info( undef, $RN_URL ) );
	my @names = map { $_->{name} } @{ ( $c->args(0) )[0]->{items} };
	is( scalar( grep { /^Next:/ } @names ), 0, 'no next program: no "Next" row' );
	ok( scalar( grep { /^On air: The Radio National Hour/ } @names ), '... "On air" still there' );

	reset_all();
	$EPG{'RN/now'}  = { code => 500 };
	$EPG{'RN/next'} = { code => 500 };
	$c = open_info( undef, program_info( undef, $RN_URL ) );
	is_deeply( [ map { $_->{type} } @{ ( $c->args(0) )[0]->{items} } ], ['textarea'], 'no program data: the synopsis only' );

	$S->_setRecords( { %{ $S->get('RN') }, synopsis => undef } );
	$c = open_info( undef, program_info( undef, $RN_URL ) );
	is_deeply( ( $c->args(0) )[0]->{items}, [ { type => 'text', name => 'Radio National' } ], 'nothing at all: the station name' );
	$S->_setRecords();
};

subtest 'song info: answers within 3 s even when ABC is slow, exactly once' => sub {
	reset_all();
	$PH->getMetadataFor( undef, $RN_URL );
	$EPG{'RN/next'} = { content => fixture('live/bff-epgNowPlaying-RN-next.json'), defer => 1 };

	my $c = open_info( undef, program_info( undef, $RN_URL ) );
	advanceTime(2.9);
	is( $c->count, 0, 'waits for /next' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at 3 s' );
	my @names = map { $_->{name} } @{ ( $c->args(0) )[0]->{items} };
	ok( scalar( grep { /^On air:/ } @names ), '... with what is known' );
	is( scalar( grep { /^Next:/ } @names ), 0, '... without Next' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late answer does not call back again' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timer left' );
};

subtest '$song->duration and startOffset are never called' => sub {
	is( scalar( map { $_->calls('duration'), $_->calls('startOffset') } @SONGS ), 0, 'across all the songs above' );
	ok( scalar(@SONGS) > 10, '(' . scalar(@SONGS) . ' songs)' );
	ok( scalar(@TITLE_CALLS_ALL), '(' . scalar(@TITLE_CALLS_ALL) . ' setCurrentTitle calls)' );
	is( scalar( grep { defined $_->[2] } @TITLE_CALLS_ALL ), 0, 'setCurrentTitle never with a client' );
};

done_testing();

# A Slim::Player::Song for the live metadata: its current track's URL, its master, its stream URL.
package L2Song;

use parent -norequire, 'ABCListenTest::FakeSong';

sub new {
	my ( $class, $url, $owner ) = @_;
	my $self = ABCListenTest::FakeSong::new($class);
	@$self{qw(url owner)} = ( $url, $owner );
	return $self;
}

sub currentTrack { L2Track->new( $_[0]->{url} ) }
sub master       { $_[0]->{owner}->master }
sub streamUrl    { 'https://abc.streamguys1.com/live/rnnsw/icecast.audio' }

package L2Track;

sub new { bless { url => $_[1] }, $_[0] }
sub url { $_[0]->{url} }

1;
