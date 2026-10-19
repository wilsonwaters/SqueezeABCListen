package Plugins::ABCListen::OnDemand;

# Programs and episodes hook (hook API: see Plugin.pm) and the on-demand builders every stream uses
# for program and episode rows (ai-state/streams.md contract 6). Data: Plugins::ABCListen::Programs.
#
# init loads and initialises Plugins::ABCListen::Episode (episode playback, O1), so O1 fills
# Episode.pm and never edits this file.
#
# Menus: top level "Programs" (weight Util::topWeight('programs'), declared in menuWeights)
#   -> _programsRoot: "By network" (O3 adds A-Z and By type and owns _programsRoot from then on)
#   -> the networks (Programs::networks order) -> the network's programs (programItem rows)
#   -> _programMenu -> episodes (episodeItem rows) -> _episodeMenu.
# Every feed (a coderef url, called as ($client, $cb, $args, @passthrough)) calls
# $cb->({ items => [...] }) exactly once: on success, when empty, on error (one readable text item:
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

# Programs: "By network" (O3 adds A-Z and By type here).
sub _programsRoot {
	my ( $client, $cb, $args ) = @_;

	_respond( $client, $cb, sub {
		return [ {
			name  => cstring( $client, 'PLUGIN_ABCLISTEN_BY_NETWORK' ),
			type  => 'link',
			url   => \&_networksFeed,
			image => Plugins::ABCListen::Util::ICON,
		} ];
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
