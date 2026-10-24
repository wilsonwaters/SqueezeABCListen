#!/usr/bin/perl
# .github/workflows/release.yml: triggers and dry runs, permissions (write for the release job
# only), concurrency, CI first (workflow_call of ci.yml), the no-op for a push that leaves
# <version> alone once that version is in repo.xml on main, the guards, release notes from
# CHANGELOG.md with a GitHub-generated fallback, the uploaded-asset check, the copy on the
# release-assets branch that repo.xml points LMS at (published, then its raw URL verified, before
# repo.xml changes; #62), repo.xml targets from the released zip, and the repo.xml commit
# (identity defined once, as the repository owner; [skip ci]; only repo.xml; retried 3x;
# refusals recognised). The scripts of the "Read version", "Existing release (no-op or repair)",
# "Publish to release-assets" and "Update repo.xml" steps are also run here, against throwaway
# git repositories.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

my $ROOT = getcwd();

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub spew {
	my ( $file, $content ) = @_;
	open( my $fh, '>:encoding(UTF-8)', $file ) or die "Can't write $file: $!";
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
@ENV{qw(GIT_AUTHOR_NAME GIT_COMMITTER_NAME)}   = ('Test') x 2;
@ENV{qw(GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL)} = ('test@example.invalid') x 2;

my $yml = slurp('.github/workflows/release.yml');

# top-level jobs: name => text; steps of all jobs: name => text
my ($jobsText) = $yml =~ /^jobs:\n(.*)\z/ms;
my %job;
$job{$1} = $2 while ( $jobsText // '' ) =~ /^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\z)/msg;
my %step;
$step{$1} = $2 while $yml =~ /^      - name: ([^\n]+)\n(.*?)(?=^      - |^  [\w-]+:\n|\z)/msg;

# the `if:` condition of a step
sub stepIf { my ($cond) = ( $step{ $_[0] } // '' ) =~ /^        if: (.+)$/m; return $cond // '' }

# the shell script of a step's `run: |` block, de-indented
sub stepRun {
	my ($block) = ( $step{ $_[0] } // '' ) =~ /^        run: \|\n((?:(?: {10}.*)?\n)*)/m;
	return '' unless defined $block;
	$block =~ s/^ {10}//mg;
	return $block;
}

# run a step's script as GitHub Actions does (shell: bash = bash --noprofile --norc -eo pipefail)
# in $dir with %env added; returns (exit code, output, $GITHUB_OUTPUT, $GITHUB_ENV, summary)
sub runStep {
	my ( $name, $dir, %env ) = @_;
	my $tmp    = tempdir( CLEANUP => 1 );
	my $script = spew( "$tmp/step.sh", stepRun($name) );
	spew( "$tmp/$_", '' ) for qw(output env summary);
	local @ENV{ keys %env } = values %env;
	local $ENV{GITHUB_OUTPUT}       = "$tmp/output";
	local $ENV{GITHUB_ENV}          = "$tmp/env";
	local $ENV{GITHUB_STEP_SUMMARY} = "$tmp/summary";
	local $ENV{RUNNER_TEMP}         = $tmp;
	my ( $rc, $out ) = run( [ 'bash', '--noprofile', '--norc', '-eo', 'pipefail', $script ], cwd => $dir );
	return ( $rc, $out, map { slurp("$tmp/$_") } qw(output env summary) );
}

# a step's script must not use ${{ }} expressions, so that runStep runs it exactly as Actions does
sub runnable {
	my $name   = shift;
	my $script = stepRun($name);
	ok( length $script, "\"$name\" has a run script" ) or return 0;
	unlike( $script, qr/\$\{\{/, "\"$name\" uses no \${{ }} expressions (they come in through env)" ) or return 0;
	return 1;
}

subtest 'triggers' => sub {
	like( $yml, qr/^  workflow_dispatch:\n    inputs:\n      dry_run:\n(?:        .*\n)*?        type: boolean\n/m, 'workflow_dispatch with a boolean dry_run input' );
	like( $yml, qr/^  push:\n    branches: \[main\]\n    paths: \['ABCListen\/install\.xml'\]$/m, 'push to main touching ABCListen/install.xml' );

	my ($paths) = $yml =~ /^  pull_request:\n    paths:\n((?:      - .*\n)+)/m;
	my @paths = ( $paths // '' ) =~ /^      - '([^']+)'$/mg;
	is_deeply(
		[ sort @paths ],
		[ sort qw(.github/workflows/release.yml ABCListen/install.xml repo.xml CHANGELOG.md scripts/build.sh scripts/check-package.sh scripts/update-repo-xml.pl scripts/changelog-section.sh scripts/publish-release-asset.sh scripts/push-refused.sh scripts/verify-download.sh) ],
		'pull requests touching the release files get a dry run'
	);
	like( $yml, qr/DRY_RUN: \$\{\{ github\.event_name == 'pull_request' \|\| inputs\.dry_run == true \}\}/, 'pull requests and dispatch with dry_run are dry runs' );
};

subtest 'permissions: write for the release job only; CI first' => sub {
	like( $yml, qr/^permissions:\n  contents: read\n/m, 'workflow default: contents: read' );
	like( $job{release} // '', qr/^    permissions:\n      contents: write\n/m, 'the release job (release, tag, repo.xml push): contents: write' );
	my @blocks;
	push @blocks, "$1permissions:\n$2" while $yml =~ /^( *)permissions:\n((?:\1  \S.*\n)+)/mg;
	is_deeply(
		\@blocks,
		[ "permissions:\n  contents: read\n", "    permissions:\n      contents: write\n" ],
		'those are the only permissions: no other job gets write, and no other scope is granted'
	);
	like( $job{checks} // '', qr{^    uses: \./\.github/workflows/ci\.yml$}m, 'CI checks job is a workflow_call of ci.yml' );
	like( slurp('.github/workflows/ci.yml'), qr/^  workflow_call:/m, 'ci.yml can be called' );
	like( $job{release} // '', qr/^    needs: \[version, checks\]$/m, 'the release job waits for the CI checks' );
};

subtest 'concurrency: real releases from main share one group, never cancelled' => sub {
	my @groups = $yml =~ /^(\s*)concurrency:\n/mg;
	is_deeply( \@groups, [''], 'one concurrency block, for the whole workflow (the no-op decision runs inside it)' );
	like( $yml, qr/^concurrency:\n  group: (.+)\n  cancel-in-progress: false\n/m, 'a running release is never cancelled' );
	my ($group) = $yml =~ /^concurrency:\n  group: \$\{\{ (.+) \}\}\n/m;
	is(
		$group // '',
		q{(github.event_name == 'pull_request' || inputs.dry_run || github.ref != 'refs/heads/main') && format('release-run-{0}', github.run_id) || 'release'},
		"pull requests, dry runs and runs on other branches get a group per run, so they can't cancel a waiting release"
	);
};

subtest 'a push that leaves <version> alone is a no-op only once repo.xml on main has it' => sub {
	my $read = $step{'Read version'} // '';
	like( $read, qr/BEFORE: \$\{\{ github\.event\.before \}\}/,                    'knows the commit before the push' );
	like( $read, qr/git show "\$BEFORE:ABCListen\/install\.xml"/,                   'reads install.xml as it was before the push' );
	like( $read, qr/git fetch --no-tags origin \+refs\/heads\/main:refs\/remotes\/origin\/main/, 'fetches the latest main' );
	like( $read, qr/git show origin\/main:repo\.xml/,                                 'reads repo.xml there' );
	like( $read, qr/if \[\[ "\$main_v" == "\$V" \]\]; then\n(?:.*\n)*?\s+release=false$/m, 'release=false only when it already has the version' );
	my @false = $read =~ /release=false/g;
	is( scalar @false, 1, 'and nowhere else' );
	like( $read, qr/echo "release=\$release" >> "\$GITHUB_OUTPUT"/,                  'passed on as a job output' );
	for my $name (qw(checks release)) {
		like( $job{$name} // '', qr/^    if: needs\.version\.outputs\.release == 'true'$/m, "$name job only runs when there is something to release" );
	}
};

# Runs the "Read version" script against a real history. The case that matters: 0.3.0 is bumped
# (push A), its run waits behind another release, and a later push B touches install.xml without
# changing <version>; GitHub cancels A's waiting run, and B's run must release 0.3.0.
subtest 'the no-op decision, run against a git history' => sub {
	runnable('Read version') or return;

	my $tmp    = tempdir( CLEANUP => 1 );
	my $origin = "$tmp/origin.git";
	my $work   = "$tmp/work";
	my $co     = "$tmp/checkout";
	git( $tmp, 'init', '-q', '--bare', $origin );
	git( $tmp, 'init', '-q', $work );
	git( $work, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	make_path("$work/ABCListen");

	my $repoXml = slurp('repo.xml');
	my $commit  = sub {
		my ( $installV, $optionsURL, $repoV ) = @_;
		my $options = $optionsURL ? "\t<optionsURL>$optionsURL</optionsURL>\n" : '';
		spew( "$work/ABCListen/install.xml", qq{<?xml version="1.0" encoding="UTF-8"?>\n<extension>\n\t<version>$installV</version>\n$options</extension>\n} );
		spew( "$work/repo.xml", $repoXml =~ s/(<plugin\s[^>]*?\bname="ABCListen"[^>]*?\sversion=")[^"]*"/$1$repoV"/r );
		git( $work, 'add', 'ABCListen/install.xml', 'repo.xml' );
		git( $work, 'commit', '-q', '-m', "install.xml $installV, repo.xml $repoV" );
		return git( $work, 'rev-parse', 'HEAD' );
	};
	my $released = $commit->( '0.2.0', '',               '0.2.0' );    # 0.2.0, released
	my $bump     = $commit->( '0.3.0', '',               '0.2.0' );    # push A: bump to 0.3.0
	my $options  = $commit->( '0.3.0', 'settings.html',  '0.2.0' );    # push B: same version
	my $repoDone = $commit->( '0.3.0', 'settings.html',  '0.3.0' );    # the workflow's repo.xml commit for 0.3.0
	my $later    = $commit->( '0.3.0', 'settings2.html', '0.3.0' );    # another push, same version
	git( $work, 'push', '-q', $origin, 'main' );
	git( $tmp, 'clone', '-q', $origin, $co );

	# run the step at $sha (the pushed commit), with main on origin at $main
	my $decide = sub {
		my (%a) = @_;
		git( $origin, 'update-ref', 'refs/heads/main', $a{main} // $a{sha} );
		git( $co, 'update-ref', 'refs/remotes/origin/main', $released );    # stale until fetched
		git( $co, 'checkout', '-q', '--detach', $a{sha} );
		my ( $rc, $out, $output, undef, $summary ) = runStep(
			'Read version', $co,
			GITHUB_EVENT_NAME => $a{event} // 'push',
			GITHUB_REF        => 'refs/heads/main',
			GITHUB_SHA        => $a{sha},
			DRY_RUN           => 'false',
			BEFORE            => $a{before} // '',
		);
		is( $rc, 0, "$a{name}: step succeeds" ) or diag $out;
		my ($release) = $output =~ /^release=(.*)$/m;
		my ($version) = $output =~ /^version=(.*)$/m;
		is( $version, '0.3.0', "$a{name}: version=0.3.0" );
		is( $release, $a{want}, "$a{name}: release=$a{want}" ) or diag $out;
		return ( $out, $summary );
	};

	$decide->( name => 'push that bumps <version>', sha => $bump, before => $released, want => 'true' );
	my ($out) = $decide->( name => 'push that leaves <version> alone, bump not yet released', sha => $options, before => $bump, want => 'true' );
	like( $out, qr/repo\.xml on main is at 0\.2\.0: 0\.3\.0 was never released/, '... and says why it releases' );
	$decide->( name => 'same push, after the repo.xml commit for 0.3.0 reached main', sha => $options, before => $bump, main => $later, want => 'false' );
	my ( undef, $summary ) = $decide->( name => 'push that leaves <version> alone, already released', sha => $later, before => $repoDone, want => 'false' );
	like( $summary, qr/^### No-op: <version> is still 0\.3\.0 and repo\.xml on main is at 0\.3\.0/m, '... and says so in the run summary' );
	$decide->( name => 'push with no "before" commit', sha => $later, before => '0' x 40, want => 'true' );
	$decide->( name => 'push whose "before" commit is unknown', sha => $later, before => 'f' x 40, want => 'true' );
	$decide->( name => 'workflow_dispatch', sha => $later, event => 'workflow_dispatch', want => 'true' );
};

subtest 'guards' => sub {
	like( $step{'Read version'} // '', qr/\[\[ ! "\$V" =~ \^\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$ \]\]/, 'version must be X.Y.Z' );
	my $guards = $step{Guards} // '';
	like( $guards, qr/git ls-remote --tags --refs origin 'refs\/tags\/v\*'/, 'reads the existing v* tags' );
	like( $guards, qr/sort -V \| tail -n 1\)"/,                               'finds the highest one' );
	like( $guards, qr/::error::version \$V is lower than the highest release tag/, 'refuses a downgrade' );
	like( $guards, qr/plugin\[\@name="ABCListen"\]/,                          'repo.xml on main must have the ABCListen entry' );
	like( $guards, qr/::error::repo\.xml on main has no ABCListen plugin entry/, '... or the release stops' );
	like( $guards, qr/tag v\$V exists but has no GitHub Release/,              'a tag without a release needs a human' );
};

subtest 'existing release: no-op or repair, never a new asset' => sub {
	my $existing = $step{'Existing release (no-op or repair)'} // '';
	is( stepIf('Existing release (no-op or repair)'), q{env.RELEASE_EXISTS == 'true'}, 'runs when the release exists' );
	like( $existing, qr/gh release download "v\$V"/, 'hashes the existing asset' );
	like( $existing, qr/ACTION=none/,   'nothing to do when repo.xml already points at it' );
	like( $existing, qr/ACTION=repair/, 'otherwise repairs repo.xml from it' );
	like( $existing, qr/\[\[ "\$main_url" == "\$ZIP_URL" \]\]/, 'the no-op compares repo.xml\'s url with the raw release-assets URL (ZIP_URL), not the GitHub Release URL' );
	unlike( $existing, qr/ASSET_URL/, 'and never with the GitHub Release URL' );
	is( stepIf('Build'), q{env.RELEASE_EXISTS == 'false'}, 'builds only when there is no release yet' );
	unlike( $yml, qr/gh release (?:upload|delete|edit)/, 'never uploads to, deletes or edits an existing release' );
};

# Runs the "Existing release (no-op or repair)" script with a stand-in gh that "downloads" a
# fixed asset, against an origin whose main has a given repo.xml and maybe a release-assets
# branch. The case that matters (#62): 0.3.0, released with repo.xml pointing at its GitHub
# Release asset, must be repaired, not reported as "nothing to do".
subtest 'existing release: the no-op decision, run against git repositories' => sub {
	runnable('Existing release (no-op or repair)') or return;
	my @missing = grep { my $tool = $_; !grep { -x "$_/$tool" } split /:/, $ENV{PATH} } qw(xmllint sha1sum);
	if (@missing) {
		fail("not installed: @missing") if $ENV{CI};
		diag("skipping the run of \"Existing release (no-op or repair)\": not installed: @missing");
		return;
	}

	my $tmp = tempdir( CLEANUP => 1 );
	make_path( "$tmp/bin", "$tmp/asset", "$tmp/other" );
	my $asset = spew( "$tmp/asset/ABCListen-0.3.0.zip", "the released 0.3.0 zip\n" );
	my $other = spew( "$tmp/other/ABCListen-0.3.0.zip", "some other zip\n" );
	my ( undef, $shaOut ) = run( [ 'sha1sum', $asset ] );
	my ($sha) = split ' ', $shaOut;
	my $gh = spew( "$tmp/bin/gh", <<'EOF' );
#!/usr/bin/env bash
# stand-in for "gh release download vV --pattern NAME --dir DIR": copies $FAKE_ASSET there
[[ "$1 $2" == "release download" ]] || { echo "unexpected: gh $*" >&2; exit 1; }
shift 3
while [[ $# -gt 0 ]]; do
  case "$1" in --pattern) p="$2"; shift 2 ;; --dir) d="$2"; shift 2 ;; *) shift ;; esac
done
cp "$FAKE_ASSET" "$d/$p"
EOF
	chmod 0755, $gh;

	my $zipUrl    = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-0.3.0.zip';
	my $assetUrl  = 'https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v0.3.0/ABCListen-0.3.0.zip';
	my $committed = slurp("$ROOT/repo.xml");
	my $n         = 0;
	my $decide    = sub {
		my (%a) = @_;
		my $dir    = "$tmp/case" . ++$n;
		my $origin = "$dir/origin.git";
		my $work   = "$dir/work";
		my $co     = "$dir/checkout";
		make_path($dir);
		git( $dir, 'init', '-q', '--bare', $origin );
		git( $dir, 'init', '-q', $work );
		git( $work, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
		spew( "$work/repo.xml", $committed =~ s{(<plugin\s[^>]*?\sversion=")[^"]*"}{${1}0.3.0"}r =~ s{<url>[^<]*</url>}{<url>$a{url}</url>}r =~ s{<sha>[^<]*</sha>}{<sha>$a{sha}</sha>}r );
		git( $work, 'add', 'repo.xml' );
		git( $work, 'commit', '-q', '-m', 'main' );
		git( $work, 'push', '-q', $origin, 'main' );
		if ( $a{published} ) {
			git( $work, 'checkout', '-q', '--orphan', 'release-assets' );
			git( $work, 'rm', '-q', '-rf', '.' );
			spew( "$work/ABCListen-0.3.0.zip", slurp( $a{published} ) );
			git( $work, 'add', 'ABCListen-0.3.0.zip' );
			git( $work, 'commit', '-q', '-m', 'Add ABCListen-0.3.0.zip' );
			git( $work, 'push', '-q', $origin, 'release-assets' );
		}
		git( $dir, 'clone', '-q', $origin, $co );
		my ( $rc, $out, undef, $env ) = runStep(
			'Existing release (no-op or repair)', $co,
			PATH          => "$tmp/bin:$ENV{PATH}",
			FAKE_ASSET    => $asset,
			V             => '0.3.0',
			ZIP_NAME      => 'ABCListen-0.3.0.zip',
			ZIP_URL       => $zipUrl,
			ASSETS_BRANCH => 'release-assets',
		);
		my ($action) = $env =~ /^ACTION=(.*)$/m;
		return ( $rc, $out, $action // '', $env );
	};

	my ( $rc, $out, $action, $env ) = $decide->( url => $assetUrl, sha => $sha );
	is( $rc, 0, '0.3.0 with its GitHub Release URL in repo.xml: step succeeds' ) or diag $out;
	is( $action, 'repair', '... and repairs (the published v0.3.0 state)' );
	like( $out, qr/stale: repo\.xml url is '\Q$assetUrl\E', not \Q$zipUrl\E/, '... because of the url' );
	like( $out, qr/stale: ABCListen-0\.3\.0\.zip is not on release-assets/, '... and the missing release-assets copy' );
	like( $env, qr/^SHA=$sha$/m,                                 '... from the existing asset\'s SHA1' );
	like( $env, qr/^ZIP=.*\/existing\/ABCListen-0\.3\.0\.zip$/m, '... and that file' );

	( $rc, $out, $action ) = $decide->( url => $zipUrl, sha => $sha, published => $asset );
	is( $rc, 0, 'raw URL, same SHA1, zip on release-assets: step succeeds' ) or diag $out;
	is( $action, 'none', '... nothing to do' );
	like( $out, qr/nothing to do: release v0\.3\.0 exists, ABCListen-0\.3\.0\.zip is on release-assets/, '... and says so' );

	( $rc, $out, $action ) = $decide->( url => $zipUrl, sha => $sha );
	is( $action, 'repair', 'raw URL and SHA1 in repo.xml but no release-assets copy: repair' ) or diag $out;

	( $rc, $out, $action ) = $decide->( url => $zipUrl, sha => 'f' x 40, published => $asset );
	is( $action, 'repair', 'zip on release-assets but another SHA1 in repo.xml: repair' ) or diag $out;
	like( $out, qr/stale: repo\.xml sha is 'f{40}', not $sha/, '... because of the sha' );

	( $rc, $out, $action ) = $decide->( url => $zipUrl, sha => $sha, published => $other );
	is( $rc, 1, 'a different zip of that name on release-assets: the step fails' );
	like( $out, qr/::error::release-assets already has ABCListen-0\.3\.0\.zip with sha1 [0-9a-f]{40}, but release v0\.3\.0's asset has $sha\. A published zip is never replaced/, '... and says a published zip is never replaced' );
	is( $action, '', '... before choosing an action' );
};

subtest 'release notes from CHANGELOG.md, GitHub-generated as the fallback' => sub {
	my $notes = $step{'Release notes'};
	ok( $notes, 'a "Release notes" step' ) or return;
	is( stepIf('Release notes'), '', 'it runs on every path, dry runs included' );
	like( $notes, qr/scripts\/changelog-section\.sh "\$V" > "\$notes"/, 'takes the CHANGELOG.md section for V' );
	like( $notes, qr/cat "\$notes"/,                                     'prints the notes it would use' );

	my $create = $step{'Create release'} // '';
	like( $create, qr/notes=\(--generate-notes\)/,                            'fallback: --generate-notes' );
	like( $create, qr/notes=\(--notes-file "\$NOTES_FILE"\)/,                 'CHANGELOG notes when there is a section' );
	like( $create, qr/gh release create "v\$V" "\$ZIP" .*"\$\{notes\[@\]\}"/, 'gh release create, server-side, with them' );
};

subtest 'dry runs publish nothing; the uploaded asset is verified' => sub {
	for my $name ( 'Create release', 'Verify uploaded asset', 'Verify download URL', 'Commit and push repo.xml' ) {
		like( stepIf($name), qr/env\.DRY_RUN != 'true'/, "$name: skipped on dry runs" );
	}
	unlike( $yml, qr/^\s+git tag\b|git push[^\n]*(?:--tags|refs\/tags)/m, 'never creates or pushes a git tag itself' );

	my $verify = $step{'Verify uploaded asset'} // '';
	like( $verify, qr/gh release download "v\$V" --pattern "\$ZIP_NAME"/,  'downloads the uploaded asset' );
	like( $verify, qr/got="\$\(sha1sum "\$dir\/\$ZIP_NAME"/,                'hashes it' );
	like( $verify, qr/if \[\[ "\$got" != "\$SHA" \]\]; then\n.*::error::/, 'and fails unless it matches the built zip' );

	my %scripts = map { $_ => 1 } $yml =~ m{\b(scripts/[\w.-]+)}g;
	ok( scalar keys %scripts, 'the workflow runs scripts from scripts/' );
	for my $script ( sort keys %scripts ) {
		ok( -x $script, "$script exists and is executable (the workflow runs it directly)" );
	}

	my $update = $step{'Update repo.xml'} // '';
	like( $update, qr/scripts\/update-repo-xml\.pl --version "\$V" --sha "\$SHA" --url "\$ZIP_URL"/, 'update-repo-xml.pl, with the raw release-assets URL' );
	like( $update, qr/xmllint --noout repo\.xml/,       'xmllint' );
	like( $update, qr/git --no-pager diff -- repo\.xml/, 'shows the repo.xml diff' );
};

# LMS 9.1.1 can't read GitHub's release-download redirect (#62): repo.xml points at the copy on
# the release-assets branch, served by raw.githubusercontent.com.
subtest 'release-assets: published, then its raw URL verified, before repo.xml changes' => sub {
	my $release = $job{release} // '';
	like( $release, qr/^      ASSETS_BRANCH: release-assets$/m, 'ASSETS_BRANCH: release-assets' );
	my ($zipUrl) = $release =~ /^      ZIP_URL: (.+)$/m;
	is(
		$zipUrl // '',
		'https://raw.githubusercontent.com/${{ github.repository }}/release-assets/ABCListen-${{ needs.version.outputs.version }}.zip',
		'ZIP_URL: the zip of the version on that branch, on raw.githubusercontent.com'
	);
	like( $release, qr{^      ASSET_URL: https://github\.com/\$\{\{ github\.repository \}\}/releases/download/}m, 'ASSET_URL stays the GitHub Release asset (for people)' );
	my @urls = $yml =~ /--url "\$(\w+)"/g;
	is_deeply( [ sort { $a cmp $b } keys %{ { map { $_ => 1 } @urls } } ], ['ZIP_URL'], 'repo.xml only ever gets ZIP_URL' );

	my $publish = stepRun('Publish to release-assets');
	ok( length $publish, 'a "Publish to release-assets" step' ) or return;
	is( stepIf('Publish to release-assets'), q{env.ACTION != 'none'}, 'it runs on releases and repairs, dry runs included' );
	like( $publish, qr/args=\(--branch "\$ASSETS_BRANCH"\)/,                                  'publishes to ASSETS_BRANCH' );
	like( $publish, qr/if \[\[ "\$DRY_RUN" == true \]\]; then args\+=\(--dry-run\); fi/,     'with --dry-run on dry runs (nothing pushed)' );
	like( $publish, qr/^scripts\/publish-release-asset\.sh "\$\{args\[@\]\}" "\$ZIP"$/m,       'the zip that was built and verified, or the existing asset on repair' );
	like( $publish, qr/git config user\.name "\$COMMIT_NAME"\ngit config user\.email "\$COMMIT_EMAIL"\n/, 'committed as COMMIT_NAME/COMMIT_EMAIL' );

	my $verify = stepRun('Verify download URL');
	ok( length $verify, 'a "Verify download URL" step' ) or return;
	like( $verify, qr/^scripts\/verify-download\.sh --timeout 360 --interval 15 "\$ZIP_URL" "\$SHA"$/m, 'downloads ZIP_URL and checks its SHA1, retrying for up to 6 minutes (longer than raw.githubusercontent.com caches a 404)' );
	like( $job{release} // '', qr/^    timeout-minutes: (?:2[0-9]|[3-5][0-9])$/m, 'the job has time for that wait' );

	my @order = ( 'Verify uploaded asset', 'Publish to release-assets', 'Verify download URL', 'Update repo.xml', 'Commit and push repo.xml' );
	my @at    = map { index( $yml, "      - name: $_\n" ) } @order;
	ok( !grep( { $_ < 0 } @at ) && join( ',', @at ) eq join( ',', sort { $a <=> $b } @at ), 'order: ' . join( ' -> ', @order ) );

	# one rule for a refused push, scripts/push-refused.sh, in both places (#75)
	my $script = slurp('scripts/publish-release-asset.sh');
	my $commit = $step{'Commit and push repo.xml'} // '';
	like( $script, qr/^push_refused="\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)\/push-refused\.sh"$/m, 'publish-release-asset.sh uses scripts/push-refused.sh, next to it' );
	like( $script, qr/^  if "\$push_refused" <<<"\$out"; then\n    die "push to \$branch refused/m,  '... to decide that a failed push to release-assets was refused' );
	like( $commit, qr/^ +if scripts\/push-refused\.sh <<<"\$out"; then$/m,                        'so does the repo.xml push' );
	unlike( $script . $commit, qr/refused\(\)|\*403\*|\*denied\*|\$\{1,,\}/,                     'neither has a rule of its own' );
};

# Runs the "Publish to release-assets" script in a throwaway checkout: a dry run pushes nothing;
# a real run creates the branch as COMMIT_NAME/COMMIT_EMAIL. No other git identity is set (as on
# a runner), so the step's own git config is what names the author and committer.
subtest 'release-assets publish step, run against a git repository' => sub {
	runnable('Publish to release-assets') or return;
	local %ENV = %ENV;
	my $tmp    = tempdir( CLEANUP => 1 );
	my $origin = "$tmp/origin.git";
	my $work   = "$tmp/work";
	my $co     = "$tmp/checkout";
	git( $tmp, 'init', '-q', '--bare', $origin );
	git( $origin, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	git( $tmp, 'init', '-q', $work );
	git( $work, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	make_path("$work/scripts");
	for my $script (qw(publish-release-asset.sh push-refused.sh)) {
		spew( "$work/scripts/$script", slurp("$ROOT/scripts/$script") );
		chmod 0755, "$work/scripts/$script";
	}
	git( $work, 'add', '.' );
	git( $work, 'commit', '-q', '-m', 'main' );
	git( $work, 'push', '-q', $origin, 'main' );
	git( $tmp, 'clone', '-q', $origin, $co );
	my $zip = spew( "$tmp/ABCListen-0.3.0.zip", "zip\n" );
	delete @ENV{qw(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL)};

	my %env = ( ASSETS_BRANCH => 'release-assets', ZIP => $zip, COMMIT_NAME => 'Wilson Waters', COMMIT_EMAIL => 'wilsonwaters@users.noreply.github.com' );
	my ( $rc, $out ) = runStep( 'Publish to release-assets', $co, %env, DRY_RUN => 'true' );
	is( $rc, 0, 'dry run: step succeeds' ) or diag $out;
	like( $out, qr/dry run: ABCListen-0\.3\.0\.zip not pushed/, 'dry run: not pushed' );
	my ($lsRc) = run( [ 'git', 'rev-parse', '-q', '--verify', 'refs/heads/release-assets' ], cwd => $origin );
	isnt( $lsRc, 0, 'dry run: no release-assets branch on origin' );

	( $rc, $out ) = runStep( 'Publish to release-assets', $co, %env, DRY_RUN => 'false' );
	is( $rc, 0, 'real run: step succeeds' ) or diag $out;
	is( git( $origin, 'log', '-1', '--format=%an <%ae>|%cn <%ce>|%s', 'release-assets' ), 'Wilson Waters <wilsonwaters@users.noreply.github.com>|Wilson Waters <wilsonwaters@users.noreply.github.com>|Add ABCListen-0.3.0.zip', 'real run: release-assets created, authored and committed as COMMIT_NAME <COMMIT_EMAIL>' );
	is( git( $origin, 'ls-tree', '--name-only', 'release-assets' ), "ABCListen-0.3.0.zip\nREADME.md", 'real run: the zip and the README' );
};

subtest 'repo.xml commit: the repository owner, [skip ci], only repo.xml, retried 3 times' => sub {
	my @names  = $yml =~ /^\s+COMMIT_NAME: (.+)$/mg;
	my @emails = $yml =~ /^\s+COMMIT_EMAIL: (.+)$/mg;
	is_deeply( \@names,  ['Wilson Waters'],                          'COMMIT_NAME defined once: Wilson Waters' );
	is_deeply( \@emails, ['wilsonwaters@users.noreply.github.com'], 'COMMIT_EMAIL defined once: the owner noreply address' );
	like( $yml, qr/^env:\n  COMMIT_NAME: .+\n  COMMIT_EMAIL: .+\n/m, 'as workflow-level env: one setting to switch' );
	unlike( $yml, qr/git config user\.\w+ ["']?github-actions\[bot\]/, 'not committed as github-actions[bot]' );

	my $commit = $step{'Commit and push repo.xml'};
	ok( $commit, 'a "Commit and push repo.xml" step' ) or return;
	like( $commit, qr/git config user\.name "\$COMMIT_NAME"/,                      'git user.name' );
	like( $commit, qr/git config user\.email "\$COMMIT_EMAIL"/,                    'git user.email' );
	like( $commit, qr/git commit -m "Release v\$V: update repo\.xml \[skip ci\]"/, 'message has [skip ci]' );
	like( $commit, qr/^\s+git add repo\.xml$/m,                                    'stages repo.xml' );
	unlike( $yml, qr/git add (?:-A|--all|\.|-u)|git commit (?:-a|--all)/,         'and nothing else' );
	like( $commit, qr/\[\[ "\$staged" != repo\.xml \]\]/,                           'refuses to commit if anything else is staged' );
	like( $commit, qr/git push origin HEAD:refs\/heads\/main/,                      'pushed to main' );
	like( $commit, qr/for attempt in 1 2 3 4; do/,                                  'one push plus up to 3 retries' );
	like( $commit, qr/git reset --hard origin\/main\n(?:.*\n)*?\s+scripts\/update-repo-xml\.pl/, 'a retry re-applies the change on the latest main' );
	like( $commit, qr/::error::could not push repo\.xml after 3 retries/,           'then fails loudly' );

	like( $yml, qr/^      GH_TOKEN: \$\{\{ github\.token \}\}$/m, 'GITHUB_TOKEN for the GitHub CLI' );
	unlike( $yml, qr/secrets\./,                                   'no other token or secret' );
	unlike( $yml, qr/persist-credentials:\s*false/,                'checkout keeps GITHUB_TOKEN for the push' );
};

# scripts/push-refused.sh: the one rule both pushes (release-assets and repo.xml) use. Only a real
# refusal counts; a "403" inside a SHA, a path or a port number is a rejected push, retried (#75).
subtest 'a refused push is recognised (HTTP 403, permission, workflows, GH006, GH013), a "403" in a SHA or path is not' => sub {
	my $commit = $step{'Commit and push repo.xml'} // '';
	like( $commit, qr/if scripts\/push-refused\.sh <<<"\$out"; then\n\s+echo "::error::push to main refused/, 'a refusal fails the step instead of retrying' );
	ok( -x 'scripts/push-refused.sh', 'scripts/push-refused.sh is executable' ) or return;
	my @cases = (
		[ 1, "remote: error: GH006: Protected branch update failed for refs/heads/main.\nremote: error: Changes must be made through a pull request." ],
		[ 1, " ! [remote rejected] HEAD -> main (protected branch hook declined)" ],
		[ 1, "remote: error: GH013: Repository rule violations found for refs/heads/main.\nremote: - Changes must be made through a pull request." ],
		[ 1, "remote: error: gh013: repository rule violations found" ],
		[ 1, "remote: Permission to wilsonwaters/SqueezeABCListen.git denied to github-actions[bot].\nfatal: unable to access 'https://github.com/wilsonwaters/SqueezeABCListen/': The requested URL returned error: 403" ],
		[ 1, "fatal: unable to access 'https://github.com/wilsonwaters/SqueezeABCListen/': The requested URL returned error: 403" ],
		[ 1, "error: RPC failed; HTTP 403 curl 22 The requested URL returned error: 403" ],
		[ 1, "< HTTP/2 403" ],
		[ 1, "remote: PERMISSION DENIED" ],
		[ 1, "git\@github.com: Permission denied (publickey)." ],
		[ 1, " ! [remote rejected] HEAD -> main (refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission)" ],
		[ 0, " ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs to 'https://github.com/wilsonwaters/SqueezeABCListen'\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally." ],
		[ 0, " ! [rejected]        HEAD -> main (non-fast-forward)" ],
		[ 0, " ! [remote rejected] 86f98138c2d4e6f8a1b3c5d7e9f0a2b4f8a40345 -> release-assets (pre-receive hook declined)\nerror: failed to push some refs to 'https://github.com/wilsonwaters/SqueezeABCListen'" ],
		[ 0, "remote: error: cannot lock ref 'refs/heads/main': is at 4031e5c7a9b2d4f6e8c0a1b3d5f7e9c2b4d6f8a0 but expected 86f98138c2d4e6f8a1b3c5d7e9f0a2b4f8a40345" ],
		[ 0, "remote: error: Unable to create '/srv/git/403/origin.git/refs/heads/main.lock': File exists." ],
		[ 0, "To /tmp/Ab403xYz12/origin.git\n ! [rejected]        HEAD -> main (fetch first)" ],
		[ 0, "To http://127.0.0.1:40312/origin.git\n ! [rejected]        HEAD -> main (fetch first)" ],
		[ 0, " ! [rejected]        HEAD -> access-denied (fetch first)" ],
		[ 0, "" ],
	);
	for my $case (@cases) {
		my ( $want, $output ) = @$case;
		my ($rc) = run( [ 'bash', '-c', 'scripts/push-refused.sh <<<"$1"', 'push-refused', $output ] );
		is( $rc, $want ? 0 : 1, ( $want ? 'refused: ' : 'retried: ' ) . ( ( split /\n/, $output )[0] // '(no output)' ) );
	}
	is( ( run( [ 'scripts/push-refused.sh', 'output' ] ) )[0], 2, 'an argument: usage error (the output comes on stdin)' );
};

# Runs the "Commit and push repo.xml" script against a throwaway origin. Its pre-receive hook
# first rejects the push the way a moved main does, naming SHAs and a path with "403" in them:
# the step retries on the new main (#75). Then it refuses the next push the way GitHub refuses a
# read-only token: the step fails at once.
subtest 'repo.xml push, run against a git repository: a rejected push is retried, a refused one is not' => sub {
	runnable('Commit and push repo.xml') or return;
	if ( !grep { -x "$_/xmllint" } split /:/, $ENV{PATH} ) {
		# CI must run this; locally it is skipped with a notice
		fail('not installed: xmllint') if $ENV{CI};
		diag('skipping the run of "Commit and push repo.xml": not installed: xmllint');
		return;
	}
	my $tmp    = tempdir( CLEANUP => 1 );
	my $origin = "$tmp/origin.git";
	my $work   = "$tmp/work";
	my $co     = "$tmp/checkout";
	git( $tmp, 'init', '-q', '--bare', $origin );
	git( $origin, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	git( $tmp, 'init', '-q', $work );
	git( $work, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
	make_path("$work/scripts");
	for my $script (qw(update-repo-xml.pl push-refused.sh)) {
		spew( "$work/scripts/$script", slurp("$ROOT/scripts/$script") );
		chmod 0755, "$work/scripts/$script";
	}
	spew( "$work/repo.xml", slurp("$ROOT/repo.xml") );
	git( $work, 'add', '.' );
	git( $work, 'commit', '-q', '-m', 'main' );
	git( $work, 'push', '-q', $origin, 'main' );
	git( $tmp, 'clone', '-q', $origin, $co );
	# what main moves on to while the release runs; the hook puts it there
	spew( "$work/README.md", "moved on\n" );
	git( $work, 'add', 'README.md' );
	git( $work, 'commit', '-q', '-m', 'moved on' );
	my $moved = git( $work, 'rev-parse', 'HEAD' );
	git( $work, 'push', '-q', $origin, "$moved:refs/test/moved" );

	my $installXml = spew( "$tmp/install.xml", slurp("$ROOT/ABCListen/install.xml") );
	my $sha        = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';
	# repo.xml in the checkout as "Update repo.xml" leaves it for version $v; the step's env
	my $updated = sub {
		my $v   = shift;
		my $url = "https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-$v.zip";
		my ( $rc, $out ) = run( [ 'scripts/update-repo-xml.pl', '--version', $v, '--sha', $sha, '--url', $url, '--install-xml', $installXml ], cwd => $co );
		die "update-repo-xml.pl failed: $out" if $rc;
		return ( V => $v, SHA => $sha, ZIP_URL => $url, INSTALL_XML => $installXml, COMMIT_NAME => 'Wilson Waters', COMMIT_EMAIL => 'wilsonwaters@users.noreply.github.com' );
	};
	my $hook = sub {
		spew( "$origin/hooks/pre-receive", "#!/bin/sh\necho x >> '$tmp/pushes'\n$_[0]\n" );
		chmod 0755, "$origin/hooks/pre-receive";
		unlink "$tmp/pushes";
	};
	my $pushes = sub { return -e "$tmp/pushes" ? scalar( () = slurp("$tmp/pushes") =~ /x/g ) : 0 };

	my @sha403 = qw(86f98138c2d4e6f8a1b3c5d7e9f0a2b4f8a40345 4031e5c7a9b2d4f6e8c0a1b3d5f7e9c2b4d6f8a0);
	$hook->(
		qq{if [ "\$(wc -l < '$tmp/pushes')" -eq 1 ]; then env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git update-ref refs/heads/main $moved; }
		  . qq{echo "error: cannot lock ref 'refs/heads/main': is at $sha403[0] but expected $sha403[1]" >&2; }
		  . qq{echo "error: Unable to create '/srv/git/403/origin.git/refs/heads/main.lock': File exists." >&2; exit 1; fi}
	);
	my ( $rc, $out ) = runStep( 'Commit and push repo.xml', $co, $updated->('1.0.1') );
	is( $rc, 0, 'main moved: the step succeeds' ) or diag $out;
	like( $out, qr/is at $sha403[0] but expected $sha403[1]/, 'the rejection names SHAs with "403" in them' );
	like( $out, qr{Unable to create '/srv/git/403/},          'and a path with "403" in it' );
	unlike( $out, qr/refused/, 'it is not taken for a refusal' );
	like( $out, qr/push rejected \(main moved\?\); re-applying on the latest main, retry 1 of 3/, 'but retried' );
	is( $pushes->(), 2, 'two pushes' );
	is( git( $origin, 'log', '-1', '--format=%P|%s', 'main' ), "$moved|Release v1.0.1: update repo.xml [skip ci]", 'the repo.xml commit is on the moved main' );
	like( git( $origin, 'show', 'main:repo.xml' ), qr/<plugin name="ABCListen" version="1\.0\.1"/, 'with the new version' );

	$hook->(q{echo 'Permission to wilsonwaters/SqueezeABCListen.git denied to github-actions[bot].' >&2; exit 1});
	my $main = git( $origin, 'rev-parse', 'main' );
	( $rc, $out ) = runStep( 'Commit and push repo.xml', $co, $updated->('1.0.2') );
	is( $rc, 1, 'read-only token: the step fails' );
	like( $out, qr/::error::push to main refused/, 'as a refusal' );
	unlike( $out, qr/push rejected/, 'not retried' );
	is( $pushes->(), 1, 'one push' );
	is( git( $origin, 'rev-parse', 'main' ), $main, 'main unchanged' );
};

# Runs the "Update repo.xml" script (pull request path: no fetch of main) in a throwaway checkout
# whose ABCListen/install.xml (main's) has other targets than the install.xml inside the zip.
subtest 'repo.xml minTarget/maxTarget come from the released zip, not from main' => sub {
	my @calls = $yml =~ /^ +(scripts\/update-repo-xml\.pl .*)$/mg;
	is( scalar @calls, 2, 'update-repo-xml.pl runs in two places (update, and re-apply after a rejected push)' );
	like( $_, qr/ --install-xml "\$INSTALL_XML"$/, "with --install-xml \"\$INSTALL_XML\": $_" ) for @calls;
	my $update = $step{'Update repo.xml'} // '';
	like( $update, qr/unzip -p "\$ZIP" install\.xml > "\$INSTALL_XML"/,       'INSTALL_XML is the zip\'s install.xml (built zip, or the existing asset on repair)' );
	like( $update, qr/echo "INSTALL_XML=\$INSTALL_XML" >> "\$GITHUB_ENV"/,     'and is kept for the retry in the next step' );
	my $unzipAt = index( $update, 'unzip -p' );
	ok( $unzipAt >= 0 && $unzipAt < index( $update, 'git checkout -B release-repo-xml origin/main' ), 'it is read before main is checked out' );

	runnable('Update repo.xml') or return;
	my @missing = grep { my $tool = $_; !grep { -x "$_/$tool" } split /:/, $ENV{PATH} } qw(xmllint zip unzip);
	if (@missing) {
		# CI must run this; locally it is skipped with a notice
		fail("not installed: @missing") if $ENV{CI};
		diag("skipping the run of \"Update repo.xml\": not installed: @missing");
		return;
	}

	my ( $rc, $out );
	my $tmp = tempdir( CLEANUP => 1 );
	my $co  = "$tmp/checkout";
	make_path( "$co/ABCListen", "$co/scripts", "$tmp/pkg" );
	spew( "$co/scripts/update-repo-xml.pl", slurp("$ROOT/scripts/update-repo-xml.pl") );
	chmod 0755, "$co/scripts/update-repo-xml.pl";
	spew( "$co/repo.xml",              slurp("$ROOT/repo.xml") );
	spew( "$co/ABCListen/install.xml", slurp("$ROOT/ABCListen/install.xml") =~ s{<minVersion>[^<]*}{<minVersion>8.3}r =~ s{<maxVersion>[^<]*}{<maxVersion>*}r );
	git( $tmp, 'init', '-q', $co );
	git( $co, 'add', '.' );
	git( $co, 'commit', '-q', '-m', 'main' );
	spew( "$tmp/pkg/install.xml", slurp("$ROOT/ABCListen/install.xml") =~ s{<minVersion>[^<]*}{<minVersion>9.0}r =~ s{<maxVersion>[^<]*}{<maxVersion>9.*}r );
	( $rc, $out ) = run( [ 'zip', '-q', '-r', "$tmp/ABCListen-0.3.0.zip", '.' ], cwd => "$tmp/pkg" );
	is( $rc, 0, 'test zip built' ) or diag $out;

	my $sha = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';
	my ( $env, $summary );
	( $rc, $out, undef, $env, $summary ) = runStep(
		'Update repo.xml', $co,
		GITHUB_EVENT_NAME => 'pull_request',
		DRY_RUN           => 'true',
		ACTION            => 'release',
		V                 => '0.3.0',
		SHA               => $sha,
		ZIP               => "$tmp/ABCListen-0.3.0.zip",
		ZIP_NAME          => 'ABCListen-0.3.0.zip',
		ASSETS_BRANCH     => 'release-assets',
		ZIP_URL           => 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-0.3.0.zip',
		ASSET_URL         => 'https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v0.3.0/ABCListen-0.3.0.zip',
	);
	is( $rc, 0, 'step succeeds' ) or diag $out;
	my $repo = slurp("$co/repo.xml");
	like( $repo, qr/<plugin name="ABCListen" version="0\.3\.0" minTarget="9\.0" maxTarget="9\.\*">/, 'targets from the zip\'s install.xml (9.0 .. 9.*), not main\'s (8.3 .. *)' );
	like( $repo, qr/<sha>$sha<\/sha>/,                                                     'sha set' );
	like( $repo, qr{<url>https://raw\.githubusercontent\.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-0\.3\.0\.zip</url>}, 'url set to ZIP_URL' );
	like( $env,  qr/^INSTALL_XML=.*\/released-install\.xml$/m,                              'INSTALL_XML exported for the commit step' );
	like( $summary, qr/^\+.*minTarget="9\.0"/m,                                             'the summary diff shows it' );
};

done_testing();
