#!/usr/bin/perl
# Plugins::ABCListen::Stations (and StationData), offline: catalogue integrity against the captured
# BFF collections, PAPI services and Icecast probes (unique ids, groups, every card mapped, every listed
# variant, mounts, crop-param logos, PAPI time zones and titles); byPageSlug (live pages, network homes,
# host variants, aliases); mediahub normalisation; .pls parsing (LF/CRLF, extra entries, missing File1,
# HTML, odd hosts); stream candidates (Icecast from the .pls with a 24 h cache and the static fallback,
# the mediahub alternate, HLS-only, variants, Wide Bay, never .m3u8/.f4m/.pls); event-only services
# (on air / off air / {} / null / errors, 5 min cache, at most 6 requests at once); BFF enrichment
# (names for sport, logos, order, unknown cards, failures, 24 h); and the `live` kind in Live.pm
# (resolve shapes and tokens with exactly one callback, metadata that never dies).
#
# Fixtures in t/data/live/ are raw response bodies as served:
#   bff-collection-national.json          GET /core-next/api/collection/listen/radio?collectionId=12872264&metaInMeta=false&rootMetaCollectionId=14139428 (captured 2026-10-19)
#   bff-collection-state-<ST>.json        the same with rootMetaCollectionId=14123276 and collectionId NSW 14126370, ACT 14126436,
#                                         NT 14128062, VIC 14128070, SA 14128508, TAS 14128536, QLD 14128542, WA 14128996 (captured 2026-10-19)
#   papi-services-offset{0,100}.json      GET https://program.abcradio.net.au/api/v1/services.json[?offset=100] (captured 2026-10-19;
#                                         items trimmed to service_id, title, mini_synopsis, service_timezone, exclude_from_display, linked_services)
#   bff-epgNowPlaying-RN-now.json         research sample (wrapper stripped): an on-air service (hls + mediahub aac sources)
#   bff-epgNowPlaying-SPORT_BBL-now.json  captured 2026-10-19: an off-air event service answers `null`
#   bff-epgNowPlaying-ABCSPORTSYNC-now.json captured 2026-10-19: on air, hls + a legacy www.abc.net.au .pls aac source
#   live-ice-triplejnsw.pls               research sample: https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls
#   derived-icecast-probe.tsv             research probe of the .pls files (slug, status, File1, type, kbps, first bytes)
#   icecast-pls-probe.tsv                 fresh probe 2026-10-19 of every catalogue .pls (slug, status, File1)
#   synthetic: pls-*.pls / pls-error-page.html (.pls edge cases), epg-*.json (event shapes: on air via .pls or
#   mediahub, HLS-only sources, {}, no sources)

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();

use Slim::Utils::Log;

use Plugins::ABCListen::Stations;
use Plugins::ABCListen::StationData;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::API;

my $S   = 'Plugins::ABCListen::Stations';
my $BFF = 'https://www.abc.net.au/core-next/api/';
my $PLS = 'https://streaming.abc-cdn.net.au/audio/ice/%s.pls';
my $ICE = 'https://abc.streamguys1.com/live/%s/icecast.audio';
my $NOW = 1_792_389_600;    # 2026-10-19 19:00 AEDT

my $HLS_ONLY    = 'PLUGIN_ABCLISTEN_LIVE_HLS_ONLY';
my $OFF_AIR     = 'PLUGIN_ABCLISTEN_LIVE_OFF_AIR';
my $LIVE_FAILED = 'PLUGIN_ABCLISTEN_LIVE_FAILED';
my $UNAVAILABLE = 'PLUGIN_ABCLISTEN_UNAVAILABLE';

my %STATE_COLLECTION = (
	NSW => 14126370, ACT => 14126436, NT  => 14128062, VIC => 14128070,
	SA  => 14128508, TAS => 14128536, QLD => 14128542, WA  => 14128996,
);

# record INFO and DEBUG calls too
$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub json_fixture { JSON::PP::decode_json( fixture("live/$_[0]") ) }

sub reset_all {
	resetStubs();
	$S->_reset();
	$S->_setRecords();
	setTime($NOW);
	return;
}

sub ice { sprintf $ICE, shift }
sub pls { sprintf $PLS, shift }

sub collection_url {
	my ( $id, $root ) = @_;
	return "${BFF}collection/listen/radio?collectionId=$id&metaInMeta=false&rootMetaCollectionId=$root";
}

sub epg_url { "${BFF}epgNowPlaying/$_[0]/now?imageRatio=1x1" }

sub http_count {
	my $re = shift;
	return scalar grep { $_->{url} =~ $re } requests();
}

# streamCandidates / eventStatus answer as a collector
sub candidates {
	my $id = shift;
	my $c  = collector();
	$S->streamCandidates( $id, $c->cb );
	return $c;
}

my @RECORDS = Plugins::ABCListen::StationData::records();
my %RECORD  = map { $_->{id} => $_ } @RECORDS;

# ---- fixtures read by the integrity checks ----

my %PAPI;
for my $page (qw(0 100)) {
	$PAPI{ uc $_->{service_id} } = $_ for @{ json_fixture("papi-services-offset$page.json")->{items} };
}

sub read_tsv {
	my %rows;
	for my $line ( split /\n/, fixture( 'live/' . shift ) ) {
		my ( $slug, $status, $file1 ) = split /\t/, $line;
		$rows{$slug} = { status => $status, file1 => $file1 };
	}
	return %rows;
}
my %DERIVED_PROBE = read_tsv('derived-icecast-probe.tsv');
my %FRESH_PROBE   = read_tsv('icecast-pls-probe.tsv');

sub mount_of_file1 { defined $_[0] && $_[0] =~ m{\Ahttps://abc\.streamguys1\.com/live/([^/]+)/icecast\.audio\z} ? $1 : undef }

my %CARDS = ( national => json_fixture('bff-collection-national.json')->{collection}->{items} );
$CARDS{$_} = json_fixture("bff-collection-state-$_.json")->{collection}->{items} for keys %STATE_COLLECTION;

my $NOT_A_STATION = 'https://www.abc.net.au/listen/radio#find-your-local-station';

# ---- catalogue integrity ----

subtest 'catalogue: ids, groups and fields' => sub {
	my %seen;
	my @dupes = grep { $seen{$_}++ } map { $_->{id} } @RECORDS;
	is_deeply( \@dupes, [], 'ids are unique' );
	is( scalar @RECORDS, 101, '101 services' );

	my %groups;
	$groups{ $_->{group} }++ for @RECORDS;
	is_deeply( \%groups, { network => 12, sport => 16, local => 52, variant => 17, hidden => 4 }, 'group sizes' );

	like( $_->{id}, qr/\A[A-Z0-9_]+\z/, "$_->{id}: an upper-case service id" ) for grep { $_->{id} !~ /\A[A-Z0-9_]+\z/ } @RECORDS;
	is( scalar( grep { !( defined $_->{name} && $_->{name} =~ /\S/ ) } @RECORDS ), 0, 'every station has a name' );
	is( scalar( grep { !defined $_->{network} } @RECORDS ), 0, 'every station has a network' );

	my @bad_logos = grep { !( defined $_->{logo} && $_->{logo} =~ /[?&]cropW=\d+/ && $_->{logo} =~ /[?&]cropH=\d+/ && $_->{logo} =~ m{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/[0-9a-f]{32}\?impolicy=wcms_crop_resize&} ) } @RECORDS;
	is_deeply( [ map { $_->{id} } @bad_logos ], [], 'every logo is a wcms URL with its crop params (cropW=, cropH=)' );

	my @tz = grep { !$PAPI{ $_->{id} } || ( $PAPI{ $_->{id} }->{service_timezone} // '' ) ne $_->{tz} } @RECORDS;
	is_deeply( [ map { $_->{id} } @tz ], [], 'every tz equals PAPI service_timezone' );
	is( $RECORD{LOCAL_BROKENHILL}->{tz}, 'Australia/Broken_Hill', 'ABC Broken Hill is on Broken Hill time (an NSW station on SA time)' );
	is( $RECORD{LOCAL_PERTH}->{tz},      'Australia/Perth',       '102.5 ABC Perth: Perth time (not the derived JSON\'s Sydney)' );

	my %renamed = ( RA => 1, GRANDSTAND_EXTRA => 1 );
	my @names = grep { !$renamed{ $_->{id} } && do { ( my $t = $PAPI{ $_->{id} }->{title} ) =~ s/\A\s+|\s+\z//g; $t ne $_->{name} } } @RECORDS;
	is_deeply( [ map { $_->{id} } @names ], [], 'names are the PAPI titles (trimmed), except RA and GRANDSTAND_EXTRA' );
	is( $RECORD{RA}->{name},    'Radio Australia (English)', 'RA is told apart from RA_ML' );
	is( $RECORD{RA_ML}->{name}, 'Radio Australia',           'RA_ML keeps "Radio Australia"' );
	is( $RECORD{GRANDSTAND_EXTRA}->{name}, 'ABC Sport Extra (Grandstand)', 'GRANDSTAND_EXTRA is told apart from ITINERANT_THREE' );
	is( $RECORD{ITINERANT_THREE}->{name},  'ABC SPORT EXTRA',              'ITINERANT_THREE keeps its PAPI title' );
	isnt( lc $RECORD{GRANDSTAND_EXTRA}->{name}, lc $RECORD{ITINERANT_THREE}->{name}, 'the two Sport Extra services do not sound the same (case aside)' );

	my @synopsis = grep {
		my $papi = $PAPI{ $_->{id} }->{mini_synopsis};
		$papi = '' unless defined $papi;
		$papi =~ s/\s+/ /g;
		$papi =~ s/\A\s+|\s+\z//g;
		$papi ne ( $_->{synopsis} // '' );
	} @RECORDS;
	is_deeply( [ map { $_->{id} } @synopsis ], [], 'synopsis is the PAPI mini_synopsis' );

	is_deeply(
		{ map { $_->{id} => $_->{musicStation} } grep { $_->{musicStation} } @RECORDS },
		{ TRIPLEJ => 'triplej', DOUBLEJ => 'doublej', UNEARTHED => 'unearthed', JAZZ => 'jazz', COUNTRY => 'country', CLASSIC => 'classic', CLASSIC2 => 'classic2', H100 => 'h100', KIDSLISTEN => 'kidslisten' },
		'musicStation for the music networks'
	);

	is_deeply(
		{ map { $_->{id} => $_->{hls} } grep { $_->{hls} } @RECORDS },
		{
			CLASSIC2      => 'https://mediaserviceslive.akamaized.net/hls/live/2038317/classic2/index.m3u8',
			LOCAL_WIDEBAY => 'https://mediaserviceslive.akamaized.net/hls/live/2038240/localwidebay/index.m3u8',
			ABCSPORTSYNC  => 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8',
			ABC_AFL_RAPID => 'https://abc-hls.streamguys1.com/hls/sport-sync-afl/playlist.m3u8',
		},
		'an hls field only where the master is not .../audio/hls/<hlsSlug>.m3u8'
	);
	is( $RECORD{CLASSIC2}->{hlsSlug}, 'classic2', 'CLASSIC2: hlsSlug is the .pls name' );

	my @playlistFields = grep { join( ' ', map { $_ // '' } @$_{qw(mount mediahub hlsSlug)} ) =~ /\.(?:m3u8|f4m)/i } @RECORDS;
	is_deeply( [ map { $_->{id} } @playlistFields ], [], 'no .m3u8/.f4m in mount, mediahub or hlsSlug' );

	is_deeply( [ sort map { $_->{id} } grep { $_->{eventOnly} } @RECORDS ], [qw(GRANDSTAND_EXTRA SPORT_AFL SPORT_AFL_EXTRA SPORT_BBL SPORT_CRICKET SPORT_TENNIS SPORT_WBBL)], 'event-only services (SPORT_CRICKET is in PAPI)' );
	is_deeply( [ sort map { $_->{id} } grep { $_->{hlsOnly} } @RECORDS ], [qw(ABCSPORTSYNC ABC_AFL_RAPID ITINERANT_FOUR KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA)], 'HLS-only services (no Icecast mount)' );
	is_deeply( { map { $_->{id} => $_->{dupOf} } grep { $_->{dupOf} } @RECORDS }, { SPORT_WORLDCUP => 'ITINERANT_ONE', SPORT_AFLW => 'ITINERANT_TWO' }, 'dedupe by stream: ITINERANT_ONE and ITINERANT_TWO are listed' );
	is_deeply( [ map { $_->{id} } grep { $_->{group} eq 'hidden' } @RECORDS ], [qw(KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA)], 'hidden: the HLS-only Kids listen versions' );
	is_deeply( [ sort map { $_->{id} } grep { $_->{capital} } @RECORDS ], [qw(LOCAL_ADELAIDE LOCAL_BRISBANE LOCAL_CANBERRA LOCAL_DARWIN LOCAL_HOBART LOCAL_MELBOURNE LOCAL_PERTH LOCAL_SYDNEY)], 'one capital-city station per state' );
};

subtest 'catalogue: mounts against the Icecast probes' => sub {
	my @missing;
	for my $rec ( grep { !$_->{hlsOnly} && !$_->{eventOnly} } @RECORDS ) {
		my ($inDerived) = grep { ( mount_of_file1( $DERIVED_PROBE{$_}->{file1} ) // '' ) eq ( $rec->{mount} // '-' ) } keys %DERIVED_PROBE;
		push @missing, $rec->{id} unless $inDerived;
	}
	is_deeply( [ sort @missing ], [qw(CLASSIC2 LOCAL_WIDEBAY)], 'every other non-HLS-only mount is in derived-icecast-probe.tsv' );

	for my $id (qw(CLASSIC2 LOCAL_WIDEBAY)) {
		is( mount_of_file1( $FRESH_PROBE{ $RECORD{$id}->{hlsSlug} }->{file1} ), $RECORD{$id}->{mount}, "$id: mount $RECORD{$id}->{mount} found by the fresh .pls probe" );
	}

	my @disagree = grep { $_->{mount} && ( mount_of_file1( $FRESH_PROBE{ $_->{hlsSlug} }->{file1} ) // '' ) ne $_->{mount} } @RECORDS;
	is_deeply( [ map { $_->{id} } @disagree ], [], 'the fresh probe of every station .pls agrees with its mount' );

	my @noProbe = grep { $_->{hlsOnly} && $_->{hlsSlug} && ( $FRESH_PROBE{ $_->{hlsSlug} }->{status} // '' ) ne '404' } @RECORDS;
	is_deeply( [ map { $_->{id} } @noProbe ], [], 'HLS-only services with a .pls name really have none (404)' );
};

subtest 'catalogue: every BFF card maps to an entry; states and order' => sub {
	reset_all();

	my @unmapped;
	for my $name ( sort keys %CARDS ) {
		for my $card ( @{ $CARDS{$name} } ) {
			next if $card->{articleLink} eq $NOT_A_STATION;
			my $id = $S->byPageSlug( $card->{articleLink} );
			push @unmapped, "$name: $card->{articleLink}" unless $id && $S->get($id);
		}
	}
	is_deeply( \@unmapped, [], 'every station card of the 9 captured collections maps to a catalogue entry (byPageSlug)' );
	is( scalar( grep { $_->{articleLink} eq $NOT_A_STATION } @{ $CARDS{national} } ), 1, 'the only other card is the "ABC local radio stations" link' );

	my @networkCards = grep { $_ && $RECORD{$_}->{group} eq 'network' } map { $S->byPageSlug( $_->{articleLink} ) } @{ $CARDS{national} };
	is_deeply( [ map { $_->{id} } grep { $_->{group} eq 'network' } @RECORDS ], \@networkCards, 'networks in the BFF national-collection order' );
	is_deeply( [ map { $_->{id} } $S->list('network') ], \@networkCards, 'list(network): the same order before enrichment' );

	my $cards = 0;
	for my $state ( sort keys %STATE_COLLECTION ) {
		my @ids;
		for my $card ( @{ $CARDS{$state} } ) {
			$cards++;
			my $id = $S->byPageSlug( $card->{articleLink} );
			push @ids, $id unless grep { $_ eq $id } @ids;
		}
		my @catalogue = sort map { $_->{id} } grep { $_->{group} eq 'local' && $_->{state} eq $state } @RECORDS;
		is_deeply( \@catalogue, [ sort @ids ], "$state: the catalogue's stations are the ones its collection lists" );
	}
	is( $cards, 53, '53 local cards' );
	is( scalar( grep { $_->{group} eq 'local' } @RECORDS ), 52, '52 local service ids (Katherine is Darwin)' );
	is( $S->byPageSlug('https://www.abc.net.au/listen/live/katherine/'), 'LOCAL_DARWIN', 'the Katherine card is LOCAL_DARWIN' );

	my %count = map { my $s = $_; $s => scalar( grep { $_->{group} eq 'local' && $_->{state} eq $s } @RECORDS ) } keys %STATE_COLLECTION;
	is_deeply( \%count, { NSW => 14, ACT => 1, NT => 2, VIC => 9, SA => 5, TAS => 2, QLD => 11, WA => 8 }, 'stations per state' );

	my @variants = qw(RN_NT RN_QLD RN_SA RN_WA TRIPLEJ_ADELAIDE TRIPLEJ_BRISBANE TRIPLEJ_DARWIN TRIPLEJ_PERTH DOUBLEJ_ADELAIDE DOUBLEJ_BRISBANE DOUBLEJ_DARWIN DOUBLEJ_PERTH CLASSIC_ADELAIDE CLASSIC_BRISBANE CLASSIC_DARWIN CLASSIC_PERTH RA);
	is_deeply( [ sort map { $_->{id} } grep { $_->{group} eq 'variant' } @RECORDS ], [ sort @variants ], 'every variant listed in the master plan has an entry (17)' );
	is( scalar( grep { $_->{group} eq 'variant' && $_->{id} ne 'RA' && !( $_->{city} && $_->{state} ) } @RECORDS ), 0, 'variants know their city and state' );
	is( scalar( grep { ( $_->{group} eq 'variant' || $_->{group} eq 'hidden' ) && $_->{logo} ne $RECORD{ $_->{network} }->{logo} } @RECORDS ), 0, 'variants use their parent network\'s logo' );
};

# ---- byPageSlug ----

subtest 'byPageSlug' => sub {
	my @cases = (
		[ 'sydney',                                            'LOCAL_SYDNEY' ],
		[ 'SYDNEY',                                            'LOCAL_SYDNEY' ],
		[ '/listen/live/sydney/',                              'LOCAL_SYDNEY' ],
		[ 'https://www.abc.net.au/listen/live/sydney/?x=1#y',  'LOCAL_SYDNEY' ],
		[ 'https://www.abc.net.au/triplej/live/unearthed',     'UNEARTHED' ],
		[ '/triplej/live/triplej',                             'TRIPLEJ' ],
		[ '/listen/doublej/live',                              'DOUBLEJ' ],
		[ 'katherine',                                         'LOCAL_DARWIN' ],
		[ '/listen/live/katherine',                            'LOCAL_DARWIN' ],
		[ 'radionational',                                     'RN' ],
		[ '/listen/radionational/',                            'RN' ],
		[ 'https://www.abc.net.au/triplej/',                   'TRIPLEJ' ],
		[ 'https://www.abc.net.au/triplejhottest/',            'H100' ],
		[ 'triplejhottest',                                    'H100' ],
		[ 'https://www.abc.net.au/listen/doublej/',            'DOUBLEJ' ],
		[ '/listen/classic/',                                  'CLASSIC' ],
		[ 'classic2',                                          'CLASSIC2' ],
		[ '/listen/jazz/',                                     'JAZZ' ],
		[ 'country',                                           'COUNTRY' ],
		[ '/listen/live/country/',                             'COUNTRY' ],
		[ 'https://www.abc.net.au/kidslisten/',                'KIDSLISTEN' ],
		[ 'https://www.abc.net.au/pacific/live/',              'RA_ML' ],
		[ 'https://www.abc.net.au/listen/news',                'NEWS' ],
		[ 'news',                                              'NEWS' ],
		[ '/listen/live/news',                                 'NEWS' ],
		[ '/news',                                             undef ],
		[ 'https://www.abc.net.au/news',                       undef ],
		[ 'https://abc.net.au/listen/live/sportextra',         'ITINERANT_THREE' ],
		[ 'https://abc.net.au/listen/live/worldcup',           'SPORT_WORLDCUP' ],
		[ 'https://www.abc.net.au/listen/live/aflw',           'SPORT_AFLW' ],
		[ '//www.abc.net.au/listen/live/hobart',               'LOCAL_HOBART' ],
		[ 'https://www.triplejunearthed.com/',                 'UNEARTHED' ],
		[ 'https://www.abc.net.au/listen/live/nope',           undef ],
		[ 'nope',                                              undef ],
		[ 'https://example.com/listen/live/sydney',            undef ],
		[ 'https://www.triplejunearthed.com/artist/x',         undef ],
		[ '/listen/programs/sport',                            undef ],
		[ '/listen/sport',                                     undef ],
		[ '/listen/sydney',                                    undef ],
		[ $NOT_A_STATION,                                      undef ],
		[ 'listen/live/sydney',                                undef ],
		[ '',                                                  undef ],
		[ undef,                                               undef ],
		[ [],                                                  undef ],
	);

	for my $case (@cases) {
		my ( $in, $want ) = @$case;
		is( $S->byPageSlug($in), $want, 'byPageSlug(' . ( defined $in ? ( ref $in ? 'ARRAY' : "'$in'" ) : 'undef' ) . ') -> ' . ( $want // 'undef' ) );
	}
};

# ---- mediahub and .pls parsing ----

subtest 'normaliseMediahub' => sub {
	my $n = \&Plugins::ABCListen::Stations::normaliseMediahub;
	my $want = 'https://live-radio01.mediahubaustralia.com/2RNW/aac/';
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/aac/'),             $want, 'https unchanged' );
	is( $n->('http:live-radio01.mediahubaustralia.com/2RNW/aac/'),                $want, 'http: without //' );
	is( $n->('http://live-radio01.mediahubaustralia.com/2RNW/aac/'),              $want, 'http://' );
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/aac/;*.mp3'),       $want, ';*.mp3 dropped' );
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/aac/;'),            $want, 'trailing ; dropped' );
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/aac/?source=web'),  $want, '?source=web dropped' );
	is( $n->('http:live-radio01.mediahubaustralia.com/2RNW/aac/;*.mp3?source=web'), $want, 'all at once' );
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/aac'),              $want, 'missing trailing /' );
	is( $n->(' https://LIVE-RADIO03.mediahubaustralia.com/4BBGW/aac/ '),          'https://live-radio03.mediahubaustralia.com/4BBGW/aac/', 'whitespace, host case' );
	is( $n->('http:hot100.mediahubaustralia.com/TJHW/aac/'),                      'https://hot100.mediahubaustralia.com/TJHW/aac/', 'other mediahub hosts keep their host' );
	is( $n->('https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls'), undef, 'legacy www.abc.net.au .pls: not mediahub, no alternate' );
	is( $n->('https://streaming.abc-cdn.net.au/audio/hls/rnnsw.m3u8'),           undef, 'HLS: no' );
	is( $n->('https://live-radio01.mediahubaustralia.com/2RNW/mp3/'),             undef, 'only AAC streams' );
	is( $n->('https://live-radio01.mediahubaustralia.com.evil.test/2RNW/aac/'),   undef, 'lookalike host: no' );
	is( $n->(undef), undef, 'undef' );
	is( $n->(''),    undef, 'empty' );

	my @bad;
	for my $rec ( grep { $_->{mediahub} } @RECORDS ) {
		my $url = $n->( $rec->{mediahub} );
		push @bad, $rec->{id} unless defined $url && $url =~ m{\Ahttps://[a-z0-9-]+\.mediahubaustralia\.com/[A-Za-z0-9]+/aac/\z};
	}
	is_deeply( \@bad, [], 'every catalogue mediahub source normalises to https://<host>/<CODE>/aac/' );
};

subtest 'parsePls' => sub {
	my $p    = \&Plugins::ABCListen::Stations::parsePls;
	my $want = ice('triplejnsw');
	is( $p->( fixture('live/live-ice-triplejnsw.pls') ), $want, 'the captured triplejnsw.pls' );
	is( $p->( fixture('live/pls-crlf.pls') ),            $want, 'CRLF line endings' );
	is( $p->( fixture('live/pls-extra-entries.pls') ),   $want, 'File2 and whitespace around File1' );
	is( $p->( fixture('live/pls-moved.pls') ),           ice('triplejsyd'), 'a changed mount is taken' );
	is( $p->( fixture('live/pls-no-file1.pls') ),        undef, 'no File1: undef' );
	is( $p->( fixture('live/pls-odd-host.pls') ),        undef, 'File1 not on abc.streamguys1.com: undef' );
	is( $p->( fixture('live/pls-hls.pls') ),             undef, 'File1 an .m3u8: undef' );
	is( $p->( fixture('live/pls-error-page.html') ),     undef, 'an HTML page: undef' );
	is( $p->(''),                                        undef, 'empty body: undef' );
	is( $p->(undef),                                     undef, 'undef: undef' );
	is( $p->("File1=http://abc.streamguys1.com/live/triplejnsw/icecast.audio\n"), undef, 'http File1: undef' );
};

# ---- stream candidates ----

subtest 'streamCandidates: Icecast from the .pls (24 h cache), mediahub alternate' => sub {
	reset_all();
	route( pls('triplejnsw'), file => 'live/live-ice-triplejnsw.pls', headers => { 'Content-Type' => 'audio/x-scpls' } );

	my $c = candidates('TRIPLEJ');
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ [ ice('triplejnsw'), 'https://live-radio01.mediahubaustralia.com/2TJW/aac/' ] ], 'Icecast first, then the normalised mediahub stream' );
	is( http_count(qr{\.pls$}), 1, 'one .pls request' );

	advanceTime( 86400 - 10 );
	$c = candidates('TRIPLEJ');
	is_deeply( [ $c->args(0) ], [ [ ice('triplejnsw'), 'https://live-radio01.mediahubaustralia.com/2TJW/aac/' ] ], 'same answer within 24 h' );
	is( http_count(qr{\.pls$}), 1, 'no new request within 24 h' );

	advanceTime(20);
	candidates('TRIPLEJ');
	is( http_count(qr{\.pls$}), 2, 'fetched again after 24 h' );

	reset_all();
	route( pls('classicnsw'), file => 'live/live-ice-triplejnsw.pls' );
	route( pls('sport'), content => "[playlist]\nFile1=" . ice('sport') . "\n" );
	is_deeply( [ candidates('CLASSIC')->args(0) ], [ [ ice('triplejnsw') ] ], 'File1 is used as given (pls name classicnsw); no mediahub source: no alternate' );
	is_deeply( [ candidates('GRANDSTAND')->args(0) ], [ [ ice('sport') ] ], 'GRANDSTAND: the legacy .pls page source is no alternate' );
	is( ( grep { $_->{url} eq pls('classicnsw') } requests() ) ? 1 : 0, 1, 'the .pls is named by hlsSlug' );

	reset_all();
	route( pls('triplejnsw'), file => 'live/pls-moved.pls' );
	is_deeply( [ candidates('TRIPLEJ')->args(0) ], [ [ ice('triplejsyd'), 'https://live-radio01.mediahubaustralia.com/2TJW/aac/' ] ], 'a changed File1 (moved mount) is used' );
	Slim::Networking::SimpleAsyncHTTP->reset;
	is_deeply( [ candidates('TRIPLEJ')->args(0) ], [ [ ice('triplejsyd'), 'https://live-radio01.mediahubaustralia.com/2TJW/aac/' ] ], '... and cached' );
	is( scalar( requests() ), 0, '... without a request' );

	reset_all();
	route( pls('triplejnsw'), file => 'live/pls-crlf.pls' );
	is_deeply( [ candidates('TRIPLEJ')->args(0) ], [ [ ice('triplejnsw'), 'https://live-radio01.mediahubaustralia.com/2TJW/aac/' ] ], 'CRLF .pls' );
};

subtest 'streamCandidates: any .pls problem -> the static mount (never fails playback)' => sub {
	my %problems = (
		'404'            => [ code => 404, content => 'Not Found' ],
		'timeout'        => [ error => 'Timed out waiting for data' ],
		'HTML page'      => [ file => 'live/pls-error-page.html', headers => { 'Content-Type' => 'text/html' } ],
		'empty body'     => [ content => '' ],
		'missing File1'  => [ file => 'live/pls-no-file1.pls' ],
		'odd host'       => [ file => 'live/pls-odd-host.pls' ],
		'File1 is HLS'   => [ file => 'live/pls-hls.pls' ],
		'500'            => [ code => 500 ],
	);

	for my $problem ( sort keys %problems ) {
		reset_all();
		route( pls('localhobart'), @{ $problems{$problem} } );

		my $c = candidates('LOCAL_HOBART');
		is( $c->count, 1, "$problem: one callback" );
		is_deeply( [ $c->args(0) ], [ [ ice('localhobart'), 'https://live-radio01.mediahubaustralia.com/7LRW/aac/' ] ], "$problem: static mount, then mediahub" );

		Slim::Networking::SimpleAsyncHTTP->reset;
		candidates('LOCAL_HOBART');
		is( scalar( requests() ), 0, "$problem: the fallback is cached too (at most one .pls request a day)" );
	}

	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'no WARN or ERROR for .pls problems' );
	ok( ( grep { $_->{message} =~ /localhobart\.pls: .*using \Q${\ ice('localhobart')}\E/ } logged('INFO') ), 'the fallback is logged at INFO' );

	reset_all();
	route( pls('localhobart'), file => 'live/live-ice-triplejnsw.pls', defer => 1 );
	my $c = candidates('LOCAL_HOBART');
	is( $c->count, 0, 'asynchronous: no answer while the .pls loads' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred( error => 'Connect timed out' );
	is_deeply( [ $c->args(0) ], [ [ ice('localhobart'), 'https://live-radio01.mediahubaustralia.com/7LRW/aac/' ] ], 'late failure: static mount' );
	is( $c->count, 1, 'exactly one callback' );
};

subtest 'streamCandidates: HLS-only, Wide Bay, variants, unknown ids' => sub {
	reset_all();

	for my $id (qw(KIDSLISTEN_NT KIDSLISTEN_QLD KIDSLISTEN_SA KIDSLISTEN_WA ITINERANT_FOUR ABCSPORTSYNC ABC_AFL_RAPID)) {
		my $c = candidates($id);
		is_deeply( [ $c->args(0) ], [ { error => $HLS_ONLY } ], "$id: HLS-only without mediahub -> LIVE_HLS_ONLY" );
		is( $S->playable($id), 0, "$id: not playable" );
	}
	is( scalar( requests() ), 0, 'HLS-only: no request' );

	for my $id ( 'NOPE', undef, '', [] ) {
		my $c = candidates($id);
		is_deeply( [ $c->args(0) ], [ { error => $UNAVAILABLE } ], 'unknown id ' . ( defined $id ? ( ref $id ? 'ARRAY' : "'$id'" ) : 'undef' ) . ' -> UNAVAILABLE' );
		is( $c->count, 1, '... one callback' );
	}

	route( pls('triplejwa'), content => "[playlist]\nFile1=" . ice('triplejwa') . "\n" );
	is_deeply( [ candidates('TRIPLEJ_PERTH')->args(0) ], [ [ ice('triplejwa') ] ], 'variant: its own Icecast stream, no mediahub' );

	route( pls('localwidebay'), content => "[playlist]\nFile1=" . ice('localwidebay') . "\n" );
	is_deeply( [ candidates('LOCAL_WIDEBAY')->args(0) ], [ [ ice('localwidebay'), 'https://live-radio03.mediahubaustralia.com/4BBGW/aac/' ] ], 'Wide Bay: Icecast (localwidebay), mediahub alternate' );
	is( $S->playable('LOCAL_WIDEBAY'), 1, 'Wide Bay is playable' );

	# an HLS-only service with a mediahub stream (as Wide Bay was in the research capture)
	$S->_setRecords( { %{ $RECORD{LOCAL_WIDEBAY} }, mount => undef, hlsSlug => undef, hlsOnly => 1 }, $RECORD{KIDSLISTEN_NT} );
	Slim::Networking::SimpleAsyncHTTP->reset;
	is_deeply( [ candidates('LOCAL_WIDEBAY')->args(0) ], [ ['https://live-radio03.mediahubaustralia.com/4BBGW/aac/'] ], 'HLS-only with mediahub -> mediahub only' );
	is( scalar( requests() ), 0, '... without a .pls request' );
	is( $S->playable('LOCAL_WIDEBAY'), 1, '... and playable' );
	$S->_setRecords();
};

subtest 'streamCandidates over the whole catalogue: direct audio streams only' => sub {
	reset_all();
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{^\Qhttps://streaming.abc-cdn.net.au/audio/ice/\E}, sub {
		my ($url) = @_;
		my ($slug) = $url =~ m{/([^/]+)\.pls$};
		my $row = $FRESH_PROBE{$slug};
		return $row && $row->{file1} ? { content => "[playlist]\nNumberOfEntries=1\nFile1=$row->{file1}\n" } : { code => 404 };
	} );
	route( qr{epgNowPlaying}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' );

	my ( @bad, $answers );
	for my $rec (@RECORDS) {
		my $c = candidates( $rec->{id} );
		$answers++ if $c->count == 1;
		my ($r) = $c->args(0);
		next unless ref $r eq 'ARRAY';
		push @bad, "$rec->{id}: empty" unless @$r;
		push @bad, map {"$rec->{id}: $_"} grep { /\.(?:m3u8|f4m|pls|m3u)(?:[?#]|\z)/i || !m{\Ahttps://} } @$r;
		push @bad, "$rec->{id}: Icecast not first" if $rec->{mount} && $r->[0] ne ice( $rec->{mount} );
	}
	is( $answers, scalar @RECORDS, 'every id answers exactly once' );
	is_deeply( \@bad, [], 'never .m3u8, .f4m or .pls; https only; Icecast first' );
};

# ---- event-only services ----

subtest 'event-only: off air (null, {}, no sources, HLS-only sources, errors) and the 5 min cache' => sub {
	my %offAir = (
		'null (as captured)'  => [ file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' ],
		'{}'                  => [ file => 'live/epg-empty-object.json' ],
		'no sources'          => [ file => 'live/epg-no-sources.json' ],
		'HLS/HDS-only'        => [ file => 'live/epg-event-hls-only.json' ],
		'429'                 => [ code => 429 ],
		'500'                 => [ code => 500 ],
		'transport error'     => [ error => 'Timed out waiting for data' ],
	);

	for my $case ( sort keys %offAir ) {
		reset_all();
		route( epg_url('SPORT_BBL'), @{ $offAir{$case} } );

		my $c = collector();
		$S->eventStatus( 'SPORT_BBL', $c->cb );
		is_deeply( [ $c->args(0) ], [ { onAir => 0, sources => [] } ], "$case: off air" );
		is( $S->playable('SPORT_BBL'), 0, "$case: not playable (hidden)" );

		$c = candidates('SPORT_BBL');
		is_deeply( [ $c->args(0) ], [ { error => $OFF_AIR } ], "$case: resolve -> LIVE_OFF_AIR" );
		is( http_count(qr{epgNowPlaying}), 1, "$case: one request, cached" );

		advanceTime(299);
		candidates('SPORT_BBL');
		is( http_count(qr{epgNowPlaying}), 1, "$case: still cached at 299 s" );
		advanceTime(2);
		candidates('SPORT_BBL');
		is( http_count(qr{epgNowPlaying}), 2, "$case: checked again after 5 min" );
	}

	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'off-air answers log no WARN or ERROR' );

	reset_all();
	my $c = collector();
	$S->eventStatus( 'TRIPLEJ', $c->cb );
	is_deeply( [ $c->args(0) ], [ { onAir => 0, sources => [] } ], 'eventStatus of a service that is not event-only: off air, no request' );
	is( scalar( requests() ), 0, '... no request' );
	is( $S->playable('SPORT_BBL'), 0, 'unknown status: not playable' );
	is( scalar( requests() ), 0, 'playable never fetches' );
};

subtest 'event-only: on air' => sub {
	reset_all();
	route( epg_url('SPORT_BBL'), file => 'live/epg-event-onair-pls.json' );
	route( 'https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls', content => "[playlist]\nFile1=" . ice('sport') . "\n" );

	my $c = collector();
	$S->eventStatus( 'SPORT_BBL', $c->cb );
	is_deeply( [ $c->args(0) ], [ { onAir => 1, sources => ['https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls?source=web'] } ], 'an aac .pls source: on air' );
	is( $S->playable('SPORT_BBL'), 1, 'playable while on air' );
	is_deeply( [ candidates('SPORT_BBL')->args(0) ], [ [ ice('sport') ] ], 'candidates: the .pls resolved to Icecast' );
	is( http_count(qr{epgNowPlaying}), 1, 'the status is cached' );

	reset_all();
	route( epg_url('SPORT_TENNIS'), file => 'live/epg-event-onair-mediahub.json' );
	is_deeply( [ candidates('SPORT_TENNIS')->args(0) ], [ ['https://live-radio02.mediahubaustralia.com/TENW/aac/'] ], 'a mediahub source: on air, mediahub candidate' );

	reset_all();
	route( epg_url('SPORT_AFL'), file => 'live/bff-epgNowPlaying-RN-now.json' );
	is_deeply( [ candidates('SPORT_AFL')->args(0) ], [ ['https://live-radio01.mediahubaustralia.com/2RNW/aac/'] ], 'the RN epg shape (hls + mediahub aac): on air via mediahub; HLS ignored' );

	reset_all();
	route( epg_url('SPORT_WBBL'), file => 'live/bff-epgNowPlaying-ABCSPORTSYNC-now.json' );
	route( 'https://www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls', code => 404 );
	is_deeply( [ candidates('SPORT_WBBL')->args(0) ], [ { error => $LIVE_FAILED } ], 'on air, but its .pls fails and there is no other stream: LIVE_FAILED' );

	reset_all();
	route( epg_url('SPORT_CRICKET'), file => 'live/epg-event-onair-pls.json', defer => 1 );
	route( qr{grandstand\.pls}, content => "[playlist]\nFile1=" . ice('sport') . "\n" );
	$c = candidates('SPORT_CRICKET');
	is( $c->count, 0, 'asynchronous: waits for the event status' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ $c->args(0) ], [ [ ice('sport') ] ], 'then answers once' );
	is( $c->count, 1, 'exactly once' );
};

subtest 'event-only: at most 6 checks at once; checkOnAir answers once' => sub {
	reset_all();
	route( qr{epgNowPlaying}, file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json', defer => 1 );

	my @events = map { $_->{id} } grep { $_->{eventOnly} } @RECORDS;
	is( scalar @events, 7, '7 event-only services' );

	my $c = collector();
	$S->checkOnAir( [ @events, 'SPORT_BBL' ], $c->cb );
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 6, '6 requests in flight, not 7' );
	is( $c->count, 0, 'no answer yet' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 1, 'the 7th starts when one finishes' );
	is( $c->count, 0, 'still waiting for it' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'checkOnAir answers once all are known' );
	is( http_count(qr{epgNowPlaying}), 7, 'one request per service (a repeated id shares it)' );

	$c = collector();
	$S->checkOnAir( \@events, $c->cb );
	is( $c->count, 1, 'all cached: answers at once' );
	is( http_count(qr{epgNowPlaying}), 7, '... without requests' );

	$c = collector();
	$S->checkOnAir( [], $c->cb );
	is( $c->count, 1, 'no ids: answers at once' );
};

# ---- enrichment ----

sub route_collections {
	my %override = @_;
	route( collection_url( 12872264, 14139428 ), %{ $override{national} || { file => 'live/bff-collection-national.json' } } );
	for my $state ( keys %STATE_COLLECTION ) {
		route( collection_url( $STATE_COLLECTION{$state}, 14123276 ), %{ $override{$state} || { file => "live/bff-collection-state-$state.json" } } );
	}
	return;
}

subtest 'enrichment: names (sport), logos, order; unknown cards; 24 h' => sub {
	reset_all();

	my $national = json_fixture('bff-collection-national.json');
	my @items    = @{ $national->{collection}->{items} };
	my ($triplej)  = grep { $_->{articleLink} eq 'https://www.abc.net.au/triplej/' } @items;
	my ($worldcup) = grep { $_->{articleLink} =~ /worldcup$/ } @items;
	my ($rn)       = grep { $_->{articleLink} =~ /radionational/ } @items;
	$worldcup->{cardTitle} = 'ABC Cricket World Cup';
	$triplej->{cardTitle}  = 'triple j (BFF title)';
	$triplej->{cardImagePrepared}->{imgSrc} = 'https://live-production.wcms.abc-cdn.net.au/00000000000000000000000000000001?impolicy=wcms_crop_resize&cropH=500&cropW=500&xPos=0&yPos=0&width=862&height=862';
	$rn->{cardImagePrepared}->{imgSrc} = 'https://live-production.wcms.abc-cdn.net.au/00000000000000000000000000000002';    # no crop params: ignored
	# move triple j to the front, drop Double J's card, add an unknown card
	@items = ( $triplej, grep { $_ != $triplej && $_->{articleLink} !~ m{/listen/doublej/$} } @items );
	push @items, { articleLink => 'https://www.abc.net.au/listen/live/newstation', cardTitle => 'ABC New Station' };
	$national->{collection}->{items} = \@items;

	route_collections( national => { content => JSON::PP::encode_json($national) } );

	my @before = map { $_->{id} } $S->list('network');
	$S->enrich();
	is( http_count(qr{collection/listen/radio}), 9, 'enrich: 9 collection requests (national + 8 states)' );

	is( $S->get('ITINERANT_ONE')->{name}, 'ABC Cricket World Cup', 'sport: the BFF name wins (itinerant channel renamed, via its dedupe card)' );
	is( $S->get('SPORT_WORLDCUP')->{name}, 'ABC Cricket World Cup', '... and the duplicate\'s own' );
	is( $S->get('TRIPLEJ')->{name}, 'triple j', 'networks keep the catalogue name' );
	is( $S->get('LOCAL_GOLDCOAST')->{name}, 'ABC Gold Coast', 'locals keep the catalogue name (the card says "Gold Coast")' );
	like( $S->get('TRIPLEJ')->{logo}, qr/00000000000000000000000000000001/, 'logo from the card' );
	is( $S->get('TRIPLEJ_PERTH')->{logo}, $S->get('TRIPLEJ')->{logo}, 'variants follow their parent network\'s logo' );
	is( $S->get('RN')->{logo}, $RECORD{RN}->{logo}, 'a card logo without crop params is ignored' );
	is( $S->get('LOCAL_DARWIN')->{logo}, $RECORD{LOCAL_DARWIN}->{logo}, 'the Katherine card does not change Darwin' );

	my @after = map { $_->{id} } $S->list('network');
	is( $after[0], 'TRIPLEJ', 'order follows the cards' );
	is( $after[-1], 'DOUBLEJ', 'an id absent from the cards is kept, appended' );
	is_deeply( [ sort @after ], [ sort @before ], 'same 12 networks' );

	is( scalar( grep { $_->{message} =~ m{newstation} } logged('INFO') ), 1, 'the unknown card is logged once at INFO' );
	is( scalar( grep { $_->{message} =~ m{find-your-local-station} } logged('INFO') ), 1, 'so is the non-station card' );
	ok( !$S->get('NEWSTATION') && !$S->byPageSlug('newstation'), 'unknown ids are ignored' );

	$S->enrich();
	is( http_count(qr{collection/listen/radio}), 9, 'within 24 h: no new requests' );
	is( scalar( grep { $_->{message} =~ m{newstation} } logged('INFO') ), 1, 'still logged once' );

	advanceTime( 86400 + 1 );
	$S->enrich();
	is( http_count(qr{collection/listen/radio}), 18, 'after 24 h: fetched again (at most 9 requests a day)' );

	is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, 'no WARN or ERROR' );
};

subtest 'enrichment: cached collections apply at once; failures leave the catalogue' => sub {
	reset_all();
	route_collections();
	$S->enrich();
	my %logos = map { $_->{id} => $_->{logo} } map { $S->get( $_->{id} ) } @RECORDS;
	is_deeply( \%logos, { map { $_->{id} => $_->{logo} } @RECORDS }, 'the captured collections: same logos as the catalogue' );
	is_deeply( [ map { $_->{id} } $S->list('network') ], [ map { $_->{id} } grep { $_->{group} eq 'network' } @RECORDS ], '... same network order' );
	is_deeply( [ map { $_->{id} } $S->list('sport') ], [qw(GRANDSTAND ITINERANT_THREE ITINERANT_FOUR ITINERANT_ONE ABC_AFL_RAPID ITINERANT_TWO SPORT_BBL SPORT_WBBL SPORT_TENNIS GRANDSTAND_EXTRA SPORT_AFL SPORT_AFL_EXTRA SPORT_CRICKET ABCSPORTSYNC)], '... sport in card order, then the rest in catalogue order; duplicates left out' );

	# a later run (memory empty, API cache warm): enrichment applies synchronously, without a request
	$S->_reset();
	Slim::Networking::SimpleAsyncHTTP->reset;
	route_collections( national => { content => '{}' } );
	my $name = $S->get('ITINERANT_ONE')->{name};
	$S->enrich();
	is( scalar( requests() ), 0, 'cached collections: no request' );
	is( $S->get('ITINERANT_ONE')->{name}, $name, 'applied from the cache' );

	for my $failure ( [ code => 500 ], [ content => 'not json' ], [ content => '{"collection":{"title":"x"}}' ], [ error => 'Connect timed out' ] ) {
		resetStubs();
		$S->_reset();
		route_collections( map { $_ => {@$failure} } 'national', keys %STATE_COLLECTION );
		$S->enrich();
		is_deeply( [ map { $_->{id} } $S->list('network') ], [ map { $_->{id} } grep { $_->{group} eq 'network' } @RECORDS ], "@$failure: catalogue order" );
		is( $S->get('LOCAL_SYDNEY')->{logo}, $RECORD{LOCAL_SYDNEY}->{logo}, "@$failure: catalogue logo" );
		is( scalar( logged('WARN') ) + scalar( logged('ERROR') ), 0, "@$failure: no visible error (no WARN/ERROR)" );
	}

	resetStubs();
	$S->_reset();
	my $qld = json_fixture('bff-collection-state-QLD.json');
	delete $_->{cardImagePrepared} for @{ $qld->{collection}->{items} };
	route_collections( QLD => { content => JSON::PP::encode_json($qld) } );
	$S->enrich();
	is( $S->get('LOCAL_BRISBANE')->{logo}, $RECORD{LOCAL_BRISBANE}->{logo}, 'a card without an image: catalogue logo' );

	resetStubs();
	$S->_reset();
	route_collections( national => { file => 'live/bff-collection-national.json', defer => 1 } );
	$S->enrich();
	ok( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 'a slow collection is in flight' );
	is_deeply( [ map { $_->{id} } $S->list('network') ], [ map { $_->{id} } grep { $_->{group} eq 'network' } @RECORDS ], 'meanwhile: catalogue order (menus never wait)' );
	$S->enrich();
	is( http_count(qr{collectionId=12872264}), 1, 'no second request while one is in flight' );
};

# ---- the live kind (Live.pm) ----

subtest 'live kind: resolve shapes and tokens, exactly one callback' => sub {
	reset_all();
	route( pls('localhobart'), content => "[playlist]\nFile1=" . ice('localhobart') . "\n" );
	route( epg_url('SPORT_BBL'), file => 'live/bff-epgNowPlaying-SPORT_BBL-now.json' );

	my $resolve = \&Plugins::ABCListen::Live::_resolve;

	my $c = collector();
	$resolve->( undef, 'LOCAL_HOBART', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => ice('localhobart'), alternates => ['https://live-radio01.mediahubaustralia.com/7LRW/aac/'], failToken => $LIVE_FAILED } ], 'success: url, alternates, failToken LIVE_FAILED' );
	is( $c->count, 1, 'one callback' );

	route( pls('triplejwa'), content => "[playlist]\nFile1=" . ice('triplejwa') . "\n" );
	$c = collector();
	$resolve->( undef, 'TRIPLEJ_PERTH', $c->cb );
	is_deeply( [ $c->args(0) ], [ { url => ice('triplejwa'), alternates => [], failToken => $LIVE_FAILED } ], 'no alternate: alternates []' );

	for my $case ( [ KIDSLISTEN_NT => $HLS_ONLY ], [ SPORT_BBL => $OFF_AIR ], [ NOPE => $UNAVAILABLE ], [ ITINERANT_FOUR => $HLS_ONLY ] ) {
		my ( $id, $token ) = @$case;
		$c = collector();
		$resolve->( undef, $id, $c->cb );
		is_deeply( [ $c->args(0) ], [ { error => $token } ], "$id -> $token" );
		is( $c->count, 1, "$id: one callback" );
		ok( Slim::Utils::Strings::stringExists($token), "$token is a defined string" );
	}

	reset_all();
	route( pls('localhobart'), content => '', defer => 1 );
	$c = collector();
	$resolve->( undef, 'LOCAL_HOBART', $c->cb );
	is( $c->count, 0, 'asynchronous resolve (.pls loading)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'then one callback' );
	is( ( $c->args(0) )[0]->{url}, ice('localhobart'), 'with the static mount (empty .pls)' );
};

subtest 'live kind: metadata (name, ABC listen, logo, bitrate); never dies' => sub {
	reset_all();
	my $metadata = \&Plugins::ABCListen::Live::_metadata;
	my $hobart   = $RECORD{LOCAL_HOBART};

	my $meta = $metadata->( undef, 'abclisten://live/LOCAL_HOBART', 'LOCAL_HOBART' );
	is_deeply(
		$meta,
		{
			title   => '936 ABC Hobart',
			artist  => 'ABC listen',
			cover   => Plugins::ABCListen::API::imageUrl( $hobart->{logo}, 600 ),
			bitrate => '56kbps CBR',
		},
		'station name, "ABC listen", logo at 600 px, 56kbps CBR'
	);
	like( $meta->{cover}, qr/width=600&height=600/, 'the cover is about 600 px' );
	like( $meta->{cover}, qr/cropH=1631&cropW=1631/, '... keeping the crop params' );
	is( $metadata->( undef, 'abclisten://live/TRIPLEJ_PERTH', 'TRIPLEJ_PERTH' )->{title}, 'triple j Perth', 'a variant: its own title' );

	my $player = MetaClient->new( 'abclisten://live/LOCAL_HOBART', 'https://live-radio01.mediahubaustralia.com/7LRW/aac/' );
	ok( !exists $metadata->( $player, 'abclisten://live/LOCAL_HOBART', 'LOCAL_HOBART' )->{bitrate}, 'playing the mediahub alternate: no (56k) bitrate' );
	$player = MetaClient->new( 'abclisten://live/LOCAL_HOBART', ice('localhobart') );
	is( $metadata->( $player, 'abclisten://live/LOCAL_HOBART', 'LOCAL_HOBART' )->{bitrate}, '56kbps CBR', 'playing Icecast: 56kbps CBR' );
	$player = MetaClient->new( 'abclisten://live/RN', 'https://live-radio01.mediahubaustralia.com/2RNW/aac/' );
	is( $metadata->( $player, 'abclisten://live/LOCAL_HOBART', 'LOCAL_HOBART' )->{bitrate}, '56kbps CBR', 'the player plays another URL: Icecast assumed' );

	is_deeply( $metadata->( undef, 'abclisten://live/NOPE', 'NOPE' ), {}, 'unknown id: {}' );
	is_deeply( $metadata->( undef, undef, undef ), {}, 'undef: {}' );
	is_deeply( $metadata->( undef, 'abclisten://live/X', [] ), {}, 'a ref: {}' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Stations::get = sub { die "boom\n" };
		my $result = eval { $metadata->( undef, 'abclisten://live/RN', 'RN' ) };
		is_deeply( $result, {}, 'Stations->get dies: {} and no exception' );
	}

	is( scalar( requests() ), 0, 'metadata makes no request' );
};

done_testing();

# A player whose playing song is $trackUrl streamed from $streamUrl (Slim::Player::Client/Song subset).
package MetaClient;

sub new {
	my ( $class, $trackUrl, $streamUrl ) = @_;
	return bless { song => MetaSong->new( $trackUrl, $streamUrl ) }, $class;
}

sub playingSong { $_[0]->{song} }

package MetaSong;

sub new { my ( $class, $trackUrl, $streamUrl ) = @_; return bless { track => MetaTrack->new($trackUrl), stream => $streamUrl }, $class }
sub currentTrack { $_[0]->{track} }
sub streamUrl    { $_[0]->{stream} }

package MetaTrack;

sub new { bless { url => $_[1] }, $_[0] }
sub url { $_[0]->{url} }

1;
