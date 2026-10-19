# Changelog

All notable changes to the ABC listen plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each version's section is
also the text of its GitHub Release (see [RELEASING.md](RELEASING.md)).

## [Unreleased]

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

[unreleased]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wilsonwaters/SqueezeABCListen/releases/tag/v0.1.0
