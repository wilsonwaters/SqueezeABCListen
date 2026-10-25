package Plugins::ABCListen::Audiobooks;

# Audiobook chapters (D5, discovery stream): a "Chapters" link in every audiobook's program menu,
# whichever route reached the book (Audiobooks, Kids listen -> Books for Kids, Home, Search,
# Programs -> By type -> Audiobooks, My ABC listen), and an "Episodes" link for the other
# restricted programs ABC's website lists no episodes for (podcasts such as Bluey Listen Along).
#
# ABC's website lists no chapters for its audiobooks (ai-state/research/abc-listen-api.md §6.1): a
# book page has programTemplate 'audiobook' (or 'default'), webDistributionRestricted true and no
# episode collection, and each chapter page redirects to the book. A few restricted podcasts look
# the same, but with programTemplate 'audio' (Bluey Listen Along, Bluey Book Reads, Midsomer
# Murders Mayhem, Odd Squadcast, In Concert, The Bomb on 2026-10-23). Their chapters / episodes
# are in ABC's Algolia index (contentType:audioepisode AND programID=<id>, a numeric filter), with
# MP3 renditions under /geo-001/ or /radio/geo/ (served only to Australian addresses) or, for some
# classics, unrestricted /audio/ ones. All chapters of a book share one publication date, so the
# reading order is the ascending numeric id; a podcast's episodes are listed newest first.
#
#   init
#     Called from Plugins::ABCListen::Discover->init (so before MyABC's init: the Chapters /
#     Episodes link comes before M2's Follow rows). Registers _programMenuExtras with
#     Plugins::ABCListen::OnDemand->registerProgramMenuProvider when OnDemand has that method
#     (else a WARN line and no link). Never dies.
#
#   isAudiobook(\%program) -> 1 | 0                                      (pure; class method too)
#     \%program is the program-menu provider input (O2, ai-state/streams.md contract 6):
#     { %program row, id, title, template, restricted, episodeCollectionId }. True when
#       - template is 'audiobook' (any case), or
#       - restricted is true, there is no episodeCollectionId and the template is not 'audio' (books
#         under /listen/programs/, such as Octonauts, have template 'default'; restricted podcasts
#         have 'audio'), or
#       - no template was passed (fallback) and the canonical path is under /listen/audiobooks/,
#         without an episodeCollectionId.
#     A restricted program with an episode collection is not a book (its episodes are listed).
#
#   isRestrictedProgram(\%program) -> 1 | 0                              (pure; class method too)
#     True for a restricted program without an episode collection that is not an audiobook (in
#     practice template 'audio': restricted podcasts). Its episodes come from the index too.
#
#   chapters($programId, $cb), episodes($programId, $cb)                   (class methods too)
#     Call $cb EXACTLY ONCE with { items => [refs], fetchedAt => <epoch> } or { error => TOKEN }
#     (PLUGIN_ABCLISTEN_RATE_LIMITED from API.pm, else PLUGIN_ABCLISTEN_LOAD_FAILED). A $cb that
#     dies is logged, never called again; so is a second answer from the API. A cached answer
#     calls back synchronously. chapters: ascending numeric id (reading order); episodes: newest
#     first (publication date, then id, descending; undated last).
#     - Both send the same API::algolia query (so they share one cache entry): { query => '',
#       hitsPerPage => 1000, filters => 'contentType:audioepisode AND programID=<id>',
#       attributesToRetrieve => [objectID title canonicalURL duration dates mediaRenditions
#       mediaDownloadStatus mediaStreamingStatus programTitle programID] }, opts { ttl => 86400,
#       stale_ok => 1, timeout => 8 }: at most one query per program per day (API.pm caches by the
#       canonical params, also across LMS restarts, coalesces identical queries in flight and
#       enforces the plugin's hourly Algolia budget; over budget -> RATE_LIMITED without a
#       request). On an error the last good list is served (stale_ok, kept 7 days).
#     - fetchedAt: when ABC answered (API.pm's info at), also for a cache hit or a last-good copy.
#     - A $programId that isn't all digits: LOAD_FAILED without a request.
#     - Ref (the episode meta-cache shape, contract 3), every key only when known:
#         { id (digits of objectID coremedia://<audioepisode|audio|audiosegment>/<id>), docType
#           (that type), title, programTitle, programId (programID), path (API::sitePath of
#           canonicalURL), duration (s), date (dates.publicationDate, epoch),
#           renditions => [ { url, mime (contentType), bitrate, fileSize (when given) } ],
#           availableTo (dates.mediaStreamingAvailableTo), downloadAvailableTo
#           (dates.mediaDownloadAvailableTo), seenAt (fetchedAt) }
#       As D3 (Search.pm) seeds search hits: a missing or unparseable window end is stored as
#       Episode.pm's open end (OPEN_END), never undef (the cache merge would keep an end O1 had
#       closed); renditions and both window ends come only when the hit has http(s) renditions and
#       neither window opens later. seenAt is the fetch time, and only when the answer is not a
#       stale (last good) copy and is younger than 6 h (O1's freshness window): O1 never trusts
#       renditions older than that without asking ABC (F7: the rule is Util::episodeSeenAt, shared
#       with Search and Episode). Text is entity-decoded and trimmed.
#     - Hits are skipped when not a hash or without a parseable objectID, hidden when
#       mediaDownloadStatus and mediaStreamingStatus are both EXPIRED or NONE (any case; DQ4,
#       PENDING and missing statuses are kept), each id once (the first hit wins).
#     - nbHits above the hits returned (more than 1000): the hits returned are used and a WARN
#       line is logged once per program per run.
#     - A fresh answer also remembers how many it lists for the provider (Slim::Utils::Cache
#       namespace abclisten, key 'audiobooks:count:<id>', { count, at => fetchedAt }, valid until
#       24 h after fetchedAt, like API.pm's cached query).
#
#   _programMenuExtras($client, $program, $cb)   (O2 program-menu provider)
#     Synchronous, no network I/O, never dies, calls $cb exactly once with an array ref:
#     - neither an audiobook nor a restricted program, or no numeric id (DEBUG line) -> [];
#     - known to list nothing (count 0, e.g. The Bomb): one PLUGIN_ABCLISTEN_NO_EPISODES text item,
#       O2's own wording (O2 leaves that row out for restricted programs);
#     - an audiobook: { name => 'Chapters (N)' (PLUGIN_ABCLISTEN_CHAPTERS_N, N from the count, read
#       only) or 'Chapters' (PLUGIN_ABCLISTEN_CHAPTERS), type => 'playlist', url => \&_chaptersFeed,
#       passthrough => [ { id, title?, image? } ] }; type 'playlist' makes skins offer Play all /
#       Add all (queued in reading order);
#     - a restricted program: { name => 'Episodes (N)' (PLUGIN_ABCLISTEN_EPISODES_N) or 'Episodes'
#       (O2's PLUGIN_ABCLISTEN_EPISODES), type => 'link', url => \&_episodesFeed, passthrough as
#       above }.
#     No description on either (LMS menu rule 1).
#
#   _chaptersFeed / _episodesFeed($client, $cb, $args, \%program)   (the two links)
#     Call $cb EXACTLY ONCE with { items => [...] }, within FEED_DEADLINE (12 s; later answers
#     still warm the caches):
#     - one row per ref: Plugins::ABCListen::OnDemand->episodeItem($client, { %ref, programImage =>
#       program image, programTitle/programId from the program when the hit has none }); chapters
#       get name and line1 "<n>. <title>" (n = reading position, 1-based; the text carries it for
#       non-visual clients), episodes keep episodeItem's "<date> – <title>". play =>
#       abclisten://episode/<id>; opening a row shows O2's episode page. episodeItem writes the
#       meta cache; if it ever stops storing the seeded keys, they are written here
#       (Util::setEpisodeMeta), so O1 plays without fetching a page;
#     - an older answer never overwrites newer audio data: when the meta cache's seenAt is later
#       than fetchedAt, or O1 closed the entry's windows (both ends equal, past) later than
#       fetchedAt, the ref's renditions, window ends and seenAt are not written (F7: the rule is
#       Util::episodeMetaIsNewer, shared with Search and Episode; D5 had "not older");
#     - nothing listed: one PLUGIN_ABCLISTEN_NO_EPISODES text item;
#     - an error: one text item with the token's text (RATE_LIMITED or LOAD_FAILED);
#     - a passthrough without a numeric id (a stale or malformed link), the deadline passing, or
#       building the rows dying: one PLUGIN_ABCLISTEN_LOAD_FAILED text item.
#
# Owned by the discovery stream (D5). Outside this file D5 adds the Audiobooks->init call to
# Discover->init, the "# === D5 ===" strings section and (sanctioned in review) the info at key in
# API.pm and the /radio/geo/ path in Episode.pm's geo rule.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

use constant INDEX_TTL       => 86400;            # seconds: one Algolia query per program per day
use constant MAX_HITS        => 1000;             # Algolia's hitsPerPage maximum
use constant REQUEST_TIMEOUT => 8;                # seconds (a menu request, as Programs.pm's)
use constant FEED_DEADLINE   => 12;               # seconds for a feed to answer
use constant OPEN_END        => 4_102_444_800;    # an open window end in the episode meta cache (= Episode.pm's)

use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';
use constant NO_EPISODES  => 'PLUGIN_ABCLISTEN_NO_EPISODES';
use constant CHAPTERS     => 'PLUGIN_ABCLISTEN_CHAPTERS';
use constant CHAPTERS_N   => 'PLUGIN_ABCLISTEN_CHAPTERS_N';
use constant EPISODES     => 'PLUGIN_ABCLISTEN_EPISODES';
use constant EPISODES_N   => 'PLUGIN_ABCLISTEN_EPISODES_N';

my @ATTRIBUTES = qw(objectID title canonicalURL duration dates mediaRenditions mediaDownloadStatus
	mediaStreamingStatus programTitle programID);

# The seeded set (contract 3's optional keys), written together.
my @SEED_KEYS = Plugins::ABCListen::Util::episodeAudioKeys();

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);
my %GONE       = map { $_ => 1 } qw(EXPIRED NONE);

# What each list is called in the logs, and its order.
my %KIND = (
	chapters => { what => 'chapters', sort => sub { $a->{id} <=> $b->{id} } },
	episodes => { what => 'episodes', sort => sub { ( $b->{date} || 0 ) <=> ( $a->{date} || 0 ) || $b->{id} <=> $a->{id} } },
);

my $log = logger('plugin.abclisten');

my %truncationWarned;    # program id => 1 once "more than returned" was logged

# Forget the in-memory state (for tests).
sub _reset { %truncationWarned = (); return }

sub init {
	eval {
		if ( Plugins::ABCListen::OnDemand->can('registerProgramMenuProvider') ) {
			Plugins::ABCListen::OnDemand->registerProgramMenuProvider( \&_programMenuExtras );
		}
		else {
			$log->warn('The ABC listen program menus have no provider registry: audiobooks get no Chapters item, restricted programs no Episodes item');
		}
		1;
	} or $log->error( 'Could not add Chapters to the ABC listen audiobook menus: ' . ( $@ || 'unknown error' ) );

	return;
}

# ---------------------------------------------------------------------------
# Which programs
# ---------------------------------------------------------------------------

sub isAudiobook {
	shift if _isClass( $_[0] );
	my $program = shift;
	return 0 unless ref $program eq 'HASH';

	my $template = _text( $program->{template} );
	$template = lc $template if defined $template;
	return 1 if defined $template && $template eq 'audiobook';

	return 0 if _hasCollection($program);

	# restricted without an episode list on the web: a book, unless it is an audio (podcast) program
	return 1 if $program->{restricted} && !( defined $template && $template eq 'audio' );
	return 0 if defined $template;

	# no template: O2 didn't pass the program detail
	my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
	return defined $path && $path =~ m{\A/listen/audiobooks/[^/]} ? 1 : 0;
}

sub isRestrictedProgram {
	shift if _isClass( $_[0] );
	my $program = shift;
	return 0 unless ref $program eq 'HASH' && $program->{restricted} && !_hasCollection($program);
	return isAudiobook($program) ? 0 : 1;
}

sub _hasCollection {
	my $id = $_[0]->{episodeCollectionId};
	return defined $id && !ref $id && length $id ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Chapters and episodes (data)
# ---------------------------------------------------------------------------

sub chapters { shift if _isClass( $_[0] ); _list( 'chapters', @_ ) }
sub episodes { shift if _isClass( $_[0] ); _list( 'episodes', @_ ) }

sub _list {
	my ( $kind, $programId, $cb ) = @_;
	my $what = $KIND{$kind}->{what};

	if ( ref $cb ne 'CODE' ) {
		$log->error("Audiobooks->$kind called without a callback");
		return;
	}

	my $settled = 0;
	my $answer  = sub {
		my $result = shift;
		return if $settled++;
		eval { $cb->($result); 1 } or $log->error( "Program $what: the callback died: " . ( $@ || 'unknown error' ) );
		return;
	};

	my $id = _digits($programId);
	if ( !defined $id ) {
		main::INFOLOG && $log->is_info && $log->info( "Program $what: not a program id: " . ( defined $programId ? "'$programId'" : 'undef' ) );
		return $answer->( { error => LOAD_FAILED } );
	}

	eval {
		Plugins::ABCListen::API::algolia(
			_query($id),
			sub {
				my ( $data, $info ) = @_;
				$info = {} unless ref $info eq 'HASH';

				my $stale = $info->{stale} ? 1 : 0;
				my $at    = _isEpoch( $info->{at} ) ? $info->{at} + 0 : undef;

				my $refs = eval { _refs( $kind, $id, $data, $at, $stale ) };
				if ( ref $refs ne 'ARRAY' ) {
					$log->error( "Program $id $what: " . ( $@ || 'unknown error' ) );
					return $answer->( { error => LOAD_FAILED } );
				}

				_rememberCount( $id, scalar @$refs, $at ) unless $stale;
				$answer->( { items => $refs, ( defined $at ? ( fetchedAt => $at ) : () ) } );
			},
			sub { $answer->( { error => _token(shift) } ) },
			{ ttl => INDEX_TTL, stale_ok => 1, timeout => REQUEST_TIMEOUT },
		);
		1;
	} or do {
		$log->error( "Program $id $what: the search request failed: " . ( $@ || 'unknown error' ) );
		$answer->( { error => LOAD_FAILED } );
	};

	return;
}

sub _query {
	my $id = shift;
	return {
		query                => '',
		hitsPerPage          => MAX_HITS,
		filters              => "contentType:audioepisode AND programID=$id",
		attributesToRetrieve => [@ATTRIBUTES],
	};
}

# The Algolia response -> refs in the list's order (dies without a hits list).
sub _refs {
	my ( $kind, $id, $data, $at, $stale ) = @_;

	die "the search response has no hits list\n" unless ref $data eq 'HASH' && ref $data->{hits} eq 'ARRAY';

	my $what  = $KIND{$kind}->{what};
	my @hits  = @{ $data->{hits} };
	my $total = _positive( $data->{nbHits} );
	if ( $total && $total > @hits && !$truncationWarned{$id}++ ) {
		$log->warn( "Program $id: ABC's search index has $total $what, listing the " . scalar(@hits) . ' it returned' );
	}

	my $now = time();

	# seenAt vouches for the renditions: only a fresh answer's fetch time, while O1 would trust it
	my $seenAt = Plugins::ABCListen::Util::episodeSeenAt( { stale => $stale, at => $at }, $now );

	my ( @refs, %seen );
	for my $hit ( grep { ref $_ eq 'HASH' } @hits ) {
		my ( $type, $refId ) = Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} );
		next unless $type && $AUDIO_TYPE{$type};
		next if _gone( $hit->{mediaDownloadStatus} ) && _gone( $hit->{mediaStreamingStatus} );
		next if $seen{$refId}++;

		push @refs, _ref( $hit, $type, $refId, $now, $seenAt );
	}

	my $order = $KIND{$kind}->{sort};
	return [ sort $order @refs ];
}

sub _ref {
	my ( $hit, $type, $id, $now, $seenAt ) = @_;

	my $dates = ref $hit->{dates} eq 'HASH' ? $hit->{dates} : {};

	my %ref = (
		id           => $id,
		docType      => $type,
		title        => _text( $hit->{title} ),
		programTitle => _text( $hit->{programTitle} ),
		programId    => _digits( $hit->{programID} ),
		path         => Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} ),
		duration     => _positive( $hit->{duration} ),
		date         => Plugins::ABCListen::Util::parseISO8601( $dates->{publicationDate} ),
	);

	my $renditions = _renditions( $hit->{mediaRenditions} );
	my $notYet = grep { defined $_ && $_ > $now }
		map { Plugins::ABCListen::Util::parseISO8601( $dates->{$_} ) } qw(mediaDownloadAvailableFrom mediaStreamingAvailableFrom);

	if ( @$renditions && !$notYet ) {
		$ref{renditions}          = $renditions;
		$ref{availableTo}         = _windowEnd( $dates->{mediaStreamingAvailableTo} );
		$ref{downloadAvailableTo} = _windowEnd( $dates->{mediaDownloadAvailableTo} );
		$ref{seenAt}              = $seenAt;
	}

	return { map { $_ => $ref{$_} } grep { defined $ref{$_} } keys %ref };
}

# mediaRenditions -> [ { url, mime, bitrate, fileSize? } ] (entries without an http(s) URL dropped).
sub _renditions {
	my $list = shift;
	return [] unless ref $list eq 'ARRAY';

	my @renditions;
	for my $r ( grep { ref $_ eq 'HASH' && _isUrl( $_->{url} ) } @$list ) {
		my %rendition = ( url => $r->{url} );

		my $mime     = _text( $r->{contentType} );
		my $bitrate  = _positive( $r->{bitrate} );
		my $fileSize = _positive( $r->{fileSize} );

		$rendition{mime}     = $mime     if defined $mime;
		$rendition{bitrate}  = $bitrate  if defined $bitrate;
		$rendition{fileSize} = $fileSize if defined $fileSize;

		push @renditions, \%rendition;
	}

	return \@renditions;
}

# A window end as the episode meta cache stores it: the epoch, else (missing, or beyond
# parseISO8601 like ABC's "permanent" 2200-01-01: an open window) OPEN_END.
sub _windowEnd {
	my $epoch = Plugins::ABCListen::Util::parseISO8601(shift);
	return defined $epoch ? $epoch : OPEN_END;
}

sub _token {
	my $error = shift;
	return ref $error eq 'HASH' && defined $error->{error} && $error->{error} eq RATE_LIMITED ? RATE_LIMITED : LOAD_FAILED;
}

# ---------------------------------------------------------------------------
# How many a program lists (for the links; no network)
# ---------------------------------------------------------------------------

sub _countKey { "audiobooks:count:$_[0]" }

sub _cache { Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE ) }

# Remember the count of an answer fetched at $at until that answer is 24 h old.
sub _rememberCount {
	my ( $id, $count, $at ) = @_;
	$at = time() unless defined $at;

	my $left = INDEX_TTL - ( time() - $at );
	return unless $left > 0;

	eval {
		_cache()->set( _countKey($id), { count => $count, at => $at }, $left );
		1;
	} or $log->error( "Program $id: couldn't cache how many it lists: " . ( $@ || 'unknown error' ) );

	return;
}

# The count of a fresh answer fetched in the last 24 h, else undef.
sub _cachedCount {
	my $id = shift;

	my $entry = eval { _cache()->get( _countKey($id) ) };
	return undef unless ref $entry eq 'HASH' && defined $entry->{count} && $entry->{count} =~ /\A[0-9]+\z/;
	return undef if _isEpoch( $entry->{at} ) && time() - $entry->{at} >= INDEX_TTL;

	return $entry->{count};
}

# ---------------------------------------------------------------------------
# Program-menu provider and the two feeds
# ---------------------------------------------------------------------------

sub _programMenuExtras {
	my ( $client, $program, $cb ) = @_;

	my $rows = eval { [ _extras( $client, $program ) ] };
	$log->error( 'Building the audiobook Chapters item failed: ' . ( $@ || 'unknown error' ) ) unless $rows;

	$cb->( $rows || [] );
	return;
}

sub _extras {
	my ( $client, $program ) = @_;

	my $kind = isAudiobook($program) ? 'chapters' : isRestrictedProgram($program) ? 'episodes' : return ();

	my $id = _digits( $program->{id} );
	if ( !defined $id ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Restricted program without a program id (' . ( _text( $program->{path} ) || 'no path' ) . "): no $kind item" );
		return ();
	}

	my $count = _cachedCount($id);

	# known to list nothing: what O2 says for a program without episodes
	return _textItem( $client, NO_EPISODES ) if defined $count && $count == 0;

	my %target = ( id => $id );
	$target{title} = _text( $program->{title} ) if defined _text( $program->{title} );
	$target{image} = $program->{image}          if _hasText( $program->{image} ) || ref $program->{image} eq 'HASH';

	my $chapters = $kind eq 'chapters';
	my $name     = defined $count
		? cstring( $client, $chapters ? CHAPTERS_N : EPISODES_N, $count )
		: cstring( $client, $chapters ? CHAPTERS : EPISODES );

	return {
		name        => $name,
		type        => $chapters ? 'playlist' : 'link',
		url         => $chapters ? \&_chaptersFeed : \&_episodesFeed,
		passthrough => [ \%target ],
	};
}

sub _chaptersFeed { _listFeed( 'chapters', @_ ) }
sub _episodesFeed { _listFeed( 'episodes', @_ ) }

sub _listFeed {
	my ( $kind, $client, $cb, $args, $program ) = @_;
	my $once = _once($cb);
	my $what = $KIND{$kind}->{what};

	$program = {} unless ref $program eq 'HASH';

	my $id = _digits( $program->{id} );
	if ( !defined $id ) {
		$log->warn("Program $what opened without a program id (a stale or malformed item)");
		return _textFeed( $client, $once, LOAD_FAILED );
	}

	my $timer;
	my $stopTimer = sub {
		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + FEED_DEADLINE, sub {
		undef $timer;
		$log->warn( "Program $id $what: no answer from ABC within " . FEED_DEADLINE . ' s' );
		_textFeed( $client, $once, LOAD_FAILED );
	} );

	eval {
		_list( $kind, $id, sub {
			my $result = shift;
			$stopTimer->();
			# after the deadline this only seeds the meta cache: $once drops the late answer
			_respond( $client, $once, sub { _rows( $kind, $client, $program, $result ) } );
		} );
		1;
	} or do {
		$stopTimer->();
		$log->error( "Program $id $what failed: " . ( $@ || 'unknown error' ) );
		_textFeed( $client, $once, LOAD_FAILED );
	};

	return;
}

sub _rows {
	my ( $kind, $client, $program, $result ) = @_;

	return [ _textItem( $client, LOAD_FAILED ) ] unless ref $result eq 'HASH';
	return [ _textItem( $client, $result->{error} ) ] if $result->{error};

	my @rows;
	for my $ref ( ref $result->{items} eq 'ARRAY' ? @{ $result->{items} } : () ) {
		next unless ref $ref eq 'HASH';

		my %episode = %$ref;
		$episode{programImage} = $program->{image} if defined $program->{image};
		$episode{programTitle} = $program->{title} if !defined $episode{programTitle} && defined $program->{title};
		$episode{programId}    = $program->{id}    if !defined $episode{programId};

		# an older answer never overwrites audio data stored later (by O1, or a newer answer)
		delete @episode{@SEED_KEYS} if Plugins::ABCListen::Util::episodeMetaIsNewer( $ref->{id}, $result->{fetchedAt} );

		my $item = Plugins::ABCListen::OnDemand->episodeItem( $client, \%episode ) or next;
		_seed( \%episode );

		if ( $kind eq 'chapters' ) {
			my $title = _hasText( $item->{line1} ) ? $item->{line1} : _hasText( $ref->{title} ) ? $ref->{title} : Plugins::ABCListen::Util::DISPLAY_NAME;
			$item->{name} = $item->{line1} = ( @rows + 1 ) . ". $title";
		}

		push @rows, $item;
	}

	return @rows ? \@rows : [ _textItem( $client, NO_EPISODES ) ];
}

# Make sure the episode meta cache holds the ref's seeded set (episodeItem stores it today).
sub _seed {
	my $ref = shift;
	return unless ref $ref->{renditions} eq 'ARRAY' && @{ $ref->{renditions} };

	my $cached = Plugins::ABCListen::Util::getEpisodeMeta( $ref->{id} );
	my $stored = ref $cached eq 'HASH' && ref $cached->{renditions} eq 'ARRAY' && @{ $cached->{renditions} }
		&& ( !defined $ref->{seenAt} || ( defined $cached->{seenAt} && $cached->{seenAt} == $ref->{seenAt} ) );
	return if $stored;

	Plugins::ABCListen::Util::setEpisodeMeta( $ref->{id}, { map { $_ => $ref->{$_} } grep { defined $ref->{$_} } @SEED_KEYS } );
	return;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _gone {
	my $status = shift;
	return defined $status && !ref $status && $GONE{ uc $status } ? 1 : 0;
}

# Entity-decoded, trimmed text, or undef if empty.
sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::ABCListen::Util::decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;

	return length $text ? $text : undef;
}

sub _hasText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }

sub _isEpoch { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+(?:\.[0-9]+)?\z/ ? 1 : 0 }

sub _positive {
	my $value = shift;
	return defined $value && !ref $value && $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $value > 0 ? $value + 0 : undef;
}

sub _isUrl { defined $_[0] && !ref $_[0] && $_[0] =~ m{\Ahttps?://\S+\z}i }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

# A callback wrapper that passes on only the first call; a callback that dies is logged.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub {
		return if $called++;
		eval { $cb->(@_); 1 } or $log->error( 'Audiobook chapters: the menu callback died: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# Call back once with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the audiobook chapter list failed: ' . ( $@ || 'unknown error' ) );
		$items = [ _textItem( $client, LOAD_FAILED ) ];
	}

	$cb->( { items => $items } );
	return;
}

sub _textFeed {
	my ( $client, $cb, $token ) = @_;
	$cb->( { items => [ _textItem( $client, $token ) ] } );
	return;
}

# One text item for a string token (unknown or malformed tokens read as LOAD_FAILED).
sub _textItem {
	my ( $client, $token ) = @_;
	$token = LOAD_FAILED unless defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/;
	return { name => cstring( $client, $token ), type => 'text' };
}

1;
