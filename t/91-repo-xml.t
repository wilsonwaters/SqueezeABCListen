#!/usr/bin/perl
# repo.xml, the third-party LMS repository file users add in Manage Plugins: well-formed, has
# every element/attribute LMS reads (ExtensionsManager::_parseXML), uses absolute URLs (the zip
# on the release-assets branch), and agrees with ABCListen/install.xml.

use strict;
use warnings;

use Test::More;

my $REPO = 'https://github.com/wilsonwaters/SqueezeABCListen';
my $RAW  = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/';

sub slurp {
	my $file = shift;
	open( my $fh, '<:raw', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub versionCmp {
	my ( $x, $y ) = map { [ split /\./ ] } @_;
	return $x->[0] <=> $y->[0] || $x->[1] <=> $y->[1] || $x->[2] <=> $y->[2];
}

my $xml      = slurp('repo.xml');
my $manifest = slurp('ABCListen/install.xml');

my ($installVersion) = $manifest =~ m{<version>([^<]*)</version>};
my ($target)         = $manifest =~ m{<targetApplication>(.*?)</targetApplication>}s;
my ($minVersion)     = $target =~ m{<minVersion>([^<]*)</minVersion>};
my ($maxVersion)     = $target =~ m{<maxVersion>([^<]*)</maxVersion>};
my ($category)       = $manifest =~ m{<category>([^<]*)</category>};

SKIP: {
	skip 'xmllint not installed', 1 unless grep { -x "$_/xmllint" } split /:/, $ENV{PATH};
	my $out = qx{xmllint --noout repo.xml 2>&1};
	is( $? >> 8, 0, 'xmllint --noout repo.xml passes' ) or diag $out;
}

like( $xml, qr{\A<\?xml version="1\.0" encoding="UTF-8"\?>\n}, 'XML declaration, UTF-8' );
like( $xml, qr{<extensions>.*</extensions>\s*\z}s, 'root element <extensions>' );
like( $xml, qr{<details>\s*<title lang="EN">SqueezeABCListen plugin repository</title>\s*</details>}, 'repository title (details/title lang=EN)' );
like( $xml, qr{<plugins>.*</plugins>}s, '<plugins> group' );

my @entries = $xml =~ m{(<plugin\s[^>]*>.*?</plugin>)}sg;
is( scalar @entries, 1, 'exactly one plugin entry' );
my $entry = $entries[0] // '';

my ($startTag) = $entry =~ m{\A(<plugin\s[^>]*>)};
my %attr;
$attr{$1} = $2 while ( $startTag // '' ) =~ m{(\w+)="([^"]*)"}g;

is_deeply( [ sort keys %attr ], [qw(maxTarget minTarget name version)], 'attributes: name, version, minTarget, maxTarget (and nothing else)' );
is( $attr{name}, 'ABCListen', 'name="ABCListen" (matches Plugins::ABCListen::Plugin, the install folder, plugin.state:ABCListen)' );
like( $attr{version}, qr/\A[0-9]+\.[0-9]+\.[0-9]+\z/, 'version is X.Y.Z' );
ok( versionCmp( $attr{version} // '0.0.0', $installVersion ) <= 0, "version $attr{version} is not ahead of install.xml ($installVersion)" );
is( $attr{minTarget}, $minVersion, 'minTarget equals install.xml targetApplication/minVersion' );
is( $attr{maxTarget}, $maxVersion, 'maxTarget equals install.xml targetApplication/maxVersion' );

my %child;
$child{$1} = $2 while $entry =~ m{<(\w+)(?:\s+lang="EN")?>([^<]*)</\1>}g;

is_deeply( [ sort keys %child ], [qw(category creator desc icon link sha title url)], 'children: title, desc, category, icon, url, sha, link, creator (no email/installations/target)' );
like( $entry, qr{<title lang="EN">ABC listen</title>}, 'title lang=EN "ABC listen"' );
like( $entry, qr{<desc lang="EN">Unofficial [^<]+</desc>}, 'desc lang=EN says it is unofficial' );
like( $child{desc}, qr/not affiliated with or endorsed by the ABC/i, 'desc: "not affiliated with or endorsed by the ABC" (same wording as PLUGIN_ABCLISTEN_DESC)' );
like( $child{desc}, qr/live ABC radio stations/, 'desc names what ships: live ABC radio stations' );
is( $child{category}, 'radio',         'category radio' );
is( $child{category}, $category,       'category matches install.xml' );
is( $child{creator},  'Wilson Waters', 'creator' );
is( $child{link},     $REPO,           'link to the GitHub repository' );

# url: the zip on the release-assets branch, served by raw.githubusercontent.com, because LMS
# 9.1.1 can't read the redirect GitHub sends for release asset downloads (#62). Releases up to
# 0.3.0 were made before that branch existed and pointed at their GitHub Release asset; the
# Release workflow's repair run (the workflow dispatched on main) moves repo.xml over, and its
# CI checks run on main before that, so the old URL is still accepted for those versions only.
my $ZIPS = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/';
sub urlRule {
	my ( $version, $url ) = @_;
	return 'raw' if $url eq "${ZIPS}ABCListen-$version.zip";
	return 'legacy' if versionCmp( $version, '0.3.0' ) <= 0 && $url eq "$REPO/releases/download/v$version/ABCListen-$version.zip";
	return '';
}
is_deeply(
	[ map { urlRule(@$_) } [ '0.4.0', "${ZIPS}ABCListen-0.4.0.zip" ], [ '0.4.0', "$REPO/releases/download/v0.4.0/ABCListen-0.4.0.zip" ], [ '0.4.0', "${ZIPS}ABCListen-0.3.0.zip" ], [ '0.3.0', "$REPO/releases/download/v0.3.0/ABCListen-0.3.0.zip" ], [ '0.3.0', "$REPO/releases/download/v0.2.0/ABCListen-0.2.0.zip" ] ],
	[ 'raw', '', '', 'legacy', '' ],
	'url rule: the raw release-assets URL of the version; a GitHub Release URL only up to 0.3.0'
);
my $v    = $attr{version} // '';
my $rule = urlRule( $v || '0.0.0', $child{url} // '' );
ok( $rule, "url is ${ZIPS}ABCListen-$v.zip (the zip on the release-assets branch, for the version attribute)" ) or diag "url is '" . ( $child{url} // '' ) . "'";
note("url: $v predates release-assets and still has its GitHub Release asset URL, until the Release workflow repairs it") if $rule eq 'legacy';
like( $child{sha}, qr/\A[0-9a-f]{40}\z/, 'sha is 40 lower-case hex digits' );

is( $child{icon}, "${RAW}ABCListen/HTML/EN/plugins/ABCListen/html/images/icon.png", 'icon is the absolute raw.githubusercontent.com URL on main' );
( my $iconPath = $child{icon} // '' ) =~ s/\A\Q$RAW\E//;
ok( length $iconPath && -f $iconPath, "icon path '$iconPath' exists in the repository" );

done_testing();
