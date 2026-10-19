# Changelog

All notable changes to the ABC listen plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each version's section is
also the text of its GitHub Release (see [RELEASING.md](RELEASING.md)).

## [Unreleased]

## [0.1.0] - 2026-10-19

### Added

- **ABC listen** in the LMS Radio menu, with a **Radio** menu of five national ABC stations:
  triple j, Double J, Radio National, ABC Classic and ABC Jazz, played from ABC's live HE-AAC
  streams.
- Installation from a repository URL in Settings → Manage Plugins
  (`https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`), with
  automated releases.

### Known limitations

- Only the five live stations so far: local and digital stations, programs, episodes, podcasts,
  discovery and search are not in this release yet.
- The stations show no program or now-playing information yet.
- Tested on LMS 9.1.1 with squeezelite. LMS 8.3 and later are expected to work but haven't been
  tested. Players (or the server, when it transcodes) need to be able to decode AAC.

[unreleased]: https://github.com/wilsonwaters/SqueezeABCListen/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wilsonwaters/SqueezeABCListen/releases/tag/v0.1.0
