#!/usr/bin/perl
# update-repo-xml.pl - point the ABCListen entry in the LMS repository file at a release.
#
# Usage: scripts/update-repo-xml.pl --version V --sha S [--url U]
#            [--install-xml ABCListen/install.xml] [--file repo.xml | repo.xml]
#   --version      X.Y.Z of the release
#   --sha          SHA1 of the release zip (40 hex digits, any case; written lower-case)
#   --url          download URL of the zip: https, ending in .zip (default:
#                  https://github.com/wilsonwaters/SqueezeABCListen/releases/download/vV/ABCListen-V.zip).
#                  Plain http is accepted only for a loopback test server (127.0.0.1, localhost).
#   --install-xml  plugin manifest whose targetApplication min/maxVersion become the entry's
#                  minTarget/maxTarget (default: ABCListen/install.xml in this repository)
#   --file         file to update (default: repo.xml in this repository); may also be given as
#                  the only positional argument
#
# Sets version, minTarget and maxTarget on the one <plugin name="ABCListen" ...> element and the
# text of its <url> and <sha> children. Everything else is left byte-for-byte as it was, so a
# second identical run changes nothing (and doesn't rewrite the file). The edits are plain text
# edits on the known structure (core Perl only). Any validation failure exits 1 before anything
# is written (2 for a usage error); the new content goes to a temporary file that is then renamed
# over the original.

use strict;
use warnings;

use Cwd ();
use File::Basename qw(dirname);
use File::Temp ();
use FindBin ();
use Getopt::Long qw(GetOptions);

my $PLUGIN = 'ABCListen';
my $ROOT   = Cwd::abs_path("$FindBin::Bin/..");

my %opt = ( 'install-xml' => "$ROOT/ABCListen/install.xml" );

sub usage {
	print STDERR "usage: $0 --version V --sha S [--url U] [--install-xml FILE] [--file repo.xml | repo.xml]\n";
	exit 2;
}

sub fail {
	print STDERR "update-repo-xml.pl: $_[0]\n";
	exit 1;
}

GetOptions( \%opt, 'version=s', 'sha=s', 'url=s', 'install-xml=s', 'file=s' ) or usage();
usage() if @ARGV > 1 || ( @ARGV && defined $opt{file} ) || !defined $opt{version} || !defined $opt{sha};

my $file    = $opt{file} // ( @ARGV ? $ARGV[0] : "$ROOT/repo.xml" );
my $version = $opt{version};
my $sha     = lc $opt{sha};
my $url     = defined $opt{url} ? $opt{url}
	: "https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v$version/$PLUGIN-$version.zip";

$version =~ /\A[0-9]+\.[0-9]+\.[0-9]+\z/ or fail("version '$version' is not of the form X.Y.Z");
$sha =~ /\A[0-9a-f]{40}\z/               or fail("sha '$opt{sha}' is not 40 hex digits");
$url =~ m{\A(?:https://\S+|http://(?:127\.0\.0\.1|localhost)(?::[0-9]+)?/\S*)\.zip\z}
	or fail("url '$url' is not an https URL ending in .zip (plain http only for 127.0.0.1 or localhost)");

my ( $minTarget, $maxTarget ) = readTargets( $opt{'install-xml'} );

my $xml = slurp($file);

# the ABCListen entry: its start tag, body and end tag
my $startTag = qr{<plugin\s[^>]*?\bname\s*=\s*"\Q$PLUGIN\E"[^>]*>};
my $count    = () = $xml =~ /$startTag/g;
fail("$file has no <plugin name=\"$PLUGIN\"> element") if $count == 0;
fail("$file has $count <plugin name=\"$PLUGIN\"> elements, expected exactly one") if $count > 1;

$xml =~ m{\A(.*?)($startTag)(.*?)(</plugin>)(.*)\z}s
	or fail("$file: the <plugin name=\"$PLUGIN\"> element has no </plugin> end tag");
my ( $before, $tag, $body, $endTag, $after ) = ( $1, $2, $3, $4, $5 );

$tag = setAttribute( $tag, version   => $version );
$tag = setAttribute( $tag, minTarget => $minTarget );
$tag = setAttribute( $tag, maxTarget => $maxTarget );

$body = setElement( $body, url => $url );
$body = setElement( $body, sha => $sha );

my $new = $before . $tag . $body . $endTag . $after;

if ( $new eq $xml ) {
	print "$file already up to date: $PLUGIN $version, sha $sha, url $url\n";
	exit 0;
}

writeAtomically( $file, $new );
print "updated $file: $PLUGIN $version, sha $sha, url $url, targets $minTarget..$maxTarget\n";
exit 0;

sub slurp {
	my $path = shift;
	open( my $fh, '<:raw', $path ) or fail("can't read $path: $!");
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub readTargets {
	my $path     = shift;
	my $manifest = slurp($path);
	my ($target) = $manifest =~ m{<targetApplication>(.*?)</targetApplication>}s
		or fail("$path has no <targetApplication> element");
	my ($min) = $target =~ m{<minVersion>\s*([^<]*?)\s*</minVersion>};
	my ($max) = $target =~ m{<maxVersion>\s*([^<]*?)\s*</maxVersion>};
	fail("$path: targetApplication has no minVersion") unless defined $min && length $min;
	fail("$path: targetApplication has no maxVersion") unless defined $max && length $max;
	return ( $min, $max );
}

sub escapeXML {
	my $s = shift;
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

# replace the value of an existing attribute on the start tag
sub setAttribute {
	my ( $tag, $name, $value ) = @_;
	my $escaped = escapeXML($value);
	$tag =~ s{(\s\Q$name\E\s*=\s*")[^"]*(")}{$1$escaped$2}
		or fail("$file: <plugin name=\"$PLUGIN\"> has no $name attribute");
	return $tag;
}

# replace the text of the one child element <name>...</name> in the entry body
sub setElement {
	my ( $body, $name, $value ) = @_;
	my $found = () = $body =~ m{<\Q$name\E>[^<]*</\Q$name\E>}g;
	fail("$file: <plugin name=\"$PLUGIN\"> has $found <$name> elements, expected exactly one") if $found != 1;
	my $escaped = escapeXML($value);
	$body =~ s{(<\Q$name\E>)[^<]*(</\Q$name\E>)}{$1$escaped$2};
	return $body;
}

sub writeAtomically {
	my ( $path, $content ) = @_;
	my $mode = ( stat $path )[2] & 07777;
	my $tmp  = File::Temp->new( DIR => dirname($path), TEMPLATE => '.repo-xml-XXXXXX', UNLINK => 1 );
	binmode $tmp, ':raw';
	print {$tmp} $content or fail("can't write $tmp: $!");
	close $tmp            or fail("can't write $tmp: $!");
	chmod $mode, "$tmp"   or fail("can't chmod $tmp: $!");
	rename "$tmp", $path  or fail("can't rename $tmp to $path: $!");
	$tmp->unlink_on_destroy(0);
	return;
}
