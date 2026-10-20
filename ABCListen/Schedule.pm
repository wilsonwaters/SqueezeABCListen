package Plugins::ABCListen::Schedule;

# A live station's day schedule from ABC's BFF (research abc-listen-api.md section 5):
# GET https://www.abc.net.au/core-next/api/schedule?service=<ID>&date=YYYY-MM-DD&tz=<station tz>&ratio=1x1
# through API::bff, plus station-local dates. Data only: the station menu (Live.pm, L4) builds the
# menus.
#
#   Schedule->day($id, $date, $cb)    $cb->(\@items) or $cb->(undef, $errorToken): exactly one call,
#                                     synchronous from the cache (and for invalid arguments), else
#                                     when the request is done. \@items empty: no schedule for that
#                                     day (ABC answered {}, an empty formattedScheduleArray or only
#                                     empty blocks: an unknown service, an event-only or HLS-only one).
#                                     $errorToken: PLUGIN_ABCLISTEN_LOAD_FAILED (HTTP error, timeout,
#                                     bad JSON, invalid arguments) or PLUGIN_ABCLISTEN_RATE_LIMITED (429).
#                                     tz is the station's (Stations->get($id)->{tz}); Australia/Sydney
#                                     for an id the catalogue doesn't know.
#   parse($data, $tz)                 pure: the decoded schedule body -> \@items (undef when $data is
#                                     not a hash)
#   localDate($tz, $epoch)            'YYYY-MM-DD' of $epoch in time zone $tz
#   dayList($tz, $now)                [ { date, label, token? } x 7 ]: the station-local date of $now
#                                     and the 6 dates before it. label 'Today' (token
#                                     PLUGIN_ABCLISTEN_TODAY), 'Yesterday' (PLUGIN_ABCLISTEN_YESTERDAY),
#                                     then 'Sat 17 Oct' built from the date itself (English names, as
#                                     Util::friendlyDate). Day arithmetic is on calendar dates, so DST
#                                     days (23 h, 25 h) never skip or repeat a date.
#   timeLabel($tz, $epoch)            '6:00am' in time zone $tz
#   dateLabel('YYYY-MM-DD')           'Mon 19 Oct' (undef for anything else)
#   zoneCity($tz)                     the city whose clock a station zone keeps, for "<City> time":
#                                     Sydney (Sydney, Melbourne, Canberra, Hobart: one eastern
#                                     clock), Brisbane (no DST), Adelaide (Adelaide, Broken Hill),
#                                     Darwin, Perth; another zone: its last part ('America/New_York'
#                                     -> 'New York'); no zone: Sydney
#
# Each can be called as a function or as a class method.
#
# $item = { start, end, title, synopsis, image, presenters, programPath, onNow, timeLabel }
#   start, end   epochs from rawStartTime / rawEndTime (Util::parseISO8601). Items without a valid
#                rawStartTime (or without a title) are skipped; without rawEndTime an item ends at the
#                next item's start (undef for the last one).
#   title        entity-decoded, whitespace collapsed, trimmed ("Law Report " -> "Law Report")
#   synopsis     plain text (tags dropped, entities decoded, whitespace collapsed), or undef
#   image        cardImagePrepared's srcSet entry for about IMAGE_PX (340) px (API::imageUrl), or undef
#   presenters   presenters[].displayName joined with ', ', or undef
#   programPath  API::sitePath(url) when that path contains /programs/<slug> (old-style
#                /radionational/programs/<slug> too), else undef (station homes, off-site, news, none)
#   onNow        ABC's onNow flag, 1 or 0 (the menu marks "on air" by start <= now < end instead)
#   timeLabel    ABC's start string ("6:00am", already in the requested tz), trimmed and lower-case;
#                without one, start formatted in the station tz
# Items are sorted by start (ABC's order for equal starts). ABC's day is a broadcast day (RN 12am-12am
# Sydney, LOCAL_PERTH 3am-3am Perth): items are kept as returned, never trimmed to midnight.
#
# Cache (in memory, per service and date): the station-local today (and any later date)
# TODAY_TTL (10 min), earlier days PAST_TTL (24 h); the same ttl is passed to API::bff, so the copy
# survives an LMS restart. Errors are not cached. Identical requests are coalesced: one upstream
# request for every caller; each caller gets its own copy, and a caller whose callback dies doesn't
# stop the others.
#
# Station-local time (LQ3, no DateTime::TimeZone): the zone's UTC offset at an instant comes from
# localtime() with a localised $ENV{TZ} and POSIX::tzset (the process TZ is restored, and tzset run
# again, afterwards, also when that dies). Where tzset has no effect (no zoneinfo, e.g. Windows),
# detected per zone by comparing two known instants (2026-01-15 and 2026-07-15) with the fixed
# table below, the table is used: Sydney, Melbourne, Hobart, Canberra +10/+11; Adelaide, Broken Hill
# +9:30/+10:30; Brisbane +10; Darwin +9:30; Perth +8; AU DST from the first Sunday of October 02:00
# standard time to the first Sunday of April 03:00 daylight time. An unknown zone without tzset
# reads as Australia/Sydney.
#
# Owned by the live stream: L4 creates (ai-state/streams.md, rule 5).

use strict;
use warnings;

use POSIX ();
use Storable ();
use Time::Local ();

use Slim::Utils::Log;
use Slim::Utils::Strings ();

use Plugins::ABCListen::API;
use Plugins::ABCListen::Stations;
use Plugins::ABCListen::Util;

use constant TODAY_TTL => 600;      # seconds
use constant PAST_TTL  => 86400;
use constant TIMEOUT   => 10;       # seconds per request
use constant IMAGE_PX  => 340;
use constant DAYS      => 7;        # today and the 6 days before
use constant MAX_ENTRIES => 100;    # cache entries before expired ones are dropped

use constant DEFAULT_TZ   => 'Australia/Sydney';
use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';

# instants that tell whether tzset works for a zone (southern summer and winter)
use constant PROBE_SUMMER => 1_768_435_200;    # 2026-01-15T00:00:00Z
use constant PROBE_WINTER => 1_784_073_600;    # 2026-07-15T00:00:00Z

my $log = logger('plugin.abclisten');

my @DAY_NAMES   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH_NAMES = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# tz => [ standard offset (s), AU DST rule? ] for every tz in the station catalogue
my %TABLE = (
	'Australia/Sydney'      => [ 36000, 1 ],
	'Australia/Melbourne'   => [ 36000, 1 ],
	'Australia/Hobart'      => [ 36000, 1 ],
	'Australia/Canberra'    => [ 36000, 1 ],
	'Australia/Adelaide'    => [ 34200, 1 ],
	'Australia/Broken_Hill' => [ 34200, 1 ],
	'Australia/Brisbane'    => [ 36000, 0 ],
	'Australia/Darwin'      => [ 34200, 0 ],
	'Australia/Perth'       => [ 28800, 0 ],
);

# the city whose clock each catalogue zone keeps ("<City> time"; one label for the eastern clock)
my %ZONE_CITY = (
	'Australia/Sydney'      => 'Sydney',
	'Australia/Melbourne'   => 'Sydney',
	'Australia/Hobart'      => 'Sydney',
	'Australia/Canberra'    => 'Sydney',
	'Australia/Brisbane'    => 'Brisbane',
	'Australia/Adelaide'    => 'Adelaide',
	'Australia/Broken_Hill' => 'Adelaide',
	'Australia/Darwin'      => 'Darwin',
	'Australia/Perth'       => 'Perth',
);

my %CACHE;          # "$id|$date" => { items, expires }
my %WAITERS;        # "$id|$date" => [ callbacks ] while a request is in flight
my %ZONE_WORKS;     # tz => 1 | 0: whether tzset gives that zone's offsets
our $NO_TZSET = 0;  # tests: 1 = always use the table

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub day {
	shift if _isClass( $_[0] );
	my ( $id, $date, $cb ) = @_;

	my $once = _once($cb);

	if ( !_isServiceId($id) || !_isDate($date) ) {
		$log->warn( 'Schedule: invalid service id or date (' . _show($id) . ', ' . _show($date) . ')' );
		return _call( $once, undef, LOAD_FAILED );
	}

	my $key = "$id|$date";
	_prune();

	if ( my $entry = $CACHE{$key} ) {
		return _call( $once, _copy( $entry->{items} ) ) if time() < $entry->{expires};
		delete $CACHE{$key};
	}

	if ( my $waiters = $WAITERS{$key} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Schedule $id $date: joining the request in flight");
		push @$waiters, $once;
		return;
	}

	$WAITERS{$key} = [$once];

	my $tz  = _stationTz($id);
	my $ttl = $date ge localDate( $tz, time() ) ? TODAY_TTL : PAST_TTL;

	main::DEBUGLOG && $log->is_debug && $log->debug("Schedule request: service=$id date=$date tz=$tz (cache $ttl s)");

	my $settled = 0;
	my $settle  = sub {
		my ( $items, $error ) = @_;
		return if $settled++;

		my $waiters = delete $WAITERS{$key} || [];

		if ($items) {
			$CACHE{$key} = { items => $items, expires => time() + $ttl };
		}

		for my $waiter (@$waiters) {
			$items ? _call( $waiter, _copy($items) ) : _call( $waiter, undef, $error );
		}

		return;
	};

	eval {
		Plugins::ABCListen::API::bff(
			'schedule',
			{ service => $id, date => $date, tz => $tz, ratio => '1x1' },
			sub {
				my $data  = shift;
				my $items = eval { parse( $data, $tz ) };
				$log->error( "Schedule $id $date: could not read the schedule: " . _clean($@) ) if $@;

				if ( ref $items eq 'ARRAY' ) {
					$settle->($items);
				}
				else {
					$log->warn("Schedule $id $date: unexpected response") unless $@;
					$settle->( undef, LOAD_FAILED );
				}
			},
			sub {
				my $error = shift;
				my $token = ref $error eq 'HASH' && ( $error->{error} || '' ) eq RATE_LIMITED ? RATE_LIMITED : LOAD_FAILED;
				$settle->( undef, $token );
			},
			{ ttl => $ttl, timeout => TIMEOUT },
		);
		1;
	} or do {
		$log->error( "Schedule $id $date: request failed: " . _clean($@) );
		$settle->( undef, LOAD_FAILED );
	};

	return;
}

sub parse {
	shift if _isClass( $_[0] );
	my ( $data, $tz ) = @_;

	return undef unless ref $data eq 'HASH';
	$tz = DEFAULT_TZ unless _isText($tz);

	my $blocks = ref $data->{formattedScheduleArray} eq 'ARRAY' ? $data->{formattedScheduleArray} : [];

	my ( @items, $order );
	for my $block ( grep { ref $_ eq 'HASH' } @$blocks ) {
		for my $raw ( grep { ref $_ eq 'HASH' } @{ ref $block->{items} eq 'ARRAY' ? $block->{items} : [] } ) {
			my $item = _item( $raw, $tz ) or next;
			$item->{_order} = $order++;
			push @items, $item;
		}
	}

	@items = sort { $a->{start} <=> $b->{start} || $a->{_order} <=> $b->{_order} } @items;

	for my $i ( 0 .. $#items ) {
		my $item = $items[$i];
		delete $item->{_order};

		if ( !defined $item->{end} && $i < $#items ) {
			$item->{end} = $items[ $i + 1 ]->{start};
		}
	}

	return \@items;
}

sub localDate {
	shift if _isClass( $_[0] );
	my ( $tz, $epoch ) = @_;

	my @t = _zoneParts( $tz, $epoch ) or return undef;
	return sprintf( '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] );
}

sub dayList {
	shift if _isClass( $_[0] );
	my ( $tz, $now ) = @_;
	$now = time() unless defined $now;

	my $today = localDate( $tz, $now ) or return [];
	my ( $y, $m, $d ) = split /-/, $today;
	my $noon = Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y );

	my @days;
	for my $back ( 0 .. DAYS - 1 ) {
		my @g    = gmtime( $noon - $back * 86400 );
		my $date = sprintf( '%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3] );
		my %day  = ( date => $date, label => dateLabel($date) );

		if ( $back < 2 ) {
			$day{token} = $back ? 'PLUGIN_ABCLISTEN_YESTERDAY' : 'PLUGIN_ABCLISTEN_TODAY';
			my $string = Slim::Utils::Strings::string( $day{token} );
			$day{label} = $string if defined $string;
		}

		push @days, \%day;
	}

	return \@days;
}

sub dateLabel {
	shift if _isClass( $_[0] );
	my $date = shift;
	return undef unless _isDate($date);

	my ( $y, $m, $d ) = split /-/, $date;
	my @g = gmtime( Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y ) );

	return sprintf( '%s %d %s', $DAY_NAMES[ $g[6] ], $g[3], $MONTH_NAMES[ $g[4] ] );
}

sub zoneCity {
	shift if _isClass( $_[0] );
	my $tz = shift;
	$tz = DEFAULT_TZ unless _isText($tz);

	return $ZONE_CITY{$tz} if $ZONE_CITY{$tz};

	( my $city = $tz ) =~ s{\A.*/}{};
	$city =~ s/_/ /g;
	return length $city ? $city : $ZONE_CITY{ +DEFAULT_TZ };
}

sub timeLabel {
	shift if _isClass( $_[0] );
	my ( $tz, $epoch ) = @_;

	my @t = _zoneParts( $tz, $epoch ) or return undef;
	return sprintf( '%d:%02d%s', $t[2] % 12 || 12, $t[1], $t[2] < 12 ? 'am' : 'pm' );
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

sub _item {
	my ( $raw, $tz ) = @_;

	my $start = _epoch( $raw->{rawStartTime} );
	return undef unless defined $start;

	my $title = _cleanText( $raw->{title} );
	return undef unless defined $title;

	my $end = _epoch( $raw->{rawEndTime} );

	my @presenters = grep { defined } map { _cleanText( ref $_ eq 'HASH' ? $_->{displayName} : undef ) }
		@{ ref $raw->{presenters} eq 'ARRAY' ? $raw->{presenters} : [] };

	my $time = _cleanText( $raw->{start} );
	$time = defined $time && $time =~ /\A[0-9]{1,2}:[0-9]{2}\s*[ap]m\z/i ? lc $time : timeLabel( $tz, $start );
	$time =~ s/\s+//g;

	return {
		start       => $start,
		end         => defined $end && $end > $start ? $end : undef,
		title       => $title,
		synopsis    => _synopsis( $raw->{synopsis} ),
		image       => Plugins::ABCListen::API::imageUrl( ref $raw->{cardImagePrepared} eq 'HASH' ? $raw->{cardImagePrepared} : undef, IMAGE_PX ),
		presenters  => @presenters ? join( ', ', @presenters ) : undef,
		programPath => _programPath( $raw->{url} ),
		onNow       => $raw->{onNow} ? 1 : 0,    # JSON booleans overload bool
		timeLabel   => $time,
	};
}

# The site path of a program page: '/listen/programs/scienceshow', '/radionational/programs/breakfast',
# '/radio/programs/am'; anything else (station home, other hosts, news, empty) -> undef.
sub _programPath {
	my $path = Plugins::ABCListen::API::sitePath(shift);
	return defined $path && $path =~ m{/programs/[^/]+} ? $path : undef;
}

sub _synopsis {
	my $synopsis = shift;
	return undef unless defined $synopsis;

	my $text = ref $synopsis ? Plugins::ABCListen::API::richText($synopsis) : do {
		( my $s = $synopsis ) =~ s/<[^>]*>/ /g;
		$s;
	};

	return _cleanText($text);
}

# entity-decoded, whitespace collapsed, trimmed; undef when empty or not a string
sub _cleanText {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::ABCListen::Util::decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/\A | \z//g;

	return length $text ? $text : undef;
}

sub _epoch {
	my $value = shift;
	return undef unless defined $value && !ref $value;
	return Plugins::ABCListen::Util::parseISO8601($value);
}

# ---------------------------------------------------------------------------
# Station-local time
# ---------------------------------------------------------------------------

# localtime-style parts of $epoch in zone $tz, or () without an epoch.
sub _zoneParts {
	my ( $tz, $epoch ) = @_;
	return () unless defined $epoch && !ref $epoch && $epoch =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;

	$epoch = int $epoch;
	$tz    = DEFAULT_TZ unless _isText($tz);

	my $offset = _offset( $tz, $epoch );
	return gmtime( $epoch + $offset );
}

# UTC offset (s) of zone $tz at $epoch: tzset when it works for the zone, else the table.
sub _offset {
	my ( $tz, $epoch ) = @_;

	if ( _zoneWorks($tz) ) {
		my $offset = _tzsetOffset( $tz, $epoch );
		return $offset if defined $offset;
	}

	return _tableOffset( $tz, $epoch );
}

sub _zoneWorks {
	my $tz = shift;
	return 0 if $NO_TZSET;

	return $ZONE_WORKS{$tz} //= do {
		my @probe = map { _tzsetOffset( $tz, $_ ) } PROBE_SUMMER, PROBE_WINTER;

		if ( grep { !defined } @probe ) {
			0;
		}
		elsif ( $TABLE{$tz} ) {
			$probe[0] == _tableOffset( $tz, PROBE_SUMMER ) && $probe[1] == _tableOffset( $tz, PROBE_WINTER ) ? 1 : 0;
		}
		else {
			# not in the table: trust a zone that isn't UTC at both instants
			$probe[0] || $probe[1] ? 1 : 0;
		}
	};
}

# The offset from localtime() under TZ=$tz; the process TZ is restored (and tzset run again)
# afterwards, also when this dies. undef on failure.
sub _tzsetOffset {
	my ( $tz, $epoch ) = @_;
	my $offset;

	{
		local $ENV{TZ} = $tz;
		eval {
			POSIX::tzset();
			my @t = localtime($epoch);
			$offset = Time::Local::timegm( @t[ 0 .. 4 ], $t[5] + 1900 ) - $epoch;
			1;
		} or undef $offset;
	}

	eval { POSIX::tzset(); 1 };

	return $offset;
}

sub _tableOffset {
	my ( $tz, $epoch ) = @_;

	my ( $standard, $dst ) = @{ $TABLE{$tz} || $TABLE{ +DEFAULT_TZ } };
	return $standard unless $dst;

	# AU DST: from the first Sunday of October 02:00 standard time to the first Sunday of April
	# 03:00 daylight time (02:00 standard time), both in the year of the local standard time
	my $year  = ( gmtime( $epoch + $standard ) )[5] + 1900;
	my $start = _firstSunday( $year, 10 ) + 2 * 3600 - $standard;
	my $end   = _firstSunday( $year, 4 ) + 2 * 3600 - $standard;

	return $epoch >= $start || $epoch < $end ? $standard + 3600 : $standard;
}

# 00:00 UTC of the first Sunday of month $month (1-12) of $year, as an epoch
sub _firstSunday {
	my ( $year, $month ) = @_;
	my $first = Time::Local::timegm( 0, 0, 0, 1, $month - 1, $year );
	my $wday  = ( gmtime($first) )[6];
	return $first + ( ( 7 - $wday ) % 7 ) * 86400;
}

# Drop expired entries once the cache holds more than MAX_ENTRIES.
sub _prune {
	return if keys %CACHE <= MAX_ENTRIES;
	my $now = time();
	delete @CACHE{ grep { $CACHE{$_}->{expires} <= $now } keys %CACHE };
	return;
}

sub _stationTz {
	my $id  = shift;
	my $rec = eval { Plugins::ABCListen::Stations->get($id) };
	return ref $rec eq 'HASH' && _isText( $rec->{tz} ) ? $rec->{tz} : DEFAULT_TZ;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub { return if $called++; $cb->(@_) if ref $cb eq 'CODE' };
}

sub _call {
	my ( $cb, @args ) = @_;
	eval { $cb->(@args); 1 } or $log->error( 'Schedule callback failed: ' . _clean($@) );
	return;
}

sub _copy {
	my $data = shift;
	my $copy = eval { Storable::dclone($data) };
	return defined $copy ? $copy : $data;
}

sub _clean {
	my $error = shift;
	$error = 'unknown error' unless defined $error && length $error;
	$error =~ s/\s+at \S+ line \d+.*//s;
	$error =~ s/\s+\z//;
	return $error;
}

sub _isText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

sub _isServiceId { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[A-Z0-9_]+\z/ }

sub _isDate {
	my $date = shift;
	return 0 unless defined $date && !ref $date;
	my ( $y, $m, $d ) = $date =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/ or return 0;
	return eval { Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y ); 1 } && $y >= 1970 && $y <= 2100 ? 1 : 0;
}

sub _show { defined $_[0] ? ( ref $_[0] ? ref $_[0] : "'$_[0]'" ) : 'undef' }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# Forget all state (for tests).
sub _reset {
	%CACHE      = ();
	%WAITERS    = ();
	%ZONE_WORKS = ();
	return;
}

1;
