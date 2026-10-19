# SqueezeABCListen

An unofficial [Lyrion Music Server](https://lyrion.org/) (LMS, formerly Logitech Media Server /
Squeezebox Server) plugin for **ABC listen**, the radio of the Australian Broadcasting
Corporation. It adds **ABC listen** to the LMS Radio menu so you can play ABC radio on your
Squeezebox players.

> **Status: early preview.** Version 0.1.0 plays five national ABC live stations: triple j,
> Double J, Radio National, ABC Classic and ABC Jazz. More live stations, programs and episodes,
> discovery and search are in development. See [CHANGELOG.md](CHANGELOG.md) for what each
> version contains.

## Disclaimer

This is an **unofficial** plugin. It is **not affiliated with or endorsed by the Australian
Broadcasting Corporation (ABC)**. The ABC, ABC listen and station names and logos belong to the
ABC; they are used here only to identify the stations. For the ABC's own apps and website, visit
<https://www.abc.net.au/listen>.

## Requirements

- Lyrion Music Server (or Logitech Media Server) **8.3 or later**. Tested on LMS 9.1.1 only.
- Internet access from the LMS server to the ABC's servers.
- AAC decoding: the live streams are HE-AAC. Software players such as squeezelite and most
  apps play them directly; older hardware players need the server to transcode AAC (LMS's
  `faad` helper).

## Installation

1. In the LMS web interface, open **Settings → Manage Plugins** and scroll down to
   **Additional Repositories**.
2. Paste this URL into the empty field and click **Apply**:

   ```
   https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml
   ```

3. A new section, **SqueezeABCListen plugin repository**, appears in the plugin list. Tick
   **ABC listen** and click **Apply**.
4. LMS asks you to confirm installing a plugin from a third-party repository ("You are about to
   install: … Only install extensions from authors whom you trust. …"). Click **OK**.
5. LMS downloads the plugin, checks it, and asks to restart. Click **Restart now**, or restart
   LMS the way you normally do.
6. Open **Radio → ABC listen** on any player or in the web interface.

## Updating

When a new version is released, **Settings → Manage Plugins** shows an update notice for
ABC listen: tick it, click **Apply**, and restart LMS. If you have turned on automatic plugin
updates on that page, LMS installs new versions by itself and only needs a restart. LMS caches
repository files for about 5 minutes (and GitHub may serve the old file for a few minutes too),
so a new version can take a little while to show up. The changes in each version are listed in
[CHANGELOG.md](CHANGELOG.md).

## Uninstalling

1. In **Settings → Manage Plugins**, untick **ABC listen** and click **Apply**.
2. Restart LMS when prompted.
3. Optionally, delete the repository URL from **Additional Repositories** and click **Apply**
   again.

## Development

- `scripts/check.sh` runs every check: compile check, unit tests (`prove`), XML validation,
  strings lint, package checks and shellcheck. CI runs the same script on every pull request.
- `scripts/build.sh` builds `dist/ABCListen-<version>.zip` and its `.sha1` from `ABCListen/`.
- `scripts/lms-repo-install.sh` installs the plugin on an LMS from a repository URL without a
  browser (used for testing).
- Releases are automated: see [RELEASING.md](RELEASING.md). Update [CHANGELOG.md](CHANGELOG.md)
  first.
- Project planning and status live in [`ai-state/`](ai-state/PROGRESS.md).

## License

[Apache License 2.0](LICENSE).
