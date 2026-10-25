package Plugins::ABCListen::Util;

# Shared constants and pure helper functions for the ABC listen plugin:
#   - constants: display name, icon, cache namespace, ABC site base;
#   - topWeight: the canonical weights that order the top-level menu (home, radio, ...);
#   - parseISO8601: ISO-8601 date-times with a UTC offset (ABC's APIs send 'Z' or an offset) -> epoch;
#   - display helpers in the LMS server's local time zone (localtime): friendlyDate,
#     friendlyTime, friendlyDuration. ABC data spans AEST/AEDT/ACST/ACDT/AWST, so times are
#     parsed with their offsets and shown in the server's zone, never with a fixed offset;
#   - decodeEntities;
#   - the URL contract (ai-state/streams.md contract 2): abclisten://live/<SERVICE_ID> and
#     abclisten://episode/<digits>; liveUrl / episodeUrl / parseUrl;
#   - the episode metadata cache contract (streams.md contract 3): setEpisodeMeta / getEpisodeMeta,
#     and (F7) D5's seenAt rule for the writers that seed renditions: episodeSeenAt /
#     episodeMetaIsNewer / episodeAudioKeys.
#
# Owned by the foundation stream: other streams may only append to it (and must say so in their PR).

use strict;
use warnings;

use Time::Local qw(timegm);

use Slim::Utils::Cache;

use Exporter qw(import);
our @EXPORT_OK = qw(
	DISPLAY_NAME ICON CACHE_NAMESPACE SITE_BASE EPISODE_META_TTL
	DEFAULT_TOP_WEIGHT topWeight
	parseISO8601 friendlyDate friendlyTime friendlyDuration
	decodeEntities
	liveUrl episodeUrl parseUrl
	setEpisodeMeta getEpisodeMeta
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use constant DISPLAY_NAME => 'ABC listen';
use constant ICON         => 'plugins/ABCListen/html/images/icon.png';
use constant SITE_BASE    => 'https://www.abc.net.au';

use constant CACHE_NAMESPACE  => 'abclisten';    # Slim::Utils::Cache namespace (create it without a version)
use constant EPISODE_META_TTL => 30 * 86400;     # seconds

my @DAY_NAMES   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH_NAMES = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# ---------------------------------------------------------------------------
# Top-level menu weights
# ---------------------------------------------------------------------------

# The top-level menu mirrors the ABC listen app/site navigation. Hooks put a `weight` on each
# top-level item (Plugin.pm sorts by it), always by name through topWeight, never a bare number.
my %TOP_WEIGHTS = (
	home       => 10,
	radio      => 20,
	podcasts   => 30,
	news       => 40,
	sport      => 50,
	kids       => 60,
	audiobooks => 70,
	programs   => 75,
	search     => 80,
	myabc      => 90,
);

# Weight of a top-level item without one (or with a non-numeric one).
use constant DEFAULT_TOP_WEIGHT => 100;

# topWeight('radio') -> 20. undef for an unknown name.
sub topWeight {
	my $name = shift;
	return defined $name ? $TOP_WEIGHTS{$name} : undef;
}

# ---------------------------------------------------------------------------
# Date and time
# ---------------------------------------------------------------------------

# ISO-8601 date-time -> epoch, e.g. '2026-10-19T06:30:00+11:00', '...+1100', '...Z',
# '...T06:30:00.123Z', '...T06:30+10:00'. Without an offset the time is taken as UTC.
# Returns undef if invalid (years 1970..2100 only, ASCII digits only).
sub parseISO8601 {
	my $string = shift;
	return undef unless defined $string;

	my ( $y, $mo, $d, $h, $mi, $s, $tz ) = $string =~ /\A\s*([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?\s*\z/i
		or return undef;

	my $epoch = _timegm( $y, $mo, $d, $h, $mi, $s || 0 );
	return undef unless defined $epoch;

	my $offset = 0;
	if ( defined $tz && uc $tz ne 'Z' ) {
		my ( $sign, $oh, $om ) = $tz =~ /^([+-])([0-9]{2}):?([0-9]{2})$/;
		return undef if $oh > 23 || $om > 59;
		$offset = ( $oh * 3600 + $om * 60 ) * ( $sign eq '-' ? -1 : 1 );
	}

	return $epoch - $offset;
}

# epoch -> 'Mon 19 Oct' in the server's local time zone; ' 2025' is added when the year isn't the
# current local year ('Sun 19 Oct 2025'). undef if not an epoch.
sub friendlyDate {
	my @t = _localTime(shift) or return undef;

	my $date = sprintf( '%s %d %s', $DAY_NAMES[ $t[6] ], $t[3], $MONTH_NAMES[ $t[4] ] );
	$date .= ' ' . ( $t[5] + 1900 ) if $t[5] != ( localtime( time() ) )[5];

	return $date;
}

# epoch -> '6:30am' in the server's local time zone (12-hour clock, minutes always shown,
# '12:00am' is midnight, '12:00pm' noon). undef if not an epoch.
sub friendlyTime {
	my @t = _localTime(shift) or return undef;
	return sprintf( '%d:%02d%s', $t[2] % 12 || 12, $t[1], $t[2] < 12 ? 'am' : 'pm' );
}

# seconds -> '54 min' or '1 h 05 min', rounded to the nearest minute (at least '1 min' for
# anything above 0 s; 59.5 minutes or more show as hours). '' for undef, 0, negative or
# non-numeric input.
sub friendlyDuration {
	my $secs = shift;
	return '' unless defined $secs && $secs =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $secs > 0;

	my $mins = int( $secs / 60 + 0.5 ) || 1;
	return "$mins min" if $mins < 60;

	return sprintf( '%d h %02d min', int( $mins / 60 ), $mins % 60 );
}

sub _localTime {
	my $epoch = shift;
	return () unless defined $epoch && $epoch =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
	return localtime( int $epoch );
}

sub _timegm {
	my ( $y, $mo, $d, $h, $mi, $s ) = @_;
	return undef unless _isValidDate( $y, $mo, $d ) && $h <= 23 && $mi <= 59 && $s <= 59;
	return eval { timegm( $s, $mi, $h, $d, $mo - 1, $y ) };
}

# Dates are only valid in the years 1970..2100. This also stops Time::Local reading a year
# such as '0026' as 2026.
sub _isValidDate {
	my ( $y, $m, $d ) = @_;
	return 0 if $y < 1970 || $y > 2100 || $m < 1 || $m > 12 || $d < 1;

	my $leap = ( $y % 4 == 0 && $y % 100 != 0 ) || $y % 400 == 0;
	my @days = ( 31, $leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );

	return $d <= $days[ $m - 1 ];
}

# ---------------------------------------------------------------------------
# HTML entities
# ---------------------------------------------------------------------------

# LMS bundles HTML::Entities; plain Perl may not have it, so there is a built-in fallback that
# covers numeric entities and the common named ones.
our $HAS_HTML_ENTITIES = eval { require HTML::Entities; 1 } ? 1 : 0;

my %ENTITIES = (
	amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => "\x{A0}",
	ndash => "\x{2013}", mdash => "\x{2014}", lsquo => "\x{2018}", rsquo => "\x{2019}", sbquo => "\x{201A}",
	ldquo => "\x{201C}", rdquo => "\x{201D}", bdquo => "\x{201E}", bull => "\x{2022}", hellip => "\x{2026}",
	prime => "\x{2032}", euro => "\x{20AC}", trade => "\x{2122}", laquo => "\x{AB}", raquo => "\x{BB}",
	copy => "\x{A9}", reg => "\x{AE}", deg => "\x{B0}", middot => "\x{B7}", times => "\x{D7}", divide => "\x{F7}",
	iexcl => "\x{A1}", cent => "\x{A2}", pound => "\x{A3}", yen => "\x{A5}", sect => "\x{A7}", para => "\x{B6}",
	plusmn => "\x{B1}", frac14 => "\x{BC}", frac12 => "\x{BD}", frac34 => "\x{BE}", iquest => "\x{BF}",
	szlig => "\x{DF}",
);

# Latin-1 letters: &Agrave; (U+00C0) .. &yuml; (U+00FF), skipping times/divide/szlig.
{
	my @names = qw(
		Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml
		ETH Ntilde Ograve Oacute Ocirc Otilde Ouml - Oslash Ugrave Uacute Ucirc Uuml Yacute THORN -
		agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
		eth ntilde ograve oacute ocirc otilde ouml - oslash ugrave uacute ucirc uuml yacute thorn yuml
	);
	for my $i ( 0 .. $#names ) {
		$ENTITIES{ $names[$i] } = chr( 0xC0 + $i ) unless $names[$i] eq '-';
	}
}

# Decode HTML entities (&amp; &#8217; &#x27; &nbsp; ...) into characters. Non-breaking spaces
# become plain spaces. Unknown entities are left alone. undef stays undef.
sub decodeEntities {
	my $string = shift;
	return undef unless defined $string;

	if ($HAS_HTML_ENTITIES) {
		$string = HTML::Entities::decode_entities($string);
	}
	else {
		$string = _decodeEntitiesPP($string);
	}

	$string =~ s/\x{A0}/ /g;
	return $string;
}

sub _decodeEntitiesPP {
	my $string = shift;

	$string =~ s{&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|([A-Za-z][A-Za-z0-9]*));}{
		defined $1 ? _chr($1, "&#$1;")
		: defined $2 ? _chr(hex $2, "&#x$2;")
		: exists $ENTITIES{$3} ? $ENTITIES{$3} : "&$3;"
	}ge;

	return $string;
}

sub _chr {
	my ( $code, $original ) = @_;
	return ( $code > 0 && $code <= 0x10FFFF ) ? chr($code) : $original;
}

# ---------------------------------------------------------------------------
# URL contract (streams.md contract 2)
# ---------------------------------------------------------------------------

# liveUrl($serviceId) -> 'abclisten://live/<SERVICE_ID>'
#   $serviceId: upper-case PAPI/BFF service id, [A-Z0-9_]+ (e.g. TRIPLEJ, TRIPLEJ_PERTH, LOCAL_SYDNEY)
# episodeUrl($id) -> 'abclisten://episode/<id>'
#   $id: CoreMedia id, ASCII digits only (audioepisode, audio and audiosegment documents)
# Both return undef for an id outside its pattern, so every URL they make round-trips through
# parseUrl. Nothing may follow an id (not even a newline).
sub liveUrl {
	my $id = shift;
	return _isServiceId($id) ? "abclisten://live/$id" : undef;
}

sub episodeUrl {
	my $id = shift;
	return _isEpisodeId($id) ? "abclisten://episode/$id" : undef;
}

# parseUrl($url) -> { kind => 'live' | 'episode', id => $id }, or undef for anything else
# (other schemes, unknown kinds, lower-case service ids, empty ids, extra path segments,
# trailing slashes, queries, fragments).
sub parseUrl {
	my $url = shift;
	return undef unless defined $url;

	if ( my ($id) = $url =~ m{\Aabclisten://live/([A-Z0-9_]+)\z} ) {
		return { kind => 'live', id => $id };
	}

	if ( my ($id) = $url =~ m{\Aabclisten://episode/([0-9]+)\z} ) {
		return { kind => 'episode', id => $id };
	}

	return undef;
}

sub _isServiceId { defined $_[0] && $_[0] =~ /\A[A-Z0-9_]+\z/ }
sub _isEpisodeId { defined $_[0] && $_[0] =~ /\A[0-9]+\z/ }

# ---------------------------------------------------------------------------
# Episode metadata cache contract (streams.md contract 3)
# ---------------------------------------------------------------------------

# setEpisodeMeta($id, \%meta): merge \%meta into the cached entry for episode $id and keep it for
# EPISODE_META_TTL (30 days) from this write.
# Shape: { id, docType, title, programTitle, programId, path (canonical site path), image,
#          description, date (epoch), duration (seconds) } plus optional { renditions =>
#          [ { url, mime, bitrate } ], availableTo, downloadAvailableTo, seenAt }.
# Merge rule: new non-empty values replace the cached ones; undef, '', [] and {} never clobber an
# existing field; fields not in \%meta are kept. Code refs are dropped (the cache can't store
# them). id is always $id.
# Returns 1 when stored; 0 (and nothing changes) if $id isn't an episode id (digits) or \%meta
# has no non-empty value.
sub setEpisodeMeta {
	my ( $id, $meta ) = @_;
	return 0 unless _isEpisodeId($id) && ref $meta eq 'HASH';

	my %new = map { $_ => $meta->{$_} } grep { $_ ne 'id' && _hasValue( $meta->{$_} ) } keys %$meta;
	return 0 unless %new;

	my $cache = _cache();
	my $old   = $cache->get( _metaKey($id) );

	my %entry = ( ( ref $old eq 'HASH' ? %$old : () ), %new, id => "$id" );
	$cache->set( _metaKey($id), \%entry, EPISODE_META_TTL );

	return 1;
}

# getEpisodeMeta($id) -> the merged metadata hashref (a copy), or undef.
sub getEpisodeMeta {
	my $id = shift;
	return undef unless _isEpisodeId($id);

	my $meta = _cache()->get( _metaKey($id) );
	return ref $meta eq 'HASH' ? $meta : undef;
}

sub _hasValue {
	my $value = shift;

	return 0 unless defined $value;
	return length $value ? 1 : 0 unless ref $value;
	return @$value ? 1 : 0 if ref $value eq 'ARRAY';
	return %$value ? 1 : 0 if ref $value eq 'HASH';
	return ref $value eq 'CODE' || ref $value eq 'GLOB' ? 0 : 1;    # objects such as JSON booleans are values
}

sub _metaKey { "episode-meta:$_[0]" }

sub _cache { Slim::Utils::Cache->new(CACHE_NAMESPACE) }

# ---------------------------------------------------------------------------
# F7: seenAt from the fetch time (contract 3). D5's rule (Audiobooks.pm), shared by every writer
# that seeds renditions: Search (D3), the episode resolver (O1) and Audiobooks (D5).
# ---------------------------------------------------------------------------

# O1 (Episode.pm SEEN_MAX_AGE) plays cached renditions without asking ABC while their seenAt is
# younger than this.
use constant EPISODE_SEEN_MAX_AGE => 6 * 3600;    # seconds

# The audio data a seenAt vouches for, written together or not at all.
my @EPISODE_AUDIO_KEYS = qw(renditions availableTo downloadAvailableTo seenAt);

# episodeAudioKeys() -> ('renditions', 'availableTo', 'downloadAvailableTo', 'seenAt')
sub episodeAudioKeys { @EPISODE_AUDIO_KEYS }

# episodeSeenAt(\%info[, $now]) -> the seenAt to store with the renditions of one API.pm answer,
# \%info being that answer's success info (contract 5): the answer's fetch time (info at), when
# the answer is not a stale (last-good) copy and is younger than EPISODE_SEEN_MAX_AGE at $now
# (default time()); else undef: the renditions are stored without a seenAt, so O1 asks ABC before
# it trusts them. Never the time the answer was mapped: API.pm serves cached answers up to an hour
# (Search, episode documents) or a day (Audiobooks) old.
sub episodeSeenAt {
	my ( $info, $now ) = @_;
	return undef unless ref $info eq 'HASH' && !$info->{stale} && _isEpoch( $info->{at} );

	$now = time() unless defined $now;
	return $now - $info->{at} < EPISODE_SEEN_MAX_AGE ? $info->{at} + 0 : undef;
}

# episodeMetaIsNewer($id, $at) -> 1 when the episode meta cache holds audio data newer than an
# answer fetched at $at (an epoch; undef or not a number counts as older than anything dated): the
# cached seenAt is later than $at, or O1 closed the cached windows (both ends set to the same past
# moment: a restricted or not yet released episode) later than $at. The answer's renditions,
# window ends and seenAt (episodeAudioKeys) are then not written: an older answer never overwrites
# newer audio data. Else 0 (also without an entry). Strictly later (D5 had "not older"): the cache
# holding this same answer's seenAt (a menu walked again from API.pm's cache) is not newer data, so
# a re-walk gives the same rows.
sub episodeMetaIsNewer {
	my ( $id, $at ) = @_;
	$at = 0 unless _isEpoch($at);

	my $cached = getEpisodeMeta($id);
	return 0 unless ref $cached eq 'HASH';

	return 1 if _isEpoch( $cached->{seenAt} ) && $cached->{seenAt} > $at;

	my ( $to, $downloadTo ) = @$cached{qw(availableTo downloadAvailableTo)};
	return 1 if _isEpoch($to) && _isEpoch($downloadTo) && $to == $downloadTo && $to <= time() && $to > $at;

	return 0;
}

sub _isEpoch { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+(?:\.[0-9]+)?\z/ ? 1 : 0 }

1;
