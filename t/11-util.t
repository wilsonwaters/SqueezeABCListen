#!/usr/bin/perl
# Plugins::ABCListen::Util: constants, parseISO8601 (offsets, fractions, DST boundaries, invalid
# input), the local-time display helpers under fixed time zones, decodeEntities (with and without
# HTML::Entities), the URL contract (streams.md contract 2) and the episode metadata cache
# contract (streams.md contract 3).
# F7 (#76): episodeSeenAt (the fetch time of a fresh answer younger than 6 h, else undef) and
# episodeMetaIsNewer (a later seenAt, or windows closed later; ties are not newer).

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;

use Plugins::ABCListen::Util qw(:all);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

sub show { defined $_[0] ? "'$_[0]'" : 'undef' }

# Run $code with the server time zone set to $tz, then restore it.
sub with_tz {
	my ( $tz, $code ) = @_;
	{
		local $ENV{TZ} = $tz;
		POSIX::tzset();
		$code->();
	}
	POSIX::tzset();
	return;
}

subtest 'constants' => sub {
	is( DISPLAY_NAME,     'ABC listen',                             'display name' );
	is( ICON,             'plugins/ABCListen/html/images/icon.png', 'icon path' );
	is( CACHE_NAMESPACE,  'abclisten',                              'cache namespace' );
	is( SITE_BASE,        'https://www.abc.net.au',                 'ABC site base' );
	is( EPISODE_META_TTL, 30 * 86400,                               'episode metadata TTL: 30 days' );
	ok( -f 'ABCListen/HTML/EN/' . ICON, 'the icon path points at the shipped icon file' );
};

subtest 'top-level menu weights' => sub {
	my %expected = (
		home => 10, radio => 20, podcasts => 30, news => 40, sport => 50,
		kids => 60, audiobooks => 70, programs => 75, search => 80, myabc => 90,
	);
	is( topWeight($_), $expected{$_}, "topWeight('$_') is $expected{$_}" ) for sort { $expected{$a} <=> $expected{$b} } keys %expected;
	is( DEFAULT_TOP_WEIGHT, 100, 'items without a weight sort at 100, after every named weight' );
	is( topWeight($_), undef, 'topWeight(' . show($_) . ') is undef' ) for ( undef, '', 'Radio', 'live', 'unknown' );
};

# 2026-10-19 06:30 AEDT (Sydney, UTC+11) = 2026-10-18 19:30 UTC
my $T = timegm( 0, 30, 19, 18, 9, 2026 );

subtest 'parseISO8601: formats and offsets' => sub {
	my @same = (
		[ '2026-10-18T19:30:00Z',          'UTC "Z"' ],
		[ '2026-10-18T19:30:00z',          'lower-case "z"' ],
		[ '2026-10-18T19:30:00+00:00',     '+00:00 (as ABC sends it)' ],
		[ '2026-10-19T06:30:00+11:00',     '+11:00 (AEDT)' ],
		[ '2026-10-19T06:30:00+1100',      '+1100 (no colon)' ],
		[ '2026-10-19T05:30:00+10:00',     '+10:00 (AEST)' ],
		[ '2026-10-19T05:30:00+1000',      '+1000 (no colon)' ],
		[ '2026-10-19T06:00:00+10:30',     '+10:30 (ACDT)' ],
		[ '2026-10-19T05:00:00+09:30',     '+09:30 (ACST)' ],
		[ '2026-10-19T03:30:00+08:00',     '+08:00 (AWST)' ],
		[ '2026-10-18T14:30:00-05:00',     '-05:00 (negative offset)' ],
		[ '2026-10-18T19:30:00.123Z',      'fractional seconds .123' ],
		[ '2026-10-19T06:30:00.5+11:00',   'fractional seconds with an offset' ],
		[ '2026-10-19T06:30+11:00',        'no seconds' ],
		[ '2026-10-18T19:30:00',           'no offset: taken as UTC' ],
		[ ' 2026-10-18T19:30:00Z ',        'surrounding whitespace' ],
	);
	is( parseISO8601( $_->[0] ), $T, "$_->[1]: $_->[0]" ) for @same;
	is( parseISO8601('2026-10-18T19:30:59Z'), $T + 59, 'seconds count' );
	is( parseISO8601('1970-01-01T00:00:00Z'), 0, 'epoch 0' );
};

subtest 'parseISO8601: invalid input is undef' => sub {
	my @invalid = (
		undef, '', 'garbage', '2026-10-19',
		'2026-02-30T09:00:00+10:00',    # no 30 February
		'2026-10-19T24:00:00+10:00',    # hour 24
		'2026-10-19T06:60:00Z',         # minute 60
		'2026-10-19T06:30:60Z',         # second 60
		'0026-10-19T06:30:00+10:00',    # year 0026 (Time::Local would read it as 2026)
		'2026-10-19 06:30:00+10:00',    # space instead of T
		'2026-10-19T06:30:00+25:00',    # offset hour > 23
		'2026-10-19T06:30:00+10:60',    # offset minute > 59
		'2026-10-19T06:30:00+10',       # incomplete offset
		'2026-10-19T06:30:00 AEDT',     # zone name
		'2026-1-19T06:30:00Z',          # one-digit month
		'٢٠٢٦-10-19T06:30:00Z',         # Arabic-Indic digits
	);
	is( parseISO8601($_), undef, 'parseISO8601(' . show($_) . ')' ) for @invalid;
};

subtest 'parseISO8601: daylight-saving boundaries' => sub {
	# AEDT -> AEST: 03:00 AEDT on Sun 5 April 2026 becomes 02:00 AEST
	my $aedtLast  = parseISO8601('2026-04-05T02:59:59+11:00');
	my $aestFirst = parseISO8601('2026-04-05T02:00:00+10:00');
	is( $aestFirst - $aedtLast, 1, 'April: 02:59:59+11:00 and 02:00:00+10:00 are 1 s apart' );
	is( $aestFirst, timegm( 0, 0, 16, 4, 3, 2026 ), 'April: 02:00:00+10:00 is 16:00 UTC the day before' );

	# AEST -> AEDT: 02:00 AEST on Sun 4 October 2026 becomes 03:00 AEDT
	my $aestLast  = parseISO8601('2026-10-04T01:59:59+10:00');
	my $aedtFirst = parseISO8601('2026-10-04T03:00:00+11:00');
	is( $aedtFirst - $aestLast, 1, 'October: 01:59:59+10:00 and 03:00:00+11:00 are 1 s apart' );
	is( $aedtFirst, timegm( 0, 0, 16, 3, 9, 2026 ), 'October: 03:00:00+11:00 is 16:00 UTC the day before' );

	# ACDT/ACST (Adelaide, Broken Hill)
	is( parseISO8601('2026-04-05T02:00:00+09:30') - parseISO8601('2026-04-05T02:59:59+10:30'), 1, 'April ACDT -> ACST: 1 s apart' );
	is( parseISO8601('2026-10-04T03:00:00+10:30') - parseISO8601('2026-10-04T01:59:59+09:30'), 1, 'October ACST -> ACDT: 1 s apart' );
};

# Epoch of a local wall-clock time given with its UTC offset.
sub at { parseISO8601(shift) }

subtest 'display helpers: Australia/Sydney, either side of both 2026 DST changes' => sub {
	with_tz( 'Australia/Sydney', sub {
		setTime( at('2026-10-19T12:00:00+11:00') );

		is( friendlyDate( at('2026-10-19T06:30:00+11:00') ), 'Mon 19 Oct', 'friendlyDate in AEDT' );
		is( friendlyTime( at('2026-10-19T06:30:00+11:00') ), '6:30am',     'friendlyTime in AEDT' );
		is( friendlyTime($T),                                '6:30am',     'the same instant from a UTC string' );

		is( friendlyDate( at('2026-07-14T18:05:00+10:00') ), 'Tue 14 Jul', 'friendlyDate in AEST' );
		is( friendlyTime( at('2026-07-14T18:05:00+10:00') ), '6:05pm',     'friendlyTime in AEST' );

		# DST starts: 02:00 AEST -> 03:00 AEDT on Sun 4 Oct
		my $beforeStart = at('2026-10-04T01:59:59+10:00');
		is( friendlyTime($beforeStart),     '1:59am',     'last second of AEST' );
		is( friendlyTime( $beforeStart + 1 ), '3:00am',   'one second later it is 3:00am AEDT' );
		is( friendlyDate( $beforeStart + 1 ), 'Sun 4 Oct', 'no leading zero on the day' );
		is( friendlyDate( at('2026-10-03T23:30:00+10:00') ), 'Sat 3 Oct', 'the evening before' );

		# DST ends: 03:00 AEDT -> 02:00 AEST on Sun 5 Apr
		my $beforeEnd = at('2026-04-05T02:59:59+11:00');
		is( friendlyTime($beforeEnd),       '2:59am', 'last second of AEDT' );
		is( friendlyTime( $beforeEnd + 1 ), '2:00am', 'one second later it is 2:00am AEST again' );
		is( friendlyDate( $beforeEnd + 1 ), 'Sun 5 Apr', 'same day' );

		is( friendlyTime( at('2026-10-20T00:00:00+11:00') ), '12:00am', 'midnight is 12:00am' );
		is( friendlyTime( at('2026-10-19T12:00:00+11:00') ), '12:00pm', 'noon is 12:00pm' );
		is( friendlyTime( at('2026-10-19T06:00:00+11:00') ), '6:00am',  'on the hour: 6:00am' );
		is( friendlyTime( at('2026-10-19T23:59:00+11:00') ), '11:59pm', 'last minute of the day' );
		is( friendlyTime( at('2026-10-19T12:59:00+11:00') ), '12:59pm', '12:59pm' );
		is( friendlyTime( at('2026-10-19T00:01:00+11:00') ), '12:01am', '12:01am' );

		is( friendlyDate( at('2025-10-19T09:00:00+11:00') ), 'Sun 19 Oct 2025', 'previous year: the year is added' );
		is( friendlyDate( at('2027-01-01T09:00:00+11:00') ), 'Fri 1 Jan 2027',  'next year: the year is added' );
		is( friendlyDate( at('2026-01-01T09:00:00+11:00') ), 'Thu 1 Jan',       'earlier in the current year: no year' );

		# "current year" is the server's local year: 31 Dec 20:00 UTC is already 2027 in Sydney
		setTime( at('2026-12-31T20:00:00Z') );
		is( friendlyDate( at('2027-01-01T09:00:00+11:00') ), 'Fri 1 Jan',       'the current local year is 2027: no year' );
		is( friendlyDate( at('2026-12-31T09:00:00+11:00') ), 'Thu 31 Dec 2026', 'and 2026 now shows its year' );
		clearTime();
	} );
};

subtest 'display helpers: Australia/Perth (no DST) and UTC' => sub {
	with_tz( 'Australia/Perth', sub {
		setTime( at('2026-10-19T12:00:00+08:00') );
		is( friendlyTime($T), '3:30am',     'the same instant is 3:30am in Perth' );
		is( friendlyDate($T), 'Mon 19 Oct', 'Perth date' );
		is( friendlyTime( at('2026-10-20T00:00:00+08:00') ), '12:00am',    'Perth midnight' );
		is( friendlyDate( at('2026-10-20T00:00:00+08:00') ), 'Tue 20 Oct', 'Perth midnight is the next day' );
		is( friendlyTime( at('2026-04-05T02:30:00+08:00') ), '2:30am',     'no DST change in April' );
		is( friendlyTime( at('2026-10-04T02:30:00+08:00') ), '2:30am',     'no DST change in October' );
		clearTime();
	} );

	with_tz( 'UTC', sub {
		setTime($T);
		is( friendlyTime($T), '7:30pm',     'UTC server: 7:30pm' );
		is( friendlyDate($T), 'Sun 18 Oct', 'UTC server: still the 18th' );
		clearTime();
	} );
};

subtest 'display helpers: invalid input' => sub {
	for my $bad ( undef, '', 'yesterday', '12abc' ) {
		is( friendlyDate($bad), undef, 'friendlyDate(' . show($bad) . ') is undef' );
		is( friendlyTime($bad), undef, 'friendlyTime(' . show($bad) . ') is undef' );
	}
};

subtest 'friendlyDuration' => sub {
	my @cases = (
		[ undef, '' ], [ '', '' ], [ 'abc', '' ], [ 0, '' ], [ -5, '' ],
		[ 1,    '1 min' ],       # anything above 0 s shows at least 1 min
		[ 29,   '1 min' ],
		[ 59,   '1 min' ],
		[ 60,   '1 min' ],
		[ 89,   '1 min' ],       # rounded to the nearest minute
		[ 90,   '2 min' ],
		[ 3240, '54 min' ],
		[ 3569, '59 min' ],
		[ 3599, '1 h 00 min' ],  # rounds to 60 min, shown as hours
		[ 3600, '1 h 00 min' ],
		[ 3900, '1 h 05 min' ],
		[ 5400, '1 h 30 min' ],
		[ 7200, '2 h 00 min' ],
		[ 36000 + 59 * 60, '10 h 59 min' ],
		[ '2704.08', '45 min' ],  # fractional seconds (as LMS reports durations)
	);
	is( friendlyDuration( $_->[0] ), $_->[1], 'friendlyDuration(' . show( $_->[0] ) . ") is '$_->[1]'" ) for @cases;
};

subtest 'decodeEntities' => sub {
	my @cases = (
		[ '&amp;',                    '&',                        '&amp;' ],
		[ 'Rock &amp; Roll',          'Rock & Roll',              'named entity in text' ],
		[ 'Australia&#8217;s',        "Australia\x{2019}s",       'decimal entity' ],
		[ 'It&#x27;s',                "It's",                     'hex entity' ],
		[ 'It&#X27;s',                "It's",                     'hex entity with upper-case X' ],
		[ 'Late&nbsp;Night',          'Late Night',               '&nbsp; becomes a plain space' ],
		[ 'Caf&eacute; &lt;b&gt;',    'Café <b>',                 'accented letter, &lt; &gt;' ],
		[ '&quot;Hi&quot; &ndash; x', "\"Hi\" \x{2013} x",        'quotes and en dash' ],
		[ '&amp;amp;',                '&amp;',                    'decodes only once' ],
		[ 'no entities here',         'no entities here',         'text without entities passes through unchanged' ],
		[ 'Ünïcödé – ok',             'Ünïcödé – ok',             'non-ASCII text without entities unchanged' ],
	);

	# LMS bundles HTML::Entities; plain Perl may not have it. Test the built-in decoder always and
	# HTML::Entities when it is installed (CI installs it).
	my @paths = ( [ 'built-in decoder', 0 ] );
	push @paths, [ 'HTML::Entities', 1 ] if $Plugins::ABCListen::Util::HAS_HTML_ENTITIES;
	diag('HTML::Entities not installed: only the built-in decoder is tested') unless $Plugins::ABCListen::Util::HAS_HTML_ENTITIES;

	for my $path (@paths) {
		my ( $label, $useHTMLEntities ) = @$path;
		local $Plugins::ABCListen::Util::HAS_HTML_ENTITIES = $useHTMLEntities;
		for my $case (@cases) {
			my ( $in, $out, $name ) = @$case;
			is( decodeEntities($in), $out, "$label: $name" );
		}
		is( decodeEntities(undef), undef, "$label: undef stays undef" );
	}

	local $Plugins::ABCListen::Util::HAS_HTML_ENTITIES = 0;
	is( decodeEntities('&bogus; &#0;'), '&bogus; &#0;', 'built-in decoder: unknown and invalid entities are left alone' );
};

subtest 'URL contract: liveUrl / episodeUrl' => sub {
	is( liveUrl('TRIPLEJ'),       'abclisten://live/TRIPLEJ',       'liveUrl TRIPLEJ' );
	is( liveUrl('TRIPLEJ_PERTH'), 'abclisten://live/TRIPLEJ_PERTH', 'liveUrl with an underscore' );
	is( liveUrl('LOCAL_SYDNEY'),  'abclisten://live/LOCAL_SYDNEY',  'liveUrl LOCAL_SYDNEY' );
	is( liveUrl('RN'),            'abclisten://live/RN',            'liveUrl RN' );
	is( liveUrl('CLASSIC2'),      'abclisten://live/CLASSIC2',      'liveUrl with a digit' );

	is( liveUrl($_), undef, 'liveUrl(' . show($_) . ') is undef' )
		for ( undef, '', 'triplej', 'TripleJ', 'TRIPLE J', 'TRIPLE-J', 'TRIPLEJ/', 'TRIPLEJ?x', "TRIPLEJ\n", 'ÄBC', '../RN' );

	is( episodeUrl(107266790),   'abclisten://episode/107266790', 'episodeUrl from a number' );
	is( episodeUrl('12345'),     'abclisten://episode/12345',     'episodeUrl from a digit string' );

	is( episodeUrl($_), undef, 'episodeUrl(' . show($_) . ') is undef' )
		for ( undef, '', 'abc', '12a', '-1', '1.5', '1e5', "123\n", ' 123', '١٢٣', '１２３' );
};

subtest 'URL contract: parseUrl' => sub {
	is_deeply( parseUrl('abclisten://live/TRIPLEJ'),        { kind => 'live', id => 'TRIPLEJ' },        'live URL' );
	is_deeply( parseUrl('abclisten://live/LOCAL_SYDNEY'),   { kind => 'live', id => 'LOCAL_SYDNEY' },   'live URL with an underscore' );
	is_deeply( parseUrl('abclisten://episode/107266790'),   { kind => 'episode', id => '107266790' },   'episode URL' );

	my @invalid = (
		undef, '',
		'abclisten://live/triplej',              # lower-case service id
		'abclisten://live/',                     # empty id
		'abclisten://live',
		'abclisten://live/TRIPLEJ/',             # trailing slash
		'abclisten://live/TRIPLEJ?source=web',   # query
		'abclisten://live/TRIPLEJ#now',          # fragment
		'abclisten://live/TRIPLEJ/extra',        # extra path segment
		"abclisten://live/TRIPLEJ\n",            # trailing newline
		'abclisten://episode/',                  # empty id
		'abclisten://episode/12a',               # non-digit episode id
		'abclisten://episode/123/456',           # extra path segment
		'abclisten://episode/123?x=1',
		'abclisten://episode/١٢٣',               # non-ASCII digits
		'abclisten://program/123',               # unknown kind
		'abclisten://live/TRIPLEJ/episode/1',
		'ABCLISTEN://live/TRIPLEJ',              # scheme is lower-case only
		'https://abc.streamguys1.com/live/triplejnsw/icecast.audio',    # other scheme
		'http://live/TRIPLEJ',
		'xabclisten://live/TRIPLEJ',
		' abclisten://live/TRIPLEJ',
	);
	is( parseUrl($_), undef, 'parseUrl(' . show($_) . ') is undef' ) for @invalid;

	for my $id (qw(TRIPLEJ TRIPLEJ_PERTH LOCAL_SYDNEY RN)) {
		is_deeply( parseUrl( liveUrl($id) ), { kind => 'live', id => $id }, "round trip: parseUrl(liveUrl('$id'))" );
	}
	for my $id ( 12345, '107266790', '0' ) {
		is_deeply( parseUrl( episodeUrl($id) ), { kind => 'episode', id => "$id" }, "round trip: parseUrl(episodeUrl($id))" );
	}
};

subtest 'episode metadata cache: set / get / merge' => sub {
	resetStubs();
	setTime( at('2026-10-19T12:00:00+11:00') );

	my %meta = (
		id           => '107266790',
		docType      => 'audioepisode',
		title        => 'The Science Show',
		programTitle => 'The Science Show',
		programId    => '2885480',
		path         => '/listen/programs/scienceshow/the-science-show/107266790',
		image        => 'https://live-production.wcms.abc-cdn.net.au/abc?impolicy=wcms_crop_resize&cropH=1&cropW=1&xPos=0&yPos=0&width=862&height=862',
		description  => 'Robyn Williams',
		date         => at('2026-10-17T12:00:00+11:00'),
		duration     => 3240,
		renditions   => [ { url => 'https://mediacore-live-production.akamaized.net/audio/x.mp3', mime => 'audio/mpeg', bitrate => 128 } ],
		availableTo  => at('2027-10-17T12:00:00+11:00'),
	);

	is( getEpisodeMeta('107266790'), undef, 'unknown id: undef' );

	ok( setEpisodeMeta( '107266790', {%meta} ), 'a full write is stored' );
	is_deeply( getEpisodeMeta('107266790'), \%meta, 'get returns what was written' );
	is_deeply( getEpisodeMeta(107266790),   \%meta, 'a numeric id finds the same entry' );

	my $copy = getEpisodeMeta('107266790');
	$copy->{title} = 'changed by the caller';
	push @{ $copy->{renditions} }, 'x';
	is_deeply( getEpisodeMeta('107266790'), \%meta, 'callers get a copy' );

	ok( Slim::Utils::Cache->new('abclisten')->get('episode-meta:107266790'), 'stored in the "abclisten" cache namespace' );

	# a partial write: non-empty values replace, empty ones never clobber
	ok( setEpisodeMeta( '107266790', { title => 'New title', image => '', description => undef, renditions => [], seenAt => 1_790_000_000 } ), 'a partial write is stored' );
	is_deeply(
		getEpisodeMeta('107266790'),
		{ %meta, title => 'New title', seenAt => 1_790_000_000 },
		'partial write: new non-empty values replace old ones; undef, "" and [] keep the existing values; optional fields survive'
	);

	ok( setEpisodeMeta( '107266790', { renditions => [ { url => 'https://example.test/b.aac', mime => 'audio/aac', bitrate => 96 } ], availableTo => 0 } ), 'replace an optional field' );
	my $now = getEpisodeMeta('107266790');
	is( $now->{renditions}->[0]->{mime}, 'audio/aac', 'a new non-empty array replaces the old one' );
	is( scalar @{ $now->{renditions} }, 1, '... entirely' );
	is( $now->{availableTo}, 0, '0 is a value, not empty' );
	is( $now->{title}, 'New title', 'other fields untouched' );

	ok( setEpisodeMeta( '107266790', { id => '999', title => 'Again' } ), 'write with a different id inside the hash' );
	is( getEpisodeMeta('107266790')->{id}, '107266790', 'the id argument wins' );
	is( getEpisodeMeta('999'), undef, 'nothing stored under the id inside the hash' );

	ok( setEpisodeMeta( '42', { title => 'Only a title', play => sub { } } ), 'write with a code ref value' );
	is_deeply( getEpisodeMeta('42'), { id => '42', title => 'Only a title' }, 'code refs are dropped (the cache cannot store them); id is always set' );

	clearTime();
};

subtest 'episode metadata cache: no-op writes' => sub {
	resetStubs();

	my @noop = (
		[ [ undef, { title => 'x' } ],            'no id' ],
		[ [ '',    { title => 'x' } ],            'empty id' ],
		[ [ 'abc', { title => 'x' } ],            'non-numeric id' ],
		[ [ "1\n", { title => 'x' } ],            'id with a newline' ],
		[ [ '1',   {} ],                          'empty hash' ],
		[ [ '1',   undef ],                       'undef metadata' ],
		[ [ '1',   [ title => 'x' ] ],            'array ref instead of a hash' ],
		[ [ '1',   { title => '', image => undef, renditions => [], extra => {} } ], 'only empty values' ],
	);

	for my $case (@noop) {
		my ( $args, $name ) = @$case;
		ok( !setEpisodeMeta(@$args), "$name: not stored" );
	}
	is( getEpisodeMeta('1'), undef, 'nothing was stored under id 1' );
	is( getEpisodeMeta($_), undef, 'getEpisodeMeta(' . show($_) . ') is undef' ) for ( undef, '', 'abc' );

	ok( setEpisodeMeta( '1', { title => 'kept' } ), 'store an entry' );
	ok( !setEpisodeMeta( '1', { title => '', description => undef } ), 'an all-empty write to an existing entry is a no-op' );
	is( getEpisodeMeta('1')->{title}, 'kept', '... and keeps the entry' );
};

subtest 'episode metadata cache: 30-day TTL, refreshed by every write' => sub {
	resetStubs();
	my $t0 = at('2026-10-19T12:00:00+11:00');
	setTime($t0);

	my @ttls;
	{
		no warnings 'redefine';
		my $set = \&Slim::Utils::Cache::set;
		local *Slim::Utils::Cache::set = sub { push @ttls, $_[3]; $set->(@_) };
		setEpisodeMeta( '7', { title => 'Seven' } );
	}
	is_deeply( \@ttls, [ 30 * 86400 ], 'the cache gets a TTL of 30 days (2592000 s)' );

	advanceTime( 30 * 86400 - 1 );
	ok( getEpisodeMeta('7'), 'still cached just before 30 days' );
	advanceTime(2);
	is( getEpisodeMeta('7'), undef, 'expired after 30 days' );

	setTime($t0);
	setEpisodeMeta( '8', { title => 'Eight' } );
	advanceTime( 20 * 86400 );
	setEpisodeMeta( '8', { description => 'refreshed' } );
	advanceTime( 25 * 86400 );
	is_deeply( getEpisodeMeta('8'), { id => '8', title => 'Eight', description => 'refreshed' }, 'a later write refreshes the TTL (45 days after the first write)' );
	advanceTime( 5 * 86400 + 1 );
	is( getEpisodeMeta('8'), undef, 'expired 30 days after the last write' );

	clearTime();
};

# ---- F7 (#76): seenAt from the fetch time, D5's rule shared (contract 3) ----

subtest 'F7: episodeSeenAt - the fetch time of a fresh answer younger than 6 h, else undef' => sub {
	my $now  = 1_792_400_000;
	my $HOUR = 3600;
	my $seen = \&Plugins::ABCListen::Util::episodeSeenAt;

	is( Plugins::ABCListen::Util::EPISODE_SEEN_MAX_AGE(), 6 * $HOUR, 'the freshness window is 6 h' );
	is_deeply( [ Plugins::ABCListen::Util::episodeAudioKeys() ], [qw(renditions availableTo downloadAvailableTo seenAt)], 'the audio keys a seenAt vouches for' );

	is( $seen->( { stale => 0, at => $now }, $now ),                 $now,             'a network answer: now (its fetch time)' );
	is( $seen->( { stale => 0, at => $now - $HOUR }, $now ),         $now - $HOUR,     'an hour-old cached answer: its fetch time, not now' );
	is( $seen->( { at => $now - 6 * $HOUR + 1 }, $now ),             $now - 6 * $HOUR + 1, 'just under 6 h old: its fetch time' );
	is( $seen->( { at => $now - 6 * $HOUR }, $now ),                 undef,            '6 h old: none (O1 would not trust it)' );
	is( $seen->( { at => $now - 7 * $HOUR }, $now ),                 undef,            '7 h old: none' );
	is( $seen->( { stale => 1, at => $now - 60 }, $now ),            undef,            'a stale (last-good) copy, however young: none' );
	is( $seen->( { stale => 0 }, $now ),                             undef,            'no fetch time: none' );
	is( $seen->( { at => 'yesterday' }, $now ),                      undef,            'a fetch time that is not a number: none' );
	is( $seen->( { at => [1] }, $now ),                              undef,            'a fetch time that is a ref: none' );
	is( $seen->( undef, $now ),                                      undef,            'no info hash: none' );
	is( $seen->( 'info', $now ),                                     undef,            'not a hash: none' );
	is( $seen->( { at => "$now.5" }, $now + 1 ),                     $now + 0.5,       'a fractional fetch time is a number' );

	setTime($now);
	is( $seen->( { at => $now - $HOUR } ), $now - $HOUR, 'without $now: time() is used' );
	clearTime();
};

subtest 'F7: episodeMetaIsNewer - newer seenAt or windows closed after the fetch; ties are not newer' => sub {
	resetStubs();
	my $t0   = 1_792_400_000;
	my $HOUR = 3600;
	setTime($t0);
	my $newer = \&Plugins::ABCListen::Util::episodeMetaIsNewer;

	is( $newer->( '5001', $t0 - $HOUR ), 0, 'no entry: not newer' );
	is( $newer->( 'x', $t0 ), 0, 'not an episode id: not newer' );

	setEpisodeMeta( '5001', { title => 'No audio data' } );
	is( $newer->( '5001', $t0 - $HOUR ), 0, 'an entry without seenAt or closed windows: not newer' );

	setEpisodeMeta( '5002', { renditions => [ { url => 'https://example.test/a.mp3' } ], seenAt => $t0 - 1800 } );
	is( $newer->( '5002', $t0 - $HOUR ),  1, 'seenAt later than an hour-old answer: newer' );
	is( $newer->( '5002', $t0 - 1800 ),   0, 'seenAt equal to the fetch time (this same answer, walked again): not newer' );
	is( $newer->( '5002', $t0 ),          0, 'seenAt older than a fresh answer: not newer' );
	is( $newer->( '5002', undef ),        1, 'unknown fetch time: older than anything dated' );
	is( $newer->( '5002', 'soon' ),       1, 'a fetch time that is not a number: older than anything dated' );

	# O1 closed the windows (restricted / not yet released): both ends equal and past
	setEpisodeMeta( '5003', { availableTo => $t0 - 1800, downloadAvailableTo => $t0 - 1800 } );
	is( $newer->( '5003', $t0 - $HOUR ), 1, 'windows closed after the fetch: newer' );
	is( $newer->( '5003', $t0 - 1800 ),  0, 'closed at the fetch time: not newer' );
	is( $newer->( '5003', $t0 - 60 ),    0, 'closed before the fetch: not newer (the answer may reopen them)' );

	setEpisodeMeta( '5004', { availableTo => $t0 - 1800, downloadAvailableTo => $t0 - 1700 } );
	is( $newer->( '5004', $t0 - $HOUR ), 0, 'two different window ends are not a closure' );

	setEpisodeMeta( '5005', { availableTo => $t0 + $HOUR, downloadAvailableTo => $t0 + $HOUR } );
	is( $newer->( '5005', $t0 - $HOUR ), 0, 'equal ends in the future are open windows, not a closure' );

	setEpisodeMeta( '5006', { seenAt => 'garbage', availableTo => 'x', downloadAvailableTo => 'x' } );
	is( $newer->( '5006', $t0 - $HOUR ), 0, 'values that are not numbers: not newer' );

	clearTime();
};

done_testing();
