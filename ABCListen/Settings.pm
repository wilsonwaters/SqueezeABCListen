package Plugins::ABCListen::Settings;

# The plugin's settings page (Settings -> Plugins -> ABC listen; install.xml optionsURL), server-wide.
# Created by MyABC->init only under main::WEBUI. LMS's base handler saves each pref_<name> form field
# through the prefs object (validators run there) and fills prefs.pref_<name> for the template.
#
# The page is section-owned (ai-state/streams.md, parallel-work rule 4): each owner has its own
# <!-- === ID === --> section in HTML/EN/plugins/ABCListen/settings/basic.html and appends its pref
# names to prefs() below.
#
# Owned by the myabc stream (M1).

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.abclisten');

my %HTML_ESCAPES = ( '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;' );

sub name { 'PLUGIN_ABCLISTEN' }

sub page { 'plugins/ABCListen/settings/basic.html' }

# Append-only: later owners add their pref names at the end (L5: liveQuality).
sub prefs {
	return ( $prefs, qw(homeState liveQuality) );
}

# LMS's base handler puts a value its validator rejects into the page's warning ("... is not a valid
# value for ...") without HTML-escaping it, so escape such values first. A rejected value stays rejected
# once escaped, and valid values are passed on unchanged.
sub handler {
	my ( $class, $client, $params, @args ) = @_;

	if ( $params && $params->{saveSettings} ) {
		my ( $namespace, @names ) = $class->prefs($client);

		for my $name (@names) {
			my $value = $params->{"pref_$name"};
			next if !defined $value || ref $value || $namespace->validate( $name, $value );
			( $params->{"pref_$name"} = $value ) =~ s/([&<>"'])/$HTML_ESCAPES{$1}/g;
		}
	}

	return $class->SUPER::handler( $client, $params, @args );
}

1;
