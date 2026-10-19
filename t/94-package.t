#!/usr/bin/perl
# scripts/build.sh and scripts/check-package.sh: the real build has the layout LMS expects and
# passes the package checks; bad manifests stop the build; junk is left out and symlinks are
# stored as files; each crafted bad zip, and a repo.xml that disagrees with install.xml, fails
# the matching check. Needs zip, unzip and sha1sum (CI installs them; locally the test is
# skipped with a notice when one is missing).

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

for my $tool (qw(zip unzip sha1sum xmllint)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	# CI must run these tests; locally they are skipped with a notice
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

my $ROOT = getcwd();

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

sub copyTree {
	my ( $from, $to ) = @_;
	my ( $rc, $out ) = run( [ 'cp', '-R', $from, $to ] );
	die "cp failed: $out" if $rc;
	return $to;
}

sub zipDir {
	my ( $dir, $zip ) = @_;
	my ( $rc, $out ) = run( [ 'zip', '-q', '-r', $zip, '.' ], cwd => $dir );
	die "zip failed: $out" if $rc;
	return $zip;
}

sub sha1File {
	my ( $zip, $sha ) = @_;
	my ($name) = $zip =~ m{([^/]+)\z};
	spew( "$zip.sha1", "$sha  $name\n" );
	return;
}

sub entries {
	my ( undef, $list ) = run( [ 'unzip', '-Z1', shift ] );
	return split /\n/, $list;
}

sub checkPackage { return run( [ "$ROOT/scripts/check-package.sh", '--zip', shift ] ) }

sub failLines { return grep { /^FAIL / } split /\n/, shift }

# incompressible bytes, so a zip holding them really is that big
sub randomBytes {
	my $n = shift;
	if ( open( my $fh, '<:raw', '/dev/urandom' ) ) {
		my $got = read( $fh, my $buf, $n );
		close $fh;
		return $buf if defined $got && $got == $n;
	}
	return pack( 'N*', map { int rand 2**32 } 1 .. int( $n / 4 ) + 1 );
}

my $tmp = tempdir( CLEANUP => 1 );
my ($version) = slurp('ABCListen/install.xml') =~ m{<version>([^<]*)</version>};
my $name = "ABCListen-$version.zip";

subtest 'real build' => sub {
	my $out = "$tmp/dist";
	my ( $rc, $stdout ) = run( [ 'scripts/build.sh', '--out', $out ] );
	is( $rc, 0, 'build.sh exits 0' ) or diag $stdout;
	like( $stdout, qr{^zip=\Q$out/$name\E$}m, 'prints the zip path' );
	like( $stdout, qr{^sha1=[0-9a-f]{40}$}m,  'prints the sha1' );

	ok( -f "$out/$name",      "$name written" );
	ok( -f "$out/$name.sha1", "$name.sha1 written" );

	my @entries = entries("$out/$name");
	for my $file ( 'install.xml', 'Plugin.pm', 'strings.txt', 'HTML/EN/plugins/ABCListen/html/images/icon.png' ) {
		ok( ( grep { $_ eq $file } @entries ), "$file at the zip root" );
	}
	is( ( grep { m{^(?:ABCListen|t|dev|ai-state|scripts|docs|\.github)/} } @entries ), 0, 'no ABCListen/, t/, dev/, ai-state/, scripts/, docs/ or .github/ entries' );

	my ($sha) = $stdout =~ /^sha1=(\S+)/m;
	is( slurp("$out/$name.sha1"), "$sha  $name\n", '.sha1 is in sha1sum format: <hex><two spaces><file name>' );
	my ( $crc, $check ) = run( [ 'sha1sum', '-c', "$name.sha1" ], cwd => $out );
	is( $crc, 0, 'sha1sum -c passes' ) or diag $check;
	like( $check, qr/^\Q$name\E: OK$/m, 'sha1sum -c prints OK' );

	# a second build replaces the zip instead of adding to it
	spew( "$out/$name", 'not a zip' );
	( $rc, $stdout ) = run( [ 'scripts/build.sh', '--out', $out ] );
	is( $rc, 0, 'second build exits 0' );
	opendir( my $dh, $out ) or die;
	my @files = sort grep { !/^\./ } readdir $dh;
	closedir $dh;
	is_deeply( \@files, [ $name, "$name.sha1" ], 'after two builds the output holds exactly one zip and its .sha1' );
	is_deeply( [ entries("$out/$name") ], \@entries, 'the existing file was replaced, not updated in place' );

	( $rc, my $report ) = checkPackage("$out/$name");
	is( $rc, 0, 'check-package.sh --zip passes on the real build' ) or diag $report;

	( $rc, $report ) = run( ['scripts/check-package.sh'] );
	is( $rc, 0, 'check-package.sh (builds its own zip) passes' ) or diag $report;
	unlike( $report, qr/^FAIL/m, 'no failed package checks' );
	like( $report, qr/^ok   repo\.xml minTarget \(8\.3\) equals install\.xml minVersion$/m, 'repo.xml targets compared with install.xml' );

	SKIP: {
		my ( $grc, $inside ) = run( [ 'git', 'rev-parse', '--is-inside-work-tree' ] );
		skip 'not a git work tree', 1 if $grc || $inside !~ /true/;
		my ($irc) = run( [ 'git', 'check-ignore', '-q', "dist/$name" ] );
		is( $irc, 0, 'dist/ is git-ignored' );
	}
};

subtest 'build.sh leaves junk out and stores symlinked files as their content' => sub {
	my $src = copyTree( "$ROOT/ABCListen", "$tmp/src-junk" );
	spew( "$src/.DS_Store",      'junk' );
	spew( "$src/HTML/.DS_Store", 'junk' );
	spew( "$src/Plugin.pm~",     'backup' );
	spew( "$src/.Live.pm.swp",   'swap' );
	spew( "$tmp/outside.txt",    "linked content\n" );
	symlink( "$tmp/outside.txt", "$src/linked.txt" ) or die "symlink: $!";

	my ( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $src, '--out', "$tmp/out-junk" ] );
	is( $rc, 0, 'build exits 0' ) or diag $out;
	my @entries = entries("$tmp/out-junk/$name");
	is_deeply( [ grep { /\.DS_Store|~\z|\.swp\z/ } @entries ], [], 'no .DS_Store, *~ or *.swp entries' );
	ok( ( grep { $_ eq 'linked.txt' } @entries ), 'symlinked file is in the zip' );
	my ( undef, $content ) = run( [ 'unzip', '-p', "$tmp/out-junk/$name", 'linked.txt' ] );
	is( $content, "linked content\n", "it holds the link target's content" );
	my ( undef, $info ) = run( [ 'unzip', '-Z', "$tmp/out-junk/$name", 'linked.txt' ] );
	like( $info, qr/^-/m, 'stored as a regular file, not a symlink' );
};

subtest 'build.sh rejects a missing or malformed install.xml' => sub {
	my $src = "$tmp/src-missing";
	make_path($src);
	spew( "$src/Plugin.pm", "1;\n" );
	my ( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $src, '--out', "$tmp/out-missing" ] );
	isnt( $rc, 0, 'missing install.xml: non-zero exit' );
	like( $out, qr{\Q$src\E/install\.xml not found}, 'missing install.xml: clear message' );
	ok( !-e "$tmp/out-missing/$name", 'missing install.xml: no zip written' );

	my $manifest = slurp('ABCListen/install.xml');
	my %bad      = (
		'0.1'        => '0.1',
		'1.0.0a'     => '1.0.0a',
		'v1.0.0'     => 'v1.0.0',
		'1.0.0-beta' => '1.0.0-beta',
		'" 1.0.0 "'  => ' 1.0.0 ',
		'empty'      => '',
	);
	for my $label ( sort keys %bad ) {
		my $dir = "$tmp/src-bad-" . ( $label =~ s/\W/_/gr );
		make_path($dir);
		spew( "$dir/install.xml", $manifest =~ s{<version>[^<]*</version>}{<version>$bad{$label}</version>}r );
		spew( "$dir/Plugin.pm", "1;\n" );
		( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $dir, '--out', "$dir/out" ] );
		isnt( $rc, 0, "version $label: non-zero exit" );
		like( $out, $bad{$label} eq '' ? qr/no <version> element|not of the form X\.Y\.Z/ : qr/not of the form X\.Y\.Z/, "version $label: clear message" );
		my @zips = glob("$dir/out/*.zip");
		is( scalar @zips, 0, "version $label: no zip produced" );
	}

	my $dir = "$tmp/src-noversion";
	make_path($dir);
	spew( "$dir/install.xml", $manifest =~ s{\s*<version>[^<]*</version>}{}r );
	( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $dir, '--out', "$dir/out" ] );
	isnt( $rc, 0, 'no <version> element: non-zero exit' );
	like( $out, qr/no <version> element/, 'no <version> element: clear message' );
};

subtest 'check-package.sh fails each crafted bad zip on the matching rule' => sub {
	my $good = copyTree( "$ROOT/ABCListen", "$tmp/good" );

	# plugin files under an ABCListen/ folder
	my $nested = "$tmp/nested";
	make_path($nested);
	copyTree( $good, "$nested/ABCListen" );
	my $zip = zipDir( $nested, "$tmp/prefix-$name" );
	my ( $rc, $out ) = checkPackage($zip);
	is( $rc, 1, 'ABCListen/ prefix: exit 1' );
	like( $out, qr{^FAIL entries with a forbidden prefix}m, 'ABCListen/ prefix: forbidden-prefix rule' );
	like( $out, qr{^\s+ABCListen/install\.xml$}m, 'ABCListen/ prefix: offending entry listed' );
	like( $out, qr{^FAIL install\.xml is not at the zip root}m, 'ABCListen/ prefix: install.xml not at root' );

	my %cases;
	for my $forbidden (qw(t dev ai-state scripts docs .github Plugins)) {
		$cases{"contains $forbidden/"} = {
			setup => sub { make_path("$_[0]/$forbidden"); spew( "$_[0]/$forbidden/x.txt", "1\n" ) },
			rule  => qr{^FAIL entries with a forbidden prefix}m,
		};
	}
	$cases{'contains .gitignore'} = {
		setup => sub { spew( "$_[0]/.gitignore", "dist/\n" ) },
		rule  => qr{^FAIL entries with a forbidden prefix}m,
	};
	$cases{'contains .DS_Store'} = {
		setup => sub { spew( "$_[0]/HTML/.DS_Store", 'junk' ) },
		rule  => qr{^FAIL \.DS_Store or __MACOSX entries}m,
	};
	$cases{'contains __MACOSX'} = {
		setup => sub { make_path("$_[0]/__MACOSX"); spew( "$_[0]/__MACOSX/._install.xml", 'junk' ) },
		rule  => qr{^FAIL \.DS_Store or __MACOSX entries}m,
	};
	$cases{'over 5 MB'} = {
		setup => sub { spew( "$_[0]/HTML/big.bin", randomBytes( 5 * 1024 * 1024 + 100_000 ) ) },
		rule  => qr{^FAIL size \d+ bytes is over the 5242880 byte limit}m,
	};
	$cases{'wrong .sha1'} = {
		sha1 => '0' x 40,
		rule => qr{^FAIL \Q$name\E\.sha1 does not match}m,
	};
	$cases{'version mismatch'} = {
		zipname => 'ABCListen-9.9.9.zip',
		rule    => qr{^FAIL version mismatch: file name says 9\.9\.9, install\.xml in the zip says '\Q$version\E'}m,
	};

	for my $label ( sort keys %cases ) {
		my $case = $cases{$label};
		my $dir  = copyTree( $good, "$tmp/case-" . ( $label =~ s/\W/_/gr ) );
		$case->{setup}->($dir) if $case->{setup};
		my $outDir = "$dir-zip";
		make_path($outDir);
		my $zip = zipDir( $dir, "$outDir/" . ( $case->{zipname} || $name ) );
		my ( undef, $sum ) = run( [ 'sha1sum', $zip ] );
		sha1File( $zip, $case->{sha1} || ( split ' ', $sum )[0] );

		my ( $rc, $out ) = checkPackage($zip);
		is( $rc, 1, "$label: exit 1" );
		like( $out, $case->{rule}, "$label: fails the matching rule" );
		is( scalar( () = failLines($out) ), 1, "$label: no other rule fails" ) or diag $out;
	}

	# the unmodified copy passes, so the failures above come from the crafted defects
	my $outDir = "$tmp/good-zip";
	make_path($outDir);
	$zip = zipDir( $good, "$outDir/$name" );
	my ( undef, $sum ) = run( [ 'sha1sum', $zip ] );
	sha1File( $zip, ( split ' ', $sum )[0] );
	( $rc, $out ) = checkPackage($zip);
	is( $rc, 0, 'control: the same files zipped correctly pass' ) or diag $out;
};

# a throwaway copy of the repository files the package checks read
sub repoCopy {
	my ( $label, $repoXml ) = @_;
	my $dir = "$tmp/repo-$label";
	make_path("$dir/scripts");
	copyTree( "$ROOT/scripts/$_", "$dir/scripts/$_" ) for qw(build.sh check-package.sh);
	copyTree( "$ROOT/ABCListen", "$dir/ABCListen" );
	spew( "$dir/repo.xml", $repoXml ) if defined $repoXml;
	return $dir;
}

subtest 'check-package.sh: repo.xml rules' => sub {
	my $repoXml = slurp('repo.xml');

	my $dir = repoCopy( 'ok', $repoXml );
	my ( $rc, $out ) = run( ["$dir/scripts/check-package.sh"] );
	is( $rc, 0, 'control: a copy of the repository passes' ) or diag $out;

	for my $case (
		[ 'minTarget', $repoXml =~ s{minTarget="[^"]*"}{minTarget="8.0"}r, qr/^FAIL repo\.xml minTarget '8\.0' differs from install\.xml minVersion '8\.3'$/m ],
		[ 'maxTarget', $repoXml =~ s{maxTarget="[^"]*"}{maxTarget="9.*"}r, qr/^FAIL repo\.xml maxTarget '9\.\*' differs from install\.xml maxVersion '\*'$/m ],
		[ 'name',      $repoXml =~ s{name="ABCListen"}{name="Other"}r,      qr/^FAIL repo\.xml has 0 plugin entries named ABCListen, expected 1$/m ],
		[ 'malformed', $repoXml =~ s{</plugins>}{}r,                        qr/^FAIL xmllint repo\.xml$/m ],
	) {
		my ( $label, $xml, $rule ) = @$case;
		$dir = repoCopy( $label, $xml );
		( $rc, $out ) = run( ["$dir/scripts/check-package.sh"] );
		is( $rc, 1, "repo.xml $label wrong: exit 1" );
		like( $out, $rule, "repo.xml $label wrong: fails the matching rule" ) or diag $out;
	}

	$dir = repoCopy( 'missing', undef );
	( $rc, $out ) = run( ["$dir/scripts/check-package.sh"] );
	is( $rc, 0, 'no repo.xml: the zip checks still pass' ) or diag $out;
	like( $out, qr/^note repo\.xml not found, repository checks skipped$/m, 'no repo.xml: skipped with a message' );
};

done_testing();
