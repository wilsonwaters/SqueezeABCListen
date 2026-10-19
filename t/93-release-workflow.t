#!/usr/bin/perl
# .github/workflows/release.yml: triggers and dry runs, permissions (write for the release job
# only), concurrency, CI first (workflow_call of ci.yml), the no-op for a push that leaves
# <version> alone once that version is in repo.xml on main, the guards, release notes from
# CHANGELOG.md with a GitHub-generated fallback, the uploaded-asset check, repo.xml targets from
# the released zip, and the repo.xml commit (identity defined once, as the repository owner;
# [skip ci]; only repo.xml; retried 3x; refusals recognised). The scripts of the "Read version",
# "Update repo.xml" and "Commit and push repo.xml" steps are also run here, against throwaway
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
		[ sort qw(.github/workflows/release.yml ABCListen/install.xml repo.xml CHANGELOG.md scripts/build.sh scripts/check-package.sh scripts/update-repo-xml.pl scripts/changelog-section.sh) ],
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
	is( stepIf('Build'), q{env.RELEASE_EXISTS == 'false'}, 'builds only when there is no release yet' );
	unlike( $yml, qr/gh release (?:upload|delete|edit)/, 'never uploads to, deletes or edits an existing release' );
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
	for my $name ( 'Create release', 'Verify uploaded asset', 'Commit and push repo.xml' ) {
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
	like( $update, qr/scripts\/update-repo-xml\.pl --version "\$V" --sha "\$SHA" --url "\$ASSET_URL"/, 'update-repo-xml.pl' );
	like( $update, qr/xmllint --noout repo\.xml/,       'xmllint' );
	like( $update, qr/git --no-pager diff -- repo\.xml/, 'shows the repo.xml diff' );
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

subtest 'a refused push is recognised in any case (403, denied, GH006 protected branch, GH013 rulesets)' => sub {
	my $commit = $step{'Commit and push repo.xml'} // '';
	my ($refused) = $commit =~ /^ +(refused\(\) \{.*\})$/m;
	ok( $refused, 'a one-line refused() helper' ) or return;
	like( $commit, qr/if refused "\$out"; then\n\s+echo "::error::push to main refused/, 'a refusal fails the step instead of retrying' );
	like( $refused, qr/local o="\$\{1,,\}"/,      'it lower-cases the output first' );
	unlike( $commit, qr/"\$out" == \*/,            'no case-sensitive match on the raw output left over' );
	my @cases = (
		[ 1, "remote: error: GH006: Protected branch update failed for refs/heads/main.\nremote: error: Changes must be made through a pull request." ],
		[ 1, "remote: error: GH013: Repository rule violations found for refs/heads/main.\nremote: - Changes must be made through a pull request." ],
		[ 1, "remote: error: gh013: repository rule violations found" ],
		[ 1, "remote: Permission to wilsonwaters/SqueezeABCListen.git denied to github-actions[bot].\nfatal: unable to access 'https://github.com/wilsonwaters/SqueezeABCListen/': The requested URL returned error: 403" ],
		[ 1, "remote: PERMISSION DENIED" ],
		[ 0, " ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs to 'https://github.com/wilsonwaters/SqueezeABCListen'\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally." ],
		[ 0, " ! [rejected]        HEAD -> main (non-fast-forward)" ],
	);
	for my $case (@cases) {
		my ( $want, $output ) = @$case;
		my ($rc) = run( [ 'bash', '-c', "$refused\nrefused \"\$1\"", 'refused', $output ] );
		is( $rc == 0 ? 1 : 0, $want, ( $want ? 'refused: ' : 'retried: ' ) . ( split /\n/, $output )[0] );
	}
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
		ASSET_URL         => 'https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v0.3.0/ABCListen-0.3.0.zip',
	);
	is( $rc, 0, 'step succeeds' ) or diag $out;
	my $repo = slurp("$co/repo.xml");
	like( $repo, qr/<plugin name="ABCListen" version="0\.3\.0" minTarget="9\.0" maxTarget="9\.\*">/, 'targets from the zip\'s install.xml (9.0 .. 9.*), not main\'s (8.3 .. *)' );
	like( $repo, qr/<sha>$sha<\/sha>/,                                                     'sha set' );
	like( $env,  qr/^INSTALL_XML=.*\/released-install\.xml$/m,                              'INSTALL_XML exported for the commit step' );
	like( $summary, qr/^\+.*minTarget="9\.0"/m,                                             'the summary diff shows it' );
};

done_testing();
