#!/usr/bin/perl
# U1 (#83): short description headers. In menu mode LMS moves a leading textarea into the window
# header, which Squeezer (like SqueezePlay/Jive) shows as a fixed block above the list: a long ABC
# description left no room for the episodes. OnDemand->shortText keeps the first paragraph, cut at
# a sentence or word boundary to at most 200 characters, and OnDemand->descriptionItems adds an
# "About this program / episode / station" row with the whole text, only when it was shortened.
#
# Covered here, offline: the truncation rules (paragraphs, whitespace, sentence and word
# boundaries, initials and abbreviations, the ellipsis, non-ASCII text, the 200-character cap and
# its one exception, a single word longer than the cap); descriptionItems' exact rows; the program
# menu of the two programs the stakeholder reported (Bedtime Stories with R.A. Spratt; Wait…
# They Did What!?), the Science Show, and programs with a short description (no About row); the
# episode menu (About this episode before Play episode); row order and stable indexes; song info's
# Episode notes still full length. LiveMetadata's Program info: t/23.
#
# Fixtures: t/data/ondemand/nextdata-program-bedtime-stories.trimmed.json and
# nextdata-program-wait-they-did-what.trimmed.json are ABC's Next data for
# /listen/programs/bedtime-stories-with-ra-spratt and /listen/programs/wait-they-did-what
# (fetched 2026-10-25), trimmed to the keys Programs->program reads (pageProps
# heroImageWithCTAPrepared, heroDescriptionPrepared, presentersPrepared, the first two cards of
# programCollectionPrepared, programTemplate, webDistributionRestricted); shapes unedited.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use ABCListenTest::FakeClient;
use Test::More;

use JSON::PP ();
use POSIX ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::ABCListen::API;
use Plugins::ABCListen::Episode;
use Plugins::ABCListen::OnDemand;
use Plugins::ABCListen::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

$ENV{TZ} = 'Australia/Sydney';
POSIX::tzset();

my $OD        = 'Plugins::ABCListen::OnDemand';
my $SITE      = 'https://www.abc.net.au';
my $EPS       = "$SITE/core-next/api/episodesWithSegments/x";
my $NEXT      = "$SITE/_next/data/build-3afcd04f";
my $JSON_TYPE = { 'Content-Type' => 'application/json' };
my $ELLIPSIS  = "\x{2026}";

my $PROGRAM_MENU = \&Plugins::ABCListen::OnDemand::_programMenu;
my $EPISODE_MENU = \&Plugins::ABCListen::OnDemand::_episodeMenu;

my $ABOUT_PROGRAM = string('PLUGIN_ABCLISTEN_ABOUT_PROGRAM');
my $ABOUT_EPISODE = string('PLUGIN_ABCLISTEN_ABOUT_EPISODE');

Slim::Utils::Log->addLogCategory( { category => 'plugin.abclisten', defaultLevel => 'WARN', description => 'PLUGIN_ABCLISTEN' } );

# ---- helpers ----

sub fresh {
	resetStubs();
	Plugins::ABCListen::API::_reset();
	Plugins::ABCListen::OnDemand::_resetProviders();
	setTime(1_792_400_000);
	route( "$SITE/listen/search", file => 'foundation/listen-search.trimmed.html', headers => { 'Content-Type' => 'text/html' } );
}

sub to_json { JSON::PP->new->utf8->canonical->encode( $_[0] ) }

sub feed {
	my ( $code, $client, @passthrough ) = @_;
	my $c = collector();
	$code->( $client, $c->cb, {}, @passthrough );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub names { [ map { $_->{name} } @{ $_[0] } ] }

# shortText's answer as [short, shortened] (an empty list as [])
sub short { [ $OD->shortText(@_) ] }

# The paragraph as shortText sees it: whitespace collapsed
sub collapse { my $t = shift; $t =~ s/\s+/ /g; $t =~ s/\A | \z//g; return $t }

# Checks every cut must pass: at most $max characters, an ellipsis at the end, the text before it
# a prefix of the collapsed first paragraph that ends at a word boundary (the next character is a
# space), unless the paragraph has no space before $max (a single long word).
sub cut_ok {
	my ( $text, $max, $label ) = @_;
	$max ||= 200;
	my ( $short, $shortened ) = $OD->shortText( $text, $max );
	my ($first) = grep { length } map { collapse($_) } split /\R/, $text;

	subtest $label => sub {
		ok( length($short) <= $max, 'at most ' . $max . ' characters (' . length($short) . ')' );
		is( $shortened, 1, 'shortened' );
		like( $short, qr/\Q$ELLIPSIS\E\z/, 'ends with an ellipsis' );
		( my $head = $short ) =~ s/ ?\Q$ELLIPSIS\E\z//;
		is( substr( $first, 0, length $head ), $head, 'the rest is the start of the first paragraph' );
		my $next = substr( $first, length $head, 1 );
		ok( $next =~ /\A[\s,;:\x{2013}\x{2014}-]?\z/ || substr( $first, length($head) ) =~ /\A[,;:\x{2013}\x{2014}-]* /, "never inside a word (next character: '$next')" );
	};
}

my $BEDTIME = '/listen/programs/bedtime-stories-with-ra-spratt';
my $WAIT    = '/listen/programs/wait-they-did-what';
my $SCIENCE = '/listen/programs/scienceshow';

sub route_programs {
	route( "$NEXT$BEDTIME.json", file => 'ondemand/nextdata-program-bedtime-stories.trimmed.json',    headers => $JSON_TYPE );
	route( "$NEXT$WAIT.json",    file => 'ondemand/nextdata-program-wait-they-did-what.trimmed.json', headers => $JSON_TYPE );
	route( "$NEXT$SCIENCE.json", file => 'ondemand/nextdata-program-scienceshow.trimmed.json',        headers => $JSON_TYPE );

	# a page of episodes for any collection: the program page's first cards, as ABC sends them
	Slim::Networking::SimpleAsyncHTTP->addRoute( qr{\Q$EPS\E\?}, sub {
		my ($id) = $_[0] =~ /collectionId=([0-9]+)/;
		my $file = $id eq '106961196' ? 'bedtime-stories' : $id eq '106387620' ? 'wait-they-did-what' : 'scienceshow';
		my $page = JSON::PP::decode_json( fixture("ondemand/nextdata-program-$file.trimmed.json") )->{pageProps}->{programCollectionPrepared};
		return { code => 200, headers => $JSON_TYPE, content => to_json( { collection => { id => $id, items => $page->{items}, pagination => { offset => 0, size => 50, total => scalar @{ $page->{items} } } } } ) };
	} );
}

# ---------------------------------------------------------------------------

subtest 'shortText: nothing to show' => sub {
	is_deeply( short(undef),           [], 'undef: ()' );
	is_deeply( short(''),              [], "'': ()" );
	is_deeply( short(" \n\n\t "),      [], 'whitespace only: ()' );
	is_deeply( short( ['a list'] ),    [], 'a reference: ()' );
	is_deeply( short( { a => 'b' } ),  [], 'a hash: ()' );
	is_deeply( short("\x{A0}\x{2003}"), [], 'Unicode spaces only: ()' );
};

subtest 'shortText: a short single paragraph is kept whole, without an ellipsis' => sub {
	is_deeply( short('Science, weekly.'),                         [ 'Science, weekly.', 0 ], 'unchanged; not shortened' );
	is_deeply( short("  Science,\t\tweekly. \x{A0} Twice! "),     [ 'Science, weekly. Twice!', 0 ], 'whitespace (tabs, no-break spaces) collapsed and trimmed: still not shortened' );
	my $two = ( 'a' x 99 ) . ' ' . ( 'b' x 100 );
	is( length $two, 200, '(a 200-character paragraph)' );
	is_deeply( short($two), [ $two, 0 ], 'exactly 200 characters: kept whole' );
	is_deeply( short( 'x' x 40, 40 ), [ 'x' x 40, 0 ], 'exactly $max characters (a smaller $max): kept whole' );
};

subtest 'shortText: only the first paragraph' => sub {
	is_deeply( short("Paragraph one.\n\nParagraph two."),            [ 'Paragraph one.', 1 ], 'two paragraphs (richText\'s "\n\n"): the first, shortened, no ellipsis' );
	is_deeply( short("Paragraph one.\nParagraph two."),              [ 'Paragraph one.', 1 ], 'a single line break separates paragraphs too' );
	is_deeply( short("Paragraph one.\r\nParagraph two."),            [ 'Paragraph one.', 1 ], 'CRLF' );
	is_deeply( short("\n\n  \n  Paragraph   one. \n\n Two."),        [ 'Paragraph one.', 1 ], 'leading blank lines skipped; whitespace collapsed' );
	is_deeply( short("Only one paragraph.\n\n   \n"),                [ 'Only one paragraph.', 0 ], 'trailing blank lines: not shortened' );
	is_deeply( short("One.\x{2029}Two."),                            [ 'One.', 1 ], 'a Unicode paragraph separator' );
	my $long = 'word ' x 50;
	my ( $s, $x ) = $OD->shortText("$long\n\nSecond.");
	ok( length($s) <= 200 && $x == 1, 'a long first paragraph of several: cut too' );
};

subtest 'shortText: cut at the last sentence end that keeps at least half of the cap, then " …"' => sub {
	my $one   = 'The first sentence is here and it runs for a fair while so that it is long enough to count as a header.';    # 101
	my $two   = 'The second sentence is long too, and it would take the header well past the cap of two hundred characters if it were kept.';
	my $text  = "$one $two And a third one.";
	is_deeply( short($text), [ "$one $ELLIPSIS", 1 ], 'cut after the first sentence (101 characters): " …"' );

	my $three = 'Short one. ' x 9 . $two . ' ' . $two;    # sentence ends at 10, 21, ..., 98, then past the cap
	my ($s) = $OD->shortText($three);
	unlike( $s, qr/\A(?:Short one\. ){1,9}\Q$ELLIPSIS\E\z/, 'sentence ends before half of the cap (the 9th at 98 characters) are not used' );
	like( $s, qr/[a-z]\Q$ELLIPSIS\E\z/, '... a word cut instead' );

	for my $end ( '!', '?', '!?', "\x{2026}", '...', '."', ".\x{201D}", ".\x{2019}", '.)' ) {
		my $t = 'A sentence that is long enough to be a header on its own, running well past half of the cap, ends here' . $end . ' ' . ( 'more words ' x 20 );
		my ($cut) = $OD->shortText($t);
		like( $cut, qr/ends here\Q$end\E \Q$ELLIPSIS\E\z/, "a sentence ending in '$end'" );
	}

	cut_ok( $text, 200, 'sentence cut: the invariants' );
};

subtest 'shortText: initials and abbreviations are not sentence ends' => sub {
	my $long = 'Bedtime stories, fractured fairytales and epically good Greek myths, told for curious kids by R.A. Spratt and her friends at the ABC, are the kind of thing you hear in the car on a long drive with the whole family.';
	my ($s) = $OD->shortText($long);
	unlike( $s, qr/R\.A\. \Q$ELLIPSIS\E\z/, 'not cut after "R.A."' );
	like( $s, qr/[a-z]\Q$ELLIPSIS\E\z/, '... a word cut instead (no sentence end in reach)' );

	for my $abbr ( 'Dr.', 'Mr.', 'Mrs.', 'Ms.', 'St.', 'Prof.', 'Jr.', 'Inc.', 'No.', 'e.g.', 'i.e.', 'vs.', 'J.' ) {
		my $t = ( 'x' x 120 ) . " met $abbr Somebody " . ( 'and more ' x 20 );
		my ($cut) = $OD->shortText($t);
		unlike( $cut, qr/\Q$abbr\E \Q$ELLIPSIS\E\z/, "not a sentence end: '$abbr'" );
	}

	my ($ok) = $OD->shortText( ( 'y' x 110 ) . ' and that is the end of it. ' . ( 'and more ' x 20 ) );
	like( $ok, qr/end of it\. \Q$ELLIPSIS\E\z/, 'a plain word before the stop: a sentence end' );
};

subtest 'shortText: else the last word boundary, then "…" (trailing punctuation dropped)' => sub {
	my $words = join ' ', map {"word$_"} 1 .. 60;
	my ($s) = $OD->shortText($words);
	like( $s, qr/\Aword1 word2 .+ word\d+\Q$ELLIPSIS\E\z/, 'cut after a whole word' );
	ok( length($s) <= 200, 'at most 200 characters' );
	cut_ok( $words, 200, 'word cut: the invariants' );

	my $commas = join ', ', map {"item$_"} 1 .. 60;
	($s) = $OD->shortText($commas);
	like( $s, qr/item\d+\Q$ELLIPSIS\E\z/, 'a trailing comma is dropped before the ellipsis' );

	my $dash = ( 'z' x 196 ) . " \x{2013} " . ( 'tail ' x 10 );
	($s) = $OD->shortText($dash);
	is( $s, ( 'z' x 196 ) . $ELLIPSIS, 'a trailing dash and its space are dropped' );

	my $quote = ( 'q' x 196 ) . " \x{201C} aside" . ( ' tail' x 10 );
	($s) = $OD->shortText($quote);
	is( $s, ( 'q' x 196 ) . $ELLIPSIS, 'an opening quote is never left dangling' );

	my $colon = ( 'c' x 197 ) . ': ' . ( 'tail ' x 10 );
	($s) = $OD->shortText($colon);
	is( $s, ( 'c' x 197 ) . $ELLIPSIS, 'a trailing colon is dropped' );

	my $kids = ( 'k' x 190 ) . " kids' podcasts " . ( 'tail ' x 10 );
	($s) = $OD->shortText($kids);
	like( $s, qr/kids'\Q$ELLIPSIS\E\z/, 'a closing apostrophe (kids\') stays' );

	is_deeply( short( 'abc def ghi jkl mno pqr stu', 10 ), [ "abc def$ELLIPSIS", 1 ], 'a smaller $max' );
	is_deeply( short( 'abcdefghi jkl', 10 ), [ "abcdefghi$ELLIPSIS", 1 ], 'cut exactly before the space at $max - 1' );
};

subtest 'shortText: a stop inside a word (abc.net.au, 3.5) is not a sentence end' => sub {
	my $text = 'Find every program, podcast and live station of the ABC in one place and hear them whenever you like, '
		. 'on the website at abc.net.au/listen and in the app, which more than 3.5 million Australians use every single week of the year.';
	ok( length($text) > 200, '(longer than the cap; no sentence end before it)' );
	my ($s) = $OD->shortText($text);
	unlike( $s, qr/ \Q$ELLIPSIS\E\z/, 'not a sentence cut' );
	unlike( $s, qr/(?:abc|3)\.\s*\Q$ELLIPSIS\E\z/, 'never after "abc." or "3."' );
	like( $s, qr/[a-z]\Q$ELLIPSIS\E\z/, 'a word cut' );
	cut_ok( $text, 200, 'the invariants' );
};

subtest 'shortText: after a sentence end past the cap, the fallback cuts from the start (no stale match position)' => sub {
	my ( $s, $x ) = $OD->shortText( ( 'a' x 250 ) . '. More text here and more.' );
	is( $s, ( 'a' x 199 ) . $ELLIPSIS, '250 letters, ". More text…": the first 199 letters and "…"' );
	is( $x, 1, '... shortened' );

	my $url = 'https://www.abc.net.au/listen/' . ( 'x' x 230 );
	is( length $url, 260, '(a 260-character URL)' );
	($s) = $OD->shortText( "$url. Then a sentence about it, and some more words." );
	is( $s, substr( $url, 0, 199 ) . $ELLIPSIS, 'a URL followed by a sentence: the start of the URL' );

	($s) = $OD->shortText( ( 'b' x 150 ) . '! ' . ( 'c' x 300 ) );
	is( $s, ( 'b' x 150 ) . '! ' . $ELLIPSIS, 'a sentence end before the cap still wins' );
};

subtest 'shortText: a single word longer than the cap is the one case cut inside a word' => sub {
	my $url = 'https://www.abc.net.au/' . ( 'x' x 300 );
	my ( $s, $x ) = $OD->shortText($url);
	is( length($s), 200, '200 characters' );
	is( $s, substr( $url, 0, 199 ) . $ELLIPSIS, 'cut at 199, then the ellipsis' );
	is( $x, 1, 'shortened' );

	my $accents = "e\x{301}" x 150;    # 300 code points, 150 graphemes
	($s) = $OD->shortText($accents);
	ok( length($s) <= 200, 'combining accents: at most 200 code points' );
	like( $s, qr/\A(?:e\x{301})+\Q$ELLIPSIS\E\z/, '... never an accent cut off its letter' );
};

subtest 'shortText: non-ASCII text' => sub {
	my $text = "Wait\x{2026} They Did What!? is the question you\x{2019}ll be asking after travelling back through modern history with comedian Tilly Oddy-Black, Émigré Stories’ crew and a café full of naïve experts, all of them talking at once.";
	ok( length($text) > 200, '(longer than the cap)' );
	my ( $s, $x ) = $OD->shortText($text);
	ok( length($s) <= 200, 'at most 200 characters (' . length($s) . ')' );
	like( $s, qr/\AWait\x{2026} They Did What!\? is the question you\x{2019}ll be asking/, 'curly quotes and the ellipsis character kept as characters' );
	unlike( $s, qr/\AWait\x{2026} \Q$ELLIPSIS\E/, '"Wait…" (4 characters) is too short to be the cut' );
	cut_ok( $text, 200, 'accented text: the invariants' );

	my $emoji = ( "\x{1F437} pig " x 60 );
	($s) = $OD->shortText($emoji);
	ok( length($s) <= 200, 'emoji: at most 200 characters' );
	like( $s, qr/(?:pig|\x{1F437})\Q$ELLIPSIS\E\z/, 'emoji: cut between words' );

	my $chinese = "\x{8FD9}\x{662F}\x{4E00}\x{4E2A}\x{5173}\x{4E8E}\x{6FB3}\x{5927}\x{5229}\x{4E9A}\x{7684}\x{8282}\x{76EE}" x 20;    # no spaces
	( $s, $x ) = $OD->shortText($chinese);
	is( length($s), 200, 'Chinese without spaces: 199 characters and the ellipsis (a break beside any Han character)' );
	is( substr( $s, 0, 199 ), substr( $chinese, 0, 199 ), '... the start of the text' );

	my $sentences = ( "\x{8FD9}\x{662F}\x{4E00}\x{4E2A}\x{8282}\x{76EE}" x 20 ) . "\x{3002}" . ( "\x{6FB3}\x{5927}\x{5229}\x{4E9A}" x 30 );
	($s) = $OD->shortText($sentences);
	is( $s, ( "\x{8FD9}\x{662F}\x{4E00}\x{4E2A}\x{8282}\x{76EE}" x 20 ) . "\x{3002}$ELLIPSIS", 'a Chinese full stop ends a sentence (no space needed, none added)' );

	my $mixed = ( "\x{4E2D}\x{6587}" x 75 ) . ( 'x' x 100 );
	($s) = $OD->shortText($mixed);
	is( $s, ( "\x{4E2D}\x{6587}" x 75 ) . $ELLIPSIS, 'Chinese, then a long Latin word: cut beside the last Chinese character, not inside the word' );

	my $korean =( "\x{D55C}\x{AD6D}\x{C5B4} " x 60 );
	($s) = $OD->shortText($korean);
	like( $s, qr/\x{C5B4}\Q$ELLIPSIS\E\z/, 'Korean (spaces between words): cut at a space, never inside a word' );
};

subtest 'shortText: the cap holds for every length and shape (generated texts)' => sub {
	my @words = ( qw(a an the ABC listen program episode science café naïve), "it\x{2019}s", "R.A.", 'Dr.', 'end.', 'what?!', "\x{1F437}", "\x{4E2D}\x{6587}", 'well,', "\x{2013}", 'x' x 25 );
	my $seed = 7;
	my $rand = sub { $seed = ( $seed * 1103515245 + 12345 ) % 2**31; return $seed % $_[0] };

	my ( $over, $bad ) = ( 0, 0 );
	for my $n ( 1 .. 400 ) {
		my $text = join ' ', map { $words[ $rand->( scalar @words ) ] } 1 .. 1 + $rand->(90);
		for my $max ( 200, 60 ) {
			my ( $s, $x ) = $OD->shortText( $text, $max );
			$over++ if length($s) > $max;
			$bad++ if ( length($text) <= $max ) != !$x;
		}
	}
	is( $over, 0, '800 texts: never more than the cap' );
	is( $bad,  0, '... shortened exactly when the text was longer than the cap' );
};

subtest 'descriptionItems: the textarea, and About only when shortened' => sub {
	is_deeply( [ $OD->descriptionItems( undef, undef, 'PLUGIN_ABCLISTEN_ABOUT_PROGRAM' ) ], [], 'no description: no rows' );
	is_deeply( [ $OD->descriptionItems( undef, '  ', 'PLUGIN_ABCLISTEN_ABOUT_PROGRAM' ) ], [], 'blank: no rows' );

	is_deeply(
		[ $OD->descriptionItems( undef, 'Science, weekly.', 'PLUGIN_ABCLISTEN_ABOUT_PROGRAM' ) ],
		[ { name => 'Science, weekly.', type => 'textarea' } ],
		'short: only the textarea (exact keys), nothing extra'
	);

	my $text = "  First paragraph.\n\nSecond paragraph, which is the rest.  ";
	is_deeply(
		[ $OD->descriptionItems( undef, $text, 'PLUGIN_ABCLISTEN_ABOUT_EPISODE' ) ],
		[
			{ name => 'First paragraph.', type => 'textarea' },
			{ name => $ABOUT_EPISODE, type => 'link', items => [ { name => "First paragraph.\n\nSecond paragraph, which is the rest.", type => 'textarea' } ] },
		],
		'shortened: the textarea, then the About link with the whole text (trimmed, paragraphs kept) as one textarea'
	);

	my @rows = $OD->descriptionItems( ABCListenTest::FakeClient->new('00:00:00:00:00:01'), 'word ' x 100, 'PLUGIN_ABCLISTEN_ABOUT_PROGRAM' );
	is( scalar @rows, 2, 'one long paragraph: two rows' );
	is( $rows[1]->{name}, 'About this program', 'with a client: "About this program"' );
	ok( !exists $rows[1]->{description} && !exists $rows[1]->{url} && !exists $rows[1]->{passthrough}, 'the About link: no description (LMS menu rule 1), no feed' );
	is( string('PLUGIN_ABCLISTEN_ABOUT_EPISODE'), 'About this episode', 'About this episode' );
	is( string('PLUGIN_ABCLISTEN_ABOUT_STATION'), 'About this station', 'About this station' );
};

subtest 'program menu: Bedtime Stories with R.A. Spratt (#83 screenshot)' => sub {
	fresh();
	route_programs();
	my $c = feed( $PROGRAM_MENU, undef, { title => 'Bedtime Stories with R.A. Spratt', path => $BEDTIME } );
	is( $c->count, 1, 'one callback' );
	my $items = items_of($c);

	is_deeply(
		$items->[0],
		{ name => 'The world\'s most glamorous flying pig, Nanny Piggins tells side-splitting stories and fractured fairytales for curious kids.', type => 'textarea' },
		'the header: the first paragraph (124 characters), a textarea, first'
	);
	is( $items->[1]->{name}, $ABOUT_PROGRAM, 'then "About this program"' );
	my $full = $items->[1]->{items}->[0];
	is( $full->{type}, 'textarea', '... which opens one textarea' );
	like( $full->{name}, qr/\AThe world's most glamorous flying pig.+\n\nThe stories are perfect for bedtime.+\n\nR\.A\. Spratt \(Rachel Spratt\).+\n\nStories written and performed by R\.A\. Spratt\.\z/s, '... with all four paragraphs' );
	ok( length( $full->{name} ) > 1000, '... the whole description (' . length( $full->{name} ) . ' characters)' );
	is( $items->[2]->{name}, 'Presented by R.A. Spratt', 'then Presented by' );
	is( $items->[3]->{name}, 'ABC Kids listen', 'then the network' );
	is( scalar( grep { $_->{play} } @$items ), 2, 'then the episodes' );
	is( scalar( grep { ( $_->{type} // '' ) eq 'textarea' } @$items ), 1, 'one textarea in the menu' );
};

subtest 'program menu: Wait… They Did What!? (#83 screenshot)' => sub {
	fresh();
	route_programs();
	my $items = items_of( feed( $PROGRAM_MENU, undef, { title => 'Wait… They Did What!?', path => $WAIT } ) );

	is( $items->[0]->{type}, 'textarea', 'the header first' );
	is( $items->[0]->{name}, "Wait... They Did What!? is the question you\x{2019}ll be asking after travelling back through modern history with comedian Tilly Oddy-Black.", '... the first paragraph (133 characters)' );
	is( $items->[1]->{name}, $ABOUT_PROGRAM, 'then "About this program"' );
	like( $items->[1]->{items}->[0]->{name}, qr/Composer: David McDonald\n\nExecutive producers: Veronica Milsom and Alex Lollback\z/, '... the whole text, credits included' );
	is( $items->[2]->{name}, 'Presented by Tilly Oddy-Black', 'then Presented by' );
};

subtest 'program menu: a short description has no About row; rows after it keep their place' => sub {
	fresh();
	my $page = JSON::PP::decode_json( fixture('ondemand/nextdata-program-scienceshow.trimmed.json') );
	$page->{pageProps}->{heroDescriptionPrepared} = { descriptionPrepared => { descriptor => { type => 'tagname', key => 'div', children => [ { type => 'tagname', key => 'p', children => [ { type => 'text', content => 'Science, weekly.' } ] } ] } } };
	route( "$NEXT/listen/programs/short.json", content => to_json($page), headers => $JSON_TYPE );
	route_programs();

	my $items = items_of( feed( $PROGRAM_MENU, undef, { title => 'Short', path => '/listen/programs/short' } ) );
	is_deeply( $items->[0], { name => 'Science, weekly.', type => 'textarea' }, 'the whole description' );
	is( $items->[1]->{name}, 'Presented by Robyn Williams, Belinda Smith', 'then Presented by (no About row)' );
	ok( !( grep { ( $_->{name} // '' ) eq $ABOUT_PROGRAM } @$items ), 'no About row anywhere' );

	# the same program opened again (LMS rebuilds the menu for every item_id): the same rows
	my @first = @{ names( items_of( feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } ) ) ) };
	my @again = @{ names( items_of( feed( $PROGRAM_MENU, undef, { title => 'The Science Show', path => $SCIENCE } ) ) ) };
	is_deeply( \@again, \@first, 'opened twice: the same rows in the same order (stable item ids)' );
	is( $first[1], $ABOUT_PROGRAM, 'the Science Show (two paragraphs): About at index 1' );
};

subtest 'episode menu: a long synopsis is a short header, then "About this episode", then Play episode' => sub {
	fresh();
	my $synopsis = ( 'This episode looks at trees, potatoes and the climate in great detail. ' x 4 ) . "\n\nGuests: many.";
	my $items    = items_of( feed( $EPISODE_MENU, undef, { id => '107266790', title => 'Trees', description => $synopsis, duration => 60 } ) );
	is( $items->[0]->{type}, 'textarea', 'the synopsis header first (LMS blanks rows before a textarea)' );
	ok( length( $items->[0]->{name} ) <= 200, 'at most 200 characters' );
	like( $items->[0]->{name}, qr/\AThis episode looks at trees.+detail\. \Q$ELLIPSIS\E\z/, 'cut at a sentence end' );
	is_deeply( $items->[1], { name => $ABOUT_EPISODE, type => 'link', items => [ { name => ( $synopsis =~ s/\s+\z//r ), type => 'textarea' } ] }, 'then "About this episode" with the whole synopsis' );
	is( $items->[2]->{name}, 'Play episode', 'then Play episode' );
	is( $items->[2]->{type}, 'audio', '... still the audio item' );

	$items = items_of( feed( $EPISODE_MENU, undef, { id => '107266790', title => 'Trees', description => 'Palm oil and nickel.', duration => 60 } ) );
	is_deeply( names($items), [ 'Palm oil and nickel.', 'Play episode', '1 min' ], 'a short synopsis: no About row' );

	# a segment row's own menu works the same way
	my $row = $OD->episodeItem( undef, { id => '5', title => 'Seg', description => 'word ' x 80 } );
	$items = items_of( feed( $row->{url}, undef, @{ $row->{passthrough} } ) );
	is_deeply( [ map { $_->{type} } @$items[ 0 .. 2 ] ], [qw(textarea link audio)], 'opened from a row: textarea, About, Play episode' );
};

subtest 'song info: Episode notes stays full length (behind its own link already)' => sub {
	fresh();
	my $notes = 'word ' x 100;
	$notes =~ s/ \z//;
	Plugins::ABCListen::Util::setEpisodeMeta( '9001', { title => 'Notes', description => $notes } );
	my $rows = Plugins::ABCListen::Episode::_trackInfoItems( undef, 'abclisten://episode/9001' );
	is( $rows->[0]->{name}, string('PLUGIN_ABCLISTEN_EPISODE_NOTES'), 'Episode notes' );
	is( $rows->[0]->{items}->[0]->{name}, $notes, '... the whole description (' . length($notes) . ' characters)' );
};

done_testing();
