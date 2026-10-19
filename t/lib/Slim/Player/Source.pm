package Slim::Player::Source;

# Test stub for LMS Slim::Player::Source. Same delegation as the real module:
#   songTime($client)    = $client->controller->playingSongElapsed()
#   playingSong($client) = $client->controller->playingSong()
# so a test client only needs a controller object providing those methods.

use strict;
use warnings;

sub songTime    { shift->controller->playingSongElapsed() }
sub playingSong { shift->controller->playingSong() }

1;
