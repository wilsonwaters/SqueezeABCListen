#!/usr/bin/perl
# scripts/smoke.sh against a small fake LMS JSON-RPC server on 127.0.0.1 (no real LMS, no
# network): --help, bad arguments, missing tools, unreachable or password-protected servers,
# unknown or ambiguous players (exit 2), a server without the plugin (exit 1, checks 3-15 fail, the
# player is left alone), and scripted runs through fake ABC listen menus: a full pass (15/15),
# --skip-live (3 SKIP lines), a stuck live stream, a home state's time-zone version, geo-blocked
# episodes, a station found only by URL, a rate-limited search, an already-followed program, a
# restore of the followed programs that doesn't take, and an interrupted follow check (the
# followed programs are put back); the temporary directory with the credentials is always removed. The fake player's time runs faster than the clock, and the
# test-only SMOKE_* timing overrides shorten the waits, so the file runs in well under a minute.
# The real pass needs a real LMS and player: see the README's Self-test section. Needs curl and jq
# (CI installs them).

use strict;
use utf8;
use warnings;

use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Test::More;
use Time::HiRes qw(time sleep);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

for my $tool (qw(bash curl jq)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

# requests to the fake server must not go through a proxy
delete @ENV{qw(http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY LMS_URL PLAYER LMS_USER LMS_PASS)};
delete $ENV{$_} for grep {/^SMOKE_/} keys %ENV;

my $DIR    = tempdir( CLEANUP => 1 );
my $SCRIPT = 'scripts/smoke.sh';
my $JSON   = JSON::PP->new->canonical->utf8;

# short waits for the fake player (its time runs 20 times faster than the clock, so 0.3 s of
# waiting is 6 s of playing)
my %FAST = (
	SMOKE_LIVE_START_S     => 3,
	SMOKE_LIVE_WINDOW_S    => '0.3',
	SMOKE_META_WAIT_S      => 1,
	SMOKE_EPISODE_START_S  => 3,
	SMOKE_EPISODE_WINDOW_S => '0.3',
	SMOKE_SEEK_WAIT_S      => 2,
	SMOKE_STOP_GRACE_S     => 0,
	SMOKE_POLL_S           => '0.05',
	SMOKE_CURL_TIMEOUT_S   => 5,
);

my $DEV   = { playerid => '00:00:00:00:00:01', name => 'DevPlayer', connected => 1, power => 1 };
my $OTHER = { playerid => 'aa:bb:cc:dd:ee:ff', name => 'Kitchen',   connected => 1, power => 0 };
my $GONE  = { playerid => '00:04:20:00:00:02', name => 'Old Boom',  connected => 0, power => 0 };
my $RADIOS = [ { cmd => 'presets', name => 'My Presets', type => 'xmlbrowser' }, { cmd => 'abclisten', name => 'ABC listen', type => 'xmlbrowser' } ];

# run smoke.sh with @args (and %env); returns { code, out, err, secs }
sub smoke { return smoke_all( [@_] )->[0] }

# smoke_all([\@args, %opt], ...): several smoke.sh runs at the same time (each against its own fake
# LMS), to keep this file fast; returns their results in order
my $RUN = 0;
sub smoke_all {
	my @procs;
	for my $run (@_) {
		my ( $args, %opt ) = @$run;
		my $errfile = "$DIR/stderr-" . $RUN++;
		my $pid     = open( my $fh, '-|' ) // die "fork: $!";
		if ( !$pid ) {
			open( STDERR, '>', $errfile ) or die;
			$ENV{$_} = $opt{env}->{$_} for keys %{ $opt{env} || {} };
			exec( $opt{bash} || 'bash', $SCRIPT, @$args ) or die "exec: $!";
		}
		binmode( $fh, ':encoding(UTF-8)' );
		push @procs, { fh => $fh, args => $args, errfile => $errfile, start => time };
	}
	my @results;
	for my $p (@procs) {
		my $out = do { local $/; readline( $p->{fh} ) } // '';
		close $p->{fh};
		my $code = $? >> 8;
		open( my $efh, '<:encoding(UTF-8)', $p->{errfile} ) or die;
		my $err = do { local $/; <$efh> } // '';
		close $efh;
		my $secs = time - $p->{start};
		note( sprintf( 'smoke.sh %s: exit %d in %.1f s', join( ' ', @{ $p->{args} } ), $code, $secs ) );
		push @results, { code => $code, out => $out, err => $err, secs => $secs };
	}
	return \@results;
}

# the check lines of an output: "PASS 1", "SKIP 6", ...
sub verdicts { [ map { /^(PASS|FAIL|SKIP)  (\d+)\./ ? "$1 $2" : () } split /\n/, $_[0] ] }

# ---------------------------------------------------------------------------------------------
# A fake LMS. It answers serverstatus, players, pref (plugin state; the followed-programs pref,
# get and set), radios, power/stop/playlist clear/time, status, and - when it has the plugin -
# "abclisten items" (plain and menu:1) and "abclisten playlist play" over a small ABC listen menu
# tree, plus "playlist play abclisten://live/<ID>". Any other command gets no answer, like LMS
# without the plugin. Returns (url, stop, commands, followed).
# ---------------------------------------------------------------------------------------------

my %STATIONS = (
	TRIPLEJ      => 'triple j',
	TRIPLEJ_BRISBANE => 'triple j Brisbane',
	RN           => 'Radio National',
	LOCAL_SYDNEY => '702 ABC Sydney',
	LOCAL_MELB   => 'ABC Melbourne',
	KIDSLISTEN   => 'ABC KIDS listen',
);

sub fake_lms {
	my %opt = @_;
	$opt{speed} //= 20;
	my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 16, ReuseAddr => 1 ) or die "listen: $!";
	my $port  = $server->sockport;
	my $log   = "$DIR/commands-$port.log";
	my $state = "$DIR/followed-$port.json";

	my $pid = fork // die "fork: $!";
	if ( !$pid ) {
		local $SIG{PIPE} = 'IGNORE';    # a client that gave up waiting (curl timeout) has closed its socket
		my $lms = FakeLMS->new( %opt, statefile => $state );
		while ( my $c = $server->accept ) {
			my ( %h, $line );
			my $request = <$c>;
			while ( defined( $line = <$c> ) && $line =~ /\S/ ) {
				$h{ lc $1 } = $2 if $line =~ /^([^:]+):\s*(.*?)\r?$/;
			}
			my $body = '';
			read( $c, $body, $h{'content-length'} || 0 );

			if ( $opt{auth} && ( $h{authorization} || '' ) ne 'Basic ' . encode_base64( $opt{auth}, '' ) ) {
				print $c "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"LMS\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
				close $c;
				next;
			}

			my $req = eval { $JSON->decode($body) } || {};
			my ( $player, $cmd ) = @{ $req->{params} || [] };
			open( my $lfh, '>>', $log ) or die;
			print $lfh $JSON->encode( [ $player, $cmd ] ), "\n";
			close $lfh;

			my $result = eval { $lms->handle( $player, $cmd ) };
			warn "fake LMS: $@" if $@;
			if ($result) {
				my $json = $JSON->encode( { id => 1, method => 'slim.request', params => $req->{params}, result => $result } );
				print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . length($json) . "\r\nConnection: close\r\n\r\n$json";
			}
			close $c;
		}
		exit 0;
	}
	close $server;

	my $stop = sub { kill 'TERM', $pid; waitpid( $pid, 0 ) };
	my $commands = sub {
		open( my $fh, '<', $log ) or return ();
		my @c = map { $JSON->decode($_) } <$fh>;
		close $fh;
		return @c;
	};
	my $followed = sub {
		open( my $fh, '<', $state ) or return undef;
		local $/;
		my $json = <$fh>;
		close $fh;
		return $JSON->decode($json);
	};
	return ( "http://127.0.0.1:$port", $stop, $commands, $followed );
}

# the commands that change the player
sub touching { grep { ref $_->[1] eq 'ARRAY' && ( $_->[1][0] =~ /^(?:power|playlist|stop|time)$/ || ( $_->[1][0] eq 'abclisten' && ( $_->[1][1] // '' ) eq 'playlist' ) ) } @_ }

package FakeLMS;

sub new {
	my ( $class, %opt ) = @_;
	my $self = bless { %opt, followed => $opt{followed} // [], playing => undef, episodePlays => 0 }, $class;
	$self->{players} //= [$DEV];
	$self->{power} = { map { lc $_->{playerid} => $_->{power} } @{ $self->{players} } };
	$self->_saveFollowed;
	return $self;
}

sub _saveFollowed {
	my $self = shift;
	open( my $fh, '>', $self->{statefile} ) or die;
	print $fh $JSON->encode( $self->{followed} );
	close $fh;
}

sub handle {
	my ( $self, $player, $cmd ) = @_;
	return undef unless ref $cmd eq 'ARRAY';
	my $name = $cmd->[0] // '';

	return { version => '9.1.1', 'player count' => scalar @{ $self->{players} } } if $name eq 'serverstatus';
	return { count => scalar @{ $self->{players} }, players_loop => $self->{players} } if $name eq 'players';
	return { count => scalar @{ $self->{radios} || [] }, radioss_loop => $self->{radios} || [] } if $name eq 'radios';

	if ( $name eq 'pref' ) {
		if ( ( $cmd->[1] // '' ) eq 'plugin.abclisten:followed' ) {
			if ( ( $cmd->[2] // '' ) eq '?' && ( my $other = delete $self->{pre_change} ) ) {
				# another client follows a program right after this read; the next menu request is
				# answered late (the test interrupts smoke.sh meanwhile)
				my $snapshot = $JSON->decode( $JSON->encode( $self->{followed} ) );
				push @{ $self->{followed} }, $other;
				$self->_saveFollowed;
				$self->{hang} = 2;
				open( my $fh, '>', "$self->{statefile}.changed" ) or die;
				close $fh;
				return { _p2 => $snapshot };
			}
			if ( ( $cmd->[2] // '' ) eq '?' ) {
				Time::HiRes::sleep( delete $self->{hang_pref} ) if $self->{hang_pref};    # see hang_pref_after_follow
				return { _p2 => $self->{followed} };
			}
			return {} if $self->{ignore_pref_set};    # LMS answers, but the followed programs stay as they are
			$self->{followed} = $cmd->[2];
			$self->_saveFollowed;
			return {};
		}
		return { _p2 => $self->{state} };
	}

	return $self->_player( $cmd ) if $name =~ /^(?:power|stop|playlist|time|status)$/;

	return undef unless $self->{plugin};
	return $self->_items( $cmd ) if $name eq 'abclisten' && ( $cmd->[1] // '' ) eq 'items';
	return $self->_play( $self->_resolve( map { /^item_id:(.*)/ ? $1 : () } @$cmd ) ) if $name eq 'abclisten' && ( $cmd->[1] // '' ) eq 'playlist';
	return undef;
}

# ---- the player ----

sub _player {
	my ( $self, $cmd ) = @_;
	my $name = $cmd->[0];
	my $p    = $self->{playing};

	if ( $name eq 'power' ) { $self->{power}->{dev} = $cmd->[1]; return {} }
	if ( $name eq 'stop' ) { $p->{mode} = 'stop' if $p; return {} }
	if ( $name eq 'time' ) {
		@$p{qw(offset at)} = ( $cmd->[1], Time::HiRes::time() ) if $p;
		$p->{frozen} = 1 if $p && $self->{seek_stuck} && $self->{seek_stuck}--;    # the first seek(s) land on the target, then time never moves
		return {};
	}
	if ( $name eq 'playlist' ) {
		my $sub = $cmd->[1] // '';
		if ( $sub eq 'clear' ) { $self->{playing} = undef; return {} }
		if ( $sub eq 'play' && ( $cmd->[2] // '' ) =~ m{\Aabclisten://live/([A-Z0-9_]+)\z} ) {
			return {} unless $self->{plugin};
			return $self->_play( $STATIONS{$1} ? { station => $1, name => $STATIONS{$1} } : { station => $1, name => $1, unknown => 1 } );
		}
		return {};
	}

	# status
	return { mode => 'stop', time => 0, playlist_tracks => 0 } unless $p;
	my $real    = Time::HiRes::time() - $p->{at};
	my $elapsed = $p->{frozen} ? 0 : $real * $self->{speed};
	my $mode    = $p->{dead} ? 'stop' : $p->{mode};
	my $time    = $mode ne 'play' ? 0 : $p->{station} && ( $self->{stuck} // '' ) eq $p->{station} ? 0.4 : $p->{offset} + $elapsed;
	# a station shows its own title (or pre_title) until the plugin has metadata (after meta_after
	# seconds; never for the stations in no_meta), then a song
	my $title = $p->{station} && defined $self->{pre_title} ? $self->{pre_title} : $p->{name};
	$title = 'Some Song' if $p->{station} && $mode eq 'play' && !( grep { $_ eq $p->{station} } @{ $self->{no_meta} || [] } ) && $real >= ( $self->{meta_after} // 0 );
	return {
		mode            => $mode,
		time            => $time,
		( $p->{duration} ? ( duration => $p->{duration} ) : () ),
		playlist_tracks => 1,
		playlist_loop   => [ { 'playlist index' => 0, id => -1, title => $title } ],
	};
}

sub _play {
	my ( $self, $item ) = @_;
	return {} unless $item;
	my $p = { mode => 'play', at => Time::HiRes::time(), offset => 0, name => $item->{title} // $item->{name} };
	if ( $item->{station} ) {
		$p->{station} = $item->{station};
		$p->{dead}    = 1 if $item->{unknown};
	}
	elsif ( $item->{episode} ) {
		$p->{duration} = 1800;
		$p->{dead}     = 1 if ++$self->{episodePlays} <= ( $self->{geo} // 0 );
	}
	else {
		return {};
	}
	$self->{playing} = $p;
	return { count => 1 };
}

# ---- the menus ----

sub _link { my ( $name, $kids, %more ) = @_; return { name => $name, type => 'link', kids => $kids, %more } }
sub _text { return { name => $_[0], type => 'text' } }
# a station row, named after the station or (name => ...) after its network, as Radio's rows are when
# they play a home state's time-zone version
sub _station {
	my ( $id, %more ) = @_;
	my %s = ( station => $id, title => $STATIONS{$id} );
	return { name => $more{name} // $STATIONS{$id}, type => 'playlist', isaudio => 1, %s, kids => sub { [ { name => 'Listen live', type => 'audio', isaudio => 1, %s } ] } };
}
sub _episode { return { name => $_[0], type => 'link', isaudio => 1, episode => 1, kids => sub { [ { name => 'Play episode', type => 'audio', isaudio => 1, episode => 1 } ] } } }

my @PROGRAMS = (
	[ 'The Science Show', 'science-show' ],
	[ 'Late Night Live',  'late-night-live' ],
	[ 'Rear Vision',      'rear-vision' ],
);

sub _isFollowed { my ( $self, $path ) = @_; return grep { $_->{path} eq $path && !exists $_->{unfollowedAt} } @{ $self->{followed} } }

sub _program {
	my ( $self, $title, $slug ) = @_;
	my $path = "/listen/programs/$slug";
	return _link( $title, sub {
		my @follow = $self->_isFollowed($path)
			? ( _text(qq{✓ Following "$title"}), $self->_followAction( unfollow => qq{Unfollow "$title"}, $path, $title ) )
			: ( $self->_followAction( follow => qq{Follow "$title"}, $path, $title ), _text('Follow to see its new episodes in My ABC listen') );
		return [ { name => "About $title", type => 'textarea' }, _text('ABC Radio National'), @follow, map { _episode("Mon $_ Oct – $title, part $_") } 1 .. 2 ];
	} );
}

sub _followAction {
	my ( $self, $op, $name, $path, $title ) = @_;
	return _link( $name, sub {
		if ( $op eq 'follow' ) {
			my ($entry) = grep { $_->{path} eq $path } @{ $self->{followed} };
			if ($entry) { delete $entry->{unfollowedAt} }
			else        { push @{ $self->{followed} }, { path => $path, title => $title, followedAt => 1700000000 + @{ $self->{followed} } } }
			# like Follow.pm: beyond `cap` followed, the oldest follow (not this one) is unfollowed
			my @active = grep { !exists $_->{unfollowedAt} } @{ $self->{followed} };
			if ( $self->{cap} && @active > $self->{cap} ) {
				my ($oldest) = sort { $a->{followedAt} <=> $b->{followedAt} } grep { $_->{path} ne $path } @active;
				$oldest->{unfollowedAt} = 1800000000;
			}
			# another client follows a program at the same moment
			if ( my $other = delete $self->{other_follow} ) { push @{ $self->{followed} }, $other }
		}
		else {
			$_->{unfollowedAt} = 1800000000 for grep { $_->{path} eq $path } @{ $self->{followed} };
		}
		$self->_saveFollowed;
		# after the follow, the next menu request (hang_after_follow) or the next read of the followed
		# programs (hang_pref_after_follow) is answered late; the test interrupts smoke.sh meanwhile
		if ( $op eq 'follow' && ( $self->{hang_after_follow} || $self->{hang_pref_after_follow} ) ) {
			$self->{hang}      = $self->{hang_after_follow}      if $self->{hang_after_follow};
			$self->{hang_pref} = $self->{hang_pref_after_follow} if $self->{hang_pref_after_follow};
			open( my $fh, '>', "$self->{statefile}.followed" ) or die;
			close $fh;
		}
		return [ { %{ _text( $op eq 'follow' ? "Following $title" : "No longer following $title" ) }, showBriefly => 1 } ];
	} );
}

sub _top {
	my $self = shift;
	my @top = (
		_link( 'Home', sub { [ _link( 'Featured', sub { [ map { _episode("Featured $_") } 1 .. 3 ] } ), _link( 'Popular now', sub { [ _episode('Popular 1') ] } ) ] } ),
		_link( 'Radio', sub {
			[
				_station('RN'), ( $self->{home} ? _station( 'TRIPLEJ_BRISBANE', name => 'triple j' ) : _station('TRIPLEJ') ),
				_link( 'Sport',       sub { [] } ),
				_link( 'Local radio', sub { [ _link( 'New South Wales', sub { [ _station('LOCAL_SYDNEY') ] } ), _link( 'Victoria', sub { [ _station('LOCAL_MELB') ] } ) ] } ),
				_link( 'Time-zone versions', sub { [ _station('TRIPLEJ_BRISBANE') ] } ),
			];
		} ),
		_link( 'Podcasts', sub { [ _link( 'New & Noteworthy', sub { [ map { $self->_program(@$_) } @PROGRAMS[ 0, 1 ] ] } ), _link( 'Browse by category', sub { [] } ) ] } ),
		_link( 'News',  sub { [ _link( 'Latest News', sub { [] } ) ] } ),
		_link( 'Sport', sub { $self->{empty_sport} ? [ _text('Nothing here right now') ] : [ _link( 'Best of ABC Sport', sub { [] } ) ] } ),
		_link( 'Kids listen', sub { [ _station('KIDSLISTEN'), _link( 'Featured', sub { [] } ) ] } ),
		_link( 'Audiobooks',  sub { [ _link( 'Most Popular', sub { [] } ), _text('Most audiobooks play only in Australia.') ] } ),
		_link( 'Programs', sub {
			[
				_link( 'By network', sub { [ _link( 'Radio National', sub { [ map { $self->_program(@$_) } @PROGRAMS ] } ), _link( 'triple j', sub { [] } ) ] } ),
				_link( 'All programs A–Z', sub { [ _link( 'A (2)', sub { [ $self->_program( 'AM', 'am' ), $self->_program( 'All In the Mind', 'allinthemind' ) ] } ), _link( 'B (1)', sub { [] } ) ] } ),
				_link( 'By type', sub { [] } ),
			];
		} ),
		{ name => 'Search', type => 'search', search => 1 },
		_link( 'My ABC listen', sub {
			my @all    = @{ $self->{followed} };
			my @active = grep { !exists $_->{unfollowedAt} } @all;
			return [ _text('Open any program and choose Follow') ] unless @all;
			my @rows = $self->{hide_followed_rows} ? () : @all;    # a broken Followed programs list
			return [ _link( 'Latest episodes', sub { [] } ), _link( 'Followed programs (' . scalar(@active) . ')', sub { [ map { $self->_program( $_->{title}, $_->{path} =~ m{([^/]+)\z} ) } @rows ] } ) ];
		} ),
	);
	@top = map { $_->{name} eq $self->{rename_top}->[0] ? { %$_, name => $self->{rename_top}->[1] } : $_ } @top if $self->{rename_top};
	return \@top;
}

sub _kids {
	my ( $self, $item, $search ) = @_;
	if ( $item->{search} ) {
		return [] unless defined $search;
		return [ _text('ABC listen is busy right now. Please try again in a few minutes.') ] if $self->{rate_limited};
		return [ _link( 'Programs (3)', sub { [] } ), _link( 'Episodes (7)', sub { [] } ) ];
	}
	return $item->{kids} ? $item->{kids}->() : [];
}

# the item at "a.b.c", or undef
sub _resolve {
	my ( $self, $id ) = @_;
	return undef unless defined $id && $id =~ /\A\d+(?:\.\d+)*\z/;
	my @path  = split /\./, $id;
	my $items = $self->_top;
	my $item;
	while (@path) {
		$item = $items->[ shift @path ] or return undef;
		$items = $self->_kids($item) if @path;
	}
	return $item;
}

sub _items {
	my ( $self, $cmd ) = @_;
	my %p = map { /^([a-z_]+):(.*)\z/s ? ( $1 => $2 ) : () } @$cmd[ 4 .. $#$cmd ];

	if ( $self->{hang} ) {    # answer the next menu request late (the test interrupts smoke.sh meanwhile)
		Time::HiRes::sleep( delete $self->{hang} );
	}
	if ( $self->{slow_first_items} ) {    # the first menu request takes longer than curl waits
		Time::HiRes::sleep( delete $self->{slow_first_items} );
	}

	my ( $prefix, $items );
	if ( defined $p{item_id} ) {
		my $item = $self->_resolve( $p{item_id} ) or return { count => 0 };
		$items  = $self->_kids( $item, $p{search} );
		$prefix = "$p{item_id}.";
	}
	else {
		( $items, $prefix ) = ( $self->_top, '' );
	}

	my @rows = map { { %{ $items->[$_] }, id => $prefix . $_ } } 0 .. $#$items;
	if ( $p{menu} ) {
		return { count => scalar @rows, item_loop => [ map { $self->_menuRow($_) } @rows ] };
	}
	return { count => scalar @rows, loop_loop => [ map { my $r = $_; +{ id => $r->{id}, name => $r->{name}, type => $r->{type}, isaudio => $r->{isaudio} ? 1 : 0, hasitems => $r->{type} eq 'text' ? 0 : 1 } } @rows ] };
}

sub _menuRow {
	my ( $self, $r ) = @_;
	my %row = ( text => $r->{name}, type => $r->{type} );
	if ( $r->{station} ) {
		$row{text} .= "\nOn air: Some Program";
		$row{params} = { item_id => $r->{id}, isContextMenu => 1 };
		$row{presetParams} = { favorites_url => "abclisten://live/$r->{station}", favorites_title => $r->{title} // $r->{name}, favorites_type => 'audio' } unless $self->{no_presets};
	}
	elsif ( $r->{type} eq 'link' ) {
		$row{actions} = { go => { params => { item_id => $r->{id}, menu => 'abclisten' } } };
	}
	return \%row;
}

package main;

my @FULL = ( plugin => 1, state => 'enabled', radios => $RADIOS );

subtest '--help prints the usage and exits 0' => sub {
	for my $flag ( '--help', '-h' ) {
		my $r = smoke( [$flag] );
		is( $r->{code}, 0, "$flag: exit 0" );
		like( $r->{out}, qr/^Usage: scripts\/smoke\.sh \[LMS_URL\] \[PLAYER_MAC\] \[--skip-live\] \[--station <SERVICE_ID>\] \[--local <SERVICE_ID>\] \[-h\|--help\]$/m, "$flag: usage line" );
		like( $r->{out}, qr/WARNING: the test plays audio on the chosen player\. It replaces the player's queue/, "$flag: warns that it plays audio and replaces the queue" );
		like( $r->{out}, qr/--skip-live .*checks 6, 7 and 15/,       "$flag: --skip-live" );
		like( $r->{out}, qr/--station <ID> .*default TRIPLEJ/,      "$flag: --station and its default" );
		like( $r->{out}, qr/--local <ID> .*default LOCAL_SYDNEY/,   "$flag: --local and its default" );
		like( $r->{out}, qr/LMS_USER and LMS_PASS/,                 "$flag: mentions basic auth" );
		like( $r->{out}, qr/Exit codes: 0 no check failed \(skips allowed\), 1 a check failed, 2 usage, dependency or\nconnectivity error/, "$flag: exit codes" );
		like( $r->{out}, qr/15\. Kids listen live plays/,           "$flag: lists the 15 checks" );
		unlike( $r->{out}, qr/^#|set -uo/m,                         "$flag: no script lines" );
	}
	my $r = smoke( [ 'http://127.0.0.1:9', '--help' ] );
	is( $r->{code}, 0, '--help after other arguments: exit 0' );
};

subtest 'bad arguments: exit 2' => sub {
	my $r = smoke( ['localhost:9000'] );
	is( $r->{code}, 2, 'LMS_URL without http(s)://' );
	like( $r->{err}, qr/LMS_URL must look like http:\/\/host:9000/, 'says what LMS_URL should look like' );

	$r = smoke( [qw(http://127.0.0.1:9000 00:00:00:00:00:01 extra)] );
	is( $r->{code}, 2, 'too many arguments' );
	like( $r->{err}, qr/too many arguments: .*extra/, 'says so' );

	$r = smoke( [qw(http://127.0.0.1:9000 --bogus)] );
	is( $r->{code}, 2, 'unknown option' );
	like( $r->{err}, qr/unknown option: --bogus/, 'names it' );

	for my $bad ( 'triplej', 'TRIPLE J', 'TRIPLE-J', 'RN;rm', '' ) {
		$r = smoke( [ 'http://127.0.0.1:9', '--station', $bad ] );
		is( $r->{code}, 2, "--station '$bad': exit 2" );
		like( $r->{err}, qr/--station: '\Q$bad\E' is not a service id \(A-Z, 0-9 and _ only/, "--station '$bad': says why" );
		is( $r->{out}, '', "--station '$bad': no check was run" );
	}
	$r = smoke( [ 'http://127.0.0.1:9', '--local', 'local_sydney' ] );
	is( $r->{code}, 2, '--local with a lower-case id: exit 2' );
	$r = smoke( [ 'http://127.0.0.1:9', '--local' ] );
	is( $r->{code}, 2, '--local without an id: exit 2' );
	like( $r->{err}, qr/--local needs a service id/, 'says so' );
};

subtest 'missing tools: exit 2, says which' => sub {
	my $bin = "$DIR/bin";
	mkdir $bin;
	for my $tool (qw(bash sed head mktemp rm sleep)) {
		my ($path) = grep { -x "$_/$tool" } split /:/, $ENV{PATH};
		symlink( "$path/$tool", "$bin/$tool" ) if $path;
	}

	my $r = smoke( [ 'http://127.0.0.1:9', '00:00:00:00:00:01' ], bash => "$bin/bash", env => { PATH => $bin } );
	is( $r->{code}, 2, 'curl and jq missing: exit 2' );
	like( $r->{err}, qr/missing: curl jq/, 'curl and jq missing: both named' );

	my ($curl) = grep { -x "$_/curl" } split /:/, $ENV{PATH};
	symlink( "$curl/curl", "$bin/curl" );
	$r = smoke( [ 'http://127.0.0.1:9', '00:00:00:00:00:01' ], bash => "$bin/bash", env => { PATH => $bin } );
	is( $r->{code}, 2, 'jq absent from PATH: exit 2' );
	like( $r->{err}, qr/missing: jq \(needs bash 4\+, curl and jq\)/, 'jq absent from PATH: says jq' );
	is( $r->{out}, '', 'jq absent from PATH: no check was run' );
};

subtest 'unreachable LMS: exit 2 within 20 s' => sub {
	# a port nobody listens on
	my $s = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1 ) or die;
	my $port = $s->sockport;
	close $s;

	my $r = smoke( [ "http://127.0.0.1:$port", '00:00:00:00:00:01' ] );
	is( $r->{code}, 2, 'exit 2' );
	like( $r->{out}, qr/^FAIL  1\. Server reachable — no answer to \["serverstatus",0,0\] \(curl exit 7: /m, 'FAIL on check 1 with the reason' );
	unlike( $r->{out}, qr/^(?:PASS|FAIL|SKIP)  2\./m, 'no further checks' );
	like( $r->{err}, qr/can't talk to LMS at http:\/\/127\.0\.0\.1:$port/, 'says it cannot reach LMS' );
	ok( $r->{secs} < 20, sprintf( 'within 20 s (%.1f s)', $r->{secs} ) );

	$r = smoke( [], env => { LMS_URL => "http://127.0.0.1:$port/" } );
	like( $r->{out}, qr{on http://127\.0\.0\.1:$port\n}, 'LMS_URL from the environment, trailing slash dropped' );
};

subtest 'password-protected server: exit 2 with the LMS_USER hint; works with LMS_USER / LMS_PASS' => sub {
	my ( $url, $stop ) = fake_lms( players => [$DEV], auth => 'admin:s3cret' );

	my $r = smoke( [ $url, '00:00:00:00:00:01' ] );
	is( $r->{code}, 2, 'no credentials: exit 2' );
	like( $r->{out}, qr/^FAIL  1\. Server reachable — \Q$url\E asks for a password: set LMS_USER and LMS_PASS$/m, 'says to set LMS_USER and LMS_PASS' );

	$r = smoke( [ $url, '00:00:00:00:00:01' ], env => { LMS_USER => 'admin', LMS_PASS => 's3cret' } );
	like( $r->{out}, qr/^PASS  1\. Server reachable/m, 'with credentials: check 1 passes' );
	like( $r->{out}, qr/^PASS  2\. Player connected/m, 'with credentials: check 2 passes' );
	$stop->();

	# a password with quotes, a backslash and an ampersand; curl must never see it on its command line
	my $pass = q{p"a\\ss&w0rd};
	( $url, $stop ) = fake_lms( players => [$DEV], auth => "ad min:$pass" );
	my $bin = "$DIR/curlspy";
	mkdir $bin;
	my ($curl) = grep { -x "$_/curl" } split /:/, $ENV{PATH};
	open( my $fh, '>', "$bin/curl" ) or die;
	print $fh "#!/bin/sh\nprintf '%s\\n' \"\$*\" >>'$DIR/curl-args.log'\nexec '$curl/curl' \"\$@\"\n";
	close $fh;
	chmod 0755, "$bin/curl";
	$r = smoke( [ $url, '00:00:00:00:00:01' ], env => { LMS_USER => 'ad min', LMS_PASS => $pass, PATH => "$bin:$ENV{PATH}" } );
	like( $r->{out}, qr/^PASS  1\. Server reachable/m, 'quotes, backslash and & in the password: check 1 passes' );
	my $args = do { local ( @ARGV, $/ ) = "$DIR/curl-args.log"; <> } // '';
	like( $args, qr/ -K \S+\/auth\.conf /, 'curl reads the credentials from a config file' );
	unlike( $args, qr/s3cret|ss&w0rd|-u /, 'the password is never on curl\'s command line' );
	$stop->();
};

subtest 'the temporary directory with the credentials is removed: after a run, an early stop, a failed write' => sub {
	my ( $url, $stop ) = fake_lms( @FULL, auth => 'admin:s3cret' );
	my %auth = ( LMS_USER => 'admin', LMS_PASS => 's3cret' );
	my @tmp  = map { my $d = "$DIR/tmpdir-$_"; mkdir $d or die; $d } 0 .. 2;
	# a mktemp that leaves a directory where auth.conf goes, so it can't be written
	my $bin = "$DIR/mktempspy";
	mkdir $bin;
	my ($mktemp) = grep { -x "$_/mktemp" } split /:/, $ENV{PATH};
	open( my $fh, '>', "$bin/mktemp" ) or die;
	print $fh "#!/bin/sh\nd=\$('$mktemp/mktemp' \"\$@\") || exit 1\nmkdir \"\$d/auth.conf\"\necho \"\$d\"\n";
	close $fh;
	chmod 0755, "$bin/mktemp";

	my @r = @{ smoke_all(
		[ [ $url, '00:00:00:00:00:01', '--skip-live' ], env => { %FAST, %auth, TMPDIR => $tmp[0] } ],
		[ [ $url, '00:00:00:00:00:99' ], env => { %auth, TMPDIR => $tmp[1] } ],
		[ [ $url, '00:00:00:00:00:01' ], env => { %auth, TMPDIR => $tmp[2], PATH => "$bin:$ENV{PATH}" } ],
	) };
	my $left = sub { opendir( my $dh, $_[0] ) or die; return join ' ', grep { !/\A\.\.?\z/ } readdir $dh };

	is( $r[0]{code}, 0, 'a full run with credentials: exit 0' ) or diag $r[0]{out}, $r[0]{err};
	is( $left->( $tmp[0] ), '', '... its temporary directory is gone' );
	is( $r[1]{code}, 2, 'an unknown player: exit 2' );
	is( $left->( $tmp[1] ), '', '... its temporary directory is gone' );
	is( $r[2]{code}, 2, 'auth.conf can\'t be written: exit 2' );
	like( $r[2]{err}, qr/smoke: can't write \Q$tmp[2]\E\/\S+\/auth\.conf$/m, '... says so' );
	is( $left->( $tmp[2] ), '', '... its temporary directory is gone' );
	$stop->();
};

subtest 'unknown or ambiguous player: exit 2, players listed, player untouched' => sub {
	my ( $url, $stop, $commands ) = fake_lms( players => [ $DEV, $GONE ] );

	my $r = smoke( [ $url, '00:00:00:00:00:99' ] );
	is( $r->{code}, 2, 'unknown player: exit 2' );
	like( $r->{out}, qr/^PASS  1\. Server reachable — LMS 9\.1\.1 at \Q$url\E$/m,                    'check 1 passes' );
	like( $r->{out}, qr/^FAIL  2\. Player connected — 00:00:00:00:00:99 is not a connected player$/m, 'check 2 fails' );
	like( $r->{err}, qr/^  00:00:00:00:00:01  DevPlayer  connected=1$/m, 'lists the connected player' );
	like( $r->{err}, qr/^  00:04:20:00:00:02  Old Boom  connected=0$/m,  'and the disconnected one' );

	$r = smoke( [ $url, '00:04:20:00:00:02' ] );
	is( $r->{code}, 2, 'a known but disconnected player: exit 2' );
	$r = smoke( [ $url, '00:00:00:00:00:99' ], env => { PLAYER => '00:00:00:00:00:01' } );
	is( $r->{code}, 2, 'the argument wins over $PLAYER' );
	is( scalar( touching( $commands->() ) ), 0, 'the player was not touched' );
	$stop->();

	( $url, $stop ) = fake_lms( players => [ $DEV, $OTHER ] );
	$r = smoke( [$url] );
	is( $r->{code}, 2, 'two connected players, none given: exit 2' );
	like( $r->{out}, qr/^FAIL  2\. Player connected — 2 players connected and none chosen$/m, 'check 2 says why' );
	like( $r->{err}, qr/00:00:00:00:00:01  DevPlayer.*aa:bb:cc:dd:ee:ff  Kitchen/s, 'lists both' );
	$r = smoke( [ $url, 'AA:BB:CC:DD:EE:FF' ] );
	like( $r->{out}, qr/^PASS  2\. Player connected — Kitchen \(aa:bb:cc:dd:ee:ff\)$/m, 'an upper-case MAC is accepted' );
	$stop->();

	( $url, $stop ) = fake_lms( players => [ $GONE, $DEV ] );
	$r = smoke( [$url] );
	like( $r->{out}, qr/^PASS  2\. Player connected — DevPlayer \(00:00:00:00:00:01\)$/m, 'one connected player: used' );
	$r = smoke( [$url], env => { PLAYER => '00:00:00:00:00:01' } );
	like( $r->{out}, qr/^PASS  2\. Player connected — DevPlayer/m, 'given as $PLAYER' );
	$stop->();
};

subtest 'LMS without the plugin: exit 1, FAIL on checks 3-15, player left alone' => sub {
	my ( $url, $stop, $commands ) = fake_lms( players => [$DEV], state => undef, radios => [ $RADIOS->[0] ] );

	my $r = smoke( [ $url, '00:00:00:00:00:01' ] );
	is( $r->{code}, 1, 'exit 1' );
	is_deeply( verdicts( $r->{out} ), [ 'PASS 1', 'PASS 2', map {"FAIL $_"} 3 .. 15 ], 'one line per check: 1-2 pass, 3-15 fail' );
	like( $r->{out}, qr/^FAIL  3\. Plugin enabled — plugin\.state:ABCListen = unset \(install or enable ABC listen/m, 'check 3: plugin state and a hint' );
	like( $r->{out}, qr/^FAIL  4\. Radio lists ABC listen — no entry with cmd abclisten/m,                     'check 4: not in the Radio menu' );
	like( $r->{out}, qr/^FAIL  5\. Top level — no answer to \["abclisten","items",0,200\]/m,                  'check 5: no answer' );
	like( $r->{out}, qr/^FAIL  12\. Follow round trip — skipped: the top level is missing entries$/m,        'later checks: skipped' );
	like( $r->{out}, qr/SMOKE: 2\/15 passed\n\z/, 'final line: SMOKE: 2/15 passed' );
	is( scalar( touching( $commands->() ) ), 0, 'nothing was played, so the player was not touched' );
	ok( !( grep { $_->[1][0] eq 'pref' && $_->[1][1] eq 'plugin.abclisten:followed' } $commands->() ), 'the followed programs were not read or written' );
	$stop->();
};

subtest 'a full pass: 15/15, exit 0; the player is stopped, cleared and switched off again' => sub {
	my ( $url, $stop, $commands, $followed ) = fake_lms( @FULL, players => [ { %$DEV, power => 0 } ] );

	my $r = smoke( [ $url, '00:00:00:00:00:01' ], env => \%FAST );
	is( $r->{code}, 0, 'exit 0' ) or diag $r->{out}, $r->{err};
	is_deeply( verdicts( $r->{out} ), [ map {"PASS $_"} 1 .. 15 ], '15 PASS lines, in order' );
	like( $r->{out}, qr/^PASS  5\. Top level — 10 entries: Home \| Radio \| Podcasts \| News \| Sport \| Kids listen \| Audiobooks \| Programs \| Search \| My ABC listen$/m, 'check 5: the 10 entries' );
	like( $r->{out}, qr/^PASS  6\. National station plays with metadata — "triple j": time [\d.]+ → [\d.]+ s in 0\.3 s; now playing 'Some Song'$/m, 'check 6: triple j by its favourite link, with a song title' );
	like( $r->{out}, qr/^PASS  7\. Local station plays — New South Wales › "702 ABC Sydney": time /m,      'check 7: 702 ABC Sydney under New South Wales' );
	like( $r->{out}, qr/^PASS  8\. Episode plays and seeks — Radio National › The Science Show › Mon 1 Oct – The Science Show, part 1: duration 1800 s, seek to 600 s: time 6\d\d(?:\.\d)? → /m, 'check 8: an episode played and sought to 600 s' );
	like( $r->{out}, qr/^PASS  9\. All programs A–Z non-empty — A \(2\): 2 programs, first 'AM'$/m,         'check 9' );
	like( $r->{out}, qr/^PASS  10\. Home non-empty — Featured: 3 items/m,                                    'check 10' );
	like( $r->{out}, qr/^PASS  11\. Search — 'science': Programs \(3\), Episodes \(7\)$/m,                   'check 11' );
	like( $r->{out}, qr/^PASS  12\. Follow round trip — The Science Show: Followed programs \(0\) → followed, listed \(1\) → unfollowed \(0\); followed programs restored \(0\)$/m, 'check 12: follow, listed, unfollow, restored' );
	like( $r->{out}, qr/^PASS  13\. Podcasts non-empty — New & Noteworthy: 2 programs/m,                    'check 13' );
	like( $r->{out}, qr/^PASS  14\. Sections non-empty — News 1, Sport 1, Kids listen 2, Audiobooks 1 items$/m, 'check 14' );
	like( $r->{out}, qr/^PASS  15\. Kids listen live plays — "ABC KIDS listen": time /m,                     'check 15' );
	like( $r->{out}, qr/SMOKE: 15\/15 passed\n\z/, 'final line: SMOKE: 15/15 passed' );
	is( $r->{err}, '', 'nothing on stderr' );

	my @c = $commands->();
	my @plays = map { $_->[1] } grep { $_->[1][0] eq 'abclisten' && $_->[1][1] eq 'playlist' } @c;
	is( scalar @plays, 4, 'four plays: triple j, 702 ABC Sydney, an episode, ABC KIDS listen' );
	like( $plays[0][3], qr/^item_id:1\.1$/, 'triple j played by the id of its row (found by its abclisten://live/TRIPLEJ link)' );
	ok( ( grep { $_->[1][0] eq 'time' && $_->[1][1] == 600 } @c ), 'seek: ["time",600]' );
	ok( ( grep { $_->[1][0] eq 'pref' && ref $_->[1][2] eq 'ARRAY' } @c ), 'the followed programs were written back' );
	is_deeply( $followed->(), [], 'followed programs: back to [] (the unfollow tombstone is gone)' );
	my @tail = map { $JSON->encode( $_->[1] ) } grep { $_->[1][0] =~ /^(?:stop|playlist|power)$/ } @c;
	is_deeply( [ @tail[ -3 .. -1 ] ], [ '["stop"]', '["playlist","clear"]', '["power",0]' ], 'cleanup: stop, clear the queue, switch the player off again' );
	is( $c[-1][1][0], 'power', '... as the last commands' );
	ok( $r->{secs} < 25, sprintf( 'took %.1f s', $r->{secs} ) );
	$stop->();
};

subtest '--skip-live: checks 6, 7 and 15 SKIP, exit 0; a timed-out menu request is tried again' => sub {
	my ( $url, $stop, $commands ) = fake_lms( @FULL, slow_first_items => 1.6 );
	my $r = smoke( [ $url, '00:00:00:00:00:01', '--skip-live' ], env => { %FAST, SMOKE_CURL_TIMEOUT_S => 1 } );
	is( $r->{code}, 0, 'exit 0' ) or diag $r->{out};
	is_deeply( verdicts( $r->{out} ), [ ( map {"PASS $_"} 1 .. 5 ), 'SKIP 6', 'SKIP 7', ( map {"PASS $_"} 8 .. 14 ), 'SKIP 15' ], 'three SKIP lines: 6, 7, 15' );
	like( $r->{out}, qr/^SKIP  6\. National station plays with metadata — --skip-live$/m, 'SKIP line format' );
	like( $r->{out}, qr/SMOKE: 12\/12 passed, 3 skipped\n\z/,                          'final line: SMOKE: 12/12 passed, 3 skipped' );
	my @c = $commands->();
	my @menus = grep { $_->[1][0] eq 'abclisten' && $_->[1][1] eq 'items' } @c;
	is_deeply( [ map { $JSON->encode( $_->[1] ) } @menus[ 0, 1 ] ], [ ('["abclisten","items",0,200]') x 2 ], 'check 5: the first top-level request timed out (curl exit 28) and was tried once more' );
	ok( !( grep { $_->[1][0] eq 'power' && $_->[1][1] eq '0' } @c ), 'no power 0 for a player that was on' );
	is_deeply( [ map { $JSON->encode( $_->[1] ) } ( grep { $_->[1][0] =~ /^(?:stop|playlist)$/ } @c )[ -2, -1 ] ], [ '["stop"]', '["playlist","clear"]' ], 'cleanup: stop and clear' );
	$stop->();
};

subtest 'a live stream whose time is stuck: check 6 FAIL, exit 1' => sub {
	my ( $url, $stop ) = fake_lms( @FULL, stuck => 'TRIPLEJ' );
	my $r = smoke( [ $url, '00:00:00:00:00:01' ], env => \%FAST );
	is( $r->{code}, 1, 'exit 1' );
	like( $r->{out}, qr/^FAIL  6\. National station plays with metadata — "triple j": time 0\.4 → 0\.4 s in 0\.3 s, needs \+5 s \(mode=play/m, 'check 6 fails with the times' );
	like( $r->{out}, qr/^PASS  7\. /m,                 'check 7 still runs' );
	like( $r->{out}, qr/SMOKE: 14\/15 passed\n\z/,     'SMOKE: 14/15 passed' );
	$stop->();
};

subtest 'check 6 needs program or song metadata, also for a station played by URL or a home state\'s version; stations are looked up below Radio' => sub {
	my @fakes = (
		# no favourite links (an older LMS), and no metadata: the only title is the station's own name
		[ [ no_presets => 1, no_meta => ['RN'] ], [ '--station', 'RN' ] ],
		# favourite links, no metadata; an unknown --local
		[ [ no_meta => ['TRIPLEJ'] ], [ '--local', 'NOSUCHLOCAL' ] ],
		# played by URL, and the metadata comes a moment later
		[ [ no_presets => 1, meta_after => 0.2 ], [ '--station', 'RN' ] ],
		# a station that isn't in Radio itself is found under Local radio
		[ [], [ '--station', 'LOCAL_MELB', '--local', 'LOCAL_MELB' ] ],
		# an unknown station
		[ [], [ '--station', 'NOSUCHSTATION' ] ],
		# home state QLD: Radio's "triple j" row plays triple j Brisbane
		[ [ home => 'QLD' ], [] ],
		# ... which shows only its own title, "triple j Brisbane" (the row's favourite title)
		[ [ home => 'QLD', no_meta => ['TRIPLEJ_BRISBANE'] ], [] ],
		# a station that shows only the plugin's name
		[ [ pre_title => 'ABC listen', no_meta => ['TRIPLEJ'] ], [] ],
	);
	my @lms = map { [ fake_lms( @FULL, @{ $_->[0] } ) ] } @fakes;
	my @r = @{ smoke_all( map { [ [ $lms[$_][0], '00:00:00:00:00:01', @{ $fakes[$_][1] } ], env => \%FAST ] } 0 .. $#fakes ) };

	is( $r[0]{code}, 1, 'played by URL, no metadata: exit 1' );
	like( $r[0]{out}, qr/^FAIL  6\. National station plays with metadata — abclisten:\/\/live\/RN \(played by URL\): time .*, but no program or song title within 1 s \(title 'Radio National'\) \(no station links in menu mode, older LMS\?\)$/m, 'check 6 FAILs: the title is only the station name' );
	ok( ( grep { $_->[1][0] eq 'playlist' && ( $_->[1][2] // '' ) eq 'abclisten://live/RN' } $lms[0][2]->() ), '["playlist","play","abclisten://live/RN"]' );
	like( $r[0]{out}, qr/^PASS  7\. Local station plays — abclisten:\/\/live\/LOCAL_SYDNEY \(played by URL\): /m, 'check 7: by URL too' );

	is( $r[1]{code}, 1, 'found by its link, no metadata: exit 1' );
	like( $r[1]{out}, qr/^FAIL  6\. National station plays with metadata — "triple j": time .*, but no program or song title within 1 s \(title 'triple j'\)$/m, 'check 6 FAILs: the title is the station\'s menu name' );
	like( $r[1]{out}, qr/^FAIL  7\. Local station plays — abclisten:\/\/live\/NOSUCHLOCAL \(played by URL\): stopped after \d+ s .*\(NOSUCHLOCAL is not in Local radio\)$/m, 'an unknown --local: not in Local radio, does not play' );

	like( $r[2]{out}, qr/^PASS  6\. National station plays with metadata — abclisten:\/\/live\/RN \(played by URL\): .*; now playing 'Some Song' \(no station links in menu mode, older LMS\?\)$/m, 'check 6 PASSes by URL once a program or song title shows' );

	is( $r[3]{code}, 0, '--station LOCAL_MELB: exit 0' ) or diag $r[3]{out};
	like( $r[3]{out}, qr/^PASS  6\. National station plays with metadata — Local radio › Victoria › "ABC Melbourne": .*; now playing 'Some Song'$/m, 'check 6: found by its link under Local radio › Victoria' );
	like( $r[3]{out}, qr/^PASS  7\. Local station plays — Victoria › "ABC Melbourne": /m, 'check 7: found under its state' );
	ok( !( grep { $_->[1][0] eq 'playlist' && ( $_->[1][1] // '' ) eq 'play' } $lms[3][2]->() ), 'nothing played by URL' );

	is( $r[4]{code}, 1, 'an unknown --station: exit 1' );
	like( $r[4]{out}, qr/^FAIL  6\. National station plays with metadata — abclisten:\/\/live\/NOSUCHSTATION \(played by URL\): stopped after \d+ s .*\(NOSUCHSTATION is not in Radio\)$/m, 'check 6: not in Radio, and it does not play' );

	is( $r[5]{code}, 0, 'home state QLD: exit 0' ) or diag $r[5]{out};
	like( $r[5]{out}, qr/^PASS  6\. National station plays with metadata — "triple j", which plays triple j Brisbane \(your state's version\): time [\d.]+ → [\d.]+ s in 0\.3 s; now playing 'Some Song'$/m, 'home state QLD: check 6 PASSes on the "triple j" row and names the version it plays' );
	my @plays = grep { $_->[1][0] =~ /^(?:abclisten|playlist)$/ && ( $_->[1][1] // '' ) =~ /^(?:playlist|play)$/ } $lms[5][2]->();
	like( $plays[0][1][3] // '', qr/^item_id:1\.1$/, 'home state QLD: the "triple j" row in Radio was played' );
	ok( !( grep { $_->[1][0] eq 'playlist' && ( $_->[1][1] // '' ) eq 'play' } $lms[5][2]->() ), 'home state QLD: nothing played by URL' );

	is( $r[6]{code}, 1, 'home state QLD, no metadata: exit 1' );
	like( $r[6]{out}, qr/^FAIL  6\. National station plays with metadata — "triple j", which plays triple j Brisbane \(your state's version\): time .*, but no program or song title within 1 s \(title 'triple j Brisbane'\)$/m, 'check 6 FAILs: the title is the row\'s favourite title' );

	is( $r[7]{code}, 1, 'the plugin\'s name as the title: exit 1' );
	like( $r[7]{out}, qr/^FAIL  6\. National station plays with metadata — "triple j": time .*, but no program or song title within 1 s \(title 'ABC listen'\)$/m, 'check 6 FAILs: "ABC listen" is not a program or song' );

	$_->[1]->() for @lms;
};

subtest 'geo-blocked or expired episodes are skipped; FAIL after 5 attempts with the last reason' => sub {
	my @lms = map { [ fake_lms( @FULL, geo => $_ ) ] } 2, 99;
	my @r = @{ smoke_all( map { [ [ $_->[0], '00:00:00:00:00:01', '--skip-live' ], env => \%FAST ] } @lms ) };

	is( $r[0]{code}, 0, 'two blocked episodes, then one plays: exit 0' ) or diag $r[0]{out};
	like( $r[0]{out}, qr/^PASS  8\. Episode plays and seeks — Radio National › Late Night Live › Mon 1 Oct – Late Night Live, part 1: /m, 'check 8: the next program\'s episode' );
	like( $r[0]{out}, qr/^PASS  12\. Follow round trip — Late Night Live: /m, 'check 12 follows that program' );

	is( $r[1]{code}, 1, 'nothing plays: exit 1' );
	like( $r[1]{out}, qr/^FAIL  8\. Episode plays and seeks — no episode played in 5 attempt\(s\) over 3 program\(s\) of Radio National; last: Rear Vision › Mon 1 Oct – Rear Vision, part 1: stopped after \d+ s/m, 'check 8: 5 attempts, the last reason' );
	like( $r[1]{out}, qr/^PASS  12\. Follow round trip — AM: /m, 'check 12 falls back to the first program of check 9' );

	$_->[1]->() for @lms;
};

subtest 'FAIL with the reason: rate-limited search, empty section, wrong top level, a seek that does not play on, a follow not listed' => sub {
	my ( $url, $stop, $commands, $followed ) = fake_lms( @FULL, rate_limited => 1, empty_sport => 1, rename_top => [ 'News', 'Newsroom' ], seek_stuck => 1, hide_followed_rows => 1 );
	my $r = smoke( [ $url, '00:00:00:00:00:01', '--skip-live' ], env => \%FAST );
	is( $r->{code}, 1, 'exit 1' );
	like( $r->{out}, qr/^FAIL  5\. Top level — expected: Home \| Radio \| Podcasts \| News \| .*; got: Home \| Radio \| Podcasts \| Newsroom \| /m, 'check 5: expected and got' );
	like( $r->{out}, qr/^PASS  8\. Episode plays and seeks — Radio National › The Science Show › Mon 2 Oct – The Science Show, part 2: /m, 'check 8: an episode whose time stops at the seek target is not enough; the next one is played' );
	like( $r->{out}, qr/^FAIL  11\. Search — 'science': needs Programs \(N\) and Episodes \(M\) with N, M >= 1; ABC is limiting requests \("ABC listen is busy right now\. Please try again in a few minutes\."\); try again later$/m, 'check 11: quotes the busy message' );
	like( $r->{out}, qr/^FAIL  12\. Follow round trip — followed, but Followed programs \(1\) doesn't list The Science Show$/m, 'check 12: the followed program must be listed in Followed programs' );
	is_deeply( $followed->(), [], '... and the test\'s follow is undone' );
	like( $r->{out}, qr/^FAIL  14\. Sections non-empty — empty: Sport \(got: Nothing here right now; .*abc-endpoints-check\.sh\)$/m, 'check 14: names the empty section, suggests the endpoint check' );
	unlike( $r->{out}, qr/^FAIL  13\./m, 'the other checks still pass' );
	$stop->();
};

subtest 'followed programs: an already-followed program, 200 followed, another client following at the same time, a restore that does not take' => sub {
	my $before = [ { path => '/listen/programs/science-show', title => 'The Science Show', followedAt => 1600000000 }, { path => '/listen/programs/other', title => 'Other', followedAt => 1600000001 } ];
	my @full   = map { { path => "/listen/programs/p$_", title => "P$_", followedAt => 1600000000 + $_ } } 1 .. 200;
	my $other  = { path => '/listen/programs/other', title => 'Other', followedAt => 1700000099 };
	my @lms    = (
		[ fake_lms( @FULL, followed => $before ) ],
		[ fake_lms( @FULL, cap => 200, followed => [@full] ) ],
		[ fake_lms( @FULL, other_follow => $other ) ],
		[ fake_lms( @FULL, cap => 200, followed => [@full], ignore_pref_set => 1 ) ],
	);
	my @r = @{ smoke_all( map { [ [ $_->[0], '00:00:00:00:00:01', '--skip-live' ], env => \%FAST ] } @lms ) };

	is( $r[0]{code}, 0, 'already followed: exit 0' ) or diag $r[0]{out};
	like( $r[0]{out}, qr/^PASS  12\. Follow round trip — The Science Show was already followed: Followed programs \(2\) → unfollowed \(1\) → followed again, listed \(2\); followed programs restored \(2\)$/m, 'already followed: unfollowed, then followed again' );
	is_deeply( $lms[0][3]->(), $before, 'already followed: the followed programs as before' );

	is( $r[1]{code}, 0, '200 followed (the plugin\'s limit): exit 0' ) or diag $r[1]{out};
	like( $r[1]{out}, qr/^PASS  12\. Follow round trip — The Science Show: Followed programs \(200\) → followed, listed \(200\) → unfollowed \(199\); the list was full, so the plugin dropped the oldest follow to make room; followed programs restored \(200\)$/m, '200 followed: check 12 PASS, with a note' );
	is_deeply( $lms[1][3]->(), \@full, '200 followed: exactly as before, the oldest (P1, dropped by the plugin for the test) included' );

	is( $r[2]{code}, 1, 'another client follows a program during check 12: exit 1' );
	like( $r[2]{out}, qr/^FAIL  12\. Follow round trip — followed: Followed programs \(0\) → \(2\), expected \(1\)$/m, 'check 12 FAILs: the count changed by two' );
	is_deeply( $lms[2][3]->(), [$other], 'the other client\'s follow is kept, and the test program is no longer followed' );

	is( $r[3]{code}, 1, '200 followed, and LMS does not take the restored list: exit 1' );
	like( $r[3]{out}, qr/^FAIL  12\. Follow round trip — The Science Show: Followed programs \(200\) → followed, listed \(200\) → unfollowed \(199\); the list was full, so the plugin dropped the oldest follow to make room; restored, but Followed programs \(199\), expected \(200\)$/m, 'check 12 FAILs: the count after the restore is not the count before' );

	$_->[1]->() for @lms;
};

subtest 'interrupted during the follow check: the followed programs are put back' => sub {
	# interrupted while smoke.sh opens My ABC listen after the follow, or (before it knows the
	# followed program's path) while it reads the followed programs right after the follow
	for my $when (qw(hang_after_follow hang_pref_after_follow)) {
		my ( $url, $stop, $commands, $followed ) = fake_lms( @FULL, $when => 2 );
		my $flag = "$DIR/followed-" . ( $url =~ /:(\d+)\z/ )[0] . '.json.followed';

		my $pid = fork // die "fork: $!";
		if ( !$pid ) {
			open( STDOUT, '>', "$DIR/int.out" ) or die;
			open( STDERR, '>', "$DIR/int.err" ) or die;
			$ENV{$_} = $FAST{$_} for keys %FAST;
			exec( 'bash', $SCRIPT, $url, '00:00:00:00:00:01', '--skip-live' ) or die;
		}
		my $deadline = time + 20;
		sleep 0.1 until -e $flag || time > $deadline;
		ok( -e $flag, "$when: the follow check followed a program" );
		is( scalar @{ $followed->() }, 1, "$when: ... which is in the list now" );
		kill 'INT', $pid;
		waitpid( $pid, 0 );
		is( $? >> 8, 130, "$when: exit 130" );
		my $err = do { local ( @ARGV, $/ ) = "$DIR/int.err"; <> };
		like( $err, qr/smoke: interrupted/, "$when: says it was interrupted" );
		is_deeply( $followed->(), [], "$when: the followed programs are back to []" );
		my @c = $commands->();
		is_deeply( [ map { $JSON->encode( $_->[1] ) } @c[ -3 .. -1 ] ], [ '["pref","plugin.abclisten:followed",[]]', '["stop"]', '["playlist","clear"]' ], "$when: cleanup: followed programs restored, then the player stopped and cleared" );
		$stop->();
	}
};

subtest 'interrupted before the test follows, while another client follows a program: nothing is written' => sub {
	my $other = { path => '/listen/programs/other', title => 'Other', followedAt => 1700000099 };
	my ( $url, $stop, $commands, $followed ) = fake_lms( @FULL, pre_change => $other );
	my $flag = "$DIR/followed-" . ( $url =~ /:(\d+)\z/ )[0] . '.json.changed';

	my $pid = fork // die "fork: $!";
	if ( !$pid ) {
		open( STDOUT, '>', "$DIR/p3.out" ) or die;
		open( STDERR, '>', "$DIR/p3.err" ) or die;
		$ENV{$_} = $FAST{$_} for keys %FAST;
		exec( 'bash', $SCRIPT, $url, '00:00:00:00:00:01', '--skip-live' ) or die;
	}
	my $deadline = time + 20;
	sleep 0.1 until -e $flag || time > $deadline;
	ok( -e $flag, 'another client followed a program right after the test read the list' );
	kill 'INT', $pid;
	waitpid( $pid, 0 );
	is( $? >> 8, 130, 'exit 130' );
	is_deeply( $followed->(), [$other], 'the other client\'s follow is kept' );
	ok( !( grep { $_->[1][0] eq 'pref' && ref $_->[1][2] } $commands->() ), 'the followed programs were not written' );
	$stop->();
};

done_testing();
