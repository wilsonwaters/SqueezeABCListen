package Slim::Utils::Errno;

# Test stub for LMS Slim::Utils::Errno: the platform's error constants, exported by default
# (EWOULDBLOCK EINPROGRESS EINTR ECHILD EBADF). On Unix LMS takes them from POSIX, as here.

use strict;
use warnings;

use POSIX ();

use Exporter qw(import);
our @EXPORT = qw(EWOULDBLOCK EINPROGRESS EINTR ECHILD EBADF);

sub EWOULDBLOCK () { POSIX::EWOULDBLOCK() }
sub EINPROGRESS () { POSIX::EINPROGRESS() }
sub EINTR ()       { POSIX::EINTR() }
sub ECHILD ()      { POSIX::ECHILD() }
sub EBADF ()       { POSIX::EBADF() }

1;
