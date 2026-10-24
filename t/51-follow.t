#!/usr/bin/perl
# M2: Plugins::ABCListen::Follow, the server-wide follow list in the prefs stub (pref `followed`,
# namespace plugin.abclisten): MyABC->init's default and 'array' validator; follow / unfollow /
# isFollowed / list / listWithUnfollowed; path normalisation and de-duplication; the title
# fallback; refresh keeping followedAt and its place; stored keys exactly { path, id, title, image,
# network, followedAt } (+ unfollowedAt on a tombstone); follow order (never sorted); tombstones:
# an unfollow keeps the entry at its place for 30 min, a re-follow within that restores it in place
# (followedAt kept), later follows append, expired ones are ignored and dropped on the next write,
# at most 200; the cap of 200 (the oldest becomes a tombstone, INFO log); a fresh array on every
# set; corrupt-pref handling; persistence across a stub "restart" (the value round-tripped as LMS's
# prefs file would), tombstones included; each write re-reading the list; programPathFor's table
# (the same table as O4's "More from"), and (O8) its network-relative episode paths (Hottest 100 ->
# /triplej/hottest-100, the path the A-Z lists, so both follows are one entry).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use JSON::PP ();
use Scalar::Util qw(refaddr);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::ABCListen::Follow;
use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::OnDemand;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'INFO', description => 'PLUGIN_ABCLISTEN' } );

my $F       = 'Plugins::ABCListen::Follow';
my $T0      = 1_792_400_000;
my $SCIENCE = '/listen/programs/scienceshow';
my @KEYS    = sort qw(path id title image network followedAt);

my %SCIENCE_SHOW = (
	title   => 'The Science Show',
	path    => $SCIENCE,
	id      => '2885500',
	image   => 'https://live-production.wcms.abc-cdn.net.au/a9bfe6ad8b283391297dd347dd60de8f?width=300&height=300',
	network => 'Radio National',
);

sub prefs  { preferences('plugin.abclisten') }
sub stored { prefs()->get('followed') }

# Empty the plugin.abclisten namespace in place (Follow and MyABC keep the object they got at load
# time, as in LMS), clear the log and set the clock.
sub fresh {
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
	prefs()->init( { followed => [] } );
	Slim::Utils::Log->resetMessages;
	setTime($T0);
	return;
}

sub paths { [ map { $_->{path} } @_ ] }

# The Followed programs view: [ "<path>", or "<path> (unfollowed)" for a tombstone ], in order.
sub view { [ map { $_->{path} . ( exists $_->{unfollowedAt} ? ' (unfollowed)' : '' ) } $F->listWithUnfollowed ] }

sub infos { map { $_->{message} } grep { $_->{level} eq 'INFO' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

# ---------------------------------------------------------------------------

subtest 'MyABC->init: followed defaults to [] (an existing list is kept) with LMS\'s array validator' => sub {
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };

	my @validators;
	{
		no warnings 'redefine';
		my $orig = \&Slim::Utils::Prefs::Namespace::setValidate;
		local *Slim::Utils::Prefs::Namespace::setValidate = sub { push @validators, [ @_[ 1 .. $#_ ] ]; goto &$orig };
		Plugins::ABCListen::OnDemand::_resetProviders();
		Plugins::ABCListen::MyABC->init();
	}

	is_deeply( stored(), [], 'followed defaults to []' );
	ok( ( grep { ref $_->[0] eq 'HASH' && ( $_->[0]->{validator} || '' ) eq 'array' && $_->[1] eq 'followed' && @$_ == 2 } @validators ), 'setValidate({ validator => "array" }, "followed")' );
	is( prefs()->get('homeState'), '', 'M1\'s homeState default is still set' );

	prefs()->set( followed => [ { path => $SCIENCE, title => 'The Science Show', followedAt => 1 } ] );
	Plugins::ABCListen::MyABC->init();
	is_deeply( paths( $F->list ), [$SCIENCE], 'init keeps an existing follow list' );
	Plugins::ABCListen::OnDemand::_resetProviders();
};

subtest 'follow / isFollowed / list / unfollow' => sub {
	fresh();
	ok( !$F->isFollowed($SCIENCE), 'not followed at first' );
	is_deeply( [ $F->list ], [], 'empty list' );

	my $entry = $F->follow( {%SCIENCE_SHOW} );
	is_deeply( $entry, { %SCIENCE_SHOW, followedAt => $T0 }, 'follow returns the stored entry (followedAt = now)' );
	ok( $F->isFollowed($SCIENCE), 'isFollowed' );
	is_deeply( [ $F->list ], [ { %SCIENCE_SHOW, followedAt => $T0 } ], 'list: the entry' );
	is_deeply( stored(), [ { %SCIENCE_SHOW, followedAt => $T0 } ], 'the pref holds exactly the entry' );

	is( $F->unfollow($SCIENCE), 1, 'unfollow: 1' );
	ok( !$F->isFollowed($SCIENCE), 'no longer followed' );
	is_deeply( [ $F->list ], [], 'list: empty' );
	is_deeply( stored(), [ { %SCIENCE_SHOW, followedAt => $T0, unfollowedAt => $T0 } ], 'the pref keeps a tombstone (unfollowedAt = now)' );
	is_deeply( [ $F->listWithUnfollowed ], stored(), 'listWithUnfollowed: the tombstone' );
};

subtest 'stored keys exactly { path, id, title, image, network, followedAt }; unknown ones absent' => sub {
	fresh();
	$F->follow( { %SCIENCE_SHOW, description => 'About science', template => 'audio', restricted => 0, episodeCollectionId => '2885458', presenters => ['Robyn Williams'], mac => '00:00:00:00:00:01', custom => { x => 1 } } );
	is_deeply( [ sort keys %{ stored()->[0] } ], \@KEYS, 'program detail, player data and other keys are never stored' );

	$F->follow( { title => 'Hack', path => '/triplej/programs/hack' } );
	my ($hack) = grep { $_->{path} eq '/triplej/programs/hack' } @{ stored() };
	is_deeply( [ sort keys %$hack ], [qw(followedAt path title)], 'without id, image or network: stored without them' );

	$F->follow( { title => 'Odd', path => '/listen/programs/odd', id => ['1'], image => { imgSrc => 'x' }, network => '  ' } );
	my ($odd) = grep { $_->{path} eq '/listen/programs/odd' } @{ stored() };
	is_deeply( [ sort keys %$odd ], [qw(followedAt path title)], 'non-scalar or blank values are not stored' );
	ok( !( grep { ref $_ } map { values %$_ } @{ stored() } ), 'every stored value is a plain scalar' );

	$F->unfollow($SCIENCE);
	is_deeply( [ sort keys %{ stored()->[0] } ], [ sort @KEYS, 'unfollowedAt' ], 'a tombstone: the same keys plus unfollowedAt' );
};

subtest 'path spellings normalise to one entry (API::sitePath)' => sub {
	fresh();
	for my $spelling ( "$SCIENCE/", "https://www.abc.net.au$SCIENCE", "http://www.abc.net.au$SCIENCE/", "https://abc.net.au$SCIENCE?utm=x#top", " $SCIENCE " ) {
		$F->follow( { title => 'The Science Show', path => $spelling } );
	}
	is_deeply( paths( @{ stored() } ), [$SCIENCE], 'five spellings: one entry, the canonical path' );
	ok( $F->isFollowed("https://www.abc.net.au$SCIENCE/"), 'isFollowed normalises too' );
	is( $F->unfollow("http://abc.net.au$SCIENCE/"), 1, 'unfollow normalises too' );
	is_deeply( [ $F->list ], [], 'gone' );
};

subtest 'title fallback; following again refreshes title, image and network but keeps followedAt' => sub {
	fresh();
	$F->follow( { path => '/listen/programs/lab-notes' } );
	is( stored()->[0]->{title}, 'lab-notes', 'no title: the last path segment' );
	$F->follow( { path => '/listen/programs/blank', title => "  \t" } );
	is( ( $F->list )[-1]->{title}, 'blank', 'a blank title: the last path segment' );

	fresh();
	$F->follow( { title => 'Science (old)', path => $SCIENCE, image => 'old.jpg', network => 'RN' } );
	setTime( $T0 + 3600 );
	my $entry = $F->follow( {%SCIENCE_SHOW} );
	is( $entry->{followedAt}, $T0, 'followedAt kept' );
	is_deeply( stored(), [ { %SCIENCE_SHOW, followedAt => $T0 } ], 'title, id, image and network refreshed; still one entry' );

	$F->follow( { path => $SCIENCE } );
	is_deeply( stored(), [ { %SCIENCE_SHOW, followedAt => $T0 } ], 'following again without details keeps the known ones' );
};

subtest 'unfollow and follow are idempotent; nothing is written for a no-op unfollow' => sub {
	fresh();
	$F->follow( {%SCIENCE_SHOW} );
	$F->follow( {%SCIENCE_SHOW} );
	is( scalar @{ stored() }, 1, 'following twice: one entry' );

	my $before = refaddr( stored() );
	is( $F->unfollow('/listen/programs/never-followed'), 0, 'unfollowing a program that is not followed: 0' );
	is( refaddr( stored() ), $before, '... and the pref is not written' );
	is( $F->unfollow($SCIENCE), 1, 'unfollow: 1' );
	is( $F->unfollow($SCIENCE), 0, 'unfollow again: 0' );
};

subtest 'no site path: nothing followed' => sub {
	fresh();
	is( $F->follow( { title => 'No path' } ), undef, 'no path: undef' );
	is( $F->follow( { title => 'Elsewhere', path => 'https://example.com/listen/programs/x' } ), undef, 'another host: undef' );
	is( $F->follow( { title => 'Home', path => 'https://www.abc.net.au/' } ), undef, 'the site root: undef' );
	is( $F->follow('not a hash'), undef, 'not a hash: undef' );
	is( $F->follow(undef), undef, 'undef: undef' );
	is_deeply( stored(), [], 'nothing stored' );
	is( $F->isFollowed(undef), 0, 'isFollowed(undef): 0' );
	is( $F->unfollow(undef), 0, 'unfollow(undef): 0' );
};

subtest 'list: follow order (oldest first), never sorted; a refresh keeps its place' => sub {
	fresh();
	my @programs = (
		[ 'The Science Show', $SCIENCE ],
		[ 'Hack',             '/triplej/programs/hack' ],
		[ 'Classic Drive',    '/listen/programs/classic-drive' ],
		[ 'Ábc Pacific',      '/pacific/programs/abc-pacific' ],
		[ 'Sci',              '/listen/programs/sci-b' ],
		[ 'Sci',              '/listen/programs/sci-a' ],
	);
	my $n = 0;
	for (@programs) {
		setTime( $T0 + 10 * $n++ );
		$F->follow( { title => $_->[0], path => $_->[1] } );
	}
	my @order = map { $_->[1] } @programs;
	is_deeply( paths( $F->list ), \@order, 'in the order followed (not A-Z, not by path)' );
	is_deeply( [ map { $_->{followedAt} } $F->list ], [ map { $T0 + 10 * $_ } 0 .. 5 ], '... oldest followedAt first' );
	is( scalar( $F->list ), 6, 'scalar list(): the count' );

	setTime( $T0 + 1000 );
	$F->follow( { title => 'Aardvark (renamed)', path => '/listen/programs/classic-drive' } );
	is_deeply( paths( $F->list ), \@order, 'a refresh (even one that would sort first) keeps its place' );
	is( ( $F->list )[2]->{title}, 'Aardvark (renamed)', '... with the new title' );

	$F->follow( { title => 'Aaa', path => '/listen/programs/aaa' } );
	is_deeply( paths( $F->list ), [ @order, '/listen/programs/aaa' ], 'a new follow is appended, whatever its title' );

	# the same second: still in the order followed
	fresh();
	$F->follow( { title => $_, path => "/listen/programs/$_" } ) for qw(zeta alpha mid);
	is_deeply( paths( $F->list ), [ map {"/listen/programs/$_"} qw(zeta alpha mid) ], 'follows in the same second: in the order followed' );
	is_deeply( paths( $F->listWithUnfollowed ), paths( $F->list ), 'listWithUnfollowed without tombstones: the same as list' );
};

subtest 'tombstones: an unfollow keeps its place for 30 min; a re-follow within that restores it in place' => sub {
	fresh();
	my ( $A, $B, $C, $D, $E ) = map {"/listen/programs/$_"} qw(a b c d e);
	setTime($T0);
	$F->follow( { title => 'A', path => $A } );
	setTime( $T0 + 10 );
	$F->follow( { title => 'B', path => $B } );
	setTime( $T0 + 20 );
	$F->follow( { title => 'C', path => $C } );

	setTime( $T0 + 100 );
	is( $F->unfollow($B), 1, 'unfollow B: 1' );
	ok( !$F->isFollowed($B), 'B is not followed' );
	is_deeply( paths( $F->list ), [ $A, $C ], 'list: A, C (no tombstone)' );
	is_deeply( view(), [ $A, "$B (unfollowed)", $C ], 'listWithUnfollowed: B still at its place' );
	is_deeply( ( $F->listWithUnfollowed )[1], { path => $B, title => 'B', followedAt => $T0 + 10, unfollowedAt => $T0 + 100 }, '... with followedAt and unfollowedAt' );

	setTime( $T0 + 200 );
	$F->follow( { title => 'D', path => $D } );
	is_deeply( view(), [ $A, "$B (unfollowed)", $C, $D ], 'a new follow is appended after the tombstone' );

	my $before = refaddr( stored() );
	is( $F->unfollow($B), 0, 'unfollowing the tombstone again: 0' );
	is( refaddr( stored() ), $before, '... and nothing is written' );

	setTime( $T0 + 100 + 1799 );
	my $entry = $F->follow( { title => 'B (renamed)', path => $B, network => 'RN' } );
	is_deeply( $entry, { path => $B, title => 'B (renamed)', network => 'RN', followedAt => $T0 + 10 }, 're-follow within 30 min: restored with its followedAt, details refreshed' );
	ok( $F->isFollowed($B), '... followed again' );
	is_deeply( view(), [ $A, $B, $C, $D ], '... at its old place' );

	# expiry: 30 min after the unfollow, reads ignore it; the next write drops it
	setTime( $T0 + 3000 );
	$F->unfollow($C);
	setTime( $T0 + 3000 + 1799 );
	is_deeply( view(), [ $A, $B, "$C (unfollowed)", $D ], 'after 29:59: the tombstone is still there' );
	setTime( $T0 + 3000 + 1800 );
	is_deeply( view(), [ $A, $B, $D ], 'after 30 min: gone from listWithUnfollowed' );
	ok( !$F->isFollowed($C), '... and not followed' );
	is( scalar @{ stored() }, 4, '... still in the pref until the next write' );
	$F->follow( { title => 'E', path => $E } );
	is_deeply( paths( @{ stored() } ), [ $A, $B, $D, $E ], 'the next write drops it' );

	# a re-follow after expiry is a new follow: appended, with a new followedAt
	setTime( $T0 + 6000 );
	$F->unfollow($A);
	setTime( $T0 + 6000 + 1800 );
	$entry = $F->follow( { title => 'A', path => $A } );
	is( $entry->{followedAt}, $T0 + 7800, 're-follow after 30 min: a new followedAt' );
	is_deeply( view(), [ $B, $D, $E, $A ], '... appended at the end' );

	# a clock moved back: a tombstone from the "future" lives 30 min either way
	fresh();
	$F->follow( { title => 'A', path => $A } );
	$F->unfollow($A);
	setTime( $T0 - 1799 );
	is_deeply( view(), ["$A (unfollowed)"], 'the clock 29:59 back: still there' );
	setTime( $T0 - 1800 );
	is_deeply( view(), [], 'the clock 30 min back: expired' );
};

subtest 'tombstones: at most 200 (the oldest unfollows dropped)' => sub {
	fresh();
	for my $n ( 1 .. 205 ) {
		setTime( $T0 + $n );
		$F->follow( { title => "P$n", path => "/listen/programs/p$n" } );
		$F->unfollow("/listen/programs/p$n");
	}
	is( scalar @{ stored() }, 200, '205 unfollows: 200 tombstones kept' );
	is( paths( @{ stored() } )->[0], '/listen/programs/p6', 'the five oldest unfollows dropped' );
	is_deeply( [ $F->list ], [], 'nothing followed' );
};

subtest 'cap: the 201st follow drops the oldest followedAt (INFO names it)' => sub {
	fresh();
	for my $n ( 1 .. 200 ) {
		setTime( $T0 + $n );
		$F->follow( { title => "Program $n", path => "/listen/programs/p$n" } );
	}
	is( scalar @{ stored() }, 200, '200 follows kept' );
	is_deeply( [ infos() ], [], 'no INFO yet' );

	# following an already-followed program at the cap drops nothing
	setTime( $T0 + 500 );
	$F->follow( { title => 'Program 1 (renamed)', path => '/listen/programs/p1' } );
	is( scalar @{ stored() }, 200, 'refreshing a follow at the cap drops nothing' );

	setTime( $T0 + 1000 );
	$F->follow( { title => 'Program 201', path => '/listen/programs/p201' } );
	is( scalar( my @l = $F->list ), 200, 'still 200 followed after the 201st' );
	ok( !$F->isFollowed('/listen/programs/p1'), 'the oldest follow (p1, followedAt kept on refresh) was dropped' );
	ok( $F->isFollowed('/listen/programs/p2') && $F->isFollowed('/listen/programs/p201'), 'p2 and the new p201 kept' );
	is_deeply( ( $F->listWithUnfollowed )[0], { path => '/listen/programs/p1', title => 'Program 1 (renamed)', followedAt => $T0 + 1, unfollowedAt => $T0 + 1000 }, 'p1 became a tombstone at its place (no row moves)' );
	is( ( $F->listWithUnfollowed )[-1]->{path}, '/listen/programs/p201', 'p201 appended' );
	my @info = infos();
	is( scalar @info, 1, 'one INFO message' );
	like( $info[0], qr{Program 1 \(renamed\) \(/listen/programs/p1\)}, 'it names the dropped program' );

	# 200 follows made in the same second: the new one (first by path) is never the one dropped
	fresh();
	$F->follow( { title => "Program $_", path => "/listen/programs/p$_" } ) for 1 .. 200;
	$F->follow( { title => 'A new program', path => '/listen/programs/a-new' } );
	ok( $F->isFollowed('/listen/programs/a-new'), 'equal followedAt: the new follow is kept' );
	is( scalar( @l = $F->list ), 200, '... and one older follow dropped' );
	ok( !$F->isFollowed('/listen/programs/p1'), '... the first in the list (p1)' );
};

subtest 'every write sets a fresh array of fresh hashes; earlier values are never changed' => sub {
	fresh();
	$F->follow( {%SCIENCE_SHOW} );
	my $first     = stored();
	my $firstCopy = JSON::PP->new->canonical->encode($first);

	$F->follow( { title => 'Hack', path => '/triplej/programs/hack' } );
	my $second = stored();
	isnt( refaddr($second), refaddr($first), 'follow: a new arrayref' );
	isnt( refaddr( $second->[0] ), refaddr( $first->[0] ), 'follow: new entry hashes' );
	is( JSON::PP->new->canonical->encode($first), $firstCopy, 'the previous array is unchanged' );

	$F->follow( {%SCIENCE_SHOW} );
	isnt( refaddr( stored() ), refaddr($second), 'a refresh: a new arrayref' );

	my $beforeUnfollow = stored();
	$F->unfollow('/triplej/programs/hack');
	isnt( refaddr( stored() ), refaddr($beforeUnfollow), 'unfollow: a new arrayref' );
	is( scalar @$beforeUnfollow, 2, 'the previous array still has both entries' );

	my @list = $F->list;
	$list[0]->{title} = 'changed by a caller';
	is( stored()->[0]->{title}, 'The Science Show', 'list() returns copies' );
};

subtest 'a corrupt pref never dies; it reads clean and the next write stores the clean list' => sub {
	for my $case ( [ 'undef', undef ], [ 'a string', 'not a list' ], [ 'a hash', { path => $SCIENCE } ], [ 'a code ref', sub {1} ] ) {
		fresh();
		prefs()->{prefs}->{followed} = $case->[1];
		my @list = eval { $F->list };
		is( $@, '', "$case->[0]: list() does not die" );
		is_deeply( \@list, [], "$case->[0]: reads as empty" );
		ok( !$F->isFollowed($SCIENCE), "$case->[0]: nothing followed" );
		$F->follow( {%SCIENCE_SHOW} );
		is_deeply( paths( @{ stored() } ), [$SCIENCE], "$case->[0]: the next follow stores a clean list" );
	}

	fresh();
	prefs()->{prefs}->{followed} = [
		'a string',
		undef,
		[ $SCIENCE ],
		{ title => 'No path' },
		{ path => 'https://example.com/listen/programs/x', title => 'Elsewhere' },
		{ path => "https://www.abc.net.au$SCIENCE/", title => 'The Science Show', followedAt => '17', id => '2885500', mac => '00:00:00:00:00:01', password => 'secret' },
		{ path => $SCIENCE, title => 'Duplicate', followedAt => 99 },
		{ path => '/triplej/programs/hack', title => [ 'Hack' ], followedAt => 'yesterday', image => { a => 1 } },
		{ path => '/listen/programs/bad-tombstone', title => 'Bad', followedAt => 5, unfollowedAt => 'soon' },
		{ path => '/listen/programs/ref-tombstone', title => 'Ref', followedAt => 5, unfollowedAt => [$T0] },
		{ path => '/listen/programs/old-tombstone', title => 'Old', followedAt => 5, unfollowedAt => $T0 - 1800 },
	];
	my @list = eval { $F->list };
	is( $@, '', 'mixed garbage: list() does not die' );
	is_deeply(
		\@list,
		[ { path => $SCIENCE, title => 'The Science Show', id => '2885500', followedAt => 17 }, { path => '/triplej/programs/hack', title => 'hack', followedAt => 0 } ],
		'non-hashes, entries without a site path and later duplicates dropped; unknown keys ignored; bad values fall back; stored order'
	);
	is_deeply( paths( $F->listWithUnfollowed ), paths(@list), 'tombstones with a bad or expired unfollowedAt: expired' );

	$F->unfollow('/listen/programs/not-there');
	is( ref stored()->[0], '', 'a no-op unfollow does not rewrite it' );

	$F->follow( { title => 'Classic Drive', path => '/listen/programs/classic-drive' } );
	is_deeply(
		stored(),
		[
			{ path => $SCIENCE, title => 'The Science Show', id => '2885500', followedAt => 17 },
			{ path => '/triplej/programs/hack', title => 'hack', followedAt => 0 },
			{ path => '/listen/programs/classic-drive', title => 'Classic Drive', followedAt => $T0 },
		],
		'the next write stores only clean entries (no player data, no secrets)'
	) or diag explain stored();
};

subtest 'persistence across a stub restart (the pref round-tripped like LMS\'s prefs file)' => sub {
	fresh();
	$F->follow( {%SCIENCE_SHOW} );
	setTime( $T0 + 60 );
	$F->follow( { title => 'Hack', path => '/triplej/programs/hack', network => 'triple j' } );
	$F->follow( { title => 'Classic Drive', path => '/listen/programs/classic-drive' } );
	$F->unfollow('/triplej/programs/hack');
	my @before = $F->listWithUnfollowed;
	is( scalar @before, 3, 'two follows and a tombstone' );

	my $file = JSON::PP->new->canonical->encode( stored() );

	# "restart": a new, empty namespace loaded from the file, then the plugin's init
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
	prefs()->{prefs}->{followed} = JSON::PP->new->decode($file);
	Plugins::ABCListen::OnDemand::_resetProviders();
	Plugins::ABCListen::MyABC->init();
	Plugins::ABCListen::OnDemand::_resetProviders();

	is_deeply( [ $F->listWithUnfollowed ], \@before, 'the same follows and tombstone, in the same order, after the restart' );
	ok( $F->isFollowed($SCIENCE) && $F->isFollowed('/listen/programs/classic-drive'), 'both still followed' );
	ok( !$F->isFollowed('/triplej/programs/hack'), 'the tombstone is not' );
};

subtest 'each write re-reads the list (another UI\'s write is never lost)' => sub {
	fresh();
	$F->follow( {%SCIENCE_SHOW} );

	# another player or UI writes in between (LMS runs one request at a time)
	prefs()->set( followed => [ @{ stored() }, { path => '/triplej/programs/hack', title => 'Hack', followedAt => $T0 } ] );

	$F->follow( { title => 'Classic Drive', path => '/listen/programs/classic-drive' } );
	is_deeply( [ sort @{ paths( @{ stored() } ) } ], [ sort '/listen/programs/classic-drive', '/triplej/programs/hack', $SCIENCE ], 'all three kept' );
};

subtest 'class-method and plain-function calls' => sub {
	fresh();
	Plugins::ABCListen::Follow::follow( {%SCIENCE_SHOW} );
	ok( Plugins::ABCListen::Follow::isFollowed($SCIENCE), 'plain isFollowed' );
	is( scalar( my @l = Plugins::ABCListen::Follow::list() ), 1, 'plain list' );
	is( Plugins::ABCListen::Follow::programPathFor("$SCIENCE/x/1"), $SCIENCE, 'plain programPathFor' );
	is( Plugins::ABCListen::Follow::unfollow($SCIENCE), 1, 'plain unfollow' );
};

subtest 'programPathFor: the program of an episode path (same table as O4)' => sub {
	my @table = (
		[ '/listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790',                            '/listen/programs/scienceshow' ],
		[ '/listen/programs/scienceshow/some-success-with-palm-oil-nickel-mines-the-next-challenge/107277426', '/listen/programs/scienceshow', 'a segment' ],
		[ '/listen/programs/classic-drive/classic-drive/107174638',                                            '/listen/programs/classic-drive' ],
		[ '/listen/programs/lab-notes/lab-notes-when-astronomers-make-mistakes/107232984',                     '/listen/programs/lab-notes' ],
		[ '/triplej/programs/hack/hack-15-october/107400001',                                                  '/triplej/programs/hack' ],
		[ '/kidslisten/programs/bedtime-stories/the-gruffalo/107500001',                                       '/kidslisten/programs/bedtime-stories' ],
		[ '/listen/audiobooks/the-dictionary-of-lost-words-page/chapter-1/106353760',                          '/listen/audiobooks/the-dictionary-of-lost-words-page' ],
		[ 'https://www.abc.net.au/listen/programs/scienceshow/x/107266790/?utm=1',                             '/listen/programs/scienceshow', 'an absolute URL' ],
		[ '/listen/programs/scienceshow',                                                                      '/listen/programs/scienceshow', 'the program path itself' ],
		[ '/listen/programs',                                                                                   undef, 'too short' ],
		[ '/listen/programs/',                                                                                  undef, 'too short (trailing /)' ],
		[ '/listen',                                                                                            undef, 'too short' ],
		[ '/',                                                                                                  undef, 'the root' ],
		[ '/listen/radionational/programs',                                                                     undef, 'a network\'s programs page' ],
		[ '/listen/live/triplej',                                                                               undef, 'a live page' ],
		[ '/news/2026-10-19/a-news-story/107600001',                                                            undef, 'news' ],
		[ '/listen/programsx/foo/1',                                                                            undef, 'not a /programs/ segment' ],
		[ 'https://example.com/listen/programs/x/y/1',                                                          undef, 'another host' ],
		[ 'listen/programs/x/y/1',                                                                              undef, 'not a site path' ],
		[ '',                                                                                                   undef, 'empty' ],
		[ undef,                                                                                                undef, 'undef' ],
		[ ['/listen/programs/x/y/1'],                                                                           undef, 'a reference' ],
	);
	for my $row (@table) {
		my ( $in, $want, $label ) = @$row;
		is( $F->programPathFor($in), $want, ( $label || ( defined $in ? $in : 'undef' ) ) . ' -> ' . ( defined $want ? $want : 'undef' ) );
	}
};

subtest 'programPathFor (O8): episodes of a network-relative program (Hottest 100) -> the path the A-Z lists it under' => sub {
	my @table = (
		[ '/triplej/hottest-100/hottest-100-25---1/106246016',                               '/triplej/hottest-100', 'a Hottest 100 episode' ],
		[ 'https://www.abc.net.au/triplej/hottest-100/hottest-100-50---26/106246024',        '/triplej/hottest-100', 'an absolute URL' ],
		[ '/listen/doublej/summer-mornings/summer-mornings-1-jan/107000001',                 '/listen/doublej/summer-mornings', 'under /listen/doublej' ],
		[ '/triplej/programs/hottest-100/hottest-100-25---1/106246016',                      '/triplej/programs/hottest-100', 'the /programs/ rule first, unchanged' ],
		[ '/triplej/hottest-100',                                                            undef, 'the program path itself' ],
		[ '/triplej/hottest-100/hottest-100-25---1',                                         undef, 'no episode id' ],
		[ '/listen/radionational/archived/summerschool/chas-licciardello/7099490',           undef, 'an archived program\'s page' ],
		[ '/listen/radionational/robyn-williams/2913842',                                    undef, 'a presenter page' ],
		[ '/listen/notanetwork/a-show/an-episode/1',                                         undef, 'under no network' ],
	);
	for my $row (@table) {
		my ( $in, $want, $label ) = @$row;
		is( $F->programPathFor($in), $want, "$label -> " . ( defined $want ? $want : 'undef' ) );
	}

	# following from an episode and from the A-Z row: one entry
	fresh();
	my $path = $F->programPathFor('/triplej/hottest-100/hottest-100-25---1/106246016');
	$F->follow( { title => 'Hottest 100', path => $path } );
	ok( $F->isFollowed('/triplej/hottest-100'), 'followed from an episode: the A-Z row\'s path (/triplej/hottest-100) is followed' );
	is_deeply( [ map { $_->{path} } $F->list ], ['/triplej/hottest-100'], '... one entry' );
	ok( !$F->isFollowed('/triplej/programs/hottest-100'), '... under the canonical path, not the 308 target' );
};

done_testing();
