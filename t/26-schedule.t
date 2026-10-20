#!/usr/bin/perl
# Plugins::ABCListen::Schedule (L4; offline, fake clock, any process TZ: run it with TZ=UTC and
# TZ=America/New_York too):
#   * parse: the RN day fixture (research sample, 2 items per block: blocks flattened in order,
#     epochs, presenters[].displayName, programPath via sitePath incl. an old-style
#     /radionational/programs/ URL, no url -> undef, timeLabel, onNow, the image's srcSet entry);
#     a full RN day (2026-10-20, 31 items: off-site and /radio/programs/ URLs, a trailing space,
#     the one onNow item) and a LOCAL_PERTH broadcast day (3am-3am Perth, 13 items, never trimmed);
#     every item's timeLabel equals ABC's start string AND the start formatted in the station tz;
#     synthetic bodies: {} / [] / empty blocks, items without rawStartTime or title (skipped),
#     without rawEndTime (next start), unsorted and overlapping items, entities, tags, whitespace,
#     non-program URLs, a missing start string;
#   * localDate / timeLabel / dayList at boundary instants for Sydney, Melbourne, Canberra, Hobart,
#     Brisbane, Adelaide, Broken Hill, Darwin and Perth (2026-10-18T13:30Z: Sydney 19 Oct, Perth
#     18 Oct), the DST start (2026-10-04, 23 h) and end (2026-04-05, 25 h, repeated hour) days,
#     labels across DST, month and year ends - all with tzset and with the fixed table;
#   * the fixed table agrees with tzset for every catalogue tz around every transition 2025-2027
#     and mid-month all year; the table is used when tzset has no effect; the process TZ (unset,
#     UTC, America/New_York) is restored after every call, also when the conversion dies;
#   * day(): the request (service, date, the station's tz, ratio 1x1; Sydney for an unknown id),
#     cache TTLs (station-local today 10 min, past days 24 h, also across midnight), coalescing
#     (one request, a copy per caller, a dying caller doesn't stop the others), errors (500, 429,
#     bad JSON, a JSON array) -> LOAD_FAILED / RATE_LIMITED and not cached, {} -> no schedule,
#     invalid arguments -> LOAD_FAILED without a request, exactly one callback on every path.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

use JSON::PP ();
use POSIX ();
use Time::Local ();

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Schedule;
use Plugins::ABCListen::StationData;
use Plugins::ABCListen::Util qw(parseISO8601);

my $SCH      = 'Plugins::ABCListen::Schedule';
my $SCHEDULE = 'https://www.abc.net.au/core-next/api/schedule';

$Slim::Utils::Log::CATEGORIES{'plugin.abclisten'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_ABCLISTEN' };

sub logged { Slim::Utils::Log->messages( category => 'plugin.abclisten', level => shift ) }

sub t { parseISO8601(shift) }

sub fixture_json { JSON::PP->new->utf8->decode( fixture(shift) ) }

sub reset_all {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	$SCH->_reset();
	setTime( t('2026-10-19T08:00:00Z') );    # 7:00pm AEDT, 4:00pm AWST, Monday 19 Oct
	return;
}

sub schedule_requests { grep { $_->{url} =~ m{/core-next/api/schedule\?} } requests() }

# day() with a collector; returns the collector
sub day_cb {
	my ( $id, $date ) = @_;
	my $c = collector();
	$SCH->day( $id, $date, $c->cb );
	return $c;
}

my $ZONEINFO = -e '/usr/share/zoneinfo/Australia/Perth' ? 1 : 0;

# run $code with tzset and, again, with the fixed table
sub both_ways {
	my $code = shift;
	for my $mode ( 'tzset', 'table' ) {
		next if $mode eq 'tzset' && !$ZONEINFO;
		local $Plugins::ABCListen::Schedule::NO_TZSET = $mode eq 'table' ? 1 : 0;
		$SCH->_reset();
		$code->($mode);
	}
	$SCH->_reset();
}

# ---------------------------------------------------------------------------
# parse
# ---------------------------------------------------------------------------

subtest 'parse: the RN day sample (research fixture)' => sub {
	my $items = $SCH->parse( fixture_json('live/bff-schedule-RN-day.json'), 'Australia/Sydney' );

	is( scalar @$items, 4, '2 blocks x 2 items, flattened' );
	is_deeply( [ map { $_->{title} } @$items ], [ 'Download This Show', 'Crowdscience (BBC)', 'ABC News Daily and Radio National Hour Highlights', 'Radio National Breakfast' ], 'in order' );
	is_deeply( [ map { $_->{start} } @$items ], [ map { t($_) } '2026-10-18T13:00:00Z', '2026-10-18T13:30:00Z', '2026-10-18T18:30:00Z', '2026-10-18T19:00:00Z' ], 'start: epochs from rawStartTime' );
	is_deeply( [ map { $_->{end} } @$items ], [ map { t($_) } '2026-10-18T13:30:00Z', '2026-10-18T14:00:00Z', '2026-10-18T19:00:00Z', '2026-10-18T20:10:00Z' ], 'end: epochs from rawEndTime' );
	is_deeply( [ map { $_->{timeLabel} } @$items ], [ '12:00am', '12:30am', '5:30am', '6:00am' ], 'timeLabel: ABC\'s start string' );
	is_deeply( [ map { $_->{presenters} } @$items ], [ 'Rae Johnston', undef, undef, 'Sally Sara' ], 'presenters: displayName, undef for []' );
	is_deeply( [ map { $_->{programPath} } @$items ], [ '/radionational/programs/downloadthisshow', undef, '/listen/programs/abc-news-daily', '/radionational/programs/breakfast' ],
		'programPath: sitePath of the program URL (old-style /radionational/programs/ too); no url -> undef' );
	is_deeply( [ map { $_->{onNow} } @$items ], [ 0, 0, 0, 0 ], 'onNow 0' );
	like( $items->[0]->{image}, qr{\Ahttps://resize\.abcradio\.net\.au/[^/]+=/100x100/}, 'image: the srcSet entry (only 100w here, the largest)' );
	is( $items->[0]->{synopsis}, 'Explore the latest in technology, social media, consumer electronics, digital culture and more.', 'synopsis: plain text' );
	is_deeply( [ sort keys %{ $items->[0] } ], [ sort qw(start end title synopsis image presenters programPath onNow timeLabel) ], 'item keys' );
};

subtest 'parse: a full RN day (2026-10-20) and a LOCAL_PERTH broadcast day (3am-3am)' => sub {
	my $rn = $SCH->parse( fixture_json('live/bff-schedule-RN-2026-10-20.trimmed.json'), 'Australia/Sydney' );
	is( scalar @$rn, 31, 'RN: 31 items across 4 blocks' );
	is_deeply( [ map { $_->{start} } @$rn ], [ sort { $a <=> $b } map { $_->{start} } @$rn ], 'sorted by start' );
	is( $rn->[0]->{timeLabel}, '12:00am', 'starts at 12:00am Sydney' );
	is( $rn->[0]->{programPath}, undef, 'Radiolab (wnycstudios.org): no program path' );
	my ($am) = grep { $_->{title} eq 'AM' } @$rn;
	is( $am->{programPath}, '/radio/programs/am', 'a network-wide /radio/programs/ page links' );
	my ($law) = grep { $_->{title} =~ /\ALaw Report/ } @$rn;
	is( $law->{title}, 'Law Report', '"Law Report " trimmed' );
	is_deeply( [ map { $_->{title} } grep { $_->{onNow} } @$rn ], ['Critics Corner'], 'exactly one onNow item (ABC\'s flag)' );
	like( $rn->[1]->{image}, qr{/340x340/}, 'image: the 340w srcSet entry' );
	is( scalar( grep { !( $_->{end} > $_->{start} && $_->{end} <= $rn->[ $_->{i} + 1 ]->{start} ) } map { { %{ $rn->[$_] }, i => $_ } } 0 .. $#$rn - 1 ), 0, 'each item ends after its start, by the next one\'s start' );
	my ($gap) = grep { $_->{timeLabel} eq '8:00pm' } @$rn;
	is( $gap->{end}, t('2026-10-20T09:50:00Z'), 'its own rawEndTime (Big Ideas 8:00pm-8:50pm, then a gap to 9:00pm)' );

	my $perth = $SCH->parse( fixture_json('live/bff-schedule-LOCAL_PERTH-2026-10-19.trimmed.json'), 'Australia/Perth' );
	is( scalar @$perth, 13, 'LOCAL_PERTH: 13 items' );
	is_deeply( [ @{ $perth->[0] }{qw(timeLabel start)} ], [ '3:00am', t('2026-10-18T19:00:00Z') ], 'the broadcast day starts at 3:00am Perth (19:00Z the day before)' );
	is_deeply( [ @{ $perth->[-1] }{qw(timeLabel title end)} ], [ '11:00pm', 'Overnights', t('2026-10-19T19:00:00Z') ], '... and ends at 3:00am the next day: kept, not trimmed to midnight' );
	is( $perth->[3]->{programPath}, '/radio/programs/am', 'programPath' );
	is( $perth->[2]->{programPath}, '/radio/perth/programs/breakfast', 'programPath (local program)' );

	both_ways( sub {
		my $mode = shift;
		is( scalar( grep { $_->{timeLabel} ne $SCH->timeLabel( 'Australia/Sydney', $_->{start} ) } @$rn ), 0, "$mode: every RN start, formatted in Sydney time, is ABC's start string" );
		is( scalar( grep { $_->{timeLabel} ne $SCH->timeLabel( 'Australia/Perth', $_->{start} ) } @$perth ), 0, "$mode: every LOCAL_PERTH start, in Perth time, is ABC's start string" );
		is( $SCH->localDate( 'Australia/Perth', $perth->[0]->{start} ), '2026-10-19', "$mode: the first Perth item is on the 19th Perth time (the 18th UTC)" );
	} );
};

subtest 'parse: synthetic bodies' => sub {
	is_deeply( $SCH->parse( {}, 'Australia/Sydney' ), [], '{} (unknown service): no items' );
	is_deeply( $SCH->parse( { formattedScheduleArray => [] } ), [], 'formattedScheduleArray []: no items' );
	is_deeply( $SCH->parse( { formattedScheduleArray => [ { items => [] }, { timeBlockTitle => 'x' }, 'junk' ] } ), [], 'empty / item-less / junk blocks: no items' );
	is( $SCH->parse( [] ),    undef, 'a JSON array: undef' );
	is( $SCH->parse('text'), undef, 'a string: undef' );

	my $body = {
		formattedScheduleArray => [
			{ items => [
				{ title => 'No start', rawEndTime => '2026-10-19T01:00:00Z' },
				{ title => 'Bad start', rawStartTime => 'yesterday' },
				{ rawStartTime => '2026-10-19T02:00:00Z', title => '   ' },
				{ rawStartTime => '2026-10-19T03:00:00+00:00', title => "  Q&amp;A \n  Late  ", start => '2:00 PM', url => 'https://www.abc.net.au/triplej/',
					synopsis => '<p>Tom &amp; <b>Jerry</b></p>  talk', presenters => [ { displayName => ' A ' }, { displayName => '' }, 'x', { displayName => 'B &amp; C' } ] },
				{ rawStartTime => '2026-10-19T01:00:00Z', rawEndTime => '2026-10-19T04:00:00Z', title => 'Long', url => 'https://abc.net.au/listen/programs/long/', onNow => JSON::PP::true },
			] },
			{ items => [
				{ rawStartTime => '2026-10-19T03:30:00Z', rawEndTime => '2026-10-19T03:00:00Z', title => 'Backwards', url => '/news/2026-10-19/story/123' },
				{ rawStartTime => '2026-10-19T05:00:00Z', title => 'Last', url => '', start => 'soon' },
			] },
		],
	};
	my $items = $SCH->parse( $body, 'Australia/Sydney' );
	is_deeply( [ map { $_->{title} } @$items ], [ 'Long', 'Q&A Late', 'Backwards', 'Last' ], 'no/invalid start and blank titles skipped; sorted by start (overlaps kept)' );
	is( $items->[1]->{timeLabel}, '2:00pm', 'start string trimmed and lower-cased ("2:00 PM")' );
	is( $items->[3]->{timeLabel}, '4:00pm', 'unusable start string: start in the station tz (05:00Z = 4:00pm AEDT)' );
	is( $items->[1]->{end}, t('2026-10-19T03:30:00Z'), 'no rawEndTime: ends at the next start' );
	is( $items->[2]->{end}, t('2026-10-19T05:00:00Z'), 'an end before the start: the next start' );
	is( $items->[3]->{end}, undef, 'the last item without rawEndTime: no end' );
	is( $items->[0]->{end}, t('2026-10-19T04:00:00Z'), 'an overlapping item keeps its own end' );
	is( $items->[1]->{synopsis}, 'Tom & Jerry talk', 'synopsis: tags dropped, entities decoded, whitespace collapsed' );
	is( $items->[1]->{presenters}, 'A, B & C', 'presenters: trimmed, decoded, blanks and junk dropped' );
	is_deeply( [ map { $_->{programPath} } @$items ], [ '/listen/programs/long', undef, undef, undef ], 'programPath only for /programs/<slug> (abc.net.au without www ok); station home, news, empty -> undef' );
	is_deeply( [ map { $_->{onNow} } @$items ], [ 1, 0, 0, 0 ], 'onNow from a JSON boolean' );
	is( $items->[0]->{image}, undef, 'no cardImagePrepared: no image' );
	is( $items->[0]->{synopsis}, undef, 'no synopsis: undef' );

	is( Plugins::ABCListen::Schedule::_programPath($_), undef, "not a program page: $_" )
		for 'https://www.abc.net.au/listen/programs', 'https://www.abc.net.au/programs/', 'https://www.wnycstudios.org/podcasts/radiolab/programs/x';
	is( Plugins::ABCListen::Schedule::_programPath('https://www.abc.net.au/radio/programs/overnights/'), '/radio/programs/overnights', 'a generic network page links' );
};

# ---------------------------------------------------------------------------
# Station-local dates
# ---------------------------------------------------------------------------

subtest 'localDate / timeLabel at 2026-10-18T13:30Z in every catalogue zone (tzset and table)' => sub {
	my $at = t('2026-10-18T13:30:00Z');
	my %want = (
		'Australia/Sydney'      => [ '2026-10-19', '12:30am' ],
		'Australia/Melbourne'   => [ '2026-10-19', '12:30am' ],
		'Australia/Canberra'    => [ '2026-10-19', '12:30am' ],
		'Australia/Hobart'      => [ '2026-10-19', '12:30am' ],
		'Australia/Brisbane'    => [ '2026-10-18', '11:30pm' ],
		'Australia/Adelaide'    => [ '2026-10-19', '12:00am' ],
		'Australia/Broken_Hill' => [ '2026-10-19', '12:00am' ],
		'Australia/Darwin'      => [ '2026-10-18', '11:00pm' ],
		'Australia/Perth'       => [ '2026-10-18', '9:30pm' ],
	);
	my %catalogue = map { $_->{tz} => 1 } grep { $_->{tz} } Plugins::ABCListen::StationData::records();
	is_deeply( [ sort keys %catalogue ], [ sort keys %want ], 'these are exactly the catalogue\'s zones' );

	both_ways( sub {
		my $mode = shift;
		is_deeply( [ $SCH->localDate( $_, $at ), $SCH->timeLabel( $_, $at ) ], $want{$_}, "$mode: $_ @{ $want{$_} }" ) for sort keys %want;
		is( $SCH->localDate( 'Australia/Adelaide', $at - 1 ), '2026-10-18', "$mode: Adelaide one second earlier: still the 18th" );
		is( $SCH->localDate( 'Pacific/Nowhere', $at ), $mode eq 'table' ? '2026-10-19' : $SCH->localDate( 'Pacific/Nowhere', $at ), "$mode: an unknown zone does not die" );
	} );

	is( $SCH->localDate( 'Australia/Sydney', undef ), undef, 'no epoch: undef' );
	is( $SCH->timeLabel( 'Australia/Sydney', 'x' ),  undef, 'not an epoch: undef' );
};

subtest 'DST start (2026-10-04, 23 h) and end (2026-04-05, 25 h) days' => sub {
	both_ways( sub {
		my $mode = shift;

		# start: 2:00am AEST -> 3:00am AEDT (16:00Z); Adelaide 2:00am ACST -> 3:00am ACDT (16:30Z)
		is( $SCH->timeLabel( 'Australia/Sydney', t('2026-10-03T15:59:59Z') - 59 ), '1:59am', "$mode: Sydney 1:59am AEST before the change" );
		is( $SCH->timeLabel( 'Australia/Sydney', t('2026-10-03T16:00:00Z') ),      '3:00am', "$mode: ... then 3:00am AEDT" );
		is( $SCH->timeLabel( 'Australia/Adelaide', t('2026-10-03T16:29:00Z') ),    '1:59am', "$mode: Adelaide 1:59am ACST" );
		is( $SCH->timeLabel( 'Australia/Adelaide', t('2026-10-03T16:30:00Z') ),    '3:00am', "$mode: ... then 3:00am ACDT" );
		is( $SCH->timeLabel( 'Australia/Brisbane', t('2026-10-03T16:00:00Z') ),    '2:00am', "$mode: Brisbane: no DST" );
		is( $SCH->timeLabel( 'Australia/Hobart', t('2026-10-03T16:00:00Z') ),      '3:00am', "$mode: Hobart changes with Sydney" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-10-03T13:59:59Z') ), '2026-10-03', "$mode: Sydney 4 Oct starts at 14:00Z (AEST)" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-10-03T14:00:00Z') ), '2026-10-04', "$mode: ..." );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-10-04T12:59:59Z') ), '2026-10-04', "$mode: ... and ends at 13:00Z (AEDT): 23 h" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-10-04T13:00:00Z') ), '2026-10-05', "$mode: ..." );

		# end: 3:00am AEDT -> 2:00am AEST (16:00Z), the hour 2:00-2:59am twice
		is( $SCH->timeLabel( 'Australia/Sydney', t('2026-04-04T15:30:00Z') ), '2:30am', "$mode: Sydney 2:30am AEDT" );
		is( $SCH->timeLabel( 'Australia/Sydney', t('2026-04-04T16:30:00Z') ), '2:30am', "$mode: ... and 2:30am AEST an hour later (repeated hour)" );
		is( $SCH->timeLabel( 'Australia/Melbourne', t('2026-04-04T15:59:59Z') ), '2:59am', "$mode: Melbourne 2:59am AEDT" );
		is( $SCH->timeLabel( 'Australia/Melbourne', t('2026-04-04T16:00:00Z') ), '2:00am', "$mode: ... then 2:00am AEST" );
		is( $SCH->timeLabel( 'Australia/Broken_Hill', t('2026-04-04T16:30:00Z') ), '2:00am', "$mode: Broken Hill (Adelaide time) 2:00am ACST at 16:30Z" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-04-04T12:59:59Z') ), '2026-04-04', "$mode: Sydney 5 Apr starts at 13:00Z (AEDT)" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-04-04T13:00:00Z') ), '2026-04-05', "$mode: ..." );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-04-05T13:59:59Z') ), '2026-04-05', "$mode: ... and ends at 14:00Z (AEST): 25 h" );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-04-05T14:00:00Z') ), '2026-04-06', "$mode: ..." );
		is( $SCH->timeLabel( 'Australia/Brisbane', t('2026-01-15T00:00:00Z') ), '10:00am', "$mode: in summer Brisbane is an hour behind Sydney ..." );
		is( $SCH->timeLabel( 'Australia/Sydney',   t('2026-01-15T00:00:00Z') ), '11:00am', "$mode: ... (Sydney 11:00am)" );
	} );
};

subtest 'dayList: Today, Yesterday, then 5 dates, station-local, across DST, month and year ends' => sub {
	both_ways( sub {
		my $mode = shift;
		my $at   = t('2026-10-18T13:30:00Z');

		my $sydney = $SCH->dayList( 'Australia/Sydney', $at );
		is_deeply( [ map { $_->{date} } @$sydney ], [ map {"2026-10-$_"} qw(19 18 17 16 15 14 13) ], "$mode: Sydney (19 Oct): today and the 6 days before" );
		is_deeply( [ map { $_->{label} } @$sydney ], [ 'Today', 'Yesterday', 'Sat 17 Oct', 'Fri 16 Oct', 'Thu 15 Oct', 'Wed 14 Oct', 'Tue 13 Oct' ], "$mode: labels" );
		is_deeply( [ map { $_->{token} } @$sydney ], [ 'PLUGIN_ABCLISTEN_TODAY', 'PLUGIN_ABCLISTEN_YESTERDAY', (undef) x 5 ], "$mode: tokens for Today and Yesterday" );

		my $perth = $SCH->dayList( 'Australia/Perth', $at );
		is_deeply( [ map { $_->{date} } @$perth[ 0, 1 ] ], [ '2026-10-18', '2026-10-17' ], "$mode: Perth at the same instant: today is the 18th" );
		is( $perth->[2]->{label}, 'Fri 16 Oct', "$mode: ... and the first date label is Fri 16 Oct" );

		my $dst = $SCH->dayList( 'Australia/Sydney', t('2026-10-05T01:00:00Z') );
		is_deeply( [ map { $_->{date} } @$dst ], [qw(2026-10-05 2026-10-04 2026-10-03 2026-10-02 2026-10-01 2026-09-30 2026-09-29)], "$mode: across the 23 h day and a month end: no date skipped or repeated" );
		is( $dst->[5]->{label}, 'Wed 30 Sep', "$mode: Wed 30 Sep" );

		my $end = $SCH->dayList( 'Australia/Sydney', t('2026-04-06T00:30:00Z') );
		is_deeply( [ map { $_->{date} } @$end[ 0 .. 2 ] ], [qw(2026-04-06 2026-04-05 2026-04-04)], "$mode: across the 25 h day" );

		my $year = $SCH->dayList( 'Australia/Perth', t('2027-01-01T20:00:00Z') );
		is_deeply( [ map { $_->{label} } @$year ], [ 'Today', 'Yesterday', 'Thu 31 Dec', 'Wed 30 Dec', 'Tue 29 Dec', 'Mon 28 Dec', 'Sun 27 Dec' ], "$mode: across the year end (Perth, 2 Jan 2027)" );
		is( $year->[2]->{date}, '2026-12-31', "$mode: ... 2026-12-31" );
	} );

	my $days = $SCH->dayList( 'Australia/Sydney', t('2026-10-18T13:30:00Z') );
	is( scalar( grep { $_->{label} !~ /\A(?:Today|Yesterday|(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat) [1-9][0-9]? (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec))\z/ } @$days ), 0, 'every label is a word or a full date, never a bare number' );
};

subtest 'the fixed table agrees with tzset for every catalogue zone' => sub {
	plan skip_all => 'no zoneinfo on this system' unless $ZONEINFO;

	my %zones = map { $_->{tz} => 1 } grep { $_->{tz} } Plugins::ABCListen::StationData::records();
	my @instants;
	for my $year ( 2025 .. 2027 ) {
		for my $month ( 1 .. 12 ) {
			push @instants, map { Time::Local::timegm( 0, 0, $_, 15, $month - 1, $year ) } 0, 12;
		}
		for my $month ( 4, 10 ) {    # every 15 min for 4 h around the transitions (15:00Z-19:00Z the day before the first Sunday)
			my $sunday = Plugins::ABCListen::Schedule::_firstSunday( $year, $month );
			push @instants, map { $sunday - 86400 + 15 * 3600 + $_ * 900 } 0 .. 16;
		}
	}

	for my $tz ( sort keys %zones ) {
		my @bad = grep { Plugins::ABCListen::Schedule::_tzsetOffset( $tz, $_ ) != Plugins::ABCListen::Schedule::_tableOffset( $tz, $_ ) } @instants;
		is( scalar @bad, 0, "$tz: table = tzset at " . scalar(@instants) . ' instants' ) or diag join ', ', map { scalar gmtime($_) } @bad[ 0 .. ( $#bad < 4 ? $#bad : 4 ) ];
	}

	$SCH->_reset();
	ok( Plugins::ABCListen::Schedule::_zoneWorks('Australia/Perth'), 'with zoneinfo, tzset is used' );
};

subtest 'tzset without effect: the table; the process TZ is always restored' => sub {
	$SCH->_reset();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Schedule::_tzsetOffset = sub {0};    # like a system without zoneinfo: UTC
		ok( !Plugins::ABCListen::Schedule::_zoneWorks('Australia/Sydney'), 'offsets that disagree with the known instants: tzset not used' );
		is( $SCH->localDate( 'Australia/Sydney', t('2026-10-18T13:30:00Z') ), '2026-10-19', '... the table gives the Sydney date' );
		is( $SCH->timeLabel( 'Australia/Perth', t('2026-10-18T13:30:00Z') ), '9:30pm', '... and Perth time' );
	}
	$SCH->_reset();

	my $probe = t('2026-07-01T12:00:00Z');
	for my $env ( undef, 'UTC', 'America/New_York', 'Australia/Perth' ) {
		my $label = defined $env ? $env : 'unset';
		local $ENV{TZ} = $env;
		delete $ENV{TZ} unless defined $env;
		POSIX::tzset();
		my $names  = join ',', POSIX::tzname();    # (glibc: as set by tzset; localtime() may change it)
		my $before = join ',', localtime($probe);

		$SCH->localDate( 'Australia/Darwin', $probe );
		$SCH->dayList( 'Australia/Sydney', $probe );
		Plugins::ABCListen::Schedule::_tzsetOffset( 'Australia/Hobart', $probe );

		is( join( ',', POSIX::tzname() ), $names, "process TZ $label: the C library's zone (tzname) is re-read" );    # before localtime(), which may run tzset itself
		is( $ENV{TZ}, $env, "process TZ $label: \$ENV{TZ} restored" );
		is( exists $ENV{TZ} ? 1 : 0, defined $env ? 1 : 0, "process TZ $label: (not created)" );
		is( join( ',', localtime($probe) ), $before, "process TZ $label: localtime unchanged" );

		{
			no warnings 'redefine';
			local *Time::Local::timegm = sub { die "boom\n" };
			is( Plugins::ABCListen::Schedule::_tzsetOffset( 'Australia/Hobart', $probe ), undef, "process TZ $label: a conversion that dies -> undef" );
		}
		is( $ENV{TZ}, $env, "process TZ $label: ... and \$ENV{TZ} is restored" );
		is( join( ',', localtime($probe) ), $before, "process TZ $label: ... and localtime" );
	}
	POSIX::tzset();
};

# ---------------------------------------------------------------------------
# day()
# ---------------------------------------------------------------------------

subtest 'day: the request, the items, the station tz' => sub {
	reset_all();
	route( qr{/core-next/api/schedule\?.*service=RN&}, file => 'live/bff-schedule-RN-day.json' );
	route( qr{/core-next/api/schedule\?.*service=LOCAL_PERTH&}, file => 'live/bff-schedule-LOCAL_PERTH-2026-10-19.trimmed.json' );
	route( qr{/core-next/api/schedule\?}, content => '{}' );

	my $c = day_cb( 'RN', '2026-10-19' );
	is( $c->count, 1, 'one callback' );
	my ($items) = $c->args(0);
	is( scalar @$items, 4, 'the parsed items' );
	is_deeply( [ map { $_->{url} } schedule_requests() ], ["$SCHEDULE?date=2026-10-19&ratio=1x1&service=RN&tz=Australia%2FSydney"], 'GET schedule?date&ratio=1x1&service&tz (Sydney for RN)' );
	ok( ( grep { $_->{message} =~ m{Schedule request: service=RN date=2026-10-19 tz=Australia/Sydney} } logged('DEBUG') ), 'the request is logged at DEBUG with service, date and tz' );

	$c = day_cb( 'LOCAL_PERTH', '2026-10-18' );
	is( scalar @{ ( $c->args(0) )[0] }, 13, 'LOCAL_PERTH: 13 items' );
	like( ( schedule_requests() )[-1]->{url}, qr{date=2026-10-18&ratio=1x1&service=LOCAL_PERTH&tz=Australia%2FPerth\z}, 'LOCAL_PERTH: tz=Australia/Perth' );

	$c = day_cb( 'NOPE_XYZ', '2026-10-19' );
	is_deeply( [ $c->args(0) ], [ [] ], 'an id the catalogue doesn\'t know: ABC answers {} -> no items (no error)' );
	like( ( schedule_requests() )[-1]->{url}, qr{service=NOPE_XYZ&tz=Australia%2FSydney\z}, '... asked with Sydney time' );

	$c = day_cb( 'TRIPLEJ_PERTH', '2026-10-19' );
	like( ( schedule_requests() )[-1]->{url}, qr{service=TRIPLEJ_PERTH&tz=Australia%2FPerth\z}, 'a time-zone version uses its own id and tz' );
};

subtest 'day: cache 10 min for the station-local today, 24 h for past days' => sub {
	reset_all();
	route( qr{/core-next/api/schedule\?}, file => 'live/bff-schedule-RN-day.json' );

	day_cb( 'RN', '2026-10-19' );
	advanceTime(599);
	my $c = day_cb( 'RN', '2026-10-19' );
	is( scalar schedule_requests(), 1, 'today: cached for 599 s' );
	is( $c->count, 1, '... answered at once from the cache' );
	advanceTime(2);
	day_cb( 'RN', '2026-10-19' );
	is( scalar schedule_requests(), 2, '... asked again after 10 min' );

	reset_all();
	route( qr{/core-next/api/schedule\?}, file => 'live/bff-schedule-RN-day.json' );
	day_cb( 'RN', '2026-10-18' );
	advanceTime( 86400 - 1 );
	day_cb( 'RN', '2026-10-18' );
	is( scalar schedule_requests(), 1, 'yesterday: cached for 24 h' );
	advanceTime(2);
	day_cb( 'RN', '2026-10-18' );
	is( scalar schedule_requests(), 2, '... asked again after 24 h' );

	# station-local today: at 4pm Perth (8pm Sydney) both are the 19th; at 11pm Perth (2am Sydney) Sydney is on the 20th
	reset_all();
	route( qr{/core-next/api/schedule\?}, content => '{"formattedScheduleArray":[]}' );
	setTime( t('2026-10-19T15:00:00Z') );
	day_cb( 'LOCAL_PERTH', '2026-10-19' );
	day_cb( 'RN',          '2026-10-19' );
	advanceTime(601);
	day_cb( 'LOCAL_PERTH', '2026-10-19' );
	day_cb( 'RN',          '2026-10-19' );
	is_deeply( [ map { m{service=(\w+)} ? $1 : '?' } map { $_->{url} } schedule_requests() ], [qw(LOCAL_PERTH RN LOCAL_PERTH)], 'the 19th is still today in Perth (10 min) but yesterday in Sydney (24 h)' );

	# midnight: today's list (10 min) becomes yesterday's
	reset_all();
	route( qr{/core-next/api/schedule\?}, file => 'live/bff-schedule-RN-day.json' );
	setTime( t('2026-10-19T12:55:00Z') );    # 11:55pm Sydney
	day_cb( 'RN', '2026-10-19' );
	advanceTime(360);                        # 12:01am: the 19th is yesterday now
	day_cb( 'RN', '2026-10-19' );
	is( scalar schedule_requests(), 1, 'after midnight the cached list serves until its 10 min are up' );
	advanceTime(300);
	day_cb( 'RN', '2026-10-19' );
	advanceTime( 86400 - 60 );
	day_cb( 'RN', '2026-10-19' );
	is( scalar schedule_requests(), 2, '... then it is fetched once more and kept 24 h' );
};

subtest 'day: identical requests are coalesced; one callback each, each with its own copy' => sub {
	reset_all();
	route( qr{/core-next/api/schedule\?}, file => 'live/bff-schedule-RN-day.json', defer => 1 );

	my @c = map { collector() } 1 .. 3;
	$SCH->day( 'RN', '2026-10-19', sub { $c[0]->cb->(@_); die "caller 1 broke\n" } );
	$SCH->day( 'RN', '2026-10-19', $c[1]->cb );
	$SCH->day( 'RN', '2026-10-19', $c[2]->cb );
	my $other = day_cb( 'RN', '2026-10-18' );
	is( scalar schedule_requests(), 2, 'three callers, one request (another date: its own request)' );
	is( scalar( grep { $_->count } @c ), 0, 'nobody answered yet' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { $_->count } @c, $other ], [ 1, 1, 1, 1 ], 'each caller called back once, even after one callback died' );
	ok( ( grep { $_->{message} =~ /caller 1 broke/ } logged('ERROR') ), 'the dying callback is logged' );

	my @lists = map { ( $_->args(0) )[0] } @c;
	$lists[1]->[0]->{title} = 'changed';
	is( $lists[2]->[0]->{title}, 'Download This Show', 'every caller has its own copy' );
	is( ( day_cb( 'RN', '2026-10-19' )->args(0) )[0]->[0]->{title}, 'Download This Show', '... and the cache is untouched' );
};

subtest 'day: errors, empty days, invalid arguments - exactly one callback' => sub {
	my @cases = (
		[ '500',          { code => 500, content => 'oops' },                                  [ undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ] ],
		[ '429',          { code => 429, content => 'slow down' },                             [ undef, 'PLUGIN_ABCLISTEN_RATE_LIMITED' ] ],
		[ 'bad JSON',     { code => 200, content => '{"formattedScheduleArray":' },            [ undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ] ],
		[ 'a JSON array', { code => 200, content => '[1,2]' },                                 [ undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ] ],
		[ 'timeout',      { error => 'Timed out waiting for data' },                           [ undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ] ],
		[ '{}',           { code => 200, content => '{}' },                                    [ [] ] ],
		[ 'event-only',   { code => 200, content => '{"formattedScheduleArray":[],"papiServiceIds":["SPORT_BBL"]}' }, [ [] ] ],
	);

	for my $case (@cases) {
		my ( $label, $response, $want ) = @$case;
		reset_all();
		route( qr{/core-next/api/schedule\?}, %$response );
		my $c = day_cb( 'RN', '2026-10-19' );
		is( $c->count, 1, "$label: one callback" );
		is_deeply( [ $c->args(0) ], $want, "$label: " . ( defined $want->[1] ? $want->[1] : 'no items' ) );
		day_cb( 'RN', '2026-10-19' );
		if ( $label eq 'a JSON array' ) {    # a successful HTTP response: API.pm keeps it for the ttl, the parse fails again
			is_deeply( [ ( day_cb( 'RN', '2026-10-19' ) )->args(0) ], $want, "$label: still LOAD_FAILED (API.pm keeps the body, no new request)" );
			next;
		}
		is( scalar schedule_requests(), defined $want->[1] ? 2 : 1, defined $want->[1] ? "$label: not cached" : "$label: cached" );
	}

	reset_all();
	for my $args ( [ 'rn', '2026-10-19' ], [ 'RN', '2026-02-30' ], [ 'RN', '19/10/2026' ], [ undef, '2026-10-19' ], [ 'RN', undef ], [ [], {} ] ) {
		my $c = collector();
		$SCH->day( @$args, $c->cb );
		is_deeply( [ $c->count, $c->args(0) ], [ 1, undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ], 'invalid (' . join( ', ', map { defined $_ ? ( ref $_ || $_ ) : 'undef' } @$args ) . '): LOAD_FAILED at once' );
	}
	is( scalar schedule_requests(), 0, 'no request for invalid arguments' );
	ok( eval { $SCH->day( 'RN', '2026-10-19', undef ); 1 }, 'no callback: does not die' );

	reset_all();
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::API::bff = sub { die "client broke\n" };
		my $c = day_cb( 'RN', '2026-10-19' );
		is_deeply( [ $c->count, $c->args(0) ], [ 1, undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ], 'API::bff dies: LOAD_FAILED, once' );
		$c = day_cb( 'RN', '2026-10-19' );
		is( $c->count, 1, '... and the next call is not stuck behind it' );
	}
	{
		no warnings 'redefine';
		local *Plugins::ABCListen::Schedule::parse = sub { die "parser broke\n" };
		route( qr{/core-next/api/schedule\?}, file => 'live/bff-schedule-RN-day.json' );
		my $c = day_cb( 'RN', '2026-10-18' );
		is_deeply( [ $c->count, $c->args(0) ], [ 1, undef, 'PLUGIN_ABCLISTEN_LOAD_FAILED' ], 'parsing dies: LOAD_FAILED, once' );
	}
	is( scalar Slim::Utils::Timers::pending(), 0, 'no timers' );
};

done_testing();
