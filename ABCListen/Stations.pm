package Plugins::ABCListen::Stations;

# The ABC listen live station catalogue: data and stream resolution, no menu code (ai-state/streams.md
# contract 7). The static records live in Plugins::ABCListen::StationData (fields described there);
# this module adds runtime enrichment, event status and stream candidates.
#
#   Stations->get($id)               the record (a copy, enrichment applied) or undef
#   Stations->list($group[, $state]) records of a group, in display order (copies). Dedupe
#                                    duplicates (dupOf) are left out.
#                                      network, sport  the BFF national-collection order once
#                                                      enrichment is cached, else catalogue order
#                                      local           capital-city station first, then A-Z by name
#                                      variant         by network (network order), then city A-Z
#   Stations->byPageSlug($slugOrUrl) service id or undef. Accepts a live-page slug ('sydney',
#                                    'katherine'), a site path or an absolute URL on (www.)abc.net.au:
#                                    /listen/live/<slug>, /triplej/live/<slug>, /listen/doublej/live,
#                                    /pacific/live, network homes (/listen/radionational, /triplej,
#                                    /triplejhottest, /listen/doublej, /listen/classic, /listen/classic2,
#                                    /listen/jazz, /listen/country, /kidslisten, /listen/news), and
#                                    https://www.triplejunearthed.com/. Query, fragment and trailing
#                                    '/' are ignored.
#   Stations->playable($id)          1 if the station can be listed and played: known; not HLS-only
#                                    unless it has a mediahub stream; event-only services only while
#                                    the cached event status says on air (unknown = 0). L5 extends it.
#   Stations->streamCandidates($id, $cb)
#                                    calls $cb exactly once with \@urls (ordered, direct audio streams,
#                                    never .pls/.m3u8/.f4m) or { error => TOKEN }:
#                                      1. StreamGuys Icecast for the mount, from File1= of
#                                         https://streaming.abc-cdn.net.au/audio/ice/<hlsSlug>.pls
#                                         (cached 24 h); any .pls problem -> the static mount URL
#                                      2. the page's mediahub AAC stream, normalised, as an alternate
#                                    HLS-only with mediahub -> mediahub only; HLS-only without ->
#                                    PLUGIN_ABCLISTEN_LIVE_HLS_ONLY; event-only off air ->
#                                    PLUGIN_ABCLISTEN_LIVE_OFF_AIR (on air: its epg aac sources, a .pls
#                                    resolved to Icecast first); unknown id -> PLUGIN_ABCLISTEN_UNAVAILABLE.
#   Stations->eventStatus($id, $cb)  $cb->({ onAir => 0|1, sources => [aac urls] }) exactly once. One
#                                    epgNowPlaying/<ID>/now request per service per 5 min (errors,
#                                    `null`, {} and HLS-only sources count as off air and are cached
#                                    too), at most EVENT_CONCURRENCY (6) requests at a time.
#   Stations->checkOnAir(\@ids, $cb) eventStatus for each id; $cb->() once all are known.
#   Stations->enrich()               starts the lazy BFF enrichment (national + 8 state collections,
#                                    cached 24 h, stale_ok): cached collections apply at once, others
#                                    when they arrive. For known ids: logo (when it has crop params),
#                                    order (networks, sport) and, for sport services (renamed per
#                                    event), the name. Unknown cards are logged once at INFO and
#                                    ignored. At most one request per collection per 24 h.
#   normaliseMediahub($url)          'http:live-radio01.mediahubaustralia.com/2RNW/aac/;*.mp3?source=web'
#                                    -> 'https://live-radio01.mediahubaustralia.com/2RNW/aac/'; undef
#                                    for anything not an AAC stream on *.mediahubaustralia.com.
#   parsePls($body)                  File1 when it is https://abc.streamguys1.com/live/..., else undef.
#
# Owned by the live stream (L1; L5 extends playable/streamCandidates).

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::StationData;
use Plugins::ABCListen::Util;

use constant PLS_URL     => 'https://streaming.abc-cdn.net.au/audio/ice/%s.pls';
use constant ICECAST_URL => 'https://abc.streamguys1.com/live/%s/icecast.audio';

use constant PLS_TTL           => 86400;    # resolved .pls (or its fallback), seconds
use constant PLS_TIMEOUT       => 8;
use constant EVENT_TTL         => 300;      # event on-air status, seconds
use constant EVENT_TIMEOUT     => 8;
use constant EVENT_CONCURRENCY => 6;
use constant ENRICH_TTL        => 86400;

use constant HLS_ONLY    => 'PLUGIN_ABCLISTEN_LIVE_HLS_ONLY';
use constant OFF_AIR     => 'PLUGIN_ABCLISTEN_LIVE_OFF_AIR';
use constant LIVE_FAILED => 'PLUGIN_ABCLISTEN_LIVE_FAILED';
use constant UNAVAILABLE => 'PLUGIN_ABCLISTEN_UNAVAILABLE';

# BFF collections: the national networks and the 8 states (rootMetaCollectionId 14123276)
my @COLLECTIONS = (
	{ id => '12872264', root => '14139428', national => 1 },
	map { { id => $_->[1], root => '14123276', state => $_->[0] } } (
		[ NSW => '14126370' ], [ ACT => '14126436' ], [ NT  => '14128062' ], [ VIC => '14128070' ],
		[ SA  => '14128508' ], [ TAS => '14128536' ], [ QLD => '14128542' ], [ WA  => '14128996' ],
	),
);

# network homes -> id (D1/D4 channel and externallink cards)
my %HOME_SLUGS = (
	radionational  => 'RN',
	news           => 'NEWS',
	triplej        => 'TRIPLEJ',
	triplejhottest => 'H100',
	doublej        => 'DOUBLEJ',
	classic        => 'CLASSIC',
	classic2       => 'CLASSIC2',
	jazz           => 'JAZZ',
	country        => 'COUNTRY',
	kidslisten     => 'KIDSLISTEN',
	pacific        => 'RA_ML',
);

# live-page slugs of other services' streams (listed once, under their own id)
my %ALIAS_SLUGS = ( katherine => 'LOCAL_DARWIN' );

my $log = logger('plugin.abclisten');

my ( @RECORDS, %BY_ID, %LIVE_SLUGS );
_setRecords();

my %ENRICHED;        # id => { name?, logo? }
my %ORDER;           # group => [ ids in BFF card order ]
my %ENRICH_STATE;    # collection id => { at, inFlight }
my %UNKNOWN_LOGGED;  # card link => 1

my %EVENT;           # id => { at, onAir, sources }
my %EVENT_WAITERS;   # id => [ callbacks ]
my @EVENT_QUEUE;
my $eventsRunning = 0;

# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

sub get {
	my ( $class, $id ) = @_;
	return undef unless defined $id && !ref $id && $BY_ID{$id};
	return _view( $BY_ID{$id} );
}

# A copy of the record with its enrichment applied. Variants (and hidden Kids listen versions) have no
# card of their own and follow their parent network's logo.
sub _view {
	my $rec  = shift;
	my %view = ( %$rec, %{ $ENRICHED{ $rec->{id} } || {} } );

	if ( ( $rec->{group} eq 'variant' || $rec->{group} eq 'hidden' ) && !$ENRICHED{ $rec->{id} } ) {
		my $parent = $ENRICHED{ $rec->{network} };
		$view{logo} = $parent->{logo} if $parent && $parent->{logo};
	}

	return \%view;
}

sub list {
	my ( $class, $group, $state ) = @_;
	return () unless defined $group;

	my @recs = map { _view($_) } grep { $_->{group} eq $group && !$_->{dupOf} } @RECORDS;
	@recs = grep { ( $_->{state} || '' ) eq $state } @recs if defined $state;

	if ( $group eq 'local' ) {
		return sort { ( $a->{state} cmp $b->{state} ) || ( ( $b->{capital} || 0 ) <=> ( $a->{capital} || 0 ) ) || _byName() } @recs;
	}

	if ( $group eq 'variant' ) {
		my %rank = _rank( map { $_->{id} } $class->list('network') );
		return sort {
			( ( $rank{ $a->{network} } // 1e9 ) <=> ( $rank{ $b->{network} } // 1e9 ) ) || ( lc( $a->{city} // '' ) cmp lc( $b->{city} // '' ) )
		} @recs;
	}

	if ( my $order = $ORDER{$group} ) {
		my %rank = _rank(@$order);
		my %catalogue = _rank( map { $_->{id} } @recs );
		return sort {
			( ( $rank{ $a->{id} } // 1e9 ) <=> ( $rank{ $b->{id} } // 1e9 ) ) || ( $catalogue{ $a->{id} } <=> $catalogue{ $b->{id} } )
		} @recs;
	}

	return @recs;
}

sub _byName { lc $a->{name} cmp lc $b->{name} || $a->{name} cmp $b->{name} }

sub _rank {
	my $i = 0;
	return map { $_ => $i++ } @_;
}

sub playable {
	my ( $class, $id ) = @_;
	my $rec = defined $id && !ref $id && $BY_ID{$id} or return 0;

	if ( $rec->{eventOnly} ) {
		my $status = _eventCached($id);
		return $status && $status->{onAir} ? 1 : 0;
	}

	return 0 if ( $rec->{hlsOnly} || !$rec->{mount} ) && !normaliseMediahub( $rec->{mediahub} );
	return 1;
}

# ---------------------------------------------------------------------------
# Page slugs
# ---------------------------------------------------------------------------

sub byPageSlug {
	my ( $class, $slugOrUrl ) = @_;
	my ($id) = _slugLookup($slugOrUrl);
	return $id;
}

# -> ($id, $isAlias), or () when unknown.
sub _slugLookup {
	my $in = shift;
	return () unless defined $in && !ref $in;

	( my $s = $in ) =~ s/\A\s+|\s+\z//g;
	return () unless length $s;

	if ( $s =~ /\A[A-Za-z0-9-]+\z/ ) {
		my $slug = lc $s;
		return ( $LIVE_SLUGS{$slug} ) if $LIVE_SLUGS{$slug};
		return ( $ALIAS_SLUGS{$slug}, 1 ) if $ALIAS_SLUGS{$slug};
		return ( $HOME_SLUGS{$slug} ) if $HOME_SLUGS{$slug};
		return ();
	}

	my $path;
	if ( $s =~ m{\A(?:https?:)?//([^/?#]+)(.*)\z}is ) {
		my $host = lc $1;
		$path = $2;
		$host =~ s/:\d+\z//;
		$host =~ s/\Awww\.//;

		if ( $host eq 'triplejunearthed.com' ) {
			( my $p = $path ) =~ s/[?#].*//s;
			return $p =~ m{\A/*\z} ? ('UNEARTHED') : ();
		}

		return () unless $host eq 'abc.net.au';
	}
	elsif ( $s =~ m{\A/} ) {
		$path = $s;
	}
	else {
		return ();
	}

	$path =~ s/[?#].*//s;
	my @seg = grep { length } split m{/}, lc $path;

	my ( $live, $home );
	if    ( @seg == 3 && $seg[1] eq 'live' )                       { $live = $seg[2] }    # /listen/live/x, /triplej/live/x
	elsif ( @seg == 3 && $seg[0] eq 'listen' && $seg[2] eq 'live' ) { $home = $seg[1] }    # /listen/doublej/live
	elsif ( @seg == 2 && $seg[1] eq 'live' )                       { $home = $seg[0] }    # /pacific/live
	elsif ( @seg == 2 && $seg[0] eq 'listen' )                     { $home = $seg[1] }    # /listen/radionational
	elsif ( @seg == 1 )                                            { $home = $seg[0] }    # /triplej, /kidslisten

	if ( defined $live ) {
		return ( $LIVE_SLUGS{$live} ) if $LIVE_SLUGS{$live};
		return ( $ALIAS_SLUGS{$live}, 1 ) if $ALIAS_SLUGS{$live};
		return ();
	}

	return defined $home && $HOME_SLUGS{$home} ? ( $HOME_SLUGS{$home} ) : ();
}

# ---------------------------------------------------------------------------
# Stream candidates
# ---------------------------------------------------------------------------

sub streamCandidates {
	my ( $class, $id, $cb ) = @_;

	my $answer = _once($cb);
	my $rec = defined $id && !ref $id && $BY_ID{$id} or return $answer->( { error => UNAVAILABLE } );

	if ( $rec->{eventOnly} ) {
		return $class->eventStatus( $id, sub {
			my $status = shift;
			return $answer->( { error => OFF_AIR } ) unless $status && $status->{onAir};
			_eventCandidates( $id, $status->{sources}, $answer );
		} );
	}

	my $mediahub = normaliseMediahub( $rec->{mediahub} );

	if ( $rec->{hlsOnly} || !$rec->{mount} ) {
		return $answer->( $mediahub ? [$mediahub] : { error => HLS_ONLY } );
	}

	_icecast(
		sprintf( PLS_URL, $rec->{hlsSlug} || $rec->{mount} ),
		sprintf( ICECAST_URL, $rec->{mount} ),
		sub { $answer->( [ grep { defined } $_[0], $mediahub ] ) },
	);

	return;
}

# An on-air event service's candidates from its epg aac sources: the first .pls resolved to Icecast,
# then the mediahub streams.
sub _eventCandidates {
	my ( $id, $sources, $answer ) = @_;

	my ( @pls, @mediahub );
	for my $source ( @{ $sources || [] } ) {
		if    ( my $mh = normaliseMediahub($source) ) { push @mediahub, $mh }
		elsif ( _isPlsUrl($source) )                  { push @pls, $source }
	}

	my $done = sub {
		my @candidates = grep { defined } @_, @mediahub;
		$answer->( @candidates ? \@candidates : { error => LIVE_FAILED } );
	};

	return $done->() unless @pls;

	( my $plsUrl = $pls[0] ) =~ s/\?.*//s;
	_icecast( $plsUrl, undef, $done );
	return;
}

# The Icecast URL from a .pls: File1 when valid, else $static (which may be undef). The outcome is
# cached for PLS_TTL, so a station's .pls is fetched at most once a day.
sub _icecast {
	my ( $plsUrl, $static, $cb ) = @_;

	my $key   = "live-pls:$plsUrl";
	my $cache = Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE );

	my $cached = eval { $cache->get($key) };
	return $cb->($cached) if defined $cached && !ref $cached && length $cached;

	my $done = sub {
		my ( $url, $why ) = @_;

		if ( !defined $url ) {
			main::INFOLOG && $log->is_info && $log->info( "$plsUrl: $why; " . ( defined $static ? "using $static" : 'no static stream' ) );
			$url = $static;
		}

		eval { $cache->set( $key, $url, PLS_TTL ) } if defined $url;
		$cb->($url);
	};

	Plugins::ABCListen::API::text(
		$plsUrl,
		sub {
			my $file1 = parsePls( $_[0] );
			$done->( $file1, defined $file1 ? undef : 'no usable File1 entry' );
		},
		sub { $done->( undef, 'request failed: ' . ( ( $_[0] && $_[0]->{message} ) || 'unknown error' ) ) },
		{ quiet => 1, timeout => PLS_TIMEOUT },
	);

	return;
}

sub parsePls {
	my $body = shift;
	return undef unless defined $body && !ref $body;

	my ($file1) = $body =~ /^[ \t]*File1[ \t]*=[ \t]*(\S+)[ \t]*\r?$/mi;
	return undef unless defined $file1;
	return undef unless $file1 =~ m{\Ahttps://abc\.streamguys1\.com/live/[^\s?#]+\z};
	return undef if _isPlaylistUrl($file1);

	return $file1;
}

sub normaliseMediahub {
	my $url = shift;
	return undef unless defined $url && !ref $url;

	( my $s = $url ) =~ s/\A\s+|\s+\z//g;
	my ( $host, $code ) = $s =~ m{\Ahttps?:/*([A-Za-z0-9-]+\.mediahubaustralia\.com)/([A-Za-z0-9_-]+)/aac/?(?:;[^?#]*)?(?:[?#].*)?\z}is
		or return undef;

	return 'https://' . lc($host) . "/$code/aac/";
}

sub _isPlsUrl {
	my $url = shift;
	return defined $url && !ref $url && $url =~ m{\Ahttps?://(?:[A-Za-z0-9-]+\.)*abc(?:-cdn)?\.net\.au/\S*\.pls(?:\?\S*)?\z}i ? 1 : 0;
}

sub _isPlaylistUrl { $_[0] =~ /\.(?:m3u8|f4m|pls|m3u)(?:[?#]|\z)/i }

# ---------------------------------------------------------------------------
# Event-only services
# ---------------------------------------------------------------------------

sub _eventCached {
	my $id = shift;
	my $status = $EVENT{$id} or return undef;
	return time() - $status->{at} < EVENT_TTL && time() >= $status->{at} ? $status : undef;
}

sub eventStatus {
	my ( $class, $id, $cb ) = @_;
	$cb = _once($cb);

	my $rec = defined $id && !ref $id && $BY_ID{$id};
	return $cb->( { onAir => 0, sources => [] } ) unless $rec && $rec->{eventOnly};

	if ( my $status = _eventCached($id) ) {
		return $cb->( _statusCopy($status) );
	}

	my $waiting = $EVENT_WAITERS{$id};
	push @{ $EVENT_WAITERS{$id} }, $cb;
	return if $waiting;

	push @EVENT_QUEUE, $id;
	_pumpEvents();

	return;
}

sub checkOnAir {
	my ( $class, $ids, $cb ) = @_;
	$cb = _once($cb);

	my @ids = grep { defined } @{ $ids || [] };
	return $cb->() unless @ids;

	my $left = @ids;
	$class->eventStatus( $_, sub { $cb->() unless --$left } ) for @ids;

	return;
}

sub _pumpEvents {
	while ( $eventsRunning < EVENT_CONCURRENCY && @EVENT_QUEUE ) {
		my $id = shift @EVENT_QUEUE;
		$eventsRunning++;

		my $done = _once( sub {
			my $status = shift;
			$eventsRunning--;

			$EVENT{$id} = { %$status, at => time() };
			main::INFOLOG && $log->is_info && $log->info( "Event service $id is " . ( $status->{onAir} ? 'on air' : 'off air' ) );

			for my $waiter ( @{ delete $EVENT_WAITERS{$id} || [] } ) {
				eval { $waiter->( _statusCopy( $EVENT{$id} ) ); 1 } or $log->error( "Event status callback for $id died: " . ( $@ || 'unknown error' ) );
			}

			_pumpEvents();
		} );

		eval {
			Plugins::ABCListen::API::bff(
				"epgNowPlaying/$id/now",
				{ imageRatio => '1x1' },
				sub { $done->( _parseEventStatus( $_[0] ) ) },
				sub { $done->( { onAir => 0, sources => [] } ) },    # error, 429, `null`: off air (cached EVENT_TTL)
				{ quiet => 1, ttl => EVENT_TTL, timeout => EVENT_TIMEOUT },
			);
			1;
		} or do {
			$log->error( "Event status request for $id failed: " . ( $@ || 'unknown error' ) );
			$done->( { onAir => 0, sources => [] } );
		};
	}

	return;
}

# epgNowPlaying JSON -> { onAir, sources }: on air when an aac source is a .pls or a mediahub stream.
sub _parseEventStatus {
	my $data = shift;

	my @sources;
	if ( ref $data eq 'HASH' && ref $data->{sources} eq 'ARRAY' ) {
		for my $source ( @{ $data->{sources} } ) {
			next unless ref $source eq 'HASH' && lc( $source->{type} // '' ) eq 'aac';
			my $file = $source->{file};
			push @sources, $file if normaliseMediahub($file) || _isPlsUrl($file);
		}
	}

	return { onAir => @sources ? 1 : 0, sources => \@sources };
}

sub _statusCopy {
	my $status = shift;
	return { onAir => $status->{onAir}, sources => [ @{ $status->{sources} || [] } ] };
}

# ---------------------------------------------------------------------------
# Runtime enrichment (BFF collections)
# ---------------------------------------------------------------------------

sub enrich {
	my $class = shift;

	for my $collection (@COLLECTIONS) {
		my $state = $ENRICH_STATE{ $collection->{id} } ||= {};
		next if $state->{inFlight};
		next if defined $state->{at} && time() - $state->{at} < ENRICH_TTL && time() >= $state->{at};

		$state->{inFlight} = 1;

		my $done = sub {
			$state->{inFlight} = 0;
			$state->{at}       = time();
		};

		eval {
			Plugins::ABCListen::API::bff(
				'collection/listen/radio',
				{ collectionId => $collection->{id}, rootMetaCollectionId => $collection->{root}, metaInMeta => 'false' },
				sub {
					$done->();
					eval { _applyCollection( $collection, $_[0] ); 1 } or $log->error( "Could not apply BFF collection $collection->{id}: " . ( $@ || 'unknown error' ) );
				},
				sub {
					$done->();
					main::INFOLOG && $log->is_info && $log->info( "BFF collection $collection->{id} unavailable, using the catalogue: " . ( ( $_[0] && $_[0]->{message} ) || 'unknown error' ) );
				},
				{ ttl => ENRICH_TTL, stale_ok => 1, quiet => 1 },
			);
			1;
		} or do {
			$done->();
			$log->error( "BFF collection $collection->{id} request failed: " . ( $@ || 'unknown error' ) );
		};
	}

	return;
}

sub _applyCollection {
	my ( $collection, $data ) = @_;

	my $items = ref $data eq 'HASH' && ref $data->{collection} eq 'HASH' ? $data->{collection}->{items} : undef;
	if ( ref $items ne 'ARRAY' ) {
		main::INFOLOG && $log->is_info && $log->info("BFF collection $collection->{id} has no card list; using the catalogue");
		return;
	}

	my ( @order, %own, %seen );
	my @cards = grep { ref $_ eq 'HASH' } @$items;

	# ids that have their own card win over a duplicate's card
	for my $card (@cards) {
		my ( $id, $alias ) = _slugLookup( $card->{articleLink} );
		$own{$id} = 1 if $id && !$alias;
	}

	for my $card (@cards) {
		my $link = $card->{articleLink};
		my ( $id, $alias ) = _slugLookup($link);

		if ( !$id ) {
			my $what = defined $link && !ref $link ? $link : '(no link)';
			main::INFOLOG && $log->is_info && $log->info("BFF card '$what' ($collection->{id}) is not a known station; ignored") unless $UNKNOWN_LOGGED{$what}++;
			next;
		}
		next if $alias;

		my $rec = $BY_ID{$id};
		my @targets = ($id);
		push @targets, $rec->{dupOf} if $rec->{dupOf} && !$own{ $rec->{dupOf} };

		my %fields;
		my $image = ref $card->{cardImagePrepared} eq 'HASH' ? $card->{cardImagePrepared}->{imgSrc} : undef;
		$fields{logo} = $image if defined $image && !ref $image && $image =~ /[?&]cropW=\d/ && $image =~ /[?&]cropH=\d/;

		my $title = $card->{cardTitle};
		if ( $rec->{group} eq 'sport' && defined $title && !ref $title ) {
			$title = Plugins::ABCListen::Util::decodeEntities($title);
			$title =~ s/\A\s+|\s+\z//g;
			$title =~ s/\s+/ /g;
			$fields{name} = $title if length $title;
		}

		for my $target (@targets) {
			next if $seen{$target}++;
			$ENRICHED{$target} = {%fields};
			push @order, $target;
		}
	}

	if ( $collection->{national} ) {
		for my $group (qw(network sport)) {
			$ORDER{$group} = [ grep { $BY_ID{$_}->{group} eq $group && !$BY_ID{$_}->{dupOf} } @order ];
		}
	}

	return;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# $cb wrapped to run once; a die in it is logged, never propagated.
sub _once {
	my $cb = shift;
	my $called = 0;

	return sub {
		return if $called++;
		return unless ref $cb eq 'CODE';
		eval { $cb->(@_); 1 } or $log->error( 'Station callback died: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# The catalogue: StationData's records, or (tests only) the records given.
sub _setRecords {
	shift if @_ && !ref $_[0];    # class method call
	@RECORDS    = @_ ? map { {%$_} } @_ : Plugins::ABCListen::StationData::records();
	%BY_ID      = map { $_->{id} => $_ } @RECORDS;
	%LIVE_SLUGS = map { $_->{slug} => $_->{id} } grep { defined $_->{slug} } @RECORDS;
	return;
}

# test helper: forget runtime state
sub _reset {
	%ENRICHED       = ();
	%ORDER          = ();
	%ENRICH_STATE   = ();
	%UNKNOWN_LOGGED = ();
	%EVENT          = ();
	%EVENT_WAITERS  = ();
	@EVENT_QUEUE    = ();
	$eventsRunning  = 0;
	return;
}

1;
