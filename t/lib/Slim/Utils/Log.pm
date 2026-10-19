package Slim::Utils::Log;

# Test stub for LMS Slim::Utils::Log.
# Real API: Slim::Utils::Log->addLogCategory({ category, defaultLevel, description }) returns a
# logger; logger($category) returns the logger for an existing category. Loggers are
# Log::Log4perl::Logger subclasses with debug/info/warn/error and is_debug/is_info/...
#
# Every message is recorded in @MESSAGES as { level, category, message } so tests can assert on
# logging. Nothing is printed unless $ENV{ABCLISTEN_TEST_LOG} is set.

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT = qw(logger logWarning logError logBacktrace);

our @MESSAGES;          # recorded log calls
our %CATEGORIES;        # category => { defaultLevel, description }
my %loggers;

my %LEVELS = ( DEBUG => 1, INFO => 2, WARN => 3, ERROR => 4, FATAL => 5, OFF => 6 );

sub addLogCategory {
	my ( $class, $args ) = @_;

	return undef unless ref $args eq 'HASH' && $args->{category};

	$CATEGORIES{ $args->{category} } = {
		defaultLevel => $args->{defaultLevel} || 'ERROR',
		description  => $args->{description},
	};

	return logger( $args->{category} );
}

sub logger {
	my $category = shift || 'root';
	return $loggers{$category} ||= Slim::Utils::Log::Logger->new($category);
}

sub logWarning   { _record( 'WARN',  'root', @_ ) }
sub logError     { _record( 'ERROR', 'root', @_ ) }
sub logBacktrace { _record( 'ERROR', 'root', @_ ) }

# test helpers
sub resetMessages { @MESSAGES = () }

sub messages {
	my ( $class, %filter ) = @_;
	return grep {
		( !$filter{level} || $_->{level} eq $filter{level} )
			&& ( !$filter{category} || $_->{category} eq $filter{category} )
	} @MESSAGES;
}

sub _record {
	my ( $level, $category, @msg ) = @_;
	my $message = join( '', map { defined $_ ? $_ : '' } @msg );
	push @MESSAGES, { level => $level, category => $category, message => $message };
	print STDERR "# [$level] $category: $message\n" if $ENV{ABCLISTEN_TEST_LOG};
	return;
}

package Slim::Utils::Log::Logger;

sub new {
	my ( $class, $category ) = @_;
	return bless { category => $category }, $class;
}

sub _level {
	my $self = shift;
	my $cat  = $Slim::Utils::Log::CATEGORIES{ $self->{category} };
	return $LEVELS{ $cat ? $cat->{defaultLevel} : 'ERROR' } || $LEVELS{ERROR};
}

# Tests want to see every call, so messages are recorded whatever the level. The is_* checks
# report the category's configured level, as LMS does.
sub debug { my $s = shift; Slim::Utils::Log::_record( 'DEBUG', $s->{category}, @_ ) }
sub info  { my $s = shift; Slim::Utils::Log::_record( 'INFO',  $s->{category}, @_ ) }
sub warn  { my $s = shift; Slim::Utils::Log::_record( 'WARN',  $s->{category}, @_ ) }
sub error { my $s = shift; Slim::Utils::Log::_record( 'ERROR', $s->{category}, @_ ) }
sub fatal { my $s = shift; Slim::Utils::Log::_record( 'FATAL', $s->{category}, @_ ) }

sub is_debug { $_[0]->_level <= $LEVELS{DEBUG} }
sub is_info  { $_[0]->_level <= $LEVELS{INFO} }
sub is_warn  { $_[0]->_level <= $LEVELS{WARN} }
sub is_error { $_[0]->_level <= $LEVELS{ERROR} }

1;
