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
# Plugins::ABCListen::OnDemand->shortText($text[, $max]) -> ($short, $shortened) | ()      (U1)
#   Pure. The header text for a description: its first paragraph (the text up to the first line
#   break; richText separates paragraphs with "\n\n"), whitespace collapsed to single spaces,
#   at most $max (default SHORT_TEXT_MAX, 200) characters:
#     - a first paragraph that fits is kept whole, without an ellipsis;
#     - a longer one is cut at the last sentence end that leaves at least half of $max ("."
#       "!" "?" "…" and closing quotes or brackets, then a space; "。" "！" "？" need no space;
#       "R.A." style initials and Dr. Mr. Mrs. Ms. Mx. St. Prof. Rev. Mt. Jr. Inc. No. vs. e.g.
#       i.e. are not sentence ends)
#       followed by " …"; else at the last word boundary (a space, or beside a Chinese or
#       Japanese character), trailing commas, colons, dashes and opening brackets or quotes
#       dropped, followed by "…". A word is never cut, except a single word longer than $max,
#       which is cut at a character (grapheme) boundary, then "…".
#   $shortened is 1 when $short is not the whole text (a later paragraph, or the cut), else 0.
#   () for undef, a reference or text without a visible character.
#
# Plugins::ABCListen::OnDemand->descriptionItems($client, $text, $aboutToken[, $always]) -> @items  (U1)
#   The rows that head a menu with a description (LMS menu rule 2: the textarea comes first):
#     { name => $short, type => 'textarea' }                                  (shortText)
#   and, only when the text was shortened (U2: or $always is true), right after it:
#     { name => cstring($aboutToken), type => 'link',
#       items => [ { name => <the whole text, trimmed>, type => 'textarea' } ] }
#   ("About this program" / "About this episode" / "About this station"; inline items, no feed,
#   no description key: LMS menu rule 1). In menu mode LMS moves a leading textarea into the
#   window header, which apps such as Squeezer show as a fixed block above the list, so a long
#   description there left no room for the list (#83). Whether the About row is there depends only
#   on the text, so the rows after it keep their index. () without a description.
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
# Program menu (_programMenu) order: description (descriptionItems: the short textarea, then
# "About this program" when it was shortened, or (U2) when 100 or more rows follow the textarea:
# Material hides the window header of such lists; no textarea at all when the menu has more than
# JIVE_CHUNK (200) rows: see _programHeader) · "Presented by A, B" · network
# (Programs->program attribution title) · provider extras · every episode ABC lists, newest first
# (to ABC's 250), as one list (U2, #84; before: 50, then "More episodes…"). No episodes: "No
# episodes available", except for a restricted program without an episode collection (an ABC
# audiobook: D5's provider lists its chapters) that has a header row or provider extras to show:
# the menu is never empty, so with none of those it is "No episodes available" too. Episode rows
# get programImage, and programTitle/programId only when the episode path is under the program
# path ('<program path>/...'); otherwise O1 fills them at play time.
# U2: the program menu is an LMS partial feed. XMLBrowser passes a code-ref feed index/quantity
# (the rows a client lists, or index = the row it opens and quantity 1); the menu answers
# { items => those rows, offset => index, total => all rows } and loads only the ABC pages of
# EPISODE_PAGE (50) episodes those rows are on, at most PAGE_CONCURRENCY (4) at a time, plus page
# 0, whose total (at most 250) sets the length; Programs->episodes caches each page 15 min. Without
# index/quantity (playlist commands: Play all / Add all) it is the whole list, every page. The
# total is page 0's for every window (U2 review): a page of 50 that fails is loaded again as pages
# of SUB_PAGE (10); a place still without an episode keeps a text row (the failed page's error
# text, or "Episode unavailable" where ABC's page holds fewer episodes than its total said), and a
# failed page isn't asked for again for FAILURE_TTL (60 s). Row i is the same episode for as long
# as the pages are cached (stable item ids: LMS keeps no browse session and re-walks menus by
# index).
#
# Episode menu (_episodeMenu; O4 extended it): synopsis (descriptionItems: the short textarea,
# then "About this episode" when it was shortened) · "Play episode" (type audio,
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
# (modifier letters, compatibility forms, ħ ŋ ə). D9 moved _programRows' repeated-title naming
# into _nameRepeats, unchanged, so Search names its program rows the same way. U1 added shortText
# and descriptionItems (shared with LiveMetadata's Program info) and heads the program and episode
# menus with them.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Cache;
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

use constant EPISODE_PAGE     => 50;     # ABC episodes per page (U2: the program menu loads the pages its window shows)
use constant PAGE_CONCURRENCY => 4;      # U2: episode pages loading at once
use constant LONG_LIST        => 100;    # U2: rows after the header from which Material hides it (_programHeader)
use constant SUB_PAGE         => 10;     # U2 review: a failed page is loaded again as pages of this many episodes
use constant MAX_ROUNDS       => 4;      # U2 review: rounds of page loads after the first (_programMenuItems)
use constant FAILURE_TTL      => 60;     # U2 review: seconds a failed episode page isn't asked for again
use constant JIVE_CHUNK       => 200;    # U2 review: rows SqueezePlay/jivelite ask for at a time (DB.lua BLOCK_SIZE)
use constant PROVIDER_TIMEOUT => 5;      # seconds
use constant IMAGE_PX         => 300;
use constant LOAD_FAILED      => 'PLUGIN_ABCLISTEN_LOAD_FAILED';

use constant SHORT_TEXT_MAX => 200;         # U1: characters in a menu's description header
use constant ELLIPSIS       => "\x{2026}";

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

	return _nameRepeats( \@items );
}

# programItem rows whose titles repeat in the list -> name and line1 "<title> (<network>)", unless
# the network (line2) is missing or repeats too; changes the rows in place and returns them.
# O3-internal: Search (D9) names its program rows the same way.
sub _nameRepeats {
	my $items = shift;

	my ( %titles, %networks );
	for my $item (@$items) {
		my $title = lc $item->{name};
		$titles{$title}++;
		$networks{$title}{ lc $item->{line2} }++ if _hasText( $item->{line2} );
	}

	for my $item (@$items) {
		my $title   = lc $item->{name};
		my $network = $item->{line2};
		next unless $titles{$title} > 1 && _hasText($network) && $networks{$title}{ lc $network } == 1;
		$item->{name} = $item->{line1} = "$item->{name} ($network)";
	}

	return $items;
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
# === U1 === Short description headers (shortText, descriptionItems: see the header)
# ---------------------------------------------------------------------------

# Chinese and Japanese characters: a line may break beside them without a space
my $CJK = qr/[\p{Han}\p{Hiragana}\p{Katakana}]/;

# Abbreviations whose full stop doesn't end a sentence (lower case, without the last stop)
my %ABBREVIATION = map { $_ => 1 } qw(dr mr mrs ms mx st prof rev mt jr inc no vs e.g i.e);

sub shortText {
	my ( $class, $text, $max ) = @_;
	return () unless _hasText($text);

	$max = SHORT_TEXT_MAX unless defined $max && !ref $max && $max =~ /\A[0-9]+\z/ && $max >= 10;

	my @paragraphs = grep { length } map { _collapse($_) } split /\R/, $text;
	return () unless @paragraphs;

	my $first = $paragraphs[0];
	return ( $first, @paragraphs > 1 ? 1 : 0 ) if length $first <= $max;

	return ( _cutText( $first, $max ), 1 );
}

sub descriptionItems {
	my ( $class, $client, $text, $token, $always ) = @_;

	my ( $short, $shortened ) = $class->shortText($text);
	return () unless defined $short;

	my @items = ( { name => $short, type => 'textarea' } );

	if ( $shortened || $always ) {
		( my $full = $text ) =~ s/\A\s+|\s+\z//gu;
		push @items, {
			name  => cstring( $client, $token ),
			type  => 'link',
			items => [ { name => $full, type => 'textarea' } ],
		};
	}

	return @items;
}

# Whitespace runs -> one space, trimmed.
sub _collapse {
	my $text = shift;
	$text =~ s/\s+/ /gu;
	$text =~ s/\A | \z//g;
	return $text;
}

# $text (one paragraph, longer than $max) cut to at most $max characters, ending in an ellipsis.
sub _cutText {
	my ( $text, $max ) = @_;

	# the last sentence end within $max - 2 (room for " …"), if it keeps at least half of $max
	my $sentence;
	while ( $text =~ /(?:[.!?\x{2026}]+[\x{2019}\x{201D}"')\]]*(?=\s)|[\x{3002}\x{FF01}\x{FF1F}][\x{300D}\x{300F}\x{FF09}]*)/g ) {
		my $end = pos($text);
		last if $end > $max - 2;
		$sentence = $end unless _notSentenceEnd( substr( $text, 0, $end ) );
	}
	pos($text) = undef;    # the loop may stop part-way: later //g matches must start at 0

	if ( defined $sentence && $sentence >= $max / 2 ) {
		my $head = substr( $text, 0, $sentence );
		return $head . ( $head =~ /[\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]\z/ ? '' : ' ' ) . ELLIPSIS;
	}

	# else the last word boundary within $max - 1 (room for "…"): before a space, or beside a
	# Chinese or Japanese character (never before a combining mark)
	my $limit = $max - 1;
	if ( $text =~ /\A(.{1,$limit})(?:(?=\s)|(?=$CJK)|(?<=$CJK))(?!\p{Grapheme_Extend})/su ) {
		( my $head = $1 ) =~ s/[\s,;:\p{Pd}\p{Ps}\p{Pi}]+\z//u;
		return $head . ELLIPSIS if length $head;
	}

	# a single word longer than that: cut at a character (grapheme) boundary
	my $head = '';
	pos($text) = undef;
	while ( $text =~ /(\X)/g ) {
		last if length($head) + length($1) > $limit;
		$head .= $1;
	}

	return $head . ELLIPSIS;
}

# Whether the full stop that ends $prefix belongs to initials ("R.A.", "J.") or an abbreviation.
sub _notSentenceEnd {
	my $prefix = shift;
	return 0 unless $prefix =~ /\.\z/;
	return 1 if $prefix =~ /(?:\A|[\s.])\p{L}\.\z/;
	return 1 if $prefix =~ /(?:\A|\s)([\p{L}.]+)\.\z/ && $ABBREVIATION{ lc $1 };
	return 0;
}

# === end U1 ===

# ---------------------------------------------------------------------------
# Program menu
# ---------------------------------------------------------------------------

sub _programMenu {
	my ( $client, $cb, $args, $program ) = @_;
	my $once = _once($cb);

	$program = {} unless ref $program eq 'HASH';
	my $window = _window($args);

	_try( $client, $once, sub {
		Plugins::ABCListen::Programs::program( $program->{path}, sub {
			my $detail = shift;

			return _textFeed( $client, $once, $detail->{error} ) if $detail->{error};

			_try( $client, $once, sub { _programMenuItems( $client, $once, $program, $detail, $window ) } );
		} );
	} );
}

# U2: the rows LMS asks a feed for, { index, quantity }, from XMLBrowser's index/quantity args (the
# slice it lists, with up to 10 rows before it; or the row it opens, quantity 1); undef without them
# (playlist commands, other callers): the whole list.
sub _window {
	my $args = shift;
	return undef unless ref $args eq 'HASH';

	my ($index)    = defined $args->{index}    && !ref $args->{index}    ? $args->{index}    =~ /\A([0-9]+)/   : ();
	my ($quantity) = defined $args->{quantity} && !ref $args->{quantity} ? $args->{quantity} =~ /\A([0-9]+)\z/ : ();
	return undef unless defined $index && defined $quantity && $quantity > 0;

	return { index => $index + 0, quantity => $quantity + 0 };
}

# Header, provider extras, then the episodes as one list (U2): only the rows of the window, from the
# ABC pages of EPISODE_PAGE episodes that hold them, as a partial feed { items, offset, total }.
# Page 0 (it gives the total) and the window's other pages, estimated from the header alone, load
# with the providers, at most PAGE_CONCURRENCY at a time. Then, round by round (at most
# MAX_ROUNDS): a page the estimate missed (provider rows, or more episodes than the program page
# said), page 0's first SUB_PAGE episodes when page 0 failed (for the total), and the window's
# SUB_PAGE pages of a page that failed (U2 review: ABC fails some pages of 50 every time while
# their pages of 10 load).
sub _programMenuItems {
	my ( $client, $cb, $program, $detail, $window ) = @_;

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

	my %pages;    # "offset/size" => Programs::episodes' answer
	my ( $extras, @lead );
	my ( $pending, $rounds ) = ( 2, 0 );

	my $step;
	$step = sub {
		_try( $client, $cb, sub {
			# the rows before the episodes, now that the number of episodes is known
			my $count = _episodeCount( \%pages, $detail );
			@lead = ( _programHeader( $client, $detail, @$extras + ( $count || 1 ) ), @$extras );

			my @wanted = defined $context->{collectionId} && $rounds++ < MAX_ROUNDS ? _wantedPages( \%pages, scalar @lead, $window, $count || 0 ) : ();
			return _fetchPages( $context, \@wanted, \%pages, $step ) if @wanted;

			undef $step;    # done: break the closure's reference to itself
			_respondWindow( $client, $cb, sub { _programWindow( $client, $context, $detail, \@lead, \%pages, $window ) } );
		} );
	};

	my $done = sub { $step->() unless --$pending };

	_runProviders( $client, \%merged, sub {
		$extras = shift;
		$done->();
	} );

	if ( defined $context->{collectionId} ) {
		# the program page's count of episodes (unknown: one page) and the header alone
		my $estimate = $detail->{total} || EPISODE_PAGE;
		my @header   = _programHeader( $client, $detail, $estimate );
		_fetchPages( $context, [ _wantedPages( \%pages, scalar @header, $window, $estimate ) ], \%pages, $done );
	}
	else {
		$done->();
	}
}

# Description (U1: the short textarea, then "About this program" when shortened), "Presented by
# ...", network; each only when known. $after: how many rows follow the header (provider rows,
# episodes).
#   - U2: when the rows after the textarea reach LONG_LIST (100), "About this program" is there even
#     for a short description: Material shows the window header (the textarea) only for lists of
#     fewer than 100 rows (its LMS_MAX_NON_SCROLLER_ITEMS).
#   - U2 review: no leading textarea when the whole menu has more than JIVE_CHUNK (200) rows.
#     SqueezePlay, Jive players and jivelite (piCorePlayer) ask for 200 rows at a time; in menu
#     mode LMS's XMLBrowser takes the textarea out of the chunk that holds it and counts one row
#     fewer there, and their DB.lua drops everything it has whenever the count changes, so they
#     re-requested both chunks forever. Without the textarea every chunk counts the same. "About
#     this program" (there from 100 rows on) still opens the description.
sub _programHeader {
	my ( $client, $detail, $after ) = @_;

	my @presenters = grep { _hasText($_) } @{ ref $detail->{presenters} eq 'ARRAY' ? $detail->{presenters} : [] };
	my @rows;
	push @rows, { name => cstring( $client, 'PLUGIN_ABCLISTEN_PRESENTED_BY', join( ', ', @presenters ) ), type => 'text' } if @presenters;
	push @rows, { name => $detail->{network}, type => 'text' } if _hasText( $detail->{network} );

	my $rest = @rows + ( $after || 0 );
	my @description = __PACKAGE__->descriptionItems( $client, $detail->{description}, 'PLUGIN_ABCLISTEN_ABOUT_PROGRAM', $rest >= LONG_LIST );
	shift @description if @description && @description + $rest > JIVE_CHUNK;

	return ( @description, @rows );
}

sub _pageKey { join '/', @_ }

# How many episodes the list has: the total (ABC's, at most 250) of page 0, else of page 0's first
# SUB_PAGE episodes; 0 when the one that answered has no episodes. Before either has answered: the
# program page's count (an estimate). undef when both failed.
sub _episodeCount {
	my ( $pages, $detail ) = @_;

	for my $key ( _pageKey( 0, EPISODE_PAGE ), _pageKey( 0, SUB_PAGE ) ) {
		my $page = $pages->{$key};
		next unless $page && !$page->{error};
		return @{ $page->{items} || [] } ? $page->{total} || 0 : 0;
	}

	return undef if $pages->{ _pageKey( 0, EPISODE_PAGE ) } && $pages->{ _pageKey( 0, SUB_PAGE ) };
	return $detail->{total} || 0;
}

# The episode pages ("offset/size" keys) %$pages still needs for a window when $lead rows come
# before $count episodes: page 0 (it gives the total), its first SUB_PAGE episodes when page 0
# failed, the pages of the episodes in the window (the whole list without a window), and, for a
# page that failed, the window's SUB_PAGE pages within it.
sub _wantedPages {
	my ( $pages, $lead, $window, $count ) = @_;

	my @wanted = ( _pageKey( 0, EPISODE_PAGE ) );
	my $first  = $pages->{ $wanted[0] };
	push @wanted, _pageKey( 0, SUB_PAGE ) if $first && $first->{error};

	my ( $from, $to ) = _episodeRange( $lead, $window, $count );
	for my $page ( $from < $to ? int( $from / EPISODE_PAGE ) .. int( ( $to - 1 ) / EPISODE_PAGE ) : () ) {
		my $key = _pageKey( $page * EPISODE_PAGE, EPISODE_PAGE );
		push @wanted, $key;
		next unless $pages->{$key} && $pages->{$key}->{error};

		my $lo = $from > $page * EPISODE_PAGE ? $from : $page * EPISODE_PAGE;
		my $hi = $to < ( $page + 1 ) * EPISODE_PAGE ? $to : ( $page + 1 ) * EPISODE_PAGE;
		push @wanted, map { _pageKey( $_ * SUB_PAGE, SUB_PAGE ) } int( $lo / SUB_PAGE ) .. int( ( $hi - 1 ) / SUB_PAGE );
	}

	my %seen;
	return grep { !$pages->{$_} && !$seen{$_}++ } @wanted;
}

# The episode indexes [first, last) a window shows when $lead rows come before $count episodes.
sub _episodeRange {
	my ( $lead, $window, $count ) = @_;

	my ( $from, $to ) = $window ? ( $window->{index}, $window->{index} + $window->{quantity} ) : ( 0, $lead + $count );
	my $first = $from > $lead ? $from - $lead : 0;
	my $last  = $to > $lead ? $to - $lead : 0;
	$last = $count if $last > $count;

	return $first < $last ? ( $first, $last ) : ( 0, 0 );
}

# Load the episode pages ("offset/size" keys) in @$wanted that %$pages doesn't hold yet
# (Programs::episodes: its cache and coalescing), at most PAGE_CONCURRENCY at a time, each answer
# (an error too) into $pages->{key}; $cb->() once, when all have answered. U2 review: a page that
# failed is remembered for FAILURE_TTL (60 s) and not asked for again meanwhile (ABC fails some
# pages every time, and API.pm caches only answers).
sub _fetchPages {
	my ( $context, $wanted, $pages, $cb ) = @_;

	my $cache = Slim::Utils::Cache->new( Plugins::ABCListen::Util::CACHE_NAMESPACE );
	my @queue = grep { !$pages->{$_} } @$wanted;
	my ( $active, $finished, $pumping, $pump ) = ( 0, 0, 0 );

	$pump = sub {
		return if $pumping;
		$pumping = 1;

		while ( $active < PAGE_CONCURRENCY && @queue ) {
			my $key = shift @queue;
			my ( $offset, $size ) = split m{/}, $key;
			my $failKey = "episodesFailed/$context->{collectionId}/$key";

			if ( my $error = $cache->get($failKey) ) {
				$pages->{$key} = { error => $error };
				next;
			}

			my $settled = 0;
			$active++;

			my $done = sub {
				return if $settled++;
				my $result = ref $_[0] eq 'HASH' ? $_[0] : { error => LOAD_FAILED };
				$cache->set( $failKey, $result->{error}, FAILURE_TTL ) if $result->{error};
				$pages->{$key} = $result;
				$active--;
				$pump->() if $pump;
			};

			eval { Plugins::ABCListen::Programs::episodes( $context->{collectionId}, $offset, $size, $done ); 1 } or do {
				$log->error( 'Loading ABC listen episodes failed: ' . ( $@ || 'unknown error' ) );
				$done->( { error => LOAD_FAILED } );
			};
		}

		$pumping = 0;

		if ( !$active && !@queue && !$finished++ ) {
			undef $pump;    # every page answered: break the closure's reference to itself
			$cb->();
		}

		return;
	};

	$pump->();
	return;
}

# The program menu's rows in the window, { items, offset, total }. The list: the lead rows (header,
# provider extras), then
#   - no episode collection: "No episodes available", except for a restricted program (ABC's
#     audiobooks: D5's provider lists the chapters) that has lead rows: never an empty list;
#   - page 0 (and its first SUB_PAGE episodes) failed: page 0's error text; no episodes: "No
#     episodes available";
#   - else the episodes, newest first, to page 0's total (_episodeWindow).
sub _programWindow {
	my ( $client, $context, $detail, $lead, $pages, $window ) = @_;

	my $count = defined $context->{collectionId} ? _episodeCount( $pages, $detail ) : 0;

	my @tail;
	if ( !defined $context->{collectionId} ) {
		@tail = _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' ) unless $detail->{restricted} && @$lead;
	}
	elsif ( !defined $count ) {
		@tail = _textItem( $client, $pages->{ _pageKey( 0, EPISODE_PAGE ) }->{error} );
	}
	elsif ( !$count ) {
		@tail = _textItem( $client, 'PLUGIN_ABCLISTEN_NO_EPISODES' );
	}
	else {
		return _episodeWindow( $client, $context, $lead, $pages, $window, $count );
	}

	my @all = ( @$lead, @tail );
	my ( $from, $to ) = $window ? ( $window->{index}, $window->{index} + $window->{quantity} ) : ( 0, scalar @all );
	$to = @all if $to > @all;

	return { items => [ $from < $to ? @all[ $from .. $to - 1 ] : () ], offset => $from, total => scalar @all };
}

# The rows of the window when $count episodes follow the lead rows: total = lead + $count, the same
# for every window (U2 review: SqueezePlay/jivelite drop their rows when it changes, and the web UI
# pages by it). Row i is always the same episode (or placeholder) while ABC's pages are cached.
sub _episodeWindow {
	my ( $client, $context, $lead, $pages, $window, $count ) = @_;

	my $total = @$lead + $count;
	my ( $from, $to ) = $window ? ( $window->{index}, $window->{index} + $window->{quantity} ) : ( 0, $total );
	$to = $total if $to > $total;

	my @items = map { $_ < @$lead ? $lead->[$_] : _episodeRow( $client, $context, $pages, $_ - @$lead ) } $from < $to ? $from .. $to - 1 : ();

	return { items => \@items, offset => $from, total => $total };
}

# Episode n's row: its episodeItem, from its page of EPISODE_PAGE, else (that page failed) from its
# page of SUB_PAGE. A placeholder text row keeps the position otherwise: the failed page's error text
# (LOAD_FAILED, RATE_LIMITED), or "Episode unavailable" where ABC's page holds fewer episodes than
# its total said (a card that isn't an episode, or a list that shrank).
sub _episodeRow {
	my ( $client, $context, $pages, $n ) = @_;

	my $page = $pages->{ _pageKey( int( $n / EPISODE_PAGE ) * EPISODE_PAGE, EPISODE_PAGE ) };
	my $at   = $n % EPISODE_PAGE;

	if ( !$page || $page->{error} ) {
		my $sub = $pages->{ _pageKey( int( $n / SUB_PAGE ) * SUB_PAGE, SUB_PAGE ) };
		return _textItem( $client, $sub && $sub->{error} ? $sub->{error} : $page ? $page->{error} : LOAD_FAILED ) unless $sub && !$sub->{error};
		( $page, $at ) = ( $sub, $n % SUB_PAGE );
	}

	my $episode = ( $page->{items} || [] )->[$at];
	return _textItem( $client, 'PLUGIN_ABCLISTEN_EPISODE_UNAVAILABLE' ) unless ref $episode eq 'HASH';

	my $item = eval { __PACKAGE__->episodeItem( $client, _withProgram( $context, $episode ) ) };
	return $item if ref $item eq 'HASH';

	$log->error( 'Building the ABC listen episode list failed: ' . ( $@ || "no row for episode $n" ) );
	return _textItem( $client, LOAD_FAILED );
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
	# a "Play episode" item listed before it. U1: a short synopsis, then "About this episode" when
	# it was shortened.
	push @items, __PACKAGE__->descriptionItems( $client, $episode->{description}, 'PLUGIN_ABCLISTEN_ABOUT_EPISODE' );

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

# U2: call back once with the partial feed $build returns ({ items, offset, total }: LMS lists
# items as rows offset .. offset + #items - 1 of a list of total rows), or with the LOAD_FAILED item
# if it dies.
sub _respondWindow {
	my ( $client, $cb, $build ) = @_;

	my $feed = eval { $build->() };

	if ( ref $feed ne 'HASH' || ref $feed->{items} ne 'ARRAY' ) {
		$log->error( 'Building the ABC listen programs menu failed: ' . ( $@ || 'unknown error' ) );
		return _textFeed( $client, $cb, LOAD_FAILED );
	}

	$cb->($feed);
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
