#!/usr/bin/perl
# The release-assets branch LMS downloads the plugin from (repo.xml's <url>, #62):
# scripts/publish-release-asset.sh against throwaway git repositories (orphan branch with a
# README, one commit per zip as the configured identity, never replaces a zip, dry run, retries
# and refusals, including an HTTP 403 from a local server and a rejection whose output has "403"
# in SHAs and a path, #75), and scripts/verify-download.sh against that local HTTP server (SHA1,
# retries until the file is served, redirects, and the 8,192-byte header line limit of LMS
# 9.1.1's Net::HTTP). Commit dates are fixed, so every commit SHA is the same on every run.

use strict;
use warnings;

use Cwd ();
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Test::More;

for my $tool (qw(git curl sha1sum)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	# CI must run these tests; locally they are skipped with a notice
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

my $PUBLISH = Cwd::abs_path('scripts/publish-release-asset.sh');
my $VERIFY  = Cwd::abs_path('scripts/verify-download.sh');
my $NAME    = 'Wilson Waters';
my $EMAIL   = 'wilsonwaters@users.noreply.github.com';

sub slurp {
	my $file = shift;
	open( my $fh, '<:raw', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub spew {
	my ( $file, $content ) = @_;
	open( my $fh, '>:raw', $file ) or die "Can't write $file: $!";
	print {$fh} $content;
	close $fh;
	return $file;
}

# run a command (optionally in another directory); returns (exit code, stdout+stderr)
sub run {
	my ( $cmd, %opts ) = @_;
	my $pid = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>&', \*STDOUT ) or die;
		if ( $opts{cwd} ) { chdir $opts{cwd} or die "chdir $opts{cwd}: $!" }
		exec(@$cmd) or die "exec $cmd->[0]: $!";
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return ( $? >> 8, $out );
}

# git in a throwaway repository, isolated from the user's and the system's git config
sub git {
	my ( $dir, @args ) = @_;
	my ( $rc, $out ) = run( [ 'git', @args ], cwd => $dir );
	die "git @args failed in $dir: $out" if $rc;
	chomp $out;
	return $out;
}
my $gitHome = tempdir( CLEANUP => 1 );
$ENV{$_} = $gitHome for qw(HOME XDG_CONFIG_HOME);
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
delete @ENV{qw(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE)};
# fixed dates: the commits, and so the SHAs in the push output, are the same on every run
$ENV{$_} = '2026-10-24T00:00:00+00:00' for qw(GIT_AUTHOR_DATE GIT_COMMITTER_DATE);

# a bare "origin" with a main branch, and a clone set up as the workflow sets up its checkout
my $tmp    = tempdir( CLEANUP => 1 );
my $origin = "$tmp/origin.git";
git( $tmp, 'init', '-q', '--bare', $origin );
git( $origin, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
sub checkout {
	my $dir = shift;
	git( $tmp, 'clone', '-q', $origin, $dir );
	git( $dir, 'config', 'user.name',  $NAME );
	git( $dir, 'config', 'user.email', $EMAIL );
	return $dir;
}
{
	my $work = "$tmp/work";
	git( $tmp, 'init', '-q', $work );
	git( $work, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	spew( "$work/repo.xml", "<extensions/>\n" );
	git( $work, 'add', 'repo.xml' );
	git( $work, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'main' );
	git( $work, 'push', '-q', $origin, 'main' );
}
my $co    = checkout("$tmp/checkout");
my $stale = checkout("$tmp/stale");    # cloned before release-assets exists; never fetched again

make_path("$tmp/zips/a", "$tmp/zips/b");
my %zip = (
	'0.3.0'     => spew( "$tmp/zips/a/ABCListen-0.3.0.zip", "PK zip 0.3.0\0\x01\x02" ),
	'0.3.0-bad' => spew( "$tmp/zips/b/ABCListen-0.3.0.zip", "PK something else" ),
	'0.4.0'     => spew( "$tmp/zips/a/ABCListen-0.4.0.zip", "PK zip 0.4.0" ),
	'0.5.0'     => spew( "$tmp/zips/a/ABCListen-0.5.0.zip", "PK zip 0.5.0" ),
	'0.6.0'     => spew( "$tmp/zips/a/ABCListen-0.6.0.zip", "PK zip 0.6.0" ),
	'0.7.0'     => spew( "$tmp/zips/a/ABCListen-0.7.0.zip", "PK zip 0.7.0" ),
);

sub publish { my ( $dir, @args ) = @_; return run( [ $PUBLISH, @args ], cwd => $dir ) }
sub tip     { my ($rc, $out) = run( [ 'git', 'rev-parse', '-q', '--verify', 'refs/heads/release-assets' ], cwd => $origin ); chomp $out; return $rc ? '' : $out }
sub files   { return [ split /\n/, git( $origin, 'ls-tree', '--name-only', $_[0] ) ] }

subtest 'publish-release-asset.sh: usage' => sub {
	my ( $rc, $out ) = publish($co);
	is( $rc, 2, 'no zip: usage error' );
	( $rc, $out ) = publish( $co, $zip{'0.3.0'}, $zip{'0.4.0'} );
	is( $rc, 2, 'two zips: usage error' );
	( $rc, $out ) = publish( $co, '--bogus', $zip{'0.3.0'} );
	is( $rc, 2, 'unknown option: usage error' );
	( $rc, $out ) = publish( $co, spew( "$tmp/zips/other.zip", 'x' ) );
	is( $rc, 1, 'a zip not named ABCListen-X.Y.Z.zip is refused' );
	like( $out, qr/not named ABCListen-X\.Y\.Z\.zip/, '... and says so' );
	( $rc, $out ) = publish( $co, "$tmp/zips/ABCListen-9.9.9.zip" );
	is( $rc, 1, 'a missing zip is refused' );
	is( tip(), '', 'nothing was pushed' );
};

subtest 'dry run: the orphan commit is made and shown, not pushed' => sub {
	my ( $rc, $out ) = publish( $co, '--dry-run', $zip{'0.3.0'} );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( $out, qr/release-assets does not exist on origin yet; creating it as an orphan branch/, 'creates the branch as an orphan' );
	like( $out, qr/^Author:    \Q$NAME <$EMAIL>\E$/m,    'shows the author' );
	like( $out, qr/^Committer: \Q$NAME <$EMAIL>\E$/m,    'and the committer' );
	like( $out, qr/README\.md\n.*ABCListen-0\.3\.0\.zip/s, 'and the files' );
	like( $out, qr/dry run: ABCListen-0\.3\.0\.zip not pushed/, 'says it pushed nothing' );
	is( tip(), '', 'release-assets still does not exist on origin' );
};

my $first;
subtest 'first publish: an orphan branch with a README and the zip' => sub {
	my ( $rc, $out ) = publish( $co, $zip{'0.3.0'} );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( $out, qr/published ABCListen-0\.3\.0\.zip to release-assets on origin/, 'reports the publish' );
	$first = tip();
	ok( $first, 'release-assets exists on origin' ) or return;
	is( git( $origin, 'log', '-1', '--format=%P', $first ), '', 'its first commit has no parent (orphan)' );
	my ($rc2) = run( [ 'git', 'merge-base', 'main', $first ], cwd => $origin );
	isnt( $rc2, 0, 'no history in common with main' );
	is_deeply( files($first), [ 'ABCListen-0.3.0.zip', 'README.md' ], 'files: the zip and README.md, nothing else' );
	is( git( $origin, 'cat-file', 'blob', "$first:ABCListen-0.3.0.zip" ), slurp( $zip{'0.3.0'} ), 'the zip is byte-for-byte the published file' );
	is( git( $origin, 'log', '-1', '--format=%an <%ae>|%cn <%ce>', $first ), "$NAME <$EMAIL>|$NAME <$EMAIL>", "authored and committed as $NAME <$EMAIL> (the configured identity)" );
	is( git( $origin, 'log', '-1', '--format=%s', $first ), 'Add ABCListen-0.3.0.zip', 'message: Add ABCListen-0.3.0.zip' );
	my $readme = git( $origin, 'cat-file', 'blob', "$first:README.md" );
	like( $readme, qr/Don't merge this branch/, "README: don't merge it" );
	like( $readme, qr/Never change or delete a zip here/, 'README: never change a zip' );
	like( $readme, qr/repo\.xml/, 'README: what it is for (repo.xml points LMS at it)' );
};

subtest 'the same zip again: nothing to do' => sub {
	my ( $rc, $out ) = publish( $co, $zip{'0.3.0'} );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( $out, qr/ABCListen-0\.3\.0\.zip is already on release-assets .* with the same content; nothing to publish/, 'says so' );
	is( tip(), $first, 'no new commit' );
};

subtest 'a different zip of the same name is never replaced' => sub {
	my ( $rc, $out ) = publish( $co, $zip{'0.3.0-bad'} );
	is( $rc, 1, 'exit 1' );
	like( $out, qr/already has a different ABCListen-0\.3\.0\.zip .*never replaced/, 'says why' );
	is( tip(), $first, 'release-assets unchanged' );
	( $rc, $out ) = publish( $co, '--dry-run', $zip{'0.3.0-bad'} );
	is( $rc, 1, 'refused on a dry run too' );
};

my $second;
subtest 'next release: one commit on top, from a checkout that never fetched the branch' => sub {
	my ( $rc, $out ) = publish( $stale, $zip{'0.4.0'} );
	is( $rc, 0, 'exit 0' ) or diag $out;
	$second = tip();
	is( git( $origin, 'log', '-1', '--format=%P', $second ), $first, 'parent: the previous tip' );
	is_deeply( files($second), [ 'ABCListen-0.3.0.zip', 'ABCListen-0.4.0.zip', 'README.md' ], 'both zips and the README' );
	is( git( $origin, 'rev-parse', "$second:ABCListen-0.3.0.zip" ), git( $origin, 'rev-parse', "$first:ABCListen-0.3.0.zip" ), 'the earlier zip is unchanged' );
	is( git( $origin, 'log', '-1', '--format=%an <%ae>|%cn <%ce>|%s', $second ), "$NAME <$EMAIL>|$NAME <$EMAIL>|Add ABCListen-0.4.0.zip", 'identity and message' );
	is( git( $co, 'status', '--porcelain' ), '', 'the working tree and index are untouched' );
};

# ---- a local HTTP server: downloads for verify-download.sh, and a push answered with a 403 ----

# GET /<case>/<file>: ok (200), later (404 twice, then 200), redirect (302 to ok), long (302 with
# a 9,243-character Content-Security-Policy line, as GitHub's release download sends), forbidden
# (403, as GitHub answers a push made with a read-only token), missing.
my $BODY   = "PK the zip\0\x01";
my $SHA1   = do { my ( undef, $o ) = run( [ 'sh', '-c', 'sha1sum "$1"', 'sh', spew( "$tmp/body", $BODY ) ] ); ( split ' ', $o )[0] };
my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 10, ReuseAddr => 1, Proto => 'tcp' ) or die "listen: $!";
my $port   = $server->sockport;
my $pid    = fork() // die "fork: $!";
if ( !$pid ) {
	my %hits;
	while ( my $c = $server->accept ) {
		my $request = <$c> // '';
		while ( my $line = <$c> ) { last if $line =~ /^\r?\n\z/ }
		my ($path) = $request =~ m{^GET (\S+)};
		my ($case) = ( $path // '' ) =~ m{^/(\w+)/};
		$case //= '';
		$hits{$case}++;
		spew( "$tmp/hits", join( '', map {"$_ $hits{$_}\n"} sort keys %hits ) );
		my ( $status, @headers ) = ('404 Not Found');
		my $body = "not found\n";
		if ( $case eq 'ok' || ( $case eq 'later' && $hits{later} > 2 ) ) {
			( $status, $body ) = ( '200 OK', $BODY );
		}
		elsif ( $case eq 'redirect' || $case eq 'long' ) {
			$status  = '302 Found';
			$body    = '';
			@headers = ("Location: http://127.0.0.1:$port/ok/ABCListen-1.0.0.zip");
			push @headers, 'Content-Security-Policy: ' . ( 'x' x ( 9243 - 25 ) ) if $case eq 'long';
		}
		elsif ( $case eq 'forbidden' ) {
			( $status, $body ) = ( '403 Forbidden', "forbidden\n" );
		}
		print {$c} join( "\r\n", "HTTP/1.1 $status", 'Connection: close', 'Content-Length: ' . length($body), @headers, '', $body );
		close $c;
	}
	POSIX::_exit(0);
}
close $server;
END { kill 'TERM', $pid if $pid }

sub hits { my %h = -e "$tmp/hits" ? ( slurp("$tmp/hits") =~ /^(\w+) (\d+)$/mg ) : (); return $h{ $_[0] } // 0 }
# the local server is reached directly, never through a proxy the environment may set (call it
# after local %ENV)
sub direct {
	delete @ENV{qw(http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY)};
	$ENV{$_} = '127.0.0.1,localhost' for qw(no_proxy NO_PROXY);
}
my $URL = "http://127.0.0.1:$port";

# ---- publish-release-asset.sh: refusals and retries ----

# pre-receive hook in origin: writes a line per push to $count, then runs $body
sub hook {
	my ($body) = @_;
	my $hook = "$origin/hooks/pre-receive";
	if ( !defined $body ) { unlink $hook; return }
	spew( $hook, "#!/bin/sh\necho x >> '$tmp/pushes'\n$body\n" );
	chmod 0755, $hook;
	unlink "$tmp/pushes";
}
sub pushes { return -e "$tmp/pushes" ? scalar( () = slurp("$tmp/pushes") =~ /x/g ) : 0 }

subtest 'a refused push (GH013 rulesets) is not retried' => sub {
	hook(q{echo 'remote: error: GH013: Repository rule violations found for refs/heads/release-assets.' >&2; exit 1});
	my ( $rc, $out ) = publish( $co, $zip{'0.5.0'} );
	is( $rc, 1, 'exit 1' );
	like( $out, qr/push to release-assets refused/, 'says the push was refused' );
	is( pushes(), 1, 'one push, no retry' );
	is( tip(), $second, 'release-assets unchanged' );
	hook(undef);
};

# A read-only GITHUB_TOKEN: GitHub answers the push with HTTP 403. This checkout fetches from
# origin as usual, but pushes to the local server, which answers every request with a 403; git
# itself reports it ("The requested URL returned error: 403"), and that line is the only sign.
subtest 'an HTTP 403 on push is a refusal: not retried' => sub {
	my $readonly = checkout("$tmp/readonly");
	git( $readonly, 'config', 'remote.origin.pushurl', "$URL/forbidden/origin.git" );
	local %ENV = %ENV;
	direct();
	$ENV{GIT_TERMINAL_PROMPT} = 0;
	my ( $rc, $out ) = publish( $readonly, $zip{'0.7.0'} );
	is( $rc, 1, 'exit 1' );
	like( $out, qr/^fatal: unable to access '\Q$URL\E\/forbidden\/origin\.git\/': The requested URL returned error: 403$/m, 'git reports the HTTP 403' );
	unlike( $out, qr/permission|denied|protected branch|gh0(?:06|13)/i, 'and nothing else that says refused' );
	like( $out, qr/push to release-assets refused/, 'taken for a refusal' );
	unlike( $out, qr/retrying/, 'not retried' );
	is( hits('forbidden'), 1, 'one push' );
	is( tip(), $second, 'release-assets unchanged' );
};

# The first push is rejected after someone else moved the branch (another zip added); the retry
# must build on the new tip and keep that zip. The rejection names fixed fake SHAs and a path that
# have "403" in them: on CI a rejected commit 86f98138…f8a40345 was once taken for a 403 refusal
# and not retried (#75).
my @SHA403 = qw(86f98138c2d4e6f8a1b3c5d7e9f0a2b4f8a40345 4031e5c7a9b2d4f6e8c0a1b3d5f7e9c2b4d6f8a0);
my $PATH403 = '/srv/git/403/origin.git/refs/heads/release-assets.lock';
subtest 'a rejected push is retried on the new tip, even with "403" in its SHAs and paths' => sub {
	like( $_, qr/\A(?=[0-9a-f]{40}\z).*403/, "fake SHA $_ has \"403\" in it" ) for @SHA403;
	my $other = "$tmp/other";
	checkout($other);
	my ( $rc, $out ) = publish( $other, '--dry-run', $zip{'0.6.0'} );
	my ($moved) = $out =~ /^commit ([0-9a-f]{40})$/m;
	ok( $moved, 'a commit adding 0.6.0 on the current tip' ) or return diag $out;
	git( $other, 'push', '-q', $origin, "$moved:refs/test/moved" );

	hook(
		qq{if [ "\$(wc -l < '$tmp/pushes')" -eq 1 ]; then env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git update-ref refs/heads/release-assets $moved; }
		  . qq{echo "error: cannot lock ref 'refs/heads/release-assets': is at $SHA403[0] but expected $SHA403[1]" >&2; }
		  . qq{echo "error: Unable to create '$PATH403': File exists." >&2; exit 1; fi}
	);
	( $rc, $out ) = publish( $co, $zip{'0.5.0'} );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( $out, qr/^remote: error: cannot lock ref 'refs\/heads\/release-assets': is at $SHA403[0] but expected $SHA403[1] *$/m, 'the rejection names SHAs with "403" in them' );
	like( $out, qr/^remote: error: Unable to create '\Q$PATH403\E': File exists\. *$/m,                                          'and a path with "403" in it' );
	unlike( $out, qr/refused/, 'not taken for a refusal' );
	like( $out, qr/push rejected \(release-assets moved\?\); retrying on its new tip, retry 1 of 3/, 'retried' );
	is( pushes(), 2, 'two pushes' );
	my $tip = tip();
	is( git( $origin, 'log', '-1', '--format=%P', $tip ), $moved, 'built on the moved tip' );
	is_deeply( files($tip), [ map( {"ABCListen-$_.zip"} qw(0.3.0 0.4.0 0.5.0 0.6.0) ), 'README.md' ], 'keeps the zip added meanwhile' );
	hook(undef);
};

# ---- verify-download.sh against the local HTTP server ----

sub verify {
	local %ENV = %ENV;
	direct();
	my $start = time;
	my ( $rc, $out ) = run( [ $VERIFY, @_ ] );
	return ( $rc, $out, time - $start );
}

subtest 'verify-download.sh: usage' => sub {
	is( ( verify("$URL/ok/ABCListen-1.0.0.zip") )[0], 2, 'no SHA1: usage error' );
	is( ( verify( "$URL/ok/ABCListen-1.0.0.zip", 'abc' ) )[0], 2, 'bad SHA1: usage error' );
	is( ( verify( '--timeout', 'soon', "$URL/ok/ABCListen-1.0.0.zip", $SHA1 ) )[0], 2, 'bad --timeout: usage error' );
};

subtest 'verify-download.sh: the served file and its SHA1' => sub {
	my ( $rc, $out ) = verify( '--timeout', 0, "$URL/ok/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 0, 'right SHA1: exit 0' ) or diag $out;
	like( $out, qr/verified \Q$URL\E\/ok\/ABCListen-1\.0\.0\.zip: HTTP 200, sha1 $SHA1, ${\ length $BODY} bytes/, 'reports it' );
	( $rc, $out ) = verify( '--timeout', 0, "$URL/ok/ABCListen-1.0.0.zip", uc $SHA1 );
	is( $rc, 0, 'SHA1 in upper case: exit 0' ) or diag $out;
	( $rc, $out ) = verify( '--timeout', 0, "$URL/ok/ABCListen-1.0.0.zip", 'f' x 40 );
	is( $rc, 1, 'wrong SHA1: exit 1' );
	like( $out, qr/did not verify after 1 tries in 0s; last try: sha1 $SHA1, expected f{40}/, 'says why' );
	( $rc, $out ) = verify( '--timeout', 0, "$URL/redirect/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 0, 'a redirect with short headers is followed, as LMS does' ) or diag $out;
};

subtest 'verify-download.sh: retries until the file is served (CDN delay)' => sub {
	my ( $rc, $out ) = verify( '--timeout', 20, '--interval', 1, "$URL/later/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 0, 'exit 0 once it is served' ) or diag $out;
	like( $out, qr/try 1: HTTP 404; trying again in 1s/, 'try 1: 404' );
	like( $out, qr/try 2: HTTP 404; trying again in 1s/, 'try 2: 404' );
	like( $out, qr/\(try 3\)/, 'verified on try 3' );
	is( hits('later'), 3, 'three requests' );

	my $elapsed;
	( $rc, $out, $elapsed ) = verify( '--timeout', 2, '--interval', 1, "$URL/missing/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 1, 'never served: exit 1' );
	like( $out, qr/did not verify after \d+ tries in 2s; last try: HTTP 404/, 'gives up when the time is up' );
	ok( $elapsed <= 10, "and not much later (${elapsed}s)" );

	my $closed = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1 ) or die;
	my $deadPort = $closed->sockport;
	close $closed;
	( $rc, $out ) = verify( '--timeout', 0, "http://127.0.0.1:$deadPort/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 1, 'no server: exit 1' );
	like( $out, qr/last try: no response/, 'says there was no response' );
};

subtest 'verify-download.sh: a header line over 8,192 bytes fails at once' => sub {
	my ( $rc, $out, $elapsed ) = verify( '--timeout', 60, '--interval', 1, "$URL/long/ABCListen-1.0.0.zip", $SHA1 );
	is( $rc, 1, 'exit 1' );
	like( $out, qr/sends a response header line longer than 8192 bytes, which LMS 9\.1\.1 can't read \("Header line too long"\): 9244: Content-Security-Policy: x+\.\.\./, 'says which line and why' );
	is( hits('long'), 1, 'one request: no retry' );
	ok( $elapsed < 30, "fails at once (${elapsed}s), not after the timeout" );
};

done_testing();
