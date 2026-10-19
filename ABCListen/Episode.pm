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
#       3. A page without an episode document (an audiobook chapter redirects to its book), or a
#          failed generic path: ONE Algolia lookup by objectID. A hit with renditions is chosen
#          from directly (dates.mediaDownload*/mediaStreaming* are the windows); a hit without
#          them gives the page to fetch. No hit: EPISODE_NOT_FOUND.
#     A failed request answers from the cached renditions of any age if there are some, else
#     with the API's token (LOAD_FAILED or RATE_LIMITED). Every request has a 6 s timeout, and an
#     18 s deadline answers before the handler's 20 s resolve timeout (from the cached renditions
#     if any, else LOAD_FAILED). Whatever arrives later is still cached, never answered twice.
#     What is fetched is merged into the metadata cache (contract-3 keys; windows as epochs).
#
#   Choosing a rendition (ai-state/research/abc-listen-api.md §4.3), at _now():
#     - webDistributionRestricted: EPISODE_RESTRICTED, whatever the renditions;
#     - MP3 (audio/mpeg, audio/mp3) plays while downloadAvailableFrom <= now < downloadAvailableTo;
#       AAC (audio/aac) while availableFrom <= now < availableTo; a missing bound is open. Every
#       other MIME type (the duplicate application/vnd.apple.mpegurl entry of the .aac file
#       included) and every .m3u8/.f4m URL is ignored;
#     - candidates: MP3 by bitrate (highest first; 0 or none last), then AAC, each URL once. The
#       first is url, the rest alternates. None: EPISODE_EXPIRED (also before the window opens);
#     - a /geo-001/ URL among them sets failToken EPISODE_GEO: it plays only in Australia, so
#       when every candidate fails the player says so (elsewhere Akamai answers 403).
#
#   episode kind metadata($client, $url, $id): synchronous, no network, never dies. From the
#     metadata cache: title, artist = programTitle, album = network (if a writer stored one)
#     else programTitle, cover = image at 600 px (else the plugin icon), duration. Without an
#     entry: the "ABC listen episode" title and the icon. Seeking and the progress bar are left
#     to LMS's remote scan: the song's duration and start offset are never set here.
#
# Owned by the ondemand stream (O1).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::ProtocolHandler;
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
		}
	);

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

	return _fetch( $state, $path ) if defined $path;
	return _fetch( $state, sprintf( GENERIC_PATH, $id ), 1 );
}

# The episode document at $path. The generic path is a guess: if it fails, look the id up.
sub _fetch {
	my ( $state, $path, $generic ) = @_;

	Plugins::ABCListen::API::nextData(
		$path,
		sub { _document( $state, $path, shift ) },
		sub {
			my $error = shift;
			return _lookup( $state, "$path failed (" . _message($error) . ')' ) if $generic;
			_failed( $state, "the episode page $path", $error );
		},
		{ ttl => DOCUMENT_TTL, timeout => REQUEST_TIMEOUT, ( $generic ? ( quiet => 1 ) : () ) },
	);

	return;
}

sub _document {
	my ( $state, $path, $pageProps ) = @_;
	my $id = $state->{id};

	my $data = ref $pageProps eq 'HASH' && ref $pageProps->{data} eq 'HASH' ? $pageProps->{data} : {};
	my $doc  = $data->{documentProps};

	# e.g. an audiobook chapter, whose page redirects to its book
	return _lookup( $state, "no episode document at $path" ) unless ref $doc eq 'HASH';

	my $docId = _digits( $doc->{id} );
	return _lookup( $state, "the document at $path is $docId" ) if defined $docId && $docId ne $id;

	my $docType = _text( $doc->{docType} );
	if ( !defined $docType || !$AUDIO_TYPE{$docType} ) {
		main::INFOLOG && $log->is_info && $log->info( "Episode $id not found: $path is not audio (docType " . ( defined $docType ? $docType : 'none' ) . ')' );
		return _answer( $state, { error => NOT_FOUND } );
	}

	_found( $state, _parseDocument($doc) );
	return;
}

# One Algolia lookup per resolve; a second reason to look up means the episode isn't there.
sub _lookup {
	my ( $state, $why ) = @_;
	my $id = $state->{id};

	if ( $state->{lookedUp}++ ) {
		main::INFOLOG && $log->is_info && $log->info("Episode $id not found: $why");
		return _answer( $state, { error => NOT_FOUND } );
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Episode $id: $why; looking it up in ABC's search index");

	Plugins::ABCListen::API::algolia(
		{
			query                => '',
			filters              => join( ' OR ', map {qq{objectID:"coremedia://$_/$id"}} @AUDIO_TYPES ),
			hitsPerPage          => 1,
			attributesToRetrieve => [qw(objectID canonicalURL title programTitle programID duration dates mediaRenditions)],
		},
		sub { _hit( $state, shift ) },
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
		main::INFOLOG && $log->is_info && $log->info("Episode $id not found: no episode page and not in ABC's search index");
		return _answer( $state, { error => NOT_FOUND } );
	}

	my $episode = _parseHit( $hit, $type );

	# audiobook chapters: the index has their renditions (their page is the book's)
	return _found( $state, $episode ) if @{ $episode->{renditions} };

	return _fetch( $state, $episode->{path} ) if defined $episode->{path};

	main::INFOLOG && $log->is_info && $log->info("Episode $id not found: its search index entry has neither audio nor a page");
	return _answer( $state, { error => NOT_FOUND } );
}

# A parsed episode: cache it, then answer (unless answered already: late results are cached only).
sub _found {
	my ( $state, $episode ) = @_;
	my $now = _now();

	_remember( $state->{id}, $episode, $now );
	_answer( $state, _result( $state->{id}, _choose( $episode, $now ) ) );

	return;
}

# A request failed: the cached renditions, whatever their age, else the API's token.
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

	my $token = ref $error eq 'HASH' && defined $error->{error} && $error->{error} eq RATE_LIMITED ? RATE_LIMITED : LOAD_FAILED;

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
	$choice{failToken} = GEO if grep {m{/geo-001/}} $choice{url}, @candidates;

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
		renditions            => _renditions( $doc->{renditions}, 'MIMEType' ),
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
		date                  => _epoch( $dates->{publicationDate} ),
		duration              => _positive( $hit->{duration} ),
		renditions            => _renditions( $hit->{mediaRenditions}, 'contentType' ),
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

# [ { url, <$mimeKey>, bitrate } ] -> [ { url, mime, bitrate } ] (entries without a URL dropped).
sub _renditions {
	my ( $list, $mimeKey ) = @_;
	return [] unless ref $list eq 'ARRAY';

	return [
		map { { url => $_->{url}, mime => _mime( $_->{$mimeKey} ), bitrate => _bitrate( $_->{bitrate} ) } }
		grep { ref $_ eq 'HASH' && _isUrl( $_->{url} ) } @$list
	];
}

# ---------------------------------------------------------------------------
# Episode metadata cache
# ---------------------------------------------------------------------------

# Merge a fetched episode into the metadata cache. The renditions, their windows and seenAt (what
# the 6 h shortcut plays from) only when they say what plays: not for a restricted episode or one
# not released yet (the cache has no field for either), nor without renditions.
sub _remember {
	my ( $id, $episode, $now ) = @_;

	my %meta = map { ( $_ => $episode->{$_} ) } @META_KEYS;

	my $notYet = grep { defined $_ && $_ > $now } map { _epoch( $episode->{$_} ) } qw(availableFrom downloadAvailableFrom);

	if ( !$episode->{restricted} && !$notYet && @{ $episode->{renditions} } ) {
		$meta{renditions}          = $episode->{renditions};
		$meta{availableTo}         = _bound( $episode->{availableTo} );
		$meta{downloadAvailableTo} = _bound( $episode->{downloadAvailableTo} );
		$meta{seenAt}              = $now;
	}

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
