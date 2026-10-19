package Plugins::ABCListen::ProtocolHandler;

# Protocol handler for abclisten:// URLs (Plugins::ABCListen::Util URL contract), registered by
# Plugin.pm. F1 placeholder: no behaviour of its own yet; the protocol handler task (F2) adds the
# per-kind resolver registry (ai-state/streams.md contract 4). Owned by the foundation stream.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

1;
