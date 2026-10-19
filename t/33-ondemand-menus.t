#!/usr/bin/perl
# Plugins::ABCListen::OnDemand (O2 menus and public builders), offline (SimpleAsyncHTTP stub, fake
# clock, server time zone Australia/Sydney): the top-level Programs item (exact keys, weight,
# menuWeights, its place among the other hooks' items); init still calls Episode->init;
# _programsRoot and the network list; programItem / episodeItem exact keys (no on_select, play URL,
# name/line2 formats, image fallbacks, meta-cache writes incl. the programTitle rule); the program
# menu order (header -> provider extras -> episodes -> More) and paging to 250; NO_EPISODES /
# LOAD_FAILED states (restricted audiobooks without a collection: no NO_EPISODES row); the provider
# registry (order, merged program detail, dying / silent / double / non-array providers); the
# episode submenu; readable names everywhere; exactly one callback on every path.
#
# Fixtures: t/data/ondemand/ (see t/32-programs.t for provenance) and the F3 search page
# t/data/foundation/listen-search.trimmed.html (buildId build-3afcd04f). Episode pages for paging
# are generated from the Science Show episode card (250 episodes, newest first).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::Live;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Plugin;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $OD          = 'Plugins::ABCListen::OnDemand';
my $SITE        = 'https://www.abc.net.au';
my $BFF         = "$SITE/core-next/api";
my $EPS         = "$BFF/episodesWithSegments/x";
my $AGG         = "$BFF/programAggregationCollection/x";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $SCIENCE     = '/listen/programs/scienceshow';
my $T0          = 1_792_400_000;    # Mon 19 Oct 2026, 19:53 in Sydney
my $ICON        = Plugins::ABCListen::Util::ICON;
my $WCMS        = 'https://live-production.wcms.abc-cdn.net.au';
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $NO_EPISODES = string('PLUGIN_ABCLISTEN_NO_EPISODES');
my $MORE        = string('PLUGIN_ABCLISTEN_MORE_EPISODES');

my $PROGRAM_MENU = \&Plugins::ABCListen::OnDemand::_programMenu;
my $EPISODE_MENU = \&Plugins::ABCListen::OnDemand::_episodeMenu;
my $MORE_FEED    = \&Plugins::ABCListen::OnDemand::_moreEpisodes;

my $SCIENCE_IMG     = "$WCMS/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862";
my $SCIENCE_IMG_300 = "$WCMS/a9bfe6ad8b283391297dd347dd60de8f?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300";

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- API spy ----

my @API_CALLS;
{
	no warnings 'redefine';
	my $bff      = \&Plugins::ABCListen::API::bff;
	my $nextData = \&Plugins::ABCListen::API::nextData;
	*Plugins::ABCListen::API::bff      = sub { push @API_CALLS, { fn => 'bff',      path => $_[0], query => $_[1] }; goto &$bff };
	*Plugins::ABCListen::API::nextData = sub { push @API_CALLS, { fn => 'nextData', path => $_[0] }; goto &$nextData };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::OnDemand::_resetProviders();
	@API_CALLS = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture("ondemand/$_[0]") ) }
sub offset_of { $_[0] =~ /[?&]offset=([0-9]+)/ ? $1 : undef }
sub size_of   { $_[0] =~ /[?&]size=([0-9]+)/   ? $1 : undef }

sub episode_requests { map { $_->{url} } grep { $_->{url} =~ /episodesWithSegments/ } requests() }

# Call a feed coderef as XMLBrowser does: ($client, $cb, $args, @passthrough). Returns the collector.
sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

# Open an item (link) as XMLBrowser does
sub open_item {
	my ( $item, $client ) = @_;
	return feed( $item->{url}, $client, @{ $item->{passthrough} || [] } );
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

# Every item has a non-empty, readable name and no raw string token.
sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable, non-empty name" );
}

sub text_item { { name => $_[0], type => 'text' } }

# The Science Show program page
sub route_science {
	route( "$NEXT$SCIENCE.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json', headers => $JSON_TYPE );
}

# 250 Science Show episodes, newest first (every 3 days back from Sat 17 Oct 2026, 12:00 Sydney),
# served by offset/size like ABC.
my $TEMPLATE = json_file('nextdata-program-scienceshow.trimmed.json')->{pageProps}->{programCollectionPrepared}->{items}->[0];
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

sub route_episodes {
	my %opt   = @_;
	my $total = defined $opt{total} ? $opt{total} : 250;
	my $match = $opt{collection} || 2885458;

	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$EPS\E\?collectionId=$match&}, sub {
		my ( $offset, $size ) = ( offset_of( $_[0] ), size_of( $_[0] ) );
		my @cards = map { episode_card($_) } grep { $_ < $total } $offset .. $offset + $size - 1;
		return {
			code    => 200,
			headers => $JSON_TYPE,
			content => to_json( { collection => { id => "$match", items => \@cards, pagination => { offset => $offset + 0, size => $size + 0, total => $opt{reportTotal} || $total } } } ),
		};
	} );
}

sub errors_logged   { grep { $_->{level} eq 'ERROR' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }
sub warnings_logged { grep { $_->{level} eq 'WARN' } Slim::Utils::Log->messages( category => 'plugin.abclisten' ) }

my $EPISODE_NAME = qr/\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2}(?: \d{4})? \x{2013} .+/;

# ---------------------------------------------------------------------------

subtest 'top level: one "Programs" link with the programs weight; menuWeights' => sub {
	fresh();
	my $c = collector();
	$OD->menuItems( undef, $c->cb, {} );
	is( $c->count, 1, 'one callback' );

	my ($items) = $c->args(0);
	is_deeply(
		$items,
		[ { name => 'Programs', type => 'link', url => \&Plugins::ABCListen::OnDemand::_programsRoot, image => $ICON, weight => 75 } ],
		'exact keys: name "Programs", type link, url _programsRoot, icon, weight'
	);
	is( $items->[0]->{weight}, Plugins::ABCListen::Util::topWeight('programs'), 'weight = Util::topWeight("programs")' );
	is_deeply( [ $OD->menuWeights ], [ Plugins::ABCListen::Util::topWeight('programs') ], 'menuWeights = (topWeight("programs"))' );
	is( $items->[0]->{name}, string('PLUGIN_ABCLISTEN_PROGRAMS_AZ'), 'from F1\'s top-level token (EN text "Programs")' );
	is( scalar @API_CALLS, 0, 'no network access for the top level' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	$c = collector();
	$OD->menuItems( $client, $c->cb, {} );
	is( ( $c->args(0) )[0]->[0]->{name}, 'Programs', 'with a client too' );
};

subtest 'top level: Programs sorts after the app sections, before Search and My ABC listen' => sub {
	fresh();
	no strict 'refs';
	no warnings qw(redefine once);
	my $top = sub { my $name = shift; return { name => "Top $name", type => 'link', url => 'https://example.test/', weight => Plugins::ABCListen::Util::topWeight($name) } };
	local *Plugins::ABCListen::Discover::menuItems = sub { $_[2]->( [ map { $top->($_) } qw(home podcasts news sport kids audiobooks) ] ) };
	local *Plugins::ABCListen::Search::menuItems   = sub { $_[2]->( [ $top->('search') ] ) };
	local *Plugins::ABCListen::MyABC::menuItems    = sub { $_[2]->( [ $top->('myabc') ] ) };

	my $c = collector();
	Plugins::ABCListen::Plugin::toplevel( undef, $c->cb, { params => {} } );
	my ($result) = $c->args(0);
	is_deeply(
		names( $result->{items} ),
		[ 'Top home', 'Radio', 'Top podcasts', 'Top news', 'Top sport', 'Top kids', 'Top audiobooks', 'Programs', 'Top search', 'Top myabc' ],
		'Home · Radio · Podcasts · News · Sport · Kids listen · Audiobooks · Programs · Search · My ABC listen'
	);
};

subtest 'init still calls Episode->init' => sub {
	no warnings 'redefine';
	my $calls = 0;
	local *Plugins::ABCListen::Episode::init = sub { $calls++ };
	$OD->init;
	is( $calls, 1, 'OnDemand->init calls Plugins::ABCListen::Episode->init once' );
};

subtest '_programsRoot: By network; the network list' => sub {
	fresh();
	my $c = feed( \&Plugins::ABCListen::OnDemand::_programsRoot );
	is( $c->count, 1, 'one callback' );
	is_deeply(
		items_of($c),
		[ { name => 'By network', type => 'link', url => \&Plugins::ABCListen::OnDemand::_networksFeed, image => $ICON } ],
		'one "By network" link (exact keys)'
	);

	$c = open_item( items_of($c)->[0] );
	is( $c->count, 1, 'networks: one callback' );
	my $networks = items_of($c);
	is_deeply(
		names($networks),
		[ 'Radio National', 'triple j', 'Double J', 'ABC Classic', 'ABC Jazz', 'ABC Country', 'ABC Kids listen', 'triple j Unearthed', 'ABC Pacific' ],
		'the 8 networks in table order, then ABC Pacific (OQ4)'
	);
	is_deeply(
		$networks->[0],
		{ name => 'Radio National', type => 'link', url => \&Plugins::ABCListen::OnDemand::_networkFeed, passthrough => ['rn'], image => $ICON },
		'network row: exact keys'
	);
	is( scalar @API_CALLS, 0, 'no network access until a network is opened' );
	check_names( $networks, 'networks' );
};

subtest 'a network: programItem rows; errors as one text item' => sub {
	fresh();
	route( qr{\Q$AGG\E\?collectionId=11474038&}, file => 'ondemand/bff-programAggregationCollection-rn.json', headers => $JSON_TYPE );
	route( qr{\Q$AGG\E\?collectionId=13910480&}, file => 'ondemand/bff-programAggregationCollection-rn-featured.synthetic.json', headers => $JSON_TYPE );

	my $c = feed( \&Plugins::ABCListen::OnDemand::_networkFeed, undef, 'rn' );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);
	is_deeply( names($items), [ 'Émigré Stories', 'God Forbid', 'Health Report', 'The History Showcase' ], 'programs in sortKey order' );

	my ($god) = grep { $_->{name} eq 'God Forbid' } @$items;
	is_deeply(
		$god,
		{
			name        => 'God Forbid',
			line1       => 'God Forbid',
			line2       => 'Radio National',
			type        => 'link',
			url         => $PROGRAM_MENU,
			passthrough => [ {
				title       => 'God Forbid',
				path        => '/listen/programs/godforbid',
				id          => '8132136',
				image       => "$WCMS/9b022a1c24f404a4755241bb86365781?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300",
				description => 'Religion is at the centre of world affairs, but profound questions remain: Why are you here? What happens when you die? Does God matter? God Forbid seeks the answers.',
				presenters  => ['James Carleton'],
				network     => 'Radio National',
			} ],
			image       => "$WCMS/9b022a1c24f404a4755241bb86365781?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300",
			description => 'Religion is at the centre of world affairs, but profound questions remain: Why are you here? What happens when you die? Does God matter? God Forbid seeks the answers.',
		},
		'program row: exact keys (line2 = network)'
	);

	my ($emigre) = grep { $_->{name} eq 'Émigré Stories' } @$items;
	is( $emigre->{image}, $ICON, 'no artwork: the plugin icon' );
	is( $emigre->{line2}, 'Radio National', 'no artwork: still a second line' );
	ok( !exists $emigre->{description}, 'no description: no description key' );
	check_names( $items, 'RN programs' );

	fresh();
	route( qr{\Q$AGG\E}, code => 500 );
	$c = feed( \&Plugins::ABCListen::OnDemand::_networkFeed, undef, 'rn' );
	is( $c->count, 1, 'all collections fail: one callback' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'all collections fail: one LOAD_FAILED text item' );

	fresh();
	route( qr{\Q$AGG\E}, code => 429 );
	$c = feed( \&Plugins::ABCListen::OnDemand::_networkFeed, undef, 'jazz' );
	is_deeply( items_of($c), [ text_item( string('PLUGIN_ABCLISTEN_RATE_LIMITED') ) ], 'rate limited: the RATE_LIMITED text' );

	fresh();
	route( qr{\Q$AGG\E}, content => to_json( { collection => { items => [], pagination => { total => 0 } } } ), headers => $JSON_TYPE );
	$c = feed( \&Plugins::ABCListen::OnDemand::_networkFeed, undef, 'country' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'empty network: the LOAD_FAILED text item' );

	fresh();
	$c = feed( \&Plugins::ABCListen::OnDemand::_networkFeed, undef, 'nope' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'unknown network: LOAD_FAILED' );
};

subtest 'programItem: exact keys, canonical path, optional keys, undef cases' => sub {
	fresh();
	my $input = {
		title       => 'The Science Show',
		path        => 'https://www.abc.net.au/listen/programs/scienceshow/',
		id          => '2885500',
		image       => $SCIENCE_IMG,
		description => 'Science, weekly.',
		network     => 'ABC Radio National',
	};
	my $item = $OD->programItem( undef, $input );
	is_deeply(
		$item,
		{
			name        => 'The Science Show',
			line1       => 'The Science Show',
			line2       => 'ABC Radio National',
			type        => 'link',
			url         => $PROGRAM_MENU,
			passthrough => [ { %$input, path => $SCIENCE } ],
			image       => $SCIENCE_IMG_300,
			description => 'Science, weekly.',
		},
		'exact keys; image resized to 300 px; passthrough with the canonical path'
	);
	is( $input->{path}, 'https://www.abc.net.au/listen/programs/scienceshow/', 'the caller\'s hash is not changed' );
	ok( !exists $item->{on_select} && !exists $item->{play}, 'a browse row (no on_select, no play)' );

	is_deeply(
		$OD->programItem( undef, { title => 'Bare', path => '/triplej/programs/bare/', network => '', description => ' ' } ),
		{ name => 'Bare', line1 => 'Bare', type => 'link', url => $PROGRAM_MENU, passthrough => [ { title => 'Bare', path => '/triplej/programs/bare', network => '', description => ' ' } ], image => $ICON },
		'no image -> icon; empty network/description -> no line2/description'
	);

	for my $variant ( '/listen/programs/godforbid/', 'https://abc.net.au/listen/programs/godforbid', '/kidslisten/programs/godforbid?x=1', '/listen/audiobooks/godforbid-page/' ) {
		( my $expected = $variant ) =~ s{\Ahttps://abc\.net\.au}{};
		$expected =~ s{[?].*|/\z}{}g;
		is( $OD->programItem( undef, { title => 'X', path => $variant } )->{passthrough}->[0]->{path}, $expected, "path '$variant' -> '$expected'" );
	}

	is( $OD->programItem( undef, { title => 'No path' } ),                               undef, 'no path: undef' );
	is( $OD->programItem( undef, { title => 'Off site', path => 'https://example.com/x' } ), undef, 'off-site path: undef' );
	is( $OD->programItem( undef, undef ),                                                 undef, 'not a hash: undef' );
	is( $OD->programItem( undef, { path => '/listen/programs/untitled' } )->{name}, '/listen/programs/untitled', 'no title: named by its path (never empty)' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	my $l4     = $OD->programItem( $client, { title => 'Breakfast', path => '/listen/programs/breakfast', image => $SCIENCE_IMG, description => 'on air' } );
	$l4->{name} = $l4->{line1} = '6:00am Breakfast';    # L4 overrides name/line1 only
	is( $l4->{url}, $PROGRAM_MENU, 'L4-style input with a client: a program row' );
	is( $l4->{passthrough}->[0]->{title}, 'Breakfast', 'overriding name/line1 leaves the passthrough program intact' );
};

subtest 'episodeItem: exact keys, no on_select, play URL, formats, meta-cache writes' => sub {
	fresh();
	my $episode = {
		id           => '107266790',
		docType      => 'audioepisode',
		title        => '72 per cent of UK trees threatened by changing climate',
		description  => 'Palm oil and nickel.',
		path         => "$SITE$SCIENCE/trees/107266790/",
		date         => timegm( 0, 0, 1, 17, 9, 2026 ),
		duration     => 3276,
		image        => $SCIENCE_IMG,
		programTitle => 'The Science Show',
		programId    => '2885500',
		programImage => "$WCMS/other",
		presenters   => ['Robyn Williams'],
		segments     => [ { id => '1' } ],
	};

	my $item = $OD->episodeItem( undef, $episode );
	is_deeply(
		$item,
		{
			name        => "Sat 17 Oct \x{2013} 72 per cent of UK trees threatened by changing climate",
			line1       => '72 per cent of UK trees threatened by changing climate',
			line2       => "Sat 17 Oct \x{B7} 55 min",
			type        => 'link',
			url         => $EPISODE_MENU,
			passthrough => [ { %$episode, path => "$SCIENCE/trees/107266790" } ],
			play        => 'abclisten://episode/107266790',
			image       => $SCIENCE_IMG_300,
			duration    => 3276,
		},
		'exact keys: name "<date> – <title>", line2 "<date> · <duration>", play URL, duration'
	);
	ok( !exists $item->{on_select}, 'no on_select (touch skins open the row)' );
	like( $item->{name}, $EPISODE_NAME, 'name matches the episode row pattern' );

	is_deeply(
		Plugins::ABCListen::Util::getEpisodeMeta('107266790'),
		{
			id           => '107266790',
			docType      => 'audioepisode',
			title        => '72 per cent of UK trees threatened by changing climate',
			description  => 'Palm oil and nickel.',
			path         => "$SCIENCE/trees/107266790",
			date         => timegm( 0, 0, 1, 17, 9, 2026 ),
			duration     => 3276,
			image        => $SCIENCE_IMG,
			programTitle => 'The Science Show',
			programId    => '2885500',
		},
		'meta cache: the contract-3 keys only (no presenters, segments or programImage); canonical path'
	);

	$item = $OD->episodeItem( undef, { id => '1001', title => 'Art from the program', programImage => $SCIENCE_IMG, date => timegm( 0, 0, 1, 20, 0, 2024 ), duration => 1230 } );
	is( $item->{image}, $SCIENCE_IMG_300, 'no episode image: programImage' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('1001')->{image}, $SCIENCE_IMG, 'cached image = programImage' );
	is( $item->{name},  "Sat 20 Jan 2024 \x{2013} Art from the program", 'another year: the year is in the name' );
	is( $item->{line2}, "Sat 20 Jan 2024 \x{B7} 21 min",                 'line2 with the year' );

	$item = $OD->episodeItem( undef, { id => '1002', title => 'No art', duration => 600 } );
	is( $item->{image}, $ICON, 'no image at all: the plugin icon' );
	ok( !exists Plugins::ABCListen::Util::getEpisodeMeta('1002')->{image}, 'no image cached' );
	is( $item->{name},  'No art', 'no date: name = title' );
	is( $item->{line2}, '10 min', 'no date: line2 = duration' );

	$item = $OD->episodeItem( undef, { id => '1003', title => 'No duration', date => timegm( 0, 0, 1, 17, 9, 2026 ) } );
	is( $item->{line2}, 'Sat 17 Oct', 'no duration: line2 = date' );
	ok( !exists $item->{duration}, 'no duration key' );

	$item = $OD->episodeItem( undef, { id => '1004', title => 'Neither' } );
	ok( !exists $item->{line2}, 'no date or duration: no line2' );
	is( $item->{name}, 'Neither', 'still named' );

	is( $OD->episodeItem( undef, { id => '1005', programTitle => 'The Show' } )->{name}, 'The Show', 'no title: programTitle' );
	is( $OD->episodeItem( undef, { id => '1006' } )->{name}, 'ABC listen', 'no title or program: "ABC listen"' );

	$OD->episodeItem( undef, { id => '1007', title => 'Seeded', renditions => [ { url => 'https://example.test/a.mp3', mime => 'audio/mpeg', bitrate => 128 } ], availableTo => 1, downloadAvailableTo => 2, seenAt => 3 } );
	my $meta = Plugins::ABCListen::Util::getEpisodeMeta('1007');
	is_deeply( [ sort keys %$meta ], [ sort qw(id title renditions availableTo downloadAvailableTo seenAt) ], 'optional contract-3 keys (renditions, availability, seenAt) are cached too' );

	is( $OD->episodeItem( undef, { title => 'No id' } ),          undef, 'no id: undef' );
	is( $OD->episodeItem( undef, { id => 'abc', title => 'x' } ), undef, 'non-numeric id: undef' );
	is( $OD->episodeItem( undef, undef ),                         undef, 'not a hash: undef' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('abc'), undef, 'nothing cached for a bad id' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	is( $OD->episodeItem( $client, { id => '1008', title => 'With client' } )->{play}, 'abclisten://episode/1008', 'with a client' );
};

subtest 'program menu (The Science Show): header, 50 episodes newest first, More' => sub {
	fresh();
	route_science();
	route_episodes();

	my $c = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE, network => 'Radio National' } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);

	is( scalar @$items, 54, 'count 54: description, presenters, network, 50 episodes, More (no providers)' );
	is( $items->[0]->{type}, 'textarea', 'item 1: the description as a textarea' );
	like( $items->[0]->{name}, qr/\AThe Science Show gives Australians unique insights/, 'item 1: description text' );
	is_deeply( [ sort keys %{ $items->[0] } ], [qw(name type)], 'textarea: exact keys' );
	is_deeply( $items->[1], text_item('Presented by Robyn Williams, Belinda Smith'), 'item 2: Presented by …' );
	is_deeply( $items->[2], text_item('ABC Radio National'), 'item 3: the network (program page attribution)' );

	my @episodes = @$items[ 3 .. 52 ];
	is( scalar( grep { $_->{type} eq 'link' && $_->{url} == $EPISODE_MENU && $_->{play} =~ m{\Aabclisten://episode/[0-9]+\z} } @episodes ), 50, '50 episode rows: links with a play URL' );
	is( scalar( grep { $_->{name} =~ $EPISODE_NAME } @episodes ), 50, 'episode names: "<Day> <d> <Mon>[ <year>] – <title>"' );
	is( $episodes[0]->{name}, "Sat 17 Oct \x{2013} Episode 0", 'newest first' );
	my @dates = map { $_->{passthrough}->[0]->{date} } @episodes;
	is( scalar( grep { $dates[$_] > $dates[ $_ - 1 ] } 1 .. $#dates ), 0, 'dates non-increasing' );
	is( scalar( grep { $_->{image} } @episodes ), 50, 'every episode row has artwork' );
	is( $episodes[0]->{line2}, "Sat 17 Oct \x{B7} 55 min", 'line2 = date · duration' );

	is_deeply(
		$items->[53],
		{ name => $MORE, type => 'link', url => $MORE_FEED, passthrough => $items->[53]->{passthrough} },
		'item 54: "More episodes…" link'
	);
	is( $items->[53]->{name}, "More episodes\x{2026}", 'More text' );

	is_deeply( [ map { $_->{fn} } @API_CALLS ], [qw(nextData bff)], 'one program page, one episode page' );
	is_deeply( [ episode_requests() ], ["$EPS?collectionId=2885458&offset=0&size=50"], 'episodes 0..49 of collection 2885458' );
	check_names( $items, 'program menu' );

	# More: 4 more pages of 50, the last without a More link (ABC's 250)
	my $more  = $items->[53];
	my $pages = 0;
	my @all   = @episodes;
	while ($more) {
		$c = open_item($more);
		is( $c->count, 1, 'More: one callback' );
		my $page = items_of($c);
		$pages++;
		undef $more;
		$more = pop @$page if $page->[-1]->{url} && $page->[-1]->{url} == $MORE_FEED;
		is( scalar @$page, 50, "More #$pages: 50 episodes" );
		push @all, @$page;
		last if $pages > 6;
	}
	is( $pages, 4, 'four More pages, the 4th (episodes 200..249) has no further More link' );
	is( scalar @all, 250, '250 episodes in all' );
	is( scalar( keys %{ { map { $_->{play} => 1 } @all } } ), 250, 'no episode twice' );
	is_deeply( [ map { offset_of($_) } episode_requests() ], [ 0, 50, 100, 150, 200 ], 'offsets 0, 50, 100, 150, 200; nothing at 250' );
	@dates = map { $_->{passthrough}->[0]->{date} } @all;
	is( scalar( grep { $dates[$_] > $dates[ $_ - 1 ] } 1 .. $#dates ), 0, 'all 250 newest first' );
	like( $all[-1]->{name}, qr/ 2024 \x{2013} Episode 249\z/, 'older episodes carry the year' );
};

subtest 'program menu: programImage, and programTitle/programId only for the program\'s own episodes' => sub {
	fresh();
	route_science();
	my $page = json_file('nextdata-program-scienceshow.trimmed.json')->{pageProps}->{programCollectionPrepared};
	my @cards = @{ $page->{items} };
	push @cards, { %{ $cards[0] }, contentUri => 'coremedia://audioepisode/107000001', cardId => '107000001', articleLink => "$SCIENCE/no-art/107000001", cardImagePrepared => undef };
	route( qr{\Q$EPS\E\?}, content => to_json( { collection => { id => '2885458', items => \@cards, pagination => { offset => 0, size => 50, total => 3 } } } ), headers => $JSON_TYPE );

	my $c     = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } );
	my $items = items_of($c);
	is_deeply( [ map { $_->{play} } grep { $_->{play} } @$items ], [ map {"abclisten://episode/$_"} qw(107266790 107232984 107000001) ], 'all three listed (Lab Notes too) and playable' );
	ok( !( grep { $_->{name} eq $MORE } @$items ), 'total 3: no More link' );

	my $own = Plugins::ABCListen::Util::getEpisodeMeta('107266790');
	is( $own->{programTitle}, 'The Science Show', 'own episode: programTitle cached' );
	is( $own->{programId},    '2885500',          'own episode: programId cached' );

	my $lab = Plugins::ABCListen::Util::getEpisodeMeta('107232984');
	ok( !exists $lab->{programTitle} && !exists $lab->{programId}, 'Lab Notes episode (/listen/programs/lab-notes/…): no programTitle/programId' );
	like( $lab->{image}, qr/6d28416a630b86cc332eb7aa3cf680ba/, 'Lab Notes episode keeps its own artwork' );

	my ($noArt) = grep { ( $_->{play} || '' ) eq 'abclisten://episode/107000001' } @$items;
	is( $noArt->{image}, $SCIENCE_IMG_300, 'episode without artwork: the program image' );
	is( Plugins::ABCListen::Util::getEpisodeMeta('107000001')->{image}, $SCIENCE_IMG, 'cached image: the program image' );
	is( $noArt->{passthrough}->[0]->{programImage}, $SCIENCE_IMG, 'passthrough carries programImage' );
};

subtest 'program menu: empty and error states (one readable text item, never empty)' => sub {
	fresh();
	route( qr{/_next/data/}, error => 'Timed out waiting for data' );
	my $c = feed( $PROGRAM_MENU, undef, { title => 'Broken', path => '/listen/programs/broken' } );
	is( $c->count, 1, 'program page fails: one callback' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'program page fails: one LOAD_FAILED item' );

	fresh();
	route_science();
	route( qr{\Q$EPS\E}, code => 500 );
	$c = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } );
	my $items = items_of($c);
	is( $c->count, 1, 'episodes fail: one callback' );
	is( scalar @$items, 4, 'episodes fail: the header, then one item' );
	is_deeply( $items->[3], text_item($LOAD_FAILED), 'episodes fail: LOAD_FAILED where the episodes would be' );

	fresh();
	route( "$NEXT/listen/programs/quiet.json", file => 'ondemand/nextdata-program-emptydesc.synthetic.json', headers => $JSON_TYPE );
	route_episodes( collection => 90000010, total => 0 );
	$c = feed( $PROGRAM_MENU, undef, { title => 'Quiet', path => '/listen/programs/quiet' } );
	is_deeply( items_of($c), [ text_item('Presented by Kim Quiet'), text_item('ABC Radio National'), text_item($NO_EPISODES) ], 'total 0: header (no textarea for an empty description), then "No episodes available"' );

	fresh();
	route( "$NEXT/listen/programs/minimal.json", file => 'ondemand/nextdata-program-minimal.synthetic.json', headers => $JSON_TYPE );
	$c = feed( $PROGRAM_MENU, undef, { title => 'Minimal', path => '/listen/programs/minimal' } );
	is_deeply( items_of($c), [ text_item($NO_EPISODES) ], 'no episode collection, unrestricted: only "No episodes available" (no description, presenters or network rows)' );
	is( scalar episode_requests(), 0, 'no episode request without a collection' );

	fresh();
	route( "$NEXT/listen/audiobooks/the-dictionary-of-lost-words-page.json", file => 'ondemand/nextdata-program-audiobook.trimmed.json', headers => $JSON_TYPE );
	$c = feed( $PROGRAM_MENU, undef, { title => 'The Dictionary of Lost Words', path => '/listen/audiobooks/the-dictionary-of-lost-words-page' } );
	$items = items_of($c);
	is( $c->count, 1, 'audiobook: one callback' );
	is_deeply( [ map { $_->{type} } @$items ], [qw(textarea text)], 'audiobook (restricted, no collection): description and presenters only' );
	ok( !( grep { $_->{name} eq $NO_EPISODES } @$items ), 'audiobook: no "No episodes available" row' );
	is( $items->[1]->{name}, 'Presented by Pip Williams', 'audiobook: presenters' );

	fresh();
	$c = feed( $PROGRAM_MENU, undef, undef );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'no program passthrough: LOAD_FAILED' );

	fresh();
	route_science();
	route_episodes();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub { die "builder broke\n" };
		$c = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } );
	}
	is( $c->count, 1, 'a builder that dies: one callback' );
	is_deeply( items_of($c)->[-1], text_item($LOAD_FAILED), 'a builder that dies: LOAD_FAILED instead of the episodes' );
	ok( ( grep { $_->{message} =~ /builder broke/ } errors_logged() ), 'logged' );

	my $client = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
	fresh();
	route_science();
	route_episodes();
	$c = feed( $PROGRAM_MENU, $client, { title => 'The Science Show', path => $SCIENCE } );
	is( scalar @{ items_of($c) }, 54, 'with a client: the same menu' );
};

subtest 'registry: order, merged program detail, isolation' => sub {
	fresh();
	route_science();
	route_episodes();

	my @received;
	$OD->registerProgramMenuProvider( sub { push @received, $_[1]; $_[2]->( [ { name => 'Extra A', type => 'text' } ] ) } );
	$OD->registerProgramMenuProvider( sub { $_[1]->{title} = 'mutated'; my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + 2, sub { $cb->( [ { name => 'Extra B', type => 'text' }, 'junk' ] ) } ) } );
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Extra C', type => 'text' } ] ) } );

	my $program = { title => 'Science (row)', path => $SCIENCE, image => 'row-image', network => 'Radio National', custom => 1 };
	my $c       = feed( $PROGRAM_MENU, undef, $program );
	is( $c->count, 0, 'waits for the asynchronous provider' );
	advanceTime(2);
	is( $c->count, 1, 'then one callback' );

	my $items = items_of($c);
	is_deeply( [ map { $_->{name} } @$items[ 3 .. 5 ] ], [ 'Extra A', 'Extra B', 'Extra C' ], 'extras after the header, in registration order (non-hash entries dropped)' );
	like( $items->[6]->{name}, $EPISODE_NAME, 'then the episodes' );
	is( $items->[-1]->{name}, $MORE, 'then More' );
	is( scalar @$items, 57, 'count 54 + 3 extras' );

	is_deeply(
		$received[0],
		{
			title               => 'The Science Show',
			path                => $SCIENCE,
			image               => 'row-image',
			network             => 'Radio National',
			custom              => 1,
			id                  => '2885500',
			template            => 'audio',
			restricted          => 0,
			episodeCollectionId => '2885458',
		},
		'providers get the passthrough program merged with the detail {id, title, template, restricted, episodeCollectionId}'
	);
	is( $program->{title}, 'Science (row)', 'a provider changing its copy changes neither the row nor other providers' );

	# isolation
	fresh();
	route_science();
	route_episodes();
	$OD->registerProgramMenuProvider( sub { die "provider exploded\n" } );
	$OD->registerProgramMenuProvider( sub { $_[2]->('not an array') } );
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Twice 1', type => 'text' } ] ); $_[2]->( [ { name => 'Twice 2', type => 'text' } ] ) } );
	my $late;
	$OD->registerProgramMenuProvider( sub { $late = $_[2] } );
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Good', type => 'text' } ] ) } );

	$c = feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } );
	is( $c->count, 0, 'a silent provider: still waiting' );
	advanceTime(4.9);
	is( $c->count, 0, 'still waiting at 4.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered after 5 s without the silent provider' );
	is_deeply( [ map { $_->{name} } @{ items_of($c) }[ 3, 4 ] ], [ 'Twice 1', 'Good' ], 'dying, non-array and silent providers skipped; a second call back ignored' );
	is( scalar @{ items_of($c) }, 56, 'count 54 + 2 extras' );

	$late->( [ { name => 'Too late', type => 'text' } ] );
	is( $c->count, 1, 'a late call back is ignored (no second answer)' );

	my @errors = map { $_->{message} } errors_logged();
	ok( ( grep {/provider 0 failed: provider exploded/} @errors ), 'dying provider logged' );
	ok( ( grep {/provider 1 called back with a scalar instead of an array ref/} @errors ), 'non-array result logged' );
	ok( ( grep {/provider 3 did not call back within 5 s/} @errors ), 'silent provider logged' );
	ok( ( grep { $_->{message} =~ /provider 2 called back more than once/ } warnings_logged() ), 'double call back logged' );

	is( $OD->registerProgramMenuProvider('not code'), 0, 'registering a non-coderef: 0' );

	# audiobook: a provider adds the chapters link where "No episodes available" would be
	fresh();
	route( "$NEXT/listen/audiobooks/the-dictionary-of-lost-words-page.json", file => 'ondemand/nextdata-program-audiobook.trimmed.json', headers => $JSON_TYPE );
	my $book;
	$OD->registerProgramMenuProvider( sub { $book = $_[1]; $_[2]->( [ { name => 'Chapters', type => 'link', url => 'x' } ] ) } );
	$c = feed( $PROGRAM_MENU, undef, { title => 'The Dictionary of Lost Words', path => '/listen/audiobooks/the-dictionary-of-lost-words-page' } );
	is_deeply( names( items_of($c) )->[-1], 'Chapters', 'audiobook: the provider\'s item ends the menu (no "No episodes available")' );
	is_deeply( [ @$book{qw(id template restricted)} ], [ '106353766', 'audiobook', 1 ], 'audiobook provider input: id, template audiobook, restricted 1' );
	ok( !exists $book->{episodeCollectionId}, 'audiobook provider input: no episodeCollectionId' );

	fresh();
	route( "$NEXT/listen/programs/minimal.json", file => 'ondemand/nextdata-program-minimal.synthetic.json', headers => $JSON_TYPE );
	$OD->registerProgramMenuProvider( sub { $_[2]->( [ { name => 'Follow', type => 'text' } ] ) } );
	$c = feed( $PROGRAM_MENU, undef, { title => 'Minimal', path => '/listen/programs/minimal' } );
	is_deeply( names( items_of($c) ), [ 'Follow', $NO_EPISODES ], 'unrestricted without a collection: extras, then "No episodes available"' );
};

subtest 'episode submenu: Play episode, synopsis, Broadcast line' => sub {
	fresh();
	my $episode = {
		id           => '107266790',
		title        => 'Trees and potatoes',
		description  => 'Palm oil and nickel.',
		date         => timegm( 0, 0, 1, 17, 9, 2026 ),
		duration     => 3276,
		programImage => $SCIENCE_IMG,
	};
	my $c = feed( $EPISODE_MENU, undef, $episode );
	is( $c->count, 1, 'one callback' );
	my $url = 'abclisten://episode/107266790';
	is_deeply(
		items_of($c),
		[
			{
				name            => 'Play episode',
				type            => 'audio',
				on_select       => 'play',
				url             => $url,
				favorites_url   => $url,
				favorites_title => 'Trees and potatoes',
				favorites_icon  => $SCIENCE_IMG_300,
				image           => $SCIENCE_IMG_300,
			},
			{ name => 'Palm oil and nickel.', type => 'textarea' },
			text_item("Broadcast Sat 17 Oct \x{B7} 55 min"),
		],
		'exact items: Play episode (favorites_url = the abclisten:// URL), synopsis textarea, Broadcast line'
	);

	$c = open_item( $OD->episodeItem( undef, { id => '1', title => 'From the row', duration => 120 } ) );
	is_deeply( [ map { [ $_->{type}, $_->{name} ] } @{ items_of($c) } ], [ [ audio => 'Play episode' ], [ text => '2 min' ] ], 'opened from a row; no synopsis, no date: the duration as text' );
	is( items_of($c)->[0]->{image}, $ICON, 'no artwork: the icon' );

	$c = feed( $EPISODE_MENU, undef, { id => '2', title => 'Bare' } );
	is_deeply( names( items_of($c) ), ['Play episode'], 'nothing else known: only Play episode' );

	$c = feed( $EPISODE_MENU, undef, { title => 'No id' } );
	is( $c->count, 1, 'no id: one callback' );
	is_deeply( items_of($c), [ text_item($LOAD_FAILED) ], 'no id: LOAD_FAILED' );

	$c = feed( $EPISODE_MENU, ABCListenTest::FakeClient->new('00:00:00:00:00:01'), $episode );
	is( items_of($c)->[0]->{name}, 'Play episode', 'with a client' );
	check_names( items_of($c), 'episode submenu' );
};

done_testing();
