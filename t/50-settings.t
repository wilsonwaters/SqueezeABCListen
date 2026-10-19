#!/usr/bin/perl
# M1: the plugin settings page and the homeState pref.
#   * Plugins::ABCListen::Settings: name, page, prefs (namespace plugin.abclisten, homeState, then L5's
#     liveQuality: its section and pref are tested in t/28-stream-quality.t), server-wide;
#     its handler HTML-escapes a rejected value before LMS's base handler echoes it in its warning;
#   * MyABC->init: homeState default '' (an existing value is kept), the validator, the settings page
#     created only under main::WEBUI, and a failing settings constructor logged once without dying;
#   * the validator truth table (named sub and through the prefs stub's set);
#   * the template (settings/basic.html) and install.xml optionsURL.

use strict;
use warnings;

use ABCListenTest;
use Test::More;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Web::Settings;

use Plugins::ABCListen::MyABC;
use Plugins::ABCListen::Settings;

my $ROOT     = abs_path( File::Spec->catdir( dirname(__FILE__), '..' ) );
my $PAGE     = 'plugins/ABCListen/settings/basic.html';
my $TEMPLATE = File::Spec->catfile( $ROOT, 'ABCListen', 'HTML', 'EN', split m{/}, $PAGE );

my @STATES  = qw(ACT NSW NT QLD SA TAS VIC WA);
my @INVALID = ( 'nsw', ' WA', 'WA ', 'XX', 'NZ', '0', 'Wa', "WA\n", '<script>alert(1)</script>', ['WA'], { WA => 1 } );

sub prefs { preferences('plugin.abclisten') }

sub show { my $v = shift; return 'undef' unless defined $v; return ref $v ? ref($v) . ' ref' : "'$v'" }

# Reset the recorded stub state. MyABC and Settings keep the plugin.abclisten namespace object they
# got at load time (as in LMS, where it is a singleton), so it is emptied in place rather than
# replaced (resetStubs would replace it).
sub fresh {
	Slim::Web::Settings->reset;
	Slim::Utils::Log->resetMessages;
	%{ prefs() } = %{ Slim::Utils::Prefs::Namespace->new('plugin.abclisten') };
	return;
}

sub freshInit {
	fresh();
	Plugins::ABCListen::MyABC->init();
}

sub slurp {
	my $file = shift;
	open( my $fh, '<:raw', $file ) or die "Can't open $file: $!";
	local $/;
	return scalar <$fh>;
}

subtest 'Settings: name, page, prefs, server-wide' => sub {
	isa_ok( 'Plugins::ABCListen::Settings', 'Slim::Web::Settings' );
	is( Plugins::ABCListen::Settings->name, 'PLUGIN_ABCLISTEN', 'name is the plugin name token' );
	is( Plugins::ABCListen::Settings->page, $PAGE, 'page is the template path' );

	my ( $prefs, @names ) = Plugins::ABCListen::Settings->prefs;
	is( $prefs, preferences('plugin.abclisten'), 'prefs namespace is plugin.abclisten' );
	is( $prefs->namespace, 'plugin.abclisten', '... by name' );
	is_deeply( \@names, [qw(homeState liveQuality)], 'the page handles homeState, then liveQuality (appended by L5, t/28)' );
	ok( !Plugins::ABCListen::Settings->needsClient, 'server-wide page (no needsClient)' );
};

subtest 'MyABC->init: homeState default, validator, settings page (main::WEBUI)' => sub {
	freshInit();

	ok( prefs()->exists('homeState'), 'homeState initialised' );
	is( prefs()->get('homeState'), '', "... to '' (not set)" );
	ok( prefs()->hasValidator('homeState'), 'validator registered for homeState' );
	is_deeply( \@Slim::Web::Settings::REGISTERED, ['Plugins::ABCListen::Settings'], 'settings page created once (main::WEBUI is true here)' );
	is( scalar Slim::Utils::Log->messages( level => 'ERROR' ), 0, 'nothing logged at ERROR' );

	# upgrade from a version that already has a value: init never overwrites it
	fresh();
	prefs()->set( homeState => 'WA' );
	Plugins::ABCListen::MyABC->init();
	is( prefs()->get('homeState'), 'WA', 'an existing value is kept' );

	# a stored invalid value (hand-edited prefs) is kept too; the page shows "Not set" and consumers treat it like ''
	fresh();
	prefs()->set( homeState => 'nsw' );
	Plugins::ABCListen::MyABC->init();
	is( prefs()->get('homeState'), 'nsw', 'init does not touch a stored invalid value' );
	my ( $value, $ok ) = prefs()->set( homeState => 'SA' );
	ok( $ok && prefs()->get('homeState') eq 'SA', 'saving a valid value replaces it' );
};

subtest 'validator truth table (named sub)' => sub {
	my $v = \&Plugins::ABCListen::MyABC::validateHomeState;
	ok( $v->( 'homeState', $_ ), "valid: '$_'" ) for ( '', @STATES );
	ok( !$v->( 'homeState', $_ ), 'invalid: ' . show($_) ) for @INVALID;
	ok( !$v->( 'homeState', undef ), 'invalid: undef (not mapped to \'\')' );
};

subtest 'validator through the prefs layer (set: used by the JSON-RPC pref command and the settings form)' => sub {
	freshInit();

	for my $state ( @STATES, '' ) {
		my ( $value, $ok ) = prefs()->set( homeState => $state );
		ok( $ok && prefs()->get('homeState') eq $state, "set '$state' is stored" );
	}

	prefs()->set( homeState => 'WA' );
	for my $bad ( @INVALID, undef ) {
		my ( $value, $ok ) = prefs()->set( homeState => $bad );
		ok( !$ok, 'set ' . show($bad) . ' is rejected' );
		is( prefs()->get('homeState'), 'WA', '... and homeState is still WA' );
	}
};

subtest 'settings form: save, reject, missing field, HTML in the value' => sub {
	freshInit();
	my $S = 'Plugins::ABCListen::Settings';

	is( $S->handler( undef, { saveSettings => 1, pref_homeState => 'WA' } ), $PAGE, 'handler renders the page' );
	is( prefs()->get('homeState'), 'WA', 'POST pref_homeState=WA saves WA' );

	my $params = { saveSettings => 1, pref_homeState => 'nsw' };
	$S->handler( undef, $params );
	is( prefs()->get('homeState'), 'WA', 'POST nsw is rejected' );
	is( $params->{prefs}->{pref_homeState}, 'WA', '... and the page shows the stored value' );

	$S->handler( undef, { saveSettings => 1 } );
	is( prefs()->get('homeState'), 'WA', 'POST without pref_homeState leaves homeState unchanged' );

	$params = { saveSettings => 1, pref_homeState => q{<script>alert("x")</script>&'} };
	$S->handler( undef, $params );
	is( prefs()->get('homeState'), 'WA', 'POST with HTML is rejected' );
	is( $params->{pref_homeState}, '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;&#39;', '... and the value LMS echoes in its warning is HTML-escaped' );

	$params = { saveSettings => 1, pref_homeState => 'QLD' };
	$S->handler( undef, $params );
	is( $params->{pref_homeState}, 'QLD', 'a valid value is passed on unchanged' );
	is( prefs()->get('homeState'), 'QLD', '... and saved' );

	$S->handler( undef, { saveSettings => 1, pref_homeState => '' } );
	is( prefs()->get('homeState'), '', "POST pref_homeState= (empty) resets to ''" );

	$params = { pref_homeState => '<b>' };
	$S->handler( undef, $params );
	is( $params->{pref_homeState}, '<b>', 'without saveSettings nothing is touched' );
};

subtest 'a failing settings page constructor is logged once and init does not die' => sub {
	fresh();
	{
		no warnings 'redefine';
		local *Slim::Web::Settings::new = sub { die "web settings exploded\n" };
		ok( eval { Plugins::ABCListen::MyABC->init(); 1 }, 'MyABC->init does not die' ) or diag $@;
	}
	my @errors = Slim::Utils::Log->messages( level => 'ERROR' );
	is( scalar @errors, 1, 'one ERROR logged' );
	like( $errors[0] && $errors[0]->{message}, qr/settings.*web settings exploded/i, '... naming the settings page and the reason' );
	is( prefs()->get('homeState'), '', 'homeState still initialised' );
	ok( prefs()->hasValidator('homeState'), 'validator still registered' );
};

subtest 'main::WEBUI false (LMS --noweb): no settings page, prefs still initialised and validated' => sub {
	# main::WEBUI is a constant inlined at compile time, so this runs in a child perl that redefines
	# it to 0 before MyABC is compiled.
	my $lib  = File::Spec->catdir( $ROOT, 't', 'lib' );
	my $code = <<'PERL';
use strict;
use warnings;
use ABCListenTest;
BEGIN { no warnings 'redefine'; no strict 'refs'; *{'main::WEBUI'} = sub () { 0 }; }
use Slim::Utils::Prefs;
use Slim::Web::Settings;
require Plugins::ABCListen::MyABC;
my $ok = eval { Plugins::ABCListen::MyABC->init(); 1 } ? 1 : 0;
my $p  = preferences('plugin.abclisten');
my (undef, $setXX) = $p->set( homeState => 'XX' );
my (undef, $setWA) = $p->set( homeState => 'WA' );
print join( "\n",
	"initOk=$ok",
	'registered=' . scalar(@Slim::Web::Settings::REGISTERED),
	'settingsLoaded=' . ( $INC{'Plugins/ABCListen/Settings.pm'} ? 1 : 0 ),
	'exists=' . ( $p->exists('homeState') ? 1 : 0 ),
	"setXX=$setXX",
	"setWA=$setWA",
	'homeState=' . $p->get('homeState'),
), "\n";
PERL
	open( my $ph, '-|', $^X, "-I$lib", '-e', $code ) or die "Can't run $^X: $!";
	my %out = map { chomp; split /=/, $_, 2 } <$ph>;
	close $ph;
	is( $?, 0, 'child perl exited cleanly' );
	is( $out{initOk},         1,    'init does not die' );
	is( $out{registered},     0,    'no settings page created' );
	is( $out{settingsLoaded}, 0,    'Plugins::ABCListen::Settings (Slim::Web) not even loaded' );
	is( $out{exists},         1,    'homeState initialised' );
	is( $out{setXX},          0,    'invalid value rejected' );
	is( $out{setWA},          1,    'valid value accepted' );
	is( $out{homeState},      'WA', 'homeState is WA' );

	my $src = slurp( File::Spec->catfile( $ROOT, 'ABCListen', 'MyABC.pm' ) );
	like( $src, qr/\bmain::WEBUI\b/, 'MyABC.pm checks main::WEBUI' );
	unlike( $src, qr/WEB_UI/, '... never WEB_UI' );
};

subtest 'template settings/basic.html' => sub {
	ok( -f $TEMPLATE, "template exists at HTML/EN/$PAGE" ) or return;
	my $html = slurp($TEMPLATE);

	like( $html, qr/\A\s*\[% PROCESS settings\/header\.html %\]/, 'starts with the settings header' );
	like( $html, qr/\[% PROCESS settings\/footer\.html %\]\s*\z/, 'ends with the settings footer' );

	my @select = $html =~ /(<select\b[^>]*>)/g;
	is( scalar @select, 2, 'two selects: homeState, then L5\'s liveQuality (t/28)' );
	my $select = $select[0] || '';
	like( $select, qr/\bname="pref_homeState"/, 'select name="pref_homeState"' );
	# id is the pref name, as in core templates: the settings footer binds its validator by that id
	# (the Classic/Material footer throws a script error when no element has it)
	like( $select, qr/\bid="homeState"/, 'select id="homeState" (the pref name)' );
	like(
		$select . $html,
		qr/\baria-label="\[% 'PLUGIN_ABCLISTEN_HOME_STATE' \| string \| html %\]"|<label\b[^>]*\bfor="homeState"/,
		'explicit accessible name (aria-label or label for) from PLUGIN_ABCLISTEN_HOME_STATE'
	);

	my ($options) = $html =~ m{<select\b[^>]*>(.*?)</select>}s;
	my @values = ( $options || '' ) =~ /<option\b[^>]*\bvalue="([^"]*)"/g;
	is_deeply( \@values, [ '', @STATES ], '9 options in order: "", ACT NSW NT QLD SA TAS VIC WA' );

	my @labels = ( $options || '' ) =~ /<option\b[^>]*>\s*\[% '(PLUGIN_ABCLISTEN_\w+)' \| string \| html %\]\s*<\/option>/g;
	is_deeply( \@labels, [ 'PLUGIN_ABCLISTEN_HOME_STATE_NONE', map {"PLUGIN_ABCLISTEN_STATE_$_"} @STATES ], 'option labels: Not set, then the state names (HTML-escaped)' );

	for my $state (@STATES) {
		like( $options, qr/<option value="$state"\[% IF prefs\.pref_homeState == '$state' %\] selected="selected"\[% END %\]>/, "$state selected from prefs.pref_homeState" );
	}
	like( $options, qr/<option value=""\[% IF prefs\.pref_homeState == '' %\] selected="selected"\[% END %\]>/, 'Not set selected when empty (an invalid value selects nothing)' );

	like( $html, qr/\[% WRAPPER setting title="PLUGIN_ABCLISTEN_HOME_STATE" desc="PLUGIN_ABCLISTEN_HOME_STATE_DESC" %\]/, 'setting WRAPPER with title and description' );

	my @markers = $html =~ /<!-- === (\/?\w+) === -->/g;
	is_deeply( \@markers, [qw(M1 /M1 L5 /L5)], 'owner sections: M1 (with the select), then L5' );
	my ($m1) = $html =~ m{<!-- === M1 === -->(.*?)<!-- === /M1 === -->}s;
	like( $m1 || '', qr/<select\b[^>]*name="pref_homeState"/, 'the select is inside the M1 section' );
	my ($l5) = $html =~ m{<!-- === L5 === -->(.*?)<!-- === /L5 === -->}s;
	like( $l5 // 'missing', qr/<select\b[^>]*name="pref_liveQuality"/, 'the L5 section holds the liveQuality select (checked in t/28)' );

	Slim::Utils::Strings->loadFile( File::Spec->catfile( $ROOT, 'ABCListen', 'strings.txt' ) );
	( my $outsideL5 = $html ) =~ s{<!-- === L5 === -->.*?<!-- === /L5 === -->}{}s;
	my %tokens = map { $_ => 1 } $outsideL5 =~ /\b(PLUGIN_ABCLISTEN\w*)/g;
	is_deeply(
		[ sort keys %tokens ],
		[ sort( qw(PLUGIN_ABCLISTEN_HOME_STATE PLUGIN_ABCLISTEN_HOME_STATE_DESC PLUGIN_ABCLISTEN_HOME_STATE_NONE), map {"PLUGIN_ABCLISTEN_STATE_$_"} @STATES ) ],
		'outside the L5 section, the template uses the M1 tokens and (read-only) L1\'s state names'
	);
	my %all = map { $_ => 1 } $html =~ /\b(PLUGIN_ABCLISTEN\w*)/g;
	ok( defined Slim::Utils::Strings::string($_), "$_ is defined in strings.txt" ) for sort keys %all;
};

subtest 'install.xml optionsURL' => sub {
	my $xml = slurp( File::Spec->catfile( $ROOT, 'ABCListen', 'install.xml' ) );
	my @urls = $xml =~ m{<optionsURL>([^<]*)</optionsURL>}g;
	is_deeply( \@urls, [ Plugins::ABCListen::Settings->page ], 'one optionsURL, equal to Settings->page' );
};

done_testing();
