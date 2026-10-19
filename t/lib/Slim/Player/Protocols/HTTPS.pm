package Slim::Player::Protocols::HTTPS;

# Test stub for LMS Slim::Player::Protocols::HTTPS. The real class is
# "use base qw(IO::Socket::SSL Slim::Player::Protocols::HTTP)"; the stub leaves out
# IO::Socket::SSL (no sockets in tests) and inherits everything from the HTTP stub.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

1;
