package Plugins::ABCListen::Episode;

# Episode playback (abclisten://episode/<id>). F1 stub: init is a no-op.
#
# Plugins::ABCListen::OnDemand->init calls Episode->init once at startup. Owned by the ondemand
# stream (O1) after F1.

use strict;
use warnings;

sub init { return }

1;
