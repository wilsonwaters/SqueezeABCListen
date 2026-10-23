package Plugins::ABCListen::MyABC;

# My ABC listen hook (hook API: see Plugin.pm): settings page, home state, followed programs.
# M1: the settings page (Plugins::ABCListen::Settings) and the homeState pref.
# M2: followed programs (data: Plugins::ABCListen::Follow), without any ABC account: the top-level
# "My ABC listen" menu, and the follow rows (Follow / Unfollow) on every program menu (OnDemand's
# program-menu registry) and in song info.
# Owned by the myabc stream (M1, then M2).
#
# homeState (contract 8 in ai-state/streams.md): '' (not set; consumers behave as NSW) or exactly
# one of ACT NSW NT QLD SA TAS VIC WA. Read by live radio (L1) and schedules (L4).
#
# followed (contract 8): the follow list, server-wide (MQ1), see Follow.pm. init sets its default []
# and LMS's 'array' validator.
#
# ---- Menus (every feed calls $cb exactly once; $client may be undef) ------------------------------
#   menuItems -> one link "My ABC listen" (weight Util::topWeight('myabc'), declared in menuWeights:
#   the last top-level item) -> _myABC:
#     no follows (and no tombstones): one text item, "Open any program and choose Follow";
#     else "Latest episodes" (_latestEpisodes) and "Followed programs (N)" (_followedPrograms),
#     N = the followed programs (tombstones don't count; N may be 0 while only tombstones are left).
#   Followed programs: an OnDemand->programItem row per Follow::listWithUnfollowed entry, in follow
#     order (oldest follow first), tombstones included: a program unfollowed in the last 30 min
#     keeps its row (the same programItem row; its program menu then offers Follow).
#   Latest episodes: for each Follow::listWithUnfollowed entry (follow order, tombstones included)
#     Programs->program(path) -> its episodeCollectionId -> Programs->episodes(id, 0, 5): a program
#     unfollowed in the last 30 min keeps its episodes, in their places, until its tombstone
#     expires (M4; see "Follow / Unfollow"); no follows and no tombstones -> the help text. At
#     most 4 programs in flight; a program that fails is skipped (WARN). After 25 s (XMLBrowser
#     gives a feed 35 s) the feed answers with what has arrived (WARN with the number of programs
#     left out) and ignores later results.
#     Merge: one row per episode id (the program the episode belongs to wins, else the first A-Z),
#     newest first, then by program (Programs::sortKey), then by id; undated episodes last; the newest
#     50. Rows are OnDemand->episodeItem rows (programImage = the followed entry's image;
#     programTitle/programId only for the program's own episodes, O2's rule) with name
#     "<program>: <episodeItem name>" and line1 "<program>: <episode title>" (the episode meta cache
#     keeps the episode title). Every program failing (or none answering in time) -> LOAD_FAILED;
#     no episodes -> NO_EPISODES. The merged episode refs (plain data) are cached 15 min under the
#     sorted paths of the entries, tombstones included: an unfollow (and a re-follow within 30 min)
#     keeps the key and so the list; a new follow, or a tombstone expiring, starts a new list.
#     Partial lists are cached too: XMLBrowser re-runs this feed to open a row, and a row's index
#     must not move meanwhile.
#
# ---- Follow / Unfollow ----------------------------------------------------------------------------
#   The follow rows for a program are always two rows, so no row after them ever moves, and the two
#   actions never share an index across states:
#     not following: Follow "<program>" (action), then the text "Follow to see its new episodes in
#                    My ABC listen";
#     following:     the text "<U+2713> Following "<program>"", then Unfollow "<program>" (action).
#   LMS keeps no browse session for this plugin (its top level has code-ref feeds), so every item_id
#   request runs the feeds again, providers included, and opens whatever row is at the index now.
#   What keeps a stale id (one from before a follow or unfollow) from changing the follows:
#   * the follow rows: a stale Follow id lands on the "Following" text row and a stale Unfollow id
#     on the hint text row (both no-ops), and no row after them moves (program menu and song info);
#   * Followed programs: a follow appends a row after every existing one, a refresh or a re-follow
#     within 30 min keeps the row's place, and an unfollowed program keeps its row for 30 min
#     (Follow.pm's tombstones, kept in the pref, so across LMS restarts too). Nothing is sorted, so
#     same-second follows or a clock change never reorder rows either. Rows move only when a
#     tombstone expires, 30 min after its unfollow: then every row below it moves up one. Any id into
#     Followed programs (and on into a program menu) that is used across that moment - including a
#     menu left open on screen - may open the next program's menu, follow rows included. That
#     residual window is the accepted limit of the guarantee.
#   * Latest episodes (M4): the episode menu links to the episode's program (O4's "More from"), so
#     an id can run My ABC listen -> Latest episodes -> episode -> More from -> the program's follow
#     rows. Latest is built from the follows and the tombstones, under a key of all their paths, so
#     an unfollow (from there or anywhere) changes neither the key nor the cached list: every id
#     into Latest opens the same episode, its More from the same program, and a repeated Unfollow
#     id lands on that program's hint text row (a no-op), never on another program's Unfollow. A
#     re-follow within 30 min restores the entry in place: the same key again. When the 15 min
#     cache expires the list is fetched again from the same programs, tombstones included, so rows
#     move only if ABC's newest episodes changed meanwhile. Rows also move when a tombstone expires
#     (30 min after its unfollow, its episodes leave) or a program not in the list is followed (via
#     Latest only from the More from of an episode a followed program lists from another program).
#     Those windows are the same accepted limit as for Followed programs: an id used across one may
#     open another episode and, through its More from, another program's follow rows.
#   _programMenuExtras($client, $program, $cb) (OnDemand->registerProgramMenuProvider): $cb->(\@rows)
#     once, the follow rows (after the program header); $cb->([]) without a program path.
#   _trackInfo (Slim::Menu::TrackInfo provider 'abclistenfollow', after 'top'): synchronous, no
#     network I/O; for an abclisten://episode/<id> URL whose meta-cache entry has a path and a
#     programTitle: the follow rows (an arrayref) for Follow::programPathFor(path); else undef.
#   Each action is { name, type => 'link', url => \&_followAction, nextWindow => 'parent',
#     passthrough => [ { op => 'follow' | 'unfollow', program => { path, title?, id?, image?, network? } } ] }.
#   _followAction applies the explicit op (idempotent: never a toggle) and answers one text item,
#     "Following <title>" / "No longer following <title>", with showBriefly => 1 and
#     nextWindow => 'parent' (MQ2). In menu mode (Material, Jive) LMS shows that item as a
#     showBriefly popup and lists nothing, so nextWindow is also on the action item: Material and
#     Jive take it from the item that was opened, then go back.
#
# Nothing here talks to an ABC account, and the prefs hold no player data or credentials.

use strict;
use warnings;

use Digest::MD5 ();
use Time::HiRes ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Follow;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Util;

use constant LATEST_PER_PROGRAM => 5;
use constant LATEST_MAX         => 50;
use constant LATEST_IN_FLIGHT   => 4;      # programs fetched at once
use constant LATEST_DEADLINE    => 25;     # seconds (XMLBrowser gives a feed 35 s)
use constant LATEST_TTL         => 900;    # seconds
use constant LOAD_FAILED        => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

my $log   = logger('plugin.abclisten');
my $prefs = preferences('plugin.abclisten');

my %HOME_STATES = map { $_ => 1 } qw(ACT NSW NT QLD SA TAS VIC WA);

sub init {
	$prefs->init( { homeState => '' } );
	$prefs->setValidate( { validator => \&validateHomeState }, 'homeState' );

	# M2: the follow list (server-wide)
	$prefs->init( { followed => [] } );
	$prefs->setValidate( { validator => 'array' }, 'followed' );

	if (main::WEBUI) {
		eval {
			require Plugins::ABCListen::Settings;
			Plugins::ABCListen::Settings->new;
			1;
		} or $log->error( 'Could not create the ABC listen settings page: ' . ( $@ || 'unknown error' ) );
	}

	eval {
		Plugins::ABCListen::OnDemand->registerProgramMenuProvider( \&_programMenuExtras );
		1;
	} or $log->error( 'Could not add Follow to the ABC listen program menus: ' . ( $@ || 'unknown error' ) );

	eval {
		require Slim::Menu::TrackInfo;
		Slim::Menu::TrackInfo->registerInfoProvider( abclistenfollow => (
			after => 'top',
			func  => \&_trackInfo,
		) );
		1;
	} or $log->error( 'Could not add Follow to ABC listen song info: ' . ( $@ || 'unknown error' ) );

	return;
}

# Prefs validator for homeState, called by LMS as ($pref, $new, \%params, $old, $client): true for ''
# or one of the upper-case state codes. Anything else is rejected, including undef: the pref layer
# does not map undef to '', so a save without the field leaves homeState unchanged.
sub validateHomeState {
	my ( $pref, $new ) = @_;
	return 0 if !defined $new || ref $new;
	return ( $new eq '' || $HOME_STATES{$new} ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# My ABC listen
# ---------------------------------------------------------------------------

# The top-level "My ABC listen" item sorts at the "myabc" weight (see Plugin.pm, Util::topWeight).
sub menuWeights { Plugins::ABCListen::Util::topWeight('myabc') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_MY_ABC' ),
		type   => 'link',
		url    => \&_myABC,
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight('myabc'),
	} ] );
}

sub _myABC {
	my ( $client, $cb, $args ) = @_;

	_respond( $client, $cb, sub {
		my @follows = Plugins::ABCListen::Follow::list();

		# a tombstone keeps both rows, so ids into Followed programs still open it (see the header)
		return [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP' ) ] unless @follows || Plugins::ABCListen::Follow::listWithUnfollowed();

		return [ {
			name  => cstring( $client, 'PLUGIN_ABCLISTEN_LATEST_EPISODES' ),
			type  => 'link',
			url   => \&_latestEpisodes,
			image => Plugins::ABCListen::Util::ICON,
		}, {
			name  => cstring( $client, 'PLUGIN_ABCLISTEN_FOLLOWED_PROGRAMS', scalar @follows ),
			type  => 'link',
			url   => \&_followedPrograms,
			image => Plugins::ABCListen::Util::ICON,
		} ];
	} );
}

# One row per followed program and per tombstone, in follow order (see the header): never sorted,
# so no row moves when a program is followed or unfollowed.
sub _followedPrograms {
	my ( $client, $cb, $args ) = @_;

	_respond( $client, $cb, sub {
		my @items = grep {defined} map { Plugins::ABCListen::OnDemand->programItem( $client, _programOf($_) ) } Plugins::ABCListen::Follow::listWithUnfollowed();
		return @items ? \@items : [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP' ) ];
	} );
}

# A follow entry as a program ref for the builders: { path, title, id?, image?, network? }.
sub _programOf {
	my $entry = shift;
	return { map { $_ => $entry->{$_} } grep { defined $entry->{$_} } qw(path title id image network) };
}

# ---------------------------------------------------------------------------
# Latest episodes
# ---------------------------------------------------------------------------

sub _latestEpisodes {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		# M4: tombstones included, so an unfollow keeps the list (and its key) for 30 min (see the header)
		my @programs = Plugins::ABCListen::Follow::listWithUnfollowed();
		return _textFeed( $client, $once, 'PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP' ) unless @programs;

		my $key    = _latestKey( \@programs );
		my $cached = _cache()->get($key);
		return _latestFeed( $client, $once, $cached ) if ref $cached eq 'ARRAY';

		_collectLatest( \@programs, sub {
			my ( $results, $stats ) = @_;

			_try( $client, $once, sub {
				# nothing arrived: every program failed, or none answered in time
				return _textFeed( $client, $once, LOAD_FAILED ) unless $stats->{ok};

				my $refs = _mergeLatest($results);
				_cache()->set( $key, $refs, LATEST_TTL );
				_latestFeed( $client, $once, $refs );
			} );
		} );
	} );
}

# Rows for the merged refs, or NO_EPISODES.
sub _latestFeed {
	my ( $client, $cb, $refs ) = @_;

	_respond( $client, $cb, sub {
		my @items = grep {defined} map { _latestRow( $client, $_ ) } @$refs;
		return @items ? \@items : [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) ];
	} );
}

sub _latestRow {
	my ( $client, $ref ) = @_;
	return undef unless ref $ref eq 'HASH' && ref $ref->{episode} eq 'HASH';

	my $item = Plugins::ABCListen::OnDemand->episodeItem( $client, $ref->{episode} ) or return undef;

	# the program name in the row text (the Default web skin shows only the name), never in the cache
	if ( _hasText( $ref->{program} ) ) {
		$item->{name}  = "$ref->{program}: $item->{name}";
		$item->{line1} = "$ref->{program}: $item->{line1}";
	}

	return $item;
}

# Fetch the newest episodes of every entry (a followed program or a tombstone), LATEST_IN_FLIGHT
# programs at a time, and call $done->(\@results, { ok, failed, skipped }) once: when every program
# has answered, or at the deadline (later answers are ignored). A result is { entry, detail,
# episodes }.
sub _collectLatest {
	my ( $follows, $done ) = @_;

	my @queue = @$follows;
	my $total = scalar @queue;
	my %stats = ( ok => 0, failed => 0 );
	my @results;
	my ( $inFlight, $finished, $pumping, $timer ) = ( 0, 0, 0, undef );
	my $pump;

	my $finish = sub {
		return if $finished++;

		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;
		undef $pump;

		$stats{skipped} = $total - $stats{ok} - $stats{failed};
		$done->( \@results, {%stats} );
	};

	my $answered = sub {
		my ( $entry, $result ) = @_;
		return if $finished;    # after the deadline

		$inFlight--;

		if ( $result->{error} ) {
			$stats{failed}++;
			$log->warn( "Latest episodes: skipped the program $entry->{title} ($entry->{path}): " . ( $result->{message} || $result->{error} ) );
		}
		else {
			$stats{ok}++;
			push @results, $result;
		}

		$pump->();
	};

	# Start programs until LATEST_IN_FLIGHT are in flight. Answers that come back synchronously (cache
	# hits) re-enter here and return at once; the running loop goes on, so nothing recurses.
	$pump = sub {
		return if $finished || $pumping;
		$pumping = 1;

		while ( !$finished && $inFlight < LATEST_IN_FLIGHT && @queue ) {
			my $entry = shift @queue;
			$inFlight++;
			_programLatest( $entry, sub { $answered->( $entry, shift ) } );
		}

		$pumping = 0;
		$finish->() if !$inFlight && !@queue;
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + LATEST_DEADLINE, sub {
		undef $timer;
		my $missing = $total - $stats{ok} - $stats{failed};
		$log->warn( 'Latest episodes: answered after ' . LATEST_DEADLINE . " s without $missing of $total programs" );
		$finish->();
	} );

	$pump->();
	return;
}

# One program's newest episodes (a followed program or a tombstone): $cb->({ entry, detail, episodes })
# or $cb->({ error }), once.
sub _programLatest {
	my ( $entry, $cb ) = @_;

	my $called = 0;
	my $answer = sub { $cb->(@_) unless $called++ };

	eval {
		Plugins::ABCListen::Programs::program( $entry->{path}, sub {
			my $detail = shift;
			return $answer->( { error => _error($detail) } ) if ref $detail ne 'HASH' || $detail->{error};

			# no episode list (an ABC audiobook): nothing to add
			my $collectionId = $detail->{episodeCollectionId};
			return $answer->( { entry => $entry, detail => $detail, episodes => [] } ) unless defined $collectionId;

			Plugins::ABCListen::Programs::episodes( $collectionId, 0, LATEST_PER_PROGRAM, sub {
				my $result = shift;
				return $answer->( { error => _error($result) } ) if ref $result ne 'HASH' || $result->{error};

				$answer->( { entry => $entry, detail => $detail, episodes => ref $result->{items} eq 'ARRAY' ? $result->{items} : [] } );
			} );
		} );
		1;
	} or $answer->( { error => LOAD_FAILED, message => $@ || 'unknown error' } );

	return;
}

# The results -> [ { program => <program title>, episode => <episodeItem input> } ], newest first.
sub _mergeLatest {
	my $results = shift;
	my @candidates;

	for my $result (@$results) {
		my ( $entry, $detail ) = @$result{qw(entry detail)};

		my $path    = $entry->{path};
		my $title   = _hasText( $detail->{title} ) ? $detail->{title} : $entry->{title};
		my $id      = defined $detail->{id} ? $detail->{id} : $entry->{id};
		my $image   = _hasText( $entry->{image} ) ? $entry->{image} : $detail->{image};
		my $sortKey = Plugins::ABCListen::Programs::sortKey($title);

		for my $episode ( @{ $result->{episodes} } ) {
			next unless ref $episode eq 'HASH' && defined Plugins::ABCListen::Util::episodeUrl( $episode->{id} );

			my %episode     = %$episode;
			my $episodePath = Plugins::ABCListen::API::sitePath( $episode{path} );
			my $own         = defined $episodePath && index( $episodePath, "$path/" ) == 0 ? 1 : 0;

			$episode{programImage} = $image if _hasText($image);

			# O2's rule: only the program's own episodes are labelled with it
			if ($own) {
				$episode{programTitle} = $title if _hasText($title);
				$episode{programId}    = $id    if defined $id;
			}

			push @candidates, {
				program => $title,
				sortKey => $sortKey,
				path    => $path,
				own     => $own,
				date    => _isEpoch( $episode{date} ) ? $episode{date} + 0 : undef,
				id      => $episode{id},
				episode => \%episode,
			};
		}
	}

	# one row per episode: the program it belongs to wins, else the first program A-Z
	my ( %seen, @unique );
	for my $c ( sort { $b->{own} <=> $a->{own} || $a->{sortKey} cmp $b->{sortKey} || $a->{path} cmp $b->{path} } @candidates ) {
		push @unique, $c unless $seen{ $c->{id} }++;
	}

	my @sorted = sort {
		( defined $a->{date} ? 0 : 1 ) <=> ( defined $b->{date} ? 0 : 1 )
			|| ( defined $a->{date} && $b->{date} <=> $a->{date} )
			|| $a->{sortKey} cmp $b->{sortKey}
			|| $a->{id} <=> $b->{id}
			|| $a->{path} cmp $b->{path}
	} @unique;

	splice( @sorted, LATEST_MAX ) if @sorted > LATEST_MAX;

	return [ map { +{ program => $_->{program}, episode => $_->{episode} } } @sorted ];
}

# Cache key: the sorted paths of the entries (Follow::listWithUnfollowed: followed programs and
# tombstones alike, so an unfollow or a re-follow within 30 min keeps the key).
sub _latestKey {
	my $entries = shift;
	my $paths = join( "\n", sort map { $_->{path} } @$entries );
	utf8::encode($paths) if utf8::is_utf8($paths);
	return 'myabc-latest:' . Digest::MD5::md5_hex($paths);
}

sub _cache { Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE ) }

# ---------------------------------------------------------------------------
# Follow / Unfollow
# ---------------------------------------------------------------------------

# Program-menu provider (OnDemand->registerProgramMenuProvider): the follow rows.
sub _programMenuExtras {
	my ( $client, $program, $cb ) = @_;

	my $rows = eval { [ _followRows( $client, $program ) ] };
	$log->error( "Building the Follow rows failed: $@" ) if $@;

	$cb->( $rows || [] );
}

# Song-info provider (Slim::Menu::TrackInfo): the follow rows (an arrayref) while an episode with a
# known program plays, else undef.
sub _trackInfo {
	my ( $client, $url ) = @_;

	my $rows = eval {
		my $parsed = Plugins::ABCListen::Util::parseUrl($url);
		return undef unless $parsed && $parsed->{kind} eq 'episode';

		my $meta = Plugins::ABCListen::Util::getEpisodeMeta( $parsed->{id} );
		return undef unless ref $meta eq 'HASH' && _hasText( $meta->{programTitle} );

		my $path = Plugins::ABCListen::Follow::programPathFor( $meta->{path} );
		return undef unless defined $path;

		my @rows = _followRows( $client, { title => $meta->{programTitle}, path => $path, id => $meta->{programId}, image => $meta->{image} } );
		return @rows ? \@rows : undef;
	};
	$log->warn( "Song info Follow item failed: $@" ) if $@;

	return $rows;
}

# The two follow rows for $program ({ path, title?, id?, image?, network? }) in its current state
# (see the header): Follow "<title>" and the hint text, or the "Following" text and Unfollow
# "<title>". Always two rows, and never an action at the other state's action index: LMS re-opens
# stale item ids by index. () without a path.
sub _followRows {
	my ( $client, $program ) = @_;
	return () unless ref $program eq 'HASH';

	my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
	return () unless defined $path && $path ne '/';

	my %target = ( path => $path );
	for my $key (qw(title id image network)) {
		$target{$key} = $program->{$key} if _hasText( $program->{$key} );
	}
	my $title = _titleOf( \%target );

	my $action = sub {
		my ( $op, $token ) = @_;
		return {
			name        => cstring( $client, $token, $title ),
			type        => 'link',
			url         => \&_followAction,
			passthrough => [ { op => $op, program => \%target } ],
			nextWindow  => 'parent',
		};
	};

	if ( Plugins::ABCListen::Follow::isFollowed($path) ) {
		return (
			{ name => cstring( $client, 'PLUGIN_ABCLISTEN_FOLLOWING_NAMED', $title ), type => 'text' },
			$action->( unfollow => 'PLUGIN_ABCLISTEN_UNFOLLOW_NAMED' ),
		);
	}

	return (
		$action->( follow => 'PLUGIN_ABCLISTEN_FOLLOW_NAMED' ),
		{ name => cstring( $client, 'PLUGIN_ABCLISTEN_FOLLOW_HINT' ), type => 'text' },
	);
}

# Apply the item's op (never a toggle) and confirm it in one text item.
sub _followAction {
	my ( $client, $cb, $args, $params ) = @_;

	_respond( $client, $cb, sub {
		my $op      = ref $params eq 'HASH' ? $params->{op} : undef;
		my $program = ref $params eq 'HASH' && ref $params->{program} eq 'HASH' ? $params->{program} : {};

		die "unknown follow action\n" unless defined $op && !ref $op && ( $op eq 'follow' || $op eq 'unfollow' );

		my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
		die "no program path\n" unless defined $path && $path ne '/';

		my $title = _titleOf( { %$program, path => $path } );

		if ( $op eq 'follow' ) {
			my $entry = Plugins::ABCListen::Follow::follow($program) or die "could not follow $path\n";
			$title = $entry->{title};
		}
		else {
			Plugins::ABCListen::Follow::unfollow($path);
		}

		main::INFOLOG && $log->is_info && $log->info( ( $op eq 'follow' ? 'Followed' : 'Unfollowed' ) . " the program $title ($path)" );

		return [ {
			name        => cstring( $client, $op eq 'follow' ? 'PLUGIN_ABCLISTEN_FOLLOWED_OK' : 'PLUGIN_ABCLISTEN_UNFOLLOWED_OK', $title ),
			type        => 'text',
			showBriefly => 1,
			nextWindow  => 'parent',
		} ];
	} );
}

# The program's title, else the last segment of its path.
sub _titleOf {
	my $program = shift;
	return $program->{title} if _hasText( $program->{title} );
	my ($segment) = ( $program->{path} || '' ) =~ m{([^/]+)\z};
	return defined $segment ? $segment : '';
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _hasText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

sub _isEpoch { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+(?:\.[0-9]+)?\z/ }

sub _error {
	my $result = shift;
	my $token  = ref $result eq 'HASH' ? $result->{error} : undef;
	return defined $token && !ref $token && length $token ? $token : LOAD_FAILED;
}

# A callback wrapper that passes on only the first call.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub { $cb->(@_) unless $called++ };
}

# Run $code (which answers $cb itself); if it dies, answer $cb with the LOAD_FAILED item.
sub _try {
	my ( $client, $cb, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Building the My ABC listen menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back once with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the My ABC listen menu failed: ' . ( $@ || 'unknown error' ) );
		return _textFeed( $client, $cb, LOAD_FAILED );
	}

	$cb->( { items => $items } );
}

sub _textFeed {
	my ( $client, $cb, $token ) = @_;
	$cb->( { items => [ _textItem( $client, $token ) ] } );
}

# One text item for a string token (unknown or malformed tokens read as LOAD_FAILED).
sub _textItem {
	my ( $client, $token ) = @_;
	$token = LOAD_FAILED unless defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/;
	return { name => cstring( $client, $token ), type => 'text' };
}

1;
