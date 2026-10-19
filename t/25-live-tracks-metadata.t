#!/usr/bin/perl
# Plugins::ABCListen::LiveMetadata track mode (L3; offline, fake clock, FakeClient incl. a sync group),
# through the live kind as Live->init registers it: song mode { title => song, artist, album =>
# "<program> · <station>", cover => song cover } while a song is current, program mode (L2) once it
# is over, between songs, on talk stations and for time-zone versions without data; buildMeta's
# fallbacks (no program: release title, else station name; cover: song, program image, logo); the
# poll at min(track delay (next_updated - now, 20-120 s), program delay); last-good on one empty or
# failed answer, program mode on the second; pushes only on change; RN never calls a music endpoint;
# a station switch stops song polling; two players -> one now.json per refresh; master-only polling
# in a sync group; metadata without a player never fetches songs; the "Recently played" song-info
# entry (10 rows "time · Artist – Title" in server local time, empty, error, the 3 s deadline,
# exactly one answer; absent for RN and time-zone versions); $song->duration never called.

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
use Plugins::ABCListen::Tracks;
use Plugins::ABCListen::Util qw(parseISO8601);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $PH = 'Plugins::ABCListen::ProtocolHandler';
my $LM = 'Plugins::ABCListen::LiveMetadata';
my $NP = 'Plugins::ABCListen::NowPlaying';
my $S  = 'Plugins::ABCListen::Stations';
my $T  = 'Plugins::ABCListen::Tracks';

my $TJ_URL    = 'abclisten://live/TRIPLEJ';
my $RN_URL    = 'abclisten://live/RN';
my $PERTH_URL = 'abclisten://live/TRIPLEJ_PERTH';

my $TJ_PLAYED = parseISO8601('2026-10-19T07:11:23+00:00');    # "Could This Be Love", 212 s
my $TJ_NEXT   = parseISO8601('2026-10-19T07:14:45+00:00');
my $TJ_END    = $TJ_PLAYED + 212;
my $TJ_COVER  = 'https://resize.abcradio.net.au/n4TEe5BxO3t8HKtfGyqZUrvMkis=/160x160/center/middle/https%3A%2F%2Fwww.abc.net.au%2Ftriplej%2Falbums%2Fxivy-couldthisbelove.jpg';
my $ARVOS_IMG = 'https://resize.abcradio.net.au/sig=/580x580/center/middle/arvos.jpg';
my $PROG_END  = parseISO8601('2026-10-19T08:00:00+00:00');

my $TJ_LOGO = Plugins::ABCListen::API::imageUrl( $S->get('TRIPLEJ')->{logo}, 600 );

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub json { JSON::PP->new->utf8->canonical->encode(shift) }
sub iso  { POSIX::strftime( '%Y-%m-%dT%H:%M:%S+00:00', gmtime(shift) ) }

sub epg {
	my %p = @_;
	return json( {
		title => $p{title},
		start => iso( $p{start} ),
		end   => iso( $p{end} ),
		preparedPresenters => [ map { { names => { full => $_ } } } @{ $p{presenters} || [] } ],
		$p{image} ? ( preparedImage => { imgSrc => $p{image} } ) : (),
	} );
}

my $ARVOS = epg( title => 'Arvos', start => $PROG_END - 7200, end => $PROG_END, presenters => ['Concetta Caristo'], image => $ARVOS_IMG );

# A synthetic now.json: a song played at $played for $duration s, next_updated $next.
sub song_body {
	my ( $title, $artist, $played, $duration, $next ) = @_;
	return json( {
		now => {
			summary     => { artist => $artist },
			played_time => iso($played),
			recording   => { title => $title, duration => $duration, artists => [], artwork => [] },
			release     => { title => "$title EP", release_year => '2026', artwork => [ { url => "https://www.abc.net.au/triplej/albums/\L$title\E.jpg" } ] },
		},
		next_updated => iso($next),
	} );
}

sub empty_body { json( { now => {}, next_updated => iso( $_[0] ) } ) }

# Answers by service: %EPG for epgNowPlaying/<id>/<variant>, %MUSIC for plays/<station>/now.json,
# musicNowPlaying/<ID> and plays/search.json (key 'search:<station>'): a body, a fixture name or
# { code => ..., defer => ... }.
my ( %EPG, %MUSIC );

sub answer {
	my $answer = shift;
	return { code => 404 } unless defined $answer;
	return $answer if ref $answer eq 'HASH';
	return { content => $answer =~ /\A[\[{n]/ ? $answer : fixture($answer) };
}

sub routes {
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{/epgNowPlaying/}, sub {
		my ($url) = @_;
		my ( $id, $variant ) = $url =~ m{/epgNowPlaying/([A-Z0-9_]+)/(now|next)\?} or return;
		return answer( $EPG{"$id/$variant"} );
	} );
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{music\.abcradio\.net\.au|/musicNowPlaying/}, sub {
		my ($url) = @_;
		my ($key) = $url =~ m{/plays/(\w+)/now\.json} ? ($1)
			: $url =~ m{/musicNowPlaying/(\w+)\?} ? ($1)
			: $url =~ m{/plays/search\.json\?.*station=(\w+)} ? ("search:$1")
			: ();
		return defined $key ? answer( $MUSIC{$key} ) : undef;
	} );
	return;
}

my @ORDER;    # setCurrentTitle / currentPlaylistUpdateTime / notifyFromArray calls, in order
my @TITLE_CALLS_ALL;

{
	no warnings 'redefine';

	my $setTitle = \&Slim::Music::Info::setCurrentTitle;
	*Slim::Music::Info::setCurrentTitle = sub { push @ORDER, [ setCurrentTitle => @_ ]; push @TITLE_CALLS_ALL, [@_]; goto &$setTitle };

	my $notify = \&Slim::Control::Request::notifyFromArray;
	*Slim::Control::Request::notifyFromArray = sub { push @ORDER, [ notify => $_[0], @{ $_[1] } ]; goto &$notify };

	my $update = \&ABCListenTest::FakeClient::currentPlaylistUpdateTime;
	*ABCListenTest::FakeClient::currentPlaylistUpdateTime = sub { push @ORDER, [ updateTime => $_[0] ] if @_ > 1; goto &$update };
}

my @SONGS;

sub reset_all {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$S->_reset();
	$NP->_reset();
	$T->_reset();
	$LM->_reset();
	ABCListenTest::FakeClient->resetEvents;
	@ORDER = ();
	%EPG   = ( 'TRIPLEJ/now' => $ARVOS, 'RN/now' => 'live/bff-epgNowPlaying-RN-now.json', 'TRIPLEJ_PERTH/now' => 'live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json' );
	%MUSIC = ( triplej => 'live/music-abcradio-plays-triplej-now.json' );
	routes();
	setTime( $TJ_PLAYED + 60 );    # a minute into "Could This Be Love" (Arvos until 7:00pm AEDT)
	Plugins::ABCListen::Live->init();
	return;
}

sub player {
	my ( $mac, $url, $master ) = @_;
	my $player = $master ? $master->makeSlave($mac) : ABCListenTest::FakeClient->new($mac);
	play( $player->master, $url ) unless $master;
	$Slim::Player::Playlist::PLAYLISTS{$mac} = $Slim::Player::Playlist::PLAYLISTS{ $master->id } if $master;
	return $player;
}

sub play {
	my ( $player, $url ) = @_;
	my $song = L3Song->new( $url, $player );
	push @SONGS, $song;
	$player->setSong($song);
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$url];
	return $song;
}

sub music_requests {
	my $re = shift || qr{music\.abcradio\.net\.au|/musicNowPlaying/};
	return scalar grep { $_->{url} =~ $re } requests();
}

sub timers_for { my $p = shift; return grep { ref $_->{obj} && $_->{obj} == $p } Slim::Utils::Timers::pending() }

sub pushes { grep { $_->[0] eq 'notify' && $_->[2] eq 'newmetadata' } @ORDER }

sub pushed_titles { map { $_->[2] } grep { $_->[0] eq 'setCurrentTitle' } @ORDER }

sub next_poll_in {
	my $player = shift;
	my ($timer) = timers_for($player);
	return $timer ? $timer->when - Time::HiRes::time() : undef;
}

sub np { my ( $player, $url ) = @_; return $PH->getMetadataFor( $player, $url || $TJ_URL ) }

sub start {
	my $url    = shift || $TJ_URL;
	my $player = player( '00:00:00:00:00:01', $url );
	$PH->onStream( $player, $player->playingSong );
	return $player;
}

# ---- buildMeta (pure) ----

subtest 'buildMeta: song mode and its fallbacks' => sub {
	my $station = { title => 'triple j', artist => 'ABC listen', cover => 'logo', bitrate => '56kbps CBR' };
	my $program = { title => 'Arvos', presenters => 'Concetta Caristo', image => 'prog' };
	my $song    = { title => 'Could This Be Love', artist => 'X & Ivy', album => 'Could This Be Love (2026)', cover => 'song' };

	is_deeply(
		$LM->buildMeta( $station, $program, $song ),
		{ title => 'Could This Be Love', artist => 'X & Ivy', album => "Arvos \x{B7} triple j", cover => 'song', bitrate => '56kbps CBR' },
		'song mode: title, artist, album "<program> · <station>", song cover; bitrate kept'
	);
	is( $LM->buildMeta( $station, undef, $song )->{album}, 'Could This Be Love (2026)', 'program unknown: album = the release' );
	is( $LM->buildMeta( $station, undef, { %$song, album => undef } )->{album}, 'triple j', '... else the station name' );
	is( $LM->buildMeta( $station, $program, { %$song, cover => undef } )->{cover}, 'prog', 'no song cover: the program image' );
	is( $LM->buildMeta( $station, { title => 'Arvos' }, { %$song, cover => undef } )->{cover}, 'logo', '... else the station logo' );
	is( $LM->buildMeta( $station, $program, { %$song, artist => undef } )->{artist}, 'triple j', 'no artist: the station name' );
	is_deeply( $LM->buildMeta( $station, $program, { artist => 'x' } ), $LM->buildMeta( $station, $program ), 'a song without a title: program mode' );
	is_deeply( $LM->buildMeta( $station, $program, undef ), { title => 'Arvos', artist => 'Concetta Caristo', album => 'triple j', cover => 'prog', bitrate => '56kbps CBR' }, 'no song: L2 program mode' );
	is_deeply( $station, { title => 'triple j', artist => 'ABC listen', cover => 'logo', bitrate => '56kbps CBR' }, 'the station metadata is not changed' );
};

# ---- song mode through the live kind ----

subtest 'triple j plays: the song is pushed (title, artist, album, cover), next poll at min(track, program)' => sub {
	reset_all();
	my $player = start();

	is( music_requests(), 1, 'onStream fetches the song' );
	is_deeply( [ map { $_->{url} } grep { $_->{url} =~ /music/ } requests() ], ['https://music.abcradio.net.au/api/v1/plays/triplej/now.json'], '... plays/triplej/now.json' );
	is( scalar( pushes() ), 1, 'one push' );
	is_deeply( [ pushed_titles() ], ['Could This Be Love'], 'setCurrentTitle($url, song)' );

	my $meta = np($player);
	is( $meta->{title},  'Could This Be Love',      'Now Playing title = now.recording.title' );
	is( $meta->{artist}, 'X & Ivy',                 'artist = now.summary.artist' );
	is( $meta->{album},  "Arvos \x{B7} triple j",   'album = "<program> · triple j"' );
	is( $meta->{cover},  $TJ_COVER,                 'cover = the song cover (not the logo)' );
	isnt( $meta->{cover}, $TJ_LOGO, '(the logo is something else)' );
	is( $meta->{bitrate}, '56kbps CBR', 'bitrate kept' );
	is( $PH->getCurrentTitle( $player, $TJ_URL ), 'Could This Be Love', 'getCurrentTitle: the song' );

	is( next_poll_in($player), 120, 'next poll: next_updated is 142 s away -> clamped to 120 s (program ends in 48 min)' );
	is( scalar( timers_for($player) ), 1, 'one timer for the master' );
};

subtest 'song change, song over (ABC not updated yet), between songs: song <-> program mode' => sub {
	reset_all();
	my $player = start();
	@ORDER = ();

	# ABC still answers the same song: no push; next poll at next_updated
	advanceTime(120);    # 07:14:23
	is( music_requests(), 2, 'the poll refreshes the song' );
	is( scalar( pushes() ), 0, 'unchanged: no push' );
	is( next_poll_in($player), 22, 'next poll at next_updated (22 s)' );

	# the song is over (07:14:55) but ABC hasn't updated: program mode
	advanceTime(22);    # 07:14:45: still current
	is( scalar( pushes() ), 0, 'at next_updated, the song still current: no push' );
	is( next_poll_in($player), 20, 'next_updated passed: 20 s' );
	advanceTime(20);    # 07:15:05
	is( scalar( pushes() ), 1, 'played_time + duration passed: one push' );
	is_deeply( [ @{ np($player) }{qw(title artist album cover)} ], [ 'Arvos', 'Concetta Caristo', 'triple j', $ARVOS_IMG ], '... program mode (L2 fields)' );

	# a new song
	$MUSIC{triplej} = song_body( 'Halfway', 'Swapmeet', $TJ_PLAYED + 230, 212, $TJ_PLAYED + 400 );
	advanceTime(20);    # 07:15:25
	is( scalar( pushes() ), 2, 'the next song: one push' );
	is_deeply( [ @{ np($player) }{qw(title artist album)} ], [ 'Halfway', 'Swapmeet', "Arvos \x{B7} triple j" ], '... song mode again' );
	is( np($player)->{cover}, 'https://www.abc.net.au/triplej/albums/halfway.jpg', '... with its cover' );
	is( next_poll_in($player), 120, '... next poll clamped to 120 s' );

	# between songs: {} twice
	$MUSIC{triplej} = empty_body( $TJ_PLAYED + 500 );
	advanceTime(120);
	is( scalar( pushes() ), 2, 'one empty answer while the song is current: last-good, no push' );
	is( np($player)->{title}, 'Halfway', '... still the song' );
	advanceTime( next_poll_in($player) );
	is( scalar( pushes() ), 3, 'the second empty answer: one push' );
	is( np($player)->{title}, 'Arvos', '... program mode' );
	ok( scalar( grep { $_->{message} =~ /next poll for 00:00:00:00:00:01 in \d+ s/ } logged('DEBUG') ), 'DEBUG "next poll ..."' );
};

subtest 'poll delay: min(track delay 20-120 s, program delay)' => sub {
	reset_all();
	$EPG{'TRIPLEJ/now'} = epg( title => 'Arvos', start => $TJ_PLAYED - 3600, end => $TJ_PLAYED + 60 + 15, presenters => ['C'] );
	my $player = start();
	is( next_poll_in($player), 60, 'program ends in 15 s (program delay 60 s), track 120 s: 60 s' );

	reset_all();
	$MUSIC{triplej} = song_body( 'Fast', 'A', $TJ_PLAYED, 200, $TJ_PLAYED + 65 );
	$player = start();
	is( next_poll_in($player), 20, 'next_updated in 5 s: 20 s' );

	reset_all();
	$MUSIC{triplej} = song_body( 'Mid', 'A', $TJ_PLAYED, 200, $TJ_PLAYED + 105 );
	$player = start();
	is( next_poll_in($player), 45, 'next_updated in 45 s: 45 s' );

	reset_all();
	$MUSIC{triplej} = { code => 503 };
	$player = start();
	is( next_poll_in($player), 30, 'song fetch failed: 30 s' );
	is( np($player)->{title}, 'Arvos', '... program mode' );
	is( scalar( pushes() ), 1, '... pushed (the program)' );

	reset_all();
	$EPG{'TRIPLEJ/now'} = { code => 500 };
	$player = start();
	is( next_poll_in($player), 30, 'program fetch failed (song fine): 30 s' );
	is( np($player)->{title}, 'Could This Be Love', '... the song is still pushed' );
	is( np($player)->{album}, 'Could This Be Love (2026)', '... album = the release (program unknown)' );
};

subtest 'last-good: one failed answer keeps the song, the second means program mode' => sub {
	reset_all();
	my $player = start();
	$MUSIC{triplej} = { code => 502 };
	advanceTime(120);
	is( scalar( pushes() ), 1, 'one failure: no push' );
	is( np($player)->{title}, 'Could This Be Love', '... the song while it is current' );
	is( next_poll_in($player), 30, '... retried in 30 s' );
	advanceTime(30);    # 07:15:23: the song is over anyway
	is( scalar( pushes() ), 2, 'the second failure: program mode pushed' );
	is( np($player)->{title}, 'Arvos', '... Arvos' );
	is( scalar( grep { $_->{message} =~ /Song for TRIPLEJ unavailable/ } logged('WARN') ), 1, 'WARN once for the run of failures' );
};

subtest 'RN: program mode only, no music request ever; switching to RN stops song polling' => sub {
	reset_all();
	my $player = start($RN_URL);
	advanceTime(3600);
	is( music_requests(), 0, 'RN played for an hour: no music endpoint called' );
	is( np( $player, $RN_URL )->{album}, 'Radio National', 'program mode (album = station name)' );
	is( Plugins::ABCListen::LiveMetadata::recentInfo( $player, $RN_URL ), undef, 'no "Recently played" for RN' );

	reset_all();
	$player = start();
	is( music_requests(), 1, 'triple j: the song is fetched' );
	my $song = play( $player, $RN_URL );
	$PH->onStream( $player, $song );
	advanceTime(3600);
	is( music_requests(), 1, 'switched to RN: no more song fetches' );
	is( scalar( timers_for($player) ), 1, '... one poll (RN)' );
};

subtest 'time-zone version without song data: program mode, program delay only' => sub {
	reset_all();
	$MUSIC{TRIPLEJ_PERTH} = { code => 500, content => fixture('live/bff-musicNowPlaying-TRIPLEJ_PERTH-500.json') };
	setTime( parseISO8601('2026-10-19T05:00:00Z') );
	my $player = start($PERTH_URL);
	is( music_requests(qr{/musicNowPlaying/TRIPLEJ_PERTH\?tz=Australia%2FPerth}), 1, 'musicNowPlaying/TRIPLEJ_PERTH?tz=Australia/Perth asked once' );
	is( music_requests(qr{plays/triplej/}), 0, 'never the parent\'s feed' );
	my $meta = np( $player, $PERTH_URL );
	is_deeply( [ @{$meta}{qw(title artist album)} ], [ 'Drive', 'Jordan & Luka', 'triple j Perth' ], 'program mode' );
	ok( next_poll_in($player) >= 60, 'next poll: the program delay (' . next_poll_in($player) . ' s)' );
	advanceTime(3 * 3600);
	is( music_requests(), 1, 'no song data: not asked again for 6 h while it plays' );
	is( Plugins::ABCListen::LiveMetadata::recentInfo( $player, $PERTH_URL ), undef, 'no "Recently played" for a time-zone version' );

	reset_all();
	$MUSIC{TRIPLEJ_PERTH} = json( { mapiNow => undef, nextUpdated => undef } );
	setTime( parseISO8601('2026-10-19T05:00:00Z') );
	$player = start($PERTH_URL);
	is( np( $player, $PERTH_URL )->{title}, 'Drive', 'mapiNow null: program mode' );
};

subtest 'two players, a sync group: one now.json per refresh, the master polls and pushes' => sub {
	reset_all();
	my @players = map { player( "00:00:00:00:00:1$_", $TJ_URL ) } 1 .. 2;
	$PH->onStream( $_, $_->playingSong ) for @players;
	is( music_requests(), 1, '2 players: one now.json' );
	is( scalar( pushes() ), 2, 'a push each' );
	advanceTime(120);
	is( music_requests(), 2, 'the next refresh: one request for both' );

	reset_all();
	my $master = player( '00:00:00:00:00:01', $TJ_URL );
	my $slave  = player( '00:00:00:00:00:02', undef, $master );
	$PH->onStream( $slave,  $master->playingSong );
	$PH->onStream( $master, $master->playingSong );
	np($slave);
	is( music_requests(), 1, 'sync group: one fetch' );
	is( scalar( Slim::Utils::Timers::pending() ), 1, 'one timer' );
	is( scalar( timers_for($master) ), 1, '... keyed on the master' );
	is_deeply( [ map { $_->[1]->id } pushes() ], ['00:00:00:00:00:01'], 'pushed to the master only' );
};

subtest 'metadata without a playing player never fetches a song; stale-poll recovery does' => sub {
	reset_all();
	my $meta = np(undef);
	is( music_requests(), 0, 'getMetadataFor without a player: no song request' );
	is( $meta->{title}, 'Arvos', '... program mode (the program is fetched, as in L2)' );

	my $idle = player( '00:00:00:00:00:03', $TJ_URL );
	$idle->mode('stop');
	np($idle);
	is( music_requests(), 0, 'a stopped player: no song request' );

	my $player = player( '00:00:00:00:00:01', $TJ_URL );
	np($player);
	is( music_requests(), 1, 'a playing player without a poll (LMS restart): the poll starts and fetches' );
	is( np($player)->{title}, 'Could This Be Love', '... and the song shows' );
};

# ---- song info: Recently played ----

sub recent_item {
	my ( $client, $url ) = @_;
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{abclistenRecentlyPlayed} or return;
	return $provider->{func}->( $client, $url, undef, {}, {} );
}

sub open_item {
	my ( $client, $item ) = @_;
	my $c = collector();
	$item->{url}->( $client, $c->cb, {}, @{ $item->{passthrough} || [] } );
	return $c;
}

sub rows { map { $_->{name} } @{ ( $_[0]->args(0) )[0]->{items} } }

subtest 'song info: "Recently played" for main music stations only' => sub {
	reset_all();
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{abclistenRecentlyPlayed};
	ok( $provider, 'registered by Live->init' );
	is( $provider->{after}, 'abclistenProgramInfo', '... after "Program info"' );
	ok( $Slim::Menu::TrackInfo::PROVIDERS{abclistenProgramInfo}, '("Program info" still registered)' );

	my $item = recent_item( undef, $TJ_URL );
	is( $item->{name}, 'Recently played', 'named "Recently played"' );
	is( $item->{name}, string('PLUGIN_ABCLISTEN_RECENTLY_PLAYED'), '(PLUGIN_ABCLISTEN_RECENTLY_PLAYED)' );
	is( $item->{type}, 'link', 'a link' );
	ok( !exists $item->{description}, 'no description on the link' );
	is( music_requests(), 0, 'the entry itself makes no request' );

	ok( recent_item( undef, "abclisten://live/$_" ), "$_: listed" ) for qw(DOUBLEJ CLASSIC KIDSLISTEN);
	for my $url ( $RN_URL, $PERTH_URL, 'abclisten://live/CLASSIC_PERTH', 'abclisten://live/LOCAL_SYDNEY', 'abclisten://live/NEWS', 'abclisten://episode/123', undef ) {
		is( recent_item( undef, $url ), undef, 'no entry for ' . ( $url // 'undef' ) );
	}
};

subtest 'song info: 10 rows "time · Artist – Title"; empty, error and slow: one readable row' => sub {
	reset_all();
	$MUSIC{'search:triplej'} = 'live/music-abcradio-plays-search-triplej.json';
	my $c = open_item( undef, recent_item( undef, $TJ_URL ) );
	is( $c->count, 1, 'answers once' );
	my @rows = rows($c);
	is( scalar @rows, 10, '10 rows' );
	is( $rows[0], "10:32am \x{B7} Genesis Owusu & KYE \x{2013} HUMAN AGAIN", 'newest first, server local time (AEDT)' );
	is( $rows[9], "9:53am \x{B7} The Good Kids \x{2013} No Parks (at the Beach)", 'the 10th' );
	my $data = JSON::PP->new->utf8->decode( fixture('live/music-abcradio-plays-search-triplej.json') );
	is_deeply(
		[ map { /\A\d{1,2}:\d\d[ap]m \x{B7} (.+)\z/ ? $1 : $_ } @rows ],
		[ map { "$_->{summary}->{artist} \x{2013} $_->{recording}->{title}" } @{ $data->{items} }[ 0 .. 9 ] ],
		'"Artist – Title" = the first 10 items of plays/search.json'
	);
	is( scalar( grep { $_->{type} ne 'text' } @{ ( $c->args(0) )[0]->{items} } ), 0, 'text rows' );
	is( music_requests(qr{plays/search\.json\?limit=10&order=desc&station=triplej}), 1, 'plays/search.json?station=triplej&order=desc&limit=10' );

	$c = open_item( undef, recent_item( undef, $TJ_URL ) );
	is( music_requests(qr{search}), 1, 'opened again: cached' );

	my $none = [ string('PLUGIN_ABCLISTEN_NO_RECENT_TRACKS') ];
	is( $none->[0], 'No recently played songs', '(PLUGIN_ABCLISTEN_NO_RECENT_TRACKS)' );

	reset_all();
	$MUSIC{'search:triplej'} = json( { total => 0, offset => 0, limit => 10, items => [] } );
	is_deeply( [ rows( open_item( undef, recent_item( undef, $TJ_URL ) ) ) ], $none, 'empty list: one "No recently played songs" row' );

	reset_all();
	$MUSIC{'search:triplej'} = { code => 500 };
	is_deeply( [ rows( open_item( undef, recent_item( undef, $TJ_URL ) ) ) ], $none, 'error: the same row' );

	reset_all();
	$MUSIC{'search:triplej'} = { content => fixture('live/music-abcradio-plays-search-triplej.json'), defer => 1 };
	$c = open_item( undef, recent_item( undef, $TJ_URL ) );
	advanceTime(2.9);
	is( $c->count, 0, 'waits for the music API' );
	advanceTime(0.1);
	is( $c->count, 1, 'answers at 3 s' );
	is_deeply( [ rows($c) ], $none, '... with the "none" row' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late answer does not call back again' );
	is( scalar( Slim::Utils::Timers::pending() ), 0, 'no timer left' );

	reset_all();
	$MUSIC{'search:triplej'} = json( { items => [ { played_time => 'nonsense', recording => { title => 'Only a title' } } ] } );
	is_deeply( [ rows( open_item( undef, recent_item( undef, $TJ_URL ) ) ) ], ['Only a title'], 'no time, no artist: the title alone' );
};

subtest 'never: $song->duration / startOffset, setCurrentTitle with a client' => sub {
	is( scalar( map { $_->calls('duration'), $_->calls('startOffset') } @SONGS ), 0, 'duration/startOffset never called' );
	ok( scalar(@SONGS) > 10, '(' . scalar(@SONGS) . ' songs)' );
	is( scalar( grep { defined $_->[2] } @TITLE_CALLS_ALL ), 0, 'setCurrentTitle never with a client (' . scalar(@TITLE_CALLS_ALL) . ' calls)' );
	is( scalar( logged('ERROR') ), 0, 'no ERROR logged' );
};

done_testing();

package L3Song;

use parent -norequire, 'ABCListenTest::FakeSong';

sub new {
	my ( $class, $url, $owner ) = @_;
	my $self = ABCListenTest::FakeSong::new($class);
	@$self{qw(url owner)} = ( $url, $owner );
	return $self;
}

sub currentTrack { L3Track->new( $_[0]->{url} ) }
sub master       { $_[0]->{owner}->master }
sub streamUrl    { 'https://abc.streamguys1.com/live/triplejnsw/icecast.audio' }

package L3Track;

sub new { bless { url => $_[1] }, $_[0] }
sub url { $_[0]->{url} }

1;
