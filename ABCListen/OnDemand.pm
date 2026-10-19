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
#   All programs A–Z (O3) -> "<L> (<n>)" for A..Z, then "0–9 (<n>)", letters without programs
#   omitted -> that letter's programs (rows as in programsByType). A program's letter is the first
#   [a-z0-9] character of its Programs::sortKey (a leading "The " ignored, accents folded); a digit,
#   or no such character, files it under 0–9. In fallback mode (ProgramIndex: network lists) the
#   first item is the PLUGIN_ABCLISTEN_INDEX_FALLBACK text.
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
# Program menu (_programMenu) order: description (textarea) · "Presented by A, B" · network
# (Programs->program attribution title) · provider extras · the newest 50 episodes · "More
# episodes…" (the next 50, to ABC's 250). No episodes: "No episodes available", except for a
# restricted program without an episode collection (an ABC audiobook: D5's provider lists its
# chapters) that has a header row or provider extras to show: the menu is never empty, so with
# none of those it is "No episodes available" too. Episode rows get programImage, and
# programTitle/programId only when the episode path is under the program path
# ('<program path>/...'); otherwise O1 fills them at play time.
#
# Episode menu (_episodeMenu; O4 extends it): synopsis (textarea) · "Play episode" (type audio,
# favourites keep the abclisten:// URL) · "Broadcast <date> · <duration>". The textarea must stay
# first (Slim::Control::XMLBrowser's menu mode replaces item 0 with an empty item when it moves a
# textarea into the window), so items O4 adds go after it.
#
# Ownership: O2 creates everything; O3 then owns _programsRoot, O4 owns episodeItem/_episodeMenu;
# programItem, _programMenu and the provider registry stay with O2.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ABCListen::API;
use Plugins::ABCListen::ProgramIndex;
use Plugins::ABCListen::Programs;
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
use constant DIGITS         => '0-9';    # the A–Z bucket of programs not starting with a letter

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
	my $once = _once($cb);

	eval {
		if ( !( defined $typeKey && !ref $typeKey && $TYPE_LABEL{$typeKey} ) ) {
			$log->warn( 'programsByType: unknown program type ' . ( defined $typeKey ? "'$typeKey'" : 'undef' ) );
			$once->( [ _textItem( $client, LOAD_FAILED ) ] );
			return 1;
		}

		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			my $items = eval {
				return [ _textItem( $client, LOAD_FAILED ) ]    if $index->{error};
				return [ _textItem( $client, INDEX_FALLBACK ) ] if $index->{fallback};    # types are unknown

				my @refs = grep { Plugins::ABCListen::ProgramIndex::typeKey( $_->{programType} ) eq $typeKey } @{ $index->{items} };
				return @refs ? _programRows( $client, \@refs ) : [ _textItem( $client, NO_PROGRAMS ) ];
			};

			if ( ref $items ne 'ARRAY' ) {
				$log->error( 'Building the ABC listen programs menu failed: ' . ( $@ || 'unknown error' ) );
				$items = [ _textItem( $client, LOAD_FAILED ) ];
			}

			$once->($items);
		} );

		1;
	} or do {
		$log->error( 'programsByType failed: ' . ( $@ || 'unknown error' ) );
		eval { $once->( [ _textItem( $client, LOAD_FAILED ) ] ); 1 } or $log->error( 'programsByType callback failed: ' . ( $@ || 'unknown error' ) );
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
				my %count;
				$count{ _bucket($_) }++ for @{ $index->{items} };

				my @items;
				push @items, _textItem( $client, INDEX_FALLBACK ) if $index->{fallback};

				for my $bucket ( grep { $count{$_} } 'a' .. 'z', DIGITS ) {
					push @items, {
						name        => ( $bucket eq DIGITS ? '0' . ENDASH . '9' : uc $bucket ) . " ($count{$bucket})",
						type        => 'link',
						url         => \&_letterFeed,
						passthrough => [$bucket],
						image       => Plugins::ABCListen::Util::ICON,
					};
				}

				return \@items;
			} );
		} );
	} );
}

# One letter's programs.
sub _letterFeed {
	my ( $client, $cb, $args, $bucket ) = @_;
	my $once = _once($cb);

	_try( $client, $once, sub {
		Plugins::ABCListen::ProgramIndex::programs( sub {
			my $index = shift;

			return _textFeed( $client, $once, LOAD_FAILED ) if $index->{error};

			_respond( $client, $once, sub {
				my @refs = grep { defined $bucket && _bucket($_) eq $bucket } @{ $index->{items} };
				return @refs ? _programRows( $client, \@refs ) : [ _textItem( $client, NO_PROGRAMS ) ];
			} );
		} );
	} );
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

# A program's A–Z bucket: the first [a-z0-9] character of its sort key; digits and titles
# without one -> DIGITS.
sub _bucket {
	my ($char) = Plugins::ABCListen::Programs::sortKey( _indexTitle(shift) ) =~ /([a-z0-9])/;
	return defined $char && $char =~ /[a-z]/ ? $char : DIGITS;
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
	$episode = {} unless ref $episode eq 'HASH';

	_respond( $client, $cb, sub {
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

		return \@items;
	} );
}

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
