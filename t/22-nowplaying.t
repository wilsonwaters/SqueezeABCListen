#!/usr/bin/perl
# Plugins::ABCListen::NowPlaying (offline, fake clock): parsing the RN and TRIPLEJ_PERTH "now" and the
# RN "next" fixtures (title, epochs, presenters, the 580 px srcSet image, programPath); synthetic
# empty/off-air bodies, missing presenters/image/link, entities and whitespace, odd start/end; the
# cache TTL (until the program's end, clamped 60 s - 15 min; 60 s for missing/past/inconsistent ends;
# "next" until its start); the 60 s negative cache for HTTP errors, 404, 429, timeouts and bad JSON,
# logged at WARN once per run of failures; `null` and {} as "nothing on air"; coalescing; at most
# 6 requests at a time; cached/lastGood semantics; programNext only on demand; timeSlot in local
# time (also across midnight); and exactly one callback on every path.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();
use POSIX ();

use Slim::Utils::Log;

use Plugins::ABCListen::NowPlaying;
use Plugins::ABCListen::Util qw(parseISO8601);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $NP  = 'Plugins::ABCListen::NowPlaying';
my $BFF = 'https://www.abc.net.au/core-next/api/';

my $RN_START = parseISO8601('2026-10-19T07:00:00+00:00');    # 6:00pm AEDT
my $RN_END   = parseISO8601('2026-10-19T08:00:00+00:00');

my $RN_580 = 'https://resize.abcradio.net.au/KYPnLYzMajKvohTSDh2eooeqsU0=/580x580/center/middle/https%3A%2F%2Fwww.abc.net.au%2Fradio%2Fimages%2Fprograms-2026%2FTheRadioNationalHour_3000x3000.jpg';

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub reset_all {
	resetStubs();
	$NP->_reset();
	setTime( $RN_START + 1800 );    # 6:30pm AEDT, half way through The Radio National Hour
	return;
}

sub epg_url { my ( $id, $variant ) = @_; return "${BFF}epgNowPlaying/$id/" . ( $variant || 'now' ) . '?imageRatio=1x1' }

sub epg_requests {
	my $re = shift || qr{/epgNowPlaying/};
	return scalar grep { $_->{url} =~ $re } requests();
}

sub fixture_json { JSON::PP->new->utf8->decode( fixture(shift) ) }

# A synthetic epgNowPlaying body.
sub epg {
	my %p = @_;
	my %body = (
		title       => $p{title},
		start       => $p{start},
		end         => $p{end},
		variant     => 'now',
		papiServiceId => $p{id} || 'RN',
		exists $p{presenters} ? ( preparedPresenters => [ map { { id => 'x', names => { full => $_ } } } @{ $p{presenters} } ] ) : (),
		exists $p{image}      ? ( preparedImage => $p{image} ) : (),
		exists $p{link}       ? ( programLink => $p{link} ) : (),
	);
	delete $body{$_} for grep { !defined $body{$_} } keys %body;
	return JSON::PP->new->utf8->canonical->encode( \%body );
}

sub iso { POSIX::strftime( '%Y-%m-%dT%H:%M:%S+00:00', gmtime(shift) ) }

sub now_cb {
	my $id = shift;
	my $c  = collector();
	$NP->programNow( $id, $c->cb );
	return $c;
}

# ---- parsing ----

subtest 'parse: the RN and TRIPLEJ_PERTH "now" fixtures, RN "next"' => sub {
	my $rn = $NP->parse( fixture_json('live/bff-epgNowPlaying-RN-now.json'), 'RN' );
	is_deeply(
		$rn,
		{
			serviceId   => 'RN',
			title       => 'The Radio National Hour',
			start       => $RN_START,
			end         => $RN_END,
			presenters  => 'Fran Kelly',
			image       => $RN_580,
			programPath => '/listen/programs/the-radio-national-hour',
		},
		'RN: title, epochs, presenters, the 580 px image, programPath'
	);
	is( $rn->{end} - $rn->{start}, 3600, 'RN: one hour' );

	my $perth = $NP->parse( fixture_json('live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json'), 'TRIPLEJ_PERTH' );
	is( $perth->{title},       'Drive',                                  'TRIPLEJ_PERTH: its own program' );
	is( $perth->{presenters},  'Jordan & Luka',                          '"Jordan & Luka" is one presenter' );
	is( $perth->{programPath}, '/triplej/programs/drive',                'programPath: trailing / dropped' );
	is( $perth->{start},       parseISO8601('2026-10-19T04:00:00Z'),     'start epoch' );
	is( $perth->{end},         parseISO8601('2026-10-19T06:30:00Z'),     'end epoch' );
	like( $perth->{image}, qr{\Ahttps://resize\.abcradio\.net\.au/[^/]+=/580x580/}, 'the 580 px srcSet entry' );
	is( $perth->{serviceId}, 'TRIPLEJ_PERTH', 'serviceId' );

	my $next = $NP->parse( fixture_json('live/bff-epgNowPlaying-RN-next.json'), 'RN' );
	is( $next->{title}, 'ABC News Daily and Radio National Hour Highlights', 'RN next: title' );
	is( $next->{presenters}, undef, 'empty preparedPresenters: presenters undef' );
	like( $next->{image}, qr{/580x580/}, 'next: 580 px image' );
};

subtest 'parse: empty, odd and missing fields' => sub {
	is( $NP->parse( {}, 'RN' ),                           undef, '{} -> undef' );
	is( $NP->parse( undef, 'RN' ),                        undef, 'undef -> undef' );
	is( $NP->parse( [ { title => 'x' } ], 'RN' ),         undef, 'an array -> undef' );
	is( $NP->parse( { start => '2026-10-19T07:00:00Z' } ), undef, 'no title -> undef' );
	is( $NP->parse( { title => " \n\t " } ),              undef, 'a blank title -> undef' );
	is( $NP->parse( { title => { a => 1 } } ),            undef, 'a non-text title -> undef' );

	my $p = $NP->parse(
		{
			title              => "  Q&amp;A &#8211;\n  Late&nbsp;Night  ",
			preparedPresenters => [ { names => { full => ' Phillip&nbsp;Adams ' } }, { names => {} }, 'junk', { names => { full => 'Jo &amp; Co' } } ],
			start              => 'not a date',
			programLink        => 'https://www.triplejunearthed.com/x',
			preparedImage      => { imgSrc => 'https://resize.abcradio.net.au/sig=/100x100/center/middle/x.jpg' },
		},
		'RN'
	);
	is( $p->{title},       "Q&A \x{2013} Late Night",   'entities decoded, whitespace collapsed and trimmed' );
	is( $p->{presenters},  'Phillip Adams, Jo & Co',    'presenters decoded, empty ones skipped, joined with ", "' );
	is( $p->{start},       undef,                       'an unparseable start -> undef' );
	is( $p->{end},         undef,                       'a missing end -> undef' );
	is( $p->{programPath}, undef,                       'programLink off www.abc.net.au -> undef' );
	is( $p->{image}, 'https://resize.abcradio.net.au/sig=/100x100/center/middle/x.jpg', 'no srcSet: imgSrc' );

	$p = $NP->parse( { title => 'BBC World', preparedImage => undef, preparedPresenters => [] }, 'NEWS' );
	is_deeply( [ @{$p}{qw(presenters image programPath)} ], [ undef, undef, undef ], 'NEWS-like: no presenters, image (null) or link' );

	my $long = 'A' x 500;
	is( $NP->parse( { title => $long } )->{title}, $long, 'very long titles are not truncated' );
};

# ---- fetching and the cache ----

subtest 'programNow: the request, the cache until the end (clamped), synchronous hits' => sub {
	reset_all();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json' );

	my $c = now_cb('RN');
	is( $c->count, 1, 'one callback' );
	is( ( $c->args(0) )[0]->{title}, 'The Radio National Hour', 'the program' );
	is_deeply( [ map { $_->{url} } requests() ], [ epg_url('RN') ], 'GET epgNowPlaying/RN/now?imageRatio=1x1' );

	advanceTime(899);
	$c = now_cb('RN');
	is( $c->count, 1, 'within 15 min: answered at once' );
	is( epg_requests(), 1, '... from the cache (no request); 30 min to the end is clamped to 15 min' );

	advanceTime(1);
	now_cb('RN');
	is( epg_requests(), 2, 'after 15 min: a new request' );

	for my $case ( [ 'end in 90 s' => $RN_END - 90, 90 ], [ 'end in 30 s' => $RN_END - 30, 60 ], [ 'end passed' => $RN_END + 600, 60 ] ) {
		my ( $label, $time, $ttl ) = @$case;
		reset_all();
		setTime($time);
		route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json' );
		now_cb('RN');
		advanceTime( $ttl - 1 );
		now_cb('RN');
		is( epg_requests(), 1, "$label: cached for $ttl s" );
		advanceTime(1);
		now_cb('RN');
		is( epg_requests(), 2, "$label: refreshed after $ttl s" );
	}

	for my $case ( [ 'no end' => epg( title => 'X', start => iso($RN_START) ) ], [ 'end <= start' => epg( title => 'X', start => iso($RN_END), end => iso($RN_END) ) ] ) {
		my ( $label, $body ) = @$case;
		reset_all();
		route( epg_url('RN'), content => $body );
		now_cb('RN');
		advanceTime(59);
		now_cb('RN');
		advanceTime(1);
		now_cb('RN');
		is( epg_requests(), 2, "$label: cached for 60 s" );
	}
};

subtest 'nothing on air: {} and null are answered undef, cached 60 s, not logged as failures' => sub {
	for my $body ( '{}', 'null', '[]', '{"preparedPresenters":[]}' ) {
		reset_all();
		route( epg_url('SPORT_BBL'), content => $body );
		my $c = now_cb('SPORT_BBL');
		is_deeply( [ $c->args(0) ], [undef], "$body: \$cb->(undef), no error" );
		now_cb('SPORT_BBL');
		is( epg_requests(), 1, "$body: cached" );
		is( scalar( logged('WARN') ), 0, "$body: no WARN" );
	}
};

subtest 'errors: negative cache 60 s, WARN once per run of failures' => sub {
	for my $case ( [ '500' => { code => 500 } ], [ '404' => { code => 404 } ], [ '429' => { code => 429 } ], [ 'timeout' => { error => 'Timed out waiting for data' } ], [ 'bad JSON' => { content => '<html>' } ] ) {
		my ( $label, $response ) = @$case;
		reset_all();
		route( epg_url('RN'), %$response );

		my $c = now_cb('RN');
		my ( $program, $error ) = $c->args(0);
		ok( !defined $program && defined $error, "$label: \$cb->(undef, \$error)" );
		advanceTime(59);
		$c = now_cb('RN');
		is( epg_requests(), 1, "$label: no new request for 60 s" );
		ok( defined( ( $c->args(0) )[1] ), "$label: ... the cached failure is answered" );
	}

	reset_all();
	route( epg_url('RN'), code => 500 );
	now_cb('RN') for 1 .. 3;
	advanceTime(60);
	now_cb('RN');
	advanceTime(60);
	now_cb('RN');
	is( epg_requests(), 3, 'one request per 60 s while failing' );
	is( scalar( grep { $_->{message} =~ /RN/ } logged('WARN') ), 1, 'WARN once for the run of failures' );
	ok( scalar( grep { $_->{message} =~ /still unavailable/ } logged('DEBUG') ), 'later failures at DEBUG' );

	resetStubs();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json' );
	advanceTime(60);
	is( ( now_cb('RN')->args(0) )[0]->{title}, 'The Radio National Hour', 'recovers' );

	resetStubs();
	route( epg_url('RN'), code => 503 );
	advanceTime(900);
	now_cb('RN');
	is( scalar( logged('WARN') ), 1, 'a new run of failures after a success: WARN again' );
};

subtest 'coalescing and at most 6 requests at a time' => sub {
	reset_all();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );

	my ( $a, $b ) = ( now_cb('RN'), now_cb('RN') );
	is( epg_requests(), 1, 'two callers, one request' );
	is( $a->count + $b->count, 0, 'both wait' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $a->count, 1, 'first caller answered once' );
	is( $b->count, 1, 'second caller answered once' );
	is( ( $b->args(0) )[0]->{title}, 'The Radio National Hour', '... with the program' );

	reset_all();
	route( qr{/epgNowPlaying/}, file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );
	my @ids = map {"LOCAL_$_"} qw(A B C D E F G H);
	my @c   = map { now_cb($_) } @ids;
	is( scalar( Slim::Networking::SimpleAsyncHTTP->deferred ), 6, '8 services: 6 requests in flight' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( epg_requests(), 8, 'the other 2 start as slots free up' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( grep { $_->count == 1 } @c ), 8, 'every caller answered once' );
};

subtest 'cached and lastGood' => sub {
	reset_all();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json' );

	is( $NP->cached('RN'),   undef, 'cached: undef before any fetch' );
	is( $NP->lastGood('RN'), undef, 'lastGood: undef before any fetch' );
	is( epg_requests(), 0, 'cached/lastGood never fetch' );

	now_cb('RN');
	my $copy = $NP->cached('RN');
	is( $copy->{title}, 'The Radio National Hour', 'cached: the fresh program' );
	$copy->{title} = 'changed';
	is( $NP->cached('RN')->{title}, 'The Radio National Hour', 'cached returns a copy' );

	advanceTime(900);
	is( $NP->cached('RN'), undef, 'cached: undef once stale' );
	is( $NP->lastGood('RN')->{title}, 'The Radio National Hour', 'lastGood: while the program is still on air' );

	resetStubs();
	route( epg_url('RN'), code => 500 );
	now_cb('RN');
	is( $NP->lastGood('RN')->{title}, 'The Radio National Hour', 'lastGood survives a failed request' );

	setTime($RN_END);
	is( $NP->lastGood('RN'), undef, 'lastGood: undef once the program has ended' );

	reset_all();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json' );
	now_cb('RN');
	advanceTime(900);
	resetStubs();
	route( epg_url('RN'), content => '{}' );
	now_cb('RN');
	is( $NP->lastGood('RN'), undef, 'a "nothing on air" answer forgets the last-good program' );

	reset_all();
	route( epg_url('TRIPLEJ'), file => 'live/bff-epgNowPlaying-RN-now.json' );
	route( epg_url('TRIPLEJ_PERTH'), file => 'live/bff-epgNowPlaying-TRIPLEJ_PERTH-now.json' );
	setTime( parseISO8601('2026-10-19T05:00:00Z') );
	now_cb('TRIPLEJ');
	is( $NP->cached('TRIPLEJ_PERTH'), undef, 'time-zone versions never reuse the network\'s data' );
	is( ( now_cb('TRIPLEJ_PERTH')->args(0) )[0]->{title}, 'Drive', '... TRIPLEJ_PERTH has its own' );
	is( $NP->cached('TRIPLEJ')->{title}, 'The Radio National Hour', '... and TRIPLEJ keeps its own' );
};

subtest 'programNext: only on demand, cached until its start' => sub {
	reset_all();
	route( epg_url( 'RN', 'now' ),  file => 'live/bff-epgNowPlaying-RN-now.json' );
	route( epg_url( 'RN', 'next' ), file => 'live/bff-epgNowPlaying-RN-next.json' );

	now_cb('RN');
	is( epg_requests(qr{/next\?}), 0, 'programNow never asks for /next' );

	setTime( parseISO8601('2026-10-19T18:20:00Z') );
	my $c = collector();
	$NP->programNext( 'RN', $c->cb );
	is( ( $c->args(0) )[0]->{title}, 'ABC News Daily and Radio National Hour Highlights', 'programNext: the next program' );
	is_deeply( [ map { $_->{url} } grep { $_->{url} =~ m{/next\?} } requests() ], [ epg_url( 'RN', 'next' ) ], 'GET epgNowPlaying/RN/next?imageRatio=1x1' );
	is( $NP->cached('RN'), undef, 'next never fills the "now" cache' );

	advanceTime(599);
	$NP->programNext( 'RN', sub { } );
	is( epg_requests(qr{/next\?}), 1, 'cached until the next program starts (10 min)' );
	advanceTime(1);
	$NP->programNext( 'RN', sub { } );
	is( epg_requests(qr{/next\?}), 2, '... then fetched again' );
};

subtest 'exactly one callback on every path' => sub {
	reset_all();

	for my $id ( undef, '', 'rn', 'RN/../x', [] ) {
		my $c = now_cb($id);
		is( $c->count, 1, 'programNow(' . ( defined $id ? ( ref $id ? 'ref' : "'$id'" ) : 'undef' ) . '): one callback' );
	}
	is( epg_requests(), 0, 'invalid ids: no request' );

	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );
	my $after = collector();
	$NP->programNow( 'RN', sub { die "boom\n" } );
	$NP->programNow( 'RN', $after->cb );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $after->count, 1, 'a caller whose callback dies does not stop the others' );
	ok( scalar( grep { $_->{message} =~ /boom/ } logged('ERROR') ), '... the die is logged' );

	reset_all();
	route( epg_url('RN'), file => 'live/bff-epgNowPlaying-RN-now.json', defer => 1 );
	my $c = now_cb('RN');
	Slim::Networking::SimpleAsyncHTTP->completeDeferred( error => 'Timed out waiting for data' );
	is( $c->count, 1, 'a timeout: one callback' );

	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::bff = sub { die "bff broke\n" };
		reset_all();
		$c = now_cb('RN');
	}
	is( $c->count, 1, 'API::bff dies: still one callback' );
	ok( defined( ( $c->args(0) )[1] ), '... with an error' );
};

subtest 'timeSlot: server local time, across midnight, start only' => sub {
	is( $NP->timeSlot( { start => $RN_START, end => $RN_END } ), "6:00pm\x{2013}7:00pm", 'RN: 6:00pm–7:00pm (AEDT)' );
	is(
		$NP->timeSlot( { start => parseISO8601('2026-10-19T23:00:00+11:00'), end => parseISO8601('2026-10-20T01:00:00+11:00') } ),
		"11:00pm\x{2013}1:00am", 'a program spanning midnight: 11:00pm–1:00am'
	);
	is( $NP->timeSlot( { start => $RN_START } ), '6:00pm', 'no end: the start alone' );
	is( $NP->timeSlot( { end => $RN_END } ), undef, 'no start: undef' );
	is( $NP->timeSlot(undef), undef, 'undef: undef' );
};

done_testing();
