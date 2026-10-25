package Plugins::ABCListen::Episode;

# Episode playback: abclisten://episode/<coremediaId> (ai-state/streams.md contract 2) for every
# ABC listen episode, segment and audio clip the plugin lists. init registers the `episode` kind
# with the protocol handler (contract 4); Plugins::ABCListen::OnDemand->init calls it.
#
#   Plugins::ABCListen::Episode->resolve($id, $cb)
#     Finds the audio that is playable NOW and calls $cb exactly once, with either
#       { url => $first, alternates => [ ... ], meta => \%metadata, failToken => GEO (geo only) }
#       { error => TOKEN }   EPISODE_EXPIRED, EPISODE_RESTRICTED, EPISODE_NOT_FOUND, LOAD_FAILED,
#                            RATE_LIMITED
#     Where the renditions come from:
#       1. The episode metadata cache (contract 3), when it holds renditions seen less than 6 h ago
#          (seeded from Algolia by Search, or written here): no request at all.
#       2. Else the episode document (API::nextData, 1 h cache): from the cached path, or, without
#          one, from the generic path /listen/programs/x/x/<id>, which ABC redirects to the
#          canonical page for any episode, segment or news audio id (OQ1, spiked 2026-10-19).
#          F4: a cached path that fails (any error: a renamed page, a redirect API.pm can't
#          follow, a timeout) falls back once to the generic path, then step 3 as for any generic
#          path; the document found caches its canonical path over the failed one. F6: so does a
#          cached path that serves no document for this episode (no documentProps, or another
#          id's), e.g. one that API.pm now follows through a 307 x-nextjs-redirect to the
#          program page, or an audiobook chapter's, which redirects to its book.
#       3. A page without an episode document (an audiobook chapter redirects to its book), or a
#          failed generic path: ONE Algolia lookup by objectID. A hit with renditions is chosen
#          from directly (dates.mediaDownload*/mediaStreaming* are the windows, the 1x1 crop of
#          defaultThumbnail the image); a hit without them gives the page to fetch. No hit:
#          EPISODE_NOT_FOUND.
#     When that chain fails (the lookup, or the page a hit names), it answers from the cached
#     renditions of any age if there are some, else with the API's token (LOAD_FAILED or
#     RATE_LIMITED). F6: the cached renditions are also tried when the chain started from a
#     cached path that failed (or served no document for this episode) and then found nothing (no
#     search hit, a hit with neither audio nor a page, a document that isn't audio, or a second
#     lookup needed); without them that is
#     EPISODE_NOT_FOUND. Up to F4 those cases answered EPISODE_NOT_FOUND straight away, the cached
#     renditions untried, though before F4 the failed cached path alone would have played them.
#     NOT_FOUND from a chain that didn't start with a failed cached path is still answered
#     straight away (e.g. the cached path serves a document that isn't audio).
#     Every request has a 6 s timeout, and an 18 s deadline answers before the handler's 20 s
#     resolve timeout (from the cached renditions if any, else LOAD_FAILED). Whatever arrives
#     later is still cached, never answered twice.
#     What is fetched is merged into the metadata cache (contract-3 keys; windows as epochs;
#     renditions as { url, mime, bitrate, fileSize }, fileSize only when ABC gives one). A
#     restricted or not yet released episode closes the cached windows (availableTo and
#     downloadAvailableTo = now, or the answer's fetch time when that is earlier), so that
#     fallback answers EPISODE_EXPIRED rather than playing renditions cached earlier.
#     F7 (contract 3, D5's rule in Util): seenAt is the answer's fetch time (API.pm's info at:
#     documents and lookups come from a 1 h cache), never the time it was mapped, and is left out
#     for an answer 6 h old or older (Util::episodeSeenAt), so the 6 h shortcut never trusts
#     renditions more than 6 h old. An older answer never overwrites newer audio data: when the
#     cache's seenAt is later than the fetch time, or O1 closed its windows later than it
#     (Util::episodeMetaIsNewer), the answer's renditions, windows and seenAt are not written.
#
#   Bitrates (O6): ABC gives its AAC renditions bitrate 0. An AAC rendition whose bitrate is 0 or
#     missing gets fileSize x 8 / duration / 1000 kbps (3 decimals; e.g. 353,025,904 B over
#     10,799 s: 261.525), cached with the renditions. Without a fileSize or a duration it stays
#     as it was, and the stream stays unseekable.
#
#   Choosing a rendition (ai-state/research/abc-listen-api.md §4.3), at _now():
#     - webDistributionRestricted: EPISODE_RESTRICTED, whatever the renditions;
#     - MP3 (audio/mpeg, audio/mp3) plays while downloadAvailableFrom <= now < downloadAvailableTo;
#       AAC (audio/aac) while availableFrom <= now < availableTo; a missing bound is open. Every
#       other MIME type (the duplicate application/vnd.apple.mpegurl entry of the .aac file
#       included) and every .m3u8/.f4m URL is ignored;
#     - candidates: MP3 by bitrate (highest first; 0 or none last), then AAC, each URL once. The
#       first is url, the rest alternates. None: EPISODE_EXPIRED (also before the window opens);
#     - a /geo-001/ (mediacore) or /radio/geo/ (abcmedia; D5: audiobooks, Bluey Book Reads) URL among
#       them sets failToken EPISODE_GEO: it plays only in Australia, so when every candidate fails
#       the player says so (elsewhere Akamai answers 403).
#
#   episode kind metadata($client, $url, $id): synchronous, no network, never dies. From the
#     metadata cache: title, artist = programTitle, album = network (if a writer stored one)
#     else programTitle, cover = image at 600 px (else the plugin icon), duration. Without an
#     entry: the "ABC listen episode" title and the icon.
#
#   episode kind onStream($client, $song, $id) (O6): LMS seeks in a remote stream only when the
#     song has a bitrate and a duration (Slim::Player::Protocols::HTTP canSeek, getSeekData), and
#     its remote scan finds neither for ADTS AAC (Scanner::Remote parseAACHeader sets only the
#     sample rate). So a current track without a duration gets the cached episode duration, and
#     one without a bitrate gets the cached (or derived) bitrate of the rendition being streamed
#     ($song->streamUrl, or the track's redir after a redirect), in bps. Fill-only: a value LMS
#     set (an MP3's, from its headers) is never overwritten, so filling again (once per player in
#     a sync group, again after a seek) changes nothing. The song's own duration and start
#     offset are never set (the "never set song duration" rule, narrowed to this fill for O6).
#
#   Song info (O4): init also registers the Slim::Menu::TrackInfo provider 'abclistenepisode'
#     (after 'top'; Slim::Menu::Base orders providers with the same anchor by name, so these rows
#     come before M2's 'abclistenfollow' Follow rows). For an abclisten://episode/<id> URL with a
#     metadata cache entry, in this order, each only when known:
#       Episode notes   the cached description, shaped like core's COMMENT item:
#                       { name => "Episode notes", items => [ { type => 'text', wrap => 1, name } ], unfold => 1 }
#       More from <program>  OnDemand::_moreFromItem (the episode menu's row: program path from the
#                       cached path, title and id from the cache);
#       a tracklist row (when the cache has a path): "Tracklist (N)" with the rows inline when
#                       Tracklist->cached has rows, "No tracklist" (text) when it holds an empty
#                       list, else a "Tracklist" link whose feed runs Tracklist->fetch when opened
#                       and answers once: the rows, "No tracklist" or LOAD_FAILED.
#     Always the same number of rows for one cached entry (the tracklist row only changes form),
#     so the Follow rows after them keep their index (stale ids, see MyABC.pm).
#     Synchronous, no network I/O; undef for live or foreign URLs, without a cache entry (or a
#     corrupt one), or with nothing to show. Never dies: an exception is logged at WARN, undef.
#
# Owned by the ondemand stream (O1, O6; O4 added the song info).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::ProtocolHandler;
use Plugins::ABCListen::Tracklist;
use Plugins::ABCListen::Util qw(ICON decodeEntities parseISO8601);

use constant SEEN_MAX_AGE    => 6 * 3600;    # cached renditions younger than this are used without a request
use constant DOCUMENT_TTL    => 3600;        # episode documents (API::nextData ttl)
use constant REQUEST_TIMEOUT => 6;           # seconds, every request
use constant DEADLINE        => 18;          # seconds for a whole resolve (the handler gives up at 20)
use constant COVER_PX        => 600;

# An open-ended window bound, as stored in the metadata cache (2100-01-01T00:00:00Z). A missing
# value can't be stored: the cache merge never clears a field.
use constant OPEN_END => 4_102_444_800;

use constant GENERIC_PATH => '/listen/programs/x/x/%s';

use constant EXPIRED      => 'PLUGIN_ABCLISTEN_EPISODE_EXPIRED';
use constant RESTRICTED   => 'PLUGIN_ABCLISTEN_EPISODE_RESTRICTED';
use constant GEO          => 'PLUGIN_ABCLISTEN_EPISODE_GEO';
use constant NOT_FOUND    => 'PLUGIN_ABCLISTEN_EPISODE_NOT_FOUND';
use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';
use constant TITLE        => 'PLUGIN_ABCLISTEN_EPISODE';

my $log = logger('plugin.abclisten');

my @AUDIO_TYPES = qw(audioepisode audio audiosegment);
my %AUDIO_TYPE  = map { $_ => 1 } @AUDIO_TYPES;
my %MP3         = map { $_ => 1 } qw(audio/mpeg audio/mp3);
my $AAC         = 'audio/aac';

# The episode metadata cache keys this module writes (contract 3).
my @META_KEYS = qw(docType title programTitle programId path image description date duration);

sub init {
	Plugins::ABCListen::ProtocolHandler->registerKind(
		episode => {
			resolve  => sub { my ( $client, $id, $cb ) = @_; __PACKAGE__->resolve( $id, $cb ) },
			metadata => \&_kindMetadata,
			onStream => \&_onStream,
		}
	);

	# O4: the episode's song info (notes, More from, tracklist)
	eval {
		require Slim::Menu::TrackInfo;
		Slim::Menu::TrackInfo->registerInfoProvider( abclistenepisode => (
			after => 'top',
			func  => \&_trackInfo,
		) );
		1;
	} or $log->error( 'Could not add the episode notes to ABC listen song info: ' . ( $@ || 'unknown error' ) );

	return;
}

# The current time, for the availability windows (tests override it).
sub _now { time() }

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

sub resolve {
	my ( $class, $id, $cb ) = @_;

	if ( ref $cb ne 'CODE' ) {
		$log->error('Episode->resolve called without a callback');
		return;
	}

	my $state = { id => $id, cb => $cb };

	if ( !defined $id || ref $id || $id !~ /\A[0-9]+\z/ ) {
		main::INFOLOG && $log->is_info && $log->info( 'Not an episode id: ' . ( defined $id ? "'$id'" : 'undef' ) );
		return _answer( $state, { error => NOT_FOUND } );
	}

	$state->{id} = $id = "$id";

	my $entry = _entry($id);
	if ( _hasRenditions($entry) && _isRecent( $entry->{seenAt} ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Episode $id: choosing from the renditions in the metadata cache");
		return _answer( $state, _result( $id, _choose( $entry, _now() ) ) );
	}

	$state->{timer} = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + DEADLINE, \&_deadline, $state );

	my $path = $entry ? Plugins::ABCListen::API::sitePath( $entry->{path} ) : undef;

	return _fetch( $state, $path, 'cached' ) if defined $path;
	return _fetch( $state, sprintf( GENERIC_PATH, $id ), 'generic' );
}

# The episode document at $path. $kind 'cached': the path in the metadata cache; if it fails (any
# error) or (F6) serves no document for this episode, fall back once to the id-based chain, the
# generic path (F4, _fallback), where finding nothing then tries the cached renditions before
# NOT_FOUND (F6, _notFound). 'generic': a guess; if it fails, look the id up. undef: the page a
# search hit names; if it fails, that's the answer.
sub _fetch {
	my ( $state, $path, $kind ) = @_;
	$kind ||= '';

	Plugins::ABCListen::API::nextData(
		$path,
		sub { $state->{fetched} = $_[1]; _document( $state, $path, $_[0], $kind ) },    # F7: the answer's fetch info
		sub {
			my $error = shift;
			my $why   = "$path failed (" . _message($error) . ')';

			return _fallback( $state, "the cached path $why" ) if $kind eq 'cached';
			return _lookup( $state, $why ) if $kind eq 'generic';

			_failed( $state, "the episode page $path", $error );
		},
		{ ttl => DOCUMENT_TTL, timeout => REQUEST_TIMEOUT, ( $kind eq 'generic' ? ( quiet => 1 ) : () ) },
	);

	return;
}

# F4: the cached path failed; F6: or it served no document for this episode. Either way the path
# that once served it no longer does: the generic path next (once), and if the chain then finds
# nothing, the cached renditions (_notFound).
sub _fallback {
	my ( $state, $why ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Episode $state->{id}: $why; trying the generic path");
	$state->{cachedPathFailed} = 1;

	return _fetch( $state, sprintf( GENERIC_PATH, $state->{id} ), 'generic' );
}

sub _document {
	my ( $state, $path, $pageProps, $kind ) = @_;
	my $id = $state->{id};

	my $data = ref $pageProps eq 'HASH' && ref $pageProps->{data} eq 'HASH' ? $pageProps->{data} : {};
	my $doc  = $data->{documentProps};

	# not this episode's page: from the cached path (F6: e.g. a 307 to the program page that API.pm
	# followed), fall back to the generic path; else (e.g. an audiobook chapter, whose page
	# redirects to its book) look the id up
	my $notHere = sub {
		my $why = shift;
		return ( $kind || '' ) eq 'cached' ? _fallback( $state, "the cached path: $why" ) : _lookup( $state, $why );
	};

	return $notHere->("no episode document at $path") unless ref $doc eq 'HASH';

	my $docId = _digits( $doc->{id} );
	return $notHere->("the document at $path is $docId") if defined $docId && $docId ne $id;

	my $docType = _text( $doc->{docType} );
	if ( !defined $docType || !$AUDIO_TYPE{$docType} ) {
		return _notFound( $state, "$path is not audio (docType " . ( defined $docType ? $docType : 'none' ) . ')' );
	}

	_found( $state, _parseDocument($doc) );
	return;
}

# One Algolia lookup per resolve; a second reason to look up means the episode isn't there.
sub _lookup {
	my ( $state, $why ) = @_;
	my $id = $state->{id};

	return _notFound( $state, $why ) if $state->{lookedUp}++;

	main::DEBUGLOG && $log->is_debug && $log->debug("Episode $id: $why; looking it up in ABC's search index");

	Plugins::ABCListen::API::algolia(
		{
			query                => '',
			filters              => join( ' OR ', map {qq{objectID:"coremedia://$_/$id"}} @AUDIO_TYPES ),
			hitsPerPage          => 1,
			attributesToRetrieve => [qw(objectID canonicalURL title programTitle programID duration dates mediaRenditions defaultThumbnail)],
		},
		sub { $state->{fetched} = $_[1]; _hit( $state, $_[0] ) },    # F7: the answer's fetch info
		sub { _failed( $state, 'the search index lookup', shift ) },
		{ timeout => REQUEST_TIMEOUT },
	);

	return;
}

sub _hit {
	my ( $state, $data ) = @_;
	my $id = $state->{id};

	my $hit = ref $data eq 'HASH' && ref $data->{hits} eq 'ARRAY' ? $data->{hits}->[0] : undef;
	my ( $type, $hitId ) = ref $hit eq 'HASH' ? Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} ) : ();

	if ( !$type || !$AUDIO_TYPE{$type} || $hitId ne $id ) {
		return _notFound( $state, "no episode page and not in ABC's search index" );
	}

	my $episode = _parseHit( $hit, $type );

	# audiobook chapters: the index has their renditions (their page is the book's)
	return _found( $state, $episode ) if @{ $episode->{renditions} };

	return _fetch( $state, $episode->{path} ) if defined $episode->{path};

	return _notFound( $state, 'its search index entry has neither audio nor a page' );
}

# The episode isn't there: no search hit, a hit with neither audio nor a page, a document that
# isn't audio, or a second lookup needed. F6: if the chain started from a cached path that failed
# or served no document for this episode (_fallback), that path once served the episode, so this
# is answered like a failed request
# (_failed): from the renditions cached earlier, any age, if there are some, else NOT_FOUND.
sub _notFound {
	my ( $state, $why ) = @_;

	if ( $state->{cachedPathFailed} ) {
		return _failed( $state, 'the cached path and the id chain', { error => NOT_FOUND, message => "episode not found: $why" } );
	}

	main::INFOLOG && $log->is_info && $log->info("Episode $state->{id} not found: $why");
	return _answer( $state, { error => NOT_FOUND } );
}

# A parsed episode: cache it, then answer (unless answered already: late results are cached only).
sub _found {
	my ( $state, $episode ) = @_;
	my $now = _now();

	_remember( $state->{id}, $episode, $now, $state->{fetched} );
	_answer( $state, _result( $state->{id}, _choose( $episode, $now ) ) );

	return;
}

# A request failed, or (F6, _notFound) the fallback from a failed cached path found nothing: the
# cached renditions, whatever their age, else the token (RATE_LIMITED or NOT_FOUND as given, any
# other error LOAD_FAILED).
sub _failed {
	my ( $state, $what, $error ) = @_;
	my $id = $state->{id};

	my $message = _message($error);

	if ( $state->{answered} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Episode $id: $what failed after the answer ($message)");
		return;
	}

	my $entry = _entry($id);
	if ( _hasRenditions($entry) ) {
		$log->warn("Episode $id: $what failed ($message); choosing from the renditions cached earlier");
		return _answer( $state, _result( $id, _choose( $entry, _now() ) ) );
	}

	my $given = ref $error eq 'HASH' && defined $error->{error} ? $error->{error} : '';
	my $token = $given eq RATE_LIMITED || $given eq NOT_FOUND ? $given : LOAD_FAILED;

	main::INFOLOG && $log->is_info && $log->info("Episode $id: $what failed ($message)");
	return _answer( $state, { error => $token } );
}

sub _deadline {
	my ( undef, $state ) = @_;
	delete $state->{timer};

	return if $state->{answered};

	my $id    = $state->{id};
	my $entry = _entry($id);

	if ( _hasRenditions($entry) ) {
		$log->warn( "Episode $id: no answer from ABC within " . DEADLINE . ' s; choosing from the renditions cached earlier' );
		return _answer( $state, _result( $id, _choose( $entry, _now() ) ) );
	}

	$log->warn( "Episode $id: no answer from ABC within " . DEADLINE . ' s' );
	return _answer( $state, { error => LOAD_FAILED } );
}

# Call back once; later answers are dropped.
sub _answer {
	my ( $state, $result ) = @_;
	return if $state->{answered}++;

	Slim::Utils::Timers::killSpecific( delete $state->{timer} ) if $state->{timer};

	my $id = defined $state->{id} ? $state->{id} : 'undef';

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( "Episode $id: "
				. ( $result->{error} ? $result->{error}
				: join( ' ', 'play', $result->{url}, map {"(alternate $_)"} @{ $result->{alternates} } ) . ( $result->{failToken} ? " ($result->{failToken} if none plays)" : '' ) ) );
	}

	my $cb = delete $state->{cb};
	eval { $cb->($result); 1 } or $log->error( "Episode $id: the resolve callback died: " . ( $@ || 'unknown error' ) );

	return;
}

# A choice -> the resolve answer: errors as they are, candidates with the Now Playing metadata.
sub _result {
	my ( $id, $choice ) = @_;
	return $choice if $choice->{error};
	return { %$choice, meta => _metadataFor( undef, $id ) };
}

# ---------------------------------------------------------------------------
# Rendition choice
# ---------------------------------------------------------------------------

# $episode: { renditions => [ { url, mime, bitrate } ], availableFrom, availableTo,
# downloadAvailableFrom, downloadAvailableTo (epochs or ISO-8601; missing = open), restricted }
# -> { url, alternates, failToken? } or { error }.
sub _choose {
	my ( $episode, $now ) = @_;

	return { error => RESTRICTED } if $episode->{restricted};

	my $mp3Open = _inWindow( $episode->{downloadAvailableFrom}, $episode->{downloadAvailableTo}, $now );
	my $aacOpen = _inWindow( $episode->{availableFrom},         $episode->{availableTo},         $now );

	my ( @mp3, @aac );
	my $i = 0;

	for my $rendition ( ref $episode->{renditions} eq 'ARRAY' ? @{ $episode->{renditions} } : () ) {
		next unless ref $rendition eq 'HASH' && _isUrl( $rendition->{url} );
		next if $rendition->{url} =~ m{\.(?:m3u8|f4m)(?:[?#]|\z)}i;

		my $mime = _mime( $rendition->{mime} );
		next unless defined $mime;

		if    ( $MP3{$mime} )   { push @mp3, [ $rendition->{url}, _bitrate( $rendition->{bitrate} ) || 0, $i++ ] if $mp3Open }
		elsif ( $mime eq $AAC ) { push @aac, $rendition->{url} if $aacOpen }
	}

	my %seen;
	my @candidates = grep { !$seen{$_}++ } ( map { $_->[0] } sort { $b->[1] <=> $a->[1] || $a->[2] <=> $b->[2] } @mp3 ), @aac;

	return { error => EXPIRED } unless @candidates;

	my %choice = ( url => shift @candidates, alternates => \@candidates );
	$choice{failToken} = GEO if grep {m{/(?:geo-001|radio/geo)/}} $choice{url}, @candidates;

	return \%choice;
}

sub _inWindow {
	my ( $from, $to, $now ) = @_;

	$from = _epoch($from);
	$to   = _epoch($to);

	return 0 if defined $from && $now < $from;
	return 0 if defined $to && $now >= $to;
	return 1;
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# pageProps.data.documentProps -> episode (see _choose) plus the metadata cache fields.
sub _parseDocument {
	my $doc = shift;

	my $dateline = ref $doc->{datelinePrepared} eq 'HASH' ? $doc->{datelinePrepared} : {};

	return {
		docType               => _text( $doc->{docType} ),
		title                 => _text( $doc->{title} ),
		description           => _text( $doc->{synopsis} ),
		programTitle          => _programTitle($doc),
		programId             => _digits( $doc->{programID} ),
		path                  => Plugins::ABCListen::API::sitePath( $doc->{canonicalURL} ),
		image                 => _documentImage($doc),
		date                  => _epoch( $dateline->{publishedDate} ),
		duration              => _positive( $doc->{duration} ),
		renditions            => _renditions( $doc->{renditions}, 'MIMEType', $doc->{duration} ),
		availableFrom         => _epoch( $doc->{availableFrom} ),
		availableTo           => _epoch( $doc->{availableTo} ),
		downloadAvailableFrom => _epoch( $doc->{downloadAvailableFrom} ),
		downloadAvailableTo   => _epoch( $doc->{downloadAvailableTo} ),
		restricted            => _isTrue( $doc->{webDistributionRestricted} ),
	};
}

# An Algolia hit (attributesToRetrieve of _lookup) -> episode, like _parseDocument.
sub _parseHit {
	my ( $hit, $docType ) = @_;

	my $dates = ref $hit->{dates} eq 'HASH' ? $hit->{dates} : {};

	return {
		docType               => $docType,
		title                 => _text( $hit->{title} ),
		programTitle          => _text( $hit->{programTitle} ),
		programId             => _digits( $hit->{programID} ),
		path                  => Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} ),
		image                 => _hitImage( $hit->{defaultThumbnail} ),
		date                  => _epoch( $dates->{publicationDate} ),
		duration              => _positive( $hit->{duration} ),
		renditions            => _renditions( $hit->{mediaRenditions}, 'contentType', $hit->{duration} ),
		availableFrom         => _epoch( $dates->{mediaStreamingAvailableFrom} ),
		availableTo           => _epoch( $dates->{mediaStreamingAvailableTo} ),
		downloadAvailableFrom => _epoch( $dates->{mediaDownloadAvailableFrom} ),
		downloadAvailableTo   => _epoch( $dates->{mediaDownloadAvailableTo} ),
	};
}

# The "Program:" attribution link's title, else the first link's.
sub _programTitle {
	my $doc = shift;

	my $attribution = ref $doc->{attributionLinksPrepared} eq 'HASH' ? $doc->{attributionLinksPrepared} : {};
	my @links = grep { ref $_ eq 'HASH' } ref $attribution->{links} eq 'ARRAY' ? @{ $attribution->{links} } : ();

	my ($program) = grep { ( _text( $_->{screenReaderText} ) || '' ) eq 'Program:' } @links;
	$program ||= $links[0];

	return $program ? _text( $program->{title} ) : undef;
}

# Hero image, else the thumbnail's large 1x1 crop, else the program image.
sub _documentImage {
	my $doc = shift;

	my $hero = ref $doc->{heroImageWithCTAPrepared} eq 'HASH' ? $doc->{heroImageWithCTAPrepared} : {};

	for my $url ( _imgSrc( $hero->{heroImagePrepared} ), _thumbnail( $doc->{thumbnailLink} ), _imgSrc( $hero->{programImagePrepared} ) ) {
		return $url if _isUrl($url);
	}

	return undef;
}

sub _imgSrc { ref $_[0] eq 'HASH' ? $_[0]->{imgSrc} : undef }

sub _thumbnail {
	my $thumbnail = shift;
	return undef unless ref $thumbnail eq 'HASH' && ref $thumbnail->{cropInfo} eq 'ARRAY';

	for my $crop ( @{ $thumbnail->{cropInfo} } ) {
		next unless ref $crop eq 'HASH' && ( $crop->{key} || '' ) eq 'large' && ref $crop->{value} eq 'ARRAY';

		for my $size ( @{ $crop->{value} } ) {
			return $size->{url} if ref $size eq 'HASH' && ( $size->{ratio} || '' ) eq '1x1' && _isUrl( $size->{url} );
		}
	}

	return undef;
}

# An Algolia hit's defaultThumbnail ({ <ratio> => URL }): its 1x1 crop, if any.
sub _hitImage {
	my $thumbnail = shift;
	return ref $thumbnail eq 'HASH' && _isUrl( $thumbnail->{'1x1'} ) ? $thumbnail->{'1x1'} : undef;
}

# [ { url, <$mimeKey>, bitrate, fileSize } ] -> [ { url, mime, bitrate, fileSize } ] (entries
# without a URL dropped; fileSize only when positive). An AAC rendition without a bitrate gets
# the one derived from its fileSize and the episode's $duration (_kbps).
sub _renditions {
	my ( $list, $mimeKey, $duration ) = @_;
	return [] unless ref $list eq 'ARRAY';

	my @renditions;

	for my $entry ( grep { ref $_ eq 'HASH' && _isUrl( $_->{url} ) } @$list ) {
		my %rendition = ( url => $entry->{url}, mime => _mime( $entry->{$mimeKey} ), bitrate => _bitrate( $entry->{bitrate} ) );

		my $fileSize = _positive( $entry->{fileSize} );
		$rendition{fileSize} = $fileSize if defined $fileSize;

		my $kbps = _kbps( \%rendition, $duration );
		$rendition{bitrate} = $kbps if defined $kbps;

		push @renditions, \%rendition;
	}

	return \@renditions;
}

# A rendition's bitrate in kbps: its own when positive; else, for AAC only, fileSize x 8 /
# duration / 1000 (3 decimals); else undef (no fileSize or duration, or zero: nothing derived).
sub _kbps {
	my ( $rendition, $duration ) = @_;

	my $bitrate = _positive( $rendition->{bitrate} );
	return $bitrate if defined $bitrate;

	my $mime = _mime( $rendition->{mime} );
	return undef unless defined $mime && $mime eq $AAC;

	my $fileSize = _positive( $rendition->{fileSize} );
	$duration = _positive($duration);
	return undef unless defined $fileSize && defined $duration;

	return sprintf( '%.3f', $fileSize * 8 / $duration / 1000 ) + 0;
}

# ---------------------------------------------------------------------------
# Episode metadata cache
# ---------------------------------------------------------------------------

# Merge a fetched episode into the metadata cache. The renditions, their windows and seenAt (what
# the 6 h shortcut plays from) only when they say what plays: not for a restricted episode or one
# not released yet (the cache has no field for either), nor without renditions. Such an episode
# closes the cached windows instead (both = now, or the fetch time when earlier): renditions
# cached earlier (e.g. seeded by Search) then answer EPISODE_EXPIRED when a later request fails,
# instead of playing. F7: $info is the answer's API.pm success info; seenAt is its fetch time
# (Util::episodeSeenAt), and none of that audio data is written over newer data
# (Util::episodeMetaIsNewer).
sub _remember {
	my ( $id, $episode, $now, $info ) = @_;

	$info = {} unless ref $info eq 'HASH';
	my $at = _epoch( $info->{at} );

	my %meta = map { ( $_ => $episode->{$_} ) } @META_KEYS;

	my $notYet = grep { defined $_ && $_ > $now } map { _epoch( $episode->{$_} ) } qw(availableFrom downloadAvailableFrom);

	if ( $episode->{restricted} || $notYet ) {
		$meta{availableTo} = $meta{downloadAvailableTo} = defined $at && $at < $now ? $at : $now;
	}
	elsif ( @{ $episode->{renditions} } ) {
		$meta{renditions}          = $episode->{renditions};
		$meta{availableTo}         = _bound( $episode->{availableTo} );
		$meta{downloadAvailableTo} = _bound( $episode->{downloadAvailableTo} );
		$meta{seenAt}              = Plugins::ABCListen::Util::episodeSeenAt( $info, $now );
	}

	# an older answer never overwrites newer audio data (a newer seed, or windows closed since)
	delete @meta{ Plugins::ABCListen::Util::episodeAudioKeys() } if Plugins::ABCListen::Util::episodeMetaIsNewer( $id, $at );

	Plugins::ABCListen::Util::setEpisodeMeta( $id, \%meta );

	return;
}

sub _bound {
	my $epoch = _epoch(shift);
	return defined $epoch ? $epoch : OPEN_END;
}

# The cache entry, or undef if there is none or it is corrupt (not a hash; renditions not a list).
sub _entry {
	my $id = shift;

	my $entry = eval { Plugins::ABCListen::Util::getEpisodeMeta($id) };
	return undef unless ref $entry eq 'HASH';
	return undef if defined $entry->{renditions} && ref $entry->{renditions} ne 'ARRAY';

	return $entry;
}

sub _hasRenditions { my $entry = shift; return $entry && ref $entry->{renditions} eq 'ARRAY' && @{ $entry->{renditions} } ? 1 : 0 }

sub _isRecent {
	my $seenAt = _epoch(shift);
	return 0 unless defined $seenAt;

	my $age = _now() - $seenAt;
	return $age >= 0 && $age < SEEN_MAX_AGE ? 1 : 0;
}

# ---------------------------------------------------------------------------
# The episode kind's metadata
# ---------------------------------------------------------------------------

sub _kindMetadata {
	my ( $client, $url, $id ) = @_;

	my $meta = eval { _metadataFor( $client, $id ) };
	return $meta if ref $meta eq 'HASH';

	# called for every status refresh: DEBUG only
	main::DEBUGLOG && $log->is_debug && $log->debug( 'Metadata for episode ' . ( defined $id ? $id : 'undef' ) . ' failed: ' . ( $@ || 'unknown error' ) );
	return { title => _fallbackTitle($client), cover => ICON };
}

sub _metadataFor {
	my ( $client, $id ) = @_;

	my $entry = _entry($id) || {};

	my $title   = _plain( $entry->{title} );
	my $program = _plain( $entry->{programTitle} );
	my $network = _plain( $entry->{network} );
	my $cover   = _isUrl( $entry->{image} ) ? Plugins::ABCListen::API::imageUrl( $entry->{image}, COVER_PX ) : undef;

	my %meta = (
		title => defined $title ? $title : _fallbackTitle($client),
		cover => $cover || ICON,
	);

	$meta{artist} = $program if defined $program;
	$meta{album}  = defined $network ? $network : $program if defined $network || defined $program;

	my $duration = _positive( $entry->{duration} );
	$meta{duration} = $duration if defined $duration;

	return \%meta;
}

sub _fallbackTitle {
	my $client = shift;

	my $title = Slim::Utils::Strings::cstring( $client, TITLE );
	return defined $title && length $title ? $title : Plugins::ABCListen::Util::DISPLAY_NAME;
}

# ---------------------------------------------------------------------------
# The episode kind's onStream: fill the track's empty duration and bitrate, so LMS can seek
# ---------------------------------------------------------------------------

sub _onStream {
	my ( $client, $song, $id ) = @_;

	my $track = $song && $song->currentTrack or return;

	my ( $secs, $bitrate ) = ( $track->secs, $track->bitrate );
	return if $secs && $bitrate;    # LMS knows both (an MP3): nothing to fill

	my $entry = _entry($id) or return;

	my $duration = _positive( $entry->{duration} );
	my $kbps     = _streamKbps( $entry, $duration, $song->streamUrl, $track->can('redir') ? $track->redir : undef );

	# fill-only: what LMS set is never overwritten
	Slim::Music::Info::setDuration( $track, $duration ) if !$track->secs && defined $duration;
	Slim::Music::Info::setBitrate( $track, int( $kbps * 1000 + 0.5 ) ) if !$track->bitrate && defined $kbps;

	main::INFOLOG && $log->is_info && $log->info( "Episode $id: LMS gave the stream "
			. ( $secs    ? "duration $secs s" : 'no duration' ) . ' and '
			. ( $bitrate ? "bitrate $bitrate bps" : 'no bitrate' )
			. '; from the metadata cache it now has duration ' . ( $track->secs ? $track->secs . ' s' : 'unknown' )
			. ' and bitrate ' . ( $track->bitrate ? $track->bitrate . ' bps' : 'unknown' ) );

	return;
}

# The kbps (cached, or derived by _kbps) of the cached rendition being streamed: the one whose URL
# is one of @urls (the song's stream URL, and the URL before a redirect); undef if none has one.
sub _streamKbps {
	my ( $entry, $duration, @urls ) = @_;

	my %streaming = map { ( $_ => 1 ) } grep { defined $_ && !ref $_ && length $_ } @urls;

	for my $rendition ( ref $entry->{renditions} eq 'ARRAY' ? @{ $entry->{renditions} } : () ) {
		next unless ref $rendition eq 'HASH' && defined $rendition->{url} && !ref $rendition->{url} && $streaming{ $rendition->{url} };

		my $kbps = _kbps( $rendition, $duration );
		return $kbps if defined $kbps;
	}

	return undef;
}

# ---------------------------------------------------------------------------
# === O4 === Song info (Slim::Menu::TrackInfo provider 'abclistenepisode', see the header)
# ---------------------------------------------------------------------------

sub _trackInfo {
	my ( $client, $url ) = @_;

	my $items = eval { _trackInfoItems( $client, $url ) };

	if ($@) {
		$log->warn( 'Song info for ' . ( defined $url && !ref $url ? $url : 'an episode' ) . " failed: $@" );
		return undef;
	}

	return ref $items eq 'ARRAY' && @$items ? $items : undef;
}

# Synchronous, no I/O: the rows from the metadata cache and the cached tracklist.
sub _trackInfoItems {
	my ( $client, $url ) = @_;

	my $parsed = Plugins::ABCListen::Util::parseUrl($url);
	return undef unless $parsed && $parsed->{kind} eq 'episode';

	my $id    = $parsed->{id};
	my $entry = _entry($id) or return undef;

	my @items;

	# shaped like core's COMMENT item: a bare text item shows as an empty row in some UIs
	my $notes = _plain( $entry->{description} );
	push @items, {
		name   => Slim::Utils::Strings::cstring( $client, 'PLUGIN_ABCLISTEN_EPISODE_NOTES' ),
		items  => [ { type => 'text', wrap => 1, name => $notes } ],
		unfold => 1,
	} if defined $notes;

	my $more = Plugins::ABCListen::OnDemand::_moreFromItem( $client, { %$entry, id => $id } );
	push @items, $more if $more;

	my $path = Plugins::ABCListen::API::sitePath( $entry->{path} );
	push @items, _trackInfoTracklist( $client, $id, $path ) if defined $path && $path ne '/';

	return \@items;
}

# Tracklist (N) with the rows inline when they are cached, No tracklist when the cache holds an
# empty list, else a Tracklist link that fetches them when opened.
sub _trackInfoTracklist {
	my ( $client, $id, $path ) = @_;

	my $rows = Plugins::ABCListen::Tracklist::cached($id);

	if ( !$rows ) {
		return {
			name        => Slim::Utils::Strings::cstring( $client, 'PLUGIN_ABCLISTEN_TRACKLIST_LINK' ),
			type        => 'link',
			url         => \&_trackInfoTracklistFeed,
			passthrough => [ { id => $id, path => $path } ],
		};
	}

	my @rows = Plugins::ABCListen::OnDemand::_tracklistRows($rows);
	return { name => Slim::Utils::Strings::cstring( $client, 'PLUGIN_ABCLISTEN_NO_TRACKLIST' ), type => 'text' } unless @rows;

	return {
		name  => Slim::Utils::Strings::cstring( $client, 'PLUGIN_ABCLISTEN_TRACKLIST', scalar @rows ),
		type  => 'link',
		items => \@rows,
	};
}

# The Tracklist link's feed: the rows (text items), No tracklist, or LOAD_FAILED, exactly once.
sub _trackInfoTracklistFeed {
	my ( $client, $cb, $args, $episode ) = @_;

	my $answered = 0;
	my $answer   = sub {
		return if $answered++;
		my $items = shift;
		eval { $cb->( { items => $items } ); 1 } or $log->error( 'Song info tracklist: the callback died: ' . ( $@ || 'unknown error' ) );
	};

	my $text = sub { [ { name => Slim::Utils::Strings::cstring( $client, shift ), type => 'text' } ] };

	eval {
		Plugins::ABCListen::Tracklist::fetch( $episode, sub {
			my $result = shift;

			my $items = eval {
				return $text->(LOAD_FAILED) unless ref $result eq 'HASH' && ref $result->{items} eq 'ARRAY';
				my @rows = Plugins::ABCListen::OnDemand::_tracklistRows( $result->{items} );
				return @rows ? \@rows : $text->('PLUGIN_ABCLISTEN_NO_TRACKLIST');
			};

			$answer->( ref $items eq 'ARRAY' ? $items : $text->(LOAD_FAILED) );
		} );
		1;
	} or do {
		$log->error( 'Song info tracklist failed: ' . ( $@ || 'unknown error' ) );
		$answer->( $text->(LOAD_FAILED) );
	};

	return;
}

# === end O4 ===

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Epoch seconds or an ISO-8601 date-time -> epoch; ABC's "permanent" 2200-01-01 (beyond
# parseISO8601's years) -> OPEN_END; else undef.
sub _epoch {
	my $value = shift;
	return undef unless defined $value && !ref $value;

	return $value + 0 if $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/;

	my $epoch = parseISO8601($value);
	return $epoch if defined $epoch;

	return $value =~ /\A\s*([0-9]{4})-[0-9]{2}-[0-9]{2}T/ && $1 > 2100 ? OPEN_END : undef;
}

# Entity-decoded, trimmed text, or undef if empty.
sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;

	return length $text ? $text : undef;
}

# A non-empty string as stored (cached text is decoded by its writer), or undef.
sub _plain {
	my $text = shift;
	return defined $text && !ref $text && $text =~ /\S/ ? $text : undef;
}

sub _mime {
	my $mime = shift;
	return undef unless defined $mime && !ref $mime;

	$mime = lc $mime;
	$mime =~ s/;.*\z//s;
	$mime =~ s/\A\s+|\s+\z//g;

	return length $mime ? $mime : undef;
}

sub _bitrate {
	my $bitrate = shift;
	return defined $bitrate && !ref $bitrate && $bitrate =~ /\A[0-9]+(?:\.[0-9]+)?\z/ ? $bitrate + 0 : undef;
}

sub _positive {
	my $value = shift;
	return defined $value && !ref $value && $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $value > 0 ? $value + 0 : undef;
}

sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }

sub _isUrl { defined $_[0] && !ref $_[0] && $_[0] =~ m{\Ahttps?://\S+\z}i }

# JSON true (any JSON boolean class), or a true string other than 'false'.
sub _isTrue {
	my $value = shift;
	return 0 unless defined $value;
	return $value ? 1 : 0 if ref $value;
	return $value && lc $value ne 'false' ? 1 : 0;
}

sub _message {
	my $error = shift;
	return ref $error eq 'HASH' && defined $error->{message} ? $error->{message} : 'unknown error';
}

1;
