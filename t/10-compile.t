#!/usr/bin/perl
# Every plugin module (ABCListen/**/*.pm) compiles and loads against the t/lib Slim:: stubs
# without warnings, the top-level module set is exactly the expected one (@EXPECTED), and the base classes
# are the LMS ones.

use strict;
use warnings;

use ABCListenTest;
use Test::More;

use File::Find;

my @EXPECTED = qw(API Discover Episode HTTP Live MyABC OnDemand Plugin Programs ProtocolHandler Search Settings Util);

my @modules;
find( { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm$/ } }, 'ABCListen' );
@modules = sort @modules;

my @topLevel = sort map { m{^ABCListen/(\w+)\.pm$} ? $1 : () } @modules;
is_deeply( \@topLevel, \@EXPECTED, 'ABCListen/*.pm is exactly the expected modules (F1 + M1 Settings + F3 API + O2 Programs)' ) or diag "found: @topLevel";

for my $file (@modules) {
	# ABCListen/Foo.pm is loaded as Plugins/ABCListen/Foo.pm through the t/lib/Plugins/ABCListen symlink
	( my $incPath = $file ) =~ s{^ABCListen/}{Plugins/ABCListen/};
	( my $package = $incPath ) =~ s{/}{::}g;
	$package =~ s/\.pm$//;

	my $warnings = '';
	local $SIG{__WARN__} = sub { $warnings .= join '', @_ };

	ok( eval { require $incPath; 1 }, "$package compiles and loads" ) or diag $@;
	is( $warnings, '', "$package loads without warnings" );
}

isa_ok( 'Plugins::ABCListen::Plugin',          'Slim::Plugin::OPMLBased' );
isa_ok( 'Plugins::ABCListen::ProtocolHandler', 'Slim::Player::Protocols::HTTPS' );

for my $hook (qw(Live OnDemand Discover Search MyABC)) {
	my $class = "Plugins::ABCListen::$hook";
	ok( $class->can('init') && $class->can('menuItems'), "$class implements the hook API (init, menuItems)" );
}
ok( Plugins::ABCListen::Episode->can('init'), 'Plugins::ABCListen::Episode has init (called by OnDemand->init)' );

done_testing();
