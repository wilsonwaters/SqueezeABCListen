#!/usr/bin/perl
# Plugins::ABCListen::Search as an LMS global search provider (D3), offline: Search->init registers
# the 'abclisten' provider with Slim::Menu::GlobalSearch (F1's stub); for a non-empty search the
# provider returns "ABC listen" holding one link with the search in its passthrough (no url on the
# top-level item: LMS numbers a global search session only then), else undef; calling it makes no
# request; opening the link runs the plugin's own search through the shared API.pm cache (in
# either order); init survives an LMS without registerInfoProvider, or one that dies.
#
# Fixtures: t/data/discovery/ (see t/44-search.t) and F3's search page
# t/data/foundation/listen-search.trimmed.html (app id TESTAPPID, key testsearchkey).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();

use Slim::Menu::GlobalSearch;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::API;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Search;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $SEARCH_FEED = \&Plugins::ABCListen::Search::_search;
my $SITE        = 'https://www.abc.net.au';
my $ALGOLIA     = 'https://TESTAPPID-dsn.algolia.net/1/indexes/listen_prod_all/query';
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $T0          = 1_792_400_000;

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	Slim::Networking::SimpleAsyncHTTP->addRoute( $ALGOLIA, sub {
		my ( $url, $method, $body ) = @_;
		my $programs = ( JSON::PP::decode_json($body)->{filters} || '' ) =~ /\AcontentType:program /;
		return { code => 200, headers => $JSON_TYPE, content => fixture( $programs ? 'discovery/algolia-programs-list.json' : 'discovery/algolia-listen_prod_all-query.json' ) };
	} );
}

sub provider { Slim::Menu::GlobalSearch->getInfoProvider->{abclisten} }

# Ask the provider as Slim::Menu::Base::addItem does: func->($client, $tags)
sub ask {
	my ( $client, $tags ) = @_;
	return provider()->{func}->( $client, $tags );
}

# The search link inside the provider's "ABC listen" item
sub search_link { my $item = shift; return ref $item eq 'HASH' && ref $item->{items} eq 'ARRAY' ? $item->{items}->[0] : undef }

# Open a link as XMLBrowser does: url->($client, $cb, $args, @passthrough)
sub open_item {
	my ( $item, $client, $args ) = @_;
	my $c = collector();
	$item->{url}->( $client, $c->cb, $args || {}, @{ $item->{passthrough} || [] } );
	return $c;
}

sub items_of { my ($result) = $_[0]->args(0); return ref $result eq 'HASH' ? $result->{items} : undef }
sub names    { [ map { $_->{name} } @{ $_[0] || [] } ] }
sub algolia_requests { grep { $_->{url} eq $ALGOLIA } requests() }

sub errors_logged { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# ---------------------------------------------------------------------------

subtest 'init registers the "abclisten" provider with LMS global search' => sub {
	fresh();
	ok( !provider(), 'no provider before init' );
	ok( eval { Plugins::ABCListen::Search->init(); 1 }, 'init does not die' ) or diag $@;

	my $provider = provider();
	ok( $provider, 'registered under "abclisten"' );
	is( ref $provider->{func}, 'CODE', 'with a func' );
	is( $provider->{isa}, 'middle', 'placed with the other providers (LMS default)' );
	is( scalar requests(), 0, 'no request at init' );

	# initPlugin (all hooks) registers it too
	resetStubs();
	ok( eval { Plugins::ABCListen::Plugin->initPlugin(); 1 }, 'initPlugin does not die' ) or diag $@;
	ok( provider(), 'registered by initPlugin (Search->init)' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'the provider returns "ABC listen" holding the search link (search in its passthrough)' => sub {
	fresh();
	Plugins::ABCListen::Search->init();

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my $item   = ask( $client, { search => 'science show', apps => [], menuMode => 0 } );
	is_deeply(
		$item,
		{
			name  => 'ABC listen',
			type  => 'link',
			items => [ { name => q{Results for 'science show'}, type => 'link', url => $SEARCH_FEED, passthrough => [ { search => 'science show' } ] } ],
		},
		'exact keys: "ABC listen" link with one inline link: name, type link, url _search, passthrough [{ search }]'
	);
	is( $item->{name}, string('PLUGIN_ABCLISTEN_GLOBAL_SEARCH_TITLE'), 'from PLUGIN_ABCLISTEN_GLOBAL_SEARCH_TITLE' );
	is( $item->{items}->[0]->{name}, string( 'PLUGIN_ABCLISTEN_SEARCH_RESULTS', 'science show' ), 'the inner link from PLUGIN_ABCLISTEN_SEARCH_RESULTS' );
	ok( !exists $item->{description} && !exists $item->{items}->[0]->{description}, 'no description on either link (LMS menu rule 1)' );

	# Slim::Control::XMLBrowser only gives a global search a browse session id (which the
	# "<sid>_<query>.N" item ids of every later globalsearch request need) when no top-level item
	# has a code ref url: our top-level item must not have one.
	ok( !exists $item->{url}, 'no url on the top-level item (so LMS can number the global search session)' );

	my $other = ask( undef, { search => '  Science   Show ' } );
	is_deeply( $other->{items}->[0]->{passthrough}, [ { search => '  Science   Show ' } ], 'without a client (CLI "-"): still the link, the text as typed' );
	is( $other->{items}->[0]->{name}, q{Results for 'Science Show'}, 'the name shows the text tidied (case kept)' );
	is_deeply( ask( $client, { search => 'café 🎧' } )->{items}->[0]->{passthrough}, [ { search => 'café 🎧' } ], 'non-ASCII text passed on unchanged' );
};

subtest 'empty search: the provider returns undef' => sub {
	fresh();
	Plugins::ABCListen::Search->init();

	is( ask( undef, { search => '' } ),      undef, 'empty' );
	is( ask( undef, { search => "  \t " } ), undef, 'whitespace only' );
	is( ask( undef, { search => undef } ),   undef, 'undef' );
	is( ask( undef, {} ),                    undef, 'no search tag' );
	is( ask( undef, undef ),                 undef, 'no tags' );
};

subtest 'calling the provider makes no request (no Algolia budget for library-only searches)' => sub {
	fresh();
	Plugins::ABCListen::Search->init();

	ask( undef, { search => "query $_" } ) for 1 .. 5;
	is( scalar requests(), 0, 'five global searches: no request at all' );
};

subtest 'opening the link runs the same search; it shares the cache with the Search item' => sub {
	fresh();
	Plugins::ABCListen::Search->init();

	my $c = open_item( search_link( ask( undef, { search => 'Science  Show' } ) ) );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply( names($items), [ 'Programs (3)', 'Episodes (2)' ], 'the Programs/Episodes groups' );
	is( scalar algolia_requests(), 2, 'two Algolia queries' );
	is_deeply( [ map { JSON::PP::decode_json( $_->{body} )->{query} } algolia_requests() ], [ 'science show', 'science show' ], 'the normalised query' );

	my $own = collector();
	$SEARCH_FEED->( undef, $own->cb, { search => 'science show' } );
	is_deeply( items_of($own), $items, 'the Search item gives the same items' );
	is( scalar algolia_requests(), 2, '... from the shared cache' );

	# the other way round
	fresh();
	Plugins::ABCListen::Search->init();
	$own = collector();
	$SEARCH_FEED->( undef, $own->cb, { search => 'science show' } );
	is( scalar algolia_requests(), 2, 'the Search item first: two queries' );
	$c = open_item( search_link( ask( undef, { search => 'SCIENCE SHOW' } ) ) );
	is_deeply( items_of($c), items_of($own), 'then the global search link: the same items' );
	is( scalar algolia_requests(), 2, '... without a new request' );
};

subtest 'opening the link for a search with no results: one NO_RESULTS text item' => sub {
	fresh();
	@Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
	route( $ALGOLIA, file => 'discovery/algolia-search-empty.synthetic.json', headers => $JSON_TYPE );
	Plugins::ABCListen::Search->init();

	my $c = open_item( search_link( ask( undef, { search => 'zzqxvbnm' } ) ) );
	is( $c->count, 1, 'one callback' );
	is_deeply( items_of($c), [ { name => q{No results for 'zzqxvbnm'}, type => 'text' } ], 'exactly one text item' );
};

subtest 'init survives an LMS without registerInfoProvider, or one that dies' => sub {
	fresh();
	{
		no warnings 'redefine';
		local *Slim::Menu::GlobalSearch::registerInfoProvider;
		undef &Slim::Menu::GlobalSearch::registerInfoProvider if defined &Slim::Menu::GlobalSearch::registerInfoProvider;
		ok( !Slim::Menu::GlobalSearch->can('registerInfoProvider'), 'registerInfoProvider is missing' );
		ok( eval { Plugins::ABCListen::Search->init(); 1 }, 'init does not die' ) or diag $@;
		ok( !provider(), 'no provider registered' );
		is( scalar errors_logged(), 0, 'no error logged (DEBUG only)' );
	}

	fresh();
	{
		no warnings 'redefine';
		local *Slim::Menu::GlobalSearch::registerInfoProvider = sub { die "registry exploded\n" };
		ok( eval { Plugins::ABCListen::Search->init(); 1 }, 'a dying registerInfoProvider: init does not die' ) or diag $@;
		ok( ( grep { $_->{message} =~ /registry exploded/ } errors_logged() ), 'the failure is logged' );
	}

	# the Search item still works
	my $c = collector();
	Plugins::ABCListen::Search->menuItems( undef, $c->cb, {} );
	is_deeply( names( ( $c->args(0) )[0] ), ['Search'], 'the Search item is unaffected' );
};

done_testing();
