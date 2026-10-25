package Plugins::ABCListen::Programs;

# Program and episode data for the ondemand menus (ai-state/streams.md contract 6, data side).
# Data only: no menu code. All I/O goes through Plugins::ABCListen::API (async).
#
# ---- Callbacks ------------------------------------------------------------------------------------
#   Every network function calls $cb EXACTLY ONCE with one hashref, on every path (success, empty,
#   error, a callback of ours that dies). Failure is { error => TOKEN }, TOKEN being the API error
#   token passed through ('PLUGIN_ABCLISTEN_LOAD_FAILED' or 'PLUGIN_ABCLISTEN_RATE_LIMITED').
#   Cache hits call back synchronously, other calls later: code must work either way.
#   All functions work as class methods (Plugins::ABCListen::Programs->program(...)) or as plain
#   functions (Plugins::ABCListen::Programs::program(...)).
#
# ---- Canonical program path ---------------------------------------------------------------------
#   API::sitePath(...): a site path starting with '/', no host, query or trailing slash
#   ('/listen/programs/scienceshow'). Program refs always carry it; consumers (M2's follow
#   de-duplication, O3, D1, L4) rely on it.
#
# ---- Functions ----------------------------------------------------------------------------------
#   networks() -> list of { key, name, collectionIds => [ids], sitePath }, in menu order (copies):
#       rn Radio National, triplej triple j, doublej Double J, classic ABC Classic, jazz ABC Jazz,
#       country ABC Country, kids ABC Kids listen, unearthed triple j Unearthed, pacific ABC Pacific.
#   network($key) -> one of those (a copy), or undef.
#
#   networkPrograms($key, $cb) -> $cb->({ items => [program refs] }) | $cb->({ error => TOKEN })
#       Every collection of the network (API::bff('programAggregationCollection/x',
#       {collectionId, offset, size => 50}), ttl 6 h, stale_ok, timeout 8 s), paged until
#       collection.pagination.total (without a total: until a page shorter than 50; always stops
#       at an empty page). Collections are merged in table order, de-duplicated by path, and
#       sorted by sortKey(title). A collection whose later page fails keeps the programs it has.
#       Errors: an unknown key; every collection failing (the first error's token); or no programs
#       at all (LOAD_FAILED, logged at WARN: no network is expected to be empty).
#   Program ref: { title, path, network, id?, image?, description?, presenters? }
#       title = API::cardRef title; path = canonical program path; network = the network's name;
#       id = the program id, only for coremedia://program/<id> cards (coremedia://teaser/<id>
#       cards have no id); image = cardRef image (300 px); description; presenters = [names]
#       (presentersPrepared[].names.full). Optional keys are absent when unknown.
#       Cards without a title or a path on www.abc.net.au are skipped.
#
#   Every request here is on a menu path, so it gets API_TIMEOUT (8 s) instead of HTTP.pm's 15 s:
#   a slow ABC then answers the menu with an error item instead of keeping it waiting.
#
#   sortKey($title) -> the program list sort key: lower case, accents folded, a leading "The "
#       ignored, whitespace collapsed ('' for undef). O3 and M2 reuse it.
#
#   program($path, $cb[, \%opts]) -> $cb->(\%detail) | $cb->({ error => TOKEN })
#       API::nextData($path) (ttl 6 h, stale_ok, timeout 8 s; stale buildIds and __N_REDIRECT are
#       handled there),
#       pageProps ->
#         { id                  (heroImageWithCTAPrepared.uri coremedia://program/<id>) or undef,
#           title               (heroImageWithCTAPrepared.heading) or undef,
#           description         (API::richText(heroDescriptionPrepared); undef when empty),
#           presenters          [ presentersPrepared[].label.full ],
#           image               (heroImageWithCTAPrepared.heroImagePrepared.imgSrc) or undef,
#           network             (heroImageWithCTAPrepared.attributionLinksPrepared[0].title) or undef,
#           episodeCollectionId (programCollectionPrepared.id) or undef,
#           total               min(programCollectionPrepared.pagination.total, 250); 0 without a collection,
#           firstEpisodes       [ episode refs of programCollectionPrepared.items ],
#           template            (programTemplate: 'audio', 'audiobook', 'default', ...) or undef,
#           restricted          1 | 0 (webDistributionRestricted) }
#       ABC audiobooks: template 'audiobook' (or 'default'), restricted 1, no episodeCollectionId.
#
#   episodes($collectionId, $offset, $size, $cb[, \%opts]) -> $cb->({ items => [episode refs], total, offset })
#                                                   | $cb->({ error => TOKEN })
#       API::bff('episodesWithSegments/x', {collectionId, offset, size}) (ttl 15 min, timeout 8 s),
#       newest first. ABC lists only the newest 250: total = min(pagination.total, 250); size is
#       trimmed so a page never passes 250; offset >= 250 -> { items => [], total => 250, offset }
#       without a request (so total is 250 there even when the program has fewer episodes).
#       offset defaults to 0 and size to 50 (1..250). A collection id that isn't digits -> error.
#       Episodes published between two page loads may repeat a row at a page boundary.
#   Episode ref (contract 3 keys plus list extras), every key present (undef/[] when unknown):
#       { id, docType, title, description, path, date (epoch), duration (s), image (300 px),
#         presenters => [names], segments => [segment refs] }
#       Built on API::cardRef: id (digits) and docType (audioepisode | audio | audiosegment, from
#       contentUri when the card has no docType); title = cardTitle; path = sitePath(articleLink).
#       Segment refs have the same keys (segments => []) plus label (contentLabelPrepared.labelText,
#       e.g. '1 of 5'). Cards that aren't audio documents, or without an id, are skipped.
#
#   F9: \%opts of program() and episodes(): quiet => 1 is for a caller that logs the failure itself
#       (My ABC listen's Latest episodes logs a program it skips at WARN once a day). API.pm then
#       logs that call's failures and stale serves at DEBUG instead of WARN (API.pm's quiet), and
#       the failure also carries message, API.pm's readable detail, for the caller's log line:
#       { error => TOKEN, message => '...' }. A request shared with a caller that isn't quiet is
#       still logged at WARN. Without \%opts (every other caller), or with quiet false: as before.
#
# Owned by the ondemand stream (O2).

use strict;
use warnings;

use List::Util qw(min);

use Slim::Utils::Log;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Util qw(decodeEntities);

use constant LOAD_FAILED => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

use constant AGGREGATION_TTL  => 6 * 3600;
use constant AGGREGATION_SIZE => 50;     # programs per aggregation page (larger sizes are untested)
use constant MAX_PAGES        => 20;     # per collection, so a broken total can't page forever
use constant PROGRAM_TTL      => 6 * 3600;
use constant EPISODES_TTL     => 900;
use constant EPISODE_PAGE     => 50;     # default episodes() page size
use constant MAX_EPISODES     => 250;    # ABC lists only the newest 250 episodes of a program
use constant API_TIMEOUT      => 8;      # seconds per request (menu paths; HTTP.pm's default is 15)

my $log = logger('plugin.abclisten');

my $HAS_NORMALIZE = eval { require Unicode::Normalize; 1 } ? 1 : 0;

# Programs by network: ABC's "All programs" aggregation collections (research §3), menu order.
my @NETWORKS = (
	{ key => 'rn',        name => 'Radio National',     collectionIds => [qw(11474038 13910480)], sitePath => '/listen/radionational/programs' },
	{ key => 'triplej',   name => 'triple j',           collectionIds => [qw(8698186)],           sitePath => '/triplej/programs' },
	{ key => 'doublej',   name => 'Double J',           collectionIds => [qw(9375554)],           sitePath => '/listen/doublej/programs' },
	{ key => 'classic',   name => 'ABC Classic',        collectionIds => [qw(9104650)],           sitePath => '/listen/classic/programs' },
	{ key => 'jazz',      name => 'ABC Jazz',           collectionIds => [qw(8794720)],           sitePath => '/listen/jazz/programs' },
	{ key => 'country',   name => 'ABC Country',        collectionIds => [qw(12606644)],          sitePath => '/listen/country/programs' },
	{ key => 'kids',      name => 'ABC Kids listen',    collectionIds => [qw(9317914)],           sitePath => '/kidslisten/programs' },
	{ key => 'unearthed', name => 'triple j Unearthed', collectionIds => [qw(106304964)],         sitePath => '/triplejunearthed/programs' },
	# OQ4 (probed 2026-10-19): All Programs 9373518 (45) + Featured Programs 9412768
	{ key => 'pacific',   name => 'ABC Pacific',        collectionIds => [qw(9373518 9412768)],   sitePath => '/pacific/programs' },
);

my %AUDIO_TYPE = map { $_ => 1 } qw(audioepisode audio audiosegment);

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------

sub networks {
	return map { _copyNetwork($_) } @NETWORKS;
}

sub network {
	shift if _isClass( $_[0] );
	my $key = shift;
	return undef unless defined $key;

	my ($network) = grep { $_->{key} eq $key } @NETWORKS;
	return $network ? _copyNetwork($network) : undef;
}

sub _copyNetwork { my $n = shift; return { %$n, collectionIds => [ @{ $n->{collectionIds} } ] } }

sub networkPrograms {
	shift if _isClass( $_[0] );
	my ( $key, $cb ) = @_;
	my $once = _once($cb);

	my $network = network($key);
	if ( !$network ) {
		$log->warn( 'Unknown ABC listen network: ' . ( defined $key ? "'$key'" : 'undef' ) );
		return $once->( { error => LOAD_FAILED } );
	}

	my @ids     = @{ $network->{collectionIds} };
	my @results = ();    # per collection: { cards => [...] } or { error => TOKEN }
	my $pending = scalar @ids;

	my $finish = sub {
		_guard( $once, sub {
			my @cards = map { @{ $_->{cards} || [] } } @results;
			my @errors = grep { $_->{error} } @results;

			if ( @errors == @ids ) {
				return $once->( { error => $errors[0]->{error} } );
			}

			my ( %seen, @programs );
			for my $card (@cards) {
				my $program = _programRef( $card, $network->{name} ) or next;
				push @programs, $program unless $seen{ $program->{path} }++;
			}

			if ( !@programs ) {
				$log->warn("No programs found for the ABC listen network '$network->{name}'");
				return $once->( { error => LOAD_FAILED } );
			}

			$once->( { items => _sortPrograms( \@programs ) } );
		} );
	};

	for my $i ( 0 .. $#ids ) {
		_collectionPages( $ids[$i], 0, [], 1, sub {
			$results[$i] = shift;
			$finish->() if --$pending == 0;
		} );
	}

	return;
}

# Page through one aggregation collection; $done->({ cards }) or $done->({ error }), once.
sub _collectionPages {
	my ( $collectionId, $offset, $cards, $page, $done ) = @_;

	my $settle = _once($done);

	Plugins::ABCListen::API::bff(
		'programAggregationCollection/x',
		{ collectionId => $collectionId, offset => $offset, size => AGGREGATION_SIZE },
		sub {
			my $data = shift;
			_guard( sub { $settle->( @$cards ? { cards => $cards } : $_[0] ) }, sub {
				my $collection = ref $data eq 'HASH' && ref $data->{collection} eq 'HASH' ? $data->{collection} : {};
				my @items = grep { ref $_ eq 'HASH' } @{ ref $collection->{items} eq 'ARRAY' ? $collection->{items} : [] };
				push @$cards, @items;

				my $pagination = ref $collection->{pagination} eq 'HASH' ? $collection->{pagination} : {};
				my $total      = _int( $pagination->{total} );
				my $next       = $offset + AGGREGATION_SIZE;

				my $more = @items && ( defined $total ? $next < $total : @items >= AGGREGATION_SIZE );

				if ( $more && $page >= MAX_PAGES ) {
					$log->warn("Program collection $collectionId: stopped after " . MAX_PAGES . ' pages');
					$more = 0;
				}

				return $settle->( { cards => $cards } ) unless $more;

				_collectionPages( $collectionId, $next, $cards, $page + 1, $settle );
			} );
		},
		sub {
			my $error = shift;
			# a later page failed: keep the programs we have
			$settle->( @$cards ? { cards => $cards } : { error => _token($error) } );
		},
		{ ttl => AGGREGATION_TTL, stale_ok => 1, timeout => API_TIMEOUT },
	);

	return;
}

sub _programRef {
	my ( $card, $networkName ) = @_;

	my $ref = Plugins::ABCListen::API::cardRef($card) or return undef;
	return undef unless defined $ref->{title} && defined $ref->{path};

	my %program = (
		title   => $ref->{title},
		path    => $ref->{path},
		network => $networkName,
	);

	$program{id}          = $ref->{uriId}       if $ref->{type} eq 'program';
	$program{image}       = $ref->{image}       if defined $ref->{image};
	$program{description} = $ref->{description} if defined $ref->{description};

	my @presenters = _names( $card->{presentersPrepared}, 'names' );
	$program{presenters} = \@presenters if @presenters;

	return \%program;
}

sub sortKey {
	shift if _isClass( $_[0] );
	my $title = shift;
	return '' unless defined $title && !ref $title;

	my $key = $title;
	if ($HAS_NORMALIZE) {
		$key = Unicode::Normalize::NFD($key);
		$key =~ s/\p{Mn}+//g;
	}

	$key = lc $key;
	$key =~ s/\s+/ /g;
	$key =~ s/\A | \z//g;
	$key =~ s/\Athe (?=\S)//;

	return $key;
}

sub _sortPrograms {
	my $programs = shift;
	my %key = map { $_->{path} => sortKey( $_->{title} ) } @$programs;
	return [ sort { $key{ $a->{path} } cmp $key{ $b->{path} } || $a->{title} cmp $b->{title} || $a->{path} cmp $b->{path} } @$programs ];
}

# ---------------------------------------------------------------------------
# Program detail
# ---------------------------------------------------------------------------

sub program {
	shift if _isClass( $_[0] );
	my ( $path, $cb, $opts ) = @_;
	my $once  = _once($cb);
	my $quiet = _isQuiet($opts);

	Plugins::ABCListen::API::nextData(
		$path,
		sub {
			my $pageProps = shift;
			_guard( $once, sub { $once->( _programDetail($pageProps) ) } );
		},
		sub { $once->( _failure( shift, $quiet ) ) },
		{ ttl => PROGRAM_TTL, stale_ok => 1, timeout => API_TIMEOUT, ( $quiet ? ( quiet => 1 ) : () ) },
	);

	return;
}

sub _programDetail {
	my $pageProps = shift;
	$pageProps = {} unless ref $pageProps eq 'HASH';

	my $hero       = _hash( $pageProps->{heroImageWithCTAPrepared} );
	my $collection = _hash( $pageProps->{programCollectionPrepared} );

	my ( $type, $id ) = Plugins::ABCListen::API::coreMediaRef( $hero->{uri} );
	$id = undef unless defined $type && $type eq 'program';

	my $description = Plugins::ABCListen::API::richText( $pageProps->{heroDescriptionPrepared} );

	my $attribution = ref $hero->{attributionLinksPrepared} eq 'ARRAY' ? _hash( $hero->{attributionLinksPrepared}->[0] ) : {};

	my $image = _hash( $hero->{heroImagePrepared} )->{imgSrc};
	$image = undef unless defined $image && !ref $image && length $image;

	my $collectionId = _digits( $collection->{id} );

	my @firstEpisodes = map { _episodeRef($_) } ref $collection->{items} eq 'ARRAY' ? @{ $collection->{items} } : ();

	my $total = 0;
	if ( defined $collectionId ) {
		$total = _int( _hash( $collection->{pagination} )->{total} );
		$total = scalar @firstEpisodes unless defined $total;
		$total = min( $total, MAX_EPISODES );
	}

	return {
		id                  => $id,
		title               => _text( $hero->{heading} ),
		description         => length $description ? $description : undef,
		presenters          => [ _names( $pageProps->{presentersPrepared}, 'label' ) ],
		image               => $image,
		network             => _text( $attribution->{title} ),
		episodeCollectionId => $collectionId,
		total               => $total,
		firstEpisodes       => [ grep { defined } @firstEpisodes ],
		template            => _text( $pageProps->{programTemplate} ),
		restricted          => $pageProps->{webDistributionRestricted} ? 1 : 0,
	};
}

# ---------------------------------------------------------------------------
# Episodes
# ---------------------------------------------------------------------------

sub episodes {
	shift if _isClass( $_[0] );
	my ( $collectionId, $offset, $size, $cb, $opts ) = @_;
	my $once  = _once($cb);
	my $quiet = _isQuiet($opts);

	$offset = 0 unless defined $offset && !ref $offset && $offset =~ /\A[0-9]+\z/;
	$offset += 0;
	$size = EPISODE_PAGE unless defined $size && !ref $size && $size =~ /\A[0-9]+\z/ && $size > 0;
	$size = min( $size + 0, MAX_EPISODES );

	if ( !defined _digits($collectionId) ) {
		$log->warn( 'Episodes: not an episode collection id: ' . ( defined $collectionId ? "'$collectionId'" : 'undef' ) );
		return $once->( { error => LOAD_FAILED } );
	}

	# ABC never returns more than the newest 250. No request is made here, so the real total is
	# unknown: at offset >= 250 the reported total is 250 even when the program has fewer episodes
	# (OnDemand's program menu never asks past offset 200, ABC's last page of 50, so its menus never
	# show this).
	return $once->( { items => [], total => MAX_EPISODES, offset => $offset } ) if $offset >= MAX_EPISODES;
	$size = MAX_EPISODES - $offset if $offset + $size > MAX_EPISODES;

	Plugins::ABCListen::API::bff(
		'episodesWithSegments/x',
		{ collectionId => $collectionId, offset => $offset, size => $size },
		sub {
			my $data = shift;
			_guard( $once, sub {
				my $collection = ref $data eq 'HASH' ? _hash( $data->{collection} ) : {};
				my @items = grep {defined} map { _episodeRef($_) } ref $collection->{items} eq 'ARRAY' ? @{ $collection->{items} } : ();

				my $total = _int( _hash( $collection->{pagination} )->{total} );
				$total = $offset + @items unless defined $total;

				$once->( { items => \@items, total => min( $total, MAX_EPISODES ), offset => $offset } );
			} );
		},
		sub { $once->( _failure( shift, $quiet ) ) },
		{ ttl => EPISODES_TTL, timeout => API_TIMEOUT, ( $quiet ? ( quiet => 1 ) : () ) },
	);

	return;
}

# An episode card -> episode ref (see the header), or undef.
sub _episodeRef {
	my ( $card, $isSegment ) = @_;

	my $ref = Plugins::ABCListen::API::cardRef($card) or return undef;
	return undef unless $AUDIO_TYPE{ $ref->{type} } && defined $ref->{id} && $ref->{id} =~ /\A[0-9]+\z/;

	my %episode = (
		id          => $ref->{id},
		docType     => $ref->{docType},
		title       => $ref->{title},
		description => $ref->{description},
		path        => $ref->{path},
		date        => $ref->{date},
		duration    => $ref->{duration},
		image       => $ref->{image},
		presenters  => [ _names( $card->{presentersPrepared}, 'names' ) ],
		segments    => [],
	);

	if ($isSegment) {
		$episode{label} = _text( _hash( $card->{contentLabelPrepared} )->{labelText} );
	}
	elsif ( ref $card->{segments} eq 'ARRAY' ) {
		$episode{segments} = [ grep {defined} map { _episodeRef( $_, 1 ) } @{ $card->{segments} } ];
	}

	return \%episode;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Names from a presenters list: $list->[i]->{$key}->{full}, entity-decoded and trimmed.
sub _names {
	my ( $list, $key ) = @_;
	return () unless ref $list eq 'ARRAY';
	return grep {defined} map { _text( _hash( _hash($_)->{$key} )->{full} ) } @$list;
}

# A callback wrapper that passes on only the first call.
sub _once {
	my $cb     = shift;
	my $called = 0;
	return sub {
		return if $called++;
		eval { $cb->(@_) if ref $cb eq 'CODE'; 1 } or $log->error( 'ABC listen programs callback failed: ' . ( $@ || 'unknown error' ) );
		return;
	};
}

# Run $code; if it dies, log and answer $fail with LOAD_FAILED (a callback that has already
# answered ignores it).
sub _guard {
	my ( $fail, $code ) = @_;
	eval { $code->(); 1 } or do {
		$log->error( 'Processing ABC listen program data failed: ' . ( $@ || 'unknown error' ) );
		$fail->( { error => LOAD_FAILED } );
	};
	return;
}

sub _token {
	my $error = shift;
	my $token = ref $error eq 'HASH' ? $error->{error} : undef;
	return defined $token && !ref $token && $token =~ /\APLUGIN_ABCLISTEN_[A-Z0-9_]+\z/ ? $token : LOAD_FAILED;
}

# F9: the caller logs failures itself (see the header)
sub _isQuiet { ref $_[0] eq 'HASH' && $_[0]->{quiet} ? 1 : 0 }

# An API.pm error -> our failure: { error => TOKEN }, plus (F9, for a quiet caller) API.pm's message.
sub _failure {
	my ( $error, $quiet ) = @_;

	my %failure = ( error => _token($error) );
	$failure{message} = $error->{message} if $quiet && ref $error eq 'HASH' && defined $error->{message} && !ref $error->{message};

	return \%failure;
}

sub _text {
	my $text = shift;
	return undef unless defined $text && !ref $text;
	$text = decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/\A | \z//g;
	return length $text ? $text : undef;
}

sub _hash   { ref $_[0] eq 'HASH' ? $_[0] : {} }
sub _digits { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? "$_[0]" : undef }
sub _int    { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ ? $_[0] + 0 : undef }

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

1;
