package Plugins::ABCListen::Audiobooks;

# Audiobook chapters (D5, discovery stream): a "Chapters" link in every audiobook's program menu,
# whichever route reached the book (Audiobooks, Kids listen -> Books for Kids, Home, Search,
# Programs -> By type -> Audiobooks, My ABC listen).
#
# ABC's website lists no chapters for its audiobooks (ai-state/research/abc-listen-api.md §6.1): a
# book page has programTemplate 'audiobook' (or 'default'), webDistributionRestricted true and no
# episode collection, and each chapter page redirects to the book. The chapters are in ABC's
# Algolia index (contentType:audioepisode AND programID=<book id>, a numeric filter), with MP3
# renditions under /geo-001/ that ABC's CDN serves only to Australian addresses. All chapters of a
# book share one publication date, so the reading order is the ascending numeric id.
#
#   init
#     Called from Plugins::ABCListen::Discover->init (so before MyABC's init: the Chapters link
#     comes before M2's Follow rows). Registers _programMenuExtras with
#     Plugins::ABCListen::OnDemand->registerProgramMenuProvider when OnDemand has that method
#     (else a WARN line and no Chapters link). Never dies.
#
#   isAudiobook(\%program) -> 1 | 0                                      (pure; class method too)
#     \%program is the program-menu provider input (O2, ai-state/streams.md contract 6):
#     { %program row, id, title, template, restricted, episodeCollectionId }. True when
#       - template is 'audiobook' (any case), or
#       - restricted is true and there is no episodeCollectionId (books under /listen/programs/,
#         such as Octonauts, have template 'default'), or
#       - no template was passed (fallback) and the canonical path is under /listen/audiobooks/,
#         without an episodeCollectionId.
#     A restricted program with an episode collection is not a book (its episodes are listed).
#
#   chapters($programId, $cb)                                             (class method too)
#     Calls $cb EXACTLY ONCE with { items => [chapter refs] } or { error => TOKEN }
#     (PLUGIN_ABCLISTEN_RATE_LIMITED from API.pm, else PLUGIN_ABCLISTEN_LOAD_FAILED). A $cb that
#     dies is logged, never called again. A cached answer calls back synchronously.
#     - One API::algolia query: { query => '', hitsPerPage => 1000, filters =>
#       'contentType:audioepisode AND programID=<id>', attributesToRetrieve => [objectID title
#       canonicalURL duration dates mediaRenditions mediaDownloadStatus mediaStreamingStatus
#       programTitle programID] }, opts { ttl => 86400, stale_ok => 1, timeout => 8 }: at most
#       one query per book per day (API.pm caches by the canonical params, also across LMS
#       restarts, coalesces identical queries in flight and enforces the plugin's hourly Algolia
#       budget; over budget -> RATE_LIMITED without a request). On an error the last good list is
#       served (stale_ok, kept 7 days).
#     - A $programId that isn't all digits: LOAD_FAILED without a request.
#     - Chapter ref (the episode meta-cache shape, contract 3), every key only when known:
#         { id (digits of objectID coremedia://<audioepisode|audio|audiosegment>/<id>), docType
#           (that type), title, programTitle, programId (programID), path (API::sitePath of
#           canonicalURL), duration (s), date (dates.publicationDate, epoch),
#           renditions => [ { url, mime (contentType), bitrate, fileSize (when given) } ],
#           availableTo (dates.mediaStreamingAvailableTo), downloadAvailableTo
#           (dates.mediaDownloadAvailableTo), seenAt (now) }
#       As D3 (Search.pm) seeds search hits: a missing or unparseable window end is stored as
#       Episode.pm's open end (OPEN_END), never undef (the cache merge would keep an end O1 had
#       closed); renditions, both window ends and seenAt come as one set, only when the hit has
#       http(s) renditions and neither window opens later; seenAt only for a fresh answer, not
#       for a stale (last good) one. Text is entity-decoded and trimmed.
#     - Hits are skipped when not a hash or without a parseable objectID, hidden when
#       mediaDownloadStatus and mediaStreamingStatus are both EXPIRED or NONE (any case; DQ4,
#       PENDING and missing statuses are kept), each id once (the first hit wins), then sorted by
#       numeric id, ascending (reading order).
#     - nbHits above the hits returned (more than 1000 chapters): the hits returned are used and
#       a WARN line is logged once per book per run.
#     - A fresh answer also remembers the number of chapters for the provider (Slim::Utils::Cache
#       namespace abclisten, key 'audiobooks:count:<id>', 24 h, written only when there is no
#       entry or the number changed, so it expires with API.pm's cached query).
#
#   _programMenuExtras($client, $program, $cb)   (O2 program-menu provider)
#     Synchronous, no network I/O, never dies, calls $cb exactly once with an array ref:
#     - not an audiobook (isAudiobook), or no numeric id (DEBUG line) -> [];
#     - else one link: { name => 'Chapters (N)' (PLUGIN_ABCLISTEN_CHAPTERS_N, N from the count
#       above, read only) or 'Chapters' (PLUGIN_ABCLISTEN_CHAPTERS), type => 'playlist',
#       url => \&_chaptersFeed, passthrough => [ { id, title?, image? } ] }. type 'playlist' makes
#       skins offer Play all / Add all (queued in reading order). No description (LMS menu rule 1).
#
#   _chaptersFeed($client, $cb, $args, \%book)   (the Chapters link)
#     Calls $cb EXACTLY ONCE with { items => [...] }, within FEED_DEADLINE (12 s; later answers
#     still warm the cache):
#     - one row per chapter: Plugins::ABCListen::OnDemand->episodeItem($client, { %ref,
#       programImage => book image, programTitle/programId from the book when the hit has none }),
#       with name and line1 "<n>. <title>" (n = reading position, 1-based; the text carries it for
#       non-visual clients); play => abclisten://episode/<id>, opening a row shows O2's episode
#       page. episodeItem writes the meta cache; if it ever stops storing the seeded keys, they
#       are written here (Util::setEpisodeMeta), so O1 plays a chapter without fetching a page;
#     - no chapters: one PLUGIN_ABCLISTEN_NO_EPISODES text item;
#     - an error: one text item with the token's text (RATE_LIMITED or LOAD_FAILED);
#     - a passthrough without a numeric id (a stale or malformed link), the deadline passing, or
#       building the rows dying: one PLUGIN_ABCLISTEN_LOAD_FAILED text item.
#
# Owned by the discovery stream (D5). Outside this file D5 only adds the Audiobooks->init call to
# Discover->init and the "# === D5 ===" strings section.

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

use constant CHAPTERS_TTL    => 86400;            # seconds: one Algolia query per book per day
use constant MAX_HITS        => 1000;             # Algolia's hitsPerPage maximum
use constant REQUEST_TIMEOUT => 8;                # seconds (a menu request, as Programs.pm's)
use constant FEED_DEADLINE   => 12;               # seconds for the Chapters feed to answer
use constant OPEN_END        => 4_102_444_800;    # an open window end in the episode meta cache (= Episode.pm's)

use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';
use constant NO_EPISODES  => 'PLUGIN_ABCLISTEN_NO_EPISODES';
use constant CHAPTERS     => 'PLUGIN_ABCLISTEN_CHAPTERS';
use constant CHAPTERS_N   => 'PLUGIN_ABCLISTEN_CHAPTERS_N';

my @ATTRIBUTES = qw(objectID title canonicalURL duration dates mediaRenditions mediaDownloadStatus
	mediaStreamingStatus programTitle programID);

# The seeded set (contract 3's optional keys), written together.
my @SEED_KEYS = qw(renditions availableTo downloadAvailableTo seenAt);

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);
my %GONE       = map { $_ => 1 } qw(EXPIRED NONE);

my $log = logger('plugin.abclisten');

my %truncationWarned;    # book id => 1 once "more chapters than returned" was logged

# Forget the in-memory state (for tests).
sub _reset { %truncationWarned = (); return }

sub init {
	eval {
		if ( Plugins::ABCListen::OnDemand->can('registerProgramMenuProvider') ) {
			Plugins::ABCListen::OnDemand->registerProgramMenuProvider( \&_programMenuExtras );
		}
		else {
			$log->warn('The ABC listen program menus have no provider registry: audiobooks get no Chapters item');
		}
		1;
	} or $log->error( 'Could not add Chapters to the ABC listen audiobook menus: ' . ( $@ || 'unknown error' ) );

	return;
}

# ---------------------------------------------------------------------------
# Audiobook test
# ---------------------------------------------------------------------------

sub isAudiobook {
	shift if _isClass( $_[0] );
	my $program = shift;
	return 0 unless ref $program eq 'HASH';

	my $template = _text( $program->{template} );
	return 1 if defined $template && lc $template eq 'audiobook';

	my $hasCollection = defined $program->{episodeCollectionId} && !ref $program->{episodeCollectionId} && length $program->{episodeCollectionId};
	return 0 if $hasCollection;

	return 1 if $program->{restricted};
	return 0 if defined $template;

	# no template: O2 didn't pass the program detail
	my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
	return defined $path && $path =~ m{\A/listen/audiobooks/[^/]} ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Chapters (data)
# ---------------------------------------------------------------------------

sub chapters {
	shift if _isClass( $_[0] );
	my ( $programId, $cb ) = @_;

	if ( ref $cb ne 'CODE' ) {
		$log->error('Audiobooks->chapters called without a callback');
		return;
	}

	my $settled = 0;
	my $answer  = sub {
		my $result = shift;
		return if $settled++;
		eval { $cb->($result); 1 } or $log->error( 'Audiobook chapters: the callback died: ' . ( $@ || 'unknown error' ) );
		return;
	};

	my $id = _digits($programId);
	if ( !defined $id ) {
		main::INFOLOG && $log->is_info && $log->info( 'Audiobook chapters: not a program id: ' . ( defined $programId ? "'$programId'" : 'undef' ) );
		return $answer->( { error => LOAD_FAILED } );
	}

	eval {
		Plugins::ABCListen::API::algolia(
			_query($id),
			sub {
				my ( $data, $info ) = @_;
				my $stale = ref $info eq 'HASH' && $info->{stale} ? 1 : 0;

				my $refs = eval { _chapterRefs( $id, $data, $stale ) };
				if ( ref $refs ne 'ARRAY' ) {
					$log->error( "Audiobook $id chapters: " . ( $@ || 'unknown error' ) );
					return $answer->( { error => LOAD_FAILED } );
				}

				_rememberCount( $id, scalar @$refs ) unless $stale;
				$answer->( { items => $refs } );
			},
			sub { $answer->( { error => _token(shift) } ) },
			{ ttl => CHAPTERS_TTL, stale_ok => 1, timeout => REQUEST_TIMEOUT },
		);
		1;
	} or do {
		$log->error( "Audiobook $id chapters: the search request failed: " . ( $@ || 'unknown error' ) );
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

# The Algolia response -> chapter refs in reading order (dies without a hits list).
sub _chapterRefs {
	my ( $id, $data, $stale ) = @_;

	die "the search response has no hits list\n" unless ref $data eq 'HASH' && ref $data->{hits} eq 'ARRAY';

	my @hits = @{ $data->{hits} };
	my $total = _positive( $data->{nbHits} );
	if ( $total && $total > @hits && !$truncationWarned{$id}++ ) {
		$log->warn( "Audiobook $id: ABC's search index has $total chapters, listing the " . scalar(@hits) . ' it returned' );
	}

	my $now = time();
	my ( @refs, %seen );

	for my $hit ( grep { ref $_ eq 'HASH' } @hits ) {
		my ( $type, $chapterId ) = Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} );
		next unless $type && $AUDIO_TYPE{$type};
		next if _gone( $hit->{mediaDownloadStatus} ) && _gone( $hit->{mediaStreamingStatus} );
		next if $seen{$chapterId}++;

		push @refs, _chapterRef( $hit, $type, $chapterId, $now, $stale );
	}

	return [ sort { $a->{id} <=> $b->{id} } @refs ];
}

sub _chapterRef {
	my ( $hit, $type, $id, $now, $stale ) = @_;

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
		$ref{seenAt}              = $now unless $stale;
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
# Chapter count (for the Chapters link; no network)
# ---------------------------------------------------------------------------

sub _countKey { "audiobooks:count:$_[0]" }

sub _cache { Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE ) }

sub _rememberCount {
	my ( $id, $count ) = @_;

	eval {
		my $known = _cachedCount($id);
		_cache()->set( _countKey($id), { count => $count }, CHAPTERS_TTL ) unless defined $known && $known == $count;
		1;
	} or $log->error( "Audiobook $id: couldn't cache the number of chapters: " . ( $@ || 'unknown error' ) );

	return;
}

# The number of chapters of a fresh answer in the last 24 h, else undef.
sub _cachedCount {
	my $id = shift;

	my $entry = eval { _cache()->get( _countKey($id) ) };
	return ref $entry eq 'HASH' && defined $entry->{count} && $entry->{count} =~ /\A[0-9]+\z/ ? $entry->{count} : undef;
}

# ---------------------------------------------------------------------------
# Program-menu provider and the Chapters feed
# ---------------------------------------------------------------------------

sub _programMenuExtras {
	my ( $client, $program, $cb ) = @_;

	my $rows = eval { [ _chaptersLink( $client, $program ) ] };
	$log->error( 'Building the audiobook Chapters item failed: ' . ( $@ || 'unknown error' ) ) unless $rows;

	$cb->( $rows || [] );
	return;
}

sub _chaptersLink {
	my ( $client, $program ) = @_;

	return () unless isAudiobook($program);

	my $id = _digits( $program->{id} );
	if ( !defined $id ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Audiobook without a program id (' . ( _text( $program->{path} ) || 'no path' ) . '): no Chapters item' );
		return ();
	}

	my %book = ( id => $id );
	$book{title} = _text( $program->{title} ) if defined _text( $program->{title} );
	$book{image} = $program->{image}          if _hasText( $program->{image} ) || ref $program->{image} eq 'HASH';

	my $count = _cachedCount($id);

	return {
		name        => defined $count ? cstring( $client, CHAPTERS_N, $count ) : cstring( $client, CHAPTERS ),
		type        => 'playlist',
		url         => \&_chaptersFeed,
		passthrough => [ \%book ],
	};
}

sub _chaptersFeed {
	my ( $client, $cb, $args, $book ) = @_;
	my $once = _once($cb);

	$book = {} unless ref $book eq 'HASH';

	my $id = _digits( $book->{id} );
	if ( !defined $id ) {
		$log->warn('Audiobook chapters opened without a program id (a stale or malformed item)');
		return _textFeed( $client, $once, LOAD_FAILED );
	}

	my $timer;
	my $stopTimer = sub {
		Slim::Utils::Timers::killSpecific($timer) if $timer;
		undef $timer;
	};

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + FEED_DEADLINE, sub {
		undef $timer;
		$log->warn( "Audiobook $id chapters: no answer from ABC within " . FEED_DEADLINE . ' s' );
		_textFeed( $client, $once, LOAD_FAILED );
	} );

	eval {
		chapters( $id, sub {
			my $result = shift;
			$stopTimer->();
			# after the deadline this only seeds the meta cache: $once drops the late answer
			_respond( $client, $once, sub { _chapterRows( $client, $book, $result ) } );
		} );
		1;
	} or do {
		$stopTimer->();
		$log->error( "Audiobook $id chapters failed: " . ( $@ || 'unknown error' ) );
		_textFeed( $client, $once, LOAD_FAILED );
	};

	return;
}

sub _chapterRows {
	my ( $client, $book, $result ) = @_;

	return [ _textItem( $client, LOAD_FAILED ) ] unless ref $result eq 'HASH';
	return [ _textItem( $client, $result->{error} ) ] if $result->{error};

	my @rows;
	for my $ref ( ref $result->{items} eq 'ARRAY' ? @{ $result->{items} } : () ) {
		next unless ref $ref eq 'HASH';

		my %episode = %$ref;
		$episode{programImage} = $book->{image} if defined $book->{image};
		$episode{programTitle} = $book->{title} if !defined $episode{programTitle} && defined $book->{title};
		$episode{programId}    = $book->{id}    if !defined $episode{programId};

		my $item = Plugins::ABCListen::OnDemand->episodeItem( $client, \%episode ) or next;
		_seed($ref);

		my $title = _hasText( $item->{line1} ) ? $item->{line1} : _hasText( $ref->{title} ) ? $ref->{title} : Plugins::ABCListen::Util::DISPLAY_NAME;
		$item->{name} = $item->{line1} = ( @rows + 1 ) . ". $title";

		push @rows, $item;
	}

	return @rows ? \@rows : [ _textItem( $client, NO_EPISODES ) ];
}

# Make sure the episode meta cache holds the chapter's seeded set (episodeItem stores it today).
sub _seed {
	my $ref = shift;
	my @keys = grep { defined $ref->{$_} } @SEED_KEYS;
	return unless ref $ref->{renditions} eq 'ARRAY' && @{ $ref->{renditions} };

	my $cached = Plugins::ABCListen::Util::getEpisodeMeta( $ref->{id} );
	my $stored = ref $cached eq 'HASH' && ref $cached->{renditions} eq 'ARRAY' && @{ $cached->{renditions} }
		&& ( !defined $ref->{seenAt} || ( defined $cached->{seenAt} && $cached->{seenAt} == $ref->{seenAt} ) );

	Plugins::ABCListen::Util::setEpisodeMeta( $ref->{id}, { map { $_ => $ref->{$_} } @keys } ) unless $stored;
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
