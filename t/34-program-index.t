#!/usr/bin/perl
# O3, offline (SimpleAsyncHTTP stub, fake clock): Plugins::ABCListen::ProgramIndex (the Algolia
# program index: request, mapping to program refs, de-duplication, skipped hits, the nbHits cap
# WARN, the 24 h cache and last-good copy, the network-list fallback with at most 4 lists in
# flight, typeKey) and the OnDemand menus built on it (_programsRoot order; All programs A–Z
# letters, counts and buckets; By type; program rows via programItem with the duplicate-title
# name override; the public programsByType for D2/D4; fallback and LOAD_FAILED states; exactly one
# callback on every path, also when the consumer's callback dies).
#
# Fixtures in t/data/ondemand/:
#   algolia-programs-list.json   raw response body of ai-state/research/abc-samples/algolia-programs-list.json
#                                (POST .../indexes/listen_prod_all/query, the O3 filter, hitsPerPage 1000:
#                                724 programs on 2026-10-19, trimmed to 3; {_fixture_note, data} wrapper
#                                stripped; shape unedited; no credentials)
#   bff-programAggregationCollection-rn.json, -rn-featured.synthetic.json, -pacific.trimmed.json
#                                O2's network fixtures (see t/32-programs.t), for the fallback path.
# Synthetic hit lists are built below (hit()). The search page (Algolia app id TESTAPPID, key
# testsearchkey, index listen_prod_all) is F3's t/data/foundation/listen-search.trimmed.html.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::ProgramIndex;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' } );

my $PI        = 'Plugins::ABCListen::ProgramIndex';
my $OD        = 'Plugins::ABCListen::OnDemand';
my $SITE      = 'https://www.abc.net.au';
my $AGG       = "$SITE/core-next/api/programAggregationCollection/x";
my $ALGOLIA   = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $T0        = 1_792_400_000;    # Mon 19 Oct 2026
my $ICON      = Plugins::ABCListen::Util::ICON;
my $WCMS      = 'https://live-production.wcms.abc-cdn.net.au';
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $ENDASH    = "\x{2013}";

my $LOAD_FAILED    = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $INDEX_FALLBACK = string('PLUGIN_ABCLISTEN_INDEX_FALLBACK');
my $NO_PROGRAMS    = string('PLUGIN_ABCLISTEN_NO_PROGRAMS');

my $PROGRAM_MENU = \&Plugins::ABCListen::OnDemand::_programMenu;
my $ROOT         = \&Plugins::ABCListen::OnDemand::_programsRoot;
my $AZ           = \&Plugins::ABCListen::OnDemand::_azFeed;
my $LETTER       = \&Plugins::ABCListen::OnDemand::_letterFeed;
my $TYPES        = \&Plugins::ABCListen::OnDemand::_typesFeed;
my $TYPE         = \&Plugins::ABCListen::OnDemand::_typeFeed;

my $FILTERS = 'contentType:program AND (siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)';
my @ATTRIBUTES = qw(objectID title canonicalURL shortTeaserText description defaultThumbnail infoSource programType);

# ---- API spy: every algolia call with its params and options ----

my @ALGOLIA;
{
	no warnings 'redefine';
	my $algolia = \&Plugins::ABCListen::API::algolia;
	*Plugins::ABCListen::API::algolia = sub { push @ALGOLIA, { params => $_[0], opts => $_[3] }; goto &$algolia };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::ProgramIndex::_reset();
	@ALGOLIA = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

sub algolia_requests { grep { $_->{url} eq $ALGOLIA } requests() }
sub agg_requests     { grep { index( $_->{url}, $AGG ) == 0 } requests() }

sub thumb { "$WCMS/img$_[0]?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=862&height=862" }

# A synthetic Algolia program hit; (key => undef) sends null, (-delete => [keys]) leaves keys out.
my $SERIAL = 5000;

sub hit {
	my %f      = @_;
	my $delete = delete $f{-delete} || [];
	my $n      = ++$SERIAL;
	my $slug   = delete $f{slug};
	$slug = "program-$n" unless defined $slug;

	my %hit = (
		objectID         => "coremedia://program/$n",
		title            => "Program $n",
		canonicalURL     => "https://www.abc.net.au/listen/programs/$slug/",
		shortTeaserText  => "Teaser $n",
		description      => "Description $n",
		defaultThumbnail => { '1x1' => thumb($n), '16x9' => "$WCMS/wide$n" },
		infoSource       => 'ABC Listen',
		programType      => 'podcast',
		%f,
	);
	delete @hit{@$delete};
	return \%hit;
}

sub route_hits {
	my ( $hits, %extra ) = @_;
	route( $ALGOLIA, content => to_json( { hits => $hits, nbHits => scalar @$hits, page => 0, nbPages => 1, hitsPerPage => 1000, %extra } ), headers => $JSON_TYPE );
}

# O2's network fixtures: Radio National (2 collections) and ABC Pacific; the other networks fail.
sub route_networks {
	route( qr{\Q$AGG\E\?collectionId=11474038&}, file => 'ondemand/bff-programAggregationCollection-rn.json', headers => $JSON_TYPE );
	route( qr{\Q$AGG\E\?collectionId=13910480&}, file => 'ondemand/bff-programAggregationCollection-rn-featured.synthetic.json', headers => $JSON_TYPE );
	route( qr{\Q$AGG\E\?collectionId=(?:9373518|9412768)&}, file => 'ondemand/bff-programAggregationCollection-pacific.trimmed.json', headers => $JSON_TYPE );
	route( qr{\Q$AGG\E}, code => 500 );
}

# programs() through a collector; returns the collector.
sub index_call {
	my $c = collector();
	$PI->programs( $c->cb );
	return $c;
}

sub result_of { ( $_[0]->args(0) )[0] }

# Call a feed coderef as XMLBrowser does: ($client, $cb, $args, @passthrough).
sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub open_item { my ( $item, $client ) = @_; return feed( $item->{url}, $client, @{ $item->{passthrough} || [] } ) }

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : $result;
}

sub by_type {
	my ( $key, $client ) = @_;
	my $c = collector();
	$OD->programsByType( $client, $c->cb, $key );
	return $c;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

sub text_item { { name => $_[0], type => 'text' } }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ && $_->{name} eq join( ' ', split ' ', $_->{name} ) && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty, trimmed name" );
}

sub logged { my $level = shift; grep { $_->{level} eq $level } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# The synthetic program list for the menu tests (18 programs; no News briefings).
my %MENU_REF;    # title/slug => the expected program ref

sub menu_hits {
	my @spec = (
		[ 'The Science Show',       'scienceshow',            'ABC Radio National', 'podcast' ],
		[ 'Saturday Night Country', 'saturdaynightcountry',   'ABC Country',        'music' ],
		[ 'Sunday Extra',           'sundayextra',            'ABC Radio National', 'catch-up' ],
		[ 'science friction',       'science-friction',       'ABC Radio National', 'podcast' ],
		[ 'Theatre Talk',           'theatre-talk',           'ABC Listen',         'podcast' ],
		[ 'the drum',               'the-drum',               'ABC News Podcasts',  'catch-up' ],
		[ 'The',                    'the',                    'ABC Listen',         undef ],
		[ '7.30',                   '730',                    'ABC News Podcasts',  'PODCAST' ],
		[ '100 Years of Radio',     '100-years',              'ABC Classic',        'Music Playlists' ],
		[ "'Tis the Season",        'tis-the-season',         'ABC Classic',        'music' ],
		[ '#Hashtag Hour',          'hashtag-hour',           'triple j',           'video' ],
		[ "\x{201C}Quoted\x{201D}", 'quoted',                 'ABC Listen',         'catch-up' ],
		[ "\x{C9}lan",              'elan',                   'Audio Books',        'audiobook' ],
		[ "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}", 'shengyin',     'ABC Listen',         'podcast' ],
		[ 'Breakfast',              'breakfast-sydney',       'ABC Sydney',         'catch-up' ],
		[ 'Breakfast',              'breakfast-perth',        'ABC Perth',          'catch-up' ],
		[ 'Breakfast',              'breakfast-perth-weekend', 'ABC Perth',         'catch-up' ],
		[ 'Breakfast',              'breakfast-nowhere',      undef,                'catch-up' ],
	);

	%MENU_REF = ();
	my @hits;
	for my $s (@spec) {
		my ( $title, $slug, $network, $type ) = @$s;
		my $hit = hit( title => $title, slug => $slug, infoSource => $network, programType => $type );
		push @hits, $hit;
		my ($id) = $hit->{objectID} =~ /([0-9]+)\z/;
		$MENU_REF{$slug} = {
			id          => $id,
			title       => $title,
			path        => "/listen/programs/$slug",
			description => $hit->{shortTeaserText},
			image       => $hit->{defaultThumbnail}->{'1x1'},
			( defined $network ? ( network => $network ) : () ),
			( defined $type ? ( programType => $type ) : () ),
		};
	}
	return \@hits;
}

# ---------------------------------------------------------------------------
# ProgramIndex: data
# ---------------------------------------------------------------------------

subtest 'programs: the fixture hits -> exact program refs; the request (params, opts)' => sub {
	fresh();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );

	my $c = index_call();
	is( $c->count, 1, 'one callback' );
	my $result = result_of($c);
	is_deeply( [ sort keys %$result ], [qw(fallback items)], '{ items, fallback }' );
	is( $result->{fallback}, 0, 'fallback 0' );

	my $items = $result->{items};
	is( scalar @$items, 3, 'the 3 hits' );
	is_deeply(
		$items->[0],
		{
			id          => '7462314',
			title       => 'Saturday Night Country',
			path        => '/listen/programs/saturdaynightcountry',
			description => "For over 30 years, Saturday Night Country has been Australia's home of country music.",
			image       => "$WCMS/0af840be01308fcdc934b82c3cf0336e?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=862&height=862",
			network     => 'ABC Country',
			programType => 'music',
		},
		'Saturday Night Country: exact ref (canonical path, shortTeaserText, the raw 1x1 image, infoSource, raw programType)'
	);
	is( $items->[1]->{title}, 'The Walkers: The Real Salt Path', 'a trailing space is trimmed' );
	is_deeply( [ map { $_->{path} } @$items ], [ '/listen/programs/saturdaynightcountry', '/listen/programs/the-walkers-the-real-salt-path', '/listen/programs/the-making-of-an-autocrat' ], 'Algolia order kept' );
	is( ( grep { defined $_->{id} && $_->{id} =~ /\A[0-9]+\z/ } @$items ), 3, 'every id is numeric (coremedia://program/<id>)' );
	is_deeply( [ map { $_->{programType} } @$items ], [qw(music podcast podcast)], 'programType: the raw values' );

	is( scalar @ALGOLIA, 1, 'one API::algolia call' );
	is_deeply( $ALGOLIA[0]->{opts}, { ttl => 86400, stale_ok => 1 }, 'opts: ttl 86400 (24 h), stale_ok (last-good)' );
	is_deeply(
		$ALGOLIA[0]->{params},
		{ query => '', hitsPerPage => 1000, filters => $FILTERS, attributesToRetrieve => \@ATTRIBUTES },
		'params: empty query, hitsPerPage 1000, the program filter, attributesToRetrieve'
	);

	my @sent = algolia_requests();
	is( scalar @sent, 1, 'one Algolia request' );
	is_deeply( JSON::PP::decode_json( $sent[0]->{body} ), { query => '', hitsPerPage => 1000, filters => $FILTERS, attributesToRetrieve => \@ATTRIBUTES }, 'the request body' );
	is( scalar agg_requests(), 0, 'no network lists loaded' );
};

subtest 'programs: cached 24 h (a cache hit makes no request and answers synchronously); coalesced' => sub {
	fresh();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );
	index_call();

	setTime( $T0 + 23 * 3600 );
	my $c = index_call();
	is( $c->count, 1, 'cache hit: answered synchronously' );
	is( scalar @{ result_of($c)->{items} }, 3, 'cache hit: the same programs' );
	is( scalar algolia_requests(), 1, 'cache hit: no second Algolia request within 24 h' );

	setTime( $T0 + 25 * 3600 );
	index_call();
	is( scalar algolia_requests(), 2, 'after 24 h: a new request' );

	# two menus opened before the first answer: one query
	fresh();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE, defer => 1 );
	my ( $a, $b ) = ( index_call(), index_call() );
	is( $a->count + $b->count, 0, 'in flight: nothing answered yet' );
	is( scalar algolia_requests(), 1, 'in flight: one Algolia request for both' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ $a->count, $b->count ], [ 1, 1 ], 'each caller answered once' );
	is( scalar @{ result_of($b)->{items} }, 3, 'the second caller gets the programs too' );
};

subtest 'mapping: titles, missing fields, skipped hits, de-duplication by path' => sub {
	fresh();
	route_hits( [
		hit( slug => 'entities', title => "  Tall Tales &amp; True \n  and   more  ", infoSource => 'ABC Jazz ' ),
		hit( slug => 'no-thumb',  -delete => ['defaultThumbnail'] ),
		hit( slug => 'no-square', defaultThumbnail => { '16x9' => "$WCMS/wide" } ),
		hit( slug => 'desc-only', -delete => ['shortTeaserText'], description => 'Long &amp; description' ),
		hit( slug => 'no-text',   shortTeaserText => '', description => undef ),
		hit( slug => 'no-network', infoSource => '', programType => undef ),
		hit( slug => 'no-source', -delete => [qw(infoSource programType)] ),
		( my $badId = hit( slug => 'bad-id', objectID => 'not-a-coremedia-uri' ) ),
		hit( title => 'Duplicate first',  canonicalURL => 'https://www.abc.net.au/listen/programs/dup' ),
		hit( title => 'Duplicate second', canonicalURL => 'https://www.abc.net.au/listen/programs/dup/' ),
		hit( title => 'Book',     canonicalURL => 'https://www.abc.net.au/listen/audiobooks/animal-farm-page/' ),
		hit( title => 'Hack',     canonicalURL => 'https://abc.net.au/triplej/programs/hack/' ),
		hit( title => 'No URL',   -delete => ['canonicalURL'] ),
		hit( title => 'Null URL', canonicalURL => undef ),
		hit( title => 'Off-site', canonicalURL => 'https://radio.abc.net.au/' ),
		hit( title => 'Elsewhere', canonicalURL => 'https://example.com/listen/programs/elsewhere/' ),
		hit( title => 'News page', canonicalURL => 'http://www.abc.net.au/news/qld/' ),
		hit( title => 'Network page', canonicalURL => 'https://www.abc.net.au/listen/radionational/' ),
		hit( title => 'An episode', canonicalURL => 'https://www.abc.net.au/listen/programs/scienceshow/an-episode/107266790' ),
		'not a hash',
	] );

	my $c = index_call();
	is( $c->count, 1, 'one callback' );
	my %by = map { $_->{path} => $_ } @{ result_of($c)->{items} };

	is( $by{'/listen/programs/entities'}->{title},   'Tall Tales & True and more', 'title: entities decoded, whitespace collapsed and trimmed' );
	is( $by{'/listen/programs/entities'}->{network}, 'ABC Jazz', 'network: infoSource trimmed' );
	ok( !exists $by{'/listen/programs/no-thumb'}->{image},  'no defaultThumbnail: no image' );
	ok( !exists $by{'/listen/programs/no-square'}->{image}, 'defaultThumbnail without 1x1: no image' );
	is( $by{'/listen/programs/desc-only'}->{description}, 'Long & description', 'no shortTeaserText: description' );
	ok( !exists $by{'/listen/programs/no-text'}->{description}, 'neither: no description' );
	ok( !exists $by{'/listen/programs/no-network'}->{network}, "infoSource '': no network" );
	ok( !exists $by{'/listen/programs/no-network'}->{programType}, 'programType null: no programType' );
	ok( !exists $by{'/listen/programs/no-source'}->{network} && !exists $by{'/listen/programs/no-source'}->{programType}, 'infoSource/programType missing: no network/programType' );
	ok( !exists $by{'/listen/programs/bad-id'}->{id}, 'objectID not coremedia://program/<id>: no id' );
	is( $by{'/listen/programs/bad-id'}->{title}, $badId->{title}, 'objectID not usable: the program is still listed' );

	is( $by{'/listen/programs/dup'}->{title}, 'Duplicate first', 'the same path twice: one ref (the first)' );
	is( ( grep { $_->{path} eq '/listen/programs/dup' } @{ result_of($c)->{items} } ), 1, 'the same path twice: listed once' );
	ok( $by{'/listen/audiobooks/animal-farm-page'}, 'an audiobook page is a program page' );
	ok( $by{'/triplej/programs/hack'},              'abc.net.au without www: kept, canonical path' );

	is( scalar keys %by, 11, '11 programs: 7 hits without a program page (no/null canonicalURL, other hosts, news/network/episode pages), the non-hash and the duplicate dropped' );
	ok( !( grep { $_->{title} =~ /URL|Off-site|Elsewhere|page|episode/ } values %by ), 'none of the skipped hits listed' );
	ok( ( grep { $_->{level} eq 'DEBUG' && $_->{message} =~ /7 hits without a program page skipped/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) ), 'the skipped count logged at DEBUG' );
};

subtest 'nbHits > hits returned (the index outgrew 1000): the hits returned, WARN once' => sub {
	fresh();
	route_hits( [ hit(), hit() ], nbHits => 1012 );

	my $c = index_call();
	is( scalar @{ result_of($c)->{items} }, 2, 'the hits returned' );
	is( result_of($c)->{fallback}, 0, 'no fallback' );
	is( ( grep { $_->{message} =~ /1012 programs; only the first 2/ } logged('WARN') ), 1, 'WARN logged' );
	is( scalar algolia_requests(), 1, 'no paging past the cap (one request)' );

	index_call();
	is( ( grep { $_->{message} =~ /1012 programs/ } logged('WARN') ), 1, 'logged once (not again on a cache hit)' );
};

subtest 'typeKey: the type table (case-insensitive; null and unknown -> other)' => sub {
	fresh();
	my %table = (
		'podcast'         => 'podcast',
		'PODCAST'         => 'podcast',
		' Podcast '       => 'podcast',
		'catch-up'        => 'catchup',
		'Catch-Up'        => 'catchup',
		'music'           => 'music',
		'Music Playlists' => 'music',
		'music playlists' => 'music',
		'news-briefing'   => 'news',
		'audiobook'       => 'audiobook',
		''                => 'other',
		'video'           => 'other',
		'catchup'         => 'other',
		'news'            => 'other',
	);
	for my $value ( sort keys %table ) {
		is( Plugins::ABCListen::ProgramIndex::typeKey($value), $table{$value}, "'$value' -> $table{$value}" );
	}
	is( Plugins::ABCListen::ProgramIndex::typeKey(undef), 'other', 'undef -> other' );
	is( Plugins::ABCListen::ProgramIndex::typeKey( [] ),  'other', 'a reference -> other' );
	is( $PI->typeKey('podcast'), 'podcast', 'works as a class method' );

	Plugins::ABCListen::ProgramIndex::typeKey($_) for 'Radio Drama', 'radio drama', 'Radio Drama';
	is( ( grep { $_->{level} eq 'DEBUG' && $_->{message} =~ /unknown programType '(?i:radio drama)'/ } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) ), 1, 'a new value is logged at DEBUG once' );
};

subtest 'sortKey and A–Z buckets: "The", digits, punctuation, accents, only "The"' => sub {
	my $bucket = sub { Plugins::ABCListen::OnDemand::_bucket( { title => $_[0], path => '/listen/programs/x' } ) };
	my @table = (
		[ 'The Science Show',              'science show',         's' ],
		[ 'the drum',                      'drum',                 'd' ],
		[ 'THE   Drum  ',                  'drum',                 'd' ],
		[ 'Theatre Talk',                  'theatre talk',         't' ],
		[ 'The',                           'the',                  't' ],
		[ '7.30',                          '7.30',                 '0-9' ],
		[ '100 Years of Radio',            '100 years of radio',   '0-9' ],
		[ 'The 26-Storey Treehouse',       '26-storey treehouse',  '0-9' ],
		[ "'Tis the Season",               "'tis the season",      't' ],
		[ '#Hashtag Hour',                 '#hashtag hour',        'h' ],
		[ "\x{201C}Quoted\x{201D}",        "\x{201C}quoted\x{201D}", 'q' ],
		[ "\x{C9}lan",                     'elan',                 'e' ],
		[ "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}", "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}", '0-9' ],
		[ '...',                           '...',                  '0-9' ],
	);
	for my $row (@table) {
		my ( $title, $key, $expected ) = @$row;
		is( Plugins::ABCListen::Programs::sortKey($title), $key, "sortKey('$title')" );
		is( $bucket->($title), $expected, "'$title' -> $expected" );
	}
	is( Plugins::ABCListen::OnDemand::_bucket( { path => '/listen/programs/zebra' } ), 'l', 'no title: the path programItem shows decides' );
};

subtest 'Algolia fails with a last-good copy: the stale data, no fallback' => sub {
	fresh();
	route_networks();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );
	index_call();

	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route_networks();
	route( $ALGOLIA, code => 500 );
	setTime( $T0 + 3 * 86400 );    # past the 24 h ttl, within the 7-day last-good

	my $c = index_call();
	is( $c->count, 1, 'one callback' );
	is( result_of($c)->{fallback}, 0, 'fallback 0 (no note)' );
	is_deeply( [ map { $_->{title} } @{ result_of($c)->{items} } ], [ 'Saturday Night Country', 'The Walkers: The Real Salt Path', 'The Making of an Autocrat' ], 'the last-good programs' );
	is( scalar algolia_requests(), 1, 'Algolia was asked' );
	is( scalar agg_requests(), 0, 'no network lists loaded' );

	setTime( $T0 + 8 * 86400 );    # the last-good copy is gone after 7 days
	$c = index_call();
	is( result_of($c)->{fallback}, 1, 'after 7 days: the network-list fallback' );
};

subtest 'Algolia fails without a last-good copy: the union of the network lists (fallback 1)' => sub {
	my @cases = (
		[ '500', sub { route( $ALGOLIA, code => 500 ) } ],
		[ '429 (RATE_LIMITED)', sub { route( $ALGOLIA, code => 429 ) } ],
		[ '403, the same key after re-discovery', sub { route( $ALGOLIA, code => 403 ) } ],
		[ 'bad JSON', sub { route( $ALGOLIA, content => '{"hits":[', headers => $JSON_TYPE ) } ],
		[ 'a timeout', sub { route( $ALGOLIA, error => 'Timed out waiting for data' ) } ],
		[ 'key discovery fails', sub { Slim::Networking::SimpleAsyncHTTP->reset; route( "$SITE/listen/search", code => 500 ) } ],
	);

	for my $case (@cases) {
		my ( $name, $setup ) = @$case;
		fresh();
		$setup->();
		route_networks();

		my $c = index_call();
		is( $c->count, 1, "$name: one callback" );
		my $result = result_of($c);
		is( $result->{fallback}, 1, "$name: fallback 1" );
		is_deeply(
			[ map { $_->{title} } @{ $result->{items} } ],
			[ "\x{C9}migr\x{E9} Stories", 'God Forbid', 'Health Report', 'The History Showcase', 'Nesia Daily', 'Politok', 'The Science Show' ],
			"$name: Radio National then ABC Pacific (network order), de-duplicated by path (God Forbid once)"
		);
	}

	my $c = index_call();
	my ($god) = grep { $_->{title} eq 'God Forbid' } @{ result_of($c)->{items} };
	is( $god->{network}, 'Radio National', 'the first network\'s ref wins' );
	ok( !( grep { exists $_->{programType} } @{ result_of($c)->{items} } ), 'no programType in fallback refs' );
	ok( !( grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) ), 'nothing logged at ERROR' );
};

subtest 'Algolia returns no usable hit (filter drift): fallback, never an empty A–Z' => sub {
	fresh();
	route_hits( [] );
	route_networks();
	my $c = index_call();
	is( result_of($c)->{fallback}, 1, '0 hits: fallback 1' );
	is( scalar @{ result_of($c)->{items} }, 7, '0 hits: the network programs' );
	is( ( grep { $_->{message} =~ /has no programs/ } logged('WARN') ), 1, '0 hits: WARN' );
	index_call();
	is( ( grep { $_->{message} =~ /has no programs/ } logged('WARN') ), 1, '0 hits again (cached): not logged again' );

	fresh();
	route_hits( [ hit( canonicalURL => 'https://www.abc.net.au/news/qld/' ) ] );
	route_networks();
	is( result_of( index_call() )->{fallback}, 1, 'only unusable hits: fallback 1' );

	fresh();
	route( $ALGOLIA, content => '{"message":"no hits here"}', headers => $JSON_TYPE );
	route_networks();
	is( result_of( index_call() )->{fallback}, 1, 'an answer without hits: fallback 1' );
};

subtest 'fallback: at most 4 network lists in flight; some fail -> the rest; all fail -> LOAD_FAILED' => sub {
	my %network = map { my $n = $_; map { $_ => $n->{key} } @{ $n->{collectionIds} } } Plugins::ABCListen::Programs::networks();
	my $in_flight = sub {
		my %keys = map { /collectionId=([0-9]+)/ ? ( $network{$1} => 1 ) : () } Slim::Networking::SimpleAsyncHTTP->deferred;
		return [ sort keys %keys ];
	};

	fresh();
	route( $ALGOLIA, code => 500 );
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$AGG\E}, sub {
		my ($id) = $_[0] =~ /collectionId=([0-9]+)/;
		return {
			defer   => 1,
			headers => $JSON_TYPE,
			content => to_json( { collection => { items => [ { contentUri => "coremedia://program/$id", cardId => $id, cardTitle => "Program $id", articleLink => "/listen/programs/p$id" } ], pagination => { total => 1 } } } ),
		};
	} );

	my $c = index_call();
	is( $c->count, 0, 'not answered while the lists load' );
	is_deeply( $in_flight->(), [qw(classic doublej rn triplej)], 'the first 4 networks in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( $in_flight->(), [qw(country jazz kids unearthed)], 'then the next 4' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( $in_flight->(), ['pacific'], 'then the last one' );
	is( $c->count, 0, 'still not answered' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'answered once, when every list is in' );
	is( scalar @{ result_of($c)->{items} }, 11, 'one program per collection (11 collections)' );
	is( result_of($c)->{fallback}, 1, 'fallback 1' );

	fresh();
	route( $ALGOLIA, code => 500 );
	route( qr{\Q$AGG\E}, code => 500 );
	$c = index_call();
	is( $c->count, 1, 'every network fails: one callback' );
	is_deeply( result_of($c), { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'every network fails: { error => LOAD_FAILED }' );
	ok( ( grep { $_->{message} =~ /every network list failed/ } logged('WARN') ), 'logged at WARN' );

	fresh();
	route( $ALGOLIA, code => 429 );
	route( qr{\Q$AGG\E}, code => 429 );
	is_deeply( result_of( index_call() ), { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'rate limited everywhere: LOAD_FAILED' );
};

subtest 'programs: exactly one callback, also when the consumer\'s callback dies' => sub {
	my $calls;
	my $dying = sub { $calls++; die "consumer broke\n" };

	fresh();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );
	$calls = 0;
	ok( eval { $PI->programs($dying); 1 }, 'success: the die does not reach the caller' ) or diag $@;
	is( $calls, 1, 'success: called once' );
	$calls = 0;
	ok( eval { $PI->programs($dying); 1 }, 'cache hit: the die does not reach the caller' ) or diag $@;
	is( $calls, 1, 'cache hit: called once' );

	fresh();
	route( $ALGOLIA, code => 500 );
	route_networks();
	$calls = 0;
	ok( eval { $PI->programs($dying); 1 }, 'fallback: the die does not reach the caller' ) or diag $@;
	is( $calls, 1, 'fallback: called once' );

	fresh();
	route( $ALGOLIA, code => 500 );
	route( qr{\Q$AGG\E}, code => 500 );
	$calls = 0;
	ok( eval { $PI->programs($dying); 1 }, 'error: the die does not reach the caller' ) or diag $@;
	is( $calls, 1, 'error: called once' );

	fresh();
	route_hits( [ hit() ] );
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::ProgramIndex::_ref = sub { die "mapping broke\n" };
		my $c = index_call();
		is( $c->count, 1, 'processing dies: one callback' );
		is_deeply( result_of($c), { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' }, 'processing dies: LOAD_FAILED' );
	}
	ok( ( grep { $_->{message} =~ /mapping broke/ } logged('ERROR') ), 'processing dies: logged at ERROR' );
};

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

subtest '_programsRoot: By network, All programs A–Z, By type (exact keys; no request)' => sub {
	fresh();
	my $c = feed($ROOT);
	is( $c->count, 1, 'one callback' );
	is_deeply(
		items_of($c),
		[
			{ name => 'By network',             type => 'link', url => \&Plugins::ABCListen::OnDemand::_networksFeed, image => $ICON },
			{ name => "All programs A${ENDASH}Z", type => 'link', url => $AZ,    image => $ICON },
			{ name => 'By type',                type => 'link', url => $TYPES, image => $ICON },
		],
		'exactly By network · All programs A–Z · By type'
	);
	is( scalar requests(), 0, 'no request until a list is opened' );
	ok( !( grep { exists $_->{description} } @{ items_of($c) } ), 'no description on browse items' );
};

subtest 'All programs A–Z: letters with counts, empty letters omitted, 0–9 last' => sub {
	fresh();
	route_hits( menu_hits() );

	my $c = feed($AZ);
	is( $c->count, 1, 'one callback' );
	my $letters = items_of($c);
	is_deeply( names($letters), [ 'B (4)', 'D (1)', 'E (1)', 'H (1)', 'Q (1)', 'S (4)', 'T (3)', "0${ENDASH}9 (3)" ], 'letters A..Z with programs, then 0–9; counts in the name' );
	is( ( grep { $_->{name} =~ /\A(?:[A-Z]|0\x{2013}9) \([0-9]+\)\z/ } @$letters ), scalar @$letters, 'every name matches ^([A-Z]|0–9) \(\d+\)$' );
	my $sum = 0;
	$sum += ( $_->{name} =~ /\(([0-9]+)\)/ )[0] for @$letters;
	is( $sum, 18, 'the counts add up to the programs' );
	is_deeply( $letters->[5], { name => 'S (4)', type => 'link', url => $LETTER, passthrough => ['s'], image => $ICON }, 'letter row: exact keys' );
	is_deeply( $letters->[-1]->{passthrough}, ['0-9'], '0–9 row passthrough' );
	check_names( $letters, 'letters' );
	is( scalar algolia_requests(), 1, 'one Algolia request' );

	my $s = items_of( open_item( $letters->[5] ) );
	is_deeply( names($s), [ 'Saturday Night Country', 'science friction', 'The Science Show', 'Sunday Extra' ], 'S: sortKey order; The Science Show under S' );
	is( scalar algolia_requests(), 1, 'opening a letter: no new Algolia request (cache hit)' );

	my $row = $s->[2];
	is_deeply(
		$row,
		{
			name        => 'The Science Show',
			line1       => 'The Science Show',
			line2       => 'ABC Radio National',
			type        => 'link',
			url         => $PROGRAM_MENU,
			passthrough => [ $MENU_REF{scienceshow} ],
			image       => Plugins::ABCListen::API::imageUrl( $MENU_REF{scienceshow}->{image}, 300 ),
		},
		'program row: exact O2 keys (line2 = network, the ref in the passthrough, 300 px image)'
	);
	like( $row->{image}, qr/width=300&height=300\z/, 'the artwork sized by programItem' );
	is_deeply( $row, $OD->programItem( undef, $MENU_REF{scienceshow} ), 'built by programItem' );
	ok( !( grep { exists $_->{description} } @$s ), 'no description on program rows' );

	is_deeply( names( items_of( open_item( $letters->[6] ) ) ), [ "'Tis the Season", 'The', 'Theatre Talk' ], 'T: only-"The" and "Theatre" under T' );
	is_deeply( names( items_of( open_item( $letters->[1] ) ) ), ['the drum'], 'D: "the drum" (case-insensitive "The")' );
	is_deeply( names( items_of( open_item( $letters->[-1] ) ) ), [ '100 Years of Radio', '7.30', "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}" ], '0–9: digits and a title without [a-z0-9]' );
	is_deeply( names( items_of( open_item( $letters->[3] ) ) ), ['#Hashtag Hour'], 'H: leading punctuation skipped' );
	is_deeply( names( items_of( open_item( $letters->[2] ) ) ), ["\x{C9}lan"], 'E: accent folded' );

	is_deeply( items_of( feed( $LETTER, undef, 'x' ) ), [ text_item($NO_PROGRAMS) ], 'a letter without programs (stale link): NO_PROGRAMS' );
	is_deeply( items_of( feed( $LETTER, undef ) ), [ text_item($NO_PROGRAMS) ], 'no letter: NO_PROGRAMS' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is_deeply( names( items_of( feed( $AZ, $client ) ) ), names($letters), 'with a client: the same letters' );
};

subtest 'duplicate titles: "<title> (<network>)" in name/line1 only; same network or none: the title' => sub {
	fresh();
	route_hits( menu_hits() );

	my $b = items_of( feed( $LETTER, undef, 'b' ) );
	is_deeply( names($b), [ 'Breakfast', 'Breakfast', 'Breakfast', 'Breakfast (ABC Sydney)' ], 'Sydney disambiguated; two in Perth and one without a network keep the title' );
	is_deeply( [ map { $_->{passthrough}->[0]->{path} } @$b ], [ map {"/listen/programs/breakfast-$_"} qw(nowhere perth perth-weekend sydney) ], 'same sort key: ordered by path' );

	my ($sydney) = grep { $_->{passthrough}->[0]->{path} eq '/listen/programs/breakfast-sydney' } @$b;
	is( $sydney->{line1}, 'Breakfast (ABC Sydney)', 'line1 overridden too' );
	is( $sydney->{line2}, 'ABC Sydney', 'line2 unchanged' );
	is_deeply( $sydney->{passthrough}, [ $MENU_REF{'breakfast-sydney'} ], 'the passthrough ref unchanged (title "Breakfast")' );
	ok( !exists $b->[0]->{line2}, 'no network: no line2' );
	check_names( $b, 'B' );

	is_deeply(
		[ grep {/Breakfast/} @{ names( by_type('catchup')->args(0) ) } ],
		[ 'Breakfast', 'Breakfast', 'Breakfast', 'Breakfast (ABC Sydney)' ],
		'the same in a type list'
	);
};

subtest 'By type: type rows in table order with counts, empty types omitted' => sub {
	fresh();
	route_hits( menu_hits() );

	my $c = feed($TYPES);
	is( $c->count, 1, 'one callback' );
	my $types = items_of($c);
	is_deeply( names($types), [ 'Podcasts (5)', 'Catch-up radio (7)', 'Music (3)', 'Audiobooks (1)', 'Other (2)' ], 'Podcasts … Other; News briefings (empty) omitted' );
	is_deeply( $types->[0], { name => 'Podcasts (5)', type => 'link', url => $TYPE, passthrough => ['podcast'], image => $ICON }, 'type row: exact keys' );
	is_deeply( [ map { $_->{passthrough}->[0] } @$types ], [qw(podcast catchup music audiobook other)], 'type keys' );
	check_names( $types, 'types' );

	my $podcasts = open_item( $types->[0] );
	is( $podcasts->count, 1, 'Podcasts: one callback' );
	is_deeply( names( items_of($podcasts) ), [ '7.30', 'science friction', 'The Science Show', 'Theatre Talk', "\x{58F0}\x{97F3}\x{4E4B}\x{65C5}" ], 'Podcasts: sortKey order ("PODCAST" counts)' );
	is_deeply( names( items_of( open_item( $types->[2] ) ) ), [ "'Tis the Season", '100 Years of Radio', 'Saturday Night Country' ], 'Music: incl. "Music Playlists"' );
	is_deeply( names( items_of( open_item( $types->[4] ) ) ), [ '#Hashtag Hour', 'The' ], 'Other: null and unknown programType' );
};

subtest 'programsByType: the public entry point (D2, D4)' => sub {
	fresh();
	route_hits( menu_hits() );

	my $types = items_of( feed($TYPES) );
	my %row   = map { $_->{passthrough}->[0] => $_ } @$types;

	for my $key (qw(podcast catchup music audiobook other)) {
		my $c = by_type($key);
		is( $c->count, 1, "$key: one callback" );
		my ($items) = $c->args(0);
		is( ref $items, 'ARRAY', "$key: called back with an array ref" );
		is_deeply( $items, items_of( open_item( $row{$key} ) ), "$key: identical items (names, order, keys) to By type -> $key" );
	}

	my ($podcasts) = by_type('podcast')->args(0);
	is( scalar @$podcasts, 5, 'podcast: the 5 podcasts' );
	is_deeply( $podcasts->[2], $OD->programItem( undef, $MENU_REF{scienceshow} ), 'podcast: programItem rows' );
	is_deeply( ( by_type('audiobook')->args(0) )[0], [ $OD->programItem( undef, $MENU_REF{elan} ) ], 'audiobook: the audiobook' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is_deeply( ( by_type( 'podcast', $client )->args(0) )[0], $podcasts, 'with a client: the same items' );

	my $c = by_type('news');
	is( $c->count, 1, 'empty type: one callback' );
	is_deeply( ( $c->args(0) )[0], [ text_item($NO_PROGRAMS) ], 'empty type (news): one NO_PROGRAMS text item' );

	# the D2 snippet: a feed url that hands its callback to programsByType
	my $d2 = sub { my ( $client, $cb, $args ) = @_; Plugins::ABCListen::OnDemand->programsByType( $client, $cb, 'podcast' ) };
	is_deeply( items_of( feed($d2) ), $podcasts, 'D2\'s feed snippet: the podcasts' );
	is( scalar algolia_requests(), 1, 'every list from one Algolia request' );
};

subtest 'programsByType: unknown, undef or label keys -> LOAD_FAILED + WARN; never dies; once' => sub {
	fresh();
	route_hits( menu_hits() );

	for my $key ( 'Podcasts', 'PODCAST', 'news-briefing', '', undef, [] ) {
		my $label = defined $key ? ref $key ? 'a reference' : "'$key'" : 'undef';
		Slim::Utils::Log->resetMessages;
		my $c = collector();
		ok( eval { $OD->programsByType( undef, $c->cb, $key ); 1 }, "$label: no die" ) or diag $@;
		is( $c->count, 1, "$label: one callback" );
		is_deeply( ( $c->args(0) )[0], [ text_item($LOAD_FAILED) ], "$label: one LOAD_FAILED item" );
		ok( ( grep { $_->{message} =~ /unknown program type/ } logged('WARN') ), "$label: WARN" );
	}
	is( scalar algolia_requests(), 0, 'no request for an unknown key' );

	my $calls = 0;
	ok( eval { $OD->programsByType( undef, sub { $calls++; die "D2 broke\n" }, 'nope' ); 1 }, 'unknown key, dying callback: no die' ) or diag $@;
	is( $calls, 1, 'unknown key, dying callback: called once' );
	$calls = 0;
	ok( eval { $OD->programsByType( undef, sub { $calls++; die "D2 broke\n" }, 'podcast' ); 1 }, 'dying callback: no die' ) or diag $@;
	is( $calls, 1, 'dying callback: called once' );
	ok( eval { $OD->programsByType( undef, undef, 'podcast' ); 1 }, 'no callback: no die' ) or diag $@;

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::_programRows = sub { die "rows broke\n" };
		my $c = by_type('podcast');
		is( $c->count, 1, 'building dies: one callback' );
		is_deeply( ( $c->args(0) )[0], [ text_item($LOAD_FAILED) ], 'building dies: LOAD_FAILED' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::ProgramIndex::programs = sub { die "index broke\n" };
		my $c;
		ok( eval { $c = by_type('podcast'); 1 }, 'the index dies: no die' ) or diag $@;
		is( $c->count, 1, 'the index dies: one callback' );
		is_deeply( ( $c->args(0) )[0], [ text_item($LOAD_FAILED) ], 'the index dies: LOAD_FAILED' );
	}
};

subtest 'fallback mode: the note first in A–Z; only the note in By type and programsByType' => sub {
	fresh();
	route( $ALGOLIA, code => 500 );
	route_networks();

	my $az = items_of( feed($AZ) );
	is_deeply( $az->[0], text_item($INDEX_FALLBACK), 'A–Z: the INDEX_FALLBACK text item first' );
	is_deeply( names($az), [ $INDEX_FALLBACK, 'E (1)', 'G (1)', 'H (2)', 'N (1)', 'P (1)', 'S (1)' ], 'A–Z: then the letters of the network programs' );
	is_deeply( names( items_of( open_item( $az->[3] ) ) ), [ 'Health Report', 'The History Showcase' ], 'a letter: the network programs (programItem rows)' );
	is( items_of( open_item( $az->[3] ) )->[0]->{line2}, 'Radio National', 'rows show the network' );

	my $c = feed($TYPES);
	is( $c->count, 1, 'By type: one callback' );
	is_deeply( items_of($c), [ text_item($INDEX_FALLBACK) ], 'By type: only the note (types are unknown)' );

	for my $key (qw(podcast audiobook other)) {
		$c = by_type($key);
		is( $c->count, 1, "programsByType($key): one callback" );
		is_deeply( ( $c->args(0) )[0], [ text_item($INDEX_FALLBACK) ], "programsByType($key): only the note" );
	}
	is( $INDEX_FALLBACK, 'The full program list is unavailable right now, so only programs from the network lists are shown.', 'the note says why the list is shorter' );
};

subtest 'index error: one LOAD_FAILED item on every feed; exactly one callback, also when LMS\'s callback dies' => sub {
	fresh();
	route( $ALGOLIA, code => 500 );
	route( qr{\Q$AGG\E}, code => 500 );

	for my $feed ( [ 'A–Z', $AZ ], [ 'a letter', $LETTER, 's' ], [ 'By type', $TYPES ] ) {
		my ( $name, $code, @pt ) = @$feed;
		my $c = feed( $code, undef, @pt );
		is( $c->count, 1, "$name: one callback" );
		is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], "$name: one LOAD_FAILED text item" );
	}
	my $c = by_type('podcast');
	is( $c->count, 1, 'programsByType: one callback' );
	is_deeply( ( $c->args(0) )[0], [ text_item($LOAD_FAILED) ], 'programsByType: one LOAD_FAILED text item' );

	my $calls;
	my $dying = sub { $calls++; die "LMS broke\n" };
	for my $setup ( [ 'error', sub { } ], [ 'success', sub { fresh(); route_hits( menu_hits() ) } ] ) {
		my ( $label, $prepare ) = @$setup;
		$prepare->();
		for my $feed ( [ 'A–Z', $AZ ], [ 'a letter', $LETTER, 's' ], [ 'By type', $TYPES ], [ 'a type', $TYPE, 'podcast' ] ) {
			my ( $name, $code, @pt ) = @$feed;
			$calls = 0;
			ok( eval { $code->( undef, $dying, {}, @pt ); 1 }, "$label, $name: the die does not reach LMS" ) or diag $@;
			is( $calls, 1, "$label, $name: called once" );
		}
	}
	$calls = 0;
	eval { $ROOT->( undef, $dying, {} ) };
	is( $calls, 1, 'the root: called once' );

	# a builder that dies: one LOAD_FAILED item
	fresh();
	route_hits( menu_hits() );
	no warnings 'redefine';
	local *Plugins::ABCListen::OnDemand::_bucket = sub { die "bucket broke\n" };
	for my $feed ( [ 'A–Z', $AZ ], [ 'a letter', $LETTER, 's' ] ) {
		my ( $name, $code, @pt ) = @$feed;
		$c = feed( $code, undef, @pt );
		is( $c->count, 1, "$name, building dies: one callback" );
		is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], "$name, building dies: LOAD_FAILED" );
	}
};

subtest 'the real fixture through the menus: S and By type' => sub {
	fresh();
	route( $ALGOLIA, file => 'ondemand/algolia-programs-list.json', headers => $JSON_TYPE );

	is_deeply( names( items_of( feed($AZ) ) ), [ 'M (1)', 'S (1)', 'W (1)' ], 'A–Z: "The Making…" under M, "The Walkers…" under W' );
	my $s = items_of( feed( $LETTER, undef, 's' ) );
	is_deeply( names($s), ['Saturday Night Country'], 'S: Saturday Night Country' );
	is( $s->[0]->{line2}, 'ABC Country', 'line2: the network' );
	is( $s->[0]->{image}, "$WCMS/0af840be01308fcdc934b82c3cf0336e?impolicy=wcms_crop_resize&cropH=2000&cropW=2000&xPos=0&yPos=0&width=300&height=300", 'artwork at 300 px' );
	is_deeply( names( items_of( feed($TYPES) ) ), [ 'Podcasts (2)', 'Music (1)' ], 'By type: Podcasts (2), Music (1)' );
	is( scalar algolia_requests(), 1, 'one Algolia request for all of it' );
};

done_testing();
