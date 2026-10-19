#!/usr/bin/perl
# M2: Plugins::ABCListen::Follow, the server-wide follow list in the prefs stub (pref `followed`,
# namespace plugin.abclisten): MyABC->init's default and 'array' validator; follow / unfollow /
# isFollowed / list; path normalisation and de-duplication; the title fallback; refresh keeping
# followedAt; stored keys exactly { path, id, title, image, network, followedAt }; the cap of 200
# (the oldest dropped, INFO log); A-Z by Programs::sortKey; a fresh array on every set; corrupt-pref
# handling; persistence across a stub "restart" (the value round-tripped as LMS's prefs file would);
# each write re-reading the list; programPathFor's table (the same table as O4's "More from").

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
	is_deeply( stored(), [], 'the pref is empty again' );
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
};

subtest 'path spellings normalise to one entry (API::sitePath)' => sub {
	fresh();
	for my $spelling ( "$SCIENCE/", "https://www.abc.net.au$SCIENCE", "http://www.abc.net.au$SCIENCE/", "https://abc.net.au$SCIENCE?utm=x#top", " $SCIENCE " ) {
		$F->follow( { title => 'The Science Show', path => $spelling } );
	}
	is_deeply( paths( @{ stored() } ), [$SCIENCE], 'five spellings: one entry, the canonical path' );
	ok( $F->isFollowed("https://www.abc.net.au$SCIENCE/"), 'isFollowed normalises too' );
	is( $F->unfollow("http://abc.net.au$SCIENCE/"), 1, 'unfollow normalises too' );
	is_deeply( stored(), [], 'gone' );
};

subtest 'title fallback; following again refreshes title, image and network but keeps followedAt' => sub {
	fresh();
	$F->follow( { path => '/listen/programs/lab-notes' } );
	is( stored()->[0]->{title}, 'lab-notes', 'no title: the last path segment' );
	$F->follow( { path => '/listen/programs/blank', title => "  \t" } );
	is( ( $F->list )[0]->{title}, 'blank', 'a blank title: the last path segment' );

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

subtest 'list: A-Z by Programs::sortKey ("The" ignored, accents folded), then title, then path' => sub {
	fresh();
	my @programs = (
		[ 'The Science Show', $SCIENCE ],
		[ 'Hack',             '/triplej/programs/hack' ],
		[ 'Classic Drive',    '/listen/programs/classic-drive' ],
		[ 'Ábc Pacific',      '/pacific/programs/abc-pacific' ],
		[ 'the Inside Sport', '/listen/programs/inside-sport' ],
		[ 'Sci',              '/listen/programs/sci-b' ],
		[ 'Sci',              '/listen/programs/sci-a' ],
	);
	$F->follow( { title => $_->[0], path => $_->[1] } ) for @programs;
	is_deeply(
		[ map { $_->{title} } $F->list ],
		[ 'Ábc Pacific', 'Classic Drive', 'Hack', 'the Inside Sport', 'Sci', 'Sci', 'The Science Show' ],
		'A-Z: the leading "The" ignored, accents folded'
	);
	is_deeply( [ map { $_->{path} } grep { $_->{title} eq 'Sci' } $F->list ], [ '/listen/programs/sci-a', '/listen/programs/sci-b' ], 'equal titles: by path' );
	is( scalar( $F->list ), 7, 'scalar list(): the count' );
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
	is( scalar @{ stored() }, 200, 'still 200 after the 201st' );
	ok( !$F->isFollowed('/listen/programs/p1'), 'the oldest follow (p1, followedAt kept on refresh) was dropped' );
	ok( $F->isFollowed('/listen/programs/p2') && $F->isFollowed('/listen/programs/p201'), 'p2 and the new p201 kept' );
	my @info = infos();
	is( scalar @info, 1, 'one INFO message' );
	like( $info[0], qr{Program 1 \(renamed\) \(/listen/programs/p1\)}, 'it names the dropped program' );

	# 200 follows made in the same second: the new one (first by path) is never the one dropped
	fresh();
	$F->follow( { title => "Program $_", path => "/listen/programs/p$_" } ) for 1 .. 200;
	$F->follow( { title => 'A new program', path => '/listen/programs/a-new' } );
	ok( $F->isFollowed('/listen/programs/a-new'), 'equal followedAt: the new follow is kept' );
	is( scalar @{ stored() }, 200, '... and one older follow dropped' );
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
	];
	my @list = eval { $F->list };
	is( $@, '', 'mixed garbage: list() does not die' );
	is_deeply(
		\@list,
		[ { path => '/triplej/programs/hack', title => 'hack', followedAt => 0 }, { path => $SCIENCE, title => 'The Science Show', id => '2885500', followedAt => 17 } ],
		'non-hashes, entries without a site path and later duplicates dropped; unknown keys ignored; bad values fall back'
	);

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
	my @before = $F->list;

	my $file = JSON::PP->new->canonical->encode( stored() );

	# "restart": a new, empty namespace loaded from the file, then the plugin's init
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
	prefs()->{prefs}->{followed} = JSON::PP->new->decode($file);
	Plugins::ABCListen::OnDemand::_resetProviders();
	Plugins::ABCListen::MyABC->init();
	Plugins::ABCListen::OnDemand::_resetProviders();

	is_deeply( [ $F->list ], \@before, 'the same follows, in the same order, after the restart' );
	ok( $F->isFollowed($SCIENCE) && $F->isFollowed('/triplej/programs/hack'), 'both still followed' );
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

done_testing();
