#!/usr/bin/perl
# Plugin manifest and resources as packaged by the release stream: install.xml fields (module,
# a fresh upper-case GUID, targets 8.3..*, category, X.Y.Z version, optional optionsURL), the
# 512x512 icon, and the per-task sections of strings.txt.

use strict;
use warnings;

use Test::More;

sub slurp {
	my ( $file, $layer ) = @_;
	open( my $fh, '<' . ( $layer || '' ), $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# The 20 per-task sections F1 created in strings.txt; later tasks (D4, D5, ...) may append more.
my @TASK_SECTIONS = qw(F1 F2 F3 R1 M1 L1 O1 O2 L2 L5 O3 D1 D3 M2 L3 L4 O4 D2 R2 R3);

subtest 'install.xml' => sub {
	my $xml = slurp('ABCListen/install.xml');

	my %field;
	( my $top = $xml ) =~ s{<targetApplication>.*?</targetApplication>}{}s;
	$field{$1} = $2 while $top =~ m{<(\w+)>([^<]*)</\1>}g;
	my ($target) = $xml =~ m{<targetApplication>(.*?)</targetApplication>}s;

	like( $field{id}, qr/\A[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/, 'id is an upper-case GUID' );
	unlike( $field{id} // '', qr/\AFF07025D-/i, "id is not SqueezeRTRFM's GUID (FF07025D-...)" );
	is( $field{module},      'Plugins::ABCListen::Plugin', 'module Plugins::ABCListen::Plugin' );
	is( $field{name},        'PLUGIN_ABCLISTEN',           'name is a string token' );
	is( $field{description}, 'PLUGIN_ABCLISTEN_DESC',      'description is a string token' );
	like( $field{version}, qr/\A[0-9]+\.[0-9]+\.[0-9]+\z/, 'version is X.Y.Z' );
	is( $field{category}, 'radio',                                  'category radio' );
	is( $field{icon},     'plugins/ABCListen/html/images/icon.png', 'icon path' );

	ok( defined $target, 'has targetApplication' );
	like( $target // '', qr{<minVersion>8\.3</minVersion>}, 'minVersion 8.3' );
	like( $target // '', qr{<maxVersion>\*</maxVersion>},   'maxVersion *' );

	ok( -f "ABCListen/HTML/EN/$field{icon}", 'icon path resolves to a file under HTML/EN' );

	# M1 adds optionsURL (parallel work): accept the manifest with or without it
	ok( !exists $field{settingsPage}, 'no settingsPage key (LMS reads optionsURL)' );
	if ( exists $field{optionsURL} ) {
		ok( -f "ABCListen/HTML/EN/$field{optionsURL}", "optionsURL $field{optionsURL} resolves to a file under HTML/EN" );
	}
	else {
		pass('no optionsURL (yet): nothing to resolve');
	}
};

subtest 'icon' => sub {
	my $file = 'ABCListen/HTML/EN/plugins/ABCListen/html/images/icon.png';
	ok( -f $file, 'icon exists' ) or return;

	my $png = slurp( $file, ':raw' );
	is( substr( $png, 0, 8 ), "\x89PNG\r\n\x1a\n", 'PNG signature' );
	is( substr( $png, 12, 4 ), 'IHDR', 'IHDR chunk first' );
	my ( $width, $height ) = unpack( 'NN', substr( $png, 16, 8 ) );
	is( $width,  512, 'width 512' );
	is( $height, 512, 'height 512' );
};

subtest 'strings.txt' => sub {
	my $strings  = slurp( 'ABCListen/strings.txt', ':encoding(UTF-8)' );
	my @sections = $strings =~ /^# === (\w+) ===/mg;

	my %seen;
	$seen{$_}++ for @sections;
	my @missing = grep { !$seen{$_} } @TASK_SECTIONS;
	is_deeply( \@missing, [], 'all 20 original task sections are present' );
	cmp_ok( scalar @sections, '>=', 20, 'at least 20 sections (later tasks may append theirs)' );
	is_deeply( [ grep { $seen{$_} > 1 } sort keys %seen ], [], 'no section appears twice' );
};

done_testing();
