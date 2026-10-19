package Plugins::ABCListen::Follow;

# Followed programs (M2): the list behind My ABC listen, kept only in this LMS's prefs. Data only:
# no menu code, no network I/O, nothing sent to ABC, no account.
#
# ---- Storage --------------------------------------------------------------------------------------
#   Pref `followed` in the namespace plugin.abclisten (ai-state/streams.md contract 8; MyABC->init
#   initialises it to [] and validates it as an array). Server-wide: one list per LMS, shared by
#   every player (MQ1). The value is an array of
#       { path, id, title, image, network, followedAt }
#   path is the key: the canonical program path (API::sitePath: no host, query or trailing '/');
#   followedAt is epoch seconds; id, image and network are absent when unknown. Nothing else is
#   ever stored (prefs are readable by any client through the `pref` CLI query).
#   Every write sets a fresh array of fresh hashes (never the stored arrayref changed in place), so
#   LMS sees the change and saves it. Every write re-reads the current list first.
#   A corrupt pref never dies: a value that isn't an array reads as empty; entries that aren't hashes
#   or have no site path are dropped, later duplicates of a path are dropped, unknown keys and
#   non-scalar values are ignored; the next write stores the clean list.
#
# ---- Functions (class methods or plain functions) --------------------------------------------------
#   follow(\%program) -> the stored entry (a copy), or undef without a site path in $program->{path}
#       Takes title, id, image and network from \%program (other keys are ignored). title falls
#       back to the path's last segment. Following a followed path refreshes its title, id, image
#       and network (non-empty new values win) and keeps its followedAt. At most MAX_FOLLOWED (200):
#       a new follow beyond that drops the entry with the oldest followedAt (logged at INFO).
#   unfollow($path) -> 1 if an entry was removed, else 0 (idempotent; nothing is written then).
#   isFollowed($path) -> 1 | 0.
#   list() -> copies of every entry, sorted by Programs::sortKey(title), then title, then path.
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
use Plugins::ABCListen::Programs;

use constant PREF         => 'followed';
use constant MAX_FOLLOWED => 200;

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
	my ($old) = grep { $_->{path} eq $path } @entries;

	my %entry = ( $old ? %$old : (), path => $path );
	$entry{title} = _text( $program->{title} ) // $entry{title} // _lastSegment($path);
	for my $key (@OPTIONAL) {
		my $value = _text( $program->{$key} );
		$entry{$key} = $value if defined $value;
	}
	$entry{followedAt} = $old ? $old->{followedAt} : time();

	@entries = ( ( grep { $_->{path} ne $path } @entries ), \%entry );

	# the cap: drop the oldest follows (never the one just made)
	while ( @entries > MAX_FOLLOWED ) {
		my ($oldest) = sort { $a->{followedAt} <=> $b->{followedAt} || $a->{path} cmp $b->{path} } grep { $_->{path} ne $path } @entries;
		@entries = grep { $_->{path} ne $oldest->{path} } @entries;
		main::INFOLOG && $log->is_info && $log->info( 'Followed programs: more than ' . MAX_FOLLOWED . " followed, so the oldest follow was dropped: $oldest->{title} ($oldest->{path})" );
	}

	_write( \@entries );

	return {%entry};
}

sub unfollow {
	shift if _isClass( $_[0] );
	my $path = _path(shift);
	return 0 unless defined $path;

	my @entries = _read();
	my @kept    = grep { $_->{path} ne $path } @entries;
	return 0 if @kept == @entries;

	_write( \@kept );
	return 1;
}

sub isFollowed {
	shift if _isClass( $_[0] );
	my $path = _path(shift);
	return 0 unless defined $path;
	return ( grep { $_->{path} eq $path } _read() ) ? 1 : 0;
}

sub list {
	shift if _isClass( $_[0] );
	my @entries = _read();
	my %key = map { $_->{path} => Plugins::ABCListen::Programs::sortKey( $_->{title} ) } @entries;
	my @sorted = sort { $key{ $a->{path} } cmp $key{ $b->{path} } || $a->{title} cmp $b->{title} || $a->{path} cmp $b->{path} } @entries;
	return @sorted;
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

# The stored list as fresh, clean copies (see "Storage" above).
sub _read {
	my $stored = $prefs->get(PREF);
	return () unless ref $stored eq 'ARRAY';

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

		push @entries, \%entry;
	}

	return @entries;
}

sub _write {
	my $entries = shift;
	$prefs->set( PREF, [ map { +{%$_} } @$entries ] );
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

1;
