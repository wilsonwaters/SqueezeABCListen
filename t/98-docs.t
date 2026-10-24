#!/usr/bin/perl
# The user and maintainer docs: README.md (its 16 sections, the install URL, the usage tour with
# the real menu names, now playing, limitations, troubleshooting, compatibility, privacy,
# self-test), the screenshots in docs/images, RELEASING.md, docs/official-repository.md,
# CHANGELOG.md's newest section with content, the description shared by strings.txt and repo.xml,
# and every relative link and image in the docs.

use strict;
use utf8;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

sub slurp {
	my ( $file, $layer ) = @_;
	open( my $fh, '<' . ( $layer || ':encoding(UTF-8)' ), $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# EN values of ABCListen/strings.txt
my %EN;
{
	my $token;
	for my $line ( split /\n/, slurp('ABCListen/strings.txt') ) {
		next if $line =~ /^\s*(?:#|$)/;
		if    ( $line =~ /^(\S+)\s*$/ )             { $token = $1 }
		elsif ( $token && $line =~ /^\tEN\t(.*)$/ ) { $EN{$token} = $1 }
	}
}
sub en { my $t = 'PLUGIN_ABCLISTEN' . ( length $_[0] ? "_$_[0]" : '' ); die "no EN text for $t" unless defined $EN{$t}; return $EN{$t} }

# the text with every run of white space (line breaks too) as one space
sub flat { ( my $text = shift // '' ) =~ s/\s+/ /g; return $text }

# "## Heading" => section text (up to the next ## heading)
sub sections {
	my $doc = shift;
	my %section;
	$section{$1} = $2 while $doc =~ /^## (.+?)\n(.*?)(?=^## |\z)/msg;
	return %section;
}

# "### Heading" => subsection text, within a section
sub subsections {
	my $text = shift;
	my %sub;
	$sub{$1} = $2 while $text =~ /^### (.+?)\n(.*?)(?=^### |\z)/msg;
	return %sub;
}

# GitHub's anchor for a heading
sub slug {
	my $slug = lc shift;
	$slug =~ s/[^\w\- ]//g;
	$slug =~ s/ /-/g;
	return $slug;
}

my $REPO_URL = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml';
my @DOCS     = ( 'README.md', 'RELEASING.md', 'CHANGELOG.md', glob('docs/*.md') );
my $readme   = slurp('README.md');
my %section  = sections($readme);

my @SECTIONS = ( 'About', 'Features', 'Disclaimer', 'Requirements', 'Installation', 'Usage', 'Now playing', 'Limitations', 'Troubleshooting', 'Compatibility', 'Privacy', 'Self-test', 'Updating', 'Uninstalling', 'Development', 'License' );

subtest 'README: the 16 sections, in order' => sub {
	is_deeply( [ $readme =~ /^## (.+)$/mg ], \@SECTIONS, join( ', ', @SECTIONS ) );
	like( $readme, qr/\A# SqueezeABCListen\n/, 'one # title first' );
	unlike( $readme, qr/early preview|in development/i, 'no "early preview" or "in development" status' );
	like( $section{About}, qr/\*\*ABC listen\*\* to the LMS Radio menu/, 'About: what it adds, and where' );
	like( $section{About}, qr/No ABC account\s+is needed/, 'About: no ABC account' );
	like( $section{Features}, qr/\*\*Live radio:\*\*.*\*\*Podcasts:\*\*.*\*\*Programs:\*\*.*\*\*Audiobooks:\*\*.*\*\*Search\*\*.*\*\*My ABC listen:\*\*/s, 'Features: live radio, podcasts, programs, audiobooks, search, My ABC listen' );
};

subtest 'README: install URL, installation, updating, uninstalling (R1)' => sub {
	my $install = $section{Installation};
	like( $install, qr/^\s+\Q$REPO_URL\E$/m,                'Installation: the exact repository URL, on its own line' );
	ok( ( () = $readme =~ /\Q$REPO_URL\E/g ) >= 1,          'the install URL is in README.md' );
	like( $install, qr/Settings → Manage Plugins/,         'Installation: Settings → Manage Plugins' );
	like( $install, qr/Additional Repositories/,           'Installation: Additional Repositories' );
	like( $install, qr/empty field and click \*\*Apply\*\*/, 'Installation: the URL is saved with Apply' );
	like( $install, qr/SqueezeABCListen plugin repository/, 'Installation: the repository section name' );
	like( $install, qr/Tick\s+\*\*ABC listen\*\* and click \*\*Apply\*\*/, 'Installation: tick ABC listen, Apply' );
	like( $install, qr/You are about to\s+install: … Only install extensions from authors whom you trust/, 'Installation: the third-party confirmation popup' );
	like( $install, qr/Click \*\*OK\*\*/,                   'Installation: confirm with OK' );
	like( $install, qr/raw\.githubusercontent\.com/,       'Installation: the zip comes from raw.githubusercontent.com' );
	like( $install, qr/Radio → ABC listen/,                'Installation: where to find it' );
	unlike( $readme, qr/\*\*Save\*\*/,                       'no "Save" button (LMS 9.1 has Apply)' );
	like( $section{Updating},     qr/update notice/,                 'Updating: update notice' );
	like( $section{Updating},     qr/automatic plugin\s+updates/,    'Updating: automatic updates' );
	like( $section{Updating},     qr/about 5 minutes/,               'Updating: the repository file is cached for about 5 minutes' );
	like( $section{Uninstalling}, qr/untick \*\*ABC listen\*\*/,      'Uninstalling: untick' );
	like( $section{Uninstalling}, qr/Restart LMS/,                   'Uninstalling: restart' );
	like( $section{Uninstalling}, qr/repository URL/,                'Uninstalling: optionally remove the repository URL' );
};

subtest 'README: disclaimer, requirements, compatibility, privacy' => sub {
	my $d = $section{Disclaimer};
	like( $d, qr/\*\*unofficial\*\*/,                                     'Disclaimer: unofficial' );
	like( $d, qr/\*\*not affiliated with or endorsed by the Australian\s+Broadcasting Corporation \(ABC\)\*\*/, 'Disclaimer: not affiliated with or endorsed by the ABC' );
	like( $d, qr/names and logos belong to the\s+ABC/,                    'Disclaimer: names and logos belong to the ABC' );
	like( $d, qr/never copies or re-hosts any audio/,                     'Disclaimer: audio is never re-hosted' );
	like( $d, qr{<https://www\.abc\.net\.au/listen>},                     'Disclaimer: links ABC listen' );

	like( $section{Requirements}, qr/\*\*8\.3 or later\*\*/, 'Requirements: LMS 8.3 or later' );
	like( $section{Requirements}, qr/Tested on LMS 9\.1\.1/, 'Requirements: tested on 9.1.1' );
	like( $section{Requirements}, qr/`faad`/,                'Requirements: faad for older players' );

	my $c = $section{Compatibility};
	like( $c, qr/\*\*Tested\*\* on LMS \*\*9\.1\.1\*\* with a squeezelite player, in the Default web interface and in the\s+Material skin \(6\.4\.14\)/, 'Compatibility: LMS 9.1.1, squeezelite, Default and Material 6.4.14' );
	like( $c, qr/\*\*Declared\*\* for LMS \*\*8\.3 or later\*\* \(`minTarget` 8\.3\), but not tested on 8\.x/, 'Compatibility: claims 8.3+ (minTarget), untested' );
	like( $c, qr/standard LMS menus.*Squeezebox players/s, 'Compatibility: hardware players through the standard menus' );
	my ($minVersion) = slurp('ABCListen/install.xml') =~ m{<minVersion>([^<]*)</minVersion>};
	is( $minVersion, '8.3', 'install.xml minVersion is the 8.3 the docs claim' );

	my $p = $section{Privacy};
	like( $p, qr/\*\*No ABC login or account\*\*, and the plugin stores no passwords or other credentials/, 'Privacy: no login, no credentials' );
	like( $p, qr/home state, the live stream quality and your followed programs.*`plugin\/abclisten\.prefs`/s, 'Privacy: what is stored, and where' );
	like( $p, qr/only to ABC's servers.*content-delivery networks ABC streams its audio from \(StreamGuys.*Akamai.*MediaHub Australia.*ABC's Algolia search service/s, 'Privacy: only ABC hosts, the CDNs ABC streams from, and ABC\'s Algolia search' );
	like( $p, qr/Nothing is sent to the plugin's author/, 'Privacy: nothing goes to the author' );
};

subtest 'README: Usage follows the top level, with the real menu names' => sub {
	my $usage = $section{Usage};
	my @top   = map { en($_) } qw(HOME RADIO PODCASTS NEWS SPORT KIDS AUDIOBOOKS PROGRAMS_AZ SEARCH MY_ABC);

	like( $usage, qr/\*\*Radio → \Q${\ en('')}\E\*\*/, 'Usage: **Radio → ABC listen**' );
	my @rows = $usage =~ /^\| \*\*(.+?)\*\* \|/mg;
	is_deeply( \@rows, \@top, 'the top-level table lists the 10 entries in order' );
	is_deeply( [ $usage =~ /^### (.+)$/mg ], [ @top, 'Settings', 'Favourites' ], 'one ### part per entry, in top-level order, then Settings and Favourites' );

	my %sub = subsections($usage);
	my %need = (
		Home              => [qw(FEATURED POPULAR_NOW POPULAR_SPORT)],
		Radio             => [qw(SPORT LOCAL_RADIO TIMEZONE_VERSIONS LISTEN_LIVE TODAY YESTERDAY ON_AIR_MARK)],
		Podcasts          => [qw(CATEGORIES PODCASTS_AZ)],
		'Kids listen'     => [qw(FEATURED KIDS_PROGRAMS KIDS_PODCASTS BOOKS_FOR_KIDS CHAPTERS)],
		Audiobooks        => [qw(AUDIOBOOKS_AZ AUDIOBOOKS_AU_ONLY CHAPTERS)],
		Programs          => [qw(BY_NETWORK AZ BY_TYPE TYPE_PODCAST TYPE_CATCHUP TYPE_MUSIC TYPE_NEWS TYPE_AUDIOBOOK TYPE_OTHER MORE_EPISODES PLAY_EPISODE TRACKLIST_UNAVAILABLE NO_TRACKLIST)],
		Search            => [qw(GLOBAL_SEARCH_TITLE)],
		'My ABC listen'   => [qw(LATEST_EPISODES NO_FOLLOWED_HELP)],
		Settings          => [qw(HOME_STATE HOME_STATE_NONE LIVE_QUALITY LIVE_QUALITY_STANDARD LIVE_QUALITY_MEDIAHUB)],
	);
	for my $part ( sort keys %need ) {
		like( $sub{$part} // '', qr/\*\*\Q${\ en($_)}\E\*\*/, "$part: **" . en($_) . "**" ) for @{ $need{$part} };
	}
	# names with a count or a name in them
	like( $sub{Audiobooks},      qr/\*\*Chapters \(N\)\*\*/,             'Audiobooks: **Chapters (N)**' );
	like( $sub{'Kids listen'},   qr/\*\*Episodes \(N\)\*\*/,             'Kids listen: **Episodes (N)** of a restricted podcast' );
	like( $sub{Programs},        qr/\*\*Segments \(N\)\*\*.*\*\*Tracklist \(N\)\*\*.*\*\*More from \*program\*\*\*/s, 'Programs: Segments (N), Tracklist (N), More from' );
	like( $sub{Search},          qr/\*\*Programs \(N\)\*\* and \*\*Episodes \(N\)\*\*/, 'Search: **Programs (N)** and **Episodes (N)**' );
	like( $sub{Search},          qr/LMS's own search/,                    'Search: LMS global search' );
	like( $sub{'My ABC listen'}, qr/\*\*Follow "\*program\*"\*\*.*\*\*✓ Following "\*program\*"\*\*.*\*\*Unfollow "\*program\*"\*\*/s, 'My ABC listen: Follow, Following, Unfollow rows' );
	like( $sub{'My ABC listen'}, qr/\*\*Followed programs \(N\)\*\*/,    'My ABC listen: **Followed programs (N)**' );
	like( $sub{'My ABC listen'}, qr/for the whole server: every player sees the same list/, 'My ABC listen: server-wide' );
	like( $sub{Radio},           qr/"On air: \*program\* · \*presenters\*"/, 'Radio: the "On air:" line' );
	like( $sub{Favourites},      qr/Stations and episodes.*follow them\s+instead/s, 'Favourites: stations and episodes; programs via Follow' );

	# Every bold name in Usage is a plugin menu name (an EN value, or a template with its %s filled
	# in), a path of them ("Settings → Advanced → ABC listen"), or one of LMS's own labels.
	my %LMS = map { $_ => 1 } ( 'Settings', 'Advanced', 'Manage Plugins', 'All Songs', 'Song Info', 'Save to Favorites' );
	my %exact = map { $_ => 1 } values %EN;
	my @templates = map { my $re = quotemeta $_; $re =~ s/\\%s/.+/g; qr/\A$re\z/ } grep {/%s/} values %EN;
	my @bold = $usage =~ /\*\*(.+?)\*\*/g;
	ok( @bold > 60, scalar(@bold) . ' bold names in Usage' );
	my @unknown;
	for my $bold (@bold) {
		( my $name = $bold ) =~ s/\*//g;
		for my $part ( split / → /, $name ) {
			next if $exact{$part} || $LMS{$part} || grep { $part =~ $_ } @templates;
			push @unknown, $part;
		}
	}
	is_deeply( \@unknown, [], 'every bold name in Usage is a strings.txt EN value or an LMS label' );
};

subtest 'README: now playing and limitations' => sub {
	my $np = flat( $section{'Now playing'} );
	like( $np, qr/\*\*Talk stations\*\*.*program on air.*presenters.*image/s,              'Now playing: program mode on talk stations' );
	like( $np, qr/\*\*Music stations\*\*.*title, the artist and\s+the cover art/s,        'Now playing: song mode on music stations' );
	like( $np, qr/\*\*\Q${\ en('RECENTLY_PLAYED')}\E\*\*/,                                 'Now playing: Recently played' );
	like( $np, qr/\*\*\Q${\ en('PROGRAM_INFO')}\E\*\*/,                                    'Now playing: Program info' );
	like( $np, qr/about 30 seconds after each program change/,                             'Now playing: how often the program refreshes' );
	like( $np, qr/every 20 seconds to\s+2 minutes, and at the end of each song/,           'Now playing: how often songs refresh' );
	like( $np, qr/\*\*Episodes\*\*.*title, the program, the episode's artwork and its duration.*sought/s, 'Now playing: episodes' );

	my $l = flat( $section{Limitations} );
	like( $l, qr/\*\*Live streams are 56 kbps HE-AAC by default\.\*\*.*ABC mediahub AAC.*falls back/s, 'Limitations: 56 kbps, mediahub and its fallback' );
	like( $l, qr/HLS aren't listed\*\*.*Sport Rapid, RLWC Rapid.*PlayHLS.*Kids listen time-zone\s+versions are hidden/s, 'Limitations: HLS-only stations, Kids listen time-zone versions' );
	# there is no HLS option (L5 ships Standard and mediahub only): HLS is a limitation, never a feature
	for my $part ( 'About', 'Features', 'Usage', 'Now playing', 'Compatibility' ) {
		unlike( $section{$part}, qr/HLS/i, "$part: no HLS or PlayHLS claim" );
	}
	unlike( $readme, qr/HLS (?:option|setting|quality)|quality[^.\n]*HLS|PlayHLS plugin \+ ffmpeg/i, 'no HLS quality option anywhere' );
	my %usage = subsections( $section{Usage} );
	my @qualities = $usage{Settings} =~ /\*\*((?:Standard|ABC mediahub)[^*]*)\*\*/g;
	is_deeply( \@qualities, [ map { en($_) } qw(LIVE_QUALITY_STANDARD LIVE_QUALITY_MEDIAHUB) ], 'Settings: exactly the two live stream qualities' );
	like( $l, qr/\*\*Only the newest 250 episodes\*\*/,                                    'Limitations: newest 250 episodes' );
	like( $l, qr/about\s+28 days; podcast \(MP3\) episodes stay/,                          'Limitations: catch-up AAC expiry, MP3 stays' );
	like( $l, qr/Most audiobooks play only from an Australian internet\s+connection.*The Wind in the Willows, The Wonderful Wizard of Oz, Persuasion, My Brilliant Career,\s+Frankenstein and Animal Farm.*Bluey Listen Along/s, 'Limitations: Australia-only audiobooks, the six classics, restricted podcasts' );
	like( $l, qr/isn't an official API/,                                                    'Limitations: unofficial endpoints may change' );
	like( $l, qr/\*\*Search shares ABC's limit\.\*\*/,                                    'Limitations: the search limit' );
	like( $l, qr/\*\*Followed programs are per server\*\*.*up to 30 minutes/s,            'Limitations: server-wide follows; 30-minute unfollow' );
	like( $l, qr/\*\*Times use your LMS server's time zone\*\*/,                          'Limitations: server time zone' );
	like( $l, qr/Classic 2.*composer/s,                                                     'Limitations: Classic 2, composers' );
	like( $l, qr/Schedule rows for programs that have no ABC program page/,                'Limitations: schedule rows without a program page' );
	like( $l, qr/Material's own search box/,                                                'Limitations: Material search box' );
	like( $l, qr/programs that have stopped.*Comedy Showcase,\s+Grass Roots, Desko/s,       'Limitations: stopped programs, unindexed programs' );
	like( $l, qr/"\Q${\ en('EPISODE_EXPIRED')}\E"/,                                       'Limitations: the expired message, word for word' );
	like( $l, qr/"\Q${\ en('EPISODE_GEO')}\E"/,                                           'Limitations: the Australia-only message, word for word' );
};

subtest 'README: troubleshooting' => sub {
	my @items = $section{Troubleshooting} =~ /^\*\*([a-z])\. /mg;
	is_deeply( \@items, [ 'a' .. 'j' ], 'items a-j' );
	my $ts = flat( $section{Troubleshooting} );
	like( $ts, qr/\*\*a\. ABC listen isn't in the Radio menu.*restart LMS.*about 5 minutes/s,  'a: restart; repository files cached ~5 min' );
	like( $ts, qr/\*\*b\. "unable to download ABCListen … Header line too long".*Since v0\.3\.0.*raw\.githubusercontent\.com.*install or update again/s, 'b: the Header line too long download error' );
	like( $ts, qr/\*\*c\. .*HE-AAC.*`faad`.*Settings →\s+Advanced → File Types/s,              'c: older players need faad' );
	like( $ts, qr/\*\*d\. .*\*\*ABC mediahub AAC\*\*.*back to \*\*Standard\*\*/s,               'd: a failing live stream: back to Standard' );
	like( $ts, qr/\*\*e\. "\Q${\ en('EPISODE_GEO')}\E", "\Q${\ en('EPISODE_RESTRICTED')}\E" or "\Q${\ en('EPISODE_EXPIRED')}\E"\*\*/, 'e: the Australia-only, restricted and expired messages, word for word' );
	like( $ts, qr/\*\*f\. "\Q${\ en('RATE_LIMITED')}\E"\*\*/,                                 'f: the busy (rate-limited) message, word for word' );
	like( $ts, qr/\*\*g\. .*"\Q${\ en('LOAD_FAILED')}\E".*"\Q${\ en('ERROR')}\E"/s,            'g: the load-failed messages, word for word' );
	like( $ts, qr/\*\*h\. .*Settings → Advanced → Logging.*\(plugin\.abclisten\) - ABC listen.*\*\*Debug\*\*/s, 'h: Logging page, plugin.abclisten = Debug' );
	like( $ts, qr/\Q["debug","plugin.abclisten","DEBUG"]\E/,                                    'h: the JSON-RPC command' );
	like( $ts, qr/github\.com\/wilsonwaters\/SqueezeABCListen\/issues/,                         'h: where to report' );
	like( $ts, qr/\*\*i\. Radio Now Playing.*leaves ABC listen's streams alone/s,              'i: Radio Now Playing coexistence' );
	like( $ts, qr/\*\*j\. .*`scripts\/smoke\.sh`/,                                               'j: the self-test' );
};

subtest 'README: self-test' => sub {
	like( $section{'Self-test'}, qr{^scripts/smoke\.sh http://<your-lms>:9000 <player-mac>$}m, 'how to run it' );
	is( scalar( () = $section{'Self-test'} =~ /^\d+\. /mg ), 15,                              'the 15 checks, one per line' );
	( my $quoted = $section{'Self-test'} ) =~ s/^> ?//mg;    # the warning is a block quote
	my $self = flat($quoted);
	like( $self, qr/\*\*Warning:\*\* the test plays audio .* replaces its queue/s,       'warns that it plays audio and replaces the queue' );
	like( $self, qr/puts that program back as it was in your followed programs.*oldest follow too.*Changes someone else makes to the followed programs meanwhile are kept/, 'says how the followed programs are restored' );
	like( $self, qr/synced with others, they stop too and their shared queue is cleared/, 'says synced players stop too' );
	like( $self, qr/bash 4 or later, `curl` and `jq`/,                                    'requirements' );
	like( $self, qr/`SMOKE: <passed>\/<run> passed`/,                                     'the summary line' );
	like( $self, qr/`--skip-live` skips the three live-stream checks \(6, 7 and 15\)/,   '--skip-live' );
	like( $self, qr/`--station <ID>` and `--local <ID>`/,                                 '--station and --local' );
	like( $self, qr/`LMS_USER` and `LMS_PASS`/,                                           'basic auth' );
	like( $self, qr/exits with 0 when no check fails.*1 when a check fails, and 2 when\s+it can't run/s, 'exit codes' );
	like( $self, qr/about a minute.*up to 3 minutes/s,                                    'runtime, warm and cold' );
	my $help = slurp('scripts/smoke.sh');
	like( $help, qr/^# Usage: scripts\/smoke\.sh \[LMS_URL\] \[PLAYER_MAC\] \[--skip-live\] \[--station <SERVICE_ID>\] \[--local <SERVICE_ID>\] \[-h\|--help\]$/m, 'smoke.sh: the usage line the README describes' );
};

subtest 'README screenshots: at least 9 PNGs in docs/images, each <= 200 KB, 1.8 MB in all, with alt text' => sub {
	my @images = $readme =~ /!\[([^\]]*)\]\(([^)\s]+)\)/g;
	my %alt;
	while ( my ( $alt, $file ) = splice( @images, 0, 2 ) ) { $alt{$file} = $alt }
	my @files = sort keys %alt;
	ok( @files >= 9, scalar(@files) . ' images embedded' );
	my $total = 0;
	for my $file (@files) {
		like( $file, qr{\Adocs/images/[\w.-]+\.png\z}, "$file: a PNG in docs/images/" );
		ok( length $alt{$file} >= 30, "$file: alt text \"$alt{$file}\"" );
		unlike( $alt{$file}, qr/screenshot|image of/i, "$file: the alt text says what the screen shows" );
		ok( -f $file, "$file exists" ) or next;
		my $size = -s $file;
		$total += $size;
		ok( $size <= 200 * 1024, "$file: $size bytes <= 200 KB" );
		is( substr( slurp( $file, ':raw' ), 0, 8 ), "\x89PNG\r\n\x1a\n", "$file: PNG signature" );
	}
	ok( $total <= 1.8 * 1024 * 1024, "all images: $total bytes <= 1.8 MB" );
	my %want = (
		'default-top-level.png'          => qr/Default web interface.*Home, Radio, Podcasts, News, Sport, Kids listen, Audiobooks, Programs, Search and My ABC listen/,
		'material-top-level.png'         => qr/ten ABC listen entries in the Material/,
		'default-kids-listen.png'        => qr/Kids listen/,
		'default-audiobook-chapters.png' => qr/Chapters/,
		'default-local-radio.png'        => qr/Local radio/,
		'default-program-episodes.png'   => qr/program's page/,
		'default-search-results.png'     => qr/Search results/,
		'default-settings.png'           => qr/settings page/,
		'material-now-playing.png'       => qr/Now Playing in the Material web interface while [^:]+ plays: the song title .*the artist .*(?:cover|artwork)/,
	);
	for my $shot ( sort keys %want ) {
		like( $alt{"docs/images/$shot"} // '', $want{$shot}, "a screenshot docs/images/$shot" );
	}
	my @unused = grep { my $f = $_; !grep { $_ eq $f } @files } glob('docs/images/*');
	is_deeply( \@unused, [], 'every file in docs/images is used' );
};

subtest 'docs: relative links and anchors resolve, link texts are descriptive, headings are in order' => sub {
	my %anchors;
	for my $doc (@DOCS) {
		$anchors{$doc} = { map { slug($_) => 1 } slurp($doc) =~ /^#+ (.+)$/mg };
	}
	for my $doc (@DOCS) {
		my $text = slurp($doc);
		$text =~ s/^\s*```.*?^\s*```//msg;    # not in code blocks
		my @links = $text =~ /\]\(([^)\s]+)\)/g;
		for my $link (@links) {
			next if $link =~ m{\A(?:https?:|mailto:)};
			my ( $path, $anchor ) = $link =~ /\A([^#]*)(?:#(.*))?\z/;
			my $target = length $path ? File::Spec->canonpath( File::Spec->catfile( dirname($doc), $path ) ) : $doc;
			$target =~ s{\A(?:[^/]+/\.\./)+}{};
			ok( -e $target, "$doc: $link -> $target exists" );
			if ( defined $anchor ) {
				ok( $anchors{$target} && $anchors{$target}->{$anchor}, "$doc: $link -> anchor #$anchor exists in $target" );
			}
		}
		my @vague = grep { /\A\s*(?:here|click here|this|link|this link)\s*\z/i } $text =~ /(?<!!)\[([^\]]*)\]\(/g;
		is_deeply( \@vague, [], "$doc: no link text like \"here\"" );

		my $level = 0;
		my @jumps;
		for my $hashes ( $text =~ /^(#+) /mg ) {
			push @jumps, $hashes if length($hashes) > $level + 1;
			$level = length $hashes;
		}
		is_deeply( \@jumps, [], "$doc: heading levels go # → ## → ### without skipping" );
	}
};

subtest 'docs: no private host names, addresses or keys' => sub {
	for my $doc ( @DOCS, 'scripts/smoke.sh' ) {
		my $text = slurp($doc);
		unlike( $text, qr/pi14|alintech/i, "$doc: no private host names" );
		my @ips = grep { $_ ne '127.0.0.1' } $text =~ /\b((?:\d{1,3}\.){3}\d{1,3})\b/g;
		is_deeply( \@ips, [], "$doc: no IP addresses" );
		unlike( $text, qr/\b[0-9a-f]{32}\b/, "$doc: nothing that looks like an API key" );
	}
};

subtest 'RELEASING.md keeps its sections' => sub {
	my $doc = slurp('RELEASING.md');
	is_deeply( [ $doc =~ /^## (.+)$/mg ], [ 'How to release', 'What the workflow does', 'Dry runs', 'Idempotency and repair', 'Verifying a release', 'Prerequisites and troubleshooting', 'Rules' ], 'R1\'s sections, in order' );
	like( $doc, qr/\Q$REPO_URL\E/, 'the install URL' );
	like( $doc, qr{raw\.githubusercontent\.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-<version>\.zip}, 'zips are served from the release-assets branch' );
};

subtest 'docs/official-repository.md' => sub {
	my $doc = slurp('docs/official-repository.md');
	my %sec = sections($doc);
	is_deeply( [ $doc =~ /^## (.+)$/mg ], [ 'How the official repository works', 'Prerequisites', 'Pre-submission checklist', 'Steps', 'What happens after the merge', 'Maintenance rules once listed' ], 'sections, in order' );
	like( $doc, qr/\A# Getting ABC listen into the official LMS plugin repository\n\n\*\*Status: not submitted\. The stakeholder decides whether and when to submit after accepting\s+v1\.0\.0 on their own server \(RQ4\)\.\*\*/, 'status: not submitted (RQ4)' );
	like( $sec{'How the official repository works'}, qr/`include\.json`.*`extensions\.xml`.*every 6 hours.*dies/s, 'include.json → extensions.xml, every 6 h, buildrepo.pl dies on bad XML' );

	my $pre = $sec{Prerequisites};
	like( $pre, qr{\Qcurl -sSL https://raw.githubusercontent.com/LMS-Community/lms-plugin-repository/master/extensions.xml | grep -c 'name="ABCListen"'\E}, 'the uniqueness check command' );
	like( $pre, qr/It printed `0` on \d{4}-\d{2}-\d{2}/, 'the uniqueness check: its dated result, 0' );
	like( $pre, qr/valid XML.*`buildrepo\.pl` dies/s,                  'prerequisite: valid XML' );
	like( $pre, qr/URL is stable.*\Q$REPO_URL\E/s,                     'prerequisite: stable raw URL' );
	like( $pre, qr/Zip names are versioned/,                           'prerequisite: versioned zip names' );
	like( $pre, qr/`minTarget` and `maxTarget` are both present.*`8\.3` \/ `\*`/s, 'prerequisite: minTarget 8.3, maxTarget *' );
	like( $pre, qr/category is valid.*`radio`/s,                       'prerequisite: category radio' );
	like( $pre, qr/icon URL is absolute/,                              'prerequisite: absolute icon URL' );
	like( $pre, qr/`sha` is correct/,                                  'prerequisite: correct sha' );

	like( $sec{'Pre-submission checklist'}, qr/accepted v1\.0\.0.*clean LMS.*`SMOKE: 15\/15 passed`/s, 'checklist: acceptance, clean install, smoke' );
	my $steps = $sec{Steps};
	like( $steps, qr/Fork/,                                'steps: fork' );
	like( $steps, qr/`include\.json`.*`"repositories"`/s, 'steps: add the URL to include.json' );
	like( $steps, qr/\Q"$REPO_URL",\E/,                    'steps: the exact URL' );
	like( $steps, qr/open a pull request.*unofficial/s,    'steps: the pull request says it is unofficial' );
	like( $sec{'Maintenance rules once listed'}, qr/Keep `repo\.xml` valid XML.*Never reuse a version number/s, 'maintenance rules' );

	my %repo = map { $_ => 1 } ( slurp('repo.xml') =~ /<plugin name="(\w+)"/ );
	ok( $repo{ABCListen}, 'repo.xml\'s plugin name is the ABCListen the check looks for' );
};

# The newest section with content: [Unreleased] while it has entries, otherwise (right after a
# release has moved them) the first "## [X.Y.Z] - YYYY-MM-DD" section. Returns its name and body.
sub newestChangelogSection {
	my $doc = shift;
	my ($unreleased) = $doc =~ /^## \[Unreleased\]\n(.*?)(?=^## |^\[[^\]]+\]: |\z)/ms;
	return ( '[Unreleased]', $unreleased ) if defined $unreleased && $unreleased =~ /\S/;
	my ( $version, $released ) = $doc =~ /^## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\n(.*?)(?=^## |^\[[^\]]+\]: |\z)/ms;
	return ( "[$version]", $released ) if defined $released && $released =~ /\S/;
	return;
}

subtest 'CHANGELOG.md: the newest section with content' => sub {
	my ( $name, $section ) = newestChangelogSection( slurp('CHANGELOG.md') );
	ok( defined $name, '[Unreleased] or the newest release section has entries (not both empty)' );
	$name //= '(none)';
	note("checking $name");
	ok( defined $section && $section =~ /\S/, "$name has entries" );
	like( $section // '', qr/^### Added\n.*^### Changed\n.*^### Known limitations\n/ms, "$name: Added, Changed and Known limitations" );
	like( $section // '', qr/Chapters \(N\)/,               "$name: audiobook chapters" );
	like( $section // '', qr/Segments \(N\).*Tracklist \(N\)/s, "$name: episode extras" );
	like( $section // '', qr/Latest episodes stays put/,     "$name: Latest episodes after an unfollow" );
	like( $section // '', qr/Header line too long/,          "$name: the install fix" );
	like( $section // '', qr/`scripts\/smoke\.sh/,           "$name: the self-test" );
};

subtest 'the plugin description: strings.txt and repo.xml agree' => sub {
	my ($desc) = slurp('repo.xml') =~ m{<desc lang="EN">([^<]*)</desc>};
	is( $desc, en('DESC'), 'repo.xml <desc> equals PLUGIN_ABCLISTEN_DESC' );
	like( en('DESC'), qr/\AUnofficial plugin for ABC listen/,                  'it starts with "Unofficial"' );
	like( en('DESC'), qr/Not affiliated with or endorsed by the ABC\.\z/,      'it ends with the disclaimer' );
	like( en('DESC'), qr/live ABC radio stations.*podcasts.*audiobooks.*search and followed programs/, 'it names the v1 features' );
};

done_testing();
