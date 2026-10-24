#!/usr/bin/perl
# scripts/smoke.sh walks the plugin menus by item name. The names it matches are hard-coded in
# the script (it runs against any LMS, without the plugin source); they must equal the EN values
# in ABCListen/strings.txt, compared as UTF-8 (the names contain – and ✓).

use strict;
use utf8;
use warnings;

use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# EN values of ABCListen/strings.txt: TOKEN lines followed by "<TAB>EN<TAB>text" lines
my %EN;
{
	my $token;
	for my $line ( split /\n/, slurp('ABCListen/strings.txt') ) {
		next if $line =~ /^\s*(?:#|$)/;
		if    ( $line =~ /^(\S+)\s*$/ )             { $token = $1 }
		elsif ( $token && $line =~ /^\tEN\t(.*)$/ ) { $EN{$token} = $1 }
	}
}
ok( scalar keys %EN > 50, 'strings.txt parsed (' . scalar( keys %EN ) . ' EN values)' );

my $script = slurp('scripts/smoke.sh');

# STR_<NAME>='<text>'   # PLUGIN_ABCLISTEN_<TOKEN>   (or "<text>" for a text with an apostrophe)
my %names;
while ( $script =~ /^(STR_\w+)=(?:'([^']*)'|"([^"\$`\\]*)")\s+# (PLUGIN_ABCLISTEN_\w+)\s*$/mg ) {
	$names{$1} = { text => $2 // $3, token => $4 };
}
my %byToken = map { $names{$_}->{token} => $_ } keys %names;

# the menu names every check needs: the 10-entry top level, then the names below it
my @TOP = qw(HOME RADIO PODCASTS NEWS SPORT KIDS AUDIOBOOKS PROGRAMS_AZ SEARCH MY_ABC);
my @BELOW = qw(LOCAL_RADIO BY_NETWORK AZ SEARCH_PROGRAMS SEARCH_EPISODES FOLLOWED_PROGRAMS NO_FOLLOWED_HELP
	FOLLOW_NAMED UNFOLLOW_NAMED FOLLOWING_NAMED FOLLOWED_OK UNFOLLOWED_OK RATE_LIMITED LOAD_FAILED ERROR);

subtest 'the names smoke.sh needs are all hard-coded' => sub {
	ok( $byToken{"PLUGIN_ABCLISTEN_$_"}, "PLUGIN_ABCLISTEN_$_ is hard-coded" ) for @TOP, @BELOW;
	is( scalar( () = $script =~ /^STR_\w+=/mg ), scalar keys %names, 'every STR_ line names its strings.txt token (no unannotated STR_)' );
	my %seen;
	my @dup = grep { $seen{ $names{$_}->{token} }++ } sort keys %names;
	is_deeply( \@dup, [], 'each token is hard-coded once' );
};

subtest 'each hard-coded name equals the EN value in strings.txt' => sub {
	for my $var ( sort keys %names ) {
		my ( $text, $token ) = @{ $names{$var} }{qw(text token)};
		ok( exists $EN{$token}, "$token exists in strings.txt" ) or next;
		is( $text, $EN{$token}, "$var equals $token (\"$EN{$token}\")" );
	}
};

subtest 'each hard-coded name is used' => sub {
	for my $var ( sort keys %names ) {
		my $uses = () = $script =~ /\$\{?\Q$var\E\b/g;
		ok( $uses >= 1, "$var is used ($uses times)" );
	}
};

subtest 'check 5: the top level, in order' => sub {
	my ($list) = $script =~ /^TOP_LEVEL=\(([^)]*)\)$/m;
	ok( defined $list, 'TOP_LEVEL is defined' ) or return;
	my @vars = $list =~ /"\$(STR_\w+)"/g;
	is_deeply( [ map { $names{$_} ? $names{$_}->{token} : $_ } @vars ], [ map {"PLUGIN_ABCLISTEN_$_"} @TOP ], 'TOP_LEVEL lists the 10 entries in the app order' );
	is_deeply(
		[ map { $EN{"PLUGIN_ABCLISTEN_$_"} } @TOP ],
		[ 'Home', 'Radio', 'Podcasts', 'News', 'Sport', 'Kids listen', 'Audiobooks', 'Programs', 'Search', 'My ABC listen' ],
		'... which read Home, Radio, Podcasts, News, Sport, Kids listen, Audiobooks, Programs, Search, My ABC listen'
	);
};

subtest 'names with a %s are matched by the text before it' => sub {
	for my $token (qw(SEARCH_PROGRAMS SEARCH_EPISODES FOLLOWED_PROGRAMS FOLLOW_NAMED UNFOLLOW_NAMED FOLLOWING_NAMED FOLLOWED_OK UNFOLLOWED_OK)) {
		my $en = $EN{"PLUGIN_ABCLISTEN_$token"} // '';
		is( scalar( () = $en =~ /%s/g ), 1, "PLUGIN_ABCLISTEN_$token has one %s" );
		my ($before) = $en =~ /\A(.*?)%s/;
		ok( defined $before && length $before, "... and text before it (\"" . ( $before // '' ) . "\")" );
	}
	like( $script, qr/^prefix\(\) \{ printf '%s' "\$\{1%%%s\*\}"; \}$/m, 'prefix() cuts a name at its %s' );

	# the prefixes must tell the follow rows apart
	my %pre = map { my ($p) = ( $EN{"PLUGIN_ABCLISTEN_$_"} // '' ) =~ /\A(.*?)%s/; ( $_ => $p // '' ) } qw(FOLLOW_NAMED UNFOLLOW_NAMED FOLLOWING_NAMED FOLLOWED_OK);
	isnt( index( $pre{UNFOLLOW_NAMED},  $pre{FOLLOW_NAMED} ), 0, 'Unfollow "… does not start with Follow "…' );
	isnt( index( $pre{FOLLOWING_NAMED}, $pre{FOLLOW_NAMED} ), 0, '✓ Following "… does not start with Follow "…' );
	isnt( index( $pre{FOLLOWED_OK},     $pre{FOLLOW_NAMED} ), 0, 'Following … does not start with Follow "…' );
};

subtest 'top-level names are told apart by an exact match first' => sub {
	# "Programs" (top level) is also the start of "Programs (N)" in search results
	like( $script, qr/select\(\.name == \$p\)\] \+ \[\.\[\] \| select\(\.name \| startswith\(\$p\)\)\]/, 'find_item: exact name first, then the prefix' );
	is( index( $EN{PLUGIN_ABCLISTEN_SEARCH_PROGRAMS}, $EN{PLUGIN_ABCLISTEN_PROGRAMS_AZ} ), 0, '(why: "Programs (%s)" starts with "Programs")' );
};

subtest 'ABC data names are not plugin strings' => sub {
	my @abc = $script =~ /^(ABC_\w+)=/mg;
	is_deeply( \@abc, ['ABC_NEW_NOTEWORTHY'], 'one name from ABC data: New & Noteworthy (check 13)' );
	ok( !( grep { $_ eq 'New & Noteworthy' } values %EN ), '"New & Noteworthy" is ABC\'s collection title, not in strings.txt' );
};

done_testing();
