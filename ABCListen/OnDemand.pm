package Plugins::ABCListen::OnDemand;

# Programs and episodes hook (hook API: see Plugin.pm) and the on-demand builders every stream uses
# for program and episode rows (ai-state/streams.md contract 6). Data: Plugins::ABCListen::Programs.
#
# init loads and initialises Plugins::ABCListen::Episode (episode playback, O1), so O1 fills
# Episode.pm and never edits this file.
#
# Menus: top level "Programs" (weight Util::topWeight('programs'), declared in menuWeights)
#   -> _programsRoot (O3): "By network" · "All programs A–Z" · "By type"
#   By network -> the networks (Programs::networks order) -> the network's programs (programItem rows)
#   -> _programMenu -> episodes (episodeItem rows) -> _episodeMenu.
#   All programs A–Z (O3) -> "<L> (<n>)" for A..Z, then "0–9 (<n>)", then (D7) "Other (<n>)"
#   (PLUGIN_ABCLISTEN_AZ_OTHER), rows without programs omitted -> that row's programs (rows as in
#   programsByType). A program's row comes from the first letter or digit of its Programs::sortKey
#   (a leading "The " ignored, accents folded; punctuation, symbols, spaces and (D8) modifier
#   letters such as the ʻokina before it skipped; D8: compatibility forms folded, so fullwidth
#   and ligature letters count as their letters): a-z -> that letter; D7: a letter NFD leaves
#   alone maps to its Latin letter (æ -> A, ø œ -> O, ł -> L, đ ð -> D, þ -> T, ß -> S, ı -> I;
#   D8: ħ -> H, ŋ -> N, ə -> E); a digit -> 0–9; any other letter (CJK, Cyrillic,
#   Greek, ...) or no letter or digit at all -> Other. In fallback mode (ProgramIndex: network
#   lists) the first item is the PLUGIN_ABCLISTEN_INDEX_FALLBACK text.
#   By type (O3) -> "<type label> (<n>)" in programsByType's type order, empty types omitted ->
#   programsByType($client, $cb, <type key>). In fallback mode: only the INDEX_FALLBACK text.
#   Program data: Plugins::ABCListen::ProgramIndex->programs (one Algolia query a day).
# Every feed (a coderef url, called as ($client, $cb, $args, @passthrough)) calls
# $cb->({ items => [...] }) exactly once (By type -> <type> answers programsByType's array ref):
# on success, when empty, on error (one readable text item:
# PLUGIN_ABCLISTEN_LOAD_FAILED or the API's token) and if building the items dies. $client may be
# undef everywhere (web UI without a player, CLI '-').
#
# ---- Public builders (contract 6) -----------------------------------------------------------------
#
# Plugins::ABCListen::OnDemand->programItem($client, \%program) -> \%item | undef
#   \%program = { title, path, id?, image?, description?, network? } (other keys are kept).
#   path is required (undef without a site path on www.abc.net.au); it is normalised to the
#   canonical program path (API::sitePath: '/listen/programs/scienceshow', no host, query or
#   trailing slash). title falls back to that path.
#   Item: { name => title, line1 => title, line2 => network, type => 'link', url => \&_programMenu,
#           passthrough => [ { %program, path => canonical path } ],
#           image => API::imageUrl(image, 300) || Util::ICON }
#   line2 is absent when empty. Callers may override name/line1 only (L4). There is deliberately
#   no 'description' key on the row (nor may callers add one): Slim::Control::XMLBrowser treats a
#   non-audio item with a description as an information leaf, so JSON-RPC clients (Material, Jive,
#   CLI) could not open the program. The description travels in the passthrough program and is
#   the first item of the program menu.
#
# Plugins::ABCListen::OnDemand->episodeItem($client, \%episode) -> \%item | undef
#   \%episode = the episode meta-cache shape (contract 3): { id, docType, title, programTitle,
#   programId, path, image, description, date (epoch), duration (s) }, optionally renditions,
#   availableTo, downloadAvailableTo, seenAt, plus the non-cached inputs programImage (artwork
#   fallback), presenters and segments. id (digits) is required, else undef.
#   Item: { name => "<friendlyDate> – <title>", line1 => title, line2 => "<friendlyDate> · <friendlyDuration>",
#           type => 'link', url => \&_episodeMenu, passthrough => [ { %episode } ],
#           play => 'abclisten://episode/<id>', image => API::imageUrl(episode image || programImage, 300) || ICON,
#           duration }
#   No on_select (touch skins open the row; 'play' plays it and is what favourites store).
#   Without a date the name is the title and line2 the duration; without a duration line2 is the
#   date; with neither there is no line2. duration is absent when unknown. A missing title falls
#   back to programTitle, then 'ABC listen'.
#   Side effect: Util::setEpisodeMeta(id, ...) with the contract-3 keys only (never presenters,
#   segments or programImage); the cached image is the episode image, else programImage; path is
#   canonical. Undef values never clobber the cache (Util merge rule).
#
# Plugins::ABCListen::OnDemand->registerProgramMenuProvider(sub { my ($client, $program, $cb) = @_; $cb->(\@items) })
#   Extra items for every program menu (_programMenu), between the program header and the
#   episodes, providers in registration order (Discover's before MyABC's: D5 Chapters, M2 Follow).
#   $program is a copy of the program row's passthrough hash merged with the loaded detail
#   (Programs->program): { %program, id, title, template, restricted, episodeCollectionId }, the
#   detail's values winning when they are non-empty (restricted is 1 or 0).
#   Each provider is isolated: one that dies, calls back with anything but an array ref, or has
#   not called back within 5 s is skipped (and logged); a second or late call back is ignored.
#   Non-hash entries in @items are dropped. Returns 1, or 0 (logged) for a non-coderef.
#
# Plugins::ABCListen::OnDemand->programsByType($client, $cb, $typeKey)            (O3; used by D2, D4)
#   The A–Z list of one type of program. Class method; $client may be undef. $typeKey is one of
#   the six type keys (Plugins::ABCListen::ProgramIndex::typeKey of the program's programType),
#   in By type's order:
#     podcast   (Podcasts)        programType podcast
#     catchup   (Catch-up radio)  catch-up
#     music     (Music)           music, Music Playlists
#     news      (News briefings)  news-briefing
#     audiobook (Audiobooks)      audiobook
#     other     (Other)           none, empty or any other value
#   Calls $cb->(\@items) EXACTLY ONCE, with an array ref (LMS feeds accept it, so a feed can be
#   url => sub { my ($client, $cb, $args) = @_; Plugins::ABCListen::OnDemand->programsByType($client, $cb, 'podcast') }):
#     - the type's programs: programItem rows in Programs::sortKey order (title, case-insensitive,
#       accents folded, a leading "The " ignored); when titles repeat in the list, name and line1
#       become "<title> (<network>)" (unless the network is missing or also repeats; the
#       passthrough program is unchanged). Exactly the items By type -> <type> shows;
#     - fallback mode (the index is the network lists, so types are unknown): one
#       { name => PLUGIN_ABCLISTEN_INDEX_FALLBACK text, type => 'text' } item;
#     - no programs of that type: one PLUGIN_ABCLISTEN_NO_PROGRAMS text item;
#     - an unknown $typeKey (undef, a label, ...; logged at WARN) or an index error: one
#       PLUGIN_ABCLISTEN_LOAD_FAILED text item.
#   Never dies ($cb dying is logged; it is not called again). Public from O3 on: change only
#   additively.
#
# Plugins::ABCListen::OnDemand->programsByTypeAZ($client, $cb, $typeKey)                (D6; used by D2)
#   programsByType grouped by letter, as All programs A–Z groups the index. Class method; $client
#   may be undef. Calls $cb->(\@items) EXACTLY ONCE, with an array ref:
#     - the letter rows of the type's programs: "<L> (<n>)" for A..Z, then "0–9 (<n>)", then
#       "Other (<n>)" (D7), rows without programs omitted (All programs A–Z's bucket rule and row
#       keys, passthrough [<letter>, $typeKey]: 'a'..'z', '0-9' or 'other'); the counts add up to
#       the rows programsByType($typeKey) lists. A letter opens that letter's rows of
#       programsByType($typeKey) (same keys, names, order); a letter without programs of the
#       type (a stale link) is one NO_PROGRAMS text item;
#     - fallback mode, no programs of that type, an unknown $typeKey (WARN) or an index error:
#       programsByType's one text item (INDEX_FALLBACK, NO_PROGRAMS, LOAD_FAILED).
#   Never dies ($cb dying is logged; it is not called again).
#
# Program menu (_programMenu) order: description (textarea) · "Presented by A, B" · network
# (Programs->program attribution title) · provider extras · the newest 50 episodes · "More
# episodes…" (the next 50, to ABC's 250). No episodes: "No episodes available", except for a
# restricted program without an episode collection (an ABC audiobook: D5's provider lists its
# chapters) that has a header row or provider extras to show: the menu is never empty, so with
# none of those it is "No episodes available" too. Episode rows get programImage, and
# programTitle/programId only when the episode path is under the program path
# ('<program path>/...'); otherwise O1 fills them at play time.
#
# Episode menu (_episodeMenu; O4 extended it): synopsis (textarea) · "Play episode" (type audio,
# favourites keep the abclisten:// URL) · "Broadcast <date> · <duration>". The textarea must stay
# first (Slim::Control::XMLBrowser's menu mode replaces item 0 with an empty item when it moves a
# textarea into the window), so items O4 adds go after it. O4's rows, each only when its data
# exists, in this order:
#   "Presented by A, B and C"  the episode's presenters, each once (case-insensitive); text.
#   "Segments (N)"             link -> _segmentsMenu: the episode's segments (each with a digit id;
#                              N counts those), in ABC's order, as episodeItem rows (docType
#                              audiosegment unless given; image: the segment's, else the episode's,
#                              else programImage; the episode's programTitle/programId/
#                              programImage) named and line1 "<label> – <title>": ABC's label
#                              ("1 of 5"), else "<i> of <N>". No date in the name (all segments of
#                              an episode share it). A segment row's own menu lists no segments.
#   "Tracklist (N)" | "No tracklist" | "Tracklist unavailable"
#                              the episode document's tracklist (Plugins::ABCListen::Tracklist),
#                              fetched when the menu opens (8 s at most; the same nextData path and
#                              TTL as O1's resolver, so F3's cache is shared). A link with the rows
#                              inline as text items ("00:55 · Rossini, Gioachino – The Barber of
#                              Seville: Overture"), or a text item when there are none. When the
#                              fetch failed (or died, or missed its deadline) the row is the text
#                              "Tracklist unavailable": the row is there whenever the episode has a
#                              path, so the rows after it keep their index whether the fetch worked
#                              or not (LMS re-walks menus by index; a stale "More from" id must
#                              not open the tracklist once a late document is cached). No row
#                              without an episode path (nothing is fetched). The menu answers once.
#   "More from <program>"      _moreFromItem: programItem({ title, path, id?, image? }) with
#                              name/line1 overridden, when both a program path (the episode's
#                              programPath, else Follow::programPathFor of its path) and a program
#                              title (the episode's programTitle, else the meta cache's, written by
#                              O1) are known.
# No row has a description (LMS menu rule 1). Episode.pm's song info (O4) reuses _moreFromItem
# and _tracklistRows.
#
# Ownership: O2 creates everything; O3 then owns _programsRoot, O4 owns episodeItem/_episodeMenu
# (and its private subs in the O4 section); programItem, _programMenu and the provider registry
# stay with O2. D6 added programsByTypeAZ inside
# O3's section (programsByType's core moved to _byType; _letterRows/_bucketRows are shared with
# All programs A–Z, whose menus are unchanged). D7 changed _bucket (Latin letters NFD leaves alone,
# the Other row) and _letterRows (the Other row), for both A–Z lists; D8 changed _bucket
# (modifier letters, compatibility forms, ħ ŋ ə).

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::Follow;
use Plugins::ABCListen::ProgramIndex;
use Plugins::ABCListen::Programs;
use Plugins::ABCListen::Tracklist;
use Plugins::ABCListen::Util;

use constant ENDASH => "\x{2013}";
use constant MIDDOT => "\x{B7}";

use constant EPISODE_PAGE     => 50;
use constant PROVIDER_TIMEOUT => 5;      # seconds
use constant IMAGE_PX         => 300;
use constant LOAD_FAILED      => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

# The contract-3 keys episodeItem writes to the episode meta cache
my @META_KEYS = qw(docType title programTitle programId path image description date duration
	renditions availableTo downloadAvailableTo seenAt);

my $log = logger('plugin.abclisten');

my @PROVIDERS;

sub init {
	require Plugins::ABCListen::Episode;
	Plugins::ABCListen::Episode->init();
}

# ---------------------------------------------------------------------------
# Top level and browse feeds
# ---------------------------------------------------------------------------

# The top-level "Programs" item sorts at the "programs" weight (see Plugin.pm, Util::topWeight).
sub menuWeights { Plugins::ABCListen::Util::topWeight('programs') }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name   => cstring( $client, 'PLUGIN_ABCLISTEN_PROGRAMS_AZ' ),
		type   => 'link',
		url    => \&_programsRoot,
		image  => Plugins::ABCListen::Util::ICON,
		weight => Plugins::ABCListen::Util::topWeight('programs'),
	} ] );
}

# Programs: "By network", "All programs A–Z", "By type" (O3 owns _programsRoot).
sub _programsRoot {
	my ( $client, $cb, $args ) = @_;

	_respond( $client, $cb, sub {
		return [ map {
			+{
				name  => cstring( $client, $_->[0] ),
				type  => 'link',
				url   => $_->[1],
				image => Plugins::ABCListen::Util::ICON,
			}
		} (
			[ 'PLUGIN_ABCLISTEN_BY_NETWORK', \&_networksFeed ],
			[ 'PLUGIN_ABCLISTEN_AZ',         \&_azFeed ],
			[ 'PLUGIN_ABCLISTEN_BY_TYPE',    \&_typesFeed ],
		) ];
	} );
}

# The networks, in Programs::networks order. Network names are ABC proper nouns (no strings).
sub _networksFeed {
	my ( $client, $cb, $args ) = @_;

	_respond( $client, $cb, sub {
		return [ map {
			+{
				name        => $_->{name},
				type        => 'link',
				url         => \&_networkFeed,
				passthrough => [ $_->{key} ],
				image       => Plugins::ABCListen::Util::ICON,
			}
		} Plugins::ABCListen::Programs::networks() ];
	} );
}

# One network's programs (programItem rows), or one text item on error.
sub _networkFeed {
	my ( $client, $cb, $args, $key ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::Programs::networkPrograms( $key, sub {
			my $result = shift;

			return _textFeed( $client, $once, $result->{error} ) if $result->{error};

			_respond( $client, $once, sub {
				return [ grep {defined} map { __PACKAGE__->programItem( $client, $_ ) } @{ $result->{items} } ];
			} );
		} );
	} );
}

# ---------------------------------------------------------------------------
# === O3 === All programs A–Z, By type and programsByType (see the header)
# ---------------------------------------------------------------------------

use constant INDEX_FALLBACK => 'PLUGIN_ABCLISTEN_INDEX_FALLBACK';
use constant NO_PROGRAMS    => 'PLUGIN_ABCLISTEN_NO_PROGRAMS';
use constant DIGITS         => '0-9';      # the A–Z bucket of programs starting with a digit
use constant OTHER          => 'other';    # D7: ... with a non-Latin letter (or no letter or digit)
use constant AZ_OTHER       => 'PLUGIN_ABCLISTEN_AZ_OTHER';

# D7: Latin letters that NFD does not reduce to a-z -> their A–Z letter: æ, ø, œ, ł, đ, ð (eth),
# þ (thorn), ß, ı (dotless i). sortKey has lower-cased the title; the capitals are here too in
# case a title reaches it as a byte string, which lc leaves alone above ASCII.
my %LATIN_LETTER = (
	"\x{E6}"  => 'a', "\x{C6}"  => 'a',
	"\x{F8}"  => 'o', "\x{D8}"  => 'o',
	"\x{153}" => 'o', "\x{152}" => 'o',
	"\x{142}" => 'l', "\x{141}" => 'l',
	"\x{111}" => 'd', "\x{110}" => 'd',
	"\x{F0}"  => 'd', "\x{D0}"  => 'd',
	"\x{FE}"  => 't', "\x{DE}"  => 't',
	"\x{DF}"  => 's', "\x{1E9E}" => 's',
	"\x{131}" => 'i',
	# D8: ħ (Maltese), ŋ (eng), ə (schwa)
	"\x{127}" => 'h', "\x{126}" => 'h',
	"\x{14B}" => 'n', "\x{14A}" => 'n',
	"\x{259}" => 'e', "\x{18F}" => 'e',
);

my $HAS_NORMALIZE = eval { require Unicode::Normalize; 1 } ? 1 : 0;    # D8: _bucket's NFKD

# By type: the type keys (ProgramIndex::typeKey) in menu order, with their label tokens
my @TYPES = (
	[ podcast   => 'PLUGIN_ABCLISTEN_TYPE_PODCAST' ],
	[ catchup   => 'PLUGIN_ABCLISTEN_TYPE_CATCHUP' ],
	[ music     => 'PLUGIN_ABCLISTEN_TYPE_MUSIC' ],
	[ news      => 'PLUGIN_ABCLISTEN_TYPE_NEWS' ],
	[ audiobook => 'PLUGIN_ABCLISTEN_TYPE_AUDIOBOOK' ],
	[ other     => 'PLUGIN_ABCLISTEN_TYPE_OTHER' ],
);
my %TYPE_LABEL = map { $_->[0] => $_->[1] } @TYPES;

sub programsByType {
	my ( $class, $client, $cb, $typeKey ) = @_;
	_byType( 'programsByType', $client, $cb, $typeKey, sub { _programRows( $client, shift ) } );
	return;
}

# D6: the type's letter rows (see the header); its letters open _letterFeed with the type.
sub programsByTypeAZ {
	my ( $class, $client, $cb, $typeKey ) = @_;
	_byType( 'programsByTypeAZ', $client, $cb, $typeKey, sub { _letterRows( $client, shift, $typeKey ) } );
	return;
}

# programsByType's core (D6: shared with programsByTypeAZ and a type's letters):
# $cb->($build->(\@refs of the type)) once, or programsByType's text item. $caller names the
# entry point in log lines (D7).
sub _byType {
	my ( $caller, $client, $cb, $typeKey, $build ) = @_;
	my $once = _once($cb);

	eval {
		if ( !( defined $typeKey && !ref $typeKey && $TYPE_LABEL{$typeKey} ) ) {
			$log->warn( "$caller: unknown program type " . ( defined $typeKey ? "'$typeKey'" : 'undef' ) );
			$once->( [ _textItem( $client, LOAD_FAILED ) ] );
			return 1;
		}

		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			my $items = eval {
				return [ _textItem( $client, LOAD_FAILED ) ]    if $index->{error};
				return [ _textItem( $client, INDEX_FALLBACK ) ] if $index->{fallback};    # types are unknown

				my @refs = grep { Plugins::ABCListen::ProgramIndex::typeKey( $_->{programType} ) eq $typeKey } @{ $index->{items} };
				return @refs ? $build->( \@refs ) : [ _textItem( $client, NO_PROGRAMS ) ];
			};

			if ( ref $items ne 'ARRAY' ) {
				$log->error( "$caller: building the ABC listen programs menu failed: " . ( $@ || 'unknown error' ) );
				$items = [ _textItem( $client, LOAD_FAILED ) ];
			}

			$once->($items);
		} );

		1;
	} or do {
		$log->error( "$caller failed: " . ( $@ || 'unknown error' ) );
		eval { $once->( [ _textItem( $client, LOAD_FAILED ) ] ); 1 } or $log->error( "$caller callback failed: " . ( $@ || 'unknown error' ) );
	};

	return;
}

# All programs A–Z: the letters with their counts (fallback: the note first).
sub _azFeed {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			return _textFeed( $client, $once, LOAD_FAILED ) if $index->{error};

			_respond( $client, $once, sub {
				my @items;
				push @items, _textItem( $client, INDEX_FALLBACK ) if $index->{fallback};
				push @items, @{ _letterRows( $client, $index->{items} ) };
				return \@items;
			} );
		} );
	} );
}

# The letter rows of $refs: "<L> (<n>)" for a..z, then "0–9 (<n>)", then "Other (<n>)" (D7),
# empty rows omitted, each opening _letterFeed with passthrough [$bucket] or, for one type's
# letters (D6), [$bucket, $typeKey].
sub _letterRows {
	my ( $client, $refs, $typeKey ) = @_;

	my %count;
	$count{ _bucket($_) }++ for @$refs;

	return [ map {
		+{
			name        => _bucketName( $client, $_ ) . " ($count{$_})",
			type        => 'link',
			url         => \&_letterFeed,
			passthrough => [ $_, defined $typeKey ? $typeKey : () ],
			image       => Plugins::ABCListen::Util::ICON,
		}
	} grep { $count{$_} } 'a' .. 'z', DIGITS, OTHER ];
}

# A bucket's row name: the upper-case letter, "0–9" or (D7) PLUGIN_ABCLISTEN_AZ_OTHER's text.
sub _bucketName {
	my ( $client, $bucket ) = @_;
	return $bucket eq DIGITS ? '0' . ENDASH . '9' : $bucket eq OTHER ? cstring( $client, AZ_OTHER ) : uc $bucket;
}

# One letter's programs; with a type key (D6: programsByTypeAZ's letters), that letter's rows of
# programsByType($typeKey), answered as programsByType answers.
sub _letterFeed {
	my ( $client, $cb, $args, $bucket, $typeKey ) = @_;

	return _byType( 'programsByTypeAZ letter', $client, $cb, $typeKey, sub { _bucketRows( $client, shift, $bucket ) } ) if defined $typeKey;

	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			return _textFeed( $client, $once, LOAD_FAILED ) if $index->{error};

			_respond( $client, $once, sub { _bucketRows( $client, $index->{items}, $bucket ) } );
		} );
	} );
}

# The program rows of the refs in $bucket, else one NO_PROGRAMS text item.
sub _bucketRows {
	my ( $client, $refs, $bucket ) = @_;
	my @refs = grep { defined $bucket && _bucket($_) eq $bucket } @$refs;
	return @refs ? _programRows( $client, \@refs ) : [ _textItem( $client, NO_PROGRAMS ) ];
}

# By type: the types with their counts, in @TYPES order (fallback: only the note).
sub _typesFeed {
	my ( $client, $cb, $args ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			return _textFeed( $client, $once, LOAD_FAILED )    if $index->{error};
			return _textFeed( $client, $once, INDEX_FALLBACK ) if $index->{fallback};    # types are unknown

			_respond( $client, $once, sub {
				my %count;
				$count{ Plugins::ABCListen::ProgramIndex::typeKey( $_->{programType} ) }++ for @{ $index->{items} };

				return [ map {
					my ( $key, $token ) = @$_;
					$count{$key}
						? +{
							name        => cstring( $client, $token ) . " ($count{$key})",
							type        => 'link',
							url         => \&_typeFeed,
							passthrough => [$key],
							image       => Plugins::ABCListen::Util::ICON,
						}
						: ();
				} @TYPES ];
			} );
		} );
	} );
}

# By type -> <type>: exactly programsByType (one code path with D2/D4).
sub _typeFeed {
	my ( $client, $cb, $args, $typeKey ) = @_;
	__PACKAGE__->programsByType( $client, $cb, $typeKey );
}

# Program rows (programItem) in sortKey order. Titles that repeat in the list are named
# "<title> (<network>)" (name/line1), unless the network is missing or repeats too.
sub _programRows {
	my ( $client, $refs ) = @_;

	my @sorted = map { $_->[1] }
		sort { $a->[0] cmp $b->[0] || $a->[2] cmp $b->[2] || $a->[1]->{path} cmp $b->[1]->{path} }
		map { my $title = _indexTitle($_); [ Plugins::ABCListen::Programs::sortKey($title), $_, $title ] } @$refs;

	my @items = grep {defined} map { __PACKAGE__->programItem( $client, $_ ) } @sorted;

	my ( %titles, %networks );
	for my $item (@items) {
		my $title = lc $item->{name};
		$titles{$title}++;
		$networks{$title}{ lc $item->{line2} }++ if _hasText( $item->{line2} );
	}

	for my $item (@items) {
		my $title   = lc $item->{name};
		my $network = $item->{line2};
		next unless $titles{$title} > 1 && _hasText($network) && $networks{$title}{ lc $network } == 1;
		$item->{name} = $item->{line1} = "$item->{name} ($network)";
	}

	return \@items;
}

# The title a program row shows (programItem: the title, else the path).
sub _indexTitle {
	my $ref = shift;
	return _hasText( $ref->{title} ) ? $ref->{title} : defined $ref->{path} ? $ref->{path} : '';
}

# A program's A–Z bucket, from the first letter or digit of its sort key (punctuation, symbols
# and spaces before it skipped): a-z -> that letter; D7: a Latin letter NFD leaves alone (æ, ø,
# œ, ł, đ, ð, þ, ß, ı; D8: ħ, ŋ, ə) -> its letter (%LATIN_LETTER); a digit -> DIGITS; any other
# letter (non-Latin), or no letter or digit at all -> OTHER.
# D8: modifier letters (\p{Lm}: ʻ U+02BB okina, ʼ U+02BC) are skipped like punctuation
# ("ʻUlu" -> u), and the letter or digit found is folded to its compatibility form first (NFKD,
# marks dropped, its first letter or digit, lower case: fullwidth Ｆ and the ﬁ ligature -> f,
# ① -> 1). Symbols stay skipped, also those with a compatibility form (™).
sub _bucket {
	my ($char) = Plugins::ABCListen::Programs::sortKey( _indexTitle(shift) ) =~ /((?!\p{Lm})[\p{L}\p{N}])/;

	return OTHER unless defined $char;

	if ($HAS_NORMALIZE) {
		my ($folded) = Unicode::Normalize::NFKD($char) =~ /([\p{L}\p{N}])/;
		$char = lc $folded if defined $folded;    # NFKD may give a capital (U+210C ℌ -> H)
	}

	return $char if $char =~ /\A[a-z]\z/;
	return $LATIN_LETTER{$char} if exists $LATIN_LETTER{$char};
	return DIGITS if $char =~ /\p{N}/;
	return OTHER;
}

# === end O3 ===

# ---------------------------------------------------------------------------
# Builders (contract 6)
# ---------------------------------------------------------------------------

sub programItem {
	my ( $class, $client, $program ) = @_;
	return undef unless ref $program eq 'HASH';

	my $path = Plugins::ABCListen::API::sitePath( $program->{path} );
	return undef unless defined $path;

	my %program = ( %$program, path => $path );
	my $title   = _hasText( $program{title} ) ? $program{title} : $path;

	my $item = {
		name        => $title,
		line1       => $title,
		type        => 'link',
		url         => \&_programMenu,
		passthrough => [ \%program ],
		image       => Plugins::ABCListen::API::imageUrl( $program{image}, IMAGE_PX ) || Plugins::ABCListen::Util::ICON,
	};

	# line2: Material, Jive and the CLI menu mode (the Default web skin shows only the name)
	$item->{line2} = $program{network} if _hasText( $program{network} );

	# No 'description' key: LMS's CLI/JSON-RPC browser (Slim::Control::XMLBrowser, "Bug 17385")
	# shows a non-audio item that has a description as an information leaf (Title/Description)
	# instead of opening it, so Material, Jive and the CLI could not open the program. The
	# description stays in the passthrough program and heads the program menu (textarea).

	return $item;
}

sub episodeItem {
	my ( $class, $client, $episode ) = @_;
	return undef unless ref $episode eq 'HASH';

	my $url = Plugins::ABCListen::Util::episodeUrl( $episode->{id} ) or return undef;

	my %episode = %$episode;
	$episode{path} = Plugins::ABCListen::API::sitePath( $episode{path} ) if defined $episode{path};

	my $image = _episodeImage( \%episode );
	my $title = _episodeTitle( \%episode );
	my $date  = Plugins::ABCListen::Util::friendlyDate( $episode{date} );
	my $line2 = _dateDuration( \%episode );

	my $item = {
		# the Default web skin shows only the name, so it carries the date
		name        => defined $date ? $date . ' ' . ENDASH . ' ' . $title : $title,
		line1       => $title,
		type        => 'link',
		url         => \&_episodeMenu,
		passthrough => [ \%episode ],
		play        => $url,
		image       => Plugins::ABCListen::API::imageUrl( $image, IMAGE_PX ) || Plugins::ABCListen::Util::ICON,
	};

	$item->{line2}    = $line2              if length $line2;
	$item->{duration} = $episode{duration} + 0 if _isDuration( $episode{duration} );

	my %meta = map { $_ => $episode{$_} } grep { exists $episode{$_} } @META_KEYS;
	$meta{image} = $image;
	Plugins::ABCListen::Util::setEpisodeMeta( $episode{id}, \%meta );

	return $item;
}

sub registerProgramMenuProvider {
	my ( $class, $provider ) = @_;

	if ( ref $provider ne 'CODE' ) {
		$log->warn('registerProgramMenuProvider: not a code reference; ignored');
		return 0;
	}

	push @PROVIDERS, $provider;
	return 1;
}

# Forget every provider (for tests).
sub _resetProviders { @PROVIDERS = (); return }

# ---------------------------------------------------------------------------
# Program menu
# ---------------------------------------------------------------------------

sub _programMenu {
	my ( $client, $cb, $args, $program ) = @_;
	my $once = _once($cb);

	$program = {} unless ref $program eq 'HASH';

	_try( $client, $once, sub {
		Plugins::ABCListen::Programs::program( $program->{path}, sub {
			my $detail = shift;

			return _textFeed( $client, $once, $detail->{error} ) if $detail->{error};

			_try( $client, $once, sub { _programMenuItems( $client, $once, $program, $detail ) } );
		} );
	} );
}

# Header, provider extras and the first page of episodes, fetched at once.
sub _programMenuItems {
	my ( $client, $cb, $program, $detail ) = @_;

	my @header = _programHeader( $client, $detail );

	my %merged = %$program;
	for my $key (qw(id title template restricted episodeCollectionId)) {
		$merged{$key} = $detail->{$key} if defined $detail->{$key} && length $detail->{$key};
	}

	my $context = {
		path         => $program->{path},
		programTitle => _hasText( $detail->{title} ) ? $detail->{title} : $program->{title},
		programId    => defined $detail->{id} ? $detail->{id} : $program->{id},
		programImage => $detail->{image} || $program->{image},
		collectionId => $detail->{episodeCollectionId},
	};

	my ( $extras, $episodes );
	my $pending = 2;

	my $done = sub {
		return if --$pending;

		_respond( $client, $cb, sub {
			my @items = ( @header, @$extras, @$episodes );

			# never an empty menu: a restricted program with no header rows, no provider extras
			# (none registered, or they failed or timed out) and no episode list says so
			@items = ( _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) ) unless @items;

			return \@items;
		} );
	};

	_runProviders( $client, \%merged, sub {
		$extras = shift;
		$done->();
	} );

	if ( defined $context->{collectionId} ) {
		_episodePage( $client, $context, 0, sub {
			$episodes = shift;
			$done->();
		} );
	}
	else {
		# ABC audiobooks have no episode list on the web: D5's provider lists the chapters
		$episodes = $detail->{restricted} ? [] : [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) ];
		$done->();
	}
}

# Description (textarea), "Presented by ...", network; each only when known.
sub _programHeader {
	my ( $client, $detail ) = @_;
	my @items;

	push @items, { name => $detail->{description}, type => 'textarea' } if _hasText( $detail->{description} );

	my @presenters = grep { _hasText($_) } @{ ref $detail->{presenters} eq 'ARRAY' ? $detail->{presenters} : [] };
	push @items, { name => cstring( $client, 'PLUGIN_ABCLISTEN_PRESENTED_BY', join( ', ', @presenters ) ), type => 'text' } if @presenters;

	push @items, { name => $detail->{network}, type => 'text' } if _hasText( $detail->{network} );

	return @items;
}

# One page of episode rows from $offset, then "More episodes…" when ABC has more (to 250).
# $cb->(\@items), once: episode rows (+ More), or one NO_EPISODES / error text item.
sub _episodePage {
	my ( $client, $context, $offset, $cb ) = @_;

	Plugins::ABCListen::Programs::episodes( $context->{collectionId}, $offset, EPISODE_PAGE, sub {
		my $result = shift;

		my $items = eval { _episodePageItems( $client, $context, $offset, $result ) };

		if ( ref $items ne 'ARRAY' ) {
			$log->error( 'Building the ABC listen episode list failed: ' . ( $@ || 'unknown error' ) );
			$items = [ _textItem( $client, LOAD_FAILED ) ];
		}

		$cb->($items);
	} );
}

sub _episodePageItems {
	my ( $client, $context, $offset, $result ) = @_;

	return [ _textItem( $client, $result->{error} ) ] if $result->{error};

	my @episodes = @{ $result->{items} || [] };
	return [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) ] unless @episodes;

	my @items = grep {defined} map { __PACKAGE__->episodeItem( $client, _withProgram( $context, $_ ) ) } @episodes;

	my $next = $offset + EPISODE_PAGE;
	if ( $next < ( $result->{total} || 0 ) ) {
		push @items, {
			name        => cstring( $client, 'PLUGIN_ABCLISTEN_MORE_EPISODES' ),
			type        => 'link',
			url         => \&_moreEpisodes,
			passthrough => [ $context, $next ],
		};
	}

	return \@items;
}

# "More episodes…": the next page of a program's episodes.
sub _moreEpisodes {
	my ( $client, $cb, $args, $context, $offset ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		_episodePage( $client, $context, $offset, sub {
			my $items = shift;
			_respond( $client, $once, sub {$items} );
		} );
	} );
}

# The episode ref with the program's artwork as fallback, and the program's title and id when the
# episode belongs to it (its path is under the program path). Collections can hold other
# programs' episodes (The Science Show lists Lab Notes); those get no programTitle/programId, so
# they are never labelled with the wrong program (O1 fills them in at play time).
sub _withProgram {
	my ( $context, $episode ) = @_;
	my %episode = %$episode;

	$episode{programImage} = $context->{programImage} if _hasText( $context->{programImage} );

	my $programPath = $context->{path};
	if ( defined $programPath && defined $episode{path} && index( $episode{path}, "$programPath/" ) == 0 ) {
		$episode{programTitle} = $context->{programTitle} if _hasText( $context->{programTitle} );
		$episode{programId}    = $context->{programId}    if defined $context->{programId};
	}

	return \%episode;
}

# ---------------------------------------------------------------------------
# Provider registry
# ---------------------------------------------------------------------------

# Run every provider at once; $cb->(\@extras) once, in registration order, after each provider
# has called back, died or timed out.
sub _runProviders {
	my ( $client, $program, $cb ) = @_;

	my @providers = @PROVIDERS;
	return $cb->( [] ) unless @providers;

	my @results;
	my $pending     = scalar @providers;
	my $dispatching = 1;
	my $finished    = 0;

	my $finish = sub {
		return if $finished++;
		$cb->( [ map { @{ $_ || [] } } @results ] );
	};

	for my $i ( 0 .. $#providers ) {
		my ( $settled, $timer ) = ( 0, undef );

		my $settle = sub {
			my ( $items, $why ) = @_;

			if ( $settled++ ) {
				$log->warn( "Program menu provider $i " . ( $why || 'called back more than once or too late' ) . '; ignored' );
				return;
			}

			Slim::Utils::Timers::killSpecific($timer) if $timer;
			undef $timer;

			if ($why) {
				$log->error("Program menu provider $i $why; skipped");
			}
			elsif ( ref $items ne 'ARRAY' ) {
				$log->error("Program menu provider $i called back with " . ( defined $items ? ( ref $items || 'a scalar' ) : 'undef' ) . ' instead of an array ref; ignored');
			}
			else {
				$results[$i] = [ grep { ref $_ eq 'HASH' } @$items ];
			}

			$finish->() if --$pending == 0 && !$dispatching;
		};

		$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + PROVIDER_TIMEOUT, sub {
			undef $timer;
			$settle->( undef, 'did not call back within ' . PROVIDER_TIMEOUT . ' s' );
		} );

		eval { $providers[$i]->( $client, {%$program}, sub { $settle->( $_[0] ) } ); 1 }
			or $settle->( undef, 'failed: ' . ( $@ || 'unknown error' ) );
	}

	$dispatching = 0;
	$finish->() if $pending == 0;

	return;
}

# ---------------------------------------------------------------------------
# Episode menu
# ---------------------------------------------------------------------------

sub _episodeMenu {
	my ( $client, $cb, $args, $episode ) = @_;
	my $once = _once($cb);

	$episode = {} unless ref $episode eq 'HASH';

	# O4: the tracklist is fetched when the menu opens, for an episode with a page (no page, or no
	# id: no fetch and no tracklist row). Tracklist->fetch answers once, within 8 s.
	my $path = defined Plugins::ABCListen::Util::episodeUrl( $episode->{id} ) ? Plugins::ABCListen::API::sitePath( $episode->{path} ) : undef;

	if ( !defined $path || $path eq '/' ) {
		return _respond( $client, $once, sub { _episodeMenuItems( $client, $episode, undef ) } );
	}

	my $answer = sub {
		my $tracklist = shift;
		_respond( $client, $once, sub { _episodeMenuItems( $client, $episode, $tracklist ) } );
	};

	# a fetch that dies is a failed fetch: the menu still lists everything else
	eval { Plugins::ABCListen::Tracklist::fetch( { id => $episode->{id}, path => $path }, $answer ); 1 } or do {
		$log->error( 'Fetching the ABC listen tracklist failed: ' . ( $@ || 'unknown error' ) );
		$answer->( { error => LOAD_FAILED } );
	};

	return;
}

# The episode menu's items (see the header); $tracklist is Tracklist->fetch's answer, or undef
# when nothing was fetched.
sub _episodeMenuItems {
	my ( $client, $episode, $tracklist ) = @_;

	my $url   = Plugins::ABCListen::Util::episodeUrl( $episode->{id} ) or die "no episode id\n";
	my $title = _episodeTitle($episode);
	my $image = Plugins::ABCListen::API::imageUrl( _episodeImage($episode), IMAGE_PX ) || Plugins::ABCListen::Util::ICON;

	my @items;

	# The synopsis comes first: in menu mode (Jive, Material, CLI menu:1) Slim::Control::XMLBrowser
	# moves a textarea into the window and writes an empty item at index 0, which would wipe out
	# a "Play episode" item listed before it.
	push @items, { name => $episode->{description}, type => 'textarea' } if _hasText( $episode->{description} );

	push @items, {
		name            => cstring( $client, 'PLUGIN_ABCLISTEN_PLAY_EPISODE' ),
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		favorites_title => $title,
		favorites_icon  => $image,
		image           => $image,
	};

	my $date     = Plugins::ABCListen::Util::friendlyDate( $episode->{date} );
	my $duration = Plugins::ABCListen::Util::friendlyDuration( $episode->{duration} );

	if ( defined $date ) {
		push @items, { name => cstring( $client, 'PLUGIN_ABCLISTEN_BROADCAST', _dateDuration($episode) ), type => 'text' };
	}
	elsif ( length $duration ) {
		push @items, { name => $duration, type => 'text' };
	}

	# === O4 === presenters, segments, tracklist, "More from <program>": each only when known

	my $presenters = _presenterList( $client, $episode->{presenters} );
	push @items, { name => cstring( $client, 'PLUGIN_ABCLISTEN_PRESENTED_BY', $presenters ), type => 'text' } if defined $presenters;

	my @segments = _segments($episode);
	if (@segments) {
		push @items, {
			name        => cstring( $client, 'PLUGIN_ABCLISTEN_SEGMENTS', scalar @segments ),
			type        => 'link',
			url         => \&_segmentsMenu,
			passthrough => [$episode],
		};
	}

	push @items, _tracklistItem( $client, $tracklist ) if ref $tracklist eq 'HASH';

	my $more = _moreFromItem( $client, $episode );
	push @items, $more if $more;

	return \@items;
}

# ---------------------------------------------------------------------------
# === O4 === Episode extras: segments, tracklist, "More from <program>" (see the header)
# ---------------------------------------------------------------------------

# Segments (N) -> the segments in ABC's order: episodeItem rows named "<label> – <title>"
# (ABC's "1 of 5", else "<i> of <N>"). A stale id whose episode lists no segments any more: one
# NO_EPISODES text item.
sub _segmentsMenu {
	my ( $client, $cb, $args, $episode ) = @_;
	$episode = {} unless ref $episode eq 'HASH';

	_respond( $client, $cb, sub {
		my @segments = _segments($episode);
		return [ _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) ] unless @segments;

		my $i = 0;
		return [ grep {defined} map { _segmentItem( $client, $episode, $_, ++$i, scalar @segments ) } @segments ];
	} );
}

# The episode's playable segments: hashes with a digit id (a segment without one is skipped and
# not counted). Segments of segments don't exist: a segment's own segments are never listed.
sub _segments {
	my $episode = shift;
	return () unless ref $episode->{segments} eq 'ARRAY';
	return grep { ref $_ eq 'HASH' && defined Plugins::ABCListen::Util::episodeUrl( $_->{id} ) } @{ $episode->{segments} };
}

# One segment as an episodeItem (which writes it to the meta cache, so O1 resolves it by path):
# docType audiosegment unless the segment says otherwise; image = the segment's, else the parent
# episode's (else programImage, episodeItem's fallback); the program fields of the parent.
sub _segmentItem {
	my ( $client, $episode, $segment, $i, $n ) = @_;

	my %segment = (
		id       => $segment->{id},
		docType  => _hasText( $segment->{docType} ) ? $segment->{docType} : 'audiosegment',
		segments => [],
	);

	for my $key (qw(title description path date duration presenters)) {
		$segment{$key} = $segment->{$key} if defined $segment->{$key};
	}

	my $image = _hasText( $segment->{image} ) ? $segment->{image} : $episode->{image};
	$segment{image} = $image if _hasText($image);

	for my $key (qw(programTitle programId programImage)) {
		$segment{$key} = $episode->{$key} if defined $episode->{$key};
	}

	my $item = __PACKAGE__->episodeItem( $client, \%segment ) or return undef;

	# The position in text, so lists read well without seeing their order (OPML, non-visual clients)
	my $label = _hasText( $segment->{label} ) ? $segment->{label} : cstring( $client, 'PLUGIN_ABCLISTEN_SEGMENT_OF', $i, $n );
	$item->{name} = $item->{line1} = $label . ' ' . ENDASH . ' ' . _episodeTitle( \%segment );

	return $item;
}

# Tracklist (N) with the formatted rows inline (text), or the "No tracklist" text item; for a
# failed fetch ({ error }) the "Tracklist unavailable" text item, so the row count never depends
# on the fetch.
sub _tracklistItem {
	my ( $client, $tracklist ) = @_;

	return { name => cstring( $client, 'PLUGIN_ABCLISTEN_TRACKLIST_UNAVAILABLE' ), type => 'text' } unless ref $tracklist->{items} eq 'ARRAY';

	my @rows = _tracklistRows( $tracklist->{items} );
	return { name => cstring( $client, 'PLUGIN_ABCLISTEN_NO_TRACKLIST' ), type => 'text' } unless @rows;

	return {
		name  => cstring( $client, 'PLUGIN_ABCLISTEN_TRACKLIST', scalar @rows ),
		type  => 'link',
		items => \@rows,
	};
}

# Tracklist rows -> text items (Tracklist->formatRow; rows without a title are skipped).
# O4-internal: Episode.pm's song info uses it too.
sub _tracklistRows {
	my $rows = shift;
	return map { +{ name => $_, type => 'text' } } grep {defined} map { Plugins::ABCListen::Tracklist::formatRow($_) } ref $rows eq 'ARRAY' ? @$rows : ();
}

# "More from <program>": programItem for the episode's program with name/line1 "More from
# <title>", or undef unless both a program path and a program title are known.
#   - program path: the episode's programPath when a caller gave one, else
#     Follow::programPathFor(the episode's path, else its meta-cache path);
#   - title (with id and programImage): the episode's own programTitle (O2 sets it only for the
#     browsed program's own episodes), else the meta cache's (O1 writes it when it resolves the
#     episode) with its programId and no image (programImage belongs to the browsed program).
# O4-internal: Episode.pm's song info uses it too.
sub _moreFromItem {
	my ( $client, $episode ) = @_;
	return undef unless ref $episode eq 'HASH';

	my $meta = eval { Plugins::ABCListen::Util::getEpisodeMeta( $episode->{id} ) };
	$meta = {} unless ref $meta eq 'HASH';

	my $path = _hasText( $episode->{programPath} ) ? Plugins::ABCListen::API::sitePath( $episode->{programPath} ) : undef;
	$path = Plugins::ABCListen::Follow::programPathFor( _hasText( $episode->{path} ) ? $episode->{path} : $meta->{path} ) unless defined $path && $path ne '/';
	return undef unless defined $path && $path ne '/';

	my %program;
	if ( _hasText( $episode->{programTitle} ) ) {
		%program = ( title => $episode->{programTitle}, id => $episode->{programId}, image => $episode->{programImage} );
	}
	elsif ( _hasText( $meta->{programTitle} ) ) {
		%program = ( title => $meta->{programTitle}, id => $meta->{programId} );
	}
	else {
		return undef;
	}

	%program = ( ( map { $_ => $program{$_} } grep { _hasText( $program{$_} ) } keys %program ), path => $path );

	my $item = __PACKAGE__->programItem( $client, \%program ) or return undef;
	$item->{name} = $item->{line1} = cstring( $client, 'PLUGIN_ABCLISTEN_MORE_FROM', $program{title} );

	return $item;
}

# "A", "A and B", "A, B and C": the presenters' names, each once (case-insensitively, the first
# spelling kept; blanks and non-strings skipped), or undef without any.
sub _presenterList {
	my ( $client, $names ) = @_;
	return undef unless ref $names eq 'ARRAY';

	my ( %seen, @names );
	for my $name ( grep { _hasText($_) } @$names ) {
		( my $clean = $name ) =~ s/\s+/ /g;
		$clean =~ s/\A | \z//g;
		push @names, $clean unless $seen{ lc $clean }++;
	}

	return undef unless @names;

	my $last = pop @names;
	return @names ? cstring( $client, 'PLUGIN_ABCLISTEN_NAMES_AND', join( ', ', @names ), $last ) : $last;
}

# === end O4 ===

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _episodeTitle {
	my $episode = shift;
	return $episode->{title}        if _hasText( $episode->{title} );
	return $episode->{programTitle} if _hasText( $episode->{programTitle} );
	return Plugins::ABCListen::Util::DISPLAY_NAME;
}

sub _episodeImage {
	my $episode = shift;
	return _hasText( $episode->{image} ) ? $episode->{image} : _hasText( $episode->{programImage} ) ? $episode->{programImage} : undef;
}

# "<date> · <duration>", either part alone, or ''.
sub _dateDuration {
	my $episode = shift;
	my @parts = grep { defined && length } (
		Plugins::ABCListen::Util::friendlyDate( $episode->{date} ),
		Plugins::ABCListen::Util::friendlyDuration( $episode->{duration} ),
	);
	return join( ' ' . MIDDOT . ' ', @parts );
}

sub _isDuration { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9]+\z/ && $_[0] > 0 }

sub _hasText { defined $_[0] && !ref $_[0] && $_[0] =~ /\S/ }

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
		$log->error( 'Building the ABC listen programs menu failed: ' . ( $@ || 'unknown error' ) );
		_textFeed( $client, $cb, LOAD_FAILED );
	};
	return;
}

# Call back once with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen programs menu failed: ' . ( $@ || 'unknown error' ) );
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
