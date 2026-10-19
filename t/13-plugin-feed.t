#!/usr/bin/perl
# Plugins::ABCListen::Plugin: registration (Radio menu, tag, display name, log category,
# abclisten:// protocol handler), the frozen hook API (init order Live -> OnDemand -> Discover ->
# Search -> MyABC; feed = the hooks' items concatenated in that order, one callback) and its
# failure handling: dying hooks, modules that fail to load, bad callback values, double callbacks,
# hooks that never call back (timeout), concurrent requests and errors in the feed callback
# itself. The weighted top-level order: items from all hooks merged and stable-sorted by their
# `weight` (missing = 100), weights stripped, a failing hook's error item at its declared weight.
# Also the hooks' top level: the "Radio" link (since L1 a feed; its menus are in
# t/21-live-menu.t), and the other hooks' init and declared weights.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use File::Path ();
use File::Temp ();

use Slim::Utils::Strings qw(string);

use ABCListenTest::FakeClient;

use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Util qw(topWeight);
use Plugins::ABCListen::Live;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Discover;
use Plugins::ABCListen::Search;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::Episode;

my @NAMES = qw(Live OnDemand Discover Search MyABC);
my @HOOKS = map {"Plugins::ABCListen::$_"} @NAMES;

my %ORIG         = map { $_ => \&{"Plugins::ABCListen::${_}::menuItems"} } @NAMES;
my %ORIG_WEIGHTS = map { $_ => "Plugins::ABCListen::$_"->can('menuWeights') } @NAMES;

my $ICON = 'plugins/ABCListen/html/images/icon.png';

my $A = { name => 'A', type => 'audio', url => 'https://example.test/a' };
my $B = { name => 'B', type => 'audio', url => 'https://example.test/b' };
my $C = { name => 'C', type => 'link',  url => 'https://example.test/c' };
my $D = { name => 'D', type => 'text' };
my $E = { name => 'E', type => 'search', url => 'https://example.test/e' };

my $ERROR_TEXT = string('PLUGIN_ABCLISTEN_ERROR');
my $ERROR_ITEM = { name => $ERROR_TEXT, type => 'text' };

# Build the top-level feed with the given hook implementations, keyed by hook name (default: the
# real hooks). An undef implementation removes the method, as if the module had failed to load.
# declare => { Name => [weights] | \&code | undef } replaces a hook's menuWeights (default: the
# real one, if any; undef removes it).
# Returns the collector that received the feed callback (unless cb => \&code replaces it).
sub feed {
	my %impl    = @_;
	my %declare = %{ $impl{declare} || {} };

	no strict 'refs';
	no warnings qw(redefine once);
	local *Plugins::ABCListen::Live::menuItems;
	local *Plugins::ABCListen::OnDemand::menuItems;
	local *Plugins::ABCListen::Discover::menuItems;
	local *Plugins::ABCListen::Search::menuItems;
	local *Plugins::ABCListen::MyABC::menuItems;
	local *Plugins::ABCListen::Live::menuWeights;
	local *Plugins::ABCListen::OnDemand::menuWeights;
	local *Plugins::ABCListen::Discover::menuWeights;
	local *Plugins::ABCListen::Search::menuWeights;
	local *Plugins::ABCListen::MyABC::menuWeights;

	for my $name (@NAMES) {
		my $code = exists $impl{$name} ? $impl{$name} : $ORIG{$name};
		*{"Plugins::ABCListen::${name}::menuItems"} = $code if $code;

		my $weights = exists $declare{$name} ? $declare{$name} : $ORIG_WEIGHTS{$name};
		if ( ref $weights eq 'ARRAY' ) {
			my @list = @$weights;
			$weights = sub {@list};
		}
		*{"Plugins::ABCListen::${name}::menuWeights"} = $weights if $weights;
	}

	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( $impl{client}, $impl{cb} || $c->cb, $impl{args} || { params => {} } );
	return $c;
}

# feed() with every hook answering [] except the ones given
sub feed_with {
	my %impl = @_;
	my %all = map { $_ => sync_hook() } @NAMES;
	return feed( %all, %impl );
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub errors_logged {
	return grep { $_->{level} eq 'ERROR' && $_->{category} eq 'plugin.abclisten' } Slim::Utils::Log->messages;
}

sub warnings_logged {
	return grep { $_->{level} eq 'WARN' && $_->{category} eq 'plugin.abclisten' } Slim::Utils::Log->messages;
}

sub sync_hook  { my @items = @_; return sub { $_[2]->( [@items] ) } }
sub never_hook { return sub { } }
sub later_hook { my ( $delay, @items ) = @_; return sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + $delay, sub { $cb->( [@items] ) } ) } }

# Every item (and nested item) has a non-empty, readable name and no raw string token.
sub check_names {
	my ( $items, $label ) = @_;
	for my $item (@$items) {
		ok( defined $item->{name} && $item->{name} =~ /\S/, "$label: item has a non-empty name" );
		unlike( $item->{name} // '', qr/PLUGIN_ABCLISTEN/, "$label: '" . ( $item->{name} // '' ) . "' is not a raw token" );
		check_names( $item->{items}, "$label > $item->{name}" ) if ref $item->{items} eq 'ARRAY';
	}
}

ok( defined $ERROR_TEXT && length $ERROR_TEXT, 'PLUGIN_ABCLISTEN_ERROR has text' );
unlike( $ERROR_TEXT, qr/PLUGIN_ABCLISTEN/, 'PLUGIN_ABCLISTEN_ERROR text is readable, not a token' );

subtest 'registration' => sub {
	resetStubs();

	my @initOrder;
	{
		no strict 'refs';
		no warnings 'redefine';
		local *Plugins::ABCListen::Live::init     = sub { push @initOrder, $_[0] };
		local *Plugins::ABCListen::OnDemand::init = sub { push @initOrder, $_[0] };
		local *Plugins::ABCListen::Discover::init = sub { push @initOrder, $_[0] };
		local *Plugins::ABCListen::Search::init   = sub { push @initOrder, $_[0] };
		local *Plugins::ABCListen::MyABC::init    = sub { push @initOrder, $_[0] };
		Plugins::ABCListen::Plugin->initPlugin();
	}

	is_deeply( \@initOrder, \@HOOKS, 'init called once each, in hook order (Live, OnDemand, Discover, Search, MyABC), as class methods' );

	my $args = $Slim::Plugin::OPMLBased::INIT_ARGS{'Plugins::ABCListen::Plugin'};
	ok( $args, 'OPMLBased initPlugin called' );
	is( $args->{feed}, \&Plugins::ABCListen::Plugin::toplevel, 'feed is the toplevel coderef' );
	is( $args->{tag},  'abclisten', 'tag abclisten (CLI command ["abclisten","items",...])' );
	is( $args->{menu}, 'radios',    'Radio menu' );
	ok( exists $args->{is_app} && !$args->{is_app}, 'is_app => 0 (not My Apps)' );
	like( $args->{weight}, qr/^\d+$/, 'has a weight' );
	is( Plugins::ABCListen::Plugin->menu, 'radios',    'menu class method' );
	is( Plugins::ABCListen::Plugin->tag,  'abclisten', 'tag class method' );

	is( Plugins::ABCListen::Plugin->getDisplayName, 'PLUGIN_ABCLISTEN', 'display name token' );
	is( string( Plugins::ABCListen::Plugin->getDisplayName ), 'ABC listen', 'display name text' );
	is( Plugins::ABCListen::Plugin->playerMenu, 'RADIO', 'player menu RADIO' );

	is_deeply( $Slim::Utils::Log::CATEGORIES{'plugin.abclisten'}, { defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' }, 'log category plugin.abclisten, default WARN' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'initPlugin registers the abclisten:// scheme; the real hooks initialise cleanly' => sub {
	resetStubs();
	is( Slim::Player::ProtocolHandlers->handlerForProtocol('abclisten'), undef, 'not registered before init' );

	my $episodeInit = 0;
	{
		no warnings 'redefine';
		my $orig = \&Plugins::ABCListen::Episode::init;
		local *Plugins::ABCListen::Episode::init = sub { $episodeInit++; $orig->(@_) };
		Plugins::ABCListen::Plugin->initPlugin();
	}

	is( Slim::Player::ProtocolHandlers->handlerForProtocol('abclisten'), 'Plugins::ABCListen::ProtocolHandler', 'abclisten => Plugins::ABCListen::ProtocolHandler' );
	is( Slim::Player::ProtocolHandlers->handlerForURL('abclisten://live/TRIPLEJ'),       'Plugins::ABCListen::ProtocolHandler', 'live URLs resolve to the handler' );
	is( Slim::Player::ProtocolHandlers->handlerForURL('abclisten://episode/107266790'), 'Plugins::ABCListen::ProtocolHandler', 'episode URLs resolve to the handler' );
	is( $episodeInit, 1, 'OnDemand->init calls Episode->init once' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'a failing init is logged and the plugin still loads' => sub {
	resetStubs();
	%Slim::Plugin::OPMLBased::INIT_ARGS = ();

	my @inited;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Live::init     = sub { push @inited, 'Live' };
		local *Plugins::ABCListen::OnDemand::init = sub { die "ondemand init exploded\n" };
		local *Plugins::ABCListen::Discover::init = sub { push @inited, 'Discover' };
		local *Plugins::ABCListen::Search::init   = sub { die "search init exploded\n" };
		local *Plugins::ABCListen::MyABC::init    = sub { push @inited, 'MyABC' };
		ok( eval { Plugins::ABCListen::Plugin->initPlugin(); 1 }, 'initPlugin does not die' ) or diag $@;
	}

	is_deeply( \@inited, [qw(Live Discover MyABC)], 'the other hooks are still initialised, in order' );
	ok( $Slim::Plugin::OPMLBased::INIT_ARGS{'Plugins::ABCListen::Plugin'}, 'menu still registered' );
	is( Slim::Player::ProtocolHandlers->handlerForProtocol('abclisten'), 'Plugins::ABCListen::ProtocolHandler', 'protocol handler still registered' );
	ok( ( grep { $_->{message} =~ /Plugins::ABCListen::OnDemand.*ondemand init exploded/ } errors_logged() ), 'error logged with the hook name and reason' );
	ok( ( grep { $_->{message} =~ /Plugins::ABCListen::Search.*search init exploded/ } errors_logged() ),   'second failure logged too' );
	is( scalar errors_logged(), 2, 'one error per failing hook' );

	# the menu still works: the failed hooks' menuItems are still called
	my $c = feed_with( Live => sync_hook($A), Search => sync_hook($E) );
	is_deeply( items_of($c), [ $A, $E ], 'the menu still lists every hook' );
};

subtest 'a hook module that fails to load (compile error): logged, and its slot becomes an error item' => sub {
	resetStubs();
	%Slim::Plugin::OPMLBased::INIT_ARGS = ();

	# A Discover.pm with a syntax error, found first on @INC, as if the file were broken on disk
	my $root = File::Temp::tempdir( CLEANUP => 1 );
	File::Path::make_path("$root/Plugins/ABCListen");
	open( my $fh, '>', "$root/Plugins/ABCListen/Discover.pm" ) or die "Can't write the broken module: $!";
	print $fh "package Plugins::ABCListen::Discover;\nmy \$broken = ;\n1;\n";
	close $fh;

	local @INC = ( $root, @INC );
	delete local $INC{'Plugins/ABCListen/Discover.pm'};
	local *Plugins::ABCListen::Discover::init;
	local *Plugins::ABCListen::Discover::menuItems;

	my @inited;
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Live::init   = sub { push @inited, 'Live' };
		local *Plugins::ABCListen::Search::init = sub { push @inited, 'Search' };
		local *Plugins::ABCListen::MyABC::init  = sub { push @inited, 'MyABC' };
		ok( eval { Plugins::ABCListen::Plugin->initPlugin(); 1 }, 'initPlugin does not die' ) or diag $@;
	}

	ok( $Slim::Plugin::OPMLBased::INIT_ARGS{'Plugins::ABCListen::Plugin'}, 'menu still registered' );
	ok( ( grep { $_->{message} =~ /Plugins::ABCListen::Discover init failed: .*syntax error/s } errors_logged() ), 'load failure logged with the reason' );
	is_deeply( \@inited, [qw(Live Search MyABC)], 'the other hooks are still initialised' );

	my $c = feed( Live => sync_hook($A), OnDemand => sync_hook($B), Discover => undef, Search => sync_hook($D), MyABC => sync_hook($E), declare => { Discover => undef } );
	is( $c->count, 1, 'callback once' );
	is_deeply( items_of($c), [ $A, $B, $ERROR_ITEM, $D, $E ], 'the broken hook is one error item in its slot; the others keep their order' );
};

subtest 'default feed: "Home", "Radio", "Programs", "Search" and "My ABC listen" links' => sub {
	resetStubs();
	my $c = feed();

	is( $c->count, 1, 'callback called once' );
	my $items = items_of($c);
	is( scalar @$items, 5, 'exactly five top-level items' );
	is( $items->[0]->{name}, 'Home', 'first "Home" (D1; exact keys in t/41)' );
	is( $items->[2]->{name}, 'Programs', 'then "Programs" (O2; exact keys in t/33)' );
	is( $items->[3]->{name}, 'Search',        'then "Search" (D3; exact keys in t/44)' );
	is( $items->[4]->{name}, 'My ABC listen', 'then "My ABC listen" (M2; exact keys in t/52)' );

	my $live = $items->[1];
	is( $live->{name}, 'Radio', 'named "Radio"' );
	is( $live->{name}, string('PLUGIN_ABCLISTEN_RADIO'), 'from PLUGIN_ABCLISTEN_RADIO' );
	is( $live->{type}, 'link', 'a link' );
	is( $live->{image}, $ICON, 'with the plugin icon' );
	ok( !exists $live->{weight}, 'its weight was used for sorting and removed' );
	is_deeply( [ sort keys %$live ], [qw(image name type url)], 'keys: name, type, url, image (since L1 the stations are a feed: t/21-live-menu.t)' );
	is( ref $live->{url}, 'CODE', 'its url is the Radio feed' );
	check_names( $items, 'top level' );
};

subtest 'the hooks: init is harmless; the declared weights' => sub {
	ok( eval { Plugins::ABCListen::Episode->init(); 1 }, 'Episode->init does not die' );

	resetStubs();
	my $c = collector();
	Plugins::ABCListen::Live->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'Live->menuItems calls back once' );
	my ($liveItems) = $c->args(0);
	is( scalar @$liveItems, 1, 'Live->menuItems answers one item' );
	is( $liveItems->[0]->{weight}, Plugins::ABCListen::Util::topWeight('radio'), 'the Radio item carries the "radio" weight (20)' );
	is_deeply( [ Plugins::ABCListen::Live->menuWeights ], [20], 'Live declares the "radio" weight (for its error item)' );
	ok( eval { Plugins::ABCListen::OnDemand->init(); 1 }, 'OnDemand->init does not die' ) or diag $@;
	is_deeply( [ Plugins::ABCListen::OnDemand->menuWeights ], [75], 'OnDemand declares the "programs" weight (O2; its menus are tested in t/33)' );
	ok( eval { Plugins::ABCListen::MyABC->init(); 1 }, 'MyABC->init does not die' ) or diag $@;
	is_deeply( [ Plugins::ABCListen::MyABC->menuWeights ], [90], 'MyABC declares the "myabc" weight (M2; its menus are tested in t/52)' );
	is_deeply( [ Plugins::ABCListen::Discover->menuWeights ], [10], 'Discover declares the "home" weight (D1; its menus are tested in t/41)' );
	ok( eval { Plugins::ABCListen::Search->init(); 1 }, 'Search->init does not die' ) or diag $@;
	is_deeply( [ Plugins::ABCListen::Search->menuWeights ], [80], 'Search declares the "search" weight (D3; its menus are tested in t/44)' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'feed order: Live, OnDemand, Discover, Search, MyABC' => sub {
	resetStubs();
	my $c = feed( Live => sync_hook( $A, $B ), OnDemand => sync_hook($C), Discover => sync_hook(), Search => sync_hook($E), MyABC => sync_hook($D) );
	is( $c->count, 1, 'callback called once' );
	is_deeply( items_of($c), [ $A, $B, $C, $E, $D ], 'concatenated in hook order' );

	my @hookArgs;
	my %spies = map {
		my $name = $_;
		$name => sub { push @hookArgs, [ $name, @_[ 0, 1, 3 ] ]; $_[2]->( [] ) }
	} @NAMES;
	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	$c = feed( %spies, client => $client, args => { params => { menu => 1 } } );
	is_deeply( [ map { $_->[0] } @hookArgs ], \@NAMES, 'menuItems called in hook order' );
	is_deeply( [ map { $_->[1] } @hookArgs ], \@HOOKS, 'called as class methods' );
	is( $hookArgs[0][2], $client, '$client passed through' );
	is_deeply( $hookArgs[4][3], { params => { menu => 1 } }, '$args passed through' );
	is( $c->count, 1, 'all hooks empty: callback once' );
	is_deeply( items_of($c), [], 'all hooks empty: the top level is empty' );
	is( scalar errors_logged(), 0, 'all hooks empty: no error' );
};

subtest 'asynchronous hooks: one callback after all have answered, order kept' => sub {
	resetStubs();
	setTime(1_790_000_000);

	my $c = feed( Live => later_hook( 2, $A ), OnDemand => sync_hook($C), Discover => later_hook( 1, $D ), Search => sync_hook(), MyABC => sync_hook($E) );
	is( $c->count, 0, 'no callback while Live and Discover are still loading' );
	advanceTime(1);
	is( $c->count, 0, 'still waiting for Live' );
	advanceTime(1);
	is( $c->count, 1, 'callback once Live answers' );
	is_deeply( items_of($c), [ $A, $C, $D, $E ], 'hook order kept even though Live answered last' );

	$c = feed( Live => sync_hook($A), OnDemand => later_hook( 5, $B, $C ), Discover => sync_hook(), Search => sync_hook(), MyABC => later_hook( 3, $D ) );
	is( $c->count, 0, 'waiting for OnDemand and MyABC' );
	advanceTime(5);
	is( $c->count, 1, 'callback once both answer' );
	is_deeply( items_of($c), [ $A, $B, $C, $D ], 'order kept' );

	clearTime();
};

subtest 'two concurrent top-level requests keep independent join state' => sub {
	resetStubs();
	setTime(1_790_000_000);

	my $player = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my %first  = ( Live => later_hook( 2, $A ), OnDemand => sync_hook($B), Discover => sync_hook(), Search => sync_hook(), MyABC => sync_hook() );
	my %second = ( Live => later_hook( 1, $C ), OnDemand => later_hook( 3, $D ), Discover => sync_hook(), Search => sync_hook(), MyABC => sync_hook($E) );

	my $c1 = feed( %first,  client => $player );
	my $c2 = feed( %second, client => undef );    # web UI / CLI "-": no client
	my $c3 = feed( %first,  client => undef );

	advanceTime(2);
	is( $c1->count, 1, 'first request answered when its hooks are done' );
	is( $c3->count, 1, 'third request (same hooks, no client) answered too' );
	is( $c2->count, 0, 'second request still waiting for its own OnDemand' );
	is_deeply( items_of($c1), [ $A, $B ], 'first request: its own items' );
	is_deeply( items_of($c3), [ $A, $B ], 'third request: its own items' );

	advanceTime(1);
	is( $c2->count, 1, 'second request answered' );
	is_deeply( items_of($c2), [ $C, $D, $E ], 'second request: its own items, in order' );
	is( $c1->count, 1, 'first request not answered again' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timers left' );

	clearTime();
};

subtest 'a dying hook becomes one error item in its position; the feed still returns' => sub {
	for my $i ( 0 .. $#NAMES ) {
		resetStubs();
		my $dying = $NAMES[$i];
		my %impl = ( Live => sync_hook($A), OnDemand => sync_hook($B), Discover => sync_hook($C), Search => sync_hook($D), MyABC => sync_hook($E) );
		$impl{$dying} = sub { die "$dying broke\n" };

		my @expected = ( $A, $B, $C, $D, $E );
		$expected[$i] = $ERROR_ITEM;

		# no declared weights: the error item keeps its hook-order slot (weighted error items: see
		# 'weights: the error item for a failing hook keeps that hook's position' below)
		my $c = feed( %impl, declare => { map { $_ => undef } @NAMES } );
		is( $c->count, 1, "$dying dies: callback once" );
		is_deeply( items_of($c), \@expected, "$dying dies: error item in its position, the others in order" );
		ok( ( grep { $_->{message} =~ /Plugins::ABCListen::$dying->menuItems failed: $dying broke/ } errors_logged() ), "$dying dies: error logged" );
	}

	resetStubs();
	my $c = feed( map { $_ => sub { die "x\n" } } @NAMES );
	is( $c->count, 1, 'all die: callback once' );
	is_deeply( items_of($c), [ ($ERROR_ITEM) x 5 ], 'all die: one error item each' );

	resetStubs();
	$c = feed_with( Live => undef, OnDemand => sync_hook($B) );    # e.g. Live.pm failed to compile: no menuItems method
	is( $c->count, 1, 'missing hook method: callback once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $B ], 'missing hook method: error item' );
};

subtest 'a hook calling back with undef or a non-array becomes an error item' => sub {
	for my $bad ( [ 'undef', undef ], [ 'hash ref', { items => [$A] } ], [ 'string', 'oops' ], [ 'item hash', $A ], [ 'code ref', sub { } ] ) {
		resetStubs();
		my ( $label, $value ) = @$bad;

		my $c = feed_with( Live => sub { $_[2]->($value) }, OnDemand => sync_hook($C) );
		is( $c->count, 1, "Live calls back with $label: callback once" );
		is_deeply( items_of($c), [ $ERROR_ITEM, $C ], "Live calls back with $label: error item" );
		ok( scalar errors_logged(), "Live calls back with $label: error logged" );

		# MyABC's declared weight (90) would sort its error item before $A (100): undeclared here
		$c = feed_with( Live => sync_hook($A), MyABC => sub { $_[2]->($value) }, declare => { MyABC => undef } );
		is_deeply( items_of($c), [ $A, $ERROR_ITEM ], "MyABC calls back with $label: error item" );
	}

	resetStubs();
	my $c = feed_with( Search => sub { $_[2]->() } );
	is_deeply( items_of($c), [$ERROR_ITEM], 'callback with no arguments: error item' );
};

subtest 'double callbacks are ignored' => sub {
	resetStubs();
	my $c = feed_with( Live => sub { $_[2]->( [$A] ); $_[2]->( [$B] ) }, OnDemand => sync_hook($C) );
	is( $c->count, 1, 'synchronous double call: callback once' );
	is_deeply( items_of($c), [ $A, $C ], 'first answer wins' );
	ok( ( grep { $_->{message} =~ /more than once/ } warnings_logged() ), 'warning logged' );

	resetStubs();
	setTime(1_790_000_000);
	$c = feed_with(
		Live     => sub { my $cb = $_[2]; $cb->( [$A] ); Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->( [$B] ) } ) },
		Discover => sync_hook($C),
	);
	is( $c->count, 1, 'feed answered' );
	advanceTime(2);
	is( $c->count, 1, 'late second call after the feed answered: still one callback' );
	is_deeply( items_of($c), [ $A, $C ], 'items unchanged' );

	$c = feed_with( Live => sub { $_[2]->( [$A] ); die "after callback\n" }, OnDemand => sync_hook($C) );
	is( $c->count, 1, 'hook calls back then dies: callback once' );
	is_deeply( items_of($c), [ $A, $C ], 'hook calls back then dies: its items are kept' );

	$c = feed_with(
		Live     => sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->( [$B] ) } ); die "died after scheduling\n" },
		OnDemand => sync_hook($C),
	);
	is( $c->count, 1, 'hook dies with a callback pending: feed answers at once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'error item for the dead hook' );
	advanceTime(2);
	is( $c->count, 1, 'the late callback from the dead hook is ignored' );

	clearTime();
};

my $T0      = 1_790_000_000;
my $TIMEOUT = Plugins::ABCListen::Plugin::HOOK_TIMEOUT();

subtest 'a hook that never calls back: error item after HOOK_TIMEOUT, the feed still returns' => sub {
	is( $TIMEOUT, 25, 'HOOK_TIMEOUT is 25 s' );
	cmp_ok( $TIMEOUT, '<', 35, 'below the 35 s XMLBrowser feed timeout' );

	resetStubs();
	setTime($T0);
	my $c = feed_with( Live => never_hook(), OnDemand => sync_hook($C) );
	is( $c->count, 0, 'Live silent: no callback yet' );
	is_deeply( [ map { $_->when } Slim::Utils::Timers->pending ], [ $T0 + $TIMEOUT ], 'one timeout timer, HOOK_TIMEOUT from now' );
	advanceTime( $TIMEOUT - 1 );
	is( $c->count, 0, 'Live silent: still waiting 1 s before the timeout' );
	advanceTime(1);
	is( $c->count, 1, 'Live silent: callback once the timer fires' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'Live silent: error item, then the other items' );
	ok( ( grep { $_->{message} =~ /Plugins::ABCListen::Live->menuItems did not call back within 25 s/ } errors_logged() ), 'timeout logged with the hook name' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timers left' );

	resetStubs();
	$c = feed_with( Live => sync_hook( $A, $B ), Search => never_hook() );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'Search silent: callback once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $A, $B ], 'Search silent: its error item at the search weight (80, D3), before the unweighted items' );

	resetStubs();
	$c = feed( map { $_ => never_hook() } @NAMES );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'all silent: callback once' );
	is_deeply( items_of($c), [ ($ERROR_ITEM) x 5 ], 'all silent: one error item each' );
	is( scalar errors_logged(), 5, 'all silent: one error per hook' );

	resetStubs();
	$c = feed_with( Live => later_hook( 3, $A ), MyABC => never_hook() );
	advanceTime(3);
	is( $c->count, 0, 'Live answered, MyABC silent: still waiting' );
	advanceTime( $TIMEOUT - 3 );
	is( $c->count, 1, 'Live answered, MyABC silent: callback at the timeout' );
	# the timeout's error item sorts at MyABC's declared weight (90, M2), before $A (no weight: 100)
	is_deeply( items_of($c), [ $ERROR_ITEM, $A ], 'Live answered, MyABC silent: the error item at MyABC\'s weight' );

	clearTime();
};

subtest 'an answer after the timeout is ignored' => sub {
	resetStubs();
	setTime($T0);

	my $c = feed_with( Live => later_hook( $TIMEOUT + 5, $A ), OnDemand => sync_hook($C) );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'feed answered at the timeout' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'error item for the slow hook' );

	advanceTime(5);
	is( $c->count, 1, 'late answer: still one callback' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'late answer: items unchanged' );
	ok( ( grep { $_->{message} =~ /Plugins::ABCListen::Live->menuItems called back after the 25 s timeout/ } warnings_logged() ), 'late answer: warning logged' );

	resetStubs();
	$c = feed_with( Live => sync_hook($A), Discover => sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + $TIMEOUT + 1, sub { $cb->( [$B] ); $cb->( [$C] ) } ) } );
	advanceTime( $TIMEOUT + 1 );
	is( $c->count, 1, 'late answer given twice: still one callback' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $A ], 'late answer given twice: items unchanged (the error item at Discover\'s "home" weight)' );

	clearTime();
};

subtest 'the timeout timer is cleared when every hook answers in time' => sub {
	resetStubs();
	setTime($T0);

	my $c = feed_with( Live => sync_hook($A), OnDemand => sync_hook($C) );
	is( $c->count, 1, 'synchronous answers: callback at once' );
	is( scalar Slim::Utils::Timers->pending, 0, 'synchronous answers: no timer set' );

	$c = feed_with( Live => later_hook( 2, $A ), OnDemand => later_hook( 3, $C ) );
	is( scalar( grep { $_->when == $T0 + $TIMEOUT } Slim::Utils::Timers->pending ), 1, 'asynchronous answers: timeout timer pending' );
	advanceTime(3);
	is( $c->count, 1, 'asynchronous answers: callback once all answered' );
	is_deeply( items_of($c), [ $A, $C ], 'asynchronous answers: order kept' );
	is( scalar Slim::Utils::Timers->pending, 0, 'asynchronous answers: timeout timer killed' );

	advanceTime( $TIMEOUT * 2 );
	is( $c->count, 1, 'nothing fires later' );
	is( scalar errors_logged(), 0, 'no errors logged' );

	clearTime();
};

subtest 'an error in the feed callback is not blamed on a hook' => sub {
	resetStubs();

	my $calls = 0;
	my $dyingCb = sub { $calls++; die "feed callback broke\n" };

	ok( !eval { feed_with( Live => sync_hook($A), OnDemand => sync_hook($C), cb => $dyingCb ); 1 }, 'synchronous hooks: the error reaches the caller' );
	like( $@, qr/feed callback broke/, 'synchronous hooks: with its message' );
	is( $calls, 1, 'synchronous hooks: callback called once' );
	is( scalar errors_logged(), 0, 'synchronous hooks: no hook failure logged' );

	resetStubs();
	setTime($T0);
	$calls = 0;
	feed_with( Live => later_hook( 1, $A ), OnDemand => sync_hook($C), cb => $dyingCb );
	ok( !eval { advanceTime(1); 1 }, 'asynchronous hook: the error reaches the caller of the hook callback' );
	like( $@, qr/feed callback broke/, 'asynchronous hook: with its message' );
	is( $calls, 1, 'asynchronous hook: callback called once' );
	is( scalar errors_logged(), 0, 'asynchronous hook: no hook failure logged' );
	is( scalar Slim::Utils::Timers->pending, 0, 'asynchronous hook: timeout timer killed' );

	clearTime();
};

# ---- weighted top-level ordering ----

my @TOP = qw(home radio podcasts news sport kids audiobooks programs search myabc);
my %TOP_ITEM = map { $_ => { name => "Top $_", type => 'link', url => "https://example.test/$_" } } @TOP;

# a top-level item for $name carrying the canonical weight (a fresh copy each time)
sub top { my $name = shift; return { %{ $TOP_ITEM{$name} }, weight => topWeight($name) } }

sub names_of { [ map { $_->{name} } @{ items_of(shift) || [] } ] }

subtest 'weights: items from all hooks are merged and sorted by weight' => sub {
	resetStubs();

	my $radio = top('radio');
	my $c = feed(
		Live     => sync_hook( $radio, top('sport') ),
		OnDemand => sync_hook( top('programs'), top('podcasts'), top('audiobooks') ),
		Discover => sync_hook( top('kids'), top('home'), top('news') ),
		Search   => sync_hook( top('search') ),
		MyABC    => sync_hook( top('myabc') ),
	);
	is( $c->count, 1, 'callback once' );
	is_deeply( names_of($c), [ map {"Top $_"} @TOP ], 'interleaved across hooks: home, radio, podcasts, news, sport, kids, audiobooks, programs, search, myabc' );
	is_deeply( items_of($c), [ map { $TOP_ITEM{$_} } @TOP ], 'the items are unchanged apart from the weight key' );
	is( scalar( grep { exists $_->{weight} } @{ items_of($c) } ), 0, 'no item in the feed has a weight key' );
	is( $radio->{weight}, 20, "the hook's own item hash keeps its weight (the feed holds copies)" );

	# async answers are sorted the same way
	setTime($T0);
	$c = feed_with( Live => later_hook( 2, top('radio') ), Discover => sync_hook( top('home') ), MyABC => later_hook( 1, top('myabc') ) );
	advanceTime(2);
	is_deeply( names_of($c), [ 'Top home', 'Top radio', 'Top myabc' ], 'asynchronous answers: sorted by weight' );
	clearTime();
};

subtest 'weights: ties keep hook order, then item order; missing or non-numeric weight is 100' => sub {
	resetStubs();

	my $n = sub { my ( $name, $weight ) = @_; return { name => $name, type => 'text', ( @_ > 1 ? ( weight => $weight ) : () ) } };
	my $c = feed(
		Live     => sync_hook( $n->( 'L1', 50 ), $n->( 'L2', 50 ) ),
		OnDemand => sync_hook( $n->( 'O1', 50 ), $n->('O2') ),
		Discover => sync_hook( $n->( 'D1', 10 ), $n->( 'D2', 'abc' ), $n->( 'D3', undef ), $n->( 'D4', '' ) ),
		Search   => sync_hook( $n->( 'S1', 100 ), $n->( 'S2', 99.5 ) ),
		MyABC    => sync_hook( $n->( 'M1', 150 ), $n->( 'M2', 0 ), $n->( 'M3', -5 ) ),
	);
	is_deeply(
		names_of($c),
		[qw(M3 M2 D1 L1 L2 O1 S2 O2 D2 D3 D4 S1 M1)],
		'stable: equal weights keep hook order then item order; missing, undef, empty and non-numeric weights sort as 100'
	);
	is( scalar( grep { exists $_->{weight} } @{ items_of($c) } ), 0, 'every weight key removed, valid or not' );

	$c = feed_with( Live => sync_hook( $n->('A'), $n->('B') ), MyABC => sync_hook( $n->('C') ) );
	is_deeply( names_of($c), [qw(A B C)], 'no weights at all: plain hook order (as before weights existed)' );
};

subtest 'weights: the error item for a failing hook keeps that hook\'s position' => sub {
	resetStubs();

	# Live (the real hook) declares radio = 20
	my $c = feed_with( Live => sub { die "live broke\n" }, OnDemand => sync_hook( top('podcasts') ), Discover => sync_hook( top('news'), top('home') ) );
	is_deeply( names_of($c), [ 'Top home', $ERROR_TEXT, 'Top podcasts', 'Top news' ], 'dying Live: error item at its declared weight (radio, 20)' );
	is_deeply( items_of($c)->[1], $ERROR_ITEM, 'the error item has no weight key' );

	$c = feed_with( Live => sub { $_[2]->(undef) }, Discover => sync_hook( top('home'), top('news') ) );
	is_deeply( names_of($c), [ 'Top home', $ERROR_TEXT, 'Top news' ], 'Live calls back with undef: same position' );

	$c = feed( Live => sync_hook( top('radio') ), OnDemand => sub { die "x\n" }, Discover => sync_hook( top('home'), top('news') ),
		Search => sync_hook(), MyABC => sync_hook(), declare => { OnDemand => [ 75, 30, 'x', 70 ] } );
	is_deeply( names_of($c), [ 'Top home', 'Top radio', $ERROR_TEXT, 'Top news' ], 'several declared weights: the lowest numeric one (30)' );

	$c = feed_with( Search => sub { die "x\n" }, MyABC => sync_hook( top('myabc'), { name => 'Unweighted', type => 'text' } ), Live => sync_hook( top('radio') ), declare => { Search => undef } );
	is_deeply( names_of($c), [ 'Top radio', 'Top myabc', $ERROR_TEXT, 'Unweighted' ], 'no declared weights: 100, before a later hook\'s unweighted item' );

	$c = feed_with( Live => sub { die "x\n" }, Discover => sync_hook( top('home'), top('myabc') ), declare => { Live => sub { die "weights broke\n" } } );
	is_deeply( names_of($c), [ 'Top home', 'Top myabc', $ERROR_TEXT ], 'menuWeights dies: 100' );

	$c = feed_with( Live => sub { die "x\n" }, Discover => sync_hook( top('myabc') ), declare => { Live => [ 'abc', undef ] } );
	is_deeply( names_of($c), [ 'Top myabc', $ERROR_TEXT ], 'only non-numeric declared weights: 100' );

	$c = feed_with( Live => undef, Discover => sync_hook( top('home'), top('podcasts') ) );
	is_deeply( names_of($c), [ 'Top home', $ERROR_TEXT, 'Top podcasts' ], 'missing menuItems (module did not load) with menuWeights declared: its weight' );

	resetStubs();
	setTime($T0);
	$c = feed_with( Live => never_hook(), OnDemand => sync_hook( top('podcasts') ), Discover => sync_hook( top('home') ) );
	advanceTime($TIMEOUT);
	is_deeply( names_of($c), [ 'Top home', $ERROR_TEXT, 'Top podcasts' ], 'timeout: error item at the silent hook\'s declared weight' );
	clearTime();
};

subtest 'top-level menu names are pre-seeded for every canonical weight' => sub {
	my %names = (
		home       => [ PLUGIN_ABCLISTEN_HOME        => 'Home' ],
		radio      => [ PLUGIN_ABCLISTEN_RADIO       => 'Radio' ],
		podcasts   => [ PLUGIN_ABCLISTEN_PODCASTS    => 'Podcasts' ],
		news       => [ PLUGIN_ABCLISTEN_NEWS        => 'News' ],
		sport      => [ PLUGIN_ABCLISTEN_SPORT       => 'Sport' ],
		kids       => [ PLUGIN_ABCLISTEN_KIDS        => 'Kids listen' ],
		audiobooks => [ PLUGIN_ABCLISTEN_AUDIOBOOKS  => 'Audiobooks' ],
		programs   => [ PLUGIN_ABCLISTEN_PROGRAMS_AZ => 'Programs' ],    # orchestrator decision (O2 #16)
		search     => [ PLUGIN_ABCLISTEN_SEARCH      => 'Search' ],
		myabc      => [ PLUGIN_ABCLISTEN_MY_ABC      => 'My ABC listen' ],
	);
	for my $name (@TOP) {
		my ( $token, $text ) = @{ $names{$name} };
		ok( defined topWeight($name), "'$name' has a weight" );
		is( string($token), $text, "$name: $token is '$text'" );
	}
};

subtest 'the error item is a readable text item (screen readers, hardware displays)' => sub {
	resetStubs();
	my $c = feed_with( Live => sub { die "x\n" } );
	my ($item) = @{ items_of($c) };
	is( $item->{type}, 'text', 'plain text item (no link, no spinner)' );
	is( $item->{name}, $ERROR_TEXT, 'named with the PLUGIN_ABCLISTEN_ERROR text' );
	like( $item->{name}, qr/ABC listen/, 'the text says which menu failed' );
	is_deeply( [ sort keys %$item ], [qw(name type)], 'nothing else' );
	check_names( items_of($c), 'error feed' );
};

done_testing();
