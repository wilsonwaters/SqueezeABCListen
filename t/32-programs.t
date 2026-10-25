#!/usr/bin/perl
# Plugins::ABCListen::Programs (O2 data layer), offline (SimpleAsyncHTTP stub, fake clock):
# the networks() table; networkPrograms paging, merge, de-duplication, teaser cards, names and
# sortKey order; program() detail on the Science Show, audiobook and synthetic pages; episodes()
# refs, segments, the 250 cap and no request at offset >= 250; the ttl / stale_ok / timeout (8 s)
# options passed to API.pm; { error => TOKEN } on failure; exactly one callback on every path, also
# when the consumer's callback dies.
# F9 (#89): program() and episodes() with { quiet => 1 } (My ABC listen's Latest episodes, which logs
# a program it skips itself): API.pm's quiet (failures and stale serves at DEBUG), the failure carries
# API.pm's message; without the option, or with quiet false, the options, the failure hash and the
# WARN are as before; a request shared with a caller that isn't quiet is still a WARN.
#
# Fixtures in t/data/ondemand/ (raw response bodies as served; research copies from
# ai-state/research/abc-samples/ with the {_fixture_note, data} wrapper stripped and _next/data
# re-wrapped as {"pageProps": ...}, shapes unedited):
#   bff-programAggregationCollection-rn.json          GET /core-next/api/programAggregationCollection/listen/radionational/programs?collectionId=11474038&offset=20&size=20&total=56 (trimmed to 3)
#   nextdata-program-scienceshow.trimmed.json         GET /_next/data/<buildId>/listen/programs/scienceshow.json (lists trimmed to 2; Gigya key replaced)
#   bff-episodesWithSegments-scienceshow.json         GET /core-next/api/episodesWithSegments/listen/programs/scienceshow?collectionId=2885458&offset=240&size=10 (trimmed to 2)
#   nextdata-program-audiobook.trimmed.json           GET /_next/data/build-3afcd04f/listen/audiobooks/the-dictionary-of-lost-words-page.json (selected keys)
# Recorded for O2 (2026-10-19, OQ4 probe):
#   bff-programAggregationCollection-pacific.trimmed.json  GET /core-next/api/programAggregationCollection/x?collectionId=9373518&offset=0&size=50 (45 items, trimmed to 4)
# Synthetic (*.synthetic.json): rn-featured (duplicate, accent, missing fields, unusable cards),
#   program-minimal, program-richtext, program-emptydesc, episodesWithSegments-edge.
# Shared with F3: t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Programs;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

my $P           = 'Plugins::ABCListen::Programs';
my $SITE        = 'https://www.abc.net.au';
my $BFF         = "$SITE/core-next/api";
my $AGG         = "$BFF/programAggregationCollection/x";
my $EPS         = "$BFF/episodesWithSegments/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $T0          = 1_792_400_000;    # 2026-10-19
my $LOAD_FAILED = 'PLUGIN_ABCLISTEN_LOAD_FAILED';
my $WCMS        = 'https://live-production.wcms.abc-cdn.net.au';
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };

# ---- API spy: every bff / nextData call with its options ----

my @API_CALLS;
{
	no warnings 'redefine';
	my $bff      = \&Plugins::ABCListen::API::bff;
	my $nextData = \&Plugins::ABCListen::API::nextData;
	*Plugins::ABCListen::API::bff      = sub { push @API_CALLS, { fn => 'bff',      path => $_[0], query => $_[1], opts => $_[4] }; goto &$bff };
	*Plugins::ABCListen::API::nextData = sub { push @API_CALLS, { fn => 'nextData', path => $_[0], opts => $_[3] }; goto &$nextData };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	@API_CALLS = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub json_fixture { JSON::PP::decode_json( fixture("ondemand/$_[0]") ) }
sub to_json      { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_reply   { { code => 200, content => to_json( $_[0] ), headers => $JSON_TYPE } }

sub urls { map { $_->{url} } grep { $_->{url} !~ m{/listen/search\z} } requests() }

sub agg_url { my ( $id, $offset ) = @_; return "$AGG?collectionId=$id&offset=$offset&size=50" }

sub offset_of { $_[0] =~ /[?&]offset=([0-9]+)/ ? $1 : undef }

# A synthetic program card
sub program_card {
	my $n = shift;
	return { articleLink => "/listen/programs/p$n/", contentUri => "coremedia://program/$n", cardId => "$n", cardTitle => "P$n" };
}

# Route one aggregation collection by offset: $pages->{$offset} = { items => [...], total => N|undef }
sub route_collection {
	my ( $id, $pages ) = @_;
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$AGG\E\?collectionId=$id&}, sub {
		my $page = $pages->{ offset_of( $_[0] ) } or return { code => 200, content => to_json( { collection => { items => [] } } ), headers => $JSON_TYPE };
		my %pagination = ( offset => offset_of( $_[0] ) + 0, size => 50 );
		$pagination{total} = $page->{total} if defined $page->{total};
		return json_reply( { collection => { items => $page->{items}, pagination => \%pagination } } );
	} );
}

# Call a Programs function with a collector callback; returns the collector.
sub call {
	my ( $fn, @args ) = @_;
	my $c = collector();
	$P->can($fn)->( @args, $c->cb );
	return $c;
}

sub result { my $c = shift; my ($r) = $c->args(0); return $r }

sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# The HTTP timeouts of the recorded requests (the F3 search page left out)
sub http_timeouts { map { $_->{params}->{timeout} } grep { $_->{url} !~ m{/listen/search\z} } requests() }

# A consumer's die was caught and logged by the callback guard (not mistaken for a data error)
sub callback_failure_logged {
	return scalar grep { $_->{level} eq 'ERROR' && $_->{message} =~ /\AABC listen programs callback failed: consumer broke/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' );
}

my $GOD_FORBID_IMG = "$WCMS/9b022a1c24f404a4755241bb86365781?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300";

# ---------------------------------------------------------------------------

subtest 'networks(): order, keys, collection ids, site paths' => sub {
	my @networks = $P->networks;

	is_deeply(
		[ map { [ $_->{key}, $_->{name}, $_->{collectionIds}, $_->{sitePath} ] } @networks ],
		[
			[ rn        => 'Radio National',     [qw(11474038 13910480)], '/listen/radionational/programs' ],
			[ triplej   => 'triple j',           [qw(8698186)],           '/triplej/programs' ],
			[ doublej   => 'Double J',           [qw(9375554)],           '/listen/doublej/programs' ],
			[ classic   => 'ABC Classic',        [qw(9104650)],           '/listen/classic/programs' ],
			[ jazz      => 'ABC Jazz',           [qw(8794720)],           '/listen/jazz/programs' ],
			[ country   => 'ABC Country',        [qw(12606644)],          '/listen/country/programs' ],
			[ kids      => 'ABC Kids listen',    [qw(9317914)],           '/kidslisten/programs' ],
			[ unearthed => 'triple j Unearthed', [qw(106304964)],         '/triplejunearthed/programs' ],
			[ pacific   => 'ABC Pacific',        [qw(9373518 9412768)],   '/pacific/programs' ],
		],
		'the 8 networks of the table in order, then the OQ4 addition (ABC Pacific)'
	);

	is_deeply( [ sort keys %{ $networks[0] } ], [qw(collectionIds key name sitePath)], 'exact keys' );

	$networks[0]->{name} = 'changed';
	push @{ $networks[0]->{collectionIds} }, 1;
	is( ( $P->networks )[0]->{name}, 'Radio National', 'networks() returns copies (name)' );
	is_deeply( ( $P->networks )[0]->{collectionIds}, [qw(11474038 13910480)], 'networks() returns copies (ids)' );

	is( $P->network('jazz')->{name}, 'ABC Jazz', 'network($key)' );
	is( $P->network('nope'), undef, 'unknown key: undef' );
	is( $P->network(undef),  undef, 'undef key: undef' );
};

subtest 'networkPrograms(rn): paging, merge with Featured, de-duplication, teaser card, names, order' => sub {
	fresh();
	route( qr{\Q$AGG\E\?collectionId=11474038&}, file => 'ondemand/bff-programAggregationCollection-rn.json', headers => $JSON_TYPE );
	route( qr{\Q$AGG\E\?collectionId=13910480&}, file => 'ondemand/bff-programAggregationCollection-rn-featured.synthetic.json', headers => $JSON_TYPE );

	my $c = call( 'networkPrograms', 'rn' );
	is( $c->count, 1, 'one callback' );

	is_deeply(
		[ urls() ],
		[ agg_url( 11474038, 0 ), agg_url( 11474038, 50 ), agg_url( 13910480, 0 ) ],
		'main list (total 56, size 50): exactly 2 requests (offset 0 and 50, size 50); Featured: 1'
	);
	is_deeply( [ map { $_->{path} } @API_CALLS ], [ ('programAggregationCollection/x') x 3 ], 'through API::bff' );
	is_deeply( $API_CALLS[0]->{opts}, { ttl => 6 * 3600, stale_ok => 1, timeout => 8 }, 'API opts: ttl 6 h, stale_ok, timeout 8 s' );
	is_deeply( [ http_timeouts() ], [ 8, 8, 8 ], 'every aggregation request goes out with an 8 s timeout (not HTTP.pm\'s 15 s)' );

	my $items = result($c)->{items};
	is_deeply(
		[ map { $_->{title} } @$items ],
		[ 'Émigré Stories', 'God Forbid', 'Health Report', 'The History Showcase' ],
		'names (cardRef titles) in sortKey order: accents folded, "The " ignored; duplicates and unusable cards dropped'
	);

	my %by = map { $_->{title} => $_ } @$items;

	is_deeply(
		$by{'God Forbid'},
		{
			title       => 'God Forbid',
			path        => '/listen/programs/godforbid',
			id          => '8132136',
			image       => $GOD_FORBID_IMG,
			description => 'Religion is at the centre of world affairs, but profound questions remain: Why are you here? What happens when you die? Does God matter? God Forbid seeks the answers.',
			presenters  => ['James Carleton'],
			network     => 'Radio National',
		},
		'God Forbid: exact program ref (the main list\'s copy wins over the Featured duplicate)'
	);

	is_deeply( $by{'Health Report'}->{presenters}, [ 'Norman Swan', 'Dr Preeya Alexander' ], 'presenters from presentersPrepared[].names.full' );

	my $teaser = $by{'The History Showcase'};
	ok( !exists $teaser->{id}, 'coremedia://teaser card: no id' );
	is( $teaser->{path}, '/listen/programs/radio-national-showcase', 'coremedia://teaser card: canonical path kept (browsable)' );

	is_deeply(
		$by{'Émigré Stories'},
		{ title => 'Émigré Stories', path => '/listen/programs/emigre-stories', id => '90000001', network => 'Radio National' },
		'missing image, description and presenters: those keys are absent'
	);

	unlike( $_->{path}, qr{/\z|\Ahttps?:}, "$_->{title}: canonical path (no host, no trailing slash)" ) for @$items;
};

subtest 'networkPrograms: absolute card links (recorded ABC Pacific page) normalise to canonical paths' => sub {
	fresh();
	route( qr{\Q$AGG\E\?collectionId=9373518&}, file => 'ondemand/bff-programAggregationCollection-pacific.trimmed.json', headers => $JSON_TYPE );
	route_collection( 9412768, { 0 => { items => [], total => 0 } } );

	my $c     = call( 'networkPrograms', 'pacific' );
	my $items = result($c)->{items};

	is( $c->count, 1, 'one callback' );
	is_deeply( [ urls() ], [ agg_url( 9373518, 0 ), agg_url( 9412768, 0 ) ], 'total 45 with size 50: one request per collection' );
	is_deeply(
		[ map { [ $_->{title}, $_->{path}, exists $_->{id} ? $_->{id} : 'no id' ] } @$items ],
		[
			[ 'God Forbid',       '/listen/programs/godforbid',   '8132136' ],
			[ 'Nesia Daily',      '/pacific/programs/nesia-daily', 'no id' ],
			[ 'Politok',          '/pacific/programs/politok',     '104195702' ],
			[ 'The Science Show', '/listen/programs/scienceshow',  '2885500' ],
		],
		'trimmed titles, canonical paths from absolute links, teaser without id, sorted'
	);
	is( $items->[0]->{network}, 'ABC Pacific', 'network = the network name' );
};

subtest 'networkPrograms paging edge cases' => sub {
	fresh();
	route_collection( 8794720, { 0 => { items => [ map { program_card($_) } 1 .. 50 ] }, 50 => { items => [ map { program_card($_) } 51 .. 60 ] } } );
	my $c = call( 'networkPrograms', 'jazz' );
	is_deeply( [ urls() ], [ agg_url( 8794720, 0 ), agg_url( 8794720, 50 ) ], 'no total: stops after the page shorter than size' );
	is( scalar @{ result($c)->{items} }, 60, 'all 60 programs' );

	fresh();
	route_collection( 8794720, { 0 => { items => [ map { program_card($_) } 1 .. 50 ] }, 50 => { items => [] } } );
	$c = call( 'networkPrograms', 'jazz' );
	is_deeply( [ urls() ], [ agg_url( 8794720, 0 ), agg_url( 8794720, 50 ) ], 'no total, full first page: stops at the empty page' );
	is( scalar @{ result($c)->{items} }, 50, '50 programs' );

	fresh();
	route_collection( 8794720, { 0 => { items => [ map { program_card($_) } 1 .. 50 ], total => 120 }, 50 => { items => [], total => 120 } } );
	$c = call( 'networkPrograms', 'jazz' );
	is_deeply( [ urls() ], [ agg_url( 8794720, 0 ), agg_url( 8794720, 50 ) ], 'a page with 0 items before total: stops (no endless loop)' );
	is( $c->count, 1, 'one callback' );

	fresh();
	route_collection( 8794720, { map { $_ * 50 => { items => [ map { program_card($_) } $_ * 50 + 1 .. $_ * 50 + 50 ], total => 100_000 } } 0 .. 30 } );
	$c = call( 'networkPrograms', 'jazz' );
	is( scalar urls(), 20, 'a runaway total stops after 20 pages' );
	is( scalar @{ result($c)->{items} }, 1000, 'with the programs loaded so far' );

	fresh();
	route( qr{\Q$AGG\E\?collectionId=8794720&offset=50&}, error => 'Timed out waiting for data' );    # first match wins
	route_collection( 8794720, { 0 => { items => [ map { program_card($_) } 1 .. 50 ], total => 56 } } );
	$c = call( 'networkPrograms', 'jazz' );
	is( $c->count, 1, 'a later page fails: one callback' );
	is( scalar @{ result($c)->{items} }, 50, 'a later page fails: the programs already loaded are kept' );
};

subtest 'networkPrograms failures: all collections fail, one fails, empty network, stale copy, unknown key' => sub {
	fresh();
	route( qr{\Q$AGG\E}, code => 500 );
	my $c = call( 'networkPrograms', 'rn' );
	is( $c->count, 1, 'all fail: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'all fail: { error => LOAD_FAILED }' );

	fresh();
	route( qr{\Q$AGG\E\?collectionId=11474038&}, code => 500 );
	route( qr{\Q$AGG\E\?collectionId=13910480&}, file => 'ondemand/bff-programAggregationCollection-rn-featured.synthetic.json', headers => $JSON_TYPE );
	$c = call( 'networkPrograms', 'rn' );
	is_deeply( [ map { $_->{title} } @{ result($c)->{items} } ], [ 'Émigré Stories', 'God Forbid' ], 'main list fails: the Featured programs are listed' );

	fresh();
	route( qr{\Q$AGG\E}, code => 429 );
	$c = call( 'networkPrograms', 'jazz' );
	is_deeply( result($c), { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' }, 'the API token is passed through (429 -> RATE_LIMITED)' );

	fresh();
	route_collection( 8794720, { 0 => { items => [], total => 0 } } );
	$c = call( 'networkPrograms', 'jazz' );
	is( $c->count, 1, 'empty network: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'empty network: LOAD_FAILED' );
	ok( ( grep { $_->{message} =~ /No programs found for the ABC listen network 'ABC Jazz'/ } warnings_logged() ), 'empty network: logged at WARN' );

	fresh();
	route_collection( 8794720, { 0 => { items => [ map { program_card($_) } 1 .. 3 ], total => 3 } } );
	$c = call( 'networkPrograms', 'jazz' );
	is( scalar @{ result($c)->{items} }, 3, 'loaded' );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( qr{\Q$AGG\E}, code => 500 );
	setTime( $T0 + 6 * 3600 + 1 );
	$c = call( 'networkPrograms', 'jazz' );
	is( scalar urls(), 1, 'after 6 h the list is fetched again' );
	is( scalar @{ result($c)->{items} }, 3, 'the fetch fails: the last good list is served (stale_ok)' );

	setTime( $T0 + 6 * 3600 + 2 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	$c = call( 'networkPrograms', 'jazz' );
	is( scalar urls(), 1, 'a stale copy is not fresh: fetched again' );

	fresh();
	$c = call( 'networkPrograms', 'nope' );
	is( $c->count, 1, 'unknown key: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'unknown key: LOAD_FAILED' );
	is( scalar urls(), 0, 'unknown key: no request' );
};

subtest 'networkPrograms: a callback that dies is called once and logged' => sub {
	fresh();
	route_collection( 8794720, { 0 => { items => [ program_card(1) ], total => 1 } } );
	my $calls = 0;
	$P->networkPrograms( 'jazz', sub { $calls++; die "consumer broke\n" } );
	is( $calls, 1, 'called once' );
	ok( ( grep { $_->{level} eq 'ERROR' && $_->{message} =~ /consumer broke/ } Slim::Utils::Log->messages ), 'logged at ERROR' );
};

subtest 'sortKey: lower case, accents folded, leading "The " ignored' => sub {
	is( $P->sortKey('The Science Show'), 'science show', 'The Science Show -> science show (sorts under S)' );
	is( Plugins::ABCListen::Programs::sortKey('THE  drawing   Room'), 'drawing room', 'case and whitespace' );
	is( $P->sortKey('Théâtre Été'), 'theatre ete', 'accents folded' );
	is( $P->sortKey('The'),     'the',     '"The" alone stays' );
	is( $P->sortKey('Theatre'), 'theatre', '"Theatre" is not "The atre"' );
	is( $P->sortKey(undef),     '',        'undef -> empty' );

	my @titles = ( 'The Science Show', 'background briefing', 'Écoute', 'Awaye!', 'The Ark', 'Zed' );
	is_deeply(
		[ sort { $P->sortKey($a) cmp $P->sortKey($b) } @titles ],
		[ 'The Ark', 'Awaye!', 'background briefing', 'Écoute', 'The Science Show', 'Zed' ],
		'sorting by sortKey'
	);
};

subtest 'program(): The Science Show' => sub {
	fresh();
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );

	my $c = call( 'program', '/listen/programs/scienceshow' );
	is( $c->count, 1, 'one callback' );
	my $p = result($c);

	is_deeply(
		[ sort keys %$p ],
		[ sort qw(id title description presenters image network episodeCollectionId total firstEpisodes template restricted) ],
		'exact keys'
	);
	is( $p->{id},    '2885500',          'id from heroImageWithCTAPrepared.uri' );
	is( $p->{title}, 'The Science Show', 'title = heading' );
	like( $p->{description}, qr/\AThe Science Show gives Australians unique insights into the latest scientific research and debate/, 'description: rich text, nbsp as space' );
	like( $p->{description}, qr/\n\nAirs Saturday 12pm/, 'description: paragraphs separated by a blank line' );
	is_deeply( $p->{presenters}, [ 'Robyn Williams', 'Belinda Smith' ], 'presenters from presentersPrepared[].label.full' );
	is( $p->{image},   "$WCMS/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862", 'image = heroImagePrepared.imgSrc' );
	is( $p->{network}, 'ABC Radio National', 'network = attributionLinksPrepared[0].title' );
	is( $p->{episodeCollectionId}, '2885458', 'episodeCollectionId = programCollectionPrepared.id' );
	is( $p->{total},      250,     'total = pagination.total (250 on this page; the cap is tested on a synthetic page)' );
	is( $p->{template},   'audio', 'template = programTemplate' );
	is( $p->{restricted}, 0,       'restricted 0' );

	my $first = $p->{firstEpisodes};
	is( scalar @$first, 2, 'firstEpisodes: the 2 items of the trimmed collection' );
	is( $first->[0]->{id}, '107266790', 'first episode id' );
	is_deeply(
		[ map { [ $_->{id}, $_->{docType}, $_->{label}, $_->{title} ] } @{ $first->[0]->{segments} } ],
		[
			[ '107277426', 'audiosegment', '1 of 5', 'Some success with palm oil. Nickel mines the next challenge' ],
			[ '107277432', 'audiosegment', '2 of 5', 'London street trees threatened by changing climate' ],
		],
		'segments with docType audiosegment (cards have no docType) and labels'
	);
	is_deeply( $first->[1]->{segments}, [], 'segments: null -> []' );
	is( $first->[1]->{path}, '/listen/programs/lab-notes/lab-notes-when-astronomers-make-mistakes/107232984', 'another program\'s episode keeps its own path' );

	is_deeply( $API_CALLS[0], { fn => 'nextData', path => '/listen/programs/scienceshow', opts => { ttl => 6 * 3600, stale_ok => 1, timeout => 8 } }, 'API::nextData with ttl 6 h, stale_ok and timeout 8 s' );
	is_deeply( [ http_timeouts() ], [8], 'the program page request goes out with an 8 s timeout' );

	@API_CALLS = ();
	my $requests = scalar requests();
	for my $variant ( '/listen/programs/scienceshow/', 'https://www.abc.net.au/listen/programs/scienceshow', 'https://abc.net.au/listen/programs/scienceshow/?ref=x' ) {
		$c = call( 'program', $variant );
		is( result($c)->{id}, '2885500', "path variant '$variant' -> the same program" );
	}
	is( scalar requests(), $requests, 'path variants share the cached page (one canonical path)' );
};

subtest 'program(): old-style path followed through __N_REDIRECT (inside F3)' => sub {
	fresh();
	route( "$NEXT/radionational/programs/scienceshow.json", content => to_json( { pageProps => { __N_REDIRECT => '/listen/programs/scienceshow', __N_REDIRECT_STATUS => 308 } } ), headers => $JSON_TYPE );
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );

	my $c = call( 'program', '/radionational/programs/scienceshow' );
	is( $c->count, 1, 'one callback' );
	is( result($c)->{title}, 'The Science Show', 'redirect followed' );
	is( scalar grep( { $_->{fn} eq 'nextData' } @API_CALLS ), 1, 'one nextData call (no retry in O2)' );
};

subtest 'program(): audiobook (no episode collection on the web)' => sub {
	fresh();
	route( "$NEXT/listen/audiobooks/the-dictionary-of-lost-words-page.json", file => 'ondemand/nextdata-program-audiobook.trimmed.json', headers => $JSON_TYPE );

	my $p = result( call( 'program', '/listen/audiobooks/the-dictionary-of-lost-words-page' ) );
	is( $p->{template},   'audiobook', 'template audiobook' );
	is( $p->{restricted}, 1,           'restricted 1' );
	is( $p->{episodeCollectionId}, undef, 'no episodeCollectionId' );
	is( $p->{total},      0,           'total 0' );
	is_deeply( $p->{firstEpisodes}, [], 'no firstEpisodes' );
	is( $p->{id},      '106353766',                    'id' );
	is( $p->{title},   'The Dictionary of Lost Words', 'title' );
	is( $p->{network}, undef,                          'no attribution link: network undef' );
	is_deeply( $p->{presenters}, ['Pip Williams'], 'presenters' );
};

subtest 'program(): synthetic pages (missing fields, rich text edge cases, empty descriptor)' => sub {
	fresh();
	route( "$NEXT/listen/programs/minimal.json",        file => 'ondemand/nextdata-program-minimal.synthetic.json',   headers => $JSON_TYPE );
	route( "$NEXT/listen/programs/fish-and-facts.json", file => 'ondemand/nextdata-program-richtext.synthetic.json',  headers => $JSON_TYPE );
	route( "$NEXT/listen/programs/quiet.json",          file => 'ondemand/nextdata-program-emptydesc.synthetic.json', headers => $JSON_TYPE );
	route( "$NEXT/listen/programs/bare.json",           content => to_json( { pageProps => {} } ), headers => $JSON_TYPE );

	is_deeply(
		result( call( 'program', '/listen/programs/minimal' ) ),
		{
			id => '90000002', title => 'Minimal Program', description => undef, presenters => [], image => undef, network => undef,
			episodeCollectionId => undef, total => 0, firstEpisodes => [], template => 'default', restricted => 0,
		},
		'minimal page: no description, presenters, network, image or episode collection'
	);

	my $p = result( call( 'program', '/listen/programs/fish-and-facts' ) );
	is( $p->{description}, "Fish & chips on Fridays.\n\nTwo nested nodes \x{2013} done.", 'rich text: paragraphs, nested nodes, entities, nbsp, empty paragraph dropped' );
	is( $p->{title},   'Fish & Facts',        'entities decoded in the title' );
	is( $p->{network}, 'ABC Classic & Jazz',  'the first attribution link only, decoded' );
	is_deeply( $p->{presenters}, [ "Dr Jo O\x{2019}Neil", 'Sam Lee' ], 'presenters decoded, empty names dropped, spaces collapsed' );
	is( $p->{total}, 1, 'no pagination: total = the items listed' );
	is( $p->{episodeCollectionId}, '90000007', 'collection id' );
	is( $p->{firstEpisodes}->[0]->{title}, 'First fish', 'first episodes mapped' );

	$p = result( call( 'program', '/listen/programs/quiet' ) );
	is( $p->{description}, undef, 'empty descriptor -> no description' );
	is( $p->{id},          undef, 'a teaser uri is not a program id' );
	is( $p->{total},       0,     'pagination.total 0' );
	is( $p->{episodeCollectionId}, '90000010', 'collection id kept' );

	$p = result( call( 'program', '/listen/programs/bare' ) );
	is( $p->{title}, undef, 'empty pageProps: no title' );
	is( $p->{restricted}, 0, 'empty pageProps: restricted 0' );

	# The Science Show page with more episodes than ABC lists
	for my $total ( 251, 1529 ) {
		my $page = json_fixture('nextdata-program-scienceshow.trimmed.json');
		$page->{pageProps}->{programCollectionPrepared}->{pagination}->{total} = $total;
		route( "$NEXT/listen/programs/long-running-$total.json", content => to_json($page), headers => $JSON_TYPE );

		$p = result( call( 'program', "/listen/programs/long-running-$total" ) );
		is( $p->{total}, 250, "pagination.total $total -> total capped at 250" );
	}
};

subtest 'program(): failures' => sub {
	fresh();
	route( "$NEXT/listen/programs/broken.json", error => 'Timed out waiting for data' );
	my $c = call( 'program', '/listen/programs/broken' );
	is( $c->count, 1, 'transport error: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'transport error: LOAD_FAILED' );

	$c = call( 'program', 'https://example.com/listen/programs/x' );
	is( $c->count, 1, 'not an ABC page: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'not an ABC page: LOAD_FAILED' );

	$c = call( 'program', undef );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'undef path: LOAD_FAILED' );

	fresh();
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	call( 'program', '/listen/programs/scienceshow' );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html' );
	route( qr{/_next/data/}, error => 'Timed out waiting for data' );
	setTime( $T0 + 6 * 3600 + 1 );
	$c = call( 'program', '/listen/programs/scienceshow' );
	is( result($c)->{title}, 'The Science Show', 'after 6 h a failing fetch serves the last good page (stale_ok)' );
};

subtest 'episodes(): The Science Show page at offset 240' => sub {
	fresh();
	route( qr{\Q$EPS\E\?}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );

	my $c = call( 'episodes', '2885458', 240, 10 );
	is( $c->count, 1, 'one callback' );
	is_deeply( [ urls() ], ["$EPS?collectionId=2885458&offset=240&size=10"], 'one request: collectionId, offset, size' );
	is_deeply( $API_CALLS[0]->{opts}, { ttl => 900, timeout => 8 }, 'API opts: ttl 15 min, timeout 8 s' );
	is_deeply( [ http_timeouts() ], [8], 'the episode page request goes out with an 8 s timeout' );

	my $r = result($c);
	is( $r->{total},  250, 'total' );
	is( $r->{offset}, 240, 'offset' );
	is_deeply( [ map { $_->{id} } @{ $r->{items} } ], [qw(103022914 103190018)], 'ids' );

	is_deeply(
		$r->{items}->[0],
		{
			id          => '103022914',
			docType     => 'audioepisode',
			title       => "H. G. Wells \x{2013} father of science fiction",
			description => 'He imagined the atomic bomb, believed in a world government, wrote books about science and science fiction and was the first popular communicator of scientific ideas. Today we commemorate the life and achievements of Herbert George Wells.',
			path        => '/listen/programs/scienceshow/the-science-show/103022914',
			date        => timegm( 0, 0, 1, 20, 0, 2024 ),
			duration    => 3247,
			image       => "$WCMS/23b56445f570798642596347fe3a35f9?impolicy=wcms_crop_resize&cropH=1362&cropW=1362&xPos=134&yPos=0&width=300&height=300",
			presenters  => ['Robyn Williams'],
			segments    => [],
		},
		'exact episode ref (contract-3 keys + presenters, segments)'
	);
	is( $r->{items}->[1]->{duration}, 1230, 'second: duration' );
	is( $r->{items}->[1]->{date}, timegm( 0, 0, 20, 13, 0, 2024 ), 'second: epoch date' );
	is_deeply( $r->{items}->[1]->{presenters}, ['Jonathan Webb'], 'second: presenters' );
};

subtest 'episodes(): edge cards, the 250 cap and page bounds' => sub {
	fresh();
	route( qr{\Q$EPS\E\?collectionId=90000020&}, file => 'ondemand/bff-episodesWithSegments-edge.synthetic.json', headers => $JSON_TYPE );

	my $r = result( call( 'episodes', '90000020', 0, 50 ) );
	is( $r->{total}, 250, 'pagination.total 1529 -> capped at 250' );
	is_deeply( [ map { $_->{id} } @{ $r->{items} } ], [qw(90000021 90000025 90000026 90000027)], 'unparseable contentUri, non-audio and non-hash cards skipped' );

	my %by = map { $_->{id} => $_ } @{ $r->{items} };
	is( $by{90000021}->{title}, "Q&A \x{2013} the edge cases", 'title entities decoded' );
	is( $by{90000021}->{description}, "Questions & answers about \x{2018}everything\x{2019}.", 'description entities and nbsp decoded' );
	is( $by{90000021}->{path}, '/listen/programs/edgecases/q-and-a/90000021', 'canonical path' );
	is_deeply( $by{90000021}->{presenters}, ['Ann Example'], 'empty presenter names dropped' );

	my @segments = @{ $by{90000021}->{segments} };
	is( scalar @segments, 2, 'two audio segments (the article card is skipped)' );
	is_deeply( [ sort keys %{ $segments[0] } ], [ sort qw(id docType title description path date duration image presenters segments label) ], 'segment ref: episode keys plus label' );
	is_deeply( [ map { [ $_->{id}, $_->{docType}, $_->{label}, $_->{duration} ] } @segments ], [ [ '90000022', 'audiosegment', '1 of 2', 600 ], [ '90000023', 'audiosegment', undef, undef ] ], 'segments: docType from contentUri, label, duration' );
	is_deeply( $segments[0]->{segments}, [], 'segments have no segments' );

	is( $by{90000025}->{date},     undef, 'no date: undef' );
	is( $by{90000026}->{duration}, undef, 'no duration: undef' );
	is( $by{90000027}->{docType},  'audio', 'docType null on a coremedia://audio card -> audio' );
	is_deeply( $by{90000027}->{segments}, [], 'segments absent -> []' );
	is( $by{90000027}->{image}, undef, 'no image: undef' );

	fresh();
	my $c = call( 'episodes', '90000020', 250, 50 );
	is( $c->count, 1, 'offset 250: one callback' );
	is_deeply( result($c), { items => [], total => 250, offset => 250 }, 'offset 250: no items' );
	is( scalar urls(), 0, 'offset 250: no request' );
	call( 'episodes', '90000020', 400, 50 );
	is( scalar urls(), 0, 'offset 400: no request' );

	route( qr{\Q$EPS\E\?}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );
	call( 'episodes', '2885458', 240, 50 );
	is_deeply( [ urls() ], ["$EPS?collectionId=2885458&offset=240&size=10"], 'a page never passes 250 (size trimmed to 10)' );

	fresh();
	route( qr{\Q$EPS\E\?}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );
	call( 'episodes', '2885458', undef, undef );
	is_deeply( [ urls() ], ["$EPS?collectionId=2885458&offset=0&size=50"], 'defaults: offset 0, size 50' );
};

subtest 'episodes(): empty, errors, bad collection id' => sub {
	fresh();
	route( qr{\Q$EPS\E\?}, content => to_json( { collection => { id => '1', items => [], pagination => { offset => 0, size => 50, total => 0 } } } ), headers => $JSON_TYPE );
	my $c = call( 'episodes', '1', 0, 50 );
	is( $c->count, 1, 'empty: one callback' );
	is_deeply( result($c), { items => [], total => 0, offset => 0 }, 'pagination.total 0: no items, total 0' );

	fresh();
	route( qr{\Q$EPS\E\?}, content => to_json( { collection => { items => [ json_fixture('bff-episodesWithSegments-scienceshow.json')->{collection}->{items}->[0] ] } } ), headers => $JSON_TYPE );
	is( result( call( 'episodes', '1', 100, 50 ) )->{total}, 101, 'no pagination: total = offset + items' );

	fresh();
	route( qr{\Q$EPS\E\?}, code => 500 );
	$c = call( 'episodes', '2885458', 0, 50 );
	is( $c->count, 1, 'HTTP 500: one callback' );
	is_deeply( result($c), { error => $LOAD_FAILED }, 'HTTP 500: LOAD_FAILED' );

	fresh();
	route( qr{\Q$EPS\E\?}, code => 429 );
	is_deeply( result( call( 'episodes', '2885458', 0, 50 ) ), { error => 'PLUGIN_ABCLISTEN_RATE_LIMITED' }, '429: RATE_LIMITED passed through' );

	fresh();
	route( qr{\Q$EPS\E\?}, content => '{"collection": [', headers => $JSON_TYPE );
	is_deeply( result( call( 'episodes', '2885458', 0, 50 ) ), { error => $LOAD_FAILED }, 'invalid JSON: LOAD_FAILED' );

	fresh();
	for my $bad ( undef, 'abc', '12x', '' ) {
		$c = call( 'episodes', $bad, 0, 50 );
		is( $c->count, 1, 'bad collection id ' . ( defined $bad ? "'$bad'" : 'undef' ) . ': one callback' );
		is_deeply( result($c), { error => $LOAD_FAILED }, 'bad collection id: LOAD_FAILED' );
	}
	is( scalar urls(), 0, 'bad collection ids: no request' );
};

subtest 'program() and episodes(): a consumer callback that dies is called once, logged, and never escapes' => sub {
	my $calls;
	my $dying = sub { $calls++; die "consumer broke\n" };

	my $run = sub {
		my ( $label, $fn, @args ) = @_;
		$calls = 0;
		ok( eval { $P->can($fn)->( @args, $dying ); 1 }, "$label: the die does not reach the caller" ) or diag $@;
		is( $calls, 1, "$label: called once" );
		ok( callback_failure_logged(), "$label: logged at ERROR as a callback failure" );
	};

	fresh();
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	$run->( 'program(), loaded', 'program', '/listen/programs/scienceshow' );
	$run->( 'program(), from the cache (synchronous)', 'program', '/listen/programs/scienceshow' );

	fresh();
	route( "$NEXT/listen/programs/broken.json", error => 'Timed out waiting for data' );
	$run->( 'program(), transport error', 'program', '/listen/programs/broken' );

	fresh();
	$run->( 'program(), not an ABC page (synchronous error)', 'program', 'https://example.com/listen/programs/x' );

	fresh();
	route( qr{\Q$EPS\E\?}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );
	$run->( 'episodes(), loaded', 'episodes', '2885458', 240, 10 );

	fresh();
	route( qr{\Q$EPS\E\?}, code => 500 );
	$run->( 'episodes(), HTTP 500', 'episodes', '2885458', 0, 50 );

	fresh();
	$run->( 'episodes(), offset 250 (no request, synchronous)', 'episodes', '2885458', 250, 50 );
	$run->( 'episodes(), bad collection id (synchronous)', 'episodes', 'abc', 0, 50 );
};

# ---------------------------------------------------------------------------
# F9 (#89): the quiet option
# ---------------------------------------------------------------------------

# Call a Programs function with a collector callback and \%opts after it; returns the collector.
sub call_opts {
	my ( $fn, $opts, @args ) = @_;
	my $c = collector();
	$P->can($fn)->( @args, $c->cb, $opts );
	return $c;
}

# How many plugin.abclisten lines at $level match $re.
sub logged_like {
	my ( $level, $re ) = @_;
	return scalar grep { $_->{message} =~ $re } Slim::Utils::Log->messages( category => 'plugin.abclisten', level => $level );
}

my $REMOVED     = '/listen/programs/removed';
my $REMOVED_404 = qr{\AHTTP request failed: 404 Not Found \(\Q$NEXT$REMOVED.json\E\)};
my $PAGE_FAILED = qr{\AnextData \Q$REMOVED\E: HTTP request failed: 404 };
my $EPS_URL     = "$EPS?collectionId=404&offset=0&size=5";
my $EPS_404     = qr{\AHTTP request failed: 404 Not Found \(\Q$EPS_URL\E\)};
my $EPS_FAILED  = qr{\AGET \Q$EPS_URL\E: HTTP request failed: 404 };

subtest 'F9: program() with quiet => 1: API.pm\'s quiet, the failure carries API.pm\'s message; without it, as before' => sub {
	fresh();
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';    # record DEBUG lines too
	route( "$NEXT$REMOVED.json", code => 404, content => '{}' );

	my $c = call_opts( 'program', { quiet => 1 }, $REMOVED );
	is( $c->count, 1, 'quiet: one callback' );
	my $r = result($c);
	is_deeply( [ sort keys %$r ], [qw(error message)], 'quiet: { error, message }' );
	is( $r->{error}, $LOAD_FAILED, '... error: the token, as before' );
	like( $r->{message}, $REMOVED_404, '... message: API.pm\'s detail (the 404 and the URL)' );
	is_deeply( $API_CALLS[-1]->{opts}, { ttl => 6 * 3600, stale_ok => 1, timeout => 8, quiet => 1 }, '... API::nextData with quiet => 1 added to the usual options' );
	is( logged_like( WARN => $PAGE_FAILED ), 0, '... no WARN from API.pm (the caller logs it)' );
	is( logged_like( DEBUG => $PAGE_FAILED ), 1, '... API.pm logged it at DEBUG' );

	for my $case ( [ 'no options', undef ], [ 'quiet => 0', { quiet => 0 } ], [ 'other options only', {} ] ) {
		my ( $name, $opts ) = @$case;
		Slim::Utils::Log->resetMessages;
		$c = defined $opts ? call_opts( 'program', $opts, $REMOVED ) : call( 'program', $REMOVED );
		is( $c->count, 1, "$name: one callback" );
		is_deeply( result($c), { error => $LOAD_FAILED }, "$name: { error => LOAD_FAILED } only, as before" );
		is_deeply( $API_CALLS[-1]->{opts}, { ttl => 6 * 3600, stale_ok => 1, timeout => 8 }, "$name: the options as before (no quiet)" );
		is( logged_like( WARN => $PAGE_FAILED ), 1, "$name: API.pm's WARN, as before" );
	}
	is( scalar( grep {m{/removed\.json\z}} urls() ), 4, 'every call asked ABC (a failure is not cached)' );
};

subtest 'F9: episodes() with quiet => 1: API.pm\'s quiet, the failure carries API.pm\'s message; without it, as before' => sub {
	fresh();
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';
	route( $EPS_URL, code => 404, content => '{}' );

	my $c = call_opts( 'episodes', { quiet => 1 }, '404', 0, 5 );
	is( $c->count, 1, 'quiet: one callback' );
	my $r = result($c);
	is_deeply( [ sort keys %$r ], [qw(error message)], 'quiet: { error, message }' );
	is( $r->{error}, $LOAD_FAILED, '... error: the token, as before' );
	like( $r->{message}, $EPS_404, '... message: API.pm\'s detail (the 404 and the URL)' );
	is_deeply( $API_CALLS[-1]->{opts}, { ttl => 900, timeout => 8, quiet => 1 }, '... API::bff with quiet => 1 added to the usual options' );
	is( logged_like( WARN => $EPS_FAILED ), 0, '... no WARN from API.pm (the caller logs it)' );
	is( logged_like( DEBUG => $EPS_FAILED ), 1, '... API.pm logged it at DEBUG' );

	for my $case ( [ 'no options', undef ], [ 'quiet => 0', { quiet => 0 } ] ) {
		my ( $name, $opts ) = @$case;
		Slim::Utils::Log->resetMessages;
		$c = defined $opts ? call_opts( 'episodes', $opts, '404', 0, 5 ) : call( 'episodes', '404', 0, 5 );
		is_deeply( result($c), { error => $LOAD_FAILED }, "$name: { error => LOAD_FAILED } only, as before" );
		is_deeply( $API_CALLS[-1]->{opts}, { ttl => 900, timeout => 8 }, "$name: the options as before (no quiet)" );
		is( logged_like( WARN => $EPS_FAILED ), 1, "$name: API.pm's WARN, as before" );
	}

	# a success is the same either way
	fresh();
	route( qr{\Q$EPS\E\?}, file => 'ondemand/bff-episodesWithSegments-scienceshow.json', headers => $JSON_TYPE );
	my $loud = result( call( 'episodes', '2885458', 240, 10 ) );
	is_deeply( result( call_opts( 'episodes', { quiet => 1 }, '2885458', 240, 10 ) ), $loud, 'a success: the same answer with quiet' );
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	$loud = result( call( 'program', '/listen/programs/scienceshow' ) );
	is_deeply( result( call_opts( 'program', { quiet => 1 }, '/listen/programs/scienceshow' ) ), $loud, '... and for program()' );
};

subtest 'F9: a 404 shared by a quiet and a loud caller is still a WARN; each gets its own failure' => sub {
	fresh();
	route( "$NEXT$REMOVED.json", code => 404, content => '{}', defer => 1 );

	my $quiet = call_opts( 'program', { quiet => 1 }, $REMOVED );
	my $loud  = call( 'program', $REMOVED );
	is( $quiet->count + $loud->count, 0, 'both wait for the one request in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;

	is( scalar( grep {m{/removed\.json\z}} urls() ), 1, 'one request for both' );
	like( result($quiet)->{message}, $REMOVED_404, 'the quiet caller: { error, message }' );
	is_deeply( result($loud), { error => $LOAD_FAILED }, 'the loud caller: { error } only' );
	is( logged_like( WARN => $PAGE_FAILED ), 1, 'API.pm\'s WARN, for the caller that isn\'t quiet' );
};

subtest 'F9: quiet program(): a stale serve is logged at DEBUG (the last good page is the answer); a loud caller\'s at WARN' => sub {
	fresh();
	local $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}->{defaultLevel} = 'DEBUG';
	route( "$NEXT/listen/programs/scienceshow.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
	call( 'program', '/listen/programs/scienceshow' );

	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html' );
	route( qr{/_next/data/}, code => 404, content => '{}' );
	setTime( $T0 + 6 * 3600 + 1 );
	Slim::Utils::Log->resetMessages;

	my $stale = qr{\AnextData /listen/programs/scienceshow: serving the last good copy};
	is( result( call_opts( 'program', { quiet => 1 }, '/listen/programs/scienceshow' ) )->{title}, 'The Science Show', 'quiet: the last good page' );
	is_deeply( [ logged_like( WARN => $stale ), logged_like( DEBUG => $stale ) ], [ 0, 1 ], '... its stale serve logged at DEBUG' );
	is( result( call( 'program', '/listen/programs/scienceshow' ) )->{title}, 'The Science Show', 'loud: the last good page' );
	is( logged_like( WARN => $stale ), 1, '... its stale serve logged at WARN, as before' );
};

done_testing();
