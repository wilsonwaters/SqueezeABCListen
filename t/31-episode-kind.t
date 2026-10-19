#!/usr/bin/perl
# The `episode` kind (Plugins::ABCListen::Episode->init) through the protocol handler's registry:
# registration (resolve, metadata, onStream), the contract-4 resolve shape (url, alternates array,
# meta, failToken only for geo), playback through scanUrl (the MP3, the AAC alternate after a failed
# scan, the geo message when every candidate fails, error tokens without a scan), readable text
# for every failure token, metadata (full and partial cache entries, network, 600 px cover, the
# no-entry fallback, no HTTP, corrupt entries, never an empty title), and onStream (O6: an AAC
# track's empty duration and bitrate filled from the cache, fill-only: an MP3's never overwritten;
# idempotent per player; a redirected stream; nothing derivable or no entry: skipped without
# error). Offline: SimpleAsyncHTTP, remote scanner and clock are stubs; Slim::Music::Info's
# setBitrate/setDuration are faked here as LMS implements them for a track object. Fixtures:
# t/data/ondemand (see t/30-episode.t).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use File::Spec;
use FindBin;
use JSON::PP ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use ABCListenTest::FakeClient;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Util qw(ICON CACHE_NAMESPACE parseISO8601 setEpisodeMeta);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

my $PH = 'Plugins::ABCListen::ProtocolHandler';

my $SITE    = 'https://www.abc.net.au';
my $SEARCH  = "$SITE/listen/search";
my $BUILD   = 'build-3afcd04f';
my $MEDIA   = 'https://mediacore-live-production.akamaized.net';
my $JSON    = JSON::PP->new->utf8->canonical;

my $ID    = '107266790';
my $URL   = "abclisten://episode/$ID";
my $PATH  = '/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790';
my $MP3   = "$MEDIA/audio/02/pg/Z/ai.mp3";
my $TITLE = '72 per cent of UK trees threatened by changing climate, plus the simple spud’s complex genetics';
my $IMAGE = 'https://live-production.wcms.abc-cdn.net.au/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862';
my $COVER = 'https://live-production.wcms.abc-cdn.net.au/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=600&height=600';

my $T = parseISO8601('2026-10-20T00:00:00Z');

my @O1_TOKENS = map {"PLUGIN_ABCLISTEN_EPISODE_$_"} qw(EXPIRED RESTRICTED GEO NOT_FOUND);
my @API_TOKENS = qw(PLUGIN_ABCLISTEN_LOAD_FAILED PLUGIN_ABCLISTEN_RATE_LIMITED);

# ---- helpers ----

# Episode->init, capturing what it registers (and registering it for real).
my %REGISTERED;
{
	no warnings 'redefine';
	my $real = \&Plugins::ABCListen::ProtocolHandler::registerKind;
	local *Plugins::ABCListen::ProtocolHandler::registerKind = sub {
		my ( $class, $kind, $impl ) = @_;
		$REGISTERED{$kind} = $impl;
		return $real->(@_);
	};
	Plugins::ABCListen::Episode->init;
}

# Slim::Music::Info::setBitrate/setDuration (not in the t/lib stub), as LMS implements them for a
# track object: set the track's bitrate and vbr_scale, or its secs. Every call is recorded.
my @INFO_CALLS;
{
	no warnings qw(redefine once);
	*Slim::Music::Info::setBitrate = sub {
		my ( $track, $bitrate, $vbr ) = @_;
		push @INFO_CALLS, [ setBitrate => $bitrate ];
		$track->bitrate($bitrate);
		$track->vbr_scale($vbr);
		return $track;
	};
	*Slim::Music::Info::setDuration = sub {
		my ( $track, $secs ) = @_;
		push @INFO_CALLS, [ setDuration => $secs ];
		$track->secs($secs);
		return $track;
	};
}

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	setTime( shift || $T );
	route( $SEARCH, file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	return;
}

sub serve_doc {
	my $edit = shift;
	my $doc  = $JSON->decode( fixture('ondemand/nextdata-episode-scienceshow-mp3.trimmed.json') );
	$edit->( $doc->{pageProps}->{data}->{documentProps} ) if $edit;
	setEpisodeMeta( $ID, { path => $PATH } );
	route( "$SITE/_next/data/$BUILD$PATH.json", content => $JSON->encode($doc), headers => { 'Content-Type' => 'application/json' } );
	return;
}

# The kind's resolve, called as the handler calls it.
sub kind_resolve {
	my $id = shift;
	my $c  = collector();
	$REGISTERED{episode}->{resolve}->( undef, $id, $c->cb );
	is( $c->count, 1, "resolve $id: exactly one callback" );
	return ( $c->args(0) )[0] || {};
}

sub metadata { $REGISTERED{episode}->{metadata}->( undef, 'abclisten://episode/' . ( defined $_[0] ? $_[0] : '' ), $_[0] ) }

# The fake remote scanner: URLs in @fail fail with 403 (all with 'all'); others scan.
sub scanner {
	my @fail = @_;
	$Slim::Utils::Scanner::Remote::HANDLER = sub {
		my ( $url, $args ) = @_;
		return $args->{cb}->( undef, '403 Forbidden' ) if grep { $_ eq 'all' || $_ eq $url } @fail;
		return $args->{cb}->( FakeTrack->new( url => $url ), undef );
	};
	return;
}

sub scanned { map { $_->{url} } @Slim::Utils::Scanner::Remote::SCANS }

sub play {
	my $url  = shift;
	my $song = FakeSong->new($url);
	my $c    = collector();
	$PH->scanUrl( $url, { client => $song->master, song => $song, cb => $c->cb } );
	return ( $c, $song );
}

sub logged_like {
	my ( $level, $re ) = @_;
	return scalar grep { $_->{message} =~ $re } Slim::Utils::Log->messages( category => 'plugin.abclisten', level => $level );
}

# The handler's onStream for $song (as LMS calls it, for $client: default the song's master).
# Returns [ the track's secs, its bitrate, the setDuration/setBitrate calls made ]; fails the
# test if an onStream failure was logged.
sub on_stream {
	my ( $song, $name, $client ) = @_;
	@INFO_CALLS = ();
	$PH->onStream( $client || $song->master, $song );
	is( logged_like( WARN => qr/onStream failed/ ), 0, "$name: no onStream failure logged" );
	return [ $song->currentTrack->secs, $song->currentTrack->bitrate, sort { $a->[0] cmp $b->[0] } @INFO_CALLS ];
}

# ---- registration ----

subtest 'Episode->init registers the episode kind with resolve, metadata and onStream' => sub {
	ok( $REGISTERED{episode}, 'kind episode registered' );
	is_deeply( [ sort keys %{ $REGISTERED{episode} || {} } ], [qw(metadata onStream resolve)], 'resolve, metadata and onStream (O6; no onStop)' );
	ok( !( grep { ref $_ ne 'CODE' } values %{ $REGISTERED{episode} || {} } ), 'all are code refs' );
};

# ---- resolve: contract-4 shape ----

subtest 'resolve: contract-4 shape (url, alternates array, meta; failToken only for geo)' => sub {
	fresh();
	serve_doc();
	my $r = kind_resolve($ID);
	is( $r->{url}, $MP3, 'url: the MP3' );
	is_deeply( $r->{alternates}, [], 'alternates: an array' );
	is_deeply( $r->{meta}, { title => $TITLE, artist => 'The Science Show', album => 'The Science Show', cover => $COVER, duration => 3276 }, 'meta: what the metadata hook returns' );
	is_deeply( $r->{meta}, metadata($ID), '... exactly' );
	ok( !exists $r->{failToken}, 'no failToken' );
	is_deeply( [ sort keys %$r ], [qw(alternates meta url)], 'no other keys' );

	fresh();
	serve_doc( sub { $_[0]->{renditions} = [ { url => "$MEDIA/geo-001/a.mp3", MIMEType => 'audio/mpeg', bitrate => 192 } ] } );
	is( kind_resolve($ID)->{failToken}, 'PLUGIN_ABCLISTEN_EPISODE_GEO', 'geo-001: failToken EPISODE_GEO' );
};

# ---- playback through the handler ----

subtest 'scanUrl: plays the MP3; title from the metadata; URL kept' => sub {
	fresh();
	serve_doc();
	scanner();
	my ( $c, $song ) = play($URL);

	is_deeply( [ scanned() ], [$MP3], 'scanned the MP3' );
	my ($track) = $c->args(0);
	is( $track && $track->url,   $URL,   'the track keeps the abclisten:// URL' );
	is( $track && $track->title, $TITLE, 'the track title is the episode title' );
	is( $song->streamUrl, $MP3, 'streamUrl is the MP3' );
	is( $PH->getCurrentTitle( undef, $URL ), $TITLE, 'current title: the episode title' );
	is_deeply( $PH->getMetadataFor( undef, $URL ), { title => $TITLE, artist => 'The Science Show', album => 'The Science Show', cover => $COVER, icon => ICON, duration => 3276 }, 'getMetadataFor' );
	is_deeply( [ $song->calls ], [], 'the song\'s duration/startOffset are never touched' );
};

subtest 'scanUrl: MP3 fails -> the AAC alternate; all geo candidates fail -> the geo message' => sub {
	my $aac = "$MEDIA/x/y.aac";

	fresh();
	serve_doc( sub { $_[0]->{renditions} = [ { url => $aac, MIMEType => 'audio/aac', bitrate => 0 }, { url => $MP3, MIMEType => 'audio/mpeg', bitrate => 192 } ] } );
	scanner($MP3);
	my ($c) = play($URL);
	is_deeply( [ scanned() ], [ $MP3, $aac ], 'the MP3, then the AAC alternate' );
	is( ( $c->args(0) )[0] && ( $c->args(0) )[0]->url, $URL, 'plays the AAC' );

	fresh();
	serve_doc( sub { $_[0]->{renditions} = [ { url => "$MEDIA/geo-001/a.mp3", MIMEType => 'audio/mpeg' }, { url => "$MEDIA/geo-001/a.aac", MIMEType => 'audio/aac' } ] } );
	scanner('all');
	($c) = play($URL);
	is( scalar( scanned() ), 2, 'both geo candidates tried' );
	is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_ABCLISTEN_EPISODE_GEO' ], 'then cb->(undef, EPISODE_GEO)' );
};

subtest 'scanUrl: error tokens, nothing scanned; every failure token reads as text' => sub {
	my %cases = (
		PLUGIN_ABCLISTEN_EPISODE_EXPIRED    => sub { serve_doc( sub { $_[0]->{renditions} = [] } ) },
		PLUGIN_ABCLISTEN_EPISODE_RESTRICTED => sub { serve_doc( sub { $_[0]->{webDistributionRestricted} = JSON::PP::true } ) },
		PLUGIN_ABCLISTEN_LOAD_FAILED        => sub { setEpisodeMeta( $ID, { path => $PATH } ); route( "$SITE/_next/data/$BUILD$PATH.json", error => 'Timed out' ) },
		PLUGIN_ABCLISTEN_EPISODE_NOT_FOUND  => sub {
			route( "$SITE/_next/data/$BUILD/listen/programs/x/x/$ID.json", code => 404, file => 'ondemand/nextdata-generic-1-404.json' );
			route( qr{algolia\.net/1/indexes/}, content => '{"hits":[],"nbHits":0}' );
		},
	);
	for my $token ( sort keys %cases ) {
		fresh();
		$cases{$token}->();
		scanner();
		my ($c) = play($URL);
		is_deeply( [ $c->args(0) ], [ undef, $token ], "$token reaches LMS" );
		is( scalar( scanned() ), 0, "$token: no URL handed to LMS" );
	}

	for my $token ( @O1_TOKENS, @API_TOKENS ) {
		my $text = string($token);
		ok( defined $text && $text =~ /\S/, "$token has text" );
		ok( defined $text && $text ne $token && $text !~ m{://|PLUGIN_}, "$token: readable (no token, no URL): '" . ( defined $text ? $text : '' ) . "'" );
	}
	like( string('PLUGIN_ABCLISTEN_EPISODE_EXPIRED'), qr/isn't available/i, 'EXPIRED also reads right for an episode not released yet' );
	like( string('PLUGIN_ABCLISTEN_EPISODE_GEO'), qr/only available in Australia/, 'GEO: "only available in Australia"' );
};

# ---- metadata ----

subtest 'metadata: full entry, network as album, partial entry, no entry' => sub {
	fresh();
	setEpisodeMeta( $ID, { title => $TITLE, programTitle => 'The Science Show', image => $IMAGE, duration => 3276, description => 'x' } );
	is_deeply( metadata($ID), { title => $TITLE, artist => 'The Science Show', album => 'The Science Show', cover => $COVER, duration => 3276 }, 'full entry: title, program as artist and album, 600 px cover, duration' );

	setEpisodeMeta( $ID, { network => 'ABC Radio National' } );
	is( metadata($ID)->{album}, 'ABC Radio National', 'a cached network is the album' );

	fresh();
	setEpisodeMeta( $ID, { title => 'Only a title' } );
	is_deeply( metadata($ID), { title => 'Only a title', cover => ICON }, 'partial entry: no artist/album/duration keys, the plugin icon' );

	fresh();
	is_deeply( metadata($ID), { title => 'ABC listen episode', cover => ICON }, 'no entry: "ABC listen episode" and the icon' );
	# (an id never resolved in this run, so the handler holds no resolve meta for it)
	is_deeply( $PH->getMetadataFor( undef, 'abclisten://episode/5' ), { title => 'ABC listen episode', cover => ICON, icon => ICON }, '... through getMetadataFor: never the URL' );
	is( $PH->getCurrentTitle( undef, 'abclisten://episode/5' ), 'ABC listen episode', '... and the current title' );

	fresh();
	setEpisodeMeta( $ID, { title => 'X', image => 'https://example.test/art.jpg' } );
	is( metadata($ID)->{cover}, 'https://example.test/art.jpg', 'an image on another host is used as it is' );
};

subtest 'metadata: no HTTP, survives corrupt entries, never an empty title' => sub {
	fresh();
	my $cache = Slim::Utils::Cache->new(CACHE_NAMESPACE);
	my $key   = "episode-meta:$ID";

	my @entries = (
		[ 'not a hash',           'garbage' ],
		[ 'array',                [ 1, 2 ] ],
		[ 'renditions not array', { title => 'T', renditions => 'bad' } ],
		[ 'empty title',          { title => '', programTitle => 'P' } ],
		[ 'blank title',          { title => '   ' } ],
		[ 'title a hash',         { title => { a => 1 }, programTitle => [], image => {}, duration => 'long' } ],
		[ 'undef title',          { title => undef, image => 'not a url' } ],
	);
	for my $case (@entries) {
		my ( $name, $entry ) = @$case;
		$cache->set( $key, $entry, 3600 );
		my $meta = eval { metadata($ID) };
		ok( ref $meta eq 'HASH', "$name: no die, a hash" ) or diag $@;
		ok( $meta && defined $meta->{title} && $meta->{title} =~ /\S/, "$name: non-empty title ('" . ( $meta && defined $meta->{title} ? $meta->{title} : '' ) . "')" );
		ok( !( grep { ref $_ } values %{ $meta || {} } ), "$name: only plain values" );
		is( $meta && $meta->{cover}, ICON, "$name: the icon" );
	}

	is( metadata('')->{title},    'ABC listen episode', 'empty id: fallback title' );
	is( metadata(undef)->{title}, 'ABC listen episode', 'undef id: fallback title' );
	is( scalar( requests() ), 0, 'metadata never makes a request' );
};

# ---- onStream (O6): fill the track's empty duration and bitrate, so LMS can seek ----

my $DRIVE_ID   = '107174638';
my $DRIVE_URL  = "abclisten://episode/$DRIVE_ID";
my $DRIVE_PATH = '/listen/programs/classic-drive/classic-drive/107174638';
my $DRIVE_AAC  = "$MEDIA/audio/02/pj/Z/2j.aac";
my $DRIVE_BPS  = 261_525;    # 353,025,904 B x 8 / 10,799 s

# A song streaming the Classic Drive AAC, with only the cache entry %entry (duration 10799 s
# unless %entry says otherwise; an undef one is not stored).
sub drive_song {
	my %entry = @_;
	fresh();
	setEpisodeMeta( $DRIVE_ID, { duration => 10799, %entry } );
	my $song = FakeSong->new($DRIVE_URL);
	$song->streamUrl($DRIVE_AAC);
	return $song;
}

subtest 'onStream: an AAC track without duration or bitrate gets both from the cache; idempotent' => sub {
	fresh( parseISO8601('2026-10-20T12:00:00Z') );
	setEpisodeMeta( $DRIVE_ID, { path => $DRIVE_PATH } );
	route( "$SITE/_next/data/$BUILD$DRIVE_PATH.json", file => 'ondemand/nextdata-episode-classic-drive-aac.trimmed.json', headers => { 'Content-Type' => 'application/json' } );
	scanner();
	my ( $c, $song ) = play($DRIVE_URL);
	my $track = $song->currentTrack;

	is( $song->streamUrl, $DRIVE_AAC, 'streaming the AAC' );
	ok( !$track->secs && !$track->bitrate, 'before: no duration, no bitrate (what LMS\'s scan leaves for ADTS AAC)' );

	is_deeply( on_stream( $song, 'AAC' ), [ 10799, $DRIVE_BPS, [ setBitrate => $DRIVE_BPS ], [ setDuration => 10799 ] ],
		'after: duration 10,799 s and bitrate 261,525 bps, set once each through Slim::Music::Info' );
	ok( logged_like( INFO => qr/Episode $DRIVE_ID: LMS gave the stream no duration and no bitrate; .*10799 s.*261525 bps/ ), '... logged at INFO' );

	my $other = ABCListenTest::FakeClient->new( '00:00:00:00:00:02', song => undef );
	is_deeply( on_stream( $song, 'sync group', $other ), [ 10799, $DRIVE_BPS ], 'onStream for another player of a sync group: nothing set again' );
	is_deeply( on_stream( $song, 'after a seek' ), [ 10799, $DRIVE_BPS ], 'onStream after a seek: nothing set again' );
	is_deeply( [ $song->calls ], [], 'the song\'s own duration/startOffset are never touched' );
};

subtest 'onStream: fill-only, what LMS set (an MP3\'s) is never overwritten' => sub {
	fresh();
	serve_doc();
	scanner();
	my ( $c, $song ) = play($URL);
	my $track = $song->currentTrack;

	$track->secs(3276.04);
	$track->bitrate(192000);    # as LMS's scan of the MP3 sets them
	is_deeply( on_stream( $song, 'MP3' ), [ 3276.04, 192000 ], 'MP3 with LMS\'s duration and bitrate: nothing set, both kept' );

	$track->bitrate(undef);
	$track->secs(3000);
	is_deeply( on_stream( $song, 'no bitrate' ), [ 3000, 192000, [ setBitrate => 192000 ] ], 'duration known, bitrate not: only the bitrate (the cached 192 kbps), LMS\'s duration kept' );

	$track->secs(undef);
	$track->bitrate(128000);
	is_deeply( on_stream( $song, 'no duration' ), [ 3276, 128000, [ setDuration => 3276 ] ], 'bitrate known, duration not: only the duration, LMS\'s bitrate kept' );
	is_deeply( [ $song->calls ], [], 'the song\'s own duration/startOffset are never touched' );
};

subtest 'onStream: redirected stream, pre-O6 entries, nothing derivable or no entry (skipped, no error)' => sub {
	my $aac = { url => $DRIVE_AAC, mime => 'audio/aac' };

	my $song = drive_song( renditions => [ { %$aac, bitrate => 261.525 } ] );
	$song->streamUrl("$MEDIA/redirected/2j.aac");
	$song->currentTrack->redir($DRIVE_AAC);
	is( on_stream( $song, 'redirected' )->[1], $DRIVE_BPS, 'redirected: the bitrate of the rendition the track was redirected from' );

	$song = drive_song( renditions => [ { %$aac, bitrate => 0, fileSize => 353_025_904 } ] );
	is_deeply( on_stream( $song, 'pre-O6 with fileSize' ), [ 10799, $DRIVE_BPS, [ setBitrate => $DRIVE_BPS ], [ setDuration => 10799 ] ],
		'a pre-O6 entry with fileSize and duration: the bitrate is derived now' );

	$song = drive_song( renditions => [ { %$aac, bitrate => 0 } ] );
	is_deeply( on_stream( $song, 'pre-O6 without fileSize' ), [ 10799, undef, [ setDuration => 10799 ] ], 'a pre-O6 entry without fileSize: no bitrate (stays unseekable); the duration is filled' );

	for my $duration ( 0, undef ) {
		my $name = 'duration ' . ( defined $duration ? $duration : 'missing' );
		$song = drive_song( renditions => [ { %$aac, bitrate => 0, fileSize => 353_025_904 } ], duration => $duration );
		is_deeply( on_stream( $song, $name ), [ undef, undef ], "$name: nothing derived, nothing set" );
	}

	$song = drive_song( renditions => [ { %$aac, url => "$MEDIA/another.aac", bitrate => 261.525 } ] );
	is_deeply( on_stream( $song, 'another URL' ), [ 10799, undef, [ setDuration => 10799 ] ], 'streaming a URL that no cached rendition has: no bitrate' );

	fresh();
	$song = FakeSong->new($DRIVE_URL);
	is_deeply( on_stream( $song, 'no entry' ), [ undef, undef ], 'no cache entry: nothing set' );
};

subtest 'static: the song\'s duration/startOffset never set, no setCurrentTitle; the track\'s only filled (O6 rule)' => sub {
	my $file = File::Spec->catfile( $FindBin::Bin, '..', 'ABCListen', 'Episode.pm' );
	open( my $fh, '<', $file ) or die "Can't open $file: $!";
	my @lines = <$fh>;
	close $fh;

	is_deeply( [ grep { /->(?:duration|startOffset)\(|setCurrentTitle\(/ } @lines ], [], 'no $song->duration/startOffset call, no setCurrentTitle in Episode.pm' );
	is_deeply( [ grep { /->(?:secs|bitrate|vbr_scale)\(\s*[^\s)]/ } @lines ], [], 'no direct secs/bitrate/vbr_scale setter' );

	my @setDuration = grep {/Slim::Music::Info::setDuration\(/} @lines;
	my @setBitrate  = grep {/Slim::Music::Info::setBitrate\(/} @lines;
	is( scalar(@setDuration) . '/' . scalar(@setBitrate), '1/1', 'one Slim::Music::Info::setDuration and one setBitrate call' );
	like( $setDuration[0] || '', qr/\bif !\$track->secs &&/,    '... setDuration only when the track has no duration (fill-only)' );
	like( $setBitrate[0]  || '', qr/\bif !\$track->bitrate &&/, '... setBitrate only when the track has no bitrate (fill-only)' );

	ok( Slim::Utils::Strings::stringExists('PLUGIN_ABCLISTEN_EPISODE'), 'the fallback title token exists' );
};

done_testing();

# ---- fakes for Slim::Schema::RemoteTrack and Slim::Player::Song (as in t/14) ----

package FakeTrack;

sub new { my ( $class, %args ) = @_; return bless {%args}, $class }

sub url   { my $self = shift; $self->{url}   = shift if @_; return $self->{url} }
sub title { my $self = shift; $self->{title} = shift if @_; return $self->{title} }
sub cover { my $self = shift; $self->{cover} = shift if @_; return $self->{cover} }

# as Slim::Schema::RemoteTrack: secs (duration), bitrate (bps), vbr_scale, redir (the URL before a redirect)
sub secs      { my $self = shift; $self->{secs}      = shift if @_; return $self->{secs} }
sub bitrate   { my $self = shift; $self->{bitrate}   = shift if @_; return $self->{bitrate} }
sub vbr_scale { my $self = shift; $self->{vbr_scale} = shift if @_; return $self->{vbr_scale} }
sub redir     { my $self = shift; $self->{redir}     = shift if @_; return $self->{redir} }

package FakeSong;

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
