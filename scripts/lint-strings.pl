#!/usr/bin/perl
# lint-strings.pl - check ABCListen/strings.txt (core Perl only; run from anywhere).
#
# Format rules follow LMS's parser (Slim::Utils::Strings::parseStrings):
#   - lines starting with '#' and blank lines are ignored;
#   - a token line is the token alone (here: [A-Z][A-Z0-9_]*);
#   - a text line is <TAB><LANG><TAB><text>; an empty LANG continues the previous language.
# Also checked: no CR characters, no duplicate tokens, every token has EN text, and every
# PLUGIN_ABCLISTEN* token used in ABCListen/**/*.pm, ABCListen/install.xml or the
# ABCListen/HTML/**/*.html templates is defined.
# Exits 1 and lists the problems if anything is wrong.

use strict;
use warnings;

use File::Find;
use FindBin;

my $root    = "$FindBin::Bin/..";
my $strings = "$root/ABCListen/strings.txt";
my @problems;

open( my $fh, '<:raw', $strings ) or die "Can't open $strings: $!\n";
my @lines = <$fh>;
close $fh;

my ( %defined, %hasEN, $token, $language );
my $ln = 0;

for my $line (@lines) {
	$ln++;

	if ( $line =~ /\r/ ) {
		push @problems, "strings.txt line $ln: CR character (use Unix line endings)";
		$line =~ s/\r//g;
	}

	next if $line =~ /^#/ || $line !~ /\S/;
	chomp $line;

	if ( $line =~ /^(\S+)$/ ) {
		$token = $1;
		undef $language;
		push @problems, "strings.txt line $ln: token '$token' should match [A-Z][A-Z0-9_]*" unless $token =~ /^[A-Z][A-Z0-9_]*$/;
		push @problems, "strings.txt line $ln: duplicate token '$token'" if $defined{$token}++;
	}
	elsif ( $line =~ /^\t(\S*)\t(.+)$/ ) {
		my $lang = $1;
		if ( !defined $token ) {
			push @problems, "strings.txt line $ln: text line before any token";
		}
		elsif ( $lang eq '' ) {
			push @problems, "strings.txt line $ln: continuation line without a language above it" unless defined $language;
		}
		elsif ( $lang !~ /^[A-Z]{2}(?:_[A-Z]{2})?$/ ) {
			push @problems, "strings.txt line $ln: bad language code '$lang'";
		}
		else {
			$language = $lang;
			$hasEN{$token} = 1 if $lang eq 'EN';
		}
	}
	else {
		push @problems, "strings.txt line $ln: not a token or <TAB>LANG<TAB>text line: '$line'";
	}
}

for my $tok ( sort keys %defined ) {
	push @problems, "strings.txt: token '$tok' has no EN text" unless $hasEN{$tok};
}

# every PLUGIN_ABCLISTEN* token used by the plugin (code, manifest, web templates) must be defined
my @sources = ("$root/ABCListen/install.xml");
find( { no_chdir => 1, wanted => sub { push @sources, $File::Find::name if /\.pm$/ } }, "$root/ABCListen" );
find( { no_chdir => 1, wanted => sub { push @sources, $File::Find::name if /\.html$/ } }, "$root/ABCListen/HTML" ) if -d "$root/ABCListen/HTML";

my %used;
for my $file ( sort @sources ) {
	open( my $src, '<', $file ) or die "Can't open $file: $!\n";
	( my $rel = $file ) =~ s{^\Q$root\E/}{};
	while ( my $line = <$src> ) {
		while ( $line =~ /\b(PLUGIN_ABCLISTEN[A-Z0-9_]*)/g ) {
			my $tok = $1;
			next if $tok =~ /_$/;    # built at runtime, e.g. "PLUGIN_ABCLISTEN_STATE_$state"
			push @{ $used{$tok} }, "$rel:$.";
		}
	}
	close $src;
}

for my $tok ( sort keys %used ) {
	push @problems, "token '$tok' used in @{ $used{$tok} } is not defined in strings.txt" unless $defined{$tok};
}

if (@problems) {
	print STDERR "strings lint FAILED:\n", map( {"  $_\n"} @problems );
	exit 1;
}

printf "strings lint OK: %d tokens defined, %d referenced by the plugin\n", scalar( keys %defined ), scalar( keys %used );
exit 0;
