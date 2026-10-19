#!/usr/bin/perl
# .github/workflows/release.yml: triggers and dry runs, permissions, CI first (workflow_call of
# ci.yml), the no-op for a push that leaves <version> alone, the guards, release notes from
# CHANGELOG.md with a GitHub-generated fallback, the uploaded-asset check, and the repo.xml
# commit (identity defined once, as the repository owner; [skip ci]; only repo.xml; retried 3x).

use strict;
use warnings;

use Test::More;

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

my $yml = slurp('.github/workflows/release.yml');

# top-level jobs: name => text; steps of all jobs: name => text
my ($jobsText) = $yml =~ /^jobs:\n(.*)\z/ms;
my %job;
$job{$1} = $2 while ( $jobsText // '' ) =~ /^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\z)/msg;
my %step;
$step{$1} = $2 while $yml =~ /^      - name: ([^\n]+)\n(.*?)(?=^      - |^  [\w-]+:\n|\z)/msg;

# the `if:` condition of a step
sub stepIf { my ($cond) = ( $step{ $_[0] } // '' ) =~ /^        if: (.+)$/m; return $cond // '' }

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

subtest 'permissions and CI first' => sub {
	like( $yml, qr/^permissions:\n  contents: write\n/m, 'permissions: contents: write' );
	like( $job{checks} // '', qr{^    uses: \./\.github/workflows/ci\.yml$}m, 'CI checks job is a workflow_call of ci.yml' );
	like( slurp('.github/workflows/ci.yml'), qr/^  workflow_call:/m, 'ci.yml can be called' );
	like( $job{release} // '', qr/^    needs: \[version, checks\]$/m, 'the release job waits for the CI checks' );
};

subtest 'a push that leaves <version> alone is a no-op' => sub {
	my $read = $step{'Read version'} // '';
	like( $read, qr/BEFORE: \$\{\{ github\.event\.before \}\}/,                    'knows the commit before the push' );
	like( $read, qr/git show "\$BEFORE:ABCListen\/install\.xml"/,                   'reads install.xml as it was before the push' );
	like( $read, qr/if \[\[ "\$before_v" == "\$V" \]\]; then\n(?:.*\n)*?\s+release=false$/m, 'same version: release=false' );
	like( $read, qr/echo "release=\$release" >> "\$GITHUB_OUTPUT"/,                  'passed on as a job output' );
	for my $name (qw(checks release)) {
		like( $job{$name} // '', qr/^    if: needs\.version\.outputs\.release == 'true'$/m, "$name job only runs when there is something to release" );
	}
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

done_testing();
