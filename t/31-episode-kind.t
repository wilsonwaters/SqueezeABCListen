#!/usr/bin/perl
# The `episode` kind (Plugins::ABCListen::Episode->init) through the protocol handler's registry:
# registration (resolve + metadata), the contract-4 resolve shape (url, alternates array, meta,
# failToken only for geo), playback through scanUrl (the MP3, the AAC alternate after a failed
# scan, the geo message when every candidate fails, error tokens without a scan), readable text
# for every failure token, and metadata (full and partial cache entries, network, 600 px cover,
# the no-entry fallback, no HTTP, corrupt entries, never an empty title). Offline: SimpleAsyncHTTP,
# remote scanner and clock are stubs. Fixtures: t/data/ondemand (see t/30-episode.t).

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

# ---- registration ----

subtest 'Episode->init registers the episode kind with resolve and metadata' => sub {
	ok( $REGISTERED{episode}, 'kind episode registered' );
	is_deeply( [ sort keys %{ $REGISTERED{episode} || {} } ], [qw(metadata resolve)], 'resolve and metadata (no onStream/onStop)' );
	ok( !( grep { ref $_ ne 'CODE' } values %{ $REGISTERED{episode} || {} } ), 'both are code refs' );
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

subtest 'static: Episode.pm never touches the song duration/startOffset nor setCurrentTitle with a client' => sub {
	my $file = File::Spec->catfile( $FindBin::Bin, '..', 'ABCListen', 'Episode.pm' );
	open( my $fh, '<', $file ) or die "Can't open $file: $!";
	my @hits = grep { /->(?:duration|startOffset)\(|setCurrentTitle\(/ } <$fh>;
	close $fh;
	is_deeply( \@hits, [], 'none in Episode.pm' );
	ok( Slim::Utils::Strings::stringExists('PLUGIN_ABCLISTEN_EPISODE'), 'the fallback title token exists' );
};

done_testing();

# ---- fakes for Slim::Schema::RemoteTrack and Slim::Player::Song (as in t/14) ----

package FakeTrack;

sub new { my ( $class, %args ) = @_; return bless {%args}, $class }

sub url   { my $self = shift; $self->{url}   = shift if @_; return $self->{url} }
sub title { my $self = shift; $self->{title} = shift if @_; return $self->{title} }
sub cover { my $self = shift; $self->{cover} = shift if @_; return $self->{cover} }

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
