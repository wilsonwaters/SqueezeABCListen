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

# Before LMS's base handler saves the form (saveSettings), for each pref:
#   * the field it saves is pref_<name>, or (core's fallback for old templates, which it logs as an
#     error) an unprefixed <name>;
#   * a field the POST leaves out gets the current value (M3, #52). The base handler sets every pref
#     in prefs(), so it would set the missing one to undef, which the validator rejects with a
#     spurious 'Invalid value "" for <name>' warning. Setting a pref to its current value is a no-op
#     in LMS (no validation, no change callbacks), so the pref, even a hand-edited invalid value,
#     stays as it is and no warning is shown;
#   * a posted value its validator rejects is HTML-escaped, because the base handler puts it in the
#     page's warning without escaping it. A rejected value stays rejected once escaped, and valid
#     values are passed on unchanged.
sub handler {
	my ( $class, $client, $params, @args ) = @_;

	if ( $params && $params->{saveSettings} ) {
		my ( $namespace, @names ) = $class->prefs($client);

		for my $name (@names) {
			my ($field) = grep { defined $params->{$_} } ( "pref_$name", $name );

			if ( !defined $field ) {
				$params->{"pref_$name"} = $namespace->get($name);
				next;
			}

			my $value = $params->{$field};
			next if ref $value || $namespace->validate( $name, $value );
			( $params->{$field} = $value ) =~ s/([&<>"'])/$HTML_ESCAPES{$1}/g;
		}
	}

	return $class->SUPER::handler( $client, $params, @args );
}

1;
