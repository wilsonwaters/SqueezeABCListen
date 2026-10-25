#!/usr/bin/perl
# scripts/abc-endpoints-check.sh (the ABC endpoint drift probe) and .github/workflows/abc-drift.yml
# (its weekly run), offline (a fake curl serves recorded answers; nothing reaches ABC):
#   - the probe's copies of the plugin's tables (collection ids, section pages and extras,
#     recommendations, music stations, station collections, the Algolia site filter) match the
#     modules, and its jq mirror of the parsers agrees with Collections/Programs on recorded pages;
#   - against recorded answers all 19 families pass, one line each; every ABC_CHECK_BREAK_FIELD /
#     ABC_CHECK_BREAK_PATH break fails exactly the family it names (the path breaks go to the
#     documented URLs), and a broken search page fails the families that need it;
#   - the Algolia key and app id reach Algolia in headers but are never printed, not even when an
#     error message holds them; in GitHub Actions only the ::add-mask:: lines hold them;
#   - the workflow: weekly cron off the hour plus workflow_dispatch, only GITHUB_TOKEN with
#     contents: read and issues: write, and its probe (one retry) and issue steps run against a
#     fake probe and a fake gh (a new labelled issue, else a comment on the open one; result lines
#     only). Needs bash and jq (CI installs them).

use strict;
use utf8;
use warnings;

use ABCListenTest qw(:all);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::ProgramIndex;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::StationData;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'ERROR', description => 'PLUGIN_ABCLISTEN' } );

for my $tool (qw(bash jq)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

my $SCRIPT = 'scripts/abc-endpoints-check.sh';
my $DIR    = tempdir( CLEANUP => 1 );
my $JSON   = JSON::PP->new->canonical->utf8;

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub spew {
	my ( $file, $content, $mode ) = @_;
	open( my $fh, '>:encoding(UTF-8)', $file ) or die "Can't write $file: $!";
	print {$fh} $content;
	close $fh;
	chmod( $mode, $file ) if $mode;
	return $file;
}

# start a command with %env added (undef deletes) and optionally in another directory; finish
# waits for it and returns (exit code, stdout, stderr); run does both
my $SEQ = 0;
sub start {
	my ( $cmd, %opt ) = @_;
	my $errfile = "$DIR/stderr-" . $SEQ++;
	my $pid     = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>', $errfile ) or die;
		for my $name ( keys %{ $opt{env} || {} } ) {
			defined $opt{env}->{$name} ? ( $ENV{$name} = $opt{env}->{$name} ) : delete $ENV{$name};
		}
		if ( $opt{cwd} ) { chdir $opt{cwd} or die "chdir $opt{cwd}: $!" }
		exec(@$cmd) or die "exec $cmd->[0]: $!";
	}
	binmode( $fh, ':encoding(UTF-8)' );
	return { fh => $fh, errfile => $errfile };
}

sub finish {
	my $run = shift;
	my $out = do { local $/; readline( $run->{fh} ) } // '';
	close $run->{fh};
	my $rc = $? >> 8;
	return ( $rc, $out, slurp( $run->{errfile} ) );
}

sub run { return finish( start(@_) ) }

my @FAMILIES = (
	'search page', '_next/data', 'episodesWithSegments', 'collection', 'epgNowPlaying', 'music', 'schedule',
	'Algolia search', 'pls', 'non-ASCII path', 'legacy 308', 'program aggregations', 'section extras',
	'recommendations', 'music now', 'section pages', 'Algolia program index', 'Algolia chapters', 'station collections',
);

# ---------------------------------------------------------------------------------------------
# The probe's tables are the plugin's
# ---------------------------------------------------------------------------------------------

my $script = slurp($SCRIPT);

# a bash array of the script, e.g. AGGREGATION_IDS=(1 2 3), quotes removed
sub scriptArray {
	my $name = shift;
	my ($body) = $script =~ /^\Q$name\E=\((.*)\)$/m or return;
	return map { s/\A'(.*)'\z/$1/r } $body =~ /('[^']*'|\S+)/g;
}

subtest "the probe's tables are copies of the plugin's" => sub {
	is_deeply( [ scriptArray('AGGREGATION_IDS') ], [ map { @{ $_->{collectionIds} } } Plugins::ABCListen::Programs::networks() ],
		'AGGREGATION_IDS: every collection id of Programs->networks, in order' );

	my $sections = slurp('ABCListen/Sections.pm');
	my ($table) = $sections =~ /^my %SECTIONS = \((.*?)^\);/ms;
	ok( $table, 'Sections.pm has %SECTIONS' );
	my @extras;
	while ( ( $table // '' ) =~ /\{ id => '(\d+)',([^}]*)\}/g ) {
		my ( $id, $rest ) = ( $1, $2 );
		my ($kind) = $rest =~ /kind\s*=>\s*'(\w+)'/;
		push @extras, defined $kind ? "$id:$kind" : $id;
	}
	ok( scalar @extras, 'Sections.pm lists extra collections' );
	is_deeply( [ scriptArray('SECTION_COLLECTIONS') ], \@extras, "SECTION_COLLECTIONS: the sections' extra collections (and their kind)" );

	my @programs = map { /path\s*=>\s*'([^']+)'/g } ( $table // '' ) =~ /programs\s*=>\s*\[(.*?)\]/gs;
	ok( scalar @programs, 'Sections.pm lists extra programs' );
	is_deeply( [ scriptArray('SECTION_PROGRAMS') ], \@programs, "SECTION_PROGRAMS: the sections' extra program pages" );

	my @pages = ( $table // '' ) =~ /^\t\tpath\s*=>\s*'([^']+)'/mg;
	is( scalar @pages, 4, 'Sections.pm: four section pages' );
	my ($home) = slurp('ABCListen/Collections.pm') =~ /^sub home \{.*?page\(\s*'([^']+)'/ms;
	is_deeply( [ map { s/\A[^:]*://r } scriptArray('SECTION_PAGES') ], [ $home, @pages, Plugins::ABCListen::Collections::PODCASTS_PATH() ],
		'SECTION_PAGES: Collections->home, the four sections, Collections PODCASTS_PATH' );

	my @recommendations = slurp('ABCListen/Discover.pm') =~ /_recommendationsItem\(\s*\$client,\s*'\w+',\s*'(\w+)'\s*\)/g;
	ok( scalar @recommendations, 'Discover.pm lists recommendations' );
	is_deeply( [ scriptArray('RECOMMENDATIONS') ], \@recommendations, 'RECOMMENDATIONS: the recommendations Discover lists' );

	my @music = map { $_->{musicStation} }
		grep { $_->{musicStation} && ( $_->{group} // '' ) ne 'variant' && ( $_->{group} // '' ) ne 'hidden' } Plugins::ABCListen::StationData::records();
	is_deeply( [ scriptArray('MUSIC_STATIONS') ], \@music, 'MUSIC_STATIONS: the musicStation of every music network (Tracks)' );

	my ($block) = slurp('ABCListen/Stations.pm') =~ /^my \@COLLECTIONS = \((.*?)^\);/ms;
	my @stations;
	push @stations, "$1:$2" while ( $block // '' ) =~ /\{ id => '(\d+)', root => '(\d+)', national => 1 \}/g;
	my ($root) = ( $block // '' ) =~ /root => '(\d+)', state =>/;
	push @stations, "$2:$root" while ( $block // '' ) =~ /\[ (\w+)\s*=> '(\d+)' \]/g;
	is( scalar @stations, 9, 'Stations.pm: the national and 8 state collections' );
	is_deeply( [ scriptArray('STATION_COLLECTIONS') ], \@stations, 'STATION_COLLECTIONS: Stations @COLLECTIONS (id:root)' );

	my ($filter) = $script =~ /^SITE_FILTER='([^']*)'$/m;
	is( $filter, Plugins::ABCListen::ProgramIndex::siteFilter(), 'SITE_FILTER: ProgramIndex->siteFilter' );

	my ($families) = $script =~ /^FAMILIES=(\d+)$/m;
	is( $families, scalar @FAMILIES, 'FAMILIES: 19' );
	unlike( $script, qr/program\.abcradio\.net\.au\/api/, 'no PAPI request (the plugin makes none at run time)' );
};

# ---------------------------------------------------------------------------------------------
# The probe's jq agrees with the plugin's parsers on recorded pages and collections
# ---------------------------------------------------------------------------------------------

my ($JQ_DEFS) = $script =~ /^JQ_DEFS='\n(.*?)^'$/ms;

sub jq {
	my ( $expr, $file ) = @_;
	my ( $rc, $out, $err ) = run( [ 'jq', '-c', "$JQ_DEFS $expr", $file ] );
	die "jq failed on $file: $err" if $rc;
	chomp $out;
	return $JSON->decode($out);
}

sub fixtureJSON { return $JSON->decode( fixture(shift) ) }

subtest 'jq mirrors Collections::_parsePage, _target and Programs::_programRef' => sub {
	ok( $JQ_DEFS, 'the script has JQ_DEFS' ) or return;

	for my $name (qw(discovery/nextdata-listen-home.trimmed.json discovery/nextdata-section-news.trimmed.json
		discovery/nextdata-section-sport.trimmed.json discovery/nextdata-section-kidslisten.trimmed.json
		discovery/nextdata-section-audiobooks.trimmed.json discovery/nextdata-listen-podcasts.json
		discovery/nextdata-section-kidslisten-programs.trimmed.json))
	{
		my $page = Plugins::ABCListen::Collections::_parsePage( fixtureJSON($name)->{pageProps}, {} );
		my $jq   = jq( 'page_summary', fixturePath($name) );
		is_deeply(
			[ @$jq{qw(collections hero stations)}, $jq->{categories} ? 1 : 0 ],
			[ scalar @{ $page->{collections} }, scalar @{ $page->{hero} }, scalar @{ $page->{stations} || [] }, exists $page->{categoriesId} ? 1 : 0 ],
			"$name: collections, hero, stations, categories"
		);
	}

	for my $name (qw(discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json
		discovery/bff-collection-104141842-kids-families.trimmed.json discovery/bff-collection-106510880-books-for-kids.json
		discovery/bff-recommendations-homepagePopularNow.json discovery/bff-recommendations-homepageSports.json
		foundation/bff-programAggregationCollection-rn.json discovery/bff-collection-14123152-categories.trimmed.json
		discovery/bff-collection-102833294-radio-stations.json))
	{
		my $data  = fixtureJSON($name);
		my $items = $data->{collection} ? $data->{collection}->{items} : $data->{items};
		my @refs  = grep {defined} map { Plugins::ABCListen::API::cardRef($_) } @{ $items || [] };
		my $listed   = grep { Plugins::ABCListen::Collections::_target($_) } @refs;
		my $stations = grep { ( ( Plugins::ABCListen::Collections::_target($_) || {} )->{kind} // '' ) eq 'station' } @refs;
		my $programs = grep {defined} map { Plugins::ABCListen::Programs::_programRef( $_, 'x' ) } @{ $items || [] };
		my $jq = jq( '(.collection.items // .items) as $i | [($i | cards | length), ($i | cards | map(select(card_kind == "station")) | length), ($i | program_cards | length)]', fixturePath($name) );
		if ($stations) {
			# station cards: Stations->byPageSlug decides which pages are stations; the probe doesn't
			# copy its tables and counts every channel / externallink card with a page on the site
			is_deeply( [ $jq->[0] - $jq->[1], $jq->[2] ], [ $listed - $stations, $programs ], "$name: cards listed but stations, program refs ($programs)" );
			ok( $jq->[1] >= $stations, "$name: station cards: the probe counts at least the plugin's ($stations)" );
		}
		else {
			is_deeply( [ $jq->[0], $jq->[2] ], [ $listed, $programs ], "$name: cards listed ($listed), program refs ($programs)" );
		}
	}
};

# ---------------------------------------------------------------------------------------------
# A fake curl with recorded answers
# ---------------------------------------------------------------------------------------------

my $KEY = 'fakeKey0123456789abcdefFEDCBA987';
my $APP = 'FAKEAPP123';
my $BUILD = 'build-test1';

my $bin = "$DIR/bin";
make_path($bin);

# Logs each request ({url, data, headers}) to $FAKE_LOG; answers with the first route of
# $FAKE_ROUTES whose url (and data, if given) regex matches; else a 404 whose error text holds
# the key and app id (the worst a real error could do).
spew( "$bin/curl", <<'CURL', 0755 );
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();

my ( $out, $headersOut, $data, $url, @headers );
while (@ARGV) {
	my $arg = shift @ARGV;
	if    ( $arg eq '-o' )     { $out        = shift @ARGV }
	elsif ( $arg eq '-D' )     { $headersOut = shift @ARGV }
	elsif ( $arg eq '--data' ) { $data       = shift @ARGV }
	elsif ( $arg eq '-H' ) {
		my $header = shift @ARGV;
		if ( $header =~ /\A@(.+)\z/ ) {
			open( my $fh, '<', $1 ) or die "curl: can't read $1";
			push @headers, map { s/\r?\n\z//r } <$fh>;
		}
		else { push @headers, $header }
	}
	elsif ( $arg =~ /\A(?:-w|-A|-X|--max-time|--proxy)\z/ ) { shift @ARGV }
	elsif ( $arg =~ /\A-/ ) { }
	else                    { $url = $arg }
}

my $json = JSON::PP->new->canonical;
open( my $log, '>>', $ENV{FAKE_LOG} ) or die;
print {$log} $json->encode( { url => $url, data => $data, headers => \@headers } ), "\n";
close $log;

my $routes = $json->decode( do { local $/; open( my $fh, '<', $ENV{FAKE_ROUTES} ) or die; <$fh> } );
my ($route) = grep { $url =~ /$_->{url}/ && ( !defined $_->{data} || ( $data // '' ) =~ /$_->{data}/ ) } @$routes;

my ( $status, $body ) = ( 404, '{"message":"not found"}' );
if ($route) {
	$status = $route->{status} // 200;
	$body   = defined $route->{file} ? do { local $/; open( my $fh, '<:raw', $route->{file} ) or die; <$fh> } : $route->{body} // '';
	if ( $headersOut && $route->{headers} ) {
		open( my $fh, '>', $headersOut ) or die;
		print {$fh} "HTTP/2 $status\r\n", ( map {"$_\r\n"} @{ $route->{headers} } ), "\r\n";
	}
}
else {
	print STDERR "curl: (22) error 404 with X-Algolia-API-Key: $ENV{FAKE_KEY} at " . lc( $ENV{FAKE_APP} ) . "-dsn.algolia.net ($ENV{FAKE_APP})\n";
}
open( my $fh, '>:raw', $out ) or die;
print {$fh} $body;
close $fh;
print $status;
CURL

my $SEARCH_PAGE = spew( "$DIR/search.html", '<!DOCTYPE html><html><body><script id="__NEXT_DATA__" type="application/json">'
	. $JSON->encode( { buildId => $BUILD, props => { pageProps => { data => { componentsContent => [
		{ component => 'Search', componentProps => { client => { appId => $APP, apiKey => $KEY }, indexName => 'listen_test_all' } },
	] } } } } )
	. '</script></body></html>' );

my $SITE  = 'https://www\.abc\.net\.au';
my $NEXT  = "$SITE/_next/data/$BUILD";
my $BFF   = "$SITE/core-next/api";
my $ALG   = '^https://FAKEAPP123-dsn\.algolia\.net/1/indexes/listen_test_all/query$';
my $MUSIC = 'https://music\.abcradio\.net\.au/api/v1';

sub body { return $JSON->encode(shift) }

# the program index: 120 program pages (types podcast / catch-up / none), 2 audiobooks
my @index = map { { objectID => "coremedia://program/" . ( 1000 + $_ ), title => "Program $_",
	canonicalURL => "https://www.abc.net.au/listen/programs/program-$_/", programType => [ 'podcast', 'catch-up', undef ]->[ $_ % 3 ] } } 1 .. 120;
unshift @index,
	{ objectID => 'coremedia://program/106353766', title => 'The Dictionary of Lost Words', canonicalURL => 'https://www.abc.net.au/listen/audiobooks/the-dictionary-of-lost-words-page/', programType => 'audiobook' },
	{ objectID => 'coremedia://program/106353780', title => 'The Assassin', canonicalURL => 'https://www.abc.net.au/listen/audiobooks/the-assassin-page/', programType => 'audiobook' };

my $chapter = sub {
	my ( $id, %extra ) = @_;
	return { objectID => "coremedia://audioepisode/$id", programID => 106353766, title => "Chapter $id",
		mediaRenditions => [ { url => "https://mediacore-live-production.akamaized.net/geo-001/audio/$id.mp3", contentType => 'audio/mpeg' } ],
		dates => { publicationDate => '2026-05-07T14:00:00+00:00' }, %extra };
};

my @ROUTES = (
	{ url => "^$SITE/listen/search\$", file => $SEARCH_PAGE },
	{ url => "^$NEXT/listen/programs/scienceshow\\.json\$", file => fixturePath('foundation/nextdata-program-scienceshow.trimmed.json') },
	{ url => "^$NEXT/listen/programs/scienceshow/x/107266790\\.json\$", body => body( { pageProps => { __N_REDIRECT => '/listen/programs/scienceshow/an-episode/107266790' } } ) },
	{ url => "^$NEXT/listen/programs/scienceshow/an-episode/107266790\\.json\$", file => fixturePath('foundation/nextdata-episode-scienceshow-mp3.trimmed.json') },
	{ url => "^$BFF/episodesWithSegments/x\\?collectionId=2885458&", file => fixturePath('foundation/bff-episodesWithSegments-scienceshow.json') },
	{ url => "^$BFF/collection/x\\?collectionId=103194120&", file => fixturePath('foundation/bff-collection-home-most-popular-podcasts.json') },
	{ url => "^$BFF/epgNowPlaying/RN/now\\?imageRatio=1x1\$", file => fixturePath('live/bff-epgNowPlaying-RN-now.json') },
	{ url => "^$BFF/epgNowPlaying/RN/next\\?imageRatio=1x1\$", file => fixturePath('live/bff-epgNowPlaying-RN-next.json') },
	{ url => "^$BFF/musicNowPlaying/TRIPLEJ\$", file => fixturePath('live/bff-musicNowPlaying-TRIPLEJ.json') },
	{ url => "^$MUSIC/plays/search\\.json\\?station=triplej&", file => fixturePath('foundation/music-abcradio-plays-search-triplej.json') },
	{ url => "^$BFF/schedule\\?service=RN&", file => fixturePath('live/bff-schedule-LOCAL_PERTH-2026-10-19.trimmed.json') },
	{ url => $ALG, data => '"query":"science".*"distinct":0|"distinct":0.*"query":"science"', body => body( { nbHits => 1,
		hits => [ { objectID => 'coremedia://program/2885500', title => 'The Science Show', canonicalURL => 'https://www.abc.net.au/listen/programs/scienceshow/' } ] } ) },
	{ url => $ALG, data => '"query":"science"', body => body( { nbHits => 1, hits => [ { objectID => 'coremedia://audioepisode/107266790', title => 'Trees and potatoes' } ] } ) },
	{ url => $ALG, data => '"hitsPerPage":1000,"distinct":0|"distinct":0,"filters":"contentType:program', body => body( { nbHits => scalar @index, hits => \@index } ) },
	# the second audiobook gets the first one's chapters: none of them is its own
	{ url => $ALG, data => 'programID=1063537(?:66|80)"', body => body( { nbHits => 3, hits => [
		$chapter->( 106442600, mediaDownloadStatus => 'EXPIRED', mediaStreamingStatus => 'NONE' ),    # hidden: not the one looked up
		$chapter->( 106442610, mediaDownloadStatus => 'AVAILABLE', mediaStreamingStatus => 'NONE' ), $chapter->(106442620),
	] } ) },
	{ url => $ALG, data => 'objectID:\\\\"coremedia://audioepisode/106442610\\\\"', body => body( { nbHits => 1, hits => [ $chapter->(106442610) ] } ) },
	{ url => '^https://streaming\.abc-cdn\.net\.au/audio/ice/triplejnsw\.pls$', file => fixturePath('foundation/triplejnsw.pls') },
	{ url => "^$NEXT/listen/programs/x/x/107267360\\.json\$", body => body( { pageProps => { __N_REDIRECT => 'https://www.abc.net.au/listen/programs/if-youre-listening/el-ni%C3%B1o/107267360' } } ) },
	{ url => "^$NEXT/listen/programs/if-youre-listening/el-ni%C3%B1o/107267360\\.json\$", status => 307, body => '' },
	{ url => "^$NEXT/listen/programs/if-youre-listening/el-ni%c3%b1o/107267360\\.json\$", body => body( { pageProps => { data => { documentProps => { id => 107267360 } } } } ) },
	{ url => "^$NEXT/radionational/programs/futuretense\\.json\$", status => 308, body => '/listen/programs/futuretense', headers => ['location: https://www.abc.net.au/listen/programs/futuretense'] },
	{ url => "^$BFF/programAggregationCollection/x\\?collectionId=\\d+&offset=0&size=50\$", file => fixturePath('discovery/bff-programAggregationCollection-9317914-kidslisten-programs-size50.json') },
	{ url => "^$BFF/collection/x\\?collectionId=104141842&offset=0&size=20\$", file => fixturePath('discovery/bff-collection-104141842-kids-families.trimmed.json') },
	{ url => "^$BFF/collection/x\\?collectionId=106510880&offset=0&size=20\$", file => fixturePath('discovery/bff-collection-106510880-books-for-kids.json') },
	{ url => "^$NEXT/kidslisten/programs/news-time\\.json\$", file => fixturePath('foundation/nextdata-program-scienceshow.trimmed.json') },
	{ url => "^$BFF/recommendations/listen/homepagePopularNow\$", file => fixturePath('discovery/bff-recommendations-homepagePopularNow.json') },
	{ url => "^$BFF/recommendations/listen/homepageSports\$", file => fixturePath('discovery/bff-recommendations-homepageSports.json') },
	{ url => "^$MUSIC/plays/triplej/now\\.json\$", body => body( { now => { recording => { title => 'AAAHHH!!!' } }, next_updated => '2026-10-25T02:23:48+00:00' } ) },
	{ url => "^$MUSIC/plays/[a-z0-9]+/now\\.json\$", body => body( { now => {}, next_updated => '2026-10-25T02:23:48+00:00' } ) },
	{ url => "^$NEXT/listen\\.json\$", file => fixturePath('discovery/nextdata-listen-home.trimmed.json') },
	{ url => "^$NEXT/listen/news\\.json\$", file => fixturePath('discovery/nextdata-section-news.trimmed.json') },
	{ url => "^$NEXT/listen/sport\\.json\$", file => fixturePath('discovery/nextdata-section-sport.trimmed.json') },
	{ url => "^$NEXT/kidslisten\\.json\$", file => fixturePath('discovery/nextdata-section-kidslisten.trimmed.json') },
	{ url => "^$NEXT/listen/audiobooks\\.json\$", file => fixturePath('discovery/nextdata-section-audiobooks.trimmed.json') },
	{ url => "^$NEXT/listen/podcasts\\.json\$", file => fixturePath('discovery/nextdata-listen-podcasts.json') },
	{ url => "^$BFF/collection/listen/radio\\?collectionId=12872264&metaInMeta=false&rootMetaCollectionId=14139428\$", file => fixturePath('live/bff-collection-national.json') },
	{ url => "^$BFF/collection/listen/radio\\?collectionId=\\d+&metaInMeta=false&rootMetaCollectionId=14123276\$", file => fixturePath('live/bff-collection-state-NSW.json') },
);
my $ROUTES = spew( "$DIR/routes.json", JSON::PP->new->canonical->encode( \@ROUTES ) );

my $RUN = 0;

# start the probe with %env against the fake curl; probeResult waits for it and returns { rc, out,
# err, lines => { family => line }, order => [families], requests => [{url, data, headers}] }
sub startProbe {
	my %env = @_;
	my $log = "$DIR/requests-" . $RUN++;
	my %base = (
		PATH => "$bin:$ENV{PATH}", FAKE_ROUTES => $ROUTES, FAKE_LOG => $log, FAKE_KEY => $KEY, FAKE_APP => $APP,
		GITHUB_ACTIONS => undef, map( { $_ => undef } qw(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy) ),
		map( { $_ => undef } grep {/^ABC_/} keys %ENV ),
	);
	return { run => start( [ 'bash', $SCRIPT ], env => { %base, %env } ), log => $log };
}

sub probeResult {
	my $probe = shift;
	my ( $rc, $out, $err ) = finish( $probe->{run} );
	my ( %lines, @order );
	for my $line ( split /\n/, $out ) {
		next unless $line =~ /\A(?:PASS|FAIL) ([^:]+): /;
		push @order, $1;
		$lines{$1} = $line;
	}
	my @requests = -e $probe->{log} ? map { $JSON->decode($_) } split /\n/, slurp( $probe->{log} ) : ();
	return { rc => $rc, out => $out, err => $err, lines => \%lines, order => \@order, requests => \@requests };
}

sub failed { my $r = shift; return [ grep { $r->{lines}->{$_} =~ /\AFAIL / } @{ $r->{order} } ] }

# the key and app id appear nowhere in the output (but in ::add-mask:: lines)
sub noSecrets {
	my ( $r, $what ) = @_;
	my $text = join "\n", grep { !/\A::add-mask::/ } split( /\n/, $r->{out} ), $r->{err};
	unlike( $text, qr/\Q$KEY\E/,  "$what: the Algolia key is never printed" );
	unlike( $text, qr/\Q$APP\E/i, "$what: nor the app id" );
}

# the deliberate breaks
my %FIELD_BREAKS = (
	'program aggregations'  => 'articleLink',
	'section extras'        => 'contentUri',
	'recommendations'       => 'items',
	'music now'             => 'recording',
	'section pages'         => 'componentsContent',
	'Algolia search'        => 'objectID',
	'Algolia program index' => 'canonicalURL',
	'Algolia chapters'      => 'mediaRenditions',
	'station collections'   => 'articleLink',
);
my @PATH_BREAKS = ( 'program aggregations', 'section extras', 'recommendations', 'music now', 'section pages', 'Algolia search', 'Algolia program index', 'station collections' );

# every probe run at once (each takes a few seconds, mostly jq)
my %PROBES = (
	pass        => {},
	actions     => { GITHUB_ACTIONS => 'true' },
	allFail     => { FAKE_ROUTES => spew( "$DIR/routes-search-only.json", JSON::PP->new->encode( [ $ROUTES[0] ] ) ) },
	field       => { ABC_CHECK_BREAK_FIELD => join( ',', map {"$_:$FIELD_BREAKS{$_}"} sort keys %FIELD_BREAKS ) },
	fieldSearch => { ABC_CHECK_BREAK_FIELD => 'search page:apiKey' },
	path        => { ABC_CHECK_BREAK_PATH => join( ',', @PATH_BREAKS ), ABC_AUDIOBOOK_ID => '106353766' },
	pathSearch  => { ABC_CHECK_BREAK_PATH => 'search page' },
);
my %started = map { $_ => startProbe( %{ $PROBES{$_} } ) } sort keys %PROBES;
my %R       = map { $_ => probeResult( $started{$_} ) } sort keys %started;

subtest 'recorded answers: all 19 families pass, the key travels in headers only' => sub {
	my $r = $R{pass};
	is( $r->{rc}, 0, 'exit 0' ) or diag $r->{out}, $r->{err};
	is_deeply( $r->{order}, \@FAMILIES, 'one line per family, in order' );
	is_deeply( failed($r), [], 'every family passes' ) or diag $r->{out};
	like( $r->{out}, qr/^abc-endpoints-check: all 19 families passed \(\d+ s\)$/m, 'summary' );
	like( $r->{lines}->{'search page'}, qr/buildId build-test1, Algolia index listen_test_all \(app id and key found\)/, 'search page: buildId and index' );
	like( $r->{lines}->{'Algolia chapters'}, qr/programID=106353766: 2 chapters; objectID lookup of coremedia:\/\/audioepisode\/106442610 has renditions/,
		'Algolia chapters: the first audiobook, a hidden (EXPIRED/NONE) chapter not counted, the first listed one looked up' );
	like( $r->{lines}->{'Algolia program index'}, qr/122 programs, 122 at a program page, 82 with a known programType, 2 audiobooks/, 'Algolia program index: counts' );
	like( $r->{lines}->{'music now'}, qr/9 stations, 1 playing a song \(triplej: AAAHHH!!!\)/, 'music now: between songs ({}) is fine' );
	like( $r->{lines}->{'section pages'}, qr/Home \d+, News \d+, Sport \d+, Kids listen \d+, Audiobooks \d+, Podcasts \d+/, 'section pages: all six' );
	noSecrets( $r, 'all pass' );

	my @algolia = grep { $_->{url} =~ /algolia/ } @{ $r->{requests} };
	is( scalar @algolia, 5, 'five Algolia queries: search (programs, episodes), the index, chapters, the lookup' )
		or diag explain [ map { $_->{data} } @algolia ];
	is( scalar( grep { ( grep { $_ eq "X-Algolia-API-Key: $KEY" } @{ $_->{headers} } ) && ( grep { $_ eq "X-Algolia-Application-Id: $APP" } @{ $_->{headers} } ) } @algolia ),
		scalar @algolia, 'each one sends the app id and key headers' );
	ok( !grep( { $_->{url} =~ /\Q$KEY\E/ || ( $_->{data} // '' ) =~ /\Q$KEY\E/ } @{ $r->{requests} } ), 'the key is in no URL or body' );

	my $actions = $R{actions};
	is( $actions->{rc}, 0, 'GitHub Actions: exit 0' );
	my @masks = grep {/\A::add-mask::/} split /\n/, $actions->{out};
	is_deeply( \@masks, [ "::add-mask::$KEY", "::add-mask::$APP", '::add-mask::' . lc $APP ], 'GitHub Actions: the key and app id are registered with ::add-mask:: first' );
	is_deeply( $actions->{lines}, $r->{lines}, 'GitHub Actions: the same result lines' );
	noSecrets( $actions, 'GitHub Actions' );
};

subtest 'every request fails, its error text holding the key: 18 FAILs, still no key' => sub {
	my $r = $R{allFail};
	is( $r->{rc}, 1, 'exit 1' );
	is_deeply( $r->{order}, \@FAMILIES, 'one line per family' );
	is( scalar @{ failed($r) }, 18, 'all but the search page fail' );
	like( $r->{out}, qr/^abc-endpoints-check: 18 of 19 families FAILED \(\d+ s\)$/m, 'summary' );
	like( $r->{lines}->{'Algolia search'}, qr{FAIL Algolia search: programs: HTTP 404 from https://<appId>-dsn\.algolia\.net/1/indexes/listen_test_all/query \(curl: \(22\) error 404 with X-Algolia-API-Key: <apiKey> at <appId>-dsn\.algolia\.net \(<appId>\)},
		'the key and app id in an error are redacted' );
	like( $r->{lines}->{'Algolia chapters'}, qr/no audiobook to ask for/, 'Algolia chapters: no audiobook without the index' );
	noSecrets( $r, 'all fail' );
};

subtest 'ABC_CHECK_BREAK_FIELD fails exactly the families it names' => sub {
	my $r = $R{field};
	is( $r->{rc}, 1, 'exit 1' );
	is_deeply( [ sort @{ failed($r) } ], [ sort keys %FIELD_BREAKS ], 'the nine named families fail, the other ten pass' ) or diag $r->{out};
	like( $r->{lines}->{'music now'}, qr/\.now is neither \{\} nor a song with \.now\.recording\.title/, 'music now: why' );
	like( $r->{lines}->{'section pages'}, qr{FAIL section pages: Home \(/listen\), News \(/listen/news\), Sport \(/listen/sport\), Kids listen \(/kidslisten\), Audiobooks \(/listen/audiobooks\), Podcasts \(/listen/podcasts\): no collection in \.pageProps\.data\.componentsContent$},
		'section pages: why, one entry for the six pages that fail alike' );
	like( $r->{lines}->{'program aggregations'}, qr{FAIL program aggregations: 11 of 11 collections: 11474038, 13910480, 8698186, 9375554, 9104650, 8794720, 12606644, 9317914, 106304964, 9373518, 9412768: no \.collection\.items\[\] card with a coremedia contentUri, a cardTitle and an articleLink on the site$},
		'program aggregations: why, every id' );
	like( $r->{lines}->{'Algolia program index'}, qr/0 hits at a program page/, 'Algolia program index: why' );
	like( $r->{lines}->{'Algolia chapters'}, qr/no listable chapter .* for programID 106353766, 106353780$/, 'Algolia chapters: two audiobooks tried' );
	noSecrets( $r, 'field breaks' );

	my $search = $R{fieldSearch};
	is_deeply( [ sort @{ failed($search) } ], [ sort 'search page', 'Algolia search', 'Algolia program index', 'Algolia chapters' ],
		'search page:apiKey: the search page and the three Algolia families fail' );
	like( $search->{lines}->{'search page'}, qr/no Algolia appId\/apiKey\/indexName in __NEXT_DATA__/, 'search page: why' );
	like( $search->{lines}->{'Algolia search'}, qr/no credentials \(search page failed\)/, 'Algolia search: why' );
};

subtest 'ABC_CHECK_BREAK_PATH sends the named families to paths ABC does not serve' => sub {
	my $r = $R{path};
	is( $r->{rc}, 1, 'exit 1' );
	is_deeply( [ sort @{ failed($r) } ], [ sort @PATH_BREAKS ], 'the named families fail (Algolia chapters, given ABC_AUDIOBOOK_ID, passes)' ) or diag $r->{out};
	like( $r->{lines}->{'music now'}, qr{HTTP 404 from https://music\.abcradio\.net\.au/api/v1/plays/kidslisten/now-drift\.json}, 'music now: HTTP 404 from the drifted path' );
	noSecrets( $r, 'path breaks' );

	my @urls = map { $_->{url} } @{ $r->{requests} };
	my $count = sub { my $re = shift; scalar grep { $_ =~ $re } @urls };
	is( $count->(qr{/core-next/api/programAggregationCollection-drift/x\?collectionId=\d+&offset=0&size=50$}), 11 + 1, 'aggregations (and the section extra 9317914): the BFF endpoint name' );
	is( $count->(qr{/core-next/api/collection-drift/x\?collectionId=(?:104141842|106510880)&}), 2, 'section extras: collection-drift' );
	is( $count->(qr{/_next/data/build-test1/kidslisten/programs/news-time-drift\.json$}), 1, 'section extras: the page name' );
	is( $count->(qr{/core-next/api/recommendations-drift/listen/homepage(?:PopularNow|Sports)$}), 2, 'recommendations' );
	is( $count->(qr{/plays/[a-z0-9]+/now-drift\.json$}), 9, 'music now: the file name' );
	is( $count->(qr{/_next/data/build-test1/(?:listen|listen/news|listen/sport|kidslisten|listen/audiobooks|listen/podcasts)-drift\.json$}), 6, 'section pages: the page name' );
	is( $count->(qr{/core-next/api/collection-drift/listen/radio\?collectionId=\d+&metaInMeta=false&rootMetaCollectionId=\d+$}), 9, 'station collections' );
	is( $count->(qr{algolia\.net/1/indexes/listen_test_all/query-drift$}), 2, 'Algolia search and program index: the last path segment' );
	is( $count->(qr{algolia\.net/1/indexes/listen_test_all/query$}), 2, 'Algolia chapters and its lookup: unchanged' );
	is( $count->(qr{/core-next/api/epgNowPlaying/RN/now\?imageRatio=1x1$}), 1, 'other families: unchanged' );
	is( $count->(qr/-drift/), 12 + 2 + 1 + 2 + 9 + 6 + 9 + 2, 'no other request drifted' );

	my $search = $R{pathSearch};
	like( $search->{lines}->{'search page'}, qr{FAIL search page: HTTP 404 from /listen/search-drift}, 'search page: /listen/search-drift' );
	is( scalar @{ failed($search) }, 1 + 3 + 6, 'and the families that need its buildId or key fail with it' ) or diag $search->{out};
	noSecrets( $search, 'search page path break' );
};

# ---------------------------------------------------------------------------------------------
# The weekly workflow
# ---------------------------------------------------------------------------------------------

my $yml = slurp('.github/workflows/abc-drift.yml');

my %step;
$step{$1} = $2 while $yml =~ /^      - name: ([^\n]+)\n(.*?)(?=^      - |\z)/msg;

sub stepRun {
	my ($block) = ( $step{ $_[0] } // '' ) =~ /^        run: \|\n((?:(?: {10}.*)?\n)*)/m;
	return '' unless defined $block;
	$block =~ s/^ {10}//mg;
	return $block;
}

# a step's plain env values (no ${{ }} expressions)
sub stepEnv {
	my ($block) = ( $step{ $_[0] } // '' ) =~ /^        env:\n((?:          .*\n)*)/m;
	my %env;
	for my $line ( split /\n/, $block // '' ) {
		my ( $name, $value ) = $line =~ /\A {10}(\w+): (.*?)(?:\s+#.*)?\z/ or next;
		$env{$name} = $value unless $value =~ /\$\{\{/;
	}
	return %env;
}

# run a step's script as Actions does (shell: bash = bash --noprofile --norc -eo pipefail) in $dir
sub runStep {
	my ( $name, $dir, %env ) = @_;
	my $file = spew( "$DIR/step-" . $RUN++ . '.sh', stepRun($name) );
	return run( [ 'bash', '--noprofile', '--norc', '-eo', 'pipefail', $file ], cwd => $dir, env => { stepEnv($name), %env } );
}

subtest 'workflow: weekly and on demand, GITHUB_TOKEN only, least permissions' => sub {
	my ($on) = $yml =~ /^on:\n((?:  .*\n|\s*\n)*)/m;
	my @triggers = ( $on // '' ) =~ /^  (\w+):/mg;
	is_deeply( \@triggers, [qw(schedule workflow_dispatch)], 'triggers: schedule and workflow_dispatch only (never pull requests)' );
	my ($cron) = $yml =~ /^    - cron: '([^']+)'/m;
	like( $cron // '', qr/\A(\d+) (\d+) \* \* (\d)\z/, 'one weekly cron (minute hour * * weekday)' );
	my ($minute) = ( $cron // '' ) =~ /\A(\d+) /;
	ok( defined $minute && $minute % 30 != 0, "off the hour and half-hour (minute $minute)" );

	my @blocks;
	push @blocks, "$1permissions:\n$2" while $yml =~ /^( *)permissions:\n((?:\1  \S.*\n)+)/mg;
	is_deeply( \@blocks, [ "permissions:\n  contents: read\n", "    permissions:\n      contents: read\n      issues: write\n" ],
		'workflow: contents: read; the job: contents: read and issues: write, nothing else' );
	unlike( $yml, qr/secrets\./, 'no secrets: only GITHUB_TOKEN' );
	like( $yml, qr/^          GH_TOKEN: \$\{\{ github\.token \}\}$/m, 'gh uses github.token' );
	like( $yml, qr/^        shell: bash\b/m, 'shell: bash (-eo pipefail)' );
	like( $step{"Probe ABC's endpoints"} // '', qr/^        id: probe$/m, 'the probe step has id probe' );
	like( $step{'Open or update the drift issue'} // '', qr/^        if: failure\(\) && steps\.probe\.outcome == 'failure'$/m, 'the issue step runs only when the probe failed' );
	for my $name ( "Probe ABC's endpoints", 'Open or update the drift issue' ) {
		ok( length stepRun($name), "\"$name\" has a run script" );
		unlike( stepRun($name), qr/\$\{\{/, "\"$name\" uses no \${{ }} expressions (they come in through env)" );
	}
};

subtest 'workflow: the probe step tries a failed probe once more' => sub {
	my $dir = tempdir( CLEANUP => 1 );
	make_path("$dir/scripts");
	# a fake probe: fails (exit 1) while runs < $FAIL_RUNS
	spew( "$dir/scripts/abc-endpoints-check.sh", <<'FAKE', 0755 );
#!/usr/bin/env bash
n=$(( $(cat runs 2>/dev/null || echo 0) + 1 ))
echo "$n" >runs
if (( n <= FAIL_RUNS )); then echo "FAIL music now: run $n"; exit 1; fi
echo "PASS music now: run $n"
FAKE
	for my $case ( [ 0, 0, 1, 'passes: one run' ], [ 1, 0, 2, 'fails, then passes: two runs, success' ], [ 2, 1, 2, 'fails twice: two runs, the step fails' ] ) {
		my ( $fails, $rc, $runs, $what ) = @$case;
		unlink "$dir/runs", "$dir/probe.txt";
		my ( $code, $out ) = runStep( "Probe ABC's endpoints", $dir, FAIL_RUNS => $fails, RETRY_AFTER => 0 );
		is( !!$code, !!$rc, "$what (exit)" );
		is( slurp("$dir/runs") + 0, $runs, "$what (runs)" );
		like( slurp("$dir/probe.txt"), qr/\A(?:PASS|FAIL) music now: run $runs\n\z/, "$what: probe.txt is the last run's output" );
		like( $out, qr/::warning::The ABC endpoint probe failed; trying again/, "$what: the retry is announced" ) if $fails;
	}
};

subtest 'workflow: the issue step opens a labelled issue, or comments on the open one; result lines only' => sub {
	my $dir = tempdir( CLEANUP => 1 );
	my $gh  = "$dir/bin";
	make_path($gh);
	# a fake gh: logs its arguments (one call per line) and the body file it was given; `issue
	# list` prints $FAKE_OPEN (the open issue's number, or nothing)
	spew( "$gh/gh", <<'GH', 0755 );
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --body-file ]]; then j=$((i + 1)); cp "${!j}" "$GH_LOG.body"; fi
done
if [[ "$1 $2" == 'issue list' ]]; then printf '%s\n' "$FAKE_OPEN"; fi
GH
	spew( "$dir/probe.txt", "::add-mask::$KEY\n::add-mask::$APP\nPASS search page: buildId b (app id and key found)\nFAIL music now: kidslisten: HTTP 404 from x\n\nabc-endpoints-check: 1 of 19 families FAILED (30 s)\n" );
	my %env = ( PATH => "$gh:$ENV{PATH}", GH_LOG => "$dir/gh.log", RUN_URL => 'https://github.com/o/r/actions/runs/1', GH_TOKEN => 'x', GH_REPO => 'o/r' );

	my ( $rc, $out ) = runStep( 'Open or update the drift issue', $dir, %env, FAKE_OPEN => '' );
	is( $rc, 0, 'no open issue: the step succeeds' ) or diag $out;
	my @calls = split /\n/, slurp("$dir/gh.log");
	like( $calls[0], qr/\Alabel create abc-drift .*--force\z/, 'the abc-drift label is created (or updated)' );
	like( $calls[1], qr/\Aissue list --label abc-drift --state open\b/, 'open abc-drift issues are looked up' );
	is( $calls[2], 'issue create --title ABC endpoint drift --label abc-drift --body-file issue.md', 'a new "ABC endpoint drift" issue with the label' );
	my $body = slurp("$dir/gh.log.body");
	like( $body, qr{failed on \d{4}-\d\d-\d\d \d\d:\d\d UTC: https://github\.com/o/r/actions/runs/1\n}, 'the issue links the run' );
	like( $body, qr/^````\nPASS search page: .*\nFAIL music now: .*\nabc-endpoints-check: 1 of 19 families FAILED \(30 s\)\n````$/m, 'the result lines, fenced' );
	unlike( $body, qr/add-mask|\Q$KEY\E|\Q$APP\E/, 'nothing else from the probe output (no ::add-mask:: lines)' );
	like( $body, qr/close this issue/, 'and what to do' );

	unlink "$dir/gh.log";
	( $rc, $out ) = runStep( 'Open or update the drift issue', $dir, %env, FAKE_OPEN => '42' );
	is( $rc, 0, 'an open issue: the step succeeds' ) or diag $out;
	@calls = split /\n/, slurp("$dir/gh.log");
	is( $calls[-1], 'issue comment 42 --body-file report.md', 'a comment on the open issue, no new issue' );
	is( scalar( grep {/issue create/} @calls ), 0, 'no issue created' );
	unlike( slurp("$dir/gh.log.body"), qr/add-mask|\Q$KEY\E/, 'the comment holds result lines only' );
};

done_testing();
