# Changelog

All notable changes to the ABC listen plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each version's section is
also the text of its GitHub Release (see [RELEASING.md](RELEASING.md)).

## [Unreleased]

### Added

- **High quality (HLS)**, a new Live stream quality option (Settings → Advanced → ABC listen): live stations play
  ABC's HLS streams, the ones ABC's website plays, with **192 kbps AAC on the music stations** instead of 56 kbps,
  and 64 kbps on talk stations. The plugin plays HLS itself, so there is nothing else to install. If a station's
  HLS stream can't be played (some play only in Australia), the same play falls back to the standard stream by
  itself. Now Playing, favourites and menus work as before.
  - LMS fetches the audio itself in this mode, so it uses more CPU on the server than Standard, whose streams go
    straight to the player: about 4–6% of one core on an x86 test server. A Raspberry Pi hasn't been measured yet.
- **The stations ABC streams only in HLS** are listed with High quality (HLS): the Sport Rapid, RLWC Rapid and ABC
  Cricket streams under Sport, and the Northern Territory, Queensland, South Australia and Western Australia
  versions of ABC KIDS listen under Kids listen. They have no standard stream to fall back to, and ABC Cricket
  (possibly the Rapid streams too) may play only in Australia. With another quality, a favourite of one says
  "This station is only streamed in HLS. To play it, set Live stream quality to High quality (HLS) in the ABC
  listen settings."
- A weekly check of every ABC page and service the plugin reads (`scripts/abc-endpoints-check.sh`) opens an issue
  labelled `abc-drift` on GitHub when ABC changes something the plugin relies on.

### Changed

- **Short descriptions at the top of program and episode menus**: the first paragraph, at most about 200
  characters, cut at the end of a sentence or a word with "…". Apps such as Squeezer show the description as a
  fixed header above the list, where a long one filled the screen and hid the episodes. When the description is
  cut, a new row right below it, **About this program** or **About this episode**, opens the whole text. Song
  info's Episode notes still shows all of it.
- **One continuous list instead of "More episodes…" pages:**
  - A program's episodes (up to the newest 250, all that ABC lists) and every collection (Home, Podcasts, Browse
    by category, News, Sport, Kids listen and Audiobooks) are one list each, loaded as you scroll. Lists no
    longer end in "More…" or "More episodes…"; the Default web interface pages them with its own page links.
  - Programs with more than 200 rows (most daily programs) show no description at the top of the list. They
    start with **About this program**, which opens it.
  - An ABC page that fails to load is tried again in smaller pieces. Episodes that still can't be loaded keep
    their place in the list, as "Couldn't load this from ABC listen. Please try again later." rows.
- The README now says how to check which version is installed, and where the settings file that uninstalling
  leaves behind is kept.

### Fixed

- Episode audio links from Search results and episode look-ups are trusted for 6 hours from when ABC answered, not
  from when they were shown, and an older cached answer no longer overwrites newer audio details.
- **Fewer repeated warnings in the server log**: a followed program that ABC has removed gives one WARN a day,
  instead of warnings at every Latest episodes refresh (every 15 minutes while the list is in use), and an
  unreadable song answer from ABC is logged as an error at most once an hour per station. The plugin also writes
  its cache less often: showing the same episodes again no longer rewrites their cached details.

### Known limitations

- With High quality (HLS) the audio runs about 30–40 seconds behind live, as on ABC's website, so Now Playing's
  song titles and programs change about 30–40 seconds before you hear the change.
- ABC lists only a program's newest 250 episodes, so a program's list ends there.
- Carried over from 1.0.0: most audiobooks and the restricted podcasts play only from an Australian internet
  connection; ABC mediahub may only work from Australia (with an automatic fallback); ABC's index still lists some
  programs that have stopped; a Latest episodes menu held open across its 15-minute refresh may open a different
  episode; Program info, Recently played and Sport event times use your LMS server's time zone; Material skin's
  own search box doesn't list ABC listen.

## [1.0.0] - 2026-10-24

### Added

- **Audiobook chapters**: every audiobook's menu has **Chapters (N)**, the book in reading order ("1. Prologue:
  February 1886", "2. PART ONE: 1887 - 1896", …), however you reach the book: Audiobooks, Kids listen → Books for
  Kids, Home, Search, Programs → By type → Audiobooks or My ABC listen. A chapter plays from its row; playing the
  Chapters list itself plays or queues the whole book in order.
- **Episodes for restricted podcasts**: ABC's website lists no episodes for Bluey Listen Along, Bluey Book Reads,
  Midsomer Murders Mayhem, Odd Squadcast and In Concert. They now have **Episodes (N)**, newest first, like any
  other podcast. A program with nothing to list says "No episodes available".
- **More in episode menus**: an episode now shows its presenters ("Presented by …"), **Segments (N)** for programs
  in parts such as The Science Show (each segment plays on its own, with its own title and duration),
  **Tracklist (N)** for music programs ("00:55 · Rossini, Gioachino – The Barber of Seville: Overture"; talk
  programs say "No tracklist"), and **More from** *program*, which opens the episode's program from anywhere,
  including Search results and Home.
- **Song info for episodes**: while an episode or a segment plays, Song Info (Material: More) has the episode notes,
  More from *program* and the tracklist, before the program's Follow row.
- **Hottest 100 episodes** now have "More from Hottest 100", in their menu and in song info, and song info has the
  Follow row: following there adds Hottest 100 to My ABC listen, the same as following it from Programs.
- **User guide**: the README now walks through every menu, with screenshots of the Default and Material web
  interfaces, and covers now playing, limitations, troubleshooting, compatibility and privacy.
- **Self-test**: `scripts/smoke.sh http://<your-lms>:9000 <player-mac>` checks the plugin on your own server in
  about a minute (15 checks: menus, live stations, an episode with a seek, search, follow). See the README's
  Self-test section; it plays audio on the player you choose.
- A guide to getting the plugin listed in the official LMS plugin repository (`docs/official-repository.md`).

### Changed

- **All programs A–Z is more complete**: 736 programs instead of 709. AM and The World Today are now listed, as are
  programs that share their title with another, such as *Persuasion* the audiobook (Audiobooks → All audiobooks
  A–Z now lists all 20 books) and the 14 programs called "Mornings".
- Programs use ABC's current titles, such as "Radio National Breakfast" (was "RN Breakfast") and "If You're
  Listening". A Big Country, Radio National Breakfast and If You're Listening are now under Programs → By type →
  Podcasts.
- **Search finds more programs**: programs such as AM and The World Today, and both programs when two share a title
  (for example *Persuasion* the audiobook and the podcast). Repeated titles are named "*title* (*network*)", as in
  All programs A–Z.
- **Program lists cope better when ABC is slow or blocks a request.** While ABC's pages don't answer, All programs
  A–Z, By type and All podcasts A–Z wait for ABC at most once every 10 minutes instead of every time they are
  opened, a blocked request no longer hides Hottest 100 for a day, and one bad program page no longer turns the
  whole list into an error.
- **Latest episodes stays put after an unfollow**: an unfollowed program's episodes stay in My ABC listen → Latest
  episodes, in the same places, for up to 30 minutes (as the program does in Followed programs), then leave.
  Following it again within that time changes nothing. A remote, app or script that repeats an Unfollow it reached
  through Latest episodes can no longer unfollow a different program.
- The plugin's description in Settings → Manage Plugins now lists everything it does.
- The note at the end of Audiobooks now reads "Most audiobooks play only in Australia.", since six of them play
  anywhere.

### Fixed

- **Installing from the repository URL works on LMS 9.1.1.** LMS 9.1.1 couldn't download the plugin from GitHub's
  release download link ("unable to download ABCListen … Header line too long" in the server log). `repo.xml` now
  points LMS at a copy of each release zip on raw.githubusercontent.com; v0.3.0 has been republished that way.
- Audiobook chapters stored on ABC's other Australia-only address (such as The Secret Keeper's) now say "This
  episode is only available in Australia" outside Australia, instead of a general playback error.
- Settings page: saving the page from a skin that sends only one of the two settings no longer warns "Invalid value"
  about the other one. Screen readers now read each setting's description with it.
- Older program links that ABC now redirects to a different page open again.
- An episode whose saved ABC link has moved still plays, from the audio link saved earlier.

### Known limitations

- Most audiobooks, the Bluey podcasts and the other restricted podcasts play only from an Australian internet
  connection; elsewhere they say "This episode is only available in Australia". Six classics play anywhere: The
  Wind in the Willows, The Wonderful Wizard of Oz, Persuasion, My Brilliant Career, Frankenstein and Animal Farm.
- ABC's index still lists some programs that have stopped. About 15 of them (several regional Mornings, Saturday
  Breakfast and some weekend afternoon shows) have no episode newer than 2019–2024, and their newest episodes may
  say they are no longer available. Comedy Showcase, Grass Roots and Desko, which ABC doesn't index at all, are
  only under Programs → By network.
- A Latest episodes list still refreshes every 15 minutes, and changes when an unfollow's 30 minutes run out or a
  new program is followed. A menu position held open across one of those moments may open a different episode.
- Carried over from 0.3.0: live streams are 56 kbps unless you choose ABC mediahub (which may only work from
  Australia, with an automatic fallback); stations ABC streams only as HLS aren't listed; Program info, Recently
  played and Sport event times use your LMS server's time zone; ABC lists only the newest 250 episodes of each
  program; Material skin's own search box doesn't list ABC listen.

## [0.3.0] - 2026-10-23

### Added

- **A top level like the ABC listen app**: Home, Radio, Podcasts, News, Sport, Kids listen, Audiobooks, then
  Programs, Search and My ABC listen.
- **Podcasts**: ABC's podcast collections (New & Noteworthy, Most Popular, Award Winning), **Browse by category**
  with all 18 categories, and **All podcasts A–Z** grouped by letter.
- **News, Sport, Kids listen and Audiobooks** sections with their live stations, programs and collections. Sport
  lists live and upcoming events with their times.
- **What's on air** for live stations: the program and presenters in the Radio menus, Now Playing and a
  **Program info** page (synopsis, time slot, what's next).
- **Now-playing songs** on triple j, Double J, Unearthed, ABC Jazz, ABC Country, ABC Classic, Classic 2, Hottest 100
  and ABC Kids listen: song title, artist and cover art in Now Playing, updated at every song change, and a
  **Recently played** list in the song info.
- **Station menus**: open a station for Listen live, what's on air, and the schedule for Today, Yesterday and the
  five days before, in the station's own time zone. Programs that have already aired open their catch-up episodes.
  The play button on a station still plays it live, and existing station favourites keep working.
- **My ABC listen**: follow programs from their menu; **Followed programs** lists them. Follows are stored in LMS
  only; no ABC account is needed.
- **Live stream quality** setting (Settings → Advanced → ABC listen): **Standard** (56 kbps, works everywhere) or
  **ABC mediahub** (ABC's own streams, which may only work from Australia; falls back to Standard automatically).

### Fixed

- Program and collection names no longer show image file names or text such as "… Tile".
- triple j's Hottest 100 is listed in Programs A–Z and By type → Music.
- Letters such as Æ and Ø are filed under A and O in the A–Z lists; titles in other scripts are under "Other".

### Known limitations

- Audiobooks don't list their chapters yet (coming next); a book's chapters can be found with ABC listen → Search.
  Most audiobooks play only from an Australian internet connection.
- **ABC mediahub** quality works only from Australia; elsewhere each play falls back to Standard automatically, after
  a short extra delay.
- Song titles appear only where ABC publishes them; between songs Now Playing shows the program. Some stations (e.g.
  Classic 2) publish no program information.
- Program info, Recently played and Sport event times use your LMS server's time zone; station schedules use the
  station's own local time.
- A program you unfollow stays listed in Followed programs for up to 30 minutes (it is no longer counted).
- Schedule entries for programs without an ABC program page can't be opened.
- Carried over: ABC lists only the newest 250 episodes of each program; some expired catch-up episodes are still
  listed; Material skin's own search box doesn't list ABC listen (use ABC listen → Search).

## [0.2.0] - 2026-10-19

### Added

- **Every ABC listen live station**: the national networks, music stations, local radio grouped
  by state (your home state first), sport and time-zone versions, each with its logo. Set your
  home state under Settings → Advanced → ABC listen; music and national stations then play your
  state's version where ABC has one.
- **Home**: ABC listen's Featured items and home-page collections.
- **Programs**: browse by network, **All programs A–Z** or **By type** (Podcasts, Catch-up radio,
  Music, News briefings, Audiobooks, Other). Program pages show the description and the episodes,
  newest first, with artwork, broadcast date and duration.
- **Episode playback** with seeking (MP3 and AAC catch-up), Now Playing title, program and artwork,
  and favourites. Expired, not-yet-available and Australia-only episodes show a clear message.
- **Search** for programs and episodes, also available in LMS's global search.

### Fixed

- Episodes whose ABC page address contains accented characters (e.g. "El Niño") now play.
- Older program links that ABC redirects (e.g. Future Tense, Big Ideas) now open.

### Known limitations

- ABC lists only the newest 250 episodes of each program, so older episodes can't be reached.
- Australia-only content (some podcasts and all audiobooks) plays only from an Australian
  internet connection.
- Live stations use ABC's 56 kbps HE-AAC streams; a higher-quality option is planned.
- Some expired catch-up episodes are still listed; they show "no longer available" when played.
- Material skin's own search box doesn't list ABC listen; use ABC listen → Search instead.
- Coming next: the top-level Podcasts menu, News, Sport, Kids listen and Audiobooks sections,
  followed programs (My ABC listen) and the program on air for live stations.

## [0.1.0] - 2026-10-19

### Added

- **ABC listen** in the LMS Radio menu, with a **Radio** menu of five national ABC stations:
  triple j, Double J, Radio National, ABC Classic and ABC Jazz, played from ABC's live HE-AAC
  streams.
- Stable `abclisten://` station links, so favourites keep working if ABC changes its stream
  addresses. Now Playing shows the station name and artwork.
- A settings page (Settings → Advanced → ABC listen, or Manage Plugins → ABC listen → Settings)
  with a **Home state** setting, used by later releases to list your local ABC stations first.
- Installation from a repository URL in Settings → Manage Plugins
  (`https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`), with
  automated releases.

### Known limitations

- Only the five live stations so far: local and digital stations, programs, episodes, podcasts,
  discovery and search are not in this release yet.
- The stations show no program or now-playing information yet.
- Tested on LMS 9.1.1 with squeezelite. LMS 8.3 and later are expected to work but haven't been
  tested. Players (or the server, when it transcodes) need to be able to decode AAC.

[unreleased]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.3.0...v1.0.0
[0.3.0]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wilsonwaters/SqueezeABCListen/releases/tag/v0.1.0
