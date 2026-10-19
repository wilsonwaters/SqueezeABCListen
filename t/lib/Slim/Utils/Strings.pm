package Slim::Utils::Strings;

# Test stub for LMS Slim::Utils::Strings.
# Real API: string($token, @sprintfArgs), cstring/clientString($client, $token, @args),
# getString($token), stringExists($token). Missing tokens make string() return undef.
#
# The stub loads the plugin's own ABCListen/strings.txt (English), so tests see the real text.
# Use loadFile() to load other string files.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Scalar::Util qw(blessed);

use Exporter qw(import);
our @EXPORT_OK = qw(string cstring clientString);

our %STRINGS;

sub loadFile {
	my ( $class, $file ) = @_;

	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open strings file $file: $!";

	my $token;
	while ( my $line = <$fh> ) {
		chomp $line;
		$line =~ s/\r$//;
		next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

		if ( $line =~ /^(\S+)\s*$/ ) {
			$token = $1;
		}
		elsif ( $token && $line =~ /^\t(\S+)\t(.*)$/ ) {
			my ( $lang, $text ) = ( $1, $2 );
			$STRINGS{ uc $token } = $text if $lang eq 'EN';
		}
	}

	close $fh;
	return;
}

sub string {
	my $token  = uc( shift || '' );
	my $string = $STRINGS{$token};

	return sprintf( $string, @_ ) if @_ && defined $string;
	return $string;
}

sub clientString {
	my $client = shift;

	if ( blessed($client) && $client->can('string') ) {
		return $client->string(@_);
	}

	return string(@_);
}

*cstring = \&clientString;

sub getString {
	my $token = shift;
	return $token if !defined $token || $token =~ /(?:[a-z]|\s)/;
	my $string = $STRINGS{ uc $token };
	return defined $string ? ( @_ ? sprintf( $string, @_ ) : $string ) : $token;
}

sub stringExists { defined $STRINGS{ uc( $_[0] || '' ) } ? 1 : 0 }

# Load the plugin strings: <repo>/ABCListen/strings.txt (this file is <repo>/t/lib/Slim/Utils/Strings.pm).
{
	my $file = File::Spec->catfile( dirname(__FILE__), ('..') x 4, 'ABCListen', 'strings.txt' );
	__PACKAGE__->loadFile($file) if -e $file;
}

1;
