#!/usr/bin/perl
# Home -> Popular now / Popular in sport (D2): Plugins::ABCListen::Collections->recommendations
# and Plugins::ABCListen::Discover::_recommendationsMenu, offline (SimpleAsyncHTTP stub fails any
# unrouted URL; fake clock): the request (no query string) and 1 h cache; every recommendation
# card goes to OnDemand->episodeItem with its id, docType and duration and no date (cards have no
# cardAttributionPrepared), so rows are named by title, never "1 Jan 1970"; audio and
# audiosegment cards keep their docType; cards without an image get the builder default; other
# card types are skipped; {} / no items / only unsupported cards -> "Nothing here right now";
# HTTP errors -> LOAD_FAILED / RATE_LIMITED; the last-good list after a failure (stale_ok);
# exactly one callback on every path; Home's Popular now link opens the menu.
#
# Fixtures (t/data/discovery/):
#   bff-recommendations-homepagePopularNow.json  GET /core-next/api/recommendations/listen/homepagePopularNow
#       (ai-state/research/abc-samples/ copy, unwrapped from its fixture note: 2 of 24 cards)
#   bff-recommendations-homepageSports.json      GET /core-next/api/recommendations/listen/homepageSports
#       (recorded 2026-10-19 by D2: 4 of 20 cards, 3 audioepisode + 1 audio)
# plus t/data/discovery/nextdata-listen-home.trimmed.json and the F3 search page (buildId build-3afcd04f).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::API;
use Plugins::ABCListen::Collections;
use Plugins::ABCListen::Discover;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $COL         = 'Plugins::ABCListen::Collections';
my $SITE        = 'https://www.abc.net.au';
my $RECS        = "$SITE/core-next/api/recommendations/listen";
my $NEXT        = "$SITE/_next/data/build-3afcd04f";
my $T0          = 1_792_400_000;
my $ICON        = Plugins::ABCListen::Util::ICON;
my $JSON_TYPE   = { 'Content-Type' => 'application/json' };
my $CLIENT      = ABCListenTest::FakeClient->new('00:00:00:00:00:01');
my $MENU        = \&Plugins::ABCListen::Discover::_recommendationsMenu;
my $EPISODE     = \&Plugins::ABCListen::OnDemand::_episodeMenu;
my $LOAD_FAILED = string('PLUGIN_ABCLISTEN_LOAD_FAILED');
my $EMPTY       = string('PLUGIN_ABCLISTEN_EMPTY_COLLECTION');

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- recording episodeItem stub (calls the real builder) ----

my @EPISODE_ITEM;
my $realEpisodeItem = \&Plugins::ABCListen::OnDemand::episodeItem;
{
	no warnings qw(redefine once);
	*Plugins::ABCListen::OnDemand::episodeItem = sub { push @EPISODE_ITEM, { %{ $_[2] } }; goto &$realEpisodeItem };
}

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$COL->_reset;
	@EPISODE_ITEM = ();
	setTime($T0);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json   { JSON::PP->new->utf8->canonical->encode( $_[0] ) }
sub json_file { JSON::PP::decode_json( fixture( $_[0] ) ) }

sub route_recs {
	my $name = shift;
	route( "$RECS/$name", file => "discovery/bff-recommendations-$name.json", headers => $JSON_TYPE );
}

sub route_json {
	my ( $match, $data ) = @_;
	route( $match, code => 200, headers => $JSON_TYPE, content => to_json($data) );
}

sub menu {
	my ( $name, $client ) = @_;
	my $c = collector();
	$MENU->( @_ > 1 ? $client : $CLIENT, $c->cb, {}, $name );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

sub check_names {
	my ( $items, $label ) = @_;
	my $bad = grep { !( defined $_->{name} && !ref $_->{name} && $_->{name} =~ /\S/ && $_->{name} !~ /PLUGIN_ABCLISTEN|1970/ ) } @$items;
	is( $bad, 0, "$label: every item has a readable text name (no token, no 1970 date)" );
}

sub recs_requests { grep {m{/recommendations/}} map { $_->{url} } requests() }

sub audio_card {
	my ( $type, $id, %more ) = @_;
	return { contentUri => "coremedia://$type/$id", cardId => "$id", cardTitle => "Card $id", articleLink => "/listen/programs/show/card-$id/$id", %more };
}

# ---------------------------------------------------------------------------

subtest 'recommendations(): GET recommendations/listen/<name> (no query); title and card refs; 1 h cache' => sub {
	fresh();
	route_recs('homepagePopularNow');

	my $c = collector();
	$COL->recommendations( 'homepagePopularNow', $c->cb );
	is( $c->count, 1, 'one callback' );
	my ($result) = $c->args(0);
	is( $result->{title}, 'This Week’s Most Listened', 'title' );
	my $items = json_file('discovery/bff-recommendations-homepagePopularNow.json')->{items};
	is_deeply( $result->{cards}, [ map { Plugins::ABCListen::API::cardRef($_) } @$items ], 'cards are API::cardRef refs of items[]' );
	is( $result->{stale}, 0, 'not stale' );
	is_deeply( [ recs_requests() ], ["$RECS/homepagePopularNow"], 'GET .../recommendations/listen/homepagePopularNow, no query string' );

	advanceTime(3599);
	$COL->recommendations( 'homepagePopularNow', sub { } );
	is( scalar recs_requests(), 1, 'cached for 1 h' );
	advanceTime(2);
	$COL->recommendations( 'homepagePopularNow', sub { } );
	is( scalar recs_requests(), 2, 'fetched again after 1 h' );

	fresh();
	$c = collector();
	$COL->recommendations( '../collection/x', $c->cb );
	is_deeply( [ $c->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ] ], 'a name that is not letters and digits: LOAD_FAILED, once' );
	$c = collector();
	$COL->recommendations( undef, $c->cb );
	is_deeply( [ $c->calls ], [ [ { error => 'PLUGIN_ABCLISTEN_LOAD_FAILED' } ] ], 'undef: LOAD_FAILED' );
	is( scalar requests(), 0, 'no request' );
};

subtest 'Popular now: every card -> episodeItem (id, docType, duration, no date); rows named by title' => sub {
	fresh();
	route_recs('homepagePopularNow');

	my $c = menu('homepagePopularNow');
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);

	is_deeply(
		[ map { [ @$_{qw(id docType duration date)} ] } @EPISODE_ITEM ],
		[ [ '107238050', 'audioepisode', 2913, undef ], [ '107256246', 'audioepisode', 1140, undef ] ],
		'episodeItem gets each card\'s cardId, docType and duration; date undef (no cardAttributionPrepared)'
	);
	is_deeply( [ map { $_->{path} } @EPISODE_ITEM ], [ '/listen/programs/conversations/mimi-kwa-hong-kong-family-perth/107238050', '/listen/programs/if-youre-listening/a-day-out-at-the-hezbollah-theme-park/107256246' ], 'and its page path' );

	is_deeply(
		names($items),
		[ 'A little girl with a life split in three — how Mimi made it [PART I]', 'A day out at the Hezbollah theme park' ],
		'named by the episode title alone (no date to show; never "1 Jan 1970")'
	);
	is_deeply( [ map { $_->{line2} } @$items ], [ map { Plugins::ABCListen::Util::friendlyDuration($_) } 2913, 1140 ], 'line2 = the duration (Material\'s second line)' );
	is_deeply( [ map { $_->{duration} } @$items ], [ 2913, 1140 ], 'duration key' );
	is_deeply( [ map { $_->{play} } @$items ], [ 'abclisten://episode/107238050', 'abclisten://episode/107256246' ], 'play = abclisten://episode/<cardId> (Jive play action; favourites store it)' );
	is_deeply( [ map { $_->{url} } @$items ], [ $EPISODE, $EPISODE ], 'each opens O2\'s episode menu' );
	like( $items->[0]->{image}, qr{\Ahttps://live-production\.wcms\.abc-cdn\.net\.au/9419a7d446ad3f4620983df5d8d048f1\?.*width=300}, 'artwork from the card' );
	ok( !( grep { exists $_->{description} } @$items ), 'no description key on the rows' );
	check_names( $items, 'Popular now' );
	is( Plugins::ABCListen::Util::getEpisodeMeta(107238050)->{duration}, 2913, 'the meta cache is seeded for O1 (via episodeItem)' );
};

subtest 'Popular in sport: homepageSports -> audioepisode and audio rows (docType audio kept)' => sub {
	fresh();
	route_recs('homepageSports');

	my $items = items_of( menu('homepageSports') );
	is( scalar @$items, 4, 'the 4 recorded cards' );
	is_deeply( [ map { $_->{docType} } @EPISODE_ITEM ], [qw(audioepisode audioepisode audioepisode audio)], 'docTypes: audioepisode x3, audio' );
	is_deeply( [ map { $_->{play} } @$items ], [ map {"abclisten://episode/$_"} qw(107285258 107283010 107281470 107280752) ], 'each plays abclisten://episode/<cardId>' );
	is( $items->[3]->{name}, 'Aussies Abroad: The reality of life on tour for a tennis pro outside the top 100', 'the audio clip is named by its title' );
	is( $items->[3]->{duration}, 1000, 'with its duration' );
	is( ( recs_requests() )[0], "$RECS/homepageSports", 'GET .../recommendations/listen/homepageSports' );
	check_names( $items, 'Popular in sport' );
};

subtest 'audiosegment / missing image / other card types: nothing fabricated' => sub {
	fresh();
	route_json( "$RECS/homepagePopularNow", { title => 'This Week’s Most Listened', items => [
		audio_card( 'audiosegment', 107263018, cardMediaIndicatorPrepared => { duration => 188 } ),
		audio_card( 'audioepisode', 107191228 ),
		{ contentUri => 'coremedia://article/5', cardTitle => 'An article', articleLink => '/news/5' },
		{ contentUri => 'coremedia://video/6', cardTitle => 'A video' },
		{ cardTitle => 'No contentUri' },
		audio_card( 'audiosegment', 107263018 ),
	] } );

	my $items = items_of( menu('homepagePopularNow') );
	is_deeply( names($items), [ 'Card 107263018', 'Card 107191228' ], 'the audiosegment and audioepisode cards; article, video, unparseable and duplicate cards skipped' );
	is( $EPISODE_ITEM[0]->{docType}, 'audiosegment', 'audiosegment keeps its docType (O1 resolves it)' );
	is_deeply( [ map { [ @$_{qw(date image duration programTitle)} ] } @EPISODE_ITEM ], [ [ undef, undef, 188, undef ], [ undef, undef, undef, undef ] ], 'no date, image or programTitle invented; no duration when ABC sends none' );
	is_deeply( [ map { $_->{image} } @$items ], [ $ICON, $ICON ], 'no card image: the builder default (plugin icon)' );
	ok( !exists $items->[1]->{line2}, 'neither date nor duration: no line2' );
	check_names( $items, 'synthetic' );
};

subtest 'nothing listable: {} / no items / only unsupported cards -> "Nothing here right now"' => sub {
	for my $case (
		[ '{}',                     {} ],
		[ 'no items key',           { title => 'Sport' } ],
		[ 'items not a list',       { title => 'Sport', items => 'nope' } ],
		[ 'only unsupported cards', { items => [ { contentUri => 'coremedia://article/1', cardTitle => 'x' }, { contentUri => 'coremedia://person/2' } ] } ],
	) {
		fresh();
		route_json( "$RECS/homepageSports", $case->[1] );
		my $c = menu('homepageSports');
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $EMPTY, type => 'text' } ] } ] ], "$case->[0]: one \"Nothing here right now\" text item, once" );
	}

	fresh();
	route( "$RECS/homepageSports", code => 200, headers => $JSON_TYPE, content => '[]' );
	is_deeply( items_of( menu('homepageSports') ), [ { name => $EMPTY, type => 'text' } ], 'a JSON array: empty text item' );
};

subtest 'errors: LOAD_FAILED / RATE_LIMITED; the last-good list after a failure (stale_ok)' => sub {
	fresh();
	route( "$RECS/homepagePopularNow", code => 500, content => 'down' );
	my $c = menu('homepagePopularNow');
	is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'HTTP 500, nothing cached: one LOAD_FAILED text item, once' );

	fresh();
	route( "$RECS/homepagePopularNow", code => 429, content => 'slow' );
	is_deeply( items_of( menu('homepagePopularNow') ), [ { name => string('PLUGIN_ABCLISTEN_RATE_LIMITED'), type => 'text' } ], '429: RATE_LIMITED text item' );

	fresh();
	route( "$RECS/homepagePopularNow", code => 200, headers => $JSON_TYPE, content => 'not json' );
	is_deeply( items_of( menu('homepagePopularNow') ), [ { name => $LOAD_FAILED, type => 'text' } ], 'bad JSON: LOAD_FAILED' );

	fresh();
	route_recs('homepagePopularNow');
	my $before = names( items_of( menu('homepagePopularNow') ) );
	advanceTime(3601);
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$RECS/homepagePopularNow", code => 503, content => 'down' );
	$c = collector();
	$COL->recommendations( 'homepagePopularNow', $c->cb );
	is( ( $c->args(0) )[0]->{stale}, 1, 'ABC down after the hour: recommendations() serves the last-good list, stale => 1' );
	is_deeply( names( items_of( menu('homepagePopularNow') ) ), $before, 'and the menu shows it' );
	is( scalar recs_requests(), 2, '(one new request each: the failure is not cached)' );
};

subtest 'exactly one callback on every path' => sub {
	fresh();
	route_recs('homepagePopularNow');
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::recommendations = sub { die "engine broke\n" };
		my $c = menu('homepagePopularNow');
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'recommendations() dying: one LOAD_FAILED callback' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Collections::itemsFor = sub { die "items broke\n" };
		my $c = menu('homepagePopularNow');
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'itemsFor dying: one LOAD_FAILED callback' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::OnDemand::episodeItem = sub { die "builder broke\n" };
		my $c = menu('homepagePopularNow');
		is_deeply( [ $c->calls ], [ [ { items => [ { name => $EMPTY, type => 'text' } ] } ] ], 'every builder dying: nothing listable, one callback' );
	}

	fresh();
	my $c = menu(undef);
	is_deeply( [ $c->calls ], [ [ { items => [ { name => $LOAD_FAILED, type => 'text' } ] } ] ], 'a broken passthrough (no name): LOAD_FAILED, no request' );
	is( scalar requests(), 0, 'no request' );

	fresh();
	route_recs('homepagePopularNow');
	my $calls = 0;
	eval { $MENU->( $CLIENT, sub { $calls++; die "LMS callback broke\n" }, {}, 'homepagePopularNow' ); 1 };
	is( $calls, 1, 'a callback that dies is called once, never twice' );

	fresh();
	route_recs('homepagePopularNow');
	$c = menu( 'homepagePopularNow', undef );
	is( scalar @{ items_of($c) }, 2, 'without a client ($client undef): the same rows' );
};

subtest 'Home -> Popular now / Popular in sport open these menus' => sub {
	fresh();
	route( "$NEXT/listen.json", file => 'discovery/nextdata-listen-home.trimmed.json', headers => $JSON_TYPE );
	route_recs('homepagePopularNow');
	route_recs('homepageSports');

	my $root = collector();
	Plugins::ABCListen::Discover::_homeRoot( $CLIENT, $root->cb, {} );
	my ( $popular, $sport ) = grep { $_->{url} && $_->{url} == $MENU } @{ items_of($root) };
	is_deeply( [ $popular->{name}, $sport->{name} ], [ 'Popular now', 'Popular in sport' ], 'Home lists both' );
	is( scalar recs_requests(), 0, 'Home itself fetched no recommendations' );

	my $c = collector();
	$popular->{url}->( $CLIENT, $c->cb, {}, @{ $popular->{passthrough} } );
	is( scalar @{ items_of($c) }, 2, 'Popular now -> the 2 recorded episodes' );
	$c = collector();
	$sport->{url}->( $CLIENT, $c->cb, {}, @{ $sport->{passthrough} } );
	is( scalar @{ items_of($c) }, 4, 'Popular in sport -> the 4 recorded items' );
	is_deeply( [ recs_requests() ], [ "$RECS/homepagePopularNow", "$RECS/homepageSports" ], 'one request each, when opened' );
};

done_testing();
