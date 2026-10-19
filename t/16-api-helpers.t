#!/usr/bin/perl
# Plugins::ABCListen::API pure helpers (no I/O): imageUrl (wcms crop params kept, srcSet pick on the
# radio resizer), richText, coreMediaRef, sitePath and cardRef: the FQ4 naming rule, id from cardId
# (spec amendment), and every card in the copied fixtures plus synthetic edge cards.
#
# Card fixtures (t/data/foundation/, raw response bodies copied from ai-state/research/abc-samples/,
# trimmed there, shapes unedited; see t/15-api.t for the full provenance list):
#   bff-collection-home-most-popular-podcasts.json   GET /core-next/api/collection/listen?collectionId=103194120&offset=0&size=10
#   bff-collection-audiobooks-most-popular.json      GET /core-next/api/collection/x?collectionId=105672994&rootMetaCollectionId=105894152&metaInMeta=false&offset=0&size=20
#   bff-collection-local-stations-nsw.json           GET /core-next/api/collection/listen/radio?collectionId=14126370&rootMetaCollectionId=14123276&metaInMeta=false
#   bff-collection-national-networks.json            GET /core-next/api/collection/listen/radio?collectionId=12872264&rootMetaCollectionId=14139428&metaInMeta=false
#   bff-collection-empty.json                        synthetic: the home collection with no items
#   bff-programAggregationCollection-rn.json         GET /core-next/api/programAggregationCollection/listen/radionational/programs?collectionId=11474038&offset=20&size=20&total=56
#   bff-episodesWithSegments-scienceshow.json        GET /core-next/api/episodesWithSegments/listen/programs/scienceshow?collectionId=2885458&offset=240&size=10&total=250&programTemplate=audio
#   bff-recommendations-homepagePopularNow.json      GET /core-next/api/recommendations/listen/homepagePopularNow
#   nextdata-listen-home.components.trimmed.json     GET /_next/data/build-3afcd04f/listen.json (research summary of pageProps.data, re-wrapped)
#   nextdata-program-scienceshow.trimmed.json        GET /_next/data/<buildId>/listen/programs/scienceshow.json (pageProps, re-wrapped)
#   nextdata-section-news.trimmed.json               GET /_next/data/build-3afcd04f/listen/news.json
#   nextdata-section-kidslisten-programs.trimmed.json GET /_next/data/build-3afcd04f/kidslisten/programs.json
#   nextdata-section-sport.programs.trimmed.json     GET /_next/data/build-3afcd04f/listen/sport.json (the 'Programs' collection only)
#   epgNowPlaying-RN-now.json (F1, research wrapper kept) for a resize.abcradio.net.au prepared image
# F5 (alt text as a name only when it spells the slug) also reads t/data/discovery/ (see
# t/40-collections.t): bff-collection-103194120-most-popular-podcasts-o{0,20,40}.json, the 20 program
# cards that took their name from the alt text before F5, and every card of every committed fixture
# (t/data/*/*.json) for the title junk and slug checks.

use strict;
use warnings;
use utf8;

use ABCListenTest qw(:all);
use Test::More;

use File::Glob qw(bsd_glob);
use JSON::PP ();
use Time::Local qw(timegm);
use Unicode::Normalize ();

use Plugins::ABCListen::API qw(:all);
use Plugins::ABCListen::Util qw(decodeEntities);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my @CARD_FIXTURES = qw(
	bff-collection-home-most-popular-podcasts.json bff-collection-audiobooks-most-popular.json
	bff-collection-local-stations-nsw.json bff-collection-national-networks.json bff-collection-empty.json
	bff-programAggregationCollection-rn.json bff-episodesWithSegments-scienceshow.json
	bff-recommendations-homepagePopularNow.json nextdata-listen-home.components.trimmed.json
	nextdata-program-scienceshow.trimmed.json nextdata-section-news.trimmed.json
	nextdata-section-kidslisten-programs.trimmed.json nextdata-section-sport.programs.trimmed.json
);

my @CARD_KEYS = sort qw(type id uriId title tagline path image date duration programId docType description);

my $WCMS = 'https://live-production.wcms.abc-cdn.net.au';

# A decoded fixture: a bare file name is in t/data/foundation/, 'dir/file' anywhere in t/data/.
sub json { JSON::PP::decode_json( fixture( $_[0] =~ m{/} ? $_[0] : "foundation/$_[0]" ) ) }

# Letters and digits only, lower case, accents removed: what a slug spells.
sub spelling {
	my $text = Unicode::Normalize::NFD(shift);
	$text =~ s/\p{Mn}+//g;
	$text = lc $text;
	$text =~ s/[^a-z0-9]+//g;
	return $text;
}

# The articleLink's slug (last path segment, minus a trailing '-page'), or undef.
sub slug_of {
	my $link = shift;
	return undef unless defined $link && !ref $link;
	$link =~ s/[?#].*\z//s;
	$link =~ s{/+\z}{};
	my ($slug) = $link =~ m{/([^/]+)\z} or return undef;
	$slug =~ s/-page\z//i;
	return $slug;
}

sub clean_text {
	my $text = shift;
	return undef unless defined $text && !ref $text;
	$text = decodeEntities($text);
	$text =~ s/\A\s+|\s+\z//g;
	return length $text ? $text : undef;
}

# Every card in a decoded fixture (a hash with a string contentUri and a cardTitle), in document order.
sub cards_in {
	my $node = shift;
	my @cards;
	if ( ref $node eq 'HASH' ) {
		push @cards, $node if defined $node->{contentUri} && !ref $node->{contentUri} && exists $node->{cardTitle};
		push @cards, cards_in( $node->{$_} ) for sort keys %$node;
	}
	elsif ( ref $node eq 'ARRAY' ) {
		push @cards, cards_in($_) for @$node;
	}
	return @cards;
}

sub card {
	my ( $file, $uri ) = @_;
	my ($card) = grep { $_->{contentUri} eq $uri } cards_in( json($file) );
	die "no card $uri in $file" unless $card;
	return $card;
}

# URL query params in order
sub params_of { my ($query) = $_[0] =~ /\?(.*)\z/; return [ split /&/, $query ] }

# ---------------------------------------------------------------------------
# imageUrl
# ---------------------------------------------------------------------------

subtest 'imageUrl: wcms URLs keep every crop param; only width and height change' => sub {
	my $square = "$WCMS/fa3d02deb8296dc957a2e9c3494e4672?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=862&height=862";
	is( imageUrl( $square, 300 ), "$WCMS/fa3d02deb8296dc957a2e9c3494e4672?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=300&height=300", '1x1 crop: 300x300' );
	is( imageUrl( $square, 1400 ), "$WCMS/fa3d02deb8296dc957a2e9c3494e4672?impolicy=wcms_crop_resize&cropH=3000&cropW=3000&xPos=0&yPos=0&width=1400&height=1400", '1x1 crop: 1400x1400' );

	# a 16x9 crop from the listen home fixture (dynamiccollection card)
	my $wide = card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://dynamiccollection/14129466' )->{cardImagePrepared}->{imgSrc};
	like( $wide, qr/cropH=721&cropW=1281/, 'fixture image has a 16x9 crop' );
	my $sized = imageUrl( $wide, 300 );
	is( $sized, "$WCMS/2659a0291dae2610412b27164892897b?impolicy=wcms_crop_resize&cropH=721&cropW=1281&xPos=0&yPos=0&width=300&height=169", 'cropW != cropH: height = round(300 * 721 / 1281)' );
	my @before = grep { !/^(?:width|height)=/ } @{ params_of($wide) };
	my @after  = grep { !/^(?:width|height)=/ } @{ params_of($sized) };
	is_deeply( \@after, \@before, 'every other param kept, in order (impolicy, cropH, cropW, xPos, yPos)' );

	my $video = "$WCMS/9e4b220c4100eb7e8919003885591418?impolicy=wcms_crop_resize&cropH=2160&cropW=3840&xPos=0&yPos=0&width=862&height=485";
	is( imageUrl( $video, 640 ), "$WCMS/9e4b220c4100eb7e8919003885591418?impolicy=wcms_crop_resize&cropH=2160&cropW=3840&xPos=0&yPos=0&width=640&height=360", '16x9 at 640: 640x360' );

	is( imageUrl( "$WCMS/abc?impolicy=wcms_crop_resize&cropH=500&cropW=500&xPos=0&yPos=0", 300 ),
		"$WCMS/abc?impolicy=wcms_crop_resize&cropH=500&cropW=500&xPos=0&yPos=0&width=300&height=300", 'width and height added when missing' );
};

subtest 'imageUrl: wcms URLs without crop params are unchanged (impolicy is never added)' => sub {
	my $bare = "$WCMS/94fd4544070cf8410aed9d4942f448d9";
	is( imageUrl( $bare, 300 ), $bare, 'bare hash URL unchanged' );
	is( imageUrl( "$bare.jpg?src", 300 ), "$bare.jpg?src", '?src original unchanged' );
	is( imageUrl( "$bare?width=862&height=862", 300 ), "$bare?width=862&height=862", 'width/height without impolicy: unchanged' );
	is( imageUrl( "$bare?impolicy=wcms_crop_resize&width=862&height=862", 300 ), "$bare?impolicy=wcms_crop_resize&width=862&height=862",
		'impolicy without crop params: unchanged' );
	is( imageUrl( "$bare?impolicy=wcms_crop_resize&cropH=0&cropW=500", 300 ), "$bare?impolicy=wcms_crop_resize&cropH=0&cropW=500", 'zero crop: unchanged' );
	unlike( imageUrl( $bare, 300 ), qr/impolicy/, 'no impolicy added' );
};

subtest 'imageUrl: prepared hashes use imgSrc crop params, even when srcSet differs' => sub {
	my $prepared = card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://audioepisode/107108716' )->{cardImagePrepared};
	like( $prepared->{imgSrc}, qr/xPos=560/, 'imgSrc crop xPos=560' );
	like( $prepared->{srcSet}->[0], qr/xPos=606/, 'srcSet crop xPos=606' );

	is( imageUrl( $prepared, 300 ), "$WCMS/572bd05158641dbf1adb3550221a98e8?impolicy=wcms_crop_resize&cropH=2581&cropW=2581&xPos=560&yPos=0&width=300&height=300",
		"imgSrc's crop params used" );
	is( imageUrl( { imgSrc => '' }, 300 ), undef, 'empty imgSrc: undef' );
	is( imageUrl( { srcSet => $prepared->{srcSet} }, 300 ), undef, 'no imgSrc: undef' );
	is( imageUrl( {}, 300 ), undef, 'empty hash: undef' );
};

subtest 'imageUrl: resize.abcradio.net.au picks the nearest srcSet size' => sub {
	my $prepared = json('epgNowPlaying-RN-now.json')->{data}->{preparedImage};
	is( scalar @{ $prepared->{srcSet} }, 6, 'fixture srcSet has 6 sizes (100..1300)' );

	my %expect = ( 50 => 100, 100 => 100, 101 => 160, 300 => 340, 340 => 340, 600 => 940, 1300 => 1300, 2000 => 1300 );
	for my $px ( sort { $a <=> $b } keys %expect ) {
		my $url = imageUrl( $prepared, $px );
		like( $url, qr{=/$expect{$px}x$expect{$px}/center/}, "$px px -> the $expect{$px} entry" );
		unlike( $url, qr/\s/, "$px px: the width descriptor is stripped" );
	}

	is( imageUrl( $prepared->{imgSrc}, 300 ), $prepared->{imgSrc}, 'URL string without a srcSet: unchanged (signed URL)' );
	is( imageUrl( { imgSrc => $prepared->{imgSrc}, srcSet => [] }, 300 ), $prepared->{imgSrc}, 'empty srcSet: imgSrc unchanged' );

	# entries without a "<n>w" descriptor: the width comes from the /WxH/ path segment
	my @plain = map { ( split / /, $_ )[0] } @{ $prepared->{srcSet} };
	like( imageUrl( { imgSrc => $prepared->{imgSrc}, srcSet => \@plain }, 300 ), qr{=/340x340/}, 'width from the URL when there is no descriptor' );
};

subtest 'imageUrl: undef, empty and other hosts' => sub {
	is( imageUrl( undef, 300 ), undef, 'undef -> undef' );
	is( imageUrl( '',    300 ), undef, "'' -> undef" );
	is( imageUrl( 'https://www.abc.net.au/radio/images/service/ABC-News-2024.png', 300 ), 'https://www.abc.net.au/radio/images/service/ABC-News-2024.png', 'abc.net.au image unchanged' );
	is( imageUrl( 'https://example.com/a.jpg?width=10&height=10', 300 ), 'https://example.com/a.jpg?width=10&height=10', 'non-ABC URL unchanged' );
	my $square = "$WCMS/x?impolicy=wcms_crop_resize&cropH=1&cropW=1&width=862&height=862";
	is( imageUrl( $square, undef ), $square, 'no size: unchanged' );
	is( imageUrl( $square, 'big' ), $square, 'bad size: unchanged' );
	is( Plugins::ABCListen::API->imageUrl( $square, 100 ), "$WCMS/x?impolicy=wcms_crop_resize&cropH=1&cropW=1&width=100&height=100", 'works as a class method' );
};

# ---------------------------------------------------------------------------
# richText
# ---------------------------------------------------------------------------

subtest 'richText: the Science Show description' => sub {
	my $hero = json('nextdata-program-scienceshow.trimmed.json')->{pageProps}->{heroDescriptionPrepared};
	like( $hero->{descriptionPrepared}->{descriptor}->{children}->[0]->{children}->[0]->{content}, qr/Show\x{A0}gives/, 'fixture text has a no-break space' );

	my $expected = "The Science Show gives Australians unique insights into the latest scientific research and debate, from the physics of cricket to prime ministerial biorhythms."
		. "\n\nAirs Saturday 12pm, Monday 4am and 1.30pm and Tuesday 9.30pm.";

	is( richText($hero), $expected, 'descriptionPrepared.descriptor: 2 paragraphs, nbsp normalised, nested strong flattened' );
	is( richText( $hero->{descriptionPrepared} ), $expected, 'hash with descriptor' );
	is( richText( $hero->{descriptionPrepared}->{descriptor} ), $expected, 'descriptor node' );
};

subtest 'richText: blocks, inline nodes, whitespace and entities' => sub {
	my $t = sub { { type => 'text', content => $_[0] } };
	my $tag = sub { my ( $key, @children ) = @_; { type => 'tagname', key => $key, props => {}, children => \@children } };

	is( richText( $tag->( 'p', $t->('Hello '), $tag->( 'strong', $t->('bold') ), $t->(' world'), $tag->( 'a', $t->('!') ) ) ),
		'Hello bold world!', 'inline nodes (strong, a) stay in the paragraph' );

	my $doc = $tag->(
		'div',
		$tag->( 'p', $t->('one') ), $tag->( 'p' ), $tag->( 'br' ), $tag->( 'p', $t->(' ') ),
		$tag->( 'h2', $t->('two') ), $tag->( 'li', $t->('three') ), $tag->( 'blockquote', $t->('four') ),
		$tag->( '@@standfirst', $t->('five') ), $tag->( 'H6', $t->('six') ),
	);
	is( richText($doc), "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix", 'block keys separate paragraphs; no empty, leading, trailing or duplicate breaks' );

	is( richText( $tag->( 'p', $t->("  lots \n of\t\x{A0}space  ") ) ), 'lots of space', 'whitespace collapsed and trimmed inside a paragraph' );
	is( richText( $tag->( 'p', $t->('Fish &amp; chips &#8217;n&nbsp;peas') ) ), "Fish & chips \x{2019}n peas", 'entities decoded' );
	is( richText( { descriptor => $tag->( 'p', $t->('x'), { type => 'image', props => {} } ) } ), 'x', 'unknown node types without text are skipped' );
	is( richText( $tag->( 'div', $t->('loose'), $tag->( 'p', $t->('para') ), $t->('tail') ) ), "loose\n\npara\n\ntail", 'text around blocks forms its own paragraphs' );
	is( richText( $tag->( 'p', $t->('line one'), $tag->( 'br' ), $t->('line two') ) ), "line one\n\nline two", 'br inside a paragraph breaks it' );
};

subtest 'richText: empty, strings and unrecognised input' => sub {
	is( richText( { type => 'tagname', key => 'div', props => {}, children => [] } ), '', 'empty descriptor -> empty string' );
	is( richText( { descriptionPrepared => { descriptor => { type => 'tagname', key => 'div', children => [] } } } ), '', 'empty descriptionPrepared -> empty string' );
	is( richText(' Tom &amp; Jerry&#39;s show '), "Tom & Jerry's show", 'plain string: entities decoded, trimmed' );
	is( richText(undef),            '', 'undef -> empty string' );
	is( richText( [] ),             '', 'array -> empty string' );
	is( richText( { foo => 1 } ),   '', 'unknown hash -> empty string' );
	is( richText( { descriptor => 'x' } ), '', 'descriptor that is not a node -> empty string' );
	is( richText( \'text' ),        '', 'scalar ref -> empty string' );
};

# ---------------------------------------------------------------------------
# coreMediaRef and sitePath
# ---------------------------------------------------------------------------

subtest 'coreMediaRef' => sub {
	is_deeply( [ coreMediaRef('coremedia://program/123') ],            [ 'program', 123 ],            'program' );
	is_deeply( [ coreMediaRef('coremedia://audioepisode/107266790') ], [ 'audioepisode', 107266790 ], 'audioepisode' );
	is_deeply( [ coreMediaRef('coremedia://teaser/104919410') ],       [ 'teaser', 104919410 ],       'teaser' );
	is_deeply( [ coreMediaRef('coremedia://dynamiccollection/1') ],    [ 'dynamiccollection', 1 ],    'dynamiccollection' );
	for my $bad ( undef, '', 'coremedia://program/', 'coremedia://program/abc', 'coremedia://program/123/', 'coremedia:///123',
		'papi://episode/peadd01126', 'https://www.abc.net.au/news/123', ' coremedia://program/1', [] ) {
		is_deeply( [ coreMediaRef($bad) ], [], 'not a CoreMedia ref: ' . ( defined $bad ? "'$bad'" : 'undef' ) );
	}
};

subtest 'sitePath' => sub {
	my @cases = (
		[ 'https://www.abc.net.au/listen/programs/if-youre-listening/', '/listen/programs/if-youre-listening' ],
		[ 'http://www.abc.net.au/listen/programs/scienceshow',          '/listen/programs/scienceshow' ],
		[ 'https://www.abc.net.au/listen/radio#find-your-local-station', '/listen/radio' ],
		[ 'https://www.abc.net.au/listen/search?query=science&page=2',  '/listen/search' ],
		[ 'https://abc.net.au/listen/live/sportextra',                  '/listen/live/sportextra' ],
		[ 'http://abc.net.au/kidslisten/',                              '/kidslisten' ],
		[ 'HTTPS://WWW.ABC.NET.AU/listen/news',                         '/listen/news' ],
		[ '//www.abc.net.au/listen',                                    '/listen' ],
		[ '/listen/programs/godforbid/',                                '/listen/programs/godforbid' ],
		[ '/listen/programs/scienceshow/x/107266790?x=1',               '/listen/programs/scienceshow/x/107266790' ],
		[ '/news/2026-10-19/slug/107282192',                            '/news/2026-10-19/slug/107282192' ],
		[ 'https://www.abc.net.au/',                                    '/' ],
		[ 'https://www.abc.net.au',                                     '/' ],
		[ ' /listen/ ',                                                 '/listen' ],
	);
	is( sitePath( $_->[0] ), $_->[1], "'$_->[0]' -> '$_->[1]'" ) for @cases;

	for my $bad ( undef, '', 'listen/programs', 'https://example.com/listen', 'https://iview.abc.net.au/show/x',
		'https://www.abc.net.au.example.com/listen', 'https://notabc.net.au/listen', 'mailto:someone@abc.net.au', 'ftp://www.abc.net.au/x', {} ) {
		is( sitePath($bad), undef, 'undef for ' . ( defined $bad ? "'$bad'" : 'undef' ) );
	}
};

# ---------------------------------------------------------------------------
# cardRef
# ---------------------------------------------------------------------------

subtest 'cardRef: FQ4 program names (exact titles and taglines)' => sub {
	my @table = (
		# F5: alt 'Global Roaming podcast' spells /global-roaming/ and is trimmed to that part
		[ 'bff-collection-home-most-popular-podcasts.json', 'coremedia://program/104525826', 'Global Roaming', 'Global news and how to make sense of it' ],
		[ 'bff-programAggregationCollection-rn.json', 'coremedia://program/8132136', 'God Forbid', undef ],
		[ 'bff-collection-home-most-popular-podcasts.json', 'coremedia://program/104252122', "What's really going on behind the biggest news stories", undef ],
		[ 'nextdata-listen-home.components.trimmed.json', 'coremedia://program/107274050', 'The Dinner Mix: Brisbane Special', undef ],
		[ 'nextdata-section-kidslisten-programs.trimmed.json', 'coremedia://program/13078228', 'Bedtime Stories', undef ],
		[ 'nextdata-section-sport.programs.trimmed.json', 'coremedia://program/10584496', 'ABC Cricket Podcast', undef ],
	);

	for my $row (@table) {
		my ( $file, $uri, $title, $tagline ) = @$row;
		my $card = card( $file, $uri );
		my $ref  = cardRef($card);
		is( $ref->{title},   $title,   "$uri: title" );
		is( $ref->{tagline}, $tagline, "$uri: tagline" );
		is( $ref->{type}, 'program', "$uri: type program" );
		note "alt: $card->{cardImagePrepared}->{alt}";
	}

	like( card( 'bff-programAggregationCollection-rn.json', 'coremedia://program/8132136' )->{cardImagePrepared}->{alt}, qr/\blogo\b.*\bfeaturing\b/, 'God Forbid alt has "logo" and "featuring"' );
	like( card( 'bff-collection-home-most-popular-podcasts.json', 'coremedia://program/104252122' )->{cardImagePrepared}->{alt}, qr/3000x3000.*square/, "If You're Listening alt has 3000x3000 and square" );
	is( card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://program/107274050' )->{cardImagePrepared}->{alt}, '1x1 Program Image', 'Dinner Mix alt is "1x1 Program Image"' );
	is( card( 'nextdata-section-kidslisten-programs.trimmed.json', 'coremedia://program/13078228' )->{cardImagePrepared}->{alt}, 'child sleeping on crescent moon with book', 'Bedtime Stories alt is an image description' );
	is( card( 'nextdata-section-sport.programs.trimmed.json', 'coremedia://program/10584496' )->{cardImagePrepared}->{alt}, 'Hosts with cricket paraphernalia', 'ABC Cricket Podcast alt is an image description' );

	# F5: the 20 Most Popular Podcasts program cards (of 54) whose cardTitle does not spell the slug
	# and whose alt text passed the looks-like-a-name rules, so their name came from the alt text before F5.
	my ( $o0, $o20, $o40 ) = map {"discovery/bff-collection-103194120-most-popular-podcasts-o$_.json"} 0, 20, 40;
	my @mpp = (
		# the alt text does not spell the slug (another program, an episode, a file, an image, the network): cardTitle
		[ $o0,  'coremedia://program/105102080', 'Global Roaming podcast',           'Big moments that changed the course of history',              undef ],
		[ $o0,  'coremedia://program/107254950', 'BONDY: FROM HERO TO ZERO ',        'Mark Humphries tells the remarkable true story of Alan Bond', undef ],
		[ $o0,  'coremedia://program/105985824', 'Unravel-Generic_3000x3000',        'Award-winning Investigative True Crime',                      undef ],
		[ $o0,  'coremedia://program/104331816', 'Roy and HG Podcast Tile',          'Last episode of the year for the masters of midfield mayhem', undef ],
		[ $o0,  'coremedia://program/106369508', 'ABC Podcasts Dino Dome',           'Who will win the first Dino Dome Teams Challenge?',           undef ],
		[ $o20, 'coremedia://program/106301456', 'News Top Stories',                 'The latest breaking news across the day',                     undef ],
		[ $o20, 'coremedia://program/106162560', 'Hosts with cricket paraphernalia', 'The biggest issues and stories in cricket',                   undef ],
		[ $o40, 'coremedia://program/106232754', 'The Science Show - ABC RN',        'Unique insights into science',                                undef ],

		# the alt text spells the slug, then junk or extra words: trimmed to the part that spells it
		[ $o0, 'coremedia://program/104525826', 'Global Roaming podcast',           'Global Roaming',     'Global news and how to make sense of it' ],
		[ $o0, 'coremedia://program/104960366', 'Late Night Live podcast',          'Late Night Live',    'Incisive analysis, fearless debates & nightly surprises' ],
		[ $o0, 'coremedia://program/104416144', 'BackgroundBriefing_3000x3000.jpg', 'BackgroundBriefing', 'Must-listen investigative journalism' ],
		[ $o0, 'coremedia://program/104252126', 'Dr Karl Podcast Tile',             'Dr Karl Podcast',    'Solving the mysteries of the world, with science!' ],
		[ $o0, 'coremedia://program/104252134', 'All In The Mind podcast tile',     'All In The Mind',    'Explore a world of mind, brain and behaviour' ],

		# the alt text is the name
		[ $o0,  'coremedia://program/104252132', 'Conversations',          'Conversations',          "Meet someone who's seen and done amazing things" ],
		[ $o0,  'coremedia://program/105116426', 'Politics Now',           'Politics Now',           'Political coverage you can trust' ],
		[ $o20, 'coremedia://program/104991340', 'ABC News Daily',         'ABC News Daily',         'One big story - Coverage you can trust' ],
		[ $o20, 'coremedia://program/106219650', 'Lady Killers ',          'Lady Killers',           'The sensational crimes of Victorian era women' ],
		[ $o40, 'coremedia://program/106199340', 'The Economy Stupid',     'The Economy Stupid',     'Your guide to the world of business, economics and finance' ],
		[ $o40, 'coremedia://program/106189570', 'Do You Know Mordechai?', 'Do You Know Mordechai?', 'A smooth-talking conman is stealing hearts' ],
		[ $o40, 'coremedia://program/105810568', 'Evil Genius',            'Evil Genius',            'Comedians decide if historical figures are heroes or villains' ],
	);

	for my $row (@mpp) {
		my ( $file, $uri, $alt, $title, $tagline ) = @$row;
		my $card = card( $file, $uri );
		my $ref  = cardRef($card);
		is( $card->{cardImagePrepared}->{alt}, $alt, "$uri: fixture alt '$alt'" );
		is( $ref->{title},   $title,   "$uri: title '$title'" );
		is( $ref->{tagline}, $tagline, "$uri: tagline" );
	}

	my @programs = grep { $_->{contentUri} =~ m{\Acoremedia://program/} } map { cards_in( json($_) ) } $o0, $o20, $o40;
	is( scalar @programs, 54, 'Most Popular Podcasts fixtures: 54 program cards' );
	my %alt = map { $_->[1] => 1 } grep { defined $_->[4] } @mpp;
	is_deeply(
		[ sort map { $_->{contentUri} } grep { my $r = cardRef($_); defined $r->{tagline} } @programs ],
		[ sort keys %alt ],
		'only the 12 cards whose alt text spells the slug take their name from it'
	);
};

subtest 'cardRef: id comes from cardId; uriId from contentUri (spec amendment)' => sub {
	my $ifl = cardRef( card( 'bff-collection-home-most-popular-podcasts.json', 'coremedia://program/104252122' ) );
	is( $ifl->{id},    '9593170',   'program/104252122: id = cardId 9593170' );
	is( $ifl->{uriId}, '104252122', 'program/104252122: uriId 104252122' );

	my ($latest) = grep { $_->{contentUri} eq 'coremedia://audioepisode/103186434' } cards_in( json('nextdata-section-news.trimmed.json') );
	ok( $latest, 'news page has the "Latest Current Affairs" teaser card' );
	my $ref = cardRef($latest);
	is( $ref->{id},    '107232996', 'audioepisode/103186434: id = cardId 107232996' );
	is( $ref->{uriId}, '103186434', 'audioepisode/103186434: uriId 103186434' );
	is( $ref->{path},  '/listen/programs/pm/greens-leader-disputes-senator-s-leave-status/107232996', 'path is the episode page' );

	my $same = cardRef( card( 'bff-programAggregationCollection-rn.json', 'coremedia://program/8132136' ) );
	is( $same->{id},    '8132136', 'cardId equal to the contentUri id: id unchanged' );
	is( $same->{uriId}, '8132136', '... and uriId the same' );

	my $base = { contentUri => 'coremedia://audioepisode/103186434', cardTitle => 'x', articleLink => '/listen/programs/pm/slug/107232996/' };
	is( cardRef( { %$base, cardId => undef } )->{id}, '107232996', 'audio card without cardId: numeric last segment of articleLink' );
	is( cardRef( { %$base, cardId => 'abc' } )->{id}, '107232996', 'non-numeric cardId: articleLink' );
	is( cardRef( { %$base, cardId => undef, articleLink => '/listen/programs/pm/' } )->{id}, '103186434', 'no numeric segment: contentUri id' );
	is( cardRef( { contentUri => 'coremedia://dynamiccollection/14129466', cardTitle => 'News', articleLink => '/listen/listenapp/news-and-analysis/104142082' } )->{id},
		'104142082', 'dynamiccollection without cardId: articleLink' );
	is( cardRef( { contentUri => 'coremedia://program/104252122', cardTitle => 'x', articleLink => '/listen/programs/123' } )->{id},
		'104252122', 'program without cardId: contentUri id (articleLink is not used)' );
};

subtest 'cardRef: every card in the copied fixtures' => sub {
	my ( %types, $count );

	for my $file (@CARD_FIXTURES) {
		for my $card ( cards_in( json($file) ) ) {
			my $name = "$file $card->{contentUri}";
			my $ref  = cardRef($card);
			my ( $type, $uriId ) = coreMediaRef( $card->{contentUri} );
			$count++;

			ok( $ref, "$name: parsed" ) or next;
			$types{ $ref->{type} }++;

			is_deeply( [ sort keys %$ref ], \@CARD_KEYS, "$name: exact keys" );
			is( $ref->{type},  $type,  "$name: type from contentUri" );
			is( $ref->{uriId}, $uriId, "$name: uriId from contentUri" );
			like( $ref->{id}, qr/\A[0-9]+\z/, "$name: numeric id" );
			is( $ref->{id}, $card->{cardId}, "$name: id = cardId" ) if defined $card->{cardId} && $card->{cardId} =~ /\A[0-9]+\z/;
			ok( defined $ref->{title} && length $ref->{title} && $ref->{title} !~ /\A\s|\s\z/, "$name: trimmed title" );
			ok( !defined $ref->{tagline} || lc $ref->{tagline} ne lc $ref->{title}, "$name: tagline does not repeat the title" );
			ok( !defined $ref->{path} || $ref->{path} =~ m{\A/}, "$name: path is a site path" );
			ok( !defined $ref->{image} || $ref->{image} =~ m{\Ahttps://}, "$name: image URL" );
			ok( !defined $ref->{duration} || $ref->{duration} =~ /\A[1-9][0-9]*\z/, "$name: duration a positive integer or undef" );
			ok( !defined $ref->{date} || $ref->{date} > 1_000_000_000, "$name: date an epoch or undef" );
			if ( $type =~ /\A(?:audioepisode|audio|audiosegment)\z/ ) {
				is( $ref->{docType}, defined $card->{docType} ? $card->{docType} : $type, "$name: docType" );
			}
			else {
				is( $ref->{tagline}, undef, "$name: no tagline" ) unless $type eq 'program';
			}
		}
	}

	note "$count cards: " . join( ', ', map {"$_ $types{$_}"} sort keys %types );
	ok( $count >= 50, "at least 50 fixture cards ($count)" );
	ok( $types{$_}, "fixtures cover $_ cards" ) for qw(program audioepisode audio audiosegment dynamiccollection channel teaser externallink video);
	is( scalar cards_in( json('bff-collection-empty.json') ), 0, 'the empty collection has no cards' );

	# F5: every card of every committed fixture (t/data/*/*.json that decodes). No title carries file
	# or image junk; a program title taken from the alt text spells its slug (nothing unrelated, nothing
	# more) and is a part of that alt text.
	my ( $files, $titles, $fromAlt, @junk, @unrelated, @notAlt ) = ( 0, 0, 0 );
	for my $path ( sort { $a cmp $b } bsd_glob( fixturePath('*') . '/*.json' ) ) {
		my ($rel) = $path =~ m{([^/\\]+/[^/\\]+)\z};
		my $data = eval { json($rel) } or next;
		$files++;

		for my $card ( cards_in($data) ) {
			my $ref = cardRef($card) or next;
			defined( my $title = $ref->{title} ) or next;
			$titles++;
			my $name = "$rel $card->{contentUri} '$title'";

			push @junk, $name if $title =~ /\.(?:jpe?g|png|gif|webp|svg|tiff?|bmp)\b/i || $title =~ /[0-9]{3,}x[0-9]{3,}/i || $title =~ /\btile\b/i;

			my $cardTitle = clean_text( $card->{cardTitle} );
			next if $ref->{type} ne 'program' || ( defined $cardTitle && $title eq $cardTitle );
			$fromAlt++;

			my $slug = slug_of( $card->{articleLink} );
			push @unrelated, $name unless defined $slug && spelling($title) eq spelling($slug);

			my $alt = clean_text( ref $card->{cardImagePrepared} eq 'HASH' ? $card->{cardImagePrepared}->{alt} : undef );
			push @notAlt, $name unless defined $alt && index( join( ' ', split /[\s_]+/, $alt ), $title ) >= 0;
		}
	}

	note "$files fixture files, $titles titles, $fromAlt from alt text";
	ok( $files >= 60,   "every committed fixture that decodes ($files)" );
	ok( $titles >= 300, "at least 300 titles ($titles)" );
	ok( $fromAlt >= 12, "at least 12 program titles from alt text ($fromAlt)" );
	is_deeply( \@junk,      [], 'no title has a file extension, an NNNNxNNNN size or the word "Tile"' );
	is_deeply( \@unrelated, [], 'every title from alt text spells exactly its articleLink slug' );
	is_deeply( \@notAlt,    [], 'every title from alt text is a part of that alt text' );
};

subtest 'cardRef: types pass through, with their fields' => sub {
	my $teaser = cardRef( card( 'bff-programAggregationCollection-rn.json', 'coremedia://teaser/104919410' ) );
	is_deeply(
		$teaser,
		{
			type => 'teaser', id => '104919410', uriId => '104919410', title => 'The History Showcase', tagline => undef,
			path => '/listen/programs/radio-national-showcase',
			image => "$WCMS/062ea7ff44329312542b4af74fb5bf56?impolicy=wcms_crop_resize&cropH=1125&cropW=1125&xPos=438&yPos=0&width=300&height=300",
			date => undef, duration => undef, programId => undef, docType => undef,
			description => 'A curated selection of the best history and true crime radio from around the world.',
		},
		'teaser card (exact)'
	);

	my ($external) = grep { $_->{contentUri} eq 'coremedia://externallink/13325024' } cards_in( json('nextdata-listen-home.components.trimmed.json') );
	my $ext = cardRef($external);
	is( $ext->{type}, 'externallink', 'externallink: type' );
	is( $ext->{id},   '13325044',     'externallink: id = cardId' );
	is( $ext->{path}, '/listen/radio', 'externallink: absolute link with a fragment -> path' );

	my $channel = cardRef( card( 'bff-collection-local-stations-nsw.json', 'coremedia://channel/14126406' ) );
	is( $channel->{title},       '702 ABC Sydney',         'channel: title is cardTitle (alt not used for non-programs)' );
	is( $channel->{path},        '/listen/live/sydney',    'channel: path' );
	is( $channel->{description}, 'Blue Mountains, Sydney', 'channel: description' );

	my $dyn = cardRef( card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://dynamiccollection/14129466' ) );
	is( $dyn->{type},  'dynamiccollection', 'dynamiccollection: type' );
	is( $dyn->{title}, 'News & Analysis',   'dynamiccollection: title' );
	like( $dyn->{image}, qr/cropH=721&cropW=1281&xPos=0&yPos=0&width=300&height=169\z/, 'dynamiccollection: 16x9 image at 300 px' );

	my $video = cardRef( card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://video/107277762' ) );
	is( $video->{type},     'video', 'video: type passes through' );
	is( $video->{duration}, 1530,    'video: duration' );
	is( $video->{docType},  undef,   'video: no docType' );
	is( $video->{path}, '/listen/programs/if-youre-listening/the-apocalyptic-el-ni%C3%B1o-we-didn-t-see-coming/107277762', 'video: percent-encoded path kept' );

	my $audio = cardRef( card( 'nextdata-section-news.trimmed.json', 'coremedia://audio/107282192' ) );
	is( $audio->{docType}, 'audio', 'audio card without docType: docType = type' );
	is( $audio->{path}, '/news/2026-10-19/work-begins-to-make-melbourne-s-yarra-river-swimmable-again/107282192', 'audio: News site path' );
	is( $audio->{title}, "Work begins to make Melbourne's Yarra River swimmable again", 'audio: title is cardTitle' );

	my $collection = cardRef( { contentUri => 'coremedia://collection/103194120', cardTitle => 'Most Popular Podcasts', articleLink => '/listen/promo-4/103194120' } );
	is( $collection->{type}, 'collection', 'collection card (synthetic): type' );
	is( $collection->{id},   '103194120',  'collection card: id from contentUri' );
};

subtest 'cardRef: episode fields (date, duration, docType, programId)' => sub {
	my $episode = cardRef( card( 'bff-episodesWithSegments-scienceshow.json', 'coremedia://audioepisode/103022914' ) );
	is( $episode->{date},     timegm( 0, 0, 1, 20, 0, 2024 ), 'publishedDate 2024-01-20T01:00:00+00:00 -> epoch' );
	is( $episode->{duration}, 3247,           'duration' );
	is( $episode->{docType},  'audioepisode', "card's docType" );
	ok( defined $episode->{description} && length $episode->{description}, 'description' );
	is( $episode->{path}, '/listen/programs/scienceshow/the-science-show/103022914', 'relative articleLink -> path' );

	my $rec = card( 'bff-recommendations-homepagePopularNow.json', 'coremedia://audioepisode/107238050' );
	is( $rec->{programID}, 7689108, 'recommendation card has programID' );
	is( cardRef($rec)->{programId}, '7689108', 'programId from programID' );
	is( cardRef( { %$rec, programID => undef, programId => '42' } )->{programId}, '42', 'programId from programId' );
	is( cardRef( { %$rec, programID => 'abc' } )->{programId}, undef, 'non-numeric programID -> undef' );

	my $noDuration = card( 'nextdata-listen-home.components.trimmed.json', 'coremedia://audioepisode/107276120' );
	ok( JSON::PP::is_bool( $noDuration->{cardMediaIndicatorPrepared}->{duration} ), 'fixture duration is JSON false' );
	is( cardRef($noDuration)->{duration}, undef, 'duration false -> undef' );

	my $base = { contentUri => 'coremedia://audioepisode/1', cardTitle => 't' };
	for my $bad ( 0, '0', '25 mins', '12.5', -5, '', [] ) {
		is( cardRef( { %$base, cardMediaIndicatorPrepared => { duration => $bad } } )->{duration}, undef, "duration '$bad' -> undef" );
	}
	is( cardRef( { %$base, cardMediaIndicatorPrepared => { duration => 60 } } )->{duration}, 60, 'duration 60 -> 60' );
	is( cardRef( { %$base, cardAttributionPrepared => { publishedDate => '2026-10-17T01:00:00+00:00' } } )->{date}, timegm( 0, 0, 1, 17, 9, 2026 ), '+00:00 date' );
	is( cardRef( { %$base, cardAttributionPrepared => { publishedDate => 'yesterday' } } )->{date}, undef, 'unparseable date -> undef' );
	is( cardRef( { %$base, cardAttributionPrepared => undef } )->{date}, undef, 'no attribution -> undef' );
};

subtest 'cardRef: title rule edge cases, links, text clean-up' => sub {
	my $program = sub { my %extra = @_; cardRef( { contentUri => 'coremedia://program/1', cardTitle => 'An editorial tagline', %extra } ) };

	# alt text on a card whose articleLink ends in /$slug/
	my $alt = sub { my ( $text, $slug, %extra ) = @_; $program->( articleLink => "/listen/programs/$slug/", cardImagePrepared => { alt => $text }, %extra ) };

	# the looks-like-a-name rules still apply to the whole alt text
	my $fifty = 'A' x 50;
	is( $alt->( $fifty, 'a' x 50 )->{title},     $fifty,                 'alt of exactly 50 chars: a name' );
	is( $alt->( "A$fifty", 'a' x 51 )->{title},  'An editorial tagline', 'alt of 51 chars: cardTitle' );
	is( $alt->( '  ', 'show' )->{title},         'An editorial tagline', 'blank alt: cardTitle' );
	is( $alt->( '  ', 'show' )->{tagline},       undef,                  '... and no tagline' );
	is( $program->( articleLink => '/listen/programs/show/', cardImagePrepared => undef )->{title}, 'An editorial tagline', 'no image: cardTitle' );
	is( $alt->( 'Late Night Live 1400X1400', 'latenightlive' )->{title}, 'An editorial tagline', 'NxN token (any case), even after the slug: cardTitle' );
	for my $word (qw(logo image illustration photo graphic stylised stylized square featuring Logo SQUARE)) {
		is( $alt->( "Show $word", 'show' )->{title}, 'An editorial tagline', "alt with '$word', even after the slug: cardTitle" );
	}
	is( $alt->( 'Logophile Hour', 'logophile-hour' )->{title}, 'Logophile Hour', "'Logophile' is not the word 'logo'" );

	my $named = $alt->( ' Background Briefing &amp; Friends ', 'background-briefing-friends', cardTitle => ' Investigations &#8217;n more&nbsp; ' );
	is( $named->{title},   'Background Briefing & Friends', 'alt title decoded and trimmed' );
	is( $named->{tagline}, "Investigations \x{2019}n more", 'tagline is the decoded, trimmed cardTitle' );
	is( $alt->( 'Name', 'name', cardTitle => undef )->{tagline}, undef, 'alt name without cardTitle: no tagline' );

	my $same = $alt->( ' ABC News Daily ', 'abc-news-daily', cardTitle => 'abc news DAILY' );
	is( $same->{title},   'abc news DAILY', 'alt equal to cardTitle (trimmed, any case): both spell the slug, cardTitle wins' );
	is( $same->{tagline}, undef,            '... and no tagline repeating it' );

	# a cardTitle that spells the articleLink slug is the name, whatever the alt says
	my $slugged = sub { my ( $cardTitle, $link ) = @_; $program->( cardTitle => $cardTitle, articleLink => $link, cardImagePrepared => { alt => 'Hosts at a desk' } ) };
	my @spells = (
		[ 'ABC Cricket Podcast',              '/listen/programs/abc-cricket-podcast/',                                 'exact' ],
		[ 'God Forbid',                       '/listen/programs/godforbid/',                                           'slug without hyphens' ],
		[ 'The Dinner Mix: Brisbane Special', '/listen/programs/the-dinner-mix/',                                      'slug a prefix ending at a word boundary' ],
		[ 'The 13-Storey Treehouse',          'https://www.abc.net.au/listen/audiobooks/the-13-storey-treehouse-page/', "trailing '-page' ignored" ],
		[ "If You're Listening!",             'https://abc.net.au/listen/programs/if-youre-listening?x=1#top',          'case, punctuation, query and fragment ignored' ],
		[ 'Bedtime Stories with R.A. Spratt', '/listen/programs/bedtime-stories-with-ra-spratt',                        'dotted initials' ],
	);
	for my $case (@spells) {
		my ( $cardTitle, $link, $name ) = @$case;
		my $ref = $slugged->( $cardTitle, $link );
		is( $ref->{title},   $cardTitle, "spells the slug ($name): title is cardTitle" );
		is( $ref->{tagline}, undef,      "spells the slug ($name): no tagline" );
	}
	my @misses = (
		[ 'Amazing stories, every morning',  '/listen/programs/am/',                             'slug a prefix inside a word' ],
		[ 'Bedtime Stories',                 '/listen/programs/bedtime-stories-with-ra-spratt/', 'cardTitle shorter than the slug' ],
		[ 'The Science Show',                '/listen/programs/scienceshow/',                    'slug not at the start' ],
		[ 'Global news',                     '/',                                                'no slug' ],
	);
	for my $case (@misses) {
		my ( $cardTitle, $link, $name ) = @$case;
		my $ref = $slugged->( $cardTitle, $link );
		is( $ref->{title},   $cardTitle, "does not spell the slug ($name), nor does the alt: title is cardTitle" );
		is( $ref->{tagline}, undef,      "does not spell the slug ($name), nor does the alt: no tagline" );
	}

	# F5: alt text is a name only when it spells the slug, and only the part that spells it
	my @altNames = (
		# punctuation, case and spacing differences
		[ "If You\x{2019}re Listening!",         'if-youre-listening',    "If You\x{2019}re Listening!", 'curly apostrophe; a trailing "!" is kept' ],
		[ 'Do You Know Mordechai? (podcast)',    'do-you-know-mordechai', 'Do You Know Mordechai?',      'a trailing "?" is kept, the rest dropped' ],
		[ 'The Economy, Stupid',                 'the-economy-stupid',    'The Economy, Stupid',         'a comma inside' ],
		[ 'BACKGROUND BRIEFING',                 'backgroundbriefing',    'BACKGROUND BRIEFING',         'upper case, a space the slug lacks' ],
		[ '"Lady Killers"',                      'lady-killers',          'Lady Killers',                'quotes around it dropped' ],
		[ 'The 13-Storey Treehouse',             'the-13-storey-treehouse-page', 'The 13-Storey Treehouse', "digits; trailing '-page' ignored" ],

		# file and image junk after the name
		[ 'Late_Night_Live_3000x3000.jpg',       'latenightlive',         'Late Night Live',             'file name: underscores become spaces, size and extension dropped' ],
		[ 'Politics Now.png',                    'politics-now',          'Politics Now',                'extension dropped' ],
		[ 'Dr Karl Podcast Tile',                'dr-karl-podcast',       'Dr Karl Podcast',             '"Tile" dropped' ],
		[ 'Lady Killers - ABC RN',               'lady-killers',          'Lady Killers',                'network suffix dropped' ],

		# prefix matches at a word boundary only
		[ 'AM with Sabra Lane',                  'am',                    'AM',                          'a whole word' ],
		[ 'The Case Of Jesse and Luke',          'the-case-of',           'The Case Of',                 'whole words of a longer title' ],

		# non-ASCII
		[ "\x{c9}migr\x{e9} Stories podcast tile", 'emigre-stories',      "\x{c9}migr\x{e9} Stories",    'accented letters spell their base letters' ],
		[ "Nga\x{304} Ko\x{304}rero",            'nga-korero',            "Ng\x{101} K\x{14d}rero",      'decomposed accents: composed in the name' ],
		[ "\x{2018}Allo \x{2018}Allo!",          'allo-allo',             "Allo \x{2018}Allo!",          'non-ASCII punctuation is not a letter' ],
	);
	for my $case (@altNames) {
		my ( $text, $slug, $title, $name ) = @$case;
		my $ref = $alt->( $text, $slug );
		is( $ref->{title},   $title,                 "alt spells the slug ($name): '$title'" );
		is( $ref->{tagline}, 'An editorial tagline', "alt spells the slug ($name): tagline is cardTitle" );
	}

	my @altMisses = (
		[ 'Amazing Stories',             'am',                     'the slug inside a word' ],
		[ 'Politics Nowcast',            'politics-now',           'the slug a prefix of a longer word' ],
		[ 'ABC Podcasts Dino Dome',      'dino-dome',              'the slug not at the start' ],
		[ 'Global Roaming podcast',      'no-one-saw-it-coming',   "another program's name" ],
		[ 'News Top Stories',            'abc-news-top-stories',   'shorter than the slug' ],
		[ "Caf\x{e9}",                   'caf',                    'a non-ASCII letter is not a word boundary' ],
		[ "Cafe\x{301}s",                'cafe',                   '... nor is a combining accent before a letter' ],
		[ "Ng\x{101} K\x{14d}rero",      'ng-krero',               'an accented letter is a letter, not punctuation' ],
	);
	for my $case (@altMisses) {
		my ( $text, $slug, $name ) = @$case;
		my $ref = $alt->( $text, $slug );
		is( $ref->{title},   'An editorial tagline', "alt does not spell the slug ($name): cardTitle" );
		is( $ref->{tagline}, undef,                  "alt does not spell the slug ($name): no tagline" );
	}

	# cards with no usable articleLink: the alt text is never a name
	for my $link ( undef, '', '/', 'https://www.abc.net.au/', { href => '/listen/programs/global-roaming/' } ) {
		my $ref = $program->( articleLink => $link, cardImagePrepared => { alt => 'Global Roaming' } );
		my $what = defined $link ? ref $link ? 'a hash' : "'$link'" : 'undef';
		is( $ref->{title},   'An editorial tagline', "articleLink $what: cardTitle" );
		is( $ref->{tagline}, undef,                  "articleLink $what: no tagline" );
	}

	# a non-ASCII cardTitle spells its slug too (the rn-featured synthetic card), whatever the alt says
	my $emigre = cardRef( { %{ card( 'ondemand/bff-programAggregationCollection-rn-featured.synthetic.json', 'coremedia://program/90000001' ) }, cardImagePrepared => { alt => 'Hosts at a desk' } } );
	is( $emigre->{title},   "\x{c9}migr\x{e9} Stories", "'\x{c9}migr\x{e9} Stories' spells /emigre-stories/: title is cardTitle" );
	is( $emigre->{tagline}, undef,                      '... no tagline' );

	my $episode = cardRef( { contentUri => 'coremedia://audioepisode/5', cardTitle => ' Ep &amp; 1 ', cardImagePrepared => { alt => 'Global Roaming podcast' }, description => '  ' } );
	is( $episode->{title},       'Ep & 1', 'non-program: cardTitle even when alt looks like a name' );
	is( $episode->{tagline},     undef,    'non-program: no tagline' );
	is( $episode->{description}, undef,    'blank description -> undef' );

	is( $program->( articleLink => '/listen/programs/godforbid/' )->{path},                    '/listen/programs/godforbid', 'relative articleLink -> path' );
	is( $program->( articleLink => 'https://www.abc.net.au/listen/programs/global-roaming/' )->{path}, '/listen/programs/global-roaming', 'absolute articleLink -> path' );
	is( $program->( articleLink => 'https://www.youtube.com/watch?v=x' )->{path},              undef,                        'off-site articleLink -> undef' );
	is( $program->( articleLink => undef )->{path},                                            undef,                        'no articleLink -> undef' );
};

subtest 'cardRef: not a card' => sub {
	is( cardRef(undef),                                         undef, 'undef' );
	is( cardRef( [] ),                                          undef, 'array' );
	is( cardRef( { cardTitle => 'No uri', cardId => '1' } ),    undef, 'no contentUri' );
	is( cardRef( { contentUri => 'papi://episode/peadd01126' } ), undef, 'non-CoreMedia contentUri' );
	is( cardRef( { contentUri => 'coremedia://unknown/abc' } ), undef, 'unparseable id' );
	ok( cardRef( { contentUri => 'coremedia://program/1' } ), 'a bare contentUri is enough' );
	is( Plugins::ABCListen::API->cardRef( { contentUri => 'coremedia://program/1' } )->{id}, '1', 'works as a class method' );
};

done_testing();
