#!/usr/bin/perl
# scripts/changelog-section.sh: prints one version's section of a Keep a Changelog file (the
# release notes the Release workflow uses), and CHANGELOG.md itself: Keep a Changelog layout,
# [Unreleased] and [0.1.0] sections, link references at the bottom.

use strict;
use utf8;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $SCRIPT = 'scripts/changelog-section.sh';
my $DIR    = tempdir( CLEANUP => 1 );
my $REPO   = 'https://github.com/wilsonwaters/SqueezeABCListen';

# run the script; returns (exit code, stdout, stderr)
sub capture {
	my @args = @_;
	my $pid = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>', "$DIR/stderr" ) or die;
		exec( 'bash', $SCRIPT, @args ) or die "exec: $!";
	}
	local $/;
	my $stdout = <$fh> // '';
	close $fh;
	my $code = $? >> 8;
	open( my $efh, '<', "$DIR/stderr" ) or die;
	my $stderr = do { local $/; <$efh> } // '';
	close $efh;
	utf8::decode($stdout);
	return ( $code, $stdout, $stderr );
}

sub spew {
	my ( $name, $content ) = @_;
	my $file = "$DIR/$name";
	open( my $fh, '>:encoding(UTF-8)', $file ) or die "Can't write $file: $!";
	print {$fh} $content;
	close $fh;
	return $file;
}

my $SAMPLE = spew( 'sample.md', <<'EOF' );
# Changelog

Intro text.

## [Unreleased]

## [2.0.0] - 2026-10-01

### Added

- Two “quoted” things.
- And a second line.


## [1.10.0]
### Fixed
- No date on this heading.

## [1.0.0] - 2026-09-01

### Added
- The first release.

[unreleased]: https://example.com/compare/v2.0.0...HEAD
[2.0.0]: https://example.com/compare/v1.10.0...v2.0.0
[1.0.0]: https://example.com/releases/tag/v1.0.0
EOF

subtest 'a middle section: from its heading to the next "## ", trimmed' => sub {
	my ( $code, $out ) = capture( '2.0.0', $SAMPLE );
	is( $code, 0, 'exit 0' );
	is( $out, "### Added\n\n- Two “quoted” things.\n- And a second line.\n", 'the body, without the leading and trailing blank lines' );
};

subtest 'a heading without a date' => sub {
	my ( $code, $out ) = capture( '1.10.0', $SAMPLE );
	is( $code, 0, 'exit 0' );
	is( $out, "### Fixed\n- No date on this heading.\n", 'the body' );
};

subtest 'the last section stops before the link references' => sub {
	my ( $code, $out ) = capture( '1.0.0', $SAMPLE );
	is( $code, 0, 'exit 0' );
	is( $out, "### Added\n- The first release.\n", 'the body, no "[x]: url" lines' );

	my $noLinks = spew( 'nolinks.md', "# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- Only entry.\n\n\n" );
	( $code, $out ) = capture( '0.1.0', $noLinks );
	is( $code, 0, 'last section at the end of the file: exit 0' );
	is( $out, "- Only entry.\n", 'last section at the end of the file: the body' );
};

subtest 'an absent or empty section: exit 1, no output' => sub {
	for my $version ( '9.9.9', '2.0', '2', '0.0', 'Unreleased' ) {
		my ( $code, $out, $err ) = capture( $version, $SAMPLE );
		is( $code, 1,  "$version: exit 1" );
		is( $out,  '', "$version: no output" );
		is( $err,  '', "$version: nothing on stderr" );
	}
};

subtest 'dots match only dots' => sub {
	my $file = spew( 'dots.md', "## [1x0x0] - 2026-01-01\n\n- x\n\n## [1a0b0]\n\n- y\n" );
	my ( $code, $out ) = capture( '1.0.0', $file );
	is( $code, 1,  '"1.0.0" does not match "1x0x0" or "1a0b0"' );
	is( $out,  '', 'no output' );

	( $code, $out ) = capture( '1.10.0', $SAMPLE );
	unlike( $out, qr/first release/, '"1.10.0" is not "1.0.0"' );

	$file = spew( 'meta.md', "## [1.0.0+b.1]\n\n- build\n" );
	( $code, $out ) = capture( '1.0.0+b.1', $file );
	is( $out, "- build\n", 'other regex characters are literal too' );
};

subtest 'usage errors: exit 2' => sub {
	my ($code) = capture();
	is( $code, 2, 'no version' );
	($code) = capture( '1.0.0', "$DIR/missing.md" );
	is( $code, 2, 'unreadable file' );
	($code) = capture( '1.0.0', $SAMPLE, 'extra' );
	is( $code, 2, 'too many arguments' );
};

subtest 'CHANGELOG.md' => sub {
	open( my $fh, '<:encoding(UTF-8)', 'CHANGELOG.md' ) or die "Can't open CHANGELOG.md: $!";
	my $doc = do { local $/; <$fh> };
	close $fh;

	like( $doc, qr/\A# Changelog\n/, 'title' );
	like( $doc, qr{\Qhttps://keepachangelog.com/en/1.1.0/\E}, 'says it follows Keep a Changelog 1.1.0' );

	my @versions = $doc =~ /^## \[([^\]]+)\]/mg;
	is( $versions[0], 'Unreleased', 'first section is [Unreleased]' );
	ok( ( grep { $_ eq '0.1.0' } @versions ), 'has a [0.1.0] section' );
	like( $doc, qr/^## \[0\.1\.0\] - \d{4}-\d{2}-\d{2}$/m, '0.1.0 heading has a date' );

	my ( $code, $out ) = capture('0.1.0');
	is( $code, 0, 'scripts/changelog-section.sh 0.1.0: exit 0 (default file)' );
	like( $out, qr/\A### Added\n/,         '0.1.0 starts with "### Added"' );
	like( $out, qr/ABC listen/,            '0.1.0 names the plugin' );
	unlike( $out, qr/^## |^\[[^\]]+\]: /m, '0.1.0 body has no other heading or link reference' );

	( $code, $out ) = capture('9.9.9');
	is( $code, 1,  'scripts/changelog-section.sh 9.9.9: exit 1' );
	is( $out,  '', 'scripts/changelog-section.sh 9.9.9: no output' );

	# link references at the bottom, after the last section
	my ($links) = $doc =~ /((?:^\[[^\]]+\]: \S+\n)+)\z/m;
	ok( defined $links, 'the file ends with link reference definitions' );
	my $newest = $versions[1] // '';
	like( $links // '', qr/^\[unreleased\]: \Q$REPO\E\/compare\/v\Q$newest\E\.\.\.HEAD$/m, "link: unreleased compares v$newest...HEAD" );
	like( $links // '', qr/^\[0\.1\.0\]: \Q$REPO\E\/releases\/tag\/v0\.1\.0$/m,             'link: 0.1.0 release (the first one)' );
	for my $v ( @versions[ 1 .. $#versions ] ) {
		like( $links // '', qr/^\[\Q$v\E\]: \Q$REPO\E\//m, "link reference for [$v]" );
	}
};

done_testing();
