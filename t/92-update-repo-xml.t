#!/usr/bin/perl
# scripts/update-repo-xml.pl: sets version/url/sha and the targets from install.xml, leaves
# everything else byte-for-byte alone, is idempotent, and rejects bad input without touching
# the file.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Module::CoreList;
use Test::More;

my $SCRIPT = 'scripts/update-repo-xml.pl';
my $SHA    = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';
my $ZIPS   = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets';

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

# run the script; returns (exit code, combined output)
sub run {
	my @args = @_;
	my $pid  = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>&', \*STDOUT ) or die;
		exec( $^X, $SCRIPT, @args ) or die "exec: $!";
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return ( $? >> 8, $out );
}

my $dir      = tempdir( CLEANUP => 1 );
my $original = slurp('repo.xml');

# a manifest with targets different from the committed repo.xml, to see them synced
my $manifest = spew( "$dir/install.xml", slurp('ABCListen/install.xml') =~ s{<minVersion>[^<]*}{<minVersion>9.0}r =~ s{<maxVersion>[^<]*}{<maxVersion>9.*}r );

sub fresh {
	my ( $name, $content ) = @_;
	return spew( "$dir/$name", $content // $original );
}

subtest 'sets version, url, sha and targets; nothing else changes' => sub {
	my $file = fresh('set.xml');
	chmod 0644, $file;
	my ( $rc, $out ) = run( '--version', '1.2.3', '--sha', uc $SHA, '--install-xml', $manifest, '--file', $file );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( $out, qr/updated/, 'reports the update' );

	my $url = "$ZIPS/ABCListen-1.2.3.zip";
	my $got = slurp($file);
	like( $got, qr{<plugin name="ABCListen" version="1\.2\.3" minTarget="9\.0" maxTarget="9\.\*">}, 'version, minTarget, maxTarget attributes' );
	like( $got, qr{<url>\Q$url\E</url>}, 'default url derived from the version: the zip on the release-assets branch (raw.githubusercontent.com)' );
	like( $got, qr{<sha>$SHA</sha>},     'sha written in lower case' );

	# expected result: the original with exactly those values replaced
	( my $expected = $original ) =~ s{version="[^"]*" minTarget="[^"]*" maxTarget="[^"]*"}{version="1.2.3" minTarget="9.0" maxTarget="9.*"};
	$expected =~ s{<url>[^<]*</url>}{<url>$url</url>};
	$expected =~ s{<sha>[^<]*</sha>}{<sha>$SHA</sha>};
	is( $got, $expected, 'every other byte is unchanged' );
	is( ( stat $file )[2] & 07777, 0644, 'file mode kept' );
};

subtest 'release of the committed version: only the sha line changes' => sub {
	my $file = fresh('release.xml');
	my ($v)   = $original =~ m{<plugin name="ABCListen" version="([^"]+)"};
	my ($url) = $original =~ m{<url>([^<]+)</url>};
	my ( $rc, $out ) = run( '--file', $file, '--version', $v, '--sha', $SHA, '--url', $url );
	is( $rc, 0, 'exit 0' ) or diag $out;
	my @old     = split /\n/, $original, -1;
	my @new     = split /\n/, slurp($file), -1;
	my @changed = grep { $old[$_] ne $new[$_] } 0 .. $#old;
	is( scalar @new, scalar @old, 'same number of lines' );
	is( scalar @changed, 1, 'exactly one line differs' );
	like( $new[ $changed[0] // 0 ], qr{^\s*<sha>$SHA</sha>$}, 'and it is the sha line' );
};

# the repair of a release made before release-assets (0.3.0): same version and sha, new url
subtest 'repair of a GitHub Release url: only the url line changes, to the release-assets zip' => sub {
	my ($v)   = $original =~ m{<plugin name="ABCListen" version="([^"]+)"};
	my ($sha) = $original =~ m{<sha>([^<]+)</sha>};
	my $old   = $original =~ s{<url>[^<]*</url>}{<url>https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v$v/ABCListen-$v.zip</url>}r;
	my $file  = fresh( 'repair.xml', $old );
	my ( $rc, $out ) = run( '--file', $file, '--version', $v, '--sha', $sha );
	is( $rc, 0, 'exit 0' ) or diag $out;
	my @old     = split /\n/, $old, -1;
	my @new     = split /\n/, slurp($file), -1;
	my @changed = grep { $old[$_] ne $new[$_] } 0 .. $#old;
	is( scalar @new, scalar @old, 'same number of lines' );
	is( scalar @changed, 1, 'exactly one line differs' );
	is( $new[ $changed[0] // 0 ], "      <url>$ZIPS/ABCListen-$v.zip</url>", 'and it is the url line, now the release-assets zip' );
};

subtest 'positional file argument (REF form) still works' => sub {
	my $file = fresh('positional.xml');
	my ( $rc, $out ) = run( '--version', '0.1.0', '--sha', $SHA, $file );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( slurp($file), qr{<sha>$SHA</sha>}, 'sha set' );

	( $rc, $out ) = run( '--version', '0.1.0', '--sha', $SHA, '--file', $file, $file );
	is( $rc, 2, '--file plus a positional file: usage error' );
};

subtest 'explicit --url' => sub {
	my $file = fresh('url.xml');
	my $url  = 'https://example.com/ABCListen-0.1.0.zip?a=1&b=2.zip';
	my ( $rc, $out ) = run( '--version', '0.1.0', '--sha', $SHA, '--url', $url, '--file', $file );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( slurp($file), qr{<url>https://example\.com/ABCListen-0\.1\.0\.zip\?a=1&amp;b=2\.zip</url>}, 'url set, & escaped for XML' );

	for my $local ( 'http://127.0.0.1:8765/ABCListen-0.1.0.zip', 'http://localhost:8765/ABCListen-0.1.0.zip' ) {
		$file = fresh('local.xml');
		( $rc, $out ) = run( '--version', '0.1.0', '--sha', $SHA, '--url', $local, '--file', $file );
		is( $rc, 0, "plain http allowed for a loopback test server: $local" ) or diag $out;
		like( slurp($file), qr{<url>\Q$local\E</url>}, "url set to $local" );
	}
};

subtest 'targets default to ABCListen/install.xml' => sub {
	my $file = fresh( 'targets.xml', $original =~ s{minTarget="[^"]*" maxTarget="[^"]*"}{minTarget="7.0" maxTarget="7.9"}r );
	my ( $rc, $out ) = run( '--version', '0.1.0', '--sha', $SHA, '--file', $file );
	is( $rc, 0, 'exit 0' ) or diag $out;
	like( slurp($file), qr{minTarget="8\.3" maxTarget="\*"}, 'targets synced from the repository install.xml' );
};

subtest 'idempotent' => sub {
	my $file = fresh('twice.xml');
	my @args = ( '--version', '2.0.0', '--sha', $SHA, '--install-xml', $manifest, '--file', $file );
	my ($rc1) = run(@args);
	my $first = slurp($file);
	utime 1_000_000_000, 1_000_000_000, $file;
	my ( $rc2, $out2 ) = run(@args);
	is( $rc1, 0, 'first run exit 0' );
	is( $rc2, 0, 'second run exit 0' );
	is( slurp($file), $first, 'second identical run gives a byte-identical file' );
	is( ( stat $file )[9], 1_000_000_000, 'second run does not rewrite the file' );
	like( $out2, qr/already up to date/, 'second run reports nothing to change' );
};

subtest 'invalid input: non-zero exit, file untouched' => sub {
	my @cases = (
		[ 'version 1.0',        '--version', '1.0',        '--sha', $SHA ],
		[ 'version v1.0.0',     '--version', 'v1.0.0',     '--sha', $SHA ],
		[ 'version 1.0.0-beta', '--version', '1.0.0-beta', '--sha', $SHA ],
		[ 'version " 1.0.0"',   '--version', ' 1.0.0',     '--sha', $SHA ],
		[ 'version "1.0.0\n"',  '--version', "1.0.0\n",    '--sha', $SHA ],
		[ 'sha 39 chars',       '--version', '1.0.0', '--sha', substr( $SHA, 1 ) ],
		[ 'sha 41 chars',       '--version', '1.0.0', '--sha', $SHA . '0' ],
		[ 'sha not hex',        '--version', '1.0.0', '--sha', 'g' x 40 ],
		[ 'sha empty',          '--version', '1.0.0', '--sha', '' ],
		[ 'url plain http',     '--version', '1.0.0', '--sha', $SHA, '--url', 'http://github.com/x/ABCListen-1.0.0.zip' ],
		[ 'url ftp',            '--version', '1.0.0', '--sha', $SHA, '--url', 'ftp://example.com/ABCListen-1.0.0.zip' ],
		[ 'url not .zip',       '--version', '1.0.0', '--sha', $SHA, '--url', 'https://example.com/ABCListen-1.0.0.tar.gz' ],
		[ 'url with space',     '--version', '1.0.0', '--sha', $SHA, '--url', 'https://example.com/a b.zip' ],
		[ 'url loopback lookalike', '--version', '1.0.0', '--sha', $SHA, '--url', 'http://127.0.0.1.example.com/ABCListen-1.0.0.zip' ],
		[ 'no version',         '--sha', $SHA ],
		[ 'no sha',             '--version', '1.0.0' ],
		[ 'missing install.xml', '--version', '1.0.0', '--sha', $SHA, '--install-xml', "$dir/nope.xml" ],
	);
	for my $case (@cases) {
		my ( $name, @args ) = @$case;
		my $file = fresh('bad.xml');
		utime 1_000_000_000, 1_000_000_000, $file;
		my ( $rc, $out ) = run( @args, '--file', $file );
		isnt( $rc, 0, "$name: non-zero exit" );
		is( slurp($file), $original, "$name: file unchanged" );
		is( ( stat $file )[9], 1_000_000_000, "$name: file not rewritten" );
	}

	my ( $rc, $out ) = run( '--version', '1.0.0', '--sha', $SHA, '--file', "$dir/missing-repo.xml" );
	isnt( $rc, 0, 'missing repo.xml: non-zero exit' );
	ok( !-e "$dir/missing-repo.xml", 'missing repo.xml: not created' );
};

subtest 'plugin entry must exist exactly once' => sub {
	my %files = (
		'no ABCListen entry'  => $original =~ s{name="ABCListen"}{name="SomethingElse"}r,
		'two ABCListen entries' => $original =~ s{(<plugins>\n)}{$1    <plugin name="ABCListen" version="0.0.1" minTarget="8.3" maxTarget="*"><url>x</url><sha>y</sha></plugin>\n}r,
		'no sha element'  => $original =~ s{\s*<sha>[^<]*</sha>}{}r,
		'no url element'  => $original =~ s{\s*<url>[^<]*</url>}{}r,
	);
	for my $name ( sort keys %files ) {
		my $file = fresh( 'entry.xml', $files{$name} );
		my ( $rc, $out ) = run( '--version', '1.0.0', '--sha', $SHA, '--file', $file );
		isnt( $rc, 0, "$name: non-zero exit" );
		is( slurp($file), $files{$name}, "$name: file unchanged" );
		like( $out, qr/ABCListen/, "$name: message names the entry" );
	}
};

subtest 'core modules only' => sub {
	my @modules = slurp($SCRIPT) =~ /^\s*use\s+([A-Za-z][\w:]*)/mg;
	ok( scalar @modules, 'script has use lines' );
	for my $module (@modules) {
		ok( defined Module::CoreList->first_release($module), "$module is a core module" );
	}
};

done_testing();
