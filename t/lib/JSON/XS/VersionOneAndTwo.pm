package JSON::XS::VersionOneAndTwo;

# Test shim for JSON::XS::VersionOneAndTwo, which LMS bundles (CPAN/JSON/XS/VersionOneAndTwo.pm)
# but plain Perl doesn't have. Like the real module, it exports encode_json/decode_json and the
# JSON::XS 1.x names to_json/from_json into the caller. It uses the core JSON::PP, whose
# decode_json/encode_json take and return UTF-8 bytes, like JSON::XS.

use strict;
use warnings;

use JSON::PP ();

sub import {
	my $caller = caller;
	no strict 'refs';
	*{ $caller . '::encode_json' } = \&JSON::PP::encode_json;
	*{ $caller . '::to_json' }     = \&JSON::PP::encode_json;
	*{ $caller . '::decode_json' } = \&JSON::PP::decode_json;
	*{ $caller . '::from_json' }   = \&JSON::PP::decode_json;
}

1;
