package Plugins::ABCListen::Search;

# Search hook (hook API: see Plugin.pm): the top-level "Search" item and the LMS global search
# provider ("ABC listen" in LMS's home search: Material's search box, the globalsearch CLI used by
# hardware players and apps). Owned by the discovery stream (D3).
#
# Top level: { name => PLUGIN_ABCLISTEN_SEARCH ("Search", also the input prompt), type => 'search',
#   url => \&_search, image => ICON, weight => Util::topWeight('search') }; menuWeights declares
#   it. No network I/O.
#
# _search($client, $cb, $args, $pt): the query is $args->{search} (typed into the Search item),
# else $pt->{search} (the global search link's passthrough).
#   - Normalised: UTF-8 bytes decoded, trimmed, whitespace collapsed, lower-cased, cut to 100
#     characters, so "Science  Show" and "science show" are one query and one cache entry.
#     Empty -> no request; one text item "No results for ''" (PLUGIN_ABCLISTEN_NO_RESULTS).
#   - Two API::algolia queries, started together, both with the DQ3 site segments (listen,
#     triplej, kidslisten, triplejunearthed, pacific) and opts ttl 3600: API.pm caches each result
#     by its canonical params, so a repeated normalised query costs no Algolia request (and still
#     works when the hourly budget is used up). Two queries because one combined query ranks
#     programs out of its top hits (#13 Notes):
#       programs  hitsPerPage 20  contentType:program
#       episodes  hitsPerPage 40  contentType:audioepisode OR audio OR audiosegment
#     The text only ever goes in 'query' (JSON-encoded), never into 'filters'.
#   - $cb is called exactly once, after both queries have answered (cached answers come back
#     synchronously), with { items => [...] }:
#       "Programs (N)" link with the programItem rows inline, when N > 0;
#       "Episodes (M)" link with the episodeItem rows inline, when M > 0 (after filtering);
#       one text item for a failed query: PLUGIN_ABCLISTEN_RATE_LIMITED if a query hit ABC's or
#         the plugin's Algolia limit, else PLUGIN_ABCLISTEN_LOAD_FAILED (one item if both fail);
#       both answered and nothing found: one text item "No results for '<query as typed>'".
#     Building the menu never dies: an exception gives the LOAD_FAILED text item.
#
# Hits, in relevance order, each id once; names from `title`, never `_highlightResult` (<em>):
#   program  objectID coremedia://program/<digits>, else skipped -> OnDemand->programItem
#            { title, path (canonicalURL; programItem skips a hit without a www.abc.net.au page),
#              id, image (defaultThumbnail 1x1), description (shortTeaserText, else description),
#              network (infoSource) }.
#   episode  objectID coremedia://<audioepisode|audio|audiosegment>/<digits>, else skipped. Hidden
#            when mediaDownloadStatus and mediaStreamingStatus are both EXPIRED or NONE (DQ4;
#            PENDING and missing statuses are kept: the MP3 of an AVAILABLE/EXPIRED hit is
#            permanent). -> OnDemand->episodeItem with the contract-3 meta { id, docType
#            (contentType), title, programTitle, programId, path, image (defaultThumbnail 1x1, else
#            programDefaultThumbnail 1x1), description (teaserText, else synopsis), date
#            (publicationDate), duration } and, when the hit has renditions, renditions
#            [ { url, mime, bitrate, fileSize (when the hit has one; O6 AAC seeking) } ],
#            availableTo / downloadAvailableTo (the streaming / download window ends as epochs;
#            ABC's "permanent" 2200-01-01 or a missing end is stored as Episode.pm's open end,
#            OPEN_END, so a seed reopens windows O1 closed before the release) and seenAt.
#            episodeItem stores them in the episode meta cache, so O1 plays a result without
#            fetching the episode page (Episode.pm's 6 h shortcut). Like O1's own writer, a hit
#            whose window opens later is listed but not seeded (the cache has no "from" field),
#            and nothing of that set is written without renditions (seenAt would vouch for older
#            renditions). Missing values are left out (they never clobber the cache).
#
# Global search: init registers Slim::Menu::GlobalSearch provider 'abclisten', when this LMS has
# registerInfoProvider (else DEBUG log; the plugin still loads). For a non-empty $tags->{search}
# the provider returns { name => PLUGIN_ABCLISTEN_GLOBAL_SEARCH_TITLE ("ABC listen"), type => 'link',
# items => [ { name => PLUGIN_ABCLISTEN_SEARCH_RESULTS ("Results for '<query>'"), type => 'link',
# url => \&_search, passthrough => [ { search => $tags->{search} } ] } ] }, else undef. No url on
# the top-level item: LMS 9.1.1 numbers a global search session only when no top-level item has a
# code ref url, and its globalsearch item ids don't resolve without one. The provider makes no
# request: the search runs only when the link is opened (library-only global searches cost no
# Algolia budget), through the same _search and API.pm cache as the Search item.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::ABCListen::API;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

use constant MAX_QUERY    => 100;     # characters
use constant PROGRAM_HITS => 20;      # DQ6: no paging
use constant EPISODE_HITS => 40;
use constant RESULT_TTL   => 3600;    # seconds (API.pm result cache)
use constant OPEN_END     => 4_102_444_800;    # an open window end in the episode meta cache (= Episode.pm's)

use constant LOAD_FAILED  => 'PLUGIN_ABCLISTEN_LOAD_FAILED';
use constant RATE_LIMITED => 'PLUGIN_ABCLISTEN_RATE_LIMITED';

use constant SITE_SEGMENTS => '(siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)';

my @ATTRIBUTES = qw(objectID title canonicalURL contentType defaultThumbnail programDefaultThumbnail infoSource
	shortTeaserText description teaserText synopsis programTitle programID duration dates mediaRenditions
	mediaDownloadStatus mediaStreamingStatus);

# The two queries, in result-menu order.
my @GROUPS = (
	{
		key     => 'programs',
		hits    => PROGRAM_HITS,
		filters => 'contentType:program AND ' . SITE_SEGMENTS,
		token   => 'PLUGIN_ABCLISTEN_SEARCH_PROGRAMS',
		rows    => \&_programRows,
	},
	{
		key     => 'episodes',
		hits    => EPISODE_HITS,
		filters => '(contentType:audioepisode OR contentType:audio OR contentType:audiosegment) AND ' . SITE_SEGMENTS,
		token   => 'PLUGIN_ABCLISTEN_SEARCH_EPISODES',
		rows    => \&_episodeRows,
	},
);

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);
my %GONE       = map { $_ => 1 } qw(EXPIRED NONE);

my $log = logger('plugin.abclisten');

sub init {
	eval {
		if ( Slim::Menu::GlobalSearch->can('registerInfoProvider') ) {
			Slim::Menu::GlobalSearch->registerInfoProvider( abclisten => ( func => \&_globalSearchItem ) );
		}
		else {
			main::DEBUGLOG && $log->is_debug && $log->debug('LMS global search is not available: no ABC listen results there');
		}
		1;
	} or $log->error( 'Could not register the ABC listen global search provider: ' . ( $@ || 'unknown error' ) );

	return;
}

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

sub menuWeights { Plugins::ABCListen::Util::topWeight('search') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_SEARCH' ),
		type   => 'search',
		url    => \&_search,
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight('search'),
	} ] );
}

# ---------------------------------------------------------------------------
# Global search provider
# ---------------------------------------------------------------------------

sub _globalSearchItem {
	my ( $client, $tags ) = @_;

	my $search = ref $tags eq 'HASH' ? $tags->{search} : undef;
	return undef unless length _normalise($search);

	# The search link sits inside "ABC listen": Slim::Control::XMLBrowser only numbers a global
	# search session ("<sid>_<query>.N" item ids) when no top-level item has a code ref url, and
	# without that id a later "globalsearch items item_id:..." (Jive, hardware players, apps)
	# can't find the item.
	return {
		name  => cstring( $client, 'PLUGIN_ABCLISTEN_GLOBAL_SEARCH_TITLE' ),
		type  => 'link',
		items => [ {
			name        => cstring( $client, 'PLUGIN_ABCLISTEN_SEARCH_RESULTS', _tidy($search) ),
			type        => 'link',
			url         => \&_search,
			passthrough => [ { search => $search } ],
		} ],
	};
}

# ---------------------------------------------------------------------------
# Search feed
# ---------------------------------------------------------------------------

sub _search {
	my ( $client, $cb, $args, $pt ) = @_;
	my $once = _once($cb);

	my $raw = ref $args eq 'HASH' && length _normalise( $args->{search} ) ? $args->{search} : ref $pt eq 'HASH' ? $pt->{search} : undef;

	my $query = _normalise($raw);
	my $typed = _tidy($raw);

	return _respond( $client, $once, sub { [ _noResults( $client, $typed ) ] } ) unless length $query;

	my %results;
	my $pending = scalar @GROUPS;

	for my $group (@GROUPS) {
		_query( $group, $query, sub {
			$results{ $group->{key} } = shift;
			return if --$pending;
			_respond( $client, $once, sub { _resultItems( $client, \%results, $typed ) } );
		} );
	}

	return;
}

# One Algolia query; $done->({ data }) or $done->({ error }) once, whatever happens.
sub _query {
	my ( $group, $query, $done ) = @_;
	my $settled = 0;
	my $settle  = sub { $done->(@_) unless $settled++ };

	eval {
		Plugins::ABCListen::API::algolia(
			{
				query                => $query,
				hitsPerPage          => $group->{hits},
				filters              => $group->{filters},
				attributesToRetrieve => [@ATTRIBUTES],
			},
			sub { $settle->( { data  => $_[0] } ) },
			sub { $settle->( { error => $_[0] } ) },
			{ ttl => RESULT_TTL },
		);
		1;
	} or do {
		my $error = $@ || 'unknown error';
		$log->error("ABC listen search ($group->{key}) failed: $error");
		$settle->( { error => { error => LOAD_FAILED, message => $error } } );
	};

	return;
}

sub _resultItems {
	my ( $client, $results, $typed ) = @_;
	my ( @items, @failed );

	for my $group (@GROUPS) {
		my $result = $results->{ $group->{key} } || {};
		my $data   = $result->{data};

		if ( $result->{error} ) {
			push @failed, $result->{error};
			next;
		}

		if ( ref $data ne 'HASH' || ref $data->{hits} ne 'ARRAY' ) {
			$log->warn("ABC listen search ($group->{key}): the response has no hits list");
			push @failed, { error => LOAD_FAILED };
			next;
		}

		my $rows = $group->{rows}->( $client, grep { ref $_ eq 'HASH' } @{ $data->{hits} } );
		next unless @$rows;

		push @items, {
			name  => cstring( $client, $group->{token}, scalar @$rows ),
			type  => 'link',
			items => $rows,
		};
	}

	if (@failed) {
		my $limited = grep { ref $_ eq 'HASH' && ( $_->{error} || '' ) eq RATE_LIMITED } @failed;
		push @items, _textItem( $client, $limited ? RATE_LIMITED : LOAD_FAILED );
	}
	elsif ( !@items ) {
		push @items, _noResults( $client, $typed );
	}

	return \@items;
}

sub _programRows {
	my ( $client, @hits ) = @_;
	my ( @rows, %seen );

	for my $hit (@hits) {
		my ( $type, $id ) = Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} );
		next unless $type && $type eq 'program' && !$seen{$id};

		my $item = Plugins::ABCListen::OnDemand->programItem( $client, _defined(
			title       => _text( $hit->{title} ),
			path        => Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} ),
			id          => $id,
			image       => _thumbnail( $hit->{defaultThumbnail} ),
			description => _first( _text( $hit->{shortTeaserText} ), _text( $hit->{description} ) ),
			network     => _text( $hit->{infoSource} ),
		) ) or next;

		$seen{$id} = 1;
		push @rows, $item;
	}

	return \@rows;
}

sub _episodeRows {
	my ( $client, @hits ) = @_;
	my ( @rows, %seen );
	my $now = time();

	for my $hit (@hits) {
		my ( $type, $id ) = Plugins::ABCListen::API::coreMediaRef( $hit->{objectID} );
		next unless $type && $AUDIO_TYPE{$type} && !$seen{$id};
		next if _gone( $hit->{mediaDownloadStatus} ) && _gone( $hit->{mediaStreamingStatus} );

		my $item = Plugins::ABCListen::OnDemand->episodeItem( $client, _episodeMeta( $hit, $type, $id, $now ) ) or next;

		$seen{$id} = 1;
		push @rows, $item;
	}

	return \@rows;
}

# An episode hit -> the contract-3 meta (see the header).
sub _episodeMeta {
	my ( $hit, $type, $id, $now ) = @_;

	my $dates = ref $hit->{dates} eq 'HASH' ? $hit->{dates} : {};

	my %meta = (
		id           => $id,
		docType      => _first( _text( $hit->{contentType} ), $type ),
		title        => _text( $hit->{title} ),
		programTitle => _text( $hit->{programTitle} ),
		programId    => _digits( $hit->{programID} ),
		path         => Plugins::ABCListen::API::sitePath( $hit->{canonicalURL} ),
		image        => _first( _thumbnail( $hit->{defaultThumbnail} ), _thumbnail( $hit->{programDefaultThumbnail} ) ),
		description  => _first( _text( $hit->{teaserText} ), _text( $hit->{synopsis} ) ),
		date         => Plugins::ABCListen::Util::parseISO8601( $dates->{publicationDate} ),
		duration     => _positive( $hit->{duration} ),
	);

	my $renditions = _renditions( $hit->{mediaRenditions} );
	my $notYet = grep { defined $_ && $_ > $now }
		map { Plugins::ABCListen::Util::parseISO8601( $dates->{$_} ) } qw(mediaDownloadAvailableFrom mediaStreamingAvailableFrom);

	if ( @$renditions && !$notYet ) {
		$meta{renditions}          = $renditions;
		$meta{availableTo}         = _windowEnd( $dates->{mediaStreamingAvailableTo} );
		$meta{downloadAvailableTo} = _windowEnd( $dates->{mediaDownloadAvailableTo} );
		$meta{seenAt}              = $now;
	}

	return _defined(%meta);
}

# A window end as the episode meta cache stores it (like Episode.pm): the epoch, else (ABC's
# "permanent" 2200-01-01 is beyond parseISO8601, or the end is missing: an open window) OPEN_END.
# Never undef: the cache merge would keep an end O1 closed before the episode was released.
sub _windowEnd {
	my $epoch = Plugins::ABCListen::Util::parseISO8601(shift);
	return defined $epoch ? $epoch : OPEN_END;
}

# mediaRenditions -> [ { url, mime, bitrate, fileSize? } ] (entries without an http(s) URL dropped).
sub _renditions {
	my $list = shift;
	return [] unless ref $list eq 'ARRAY';

	my @renditions;
	for my $r ( grep { ref $_ eq 'HASH' && _isUrl( $_->{url} ) } @$list ) {
		my %rendition = ( url => $r->{url}, mime => _text( $r->{contentType} ), bitrate => _positive( $r->{bitrate} ) );

		my $fileSize = _positive( $r->{fileSize} );
		$rendition{fileSize} = $fileSize if defined $fileSize;

		push @renditions, \%rendition;
	}

	return \@renditions;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The search text as characters: UTF-8 bytes (e.g. from a web request) are decoded first.
sub _chars {
	my $text = shift;
	return '' unless defined $text && !ref $text;

	utf8::decode($text) unless utf8::is_utf8($text);
	return $text;
}

# Trimmed, whitespace collapsed (no-break spaces too); case kept. For display.
sub _tidy {
	my $text = _chars(shift);

	$text =~ s/[\s\x{A0}]+/ /g;
	$text =~ s/\A | \z//g;

	return $text;
}

# The query sent and cached: tidied, lower-cased, at most MAX_QUERY characters.
sub _normalise {
	my $text = lc _tidy(shift);

	$text = substr( $text, 0, MAX_QUERY );
	$text =~ s/ \z//;

	return $text;
}

sub _gone {
	my $status = shift;
	return defined $status && !ref $status && $GONE{ uc $status } ? 1 : 0;
}

# defaultThumbnail / programDefaultThumbnail: a hash of ratios (the 1x1 crop) or a plain URL.
sub _thumbnail {
	my $thumbnail = shift;
	my $url = ref $thumbnail eq 'HASH' ? $thumbnail->{'1x1'} : $thumbnail;
	return _isUrl($url) ? $url : undef;
}

# Entity-decoded, trimmed text, or undef if empty.
sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::ABCListen::Util::decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;

	return length $text ? $text : undef;
}

sub _first { for (@_) { return $_ if defined } return undef }

sub _defined {
	my %hash = @_;
	return { map { $_ => $hash{$_} } grep { defined $hash{$_} } keys %hash };
}

sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }

sub _positive {
	my $value = shift;
	return defined $value && !ref $value && $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $value > 0 ? $value + 0 : undef;
}

sub _isUrl { defined $_[0] && !ref $_[0] && $_[0] =~ m{\Ahttps?://\S+\z}i }

# A callback wrapper that passes on only the first call.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub { $cb->(@_) unless $called++ };
}

# Call back once with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen search results failed: ' . ( $@ || 'unknown error' ) );
		$items = [ _textItem( $client, LOAD_FAILED ) ];
	}

	$cb->( { items => $items } );
	return;
}

sub _noResults {
	my ( $client, $typed ) = @_;
	return { name => cstring( $client, 'PLUGIN_ABCLISTEN_NO_RESULTS', $typed ), type => 'text' };
}

sub _textItem {
	my ( $client, $token ) = @_;
	return { name => cstring( $client, $token ), type => 'text' };
}

1;
