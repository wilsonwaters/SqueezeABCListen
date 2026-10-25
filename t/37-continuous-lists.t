#!/usr/bin/perl
# U2 (#84): one continuous list instead of "More…" / "More episodes…" pages.
#
# Program menus (OnDemand::_programMenu) are LMS partial feeds: Slim::Control::XMLBrowser and
# Slim::Web::XMLBrowser pass a code-ref feed index/quantity (the rows a client lists, or the row it
# opens with quantity 1), and the feed answers { items, offset, total }, loading only the ABC
# episode pages (50 a page) the window shows, plus page 0 for the total. Covered here: the window
# -> ABC page mapping (first open, scrolling, opening one row, the web UI's pages, the rows before
# a window that XMLBrowser adds), total and offset, stable ids (row i is the same episode whatever
# the window), the whole list without a window (Play all), at most 4 pages in flight, a failed or
# short page, a window past the end, provider rows and a program page that undercounts (a second
# round of pages), exactly one callback.
#
# Collection menus (Collections::_collectionMenu) use the bounded full fetch: every page of the
# collection to 200 cards, at most 4 requests at a time, within 4 s of the first page; a page that
# failed, was empty or was late ends the list (no gap). Covered: the whole list, the cap, the
# concurrency, the deadline (and that a late page is used on the next open), a failed page,
# cross-page duplicates, stable rows, exactly one callback.
#
# Fixtures: the Science Show program page (t/data/ondemand, as t/33) and synthetic episode and
# collection pages served by offset/size like ABC.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $OD          = 'Plugins::ABCListen::OnDemand';
my $SITE        = 'https://www.abc.net.au';
my $BFF         = "$SITE/core-next/api";
my $EPS         = "$BFF/episodesWithSegments/x";
my $COLL        = "$BFF/collection/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $SCIENCE     = '/listen/programs/scienceshow';
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $RATE        = string('PLUGIN_ABCLISTEN_RATE_LIMITED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');
my $MORE_EPS    = string('PLUGIN_ABCLISTEN_MORE_EPISODES');

my $PROGRAM_MENU = \&Plugins::ABCListen::OnDemand::_programMenu;
my $COLL_MENU    = \&Plugins::ABCListen::Collections::_collectionMenu;
my $HEADER       = 4;    # the Science Show's rows before its episodes: description, About, presenters, network

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::Collections->_reset;
	Plugins::ABCListen::OnDemand::_resetProviders();
	setTime(1_792_400_000);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub offset_of { $_[0] =~ /[?&]offset=([0-9]+)/ ? $1 + 0 : undef }

sub episode_offsets    { map { offset_of( $_->{url} ) } grep { $_->{url} =~ /episodesWithSegments/ } requests() }
sub collection_offsets { map { offset_of( $_->{url} ) } grep { $_->{url} =~ m{/collection/x} } requests() }

# Call a feed as XMLBrowser does, with these args; the collector
sub feed {
	my ( $code, $args, @passthrough ) = @_;
	my $c = collector();
	$code->( undef, $c->cb, $args, @passthrough );
	return $c;
}

sub answer { my ($c) = @_; my ($feed) = $c->args(0); return $feed }
sub names  { [ map { $_->{name} } @{ $_[0] } ] }
sub plays  { [ map { $_->{play} // $_->{name} } @{ $_[0] } ] }

sub science { feed( $PROGRAM_MENU, $_[0], { title => 'The Science Show', path => $SCIENCE } ) }

# The Science Show program page; its program page says the collection has $detailTotal episodes
sub route_science {
	my $detailTotal = shift;
	if ( !defined $detailTotal ) {
		route( "$NEXT$SCIENCE.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
		return;
	}
	my $page = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') );
	$page->{pageProps}->{programCollectionPrepared}->{pagination}->{total} = $detailTotal;
	route( "$NEXT$SCIENCE.json", content => to_json($page), headers => $JSON_TYPE );
}

my $TEMPLATE = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') )->{pageProps}->{programCollectionPrepared}->{items}->[0];
my $NEWEST   = timegm( 0, 0, 1, 17, 9, 2026 );

sub episode_card {
	my $n    = shift;
	my %card = %$TEMPLATE;
	my $id   = 300000 + $n;
	my @t    = gmtime( $NEWEST - $n * 3 * 86400 );
	$card{contentUri}              = "coremedia://audioepisode/$id";
	$card{cardId}                  = "$id";
	$card{cardTitle}               = "Episode $n";
	$card{articleLink}             = "$SCIENCE/episode-$n/$id";
	$card{cardAttributionPrepared} = { publishedDate => sprintf( '%04d-%02d-%02dT%02d:00:00+00:00', $t[5] + 1900, $t[4] + 1, $t[3], $t[2] ) };
	$card{segments}                = undef;
	return \%card;
}

# ABC's episode pages by offset/size: %opt total (250), have (how many it really holds: total),
# fail => { offset => code }, defer => { offset => 1 }
sub route_episodes {
	my %opt  = @_;
	my $total = defined $opt{total} ? $opt{total} : 250;
	my $have  = defined $opt{have}  ? $opt{have}  : $total;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$EPS\E\?collectionId=2885458&}, sub {
		my $url = shift;
		my ( $offset, $size ) = ( offset_of($url), $url =~ /size=([0-9]+)/ );
		return { code => $opt{fail}->{$offset} } if $opt{fail} && $opt{fail}->{$offset};
		my @cards = map { episode_card($_) } grep { $_ < $have } $offset .. $offset + $size - 1;
		return {
			code    => 200,
			headers => $JSON_TYPE,
			content => to_json( { collection => { id => '2885458', items => \@cards, pagination => { offset => $offset, size => $size + 0, total => $total } } } ),
			( $opt{defer} && $opt{defer}->{$offset} ? ( defer => 1 ) : () ),
		};
	} );
}

# the episode number of a row (undef for other rows)
sub episode_no { my $item = shift; return $item && ( $item->{name} // '' ) =~ /Episode ([0-9]+)\z/ ? $1 + 0 : undef }

# ---------------------------------------------------------------------------
# Program menu: the window -> ABC page mapping
# ---------------------------------------------------------------------------

subtest 'program menu, first open (menu:1 asks 0..99): rows 0..99 from pages 0 and 1; offset 0, total 254' => sub {
	fresh();
	route_science();
	route_episodes();

	my $c = science( { index => 0, quantity => 100 } );
	is( $c->count, 1, 'one callback' );
	my $feed = answer($c);
	is( $feed->{offset}, 0,   'offset 0' );
	is( $feed->{total},  254, 'total 254: 4 header rows and ABC\'s 250 episodes' );
	is( scalar @{ $feed->{items} }, 100, '100 rows' );
	is_deeply( names( [ @{ $feed->{items} }[ 1 .. 3 ] ] ), [ 'About this program', 'Presented by Robyn Williams, Belinda Smith', 'ABC Radio National' ], 'the header rows first' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} }[ 4 .. 99 ] ], [ 0 .. 95 ], 'then episodes 0..95, newest first' );
	is_deeply( [ episode_offsets() ], [ 0, 50 ], 'only the pages those rows are on: offsets 0 and 50 (of 0..200)' );
	ok( !( grep { ( $_->{name} // '' ) eq $MORE_EPS } @{ $feed->{items} } ), 'no "More episodes…" row' );
};

subtest 'program menu, scrolling (rows 100..199 next): pages 1 (cached), 2 and 3; offset 100' => sub {
	fresh();
	route_science();
	route_episodes();
	science( { index => 0, quantity => 100 } );

	my $feed = answer( science( { index => 100, quantity => 100 } ) );
	is( $feed->{offset}, 100, 'offset 100' );
	is( $feed->{total},  254, 'total 254' );
	is_deeply( [ map { episode_no($_) } @{ $feed->{items} } ], [ 96 .. 195 ], 'episodes 96..195' );
	is_deeply( [ episode_offsets() ], [ 0, 50, 100, 150 ], 'two more requests: offsets 100 and 150 (0 and 50 were cached)' );

	$feed = answer( science( { index => 200, quantity => 100 } ) );
	is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ 200, 254, 54 ], 'the last window: offset 200, 54 rows to the total' );
	is( episode_no( $feed->{items}->[-1] ), 249, 'the last row: episode 249, ABC\'s 250th' );
	is_deeply( [ episode_offsets() ], [ 0, 50, 100, 150, 200 ], 'one more request: offset 200; nothing at 250' );
};

subtest 'program menu, opening one row (index k, quantity 1): page 0 and k\'s page only; the same episode as in the whole list' => sub {
	fresh();
	route_science();
	route_episodes();
	my $whole = answer( science( {} ) )->{items};
	is( scalar @$whole, 254, '(the whole list: 254 rows)' );

	for my $k ( 0, 1, 3, 4, 53, 54, 103, 154, 253 ) {
		fresh();
		route_science();
		route_episodes();
		my $feed = answer( science( { index => $k, quantity => 1 } ) );
		is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ $k, 254, 1 ], "row $k: offset $k, total 254, one row" );
		is_deeply( plays( $feed->{items} ), plays( [ $whole->[$k] ] ), "row $k is the whole list's row $k (stable id)" );
		my $page = $k < $HEADER ? 0 : int( ( $k - $HEADER ) / 50 );
		is_deeply( [ episode_offsets() ], [ $page ? ( 0, $page * 50 ) : 0 ], "row $k: requests " . join( ', ', $page ? ( 0, $page * 50 ) : 0 ) );
	}
};

subtest 'program menu: XMLBrowser\'s extra rows before a window, and the web UI\'s pages of 50' => sub {
	fresh();
	route_science();
	route_episodes();
	my $whole = answer( science( {} ) )->{items};

	# Slim::Control::XMLBrowser asks index - 10, quantity + 10 (room for context-menu rows)
	my $feed = answer( science( { index => 90, quantity => 110 } ) );
	is_deeply( [ $feed->{offset}, scalar @{ $feed->{items} } ], [ 90, 110 ], 'index 90, quantity 110: rows 90..199' );
	is_deeply( plays( $feed->{items} ), plays( [ @$whole[ 90 .. 199 ] ] ), '... the whole list\'s rows 90..199' );

	# Slim::Web::XMLBrowser: index = the page's start, quantity = itemsPerPage (50)
	for my $start ( 0, 50, 200, 250 ) {
		$feed = answer( science( { isWeb => 1, wantMetadata => 1, wantIndex => 1, index => $start, quantity => 50 } ) );
		my $to = $start + 50 > 254 ? 254 : $start + 50;
		is_deeply( [ $feed->{offset}, $feed->{total} ], [ $start, 254 ], "web page from $start: offset $start, total 254" );
		is_deeply( plays( $feed->{items} ), plays( [ @$whole[ $start .. $to - 1 ] ] ), "... rows $start.." . ( $to - 1 ) );
	}

	# a search-suffixed or odd index: its leading digits; junk: the whole list
	is( answer( science( { index => '7_x', quantity => 1 } ) )->{offset}, 7, 'index "7_x": 7' );
	is( scalar @{ answer( science( { index => 'x', quantity => 5 } ) )->{items} }, 254, 'index "x": no window, the whole list' );
	is( scalar @{ answer( science( { index => 3, quantity => 0 } ) )->{items} }, 254, 'quantity 0: the whole list' );
};

subtest 'program menu: no window (playlist commands: Play all / Add all) is the whole list; at most 4 pages in flight' => sub {
	fresh();
	route_science();
	route_episodes( defer => { map { $_ => 1 } 0, 50, 100, 150, 200 } );

	my $c = science(undef);
	is( $c->count, 0, 'waiting for ABC' );
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 0, 50, 100, 150 ], '4 pages in flight (0, 50, 100, 150), the 5th waits' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [200], 'one answered: the 5th (200) goes' );
	is( $c->count, 0, 'still waiting' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'then one callback' );
	my $feed = answer($c);
	is_deeply( [ $feed->{offset}, $feed->{total}, scalar @{ $feed->{items} } ], [ 0, 254, 254 ], 'offset 0, total 254, every row' );
	is( scalar( grep { $_->{play} } @{ $feed->{items} } ), 250, 'all 250 episodes playable (what Play all would queue)' );
};

subtest 'program menu: a failed page ends the list with its error row; a short page ends it there' => sub {
	fresh();
	route_science();
	route_episodes( fail => { 100 => 500 } );
	my $feed = answer( science( {} ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 105, 105 ], 'page 2 failed: header, episodes 0..99, one error row: 105 rows, total 105' );
	is_deeply( $feed->{items}->[-1], { name => $LOAD_FAILED, type => 'text' }, '... the LOAD_FAILED text row' );
	is( episode_no( $feed->{items}->[-2] ), 99, '... after episode 99 (no gap, nothing after it)' );

	fresh();
	route_science();
	route_episodes( fail => { 50 => 429 } );
	$feed = answer( science( { index => 60, quantity => 10 } ) );
	is_deeply( $feed->{items}, [ { name => $RATE, type => 'text' } ], 'a window on a rate-limited page: its error row' );
	is_deeply( [ $feed->{offset}, $feed->{total} ], [ 60, 61 ], '... offset 60, total 61' );

	fresh();
	route_science();
	route_episodes( fail => { 0 => 500 } );
	$feed = answer( science( {} ) );
	is_deeply( [ @{ names( $feed->{items} ) }[ -1 ], $feed->{total} ], [ $LOAD_FAILED, 5 ], 'page 0 failed: the header, then LOAD_FAILED (total 5)' );

	fresh();
	route_science();
	route_episodes( total => 250, have => 230 );    # ABC's list shrank: it says 250, holds 230
	$feed = answer( science( {} ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 234, 234 ], 'a short last page: the list ends after episode 229 (total 234)' );
	is( episode_no( $feed->{items}->[-1] ), 229, '... the last row: episode 229' );

	fresh();
	route_science();
	route_episodes( total => 120 );
	$feed = answer( science( { index => 0, quantity => 25000 } ) );    # Material asks for everything at once
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 124, 124 ], 'a program with 120 episodes, quantity 25000 (Material): 124 rows' );
	$feed = answer( science( { index => 0, quantity => 100 } ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 124, 100 ], '... rows 0..99: 100 rows of a total 124 (page 0\'s total, not the program page\'s 250)' );
};

subtest 'program menu: a window past the end; a window in the header' => sub {
	fresh();
	route_science();
	route_episodes();
	my $feed = answer( science( { index => 300, quantity => 10 } ) );
	is_deeply( [ $feed->{items}, $feed->{offset}, $feed->{total} ], [ [], 300, 254 ], 'past the end: no rows, offset 300, total 254' );

	fresh();
	route_science();
	route_episodes();
	$feed = answer( science( { index => 1, quantity => 1 } ) );
	is_deeply( names( $feed->{items} ), ['About this program'], 'row 1: About this program' );
	is_deeply( [ episode_offsets() ], [0], '... only page 0 (for the total)' );
};

subtest 'program menu: provider rows and an undercounting program page need a second round of pages' => sub {
	fresh();
	route_science();
	route_episodes();
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Follow', type => 'text' }, { name => 'Hint', type => 'text' } ] ) } );

	# header 4 + 2 provider rows: row 105 is episode 99 (page 1); the header alone estimates episode 101 (page 2)
	my $feed = answer( science( { index => 105, quantity => 1 } ) );
	is( episode_no( $feed->{items}->[0] ), 99, 'row 105: episode 99' );
	is_deeply( [ episode_offsets() ], [ 0, 100, 50 ], 'pages 0 and 2 (the estimate), then 50 (the second round)' );
	is( $feed->{total}, 256, 'total 256 (6 rows before the episodes)' );

	fresh();
	route_science(50);    # the program page says 50 episodes; ABC has 250
	route_episodes();
	$feed = answer( science( { index => 0, quantity => 500 } ) );
	is_deeply( [ $feed->{total}, scalar @{ $feed->{items} } ], [ 254, 254 ], 'the program page says 50: page 0\'s total (250) wins, every row' );
	is_deeply( [ episode_offsets() ], [ 0, 50, 100, 150, 200 ], 'page 0 first (the estimate), then 50..200' );
};

subtest 'program menu: 100 or more rows after the description: "About this program" even for a short one (Material hides the header)' => sub {
	my $short = sub {
		my $page = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') );
		$page->{pageProps}->{heroDescriptionPrepared} = { descriptionPrepared => { descriptor => { type => 'tagname', key => 'div', children => [ { type => 'tagname', key => 'p', children => [ { type => 'text', content => 'Science, weekly.' } ] } ] } } };
		route( "$NEXT$SCIENCE.json", content => to_json($page), headers => $JSON_TYPE );
	};

	# rows after the textarea: Presented by, the network, then the episodes
	for my $case ( [ 250, 1 ], [ 98, 1 ], [ 97, 0 ], [ 30, 0 ] ) {
		my ( $episodes, $about ) = @$case;
		fresh();
		$short->();
		route_episodes( total => $episodes );
		my $feed = answer( science( { index => 0, quantity => 300 } ) );
		is_deeply( $feed->{items}->[0], { name => 'Science, weekly.', type => 'textarea' }, "$episodes episodes: the (short) description first" );
		if ($about) {
			is_deeply( $feed->{items}->[1], { name => 'About this program', type => 'link', items => [ { name => 'Science, weekly.', type => 'textarea' } ] }, "... 2 + $episodes rows after it (>= 100): About this program" );
		}
		else {
			is( $feed->{items}->[1]->{name}, 'Presented by Robyn Williams, Belinda Smith', "... 2 + $episodes rows after it (< 100): no About row" );
		}
		is( $feed->{total}, 1 + $about + 2 + $episodes, "... total " . ( 1 + $about + 2 + $episodes ) );
	}

	# the same rows whatever the window (the row is decided from page 0's total, not the window)
	fresh();
	$short->();
	route_episodes( total => 250 );
	is_deeply( names( answer( science( { index => 1, quantity => 1 } ) )->{items} ), ['About this program'], 'row 1 opened alone: About this program' );
	is( episode_no( answer( science( { index => 4, quantity => 1 } ) )->{items}->[0] ), 0, 'row 4: episode 0' );
};

subtest 'program menu: exactly one callback' => sub {
	fresh();
	route_science();
	route_episodes( defer => { 50 => 1 } );
	my $calls = 0;
	my $dies  = sub { $calls++; die "LMS broke\n" };
	ok( eval { $PROGRAM_MENU->( undef, $dies, { index => 0, quantity => 100 }, { title => 'The Science Show', path => $SCIENCE } ); 1 }, 'a callback that dies: nothing escapes' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $calls, 1, '... and it is called once' );

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Programs::episodes = sub { my $cb = $_[3]; $cb->( { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ); $cb->( { items => [], total => 0 } ) };
		my $c = science( {} );
		is( $c->count, 1, 'a page that answers twice: one callback' );
		is( names( answer($c)->{items} )->[-1], $LOAD_FAILED, '... with the first answer' );
	}

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		my $calls = 0;
		my $header = \&Plugins::ABCListen::OnDemand::_programHeader;
		local *Plugins::ABCListen::OnDemand::_programHeader = sub { die "header broke\n" if ++$calls > 1; goto &$header };
		my $c = science( { index => 0, quantity => 10 } );
		is( $c->count, 1, 'building the rows dies once the pages are in: one callback' );
		is_deeply( answer($c)->{items}, [ { name => $LOAD_FAILED, type => 'text' } ], '... the LOAD_FAILED row' );
	}

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Programs::episodes = sub { die "episodes broke\n" };
		my $c = science( {} );
		is( $c->count, 1, 'a page request that dies: one callback' );
		is( names( answer($c)->{items} )->[-1], $LOAD_FAILED, '... LOAD_FAILED after the header' );
	}
};

# ---------------------------------------------------------------------------
# Collection menus: the bounded full fetch
# ---------------------------------------------------------------------------

sub program_card {
	my $n = shift;
	return { contentUri => "coremedia://program/$n", cardId => "$n", cardTitle => "Program $n", articleLink => "$SITE/listen/programs/p$n/" };
}

# A collection of $total program cards in pages by offset/size; fail => { offset => code },
# defer => { offset => 1 }, cards => \@cards (instead of program 1..total)
sub route_collection {
	my ( $id, %opt ) = @_;
	my @cards = $opt{cards} ? @{ $opt{cards} } : map { program_card($_) } 1 .. $opt{total};
	my $total = defined $opt{total} ? $opt{total} : scalar @cards;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$COLL\E\?collectionId=$id&}, sub {
		my $url = shift;
		my ( $offset, $size ) = ( offset_of($url), $url =~ /size=([0-9]+)/ );
		return { code => $opt{fail}->{$offset} } if $opt{fail} && $opt{fail}->{$offset};
		my @page = grep {defined} @cards[ $offset .. $offset + $size - 1 ];
		return {
			code    => 200,
			headers => $JSON_TYPE,
			content => to_json( { collection => { title => "Collection $id", items => \@page, pagination => { offset => $offset, size => $size + 0, total => $total } } } ),
			( $opt{defer} && $opt{defer}->{$offset} ? ( defer => 1 ) : () ),
		};
	} );
}

sub collection { my $id = shift; my $c = feed( $COLL_MENU, {}, { id => $id, title => "Collection $id" }, 0, 1 ); advanceTime(3); return $c }

subtest 'collection menu: 97 cards (Music) as one list; 5 pages of 20; at most 4 in flight' => sub {
	fresh();
	route_collection( 104142058, total => 97, defer => { map { $_ => 1 } 20, 40, 60, 80 } );
	my $c = feed( $COLL_MENU, {}, { id => 104142058, title => 'Music' }, 0, 1 );
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 20, 40, 60, 80 ], 'after the first page: the 4 others at once (4 in flight)' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(3);    # program names (not routed: they fail and keep the card titles)
	is( $c->count, 1, 'one callback' );
	my $items = answer($c)->{items};
	is( scalar @$items, 97, '97 rows' );
	is_deeply( names($items), [ map {"Program $_"} 1 .. 97 ], 'in ABC\'s order, no "More…" row' );
	is_deeply( [ collection_offsets() ], [ 0, 20, 40, 60, 80 ], 'pages of 20 at 0..80; nothing at 100' );

	fresh();
	route_collection( 6, total => 200, defer => { map { $_ * 20 => 1 } 1 .. 9 } );
	$c = feed( $COLL_MENU, {}, { id => 6 }, 0, 1 );
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 20, 40, 60, 80 ], '200 cards: 4 later pages in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [ 100, 120, 140, 160 ], '... as they answer, the next 4' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { offset_of($_) } Slim::Networking::SimpleAsyncHTTP->deferred ], [180], '... then the last' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 200, '... 200 rows' );

	fresh();
	route_collection( 7, total => 500 );
	my $list = answer( collection(7) )->{items};
	is( scalar @$list, 200, '500 cards: the first 200 (the cap)' );
	is( $list->[-1]->{name}, 'Program 200', '... to Program 200' );
	is_deeply( [ collection_offsets() ], [ map { $_ * 20 } 0 .. 9 ], '10 pages of 20; nothing at 200' );
};

subtest 'collection menu: the 4 s deadline; a late page is left out (no gap) and used on the next open' => sub {
	fresh();
	route_collection( 8, total => 100, defer => { 40 => 1 } );
	my $c = feed( $COLL_MENU, {}, { id => 8, title => 'Eight' }, 0, 1 );
	is( $c->count, 0, 'waiting for the page at 40' );
	advanceTime(3.9);
	is( $c->count, 0, 'still waiting at 3.9 s' );
	advanceTime(0.1);
	advanceTime(3);    # program names
	is( $c->count, 1, 'answered at the 4 s deadline' );
	is_deeply( names( answer($c)->{items} ), [ map {"Program $_"} 1 .. 40 ], 'pages 0 and 20 only: the page at 60 loaded but comes after the late one (no gap)' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'the late page answers: no second callback' );

	my $again = collection(8);
	is( scalar @{ answer($again)->{items} }, 100, 'the next open: all 100 (every page cached)' );
	is_deeply( [ collection_offsets() ], [ 0, 20, 40, 60, 80 ], '... without a new request' );
};

subtest 'collection menu: a failed or empty page ends the list; the first page\'s error is the menu' => sub {
	fresh();
	route_collection( 9, total => 100, fail => { 60 => 500 } );
	is_deeply( names( answer( collection(9) )->{items} ), [ map {"Program $_"} 1 .. 60 ], 'the page at 60 failed: 60 rows (80 left out too: no gap)' );

	fresh();
	route_collection( 10, total => 100, fail => { 0 => 429 } );
	is_deeply( answer( collection(10) )->{items}, [ { name => $RATE, type => 'text' } ], 'the first page rate-limited: its text row' );
	is_deeply( [ collection_offsets() ], [0], '... and no other request' );

	fresh();
	route_collection( 11, total => 0 );
	is_deeply( answer( collection(11) )->{items}, [ { name => $EMPTY, type => 'text' } ], 'an empty collection: "Nothing here right now"' );
};

subtest 'collection menu: a card on two pages is listed once; the rows are the same on every open' => sub {
	fresh();
	my @cards = map { program_card($_) } 1 .. 30;
	$cards[25] = program_card(3);    # ABC's ranking moved program 3 between the two page loads
	route_collection( 12, cards => \@cards );
	my $first = names( answer( collection(12) )->{items} );
	is( scalar @$first, 29, '30 cards, one of them twice: 29 rows' );
	is( scalar( grep { $_ eq 'Program 3' } @$first ), 1, 'Program 3 once, where it first appears' );
	is_deeply( names( answer( collection(12) )->{items} ), $first, 'opened again: the same rows in the same order (stable ids)' );
};

subtest 'collection menu: program names are looked up only for the rows LMS asks for (+10)' => sub {
	my $lookups = sub { scalar grep { $_->{url} =~ m{/_next/data/.*/listen/programs/p[0-9]+\.json} } requests() };

	fresh();
	route_collection( 15, total => 97 );
	my $c = feed( $COLL_MENU, {}, { id => 15 }, 0, 1 );
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 97, 'no window: 97 rows' );
	cmp_ok( $lookups->(), '>=', 12, 'no window (Material asks for everything): every program\'s name is looked up (4 at a time, ' . $lookups->() . ' by the deadline)' );

	fresh();
	route_collection( 15, total => 97 );
	$c = feed( $COLL_MENU, { index => 50, quantity => 1 }, { id => 15 }, 0, 1 );
	advanceTime(3);
	is( scalar @{ answer($c)->{items} }, 97, 'opening row 50 (index 50, quantity 1): the list is whole (row 50 is Program 51)' );
	is( answer($c)->{items}->[50]->{name}, 'Program 51', '... row 50' );
	advanceTime(30);    # let every lookup that was started finish
	is( $lookups->(), 11, '... and only rows 50..60 (1 + 10) had their names looked up' );
	is_deeply( [ sort map { m{/p([0-9]+)\.json} ? $1 : () } map { $_->{url} } requests() ], [ sort( 51 .. 61 ) ], '... programs 51..61' );

	fresh();
	route_collection( 15, total => 97 );
	$c = feed( $COLL_MENU, { index => 0, quantity => 20 }, { id => 15 }, 0, 1 );
	advanceTime(30);
	is( $lookups->(), 30, 'rows 0..19 (index 0, quantity 20): 30 names (20 + 10)' );
};

subtest 'collection menu: exactly one callback' => sub {
	fresh();
	route_collection( 13, total => 60, defer => { 20 => 1 } );
	my $calls = 0;
	my $dies  = sub { $calls++; die "LMS broke\n" };
	ok( eval { $COLL_MENU->( undef, $dies, {}, { id => 13 }, 0, 1 ); 1 }, 'a callback that dies: nothing escapes' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	advanceTime(10);
	is( $calls, 1, '... called once' );

	fresh();
	route_collection( 14, total => 60 );
	{
		no warnings 'redefine';
		my $menuPage = \&Plugins::ABCListen::Collections::menuPage;
		local *Plugins::ABCListen::Collections::menuPage = sub { die "page broke\n" if $_[1] == 20; goto &$menuPage };
		my $c = collection(14);
		is( $c->count, 1, 'a page request that dies: one callback' );
		is( scalar @{ answer($c)->{items} }, 20, '... the pages before it' );
	}
};

done_testing();
