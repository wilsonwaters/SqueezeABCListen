#!/usr/bin/perl
# O9 (#72): images for text rows in the web UI. The Default skin (and the other web skins) show
# LMS's grey CD placeholder icon on a row without an image. OnDemand->rowImages gives the rows
# without one an image (the program's or the episode's, else the plugin icon); the program and
# episode menus use it when the web UI asks (Slim::Web::XMLBrowser passes isWeb => 1). CLI answers
# (Material, Jive, Squeezer) keep their rows as they were: Material shows a menu as a grid of tiles
# once every row has an image.
#
# Covered here: rowImages (which rows get the image, copies, order and count), and the episode menu
# in the web UI and through the CLI. The program menu: t/37.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

my $OD           = 'Plugins::ABCListen::OnDemand';
my $EPISODE_MENU = \&Plugins::ABCListen::OnDemand::_episodeMenu;
my $ICON         = Plugins::ABCListen::Util::ICON;
my $IMAGE        = 'https://example.com/program.jpg';
my $OWN          = 'https://example.com/episode.jpg';

my @menu = (
	{ name => 'Short description', type => 'textarea' },
	{ name => 'About this program', type => 'link', items => [ { name => 'All of it', type => 'textarea' } ] },
	{ name => 'Presented by A', type => 'text' },
	{ name => 'ABC Radio National', type => 'text' },
	{ name => 'Follow', type => 'link', url => \&Plugins::ABCListen::OnDemand::_episodeMenu },
	{ name => 'Episode 1', type => 'link', image => $OWN },
	{ name => 'Couldn\'t load', type => 'text', icon => $OWN },
);

subtest 'rowImages: every row without image or icon gets the image, except the textarea' => sub {
	my @before = map { {%$_} } @menu;
	my @rows   = $OD->rowImages( $IMAGE, @menu );
	is( scalar @rows, scalar @menu, 'as many rows (the counts don\'t change)' );
	is_deeply( [ map { $_->{name} } @rows ], [ map { $_->{name} } @menu ], '... in the same order' );
	ok( !exists $rows[0]->{image}, 'the textarea (the window header): no image' );
	is_deeply( [ map { $_->{image} } @rows[ 1 .. 4 ] ], [ ($IMAGE) x 4 ], 'About, Presented by, the network, Follow: the image' );
	is( $rows[5]->{image}, $OWN, 'a row with its own image keeps it' );
	ok( !exists $rows[6]->{image} && $rows[6]->{icon} eq $OWN, 'a row with an icon keeps it, no image added' );
	is_deeply( $rows[1]->{items}, [ { name => 'All of it', type => 'textarea' } ], 'About\'s inline textarea is untouched' );
	ok( !( grep { exists $_->{description} } @rows ), 'no description added (LMS menu rule 1)' );
	is( $rows[4]->{url}, $menu[4]->{url}, 'other keys are kept' );
	is_deeply( \@menu, \@before, 'the caller\'s rows are unchanged (copies)' );

	my @text = ( { name => 'Presented by A', type => 'text' }, { name => 'No episodes available', type => 'text' } );
	is_deeply( [ map { $_->{image} } $OD->rowImages( $IMAGE, @text ) ], [ $IMAGE, $IMAGE ], 'text rows only: each gets it too' );
	is_deeply( [ $OD->rowImages( undef, @menu ) ], \@menu, 'no image: unchanged' );
	is_deeply( [ $OD->rowImages( '', @menu ) ],    \@menu, 'an empty image: unchanged' );
	is_deeply( [ $OD->rowImages($IMAGE) ],          [],     'no rows: none' );
	is_deeply( [ $OD->rowImages( $IMAGE, undef, 'x' ) ], [ undef, 'x' ], 'non-hash entries are passed through' );
};

subtest 'episode menu: the web UI gets images on its rows; the CLI keeps them as they were' => sub {
	resetStubs();
	my $episode = { id => '107266790', title => 'Trees and potatoes', description => ( 'A long synopsis about trees and potatoes. ' x 8 ), date => 1792200000, duration => 3276, presenters => ['Robyn Williams'], image => $OWN };

	my $c = collector();
	$EPISODE_MENU->( undef, $c->cb, { isWeb => 1, wantMetadata => 1, wantIndex => 1 }, $episode );
	my ($web) = $c->args(0);
	my @rows = @{ $web->{items} };
	is_deeply( [ map { $_->{type} } @rows ], [qw(textarea link audio text text)], 'the web UI: synopsis, About this episode, Play episode, Broadcast, Presented by' );
	ok( !exists $rows[0]->{image}, '... the textarea: no image' );
	is( scalar( grep { ( $_->{image} // '' ) =~ m{\Ahttps://example\.com/episode\.jpg} } @rows[ 1 .. 4 ] ), 4, '... every other row: the episode\'s image' );

	$c = collector();
	$EPISODE_MENU->( undef, $c->cb, undef, $episode );
	my ($cli) = $c->args(0);
	is_deeply( [ map { $_->{name} } @{ $cli->{items} } ], [ map { $_->{name} } @rows ], 'the CLI: the same rows' );
	is_deeply( [ map { exists $_->{image} ? 1 : 0 } @{ $cli->{items} } ], [ 0, 0, 1, 0, 0 ], '... only Play episode has an image, as before' );

	$c = collector();
	$EPISODE_MENU->( undef, $c->cb, { isWeb => 1 }, { id => '1', title => 'Bare', duration => 120 } );
	my ($bare) = $c->args(0);
	is_deeply( [ map { [ $_->{name}, $_->{image} ] } @{ $bare->{items} } ], [ [ 'Play episode', $ICON ], [ '2 min', $ICON ] ], 'no artwork, the web UI: the plugin icon' );
};

done_testing();
