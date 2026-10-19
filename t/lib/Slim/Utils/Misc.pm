package Slim::Utils::Misc;

# Test stub for LMS Slim::Utils::Misc: only what the plugin uses.
# Real userAgentString() returns e.g.
# "Mozilla/5.0 (Linux; N; Ubuntu; x86_64-linux; EN; utf8) SqueezeCenter, Squeezebox Server, Lyrion Music Server/9.1.1/1747377420"

use strict;
use warnings;

our $USER_AGENT = 'Mozilla/5.0 (Linux; N; Test; x86_64-linux; EN; utf8) SqueezeCenter, Squeezebox Server, Lyrion Music Server/9.1.1/0';

sub userAgentString { $USER_AGENT }

1;
