package Plugins::ABCListen::Follow;

# Followed programs (M2): the list behind My ABC listen, kept only in this LMS's prefs. Data only:
# no menu code, no network I/O, nothing sent to ABC, no account.
#
# ---- Storage --------------------------------------------------------------------------------------
#   Pref `followed` in the namespace plugin.abclisten (ai-state/streams.md contract 8; MyABC->init
#   initialises it to [] and validates it as an array). Server-wide: one list per LMS, shared by
#   every player (MQ1). The value is an array of
#       { path, id, title, image, network, followedAt, unfollowedAt }
#   path is the key: the canonical program path (API::sitePath: no host, query or trailing '/');
#   followedAt and unfollowedAt are epoch seconds; id, image and network are absent when unknown.
#   Nothing else is ever stored (prefs are readable by any client through the `pref` CLI query).
#   The array order is the follow order, oldest follow first: a new follow is appended, and a
#   refresh or a re-follow keeps its place. Nothing is ever sorted, so a follow never moves a row.
#   A followed program has no unfollowedAt. An entry with unfollowedAt is a program unfollowed
#   recently (a tombstone): not followed, but kept at its place for UNFOLLOW_TTL (30 min), so the
#   Followed programs and Latest episodes menus keep their rows (LMS re-opens stale item ids by
#   index; see MyABC.pm).
#   Tombstones live in the pref itself, so they survive an LMS restart; they expire 30 min after
#   the unfollow: reads ignore them from then on, and the next write drops them.
#   Every write sets a fresh array of fresh hashes (never the stored arrayref changed in place), so
#   LMS sees the change and saves it. Every write re-reads the current list first.
#   A corrupt pref never dies: a value that isn't an array reads as empty; entries that aren't hashes
#   or have no site path are dropped, later duplicates of a path are dropped, unknown keys and
#   non-scalar values are ignored, and a tombstone with a bad unfollowedAt has expired; the next
#   write stores the clean list.
#
# ---- Functions (class methods or plain functions) --------------------------------------------------
#   follow(\%program) -> the stored entry (a copy), or undef without a site path in $program->{path}
#       Takes title, id, image and network from \%program (other keys are ignored). title falls
#       back to the path's last segment. Following a followed path refreshes its title, id, image
#       and network (non-empty new values win) in place and keeps its followedAt. Following a
#       program unfollowed less than UNFOLLOW_TTL ago restores its entry in place, with its
#       followedAt (an undo). Otherwise the entry is appended with followedAt = now. At most
#       MAX_FOLLOWED (200) are followed: a new follow beyond that unfollows the followed entry with
#       the oldest followedAt (the first in the list on a tie; logged at INFO), which becomes a
#       tombstone like any unfollow.
#   unfollow($path) -> 1 if a followed entry became a tombstone (unfollowedAt = now), else 0
#       (idempotent: nothing is written then).
#   At most MAX_FOLLOWED tombstones are kept: beyond that a write drops the oldest unfollows.
#   isFollowed($path) -> 1 | 0 (a tombstone is not followed).
#   list() -> copies of the followed entries, in follow order (no tombstones).
#   listWithUnfollowed() -> copies of the followed entries and of the tombstones (with their
#       unfollowedAt), in follow order: each tombstone at its place. For the Followed programs menu
#       and Latest episodes (M4: an unfollowed program keeps its rows there until the tombstone
#       expires).
#   programPathFor($episodePath) -> program path | undef. Pure. The prefix of the canonical
#       episode path up to and including the segment after the first /programs/ or /audiobooks/
#       segment: '/listen/programs/scienceshow/<slug>/107266790' -> '/listen/programs/scienceshow',
#       '/triplej/programs/<prog>/...' -> '/triplej/programs/<prog>',
#       '/listen/audiobooks/<book>/...' -> '/listen/audiobooks/<book>'. undef when there is no such
#       segment, or nothing after it. (O4 derives "More from" the same way, from the same table.)
#
# Owned by the myabc stream (M2).

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::ABCListen::API;

use constant PREF         => 'followed';
use constant MAX_FOLLOWED => 200;
use constant UNFOLLOW_TTL => 1800;    # seconds a tombstone keeps its row

# the optional entry keys, besides path, title and followedAt
my @OPTIONAL = qw(id image network);

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

sub follow {
	shift if _isClass( $_[0] );
	my $program = shift;
	return undef unless ref $program eq 'HASH';

	my $path = _path( $program->{path} );
	return undef unless defined $path;

	my @entries = _read();
	my ($at) = grep { $entries[$_]->{path} eq $path } 0 .. $#entries;
	my $old = defined $at ? $entries[$at] : undef;

	# a followed entry is refreshed and a tombstone restored (with its followedAt), both in place
	my %entry = ( $old ? %$old : (), path => $path );
	delete $entry{unfollowedAt};
	$entry{title} = _text( $program->{title} ) // $entry{title} // _lastSegment($path);
	for my $key (@OPTIONAL) {
		my $value = _text( $program->{$key} );
		$entry{$key} = $value if defined $value;
	}
	$entry{followedAt} = $old ? $old->{followedAt} : time();

	if ( defined $at ) {
		$entries[$at] = \%entry;
	}
	else {
		push @entries, \%entry;
	}

	# the cap: unfollow the oldest follows (never the one just made); their rows stay a while
	my @followed = grep { _isFollowedEntry( $entries[$_] ) } 0 .. $#entries;
	if ( ( my $excess = @followed - MAX_FOLLOWED ) > 0 ) {
		my @oldest = sort { $entries[$a]->{followedAt} <=> $entries[$b]->{followedAt} || $a <=> $b } grep { $entries[$_]->{path} ne $path } @followed;
		for my $i ( @oldest[ 0 .. $excess - 1 ] ) {
			$entries[$i] = { %{ $entries[$i] }, unfollowedAt => time() };
			main::INFOLOG && $log->is_info && $log->info( 'Followed programs: more than ' . MAX_FOLLOWED . " followed, so the oldest follow was unfollowed: $entries[$i]->{title} ($entries[$i]->{path})" );
		}
	}

	_write( \@entries );

	return {%entry};
}

sub unfollow {
	shift if _isClass( $_[0] );
	my $path = _path(shift);
	return 0 unless defined $path;

	my @entries = _read();
	my ($at) = grep { _isFollowedEntry( $entries[$_] ) && $entries[$_]->{path} eq $path } 0 .. $#entries;
	return 0 unless defined $at;

	$entries[$at] = { %{ $entries[$at] }, unfollowedAt => time() };

	_write( \@entries );
	return 1;
}

sub isFollowed {
	shift if _isClass( $_[0] );
	my $path = _path(shift);
	return 0 unless defined $path;
	return ( grep { _isFollowedEntry($_) && $_->{path} eq $path } _read() ) ? 1 : 0;
}

sub list {
	shift if _isClass( $_[0] );
	my @followed = grep { _isFollowedEntry($_) } _read();
	return @followed;
}

sub listWithUnfollowed {
	shift if _isClass( $_[0] );
	my @entries = _read();
	return @entries;
}

sub programPathFor {
	shift if _isClass( $_[0] );
	my $path = _path(shift);
	return undef unless defined $path;

	my ($program) = $path =~ m{\A((?:/[^/]+)*?/(?:programs|audiobooks)/[^/]+)(?:/|\z)};
	return $program;
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

# The stored list as fresh, clean copies (see "Storage" above): the followed entries and the live
# tombstones, in the stored order. Expired tombstones are left out.
sub _read {
	my $stored = $prefs->get(PREF);
	return () unless ref $stored eq 'ARRAY';

	my $now = time();
	my ( %seen, @entries );
	for my $item (@$stored) {
		next unless ref $item eq 'HASH';

		my $path = _path( $item->{path} );
		next if !defined $path || $seen{$path}++;

		my %entry = (
			path       => $path,
			title      => _text( $item->{title} ) // _lastSegment($path),
			followedAt => _epoch( $item->{followedAt} ),
		);
		for my $key (@OPTIONAL) {
			my $value = _text( $item->{$key} );
			$entry{$key} = $value if defined $value;
		}

		# a tombstone lives UNFOLLOW_TTL (either way, should the clock have moved back)
		if ( defined $item->{unfollowedAt} ) {
			my $unfollowedAt = _epoch( $item->{unfollowedAt} );
			next unless $unfollowedAt && abs( $now - $unfollowedAt ) < UNFOLLOW_TTL;
			$entry{unfollowedAt} = $unfollowedAt;
		}

		push @entries, \%entry;
	}

	return @entries;
}

# Store fresh copies of the entries, keeping at most MAX_FOLLOWED tombstones (the newest unfollows).
sub _write {
	my $entries = shift;
	my @keep = 0 .. $#$entries;

	my @tombstones = grep { !_isFollowedEntry( $entries->[$_] ) } @keep;
	if ( ( my $excess = @tombstones - MAX_FOLLOWED ) > 0 ) {
		my @oldest = ( sort { $entries->[$a]->{unfollowedAt} <=> $entries->[$b]->{unfollowedAt} || $a <=> $b } @tombstones )[ 0 .. $excess - 1 ];
		my %drop = map { $_ => 1 } @oldest;
		@keep = grep { !$drop{$_} } @keep;
	}

	$prefs->set( PREF, [ map { +{ %{ $entries->[$_] } } } @keep ] );
	return;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Canonical site path of a program or episode, or undef ('/' alone is no program).
sub _path {
	my $path = Plugins::ABCListen::API::sitePath(shift);
	return defined $path && $path ne '/' ? $path : undef;
}

sub _lastSegment {
	my ($segment) = $_[0] =~ m{([^/]+)\z};
	return defined $segment ? $segment : $_[0];
}

# A trimmed, non-empty plain string, else undef.
sub _text {
	my $value = shift;
	return undef unless defined $value && !ref $value;
	$value =~ s/\A\s+|\s+\z//g;
	return length $value ? $value : undef;
}

sub _epoch { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? $_[0] + 0 : 0 }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# A followed entry (from _read), not a tombstone.
sub _isFollowedEntry { !exists $_[0]->{unfollowedAt} }

1;
