package Plugins::ABCListen::Tracklist;

# Episode tracklists (O4): the music an ABC listen episode played, from its episode document
# (pageProps.data.documentProps.tracklistPrepared, ai-state/research/abc-listen-api.md §4.2).
# Data only: no menu code. The episode submenu (OnDemand::_episodeMenu) and the episode song info
# (Episode.pm) build their rows from these functions.
#
#   fetch(\%episode, $cb)
#       \%episode = { id (digits: keys the parsed rows), path (the episode's site path) }; other
#       keys are ignored. Calls $cb EXACTLY ONCE with one hashref:
#         { items => [ rows ] }   success; [] means no tracklist: tracklistPrepared missing, null
#                                 or without items, or a page without an episode document (an
#                                 audiobook chapter's path leads to its book page; no WARN).
#         { error => TOKEN }      the API's token (PLUGIN_ABCLISTEN_LOAD_FAILED): a 404 after F3's
#                                 buildId refresh, a transport error, bad JSON, no answer within
#                                 FETCH_TIMEOUT (8 s), a document that can't be read, or no path
#                                 (then nothing is requested; logged at DEBUG only).
#       Rows already parsed for the id (cached) answer synchronously, without the API. Otherwise
#       the document comes from API::nextData(path, ..., { ttl => 3600, timeout => 8, quiet => 1 }):
#       the same path and TTL as O1's resolver (Episode.pm DOCUMENT_TTL), so F3's cache and its
#       request coalescing are shared: an episode resolved for playback needs no second request,
#       and concurrent opens of one episode make one request. F3's cache hits call back
#       synchronously too.
#       The parsed rows are cached under 'tracklist-rows:<id>' (cache namespace abclisten) for
#       ROWS_TTL (1 h). A failure (the deadline included) is cached too, under
#       'tracklist-failed:<id>' (else the path) for FAILURE_TTL (90 s): until then fetch answers
#       that { error } at once, synchronously, without asking ABC (LMS re-walks menus by item id,
#       so every open below an episode menu would otherwise wait the 8 s again while ABC is
#       slow). A result arriving after the 8 s deadline answered is still cached (the next open
#       is instant), never answered; a success removes the cached failure.
#       A failure is logged at WARN once per episode (again only after a success), with
#       quiet => 1 so F3 itself logs it at DEBUG. A $cb that dies is logged (ERROR), never
#       called again. fetch never dies: an API call that dies is a failure like any other.
#
#   cached($id) -> [ rows ] (a copy; [] = no tracklist) | undef (nothing cached, a bad id).
#       Synchronous, no I/O.
#
#   parse($pageProps) -> [ rows ]. Pure; never dies on bad shapes (anything unexpected reads as
#       no tracklist). Rows in ABC's order: { title, artist?, time? } from
#       tracklistPrepared.items[]: title, artist (ABC's composer for classical music), time =
#       timestampRelative ('00:55', '1:02:38'; kept only in that m:ss / h:mm:ss shape). Text is
#       entity-decoded, trimmed and whitespace-collapsed; ABC's " | " between several artists
#       becomes " & " ('O'Connell, Finneas & O'Connell, Billie Eilish'); an item without a title
#       is skipped; absent values have no key. When pagination.total says ABC has more items than it sent
#       (e.g. 31 of which 3 arrived), the items present are kept and that is logged at DEBUG.
#
#   formatRow($row) -> "<time> · <artist> – <title>", e.g.
#       '00:55 · Rossini, Gioachino – The Barber of Seville: Overture'. Without a time:
#       "<artist> – <title>"; without an artist: "<time> · <title>" or the title alone; undef
#       for a row without a title (or not a hash). Text is taken as parse() left it (decoded
#       once): formatRow only trims, it never decodes again.
#
# Owned by the ondemand stream (O4).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Util qw(CACHE_NAMESPACE decodeEntities);

use constant DOCUMENT_TTL  => 3600;    # = Episode.pm DOCUMENT_TTL: one F3 cache entry per episode document
use constant FETCH_TIMEOUT => 8;       # seconds: the request's timeout and the deadline of a whole fetch
use constant ROWS_TTL      => 3600;    # seconds: parsed rows
use constant FAILURE_TTL   => 90;      # seconds: a failed fetch is answered from the cache, without asking ABC again
use constant LOAD_FAILED   => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

use constant ENDASH => "\x{2013}";
use constant MIDDOT => "\x{B7}";

my $log = logger('plugin.abclisten');

my %warned;    # episode key => 1 once a failure has been logged at WARN (until a success)

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

sub fetch {
	shift if _isClass( $_[0] );
	my ( $episode, $cb ) = @_;

	if ( ref $cb ne 'CODE' ) {
		$log->error('Tracklist fetch called without a callback');
		return;
	}

	$episode = {} unless ref $episode eq 'HASH';

	my $id   = _digits( $episode->{id} );
	my $path = Plugins::ABCListen::API::sitePath( $episode->{path} );
	my $key  = defined $id ? $id : defined $path ? $path : 'unknown';

	my $state = { cb => $cb, key => $key };

	if ( !defined $path || $path eq '/' ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Tracklist of episode $key: no episode page, nothing to fetch");
		return _answer( $state, { error => LOAD_FAILED } );
	}

	if ( defined $id && defined( my $rows = cached($id) ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Tracklist of episode $id: from the cache");
		return _answer( $state, { items => $rows } );
	}

	# a recent failure (e.g. a slow ABC): answer it again at once, so re-walking the menus by
	# item id doesn't wait for the deadline every time
	if ( defined( my $token = _recentFailure($key) ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Tracklist of episode $key: failed less than " . FAILURE_TTL . ' s ago; not asking ABC again yet' );
		return _answer( $state, { error => $token } );
	}

	$state->{timer} = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + FETCH_TIMEOUT, sub {
		delete $state->{timer};
		return if $state->{answered};
		_failed( $state, 'no answer from ABC within ' . FETCH_TIMEOUT . ' s' );
	} );

	eval {
		Plugins::ABCListen::API::nextData(
			$path,
			sub { _document( $state, $id, $path, shift ) },
			sub {
				my $error = shift;
				_failed( $state, "$path failed (" . ( ref $error eq 'HASH' && defined $error->{message} ? $error->{message} : 'unknown error' ) . ')', $error );
			},
			{ ttl => DOCUMENT_TTL, timeout => FETCH_TIMEOUT, quiet => 1 },
		);
		1;
	} or _failed( $state, "requesting $path failed: " . ( $@ || 'unknown error' ) );

	return;
}

sub _document {
	my ( $state, $id, $path, $pageProps ) = @_;

	my $rows = eval { parse($pageProps) };
	return _failed( $state, "reading the episode document $path failed: " . ( $@ || 'unknown error' ) ) unless ref $rows eq 'ARRAY';

	if ( defined $id ) {
		eval { _cache()->set( _cacheKey($id), $rows, ROWS_TTL ); 1 }
			or $log->error( "Tracklist of episode $id: couldn't cache it: " . ( $@ || 'unknown error' ) );
	}

	# a success ends the episode's failure state: the next failure is cached and warned about again
	delete $warned{ $state->{key} };
	eval { _cache()->remove( _failureKey( $state->{key} ) ); 1 };

	main::DEBUGLOG && $log->is_debug && $log->debug( "Tracklist of episode $state->{key}: " . scalar(@$rows) . ' rows' . ( $state->{answered} ? ' (after the deadline: cached only)' : '' ) );

	return _answer( $state, { items => $rows } );
}

# A failure: WARN once per episode, then LOAD_FAILED (or the API's token) unless answered already.
sub _failed {
	my ( $state, $why, $error ) = @_;

	if ( $warned{ $state->{key} }++ ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Tracklist of episode $state->{key}: $why");
	}
	else {
		$log->warn("Tracklist of episode $state->{key}: $why");
	}

	my $token = ref $error eq 'HASH' && defined $error->{error} && !ref $error->{error} && $error->{error} =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/ ? $error->{error} : LOAD_FAILED;

	eval { _cache()->set( _failureKey( $state->{key} ), $token, FAILURE_TTL ); 1 }
		or $log->error( "Tracklist of episode $state->{key}: couldn't cache the failure: " . ( $@ || 'unknown error' ) );

	return _answer( $state, { error => $token } );
}

# Call back once; later answers are dropped.
sub _answer {
	my ( $state, $result ) = @_;
	return if $state->{answered}++;

	Slim::Utils::Timers::killSpecific( delete $state->{timer} ) if $state->{timer};

	my $cb = delete $state->{cb};
	eval { $cb->($result); 1 } or $log->error( "Tracklist of episode $state->{key}: the callback died: " . ( $@ || 'unknown error' ) );

	return;
}

sub cached {
	shift if _isClass( $_[0] );
	my $id = _digits(shift);
	return undef unless defined $id;

	my $rows = eval { _cache()->get( _cacheKey($id) ) };
	return ref $rows eq 'ARRAY' ? [ grep { ref $_ eq 'HASH' } @$rows ] : undef;
}

sub _cacheKey { 'tracklist-rows:' . $_[0] }

# The negative cache: an episode's failed fetch (its error token) for FAILURE_TTL, by id (else path).
sub _failureKey { 'tracklist-failed:' . $_[0] }

sub _recentFailure {
	my $token = eval { _cache()->get( _failureKey(shift) ) };
	return defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/ ? $token : undef;
}

sub _cache { Slim::Utils::Cache->new(CACHE_NAMESPACE) }

# ---------------------------------------------------------------------------
# Parsing and formatting
# ---------------------------------------------------------------------------

sub parse {
	shift if _isClass( $_[0] );
	my $pageProps = shift;

	my $data      = _hash( _hash($pageProps)->{data} );
	my $tracklist = _hash( _hash( $data->{documentProps} )->{tracklistPrepared} );
	my $items     = ref $tracklist->{items} eq 'ARRAY' ? $tracklist->{items} : [];

	my @rows;
	for my $item ( grep { ref $_ eq 'HASH' } @$items ) {
		my $title = _text( $item->{title} );
		next unless defined $title;

		my %row = ( title => $title );

		# ABC joins several artists with " | " ("O'Connell, Finneas | O'Connell, Billie Eilish"):
		# " & " reads better, also to a screen reader
		my $artist = _text( $item->{artist} );
		$artist = join( ' & ', grep {length} split /\s*\|\s*/, $artist ) if defined $artist;
		$row{artist} = $artist if defined $artist && length $artist;

		my $time = _text( $item->{timestampRelative} );
		$row{time} = $time if defined $time && $time =~ /\A[0-9]{1,3}:[0-5][0-9](?::[0-5][0-9])?\z/;

		push @rows, \%row;
	}

	my $total = _hash( $tracklist->{pagination} )->{total};
	if ( main::DEBUGLOG && defined $total && !ref $total && $total =~ /\A[0-9]+\z/ && $total > @$items && $log->is_debug ) {
		$log->debug( "Tracklist: ABC lists $total items but sent " . scalar(@$items) . '; showing those' );
	}

	return \@rows;
}

sub formatRow {
	shift if _isClass( $_[0] );
	my $row = shift;
	return undef unless ref $row eq 'HASH';

	# rows are parse()'s, decoded once already: only trimmed here (a literal "&amp;" stays as it is)
	my $title = _trim( $row->{title} );
	return undef unless defined $title;

	my $artist = _trim( $row->{artist} );
	my $time   = _trim( $row->{time} );

	my $text = defined $artist ? $artist . ' ' . ENDASH . ' ' . $title : $title;
	return defined $time ? $time . ' ' . MIDDOT . ' ' . $text : $text;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Entity-decoded, trimmed, whitespace-collapsed text, or undef if empty (or not a string).
sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;
	return _trim( decodeEntities($text) );
}

# Trimmed, whitespace-collapsed text (no decoding), or undef if empty (or not a string).
sub _trim {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text =~ s/\s+/ /g;
	$text =~ s/\A | \z//g;

	return length $text ? $text : undef;
}

sub _hash   { ref $_[0] eq 'HASH' ? $_[0] : {} }
sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# Forget the warn-once state (for tests).
sub _reset { %warned = (); return }

1;
