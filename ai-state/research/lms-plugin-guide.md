# LMS plugin guide for SqueezeABCListen (architecture, conventions, reuse plan)

_Research date: 2026-10-19. Sources:_
- **REF**: the reference plugin `wilsonwaters/SqueezeRTRFM` v1.0.0, read in full from a local clone.
  Paths below are relative to that repo, e.g. `RTRFM/Live.pm:131-146`.
- **LMS**: `LMS-Community/slimserver` branch `public/9.1` (`$VERSION = '9.1.2'`, HEAD 582a1b2,
  2026-10-11), sparse clone of `Slim/`, `DEVELOPERS.txt`, `types.conf`, `convert.conf` and `Changelog*.html`.
  9.1.1 is still the newest release in `lms-server-repository/latest.xml`.
- **DOC**: <https://lyrion.org/reference/repository-dev/>, <https://lyrion.org/reference/music-service-plugin/>,
  <https://lyrion.org/plugins/>.
- **REPO**: `LMS-Community/lms-plugin-repository` (`README.md`, `include.json`, `buildrepo.pl`,
  `.github/workflows/update-extensions-repository.yml`, `extensions.xml`), fetched 2026-10-19.
- **PROBE**: my own curl checks of ABC endpoints from this container (§5.1).

The reference repo's own research, `ai-state/research/lms-plugin-architecture.md` (587 lines, LMS 9.1
source quotes), is still accurate. This guide doesn't repeat it, but cites it as **ARCH §n**. Read it
for the OPML item vocabulary (ARCH §3), metadata (§5), on-demand playback and seeking (§6), the
repository XML schema (§7) and testing (§8).

---

## 1. Summary

- **Identity.** Plugin name `ABCListen` everywhere: directory `ABCListen/`, packages
  `Plugins::ABCListen::*`, repo.xml `name="ABCListen"`, pref `plugin.state:ABCListen`. Lower-case
  `abclisten` for the OPML `tag` (CLI command `abclisten items …`), the log category and prefs
  namespace (`plugin.abclisten`), the cache namespace and the URL scheme (`abclisten://`). String
  tokens are `PLUGIN_ABCLISTEN_*`. No plugin called ABC* is in the official `extensions.xml`
  (checked 2026-10-19), so the name is free.
- **Shape.** Copy the reference's shape:
  - an `Slim::Plugin::OPMLBased` top level, `menu => 'radios'`;
  - a frozen "hook" API in `Plugin.pm`, so the feature streams never edit the same file;
  - one HTTP helper with a one-callback contract;
  - pure parsers driven by recorded fixtures;
  - a thin protocol handler for playback;
  - a RemoteMetadata/polling engine for live now-playing.
- **Minimum LMS: `minVersion 8.3`, `maxVersion *`.** The reference declares 8.0. Raise it only because
  LMS's remote MP4/M4A streaming fixes landed in 8.1.2–8.3.1 (§5.2), and ABC on-demand audio may be
  M4A. If ABC's audio turns out to be MP3/ADTS only, 8.0 is fine. Test on 9.1.1, the testbed version.
- **Playback.**
  - **Live:** LMS core **cannot play HLS** (`.m3u8`). ABC's own live API lists, for every outlet, an
    **HLS** stream (`streaming.abc-cdn.net.au/audio/hls/<id>.m3u8`, AAC-LC in MPEG-TS segments) **and**
    an Icecast **AAC** stream (`live-radio0N.mediahubaustralia.com/<CODE>/aac/`). LMS plays the second
    natively. Use AAC/MP3 Icecast for live.
  - **Episodes:** plain HTTPS MP3/M4A play and seek natively.
  - **Wrapping:** wrap both in a thin `abclisten://` protocol handler (resolve at play time, stable
    favourites, one `getMetadataFor`).
  - **HLS:** only a stretch goal, as our own segment handler.
- **Testbed caveat.** From this container, `*.mediahubaustralia.com` answers **Cloudflare 403
  "Sorry, you have been blocked"** for every User-Agent, over both https and http. The Akamai HLS
  hosts and the ABC JSON APIs answer 200. So live-Icecast playback **can't be verified in the
  container**; it needs pi14 (in Australia) or an HLS path.
- **Reuse.**
  - **Port as-is:** almost all of `t/lib` (stubs, harness), `HTTP.pm`, the scripts, both workflows
    and `dev/`, renaming `RTRFM` to `ABCListen` mechanically. The dev-env agent has already ported
    `dev/`.
  - **Adapt:** `Plugin.pm`, `Util.pm`, `ProtocolHandler.pm` and `LiveMetadata.pm`/`NowPlaying.pm` as
    patterns.
  - **Skip:** `Airnet.pm`, `Shows.pm`, `EpisodeWindow.pm`, `Tracklist.pm`, `t/2x`, `t/3x` and
    `t/data`, which are RTRFM data sources and their tests.

---

## 2. Standard Lyrion plugin process

### 2.1 Plugin structure
DOC (music-service-plugin) describes `Plugin.pm` ("the entry point"), `API.pm`, `API/Async.pm`
(`SimpleAsyncHTTP`), `OPML.pm`/`Browse.pm`, `ProtocolHandler.pm`, `Settings.pm`, `Importer.pm`
(library import, not needed), `HTML/EN/plugins/<Name>/` (`html/` is static, `settings/` holds
templates), `lib/`, `Bin/`, `install.xml` ("the plugin's manifest file") and `strings.txt`. DOC's key
rules are:
- "All API calls done within this module must use _async_ HTTP requests to not block the server",
  because "LMS is single threaded".
- "Don't hard code textual content. Always use localizable string tokens."
- "Respect rate limitations", and "Don't cache too aggressively".
- "Start small, release often."

Name rule (DOC repository-dev, and LMS `Slim/Utils/PluginManager.pm`): the plugin `name` must match
the package, so `Plugins::ABCListen::Plugin` means name `ABCListen` and install folder `ABCListen/`.
See ARCH §1 for the folders LMS scans and the zip extraction rules.

### 2.2 install.xml
Follow REF `RTRFM/install.xml`. Every field is explained in ARCH §2.
- `<module>` and `targetApplication/minVersion`+`maxVersion` are **required**. Without them the
  install fails with `INSTALLERROR_NO_MODULE` / `INSTALLERROR_INVALID_VERSION`.
- `name`/`description` are string tokens.
- `<icon>` is relative to `HTML/EN`: `plugins/ABCListen/html/images/icon.png`.
- `category radio`, `defaultState enabled`.
- `<id>`: generate a **new** GUID (`uuidgen`). Don't reuse RTRFM's `FF07025D-…`; it is the Jive
  menu uuid.
- Add `<optionsURL>plugins/ABCListen/settings/basic.html</optionsURL>` if we ship a settings page.
  The key is `optionsURL`; there is no `settingsPage` key.
- `<version>` is `X.Y.Z` (REF convention: `scripts/build.sh` and `release.yml` reject anything
  else).

### 2.3 Repository XML (repo.xml)
DOC repository-dev, confirmed against REF `repo.xml` and ARCH §7.1:
- `<extensions><details><title lang="EN">…</title></details><plugins><plugin name version minTarget maxTarget>`
  with `title`, `desc`, `category`, `icon`, `url`, `sha`, `link` and `creator`.
- `url` "should be a zip file". `sha` is the "sha1 digest of the zip file which is verifed before the
  zip is extracted".
- "include the version number in the archive's filename, as LMS otherwise might be re-using cached
  data".
- Categories: `hardware, information, misc, musicservices, playlists, radio, scanning, skin, tools`.
  Unknown categories become `misc`.
- **Both** `minTarget` and `maxTarget` must be present, or LMS skips version filtering (ARCH §7.1).
- `icon` must be an **absolute** URL (raw.githubusercontent.com).

### 2.4 Getting into the official list
- REPO README: "`include.json` contains a list URLs to plugin repositories … If a plugin author wants
  his plugins to be included in the default list of extensions in LMS, just add the URL to his
  repository XML file to this list". In practice this is a **pull request** to
  `LMS-Community/lms-plugin-repository` adding our raw `repo.xml` URL to `include.json`
  `"repositories"`. Today the list has 75 entries.
- The `update-extensions-repository.yml` workflow runs `buildrepo.pl` on cron `06 */6 * * *` with
  `MAX_REMOVAL_DIFF: 3`, and only pushes when the diff is below that. `buildrepo.pl`:
  - `die`s on bad XML (`die "bad xml ($url)"`), which blocks **every** plugin;
  - deletes our `installations` and fills in the real count from stats;
  - forces unknown categories to `misc`;
  - merges with `KeyAttr => ['name']`, so names must be globally unique.
- DOC /plugins/: hosting the plugin *repository itself* under the LMS-Community org is a separate
  thing ("please reach out on the forums"). Announcing in the forums.lyrion.org "3rd party software"
  forum is customary but not required.
- REF `docs/official-repository.md` is a correct, complete checklist for this. Port it with the
  names changed.

---

## 3. Recommended module layout for ABCListen

Final file names depend on the ABC API research (`ai-state/research/abc-listen-api.md`). The split
below follows REF's "data module (no menu code) / menu builder / playback" separation.

```
ABCListen/                              # zip the CONTENTS (install.xml at zip root)
├── install.xml                         # module Plugins::ABCListen::Plugin, min 8.3, max *, category radio, new GUID, optionsURL
├── strings.txt                         # PLUGIN_ABCLISTEN_* (EN), "# === <task> ===" sections like REF
├── Plugin.pm                           # OPMLBased (tag abclisten, menu radios, weight 10); frozen hook API; Settings init under main::WEBUI
├── HTTP.pm                             # REF HTTP.pm as-is: explicit UA, JSON decode, quiet opt, exactly-one-callback
├── Util.pm                             # constants (API bases, icon), ISO-8601 parsing WITH offsets/DST, decodeEntities,
│                                       #   URL contract abclisten://live/<serviceId> | abclisten://episode/<arid>, metadata-cache contract
├── API/ (or ABC.pm + small modules)    # data layer, no menu code, JSON -> plain hashes, Slim::Utils::Cache:
│   ├── Stations.pm                     #   live services/outlets + their audio_streams (pick AAC/MP3, never HLS for core playback)
│   ├── Programs.pm                     #   programs (by network / category / A-Z) and episodes (artwork, synopsis, date, duration, audio URL)
│   ├── Discover.pm                     #   featured collections, categories
│   └── Search.pm                       #   search
├── Live.pm                             # hook: "Live stations" menus (national, music, local radio by state), on-air line2
├── NowPlaying.pm                       # REF NowPlaying.pm pattern: fetch/parse/cache program-on-air (program.abcradio.net.au …/live.json)
│                                       #   and current song (music.abcradio.net.au …/plays) per service, coalesced, negative cache
├── LiveMetadata.pm                     # REF LiveMetadata.pm pattern: per-player poll timer, push (wmaMeta/currentPlaylistUpdateTime/newmetadata),
│                                       #   "Show info" song-info entry. If the PH owns live URLs, its getMetadataFor calls into this
├── OnDemand.pm                         # hook: Programs -> program -> episodes; episode row = link + play; episode submenu
├── DiscoverMenu.pm                     # hook: collections/categories + type=>'search' item
├── ProtocolHandler.pm                  # thin abclisten:// handler (REF ProtocolHandler.pm pattern) for live + episodes
├── Settings.pm                         # optional: Slim::Web::Settings (menu placement, preferred live format, ABC login)
├── Account.pm                          # optional/stretch: ABC login token handling (see §6), only if OPEN-QUESTIONS #1 says yes
└── HTML/EN/plugins/ABCListen/
    ├── html/images/icon.png            # 512x512 PNG (REF t/14-plugin-files.t asserts the size)
    └── settings/basic.html             # only with Settings.pm
```

**Hook API (frozen after the foundation task).** Generalise REF `RTRFM/Plugin.pm:42-48` and `:72-148`
from two hooks to an ordered list such as `qw(Live OnDemand DiscoverMenu)`:
- `Class->init()` is called once, inside `eval`.
- `Class->menuItems($client, $cb, $args)` must call back exactly once.
- A hook that dies, calls back badly or misses `HOOK_TIMEOUT` (25 s, below XMLBrowser's 35 s)
  becomes one error text item instead of hanging the menu.

**Identifiers to fix up front:**

| What | Value |
|---|---|
| OPML tag | `abclisten` |
| Log category | `plugin.abclisten` (default `WARN`, REF `Plugin.pm:35-39`) |
| Prefs | `preferences('plugin.abclisten')` |
| Cache | `Slim::Utils::Cache->new('abclisten')` (REF `Util.pm:40,294`) |
| URL scheme | `abclisten` |
| Icon constant | `plugins/ABCListen/html/images/icon.png` |

---

## 4. OPML / menu patterns (from REF, with cites)

**Registration** (`RTRFM/Plugin.pm:56-67`):
```perl
$class->SUPER::initPlugin( feed => \&toplevel, tag => 'rtrfm', menu => 'radios', is_app => 0, weight => 10 );
sub getDisplayName { 'PLUGIN_RTRFM' }
sub playerMenu { 'RADIO' }
```

**Playable live item** (`RTRFM/Live.pm:131-146`). `favorites_url`/`favorites_icon` keep favourites
stable:
```perl
{ name => $name, line1 => $name, favorites_title => $name, type => 'audio', on_select => 'play',
  url => $url, favorites_url => $url, image => ICON, favorites_icon => ICON, %extra }   # %extra: line2, description
```

**Browsable program** (`RTRFM/OnDemand.pm:156-171`): a coderef `url`, data passed in `passthrough`,
and `line2` for Material/Jive only:
```perl
{ name => $p->{name}, line1 => $p->{name}, type => 'link', url => \&_programMenu, passthrough => [$p],
  image => $p->{image} || ICON, line2 => $p->{schedule} }
```

**Episode row that both opens and plays** (`RTRFM/OnDemand.pm:336-365`; ARCH §3.3, gotcha 9). A
`link` with `play` set to the stable `abclisten://` URL. No `on_select`, so touch skins open it
instead of playing:
```perl
{ name => "$date – $title", line1 => $title, line2 => "$date · $time", type => 'link',
  url => \&_episodeMenu, passthrough => [$program, $episode], play => $url, image => …, duration => $secs }
```
The submenu (`OnDemand.pm:426-461`) holds:
1. a "Play episode" `type => 'audio'` item with `on_select => 'play'` and a `favorites_title`;
2. the description as `{ type => 'textarea', wrap => 1 }`;
3. a nested `link` with inline `items` (e.g. the tracklist).

**Always answer exactly once** (`OnDemand.pm:464-481`). `_respond` wraps the builder in `eval`, and
`_textFeed` turns errors into a single text item. Feed coderefs are called as
`($client, $cb, $args, @passthrough)` (LMS `Slim/Control/XMLBrowser.pm` ~l.525). `$client` may be
undef.

**Search.** Use `{ name => …, type => 'search', url => \&searchFeed }`. The coderef gets the query in
`$args->{search}` (LMS `XMLBrowser.pm:392-498`).

**What each skin shows:**
- **Material, Jive and the CLI with `menu:1`.**
  - Row text is `line1 . "\n" . line2` when `line2` is set (`XMLBrowser.pm:1125-1127`).
  - The icon is `proxiedImage($item->{image})` (`:1160-1167`, `:1386-1387`).
  - Favourites use `presetParams` from `_favoritesParams` (`:1132`, `:1925-1947`). The order is
    `favorites_url ‖ play ‖ url` (never a coderef), then `favorites_title ‖ title ‖ name`, then
    `favorites_icon ‖ image ‖ icon ‖ cover`. `favorites_type` is `audio` when `play` is set.
- **Default web skin.** Lists show `name` and a thumbnail **only**: no `line2`, so put dates in
  `name`, as REF does. `description` and `textarea` show on the item's detail page (REF README
  "Live streams" note).
- **Material icons.** An icon named `*_svg.png` makes Material load the sibling `.svg` (ARCH §1).
  A plain `icon.png` is safest.
- **Artwork.** External `https://` images are served through `/imageproxy/<url>/image.<ext>` and
  resized there (`Slim/Web/ImageProxy.pm:443-461`). ABC artwork URLs are large CDN images. To fetch a
  smaller rendition, optionally register
  `Slim::Web::ImageProxy->registerHandler(match => qr/…abc-cdn…/, func => sub { my ($url, $spec) = @_; … })`,
  as core TuneIn does (`Slim/Plugin/InternetRadio/TuneIn/Metadata.pm:49-62`).

---

## 5. Playback and protocol handler notes

### 5.1 What ABC serves (PROBE, 2026-10-19; full detail is the ABC API research's job)
- `https://program.abcradio.net.au/api/v1/programitems/triplej/live.json` (200, JSON) has
  `now.live[].outlets[].audio_streams[] = {type, url}`. For triple j:
  - `{type:"HLS", url:"https://streaming.abc-cdn.net.au/audio/hls/triplejnsw.m3u8"}`
  - `{type:"AAC", url:"https://live-radio01.mediahubaustralia.com/2TJW/aac/"}`
  - Some outlets also list legacy `HDS` (`*.akamaihd.net/…/manifest.f4m`), and `AAC` as
    `http://live-radio01.mediahubaustralia.com/5TJW/aac/;*.mp3`. The `;*.mp3` suffix is an old
    player hack, so normalise it.
- The HLS master lists two AAC variants (`mp4a.40.2` at 252 kbps and HE-AAC `mp4a.40.29` at 140 kbps).
  The media playlists hold **10 s MPEG-TS `.ts` segments** with `#EXT-X-PROGRAM-DATE-TIME`.
  `mediaserviceslive.akamaized.net/hls/live/…/index.m3u8` 302-redirects to `streaming.abc-cdn.net.au`.
- `https://music.abcradio.net.au/api/v1/plays/search.json?station=triplej&limit=1` (200) gives the
  current/recent song (artist, title, links).
- `live-radio0{1,2}.mediahubaustralia.com` answers **403 (Cloudflare block page)** to this
  container's egress, for browser, LMS and iTunes UAs alike, and over http:80 and https:443. It's
  likely IP-reputation or geo blocking. Akamai HLS and the JSON APIs are reachable.

### 5.2 What LMS 9.1 (and 8.x) plays natively
| Source | Core LMS | Evidence / notes |
|---|---|---|
| Icecast/SHOUTcast **MP3** over http/https | yes | Standard `Slim::Player::Protocols::HTTP(S)`. REF verified SomaFM https MP3 on the testbed (REF `ai-state/RUNBOOK.md` "Verification record"). |
| Icecast **AAC/HE-AAC (ADTS)** | yes | `types.conf:37` `aac audio/aac,audio/aacp`. REF plays RTRFM HE-AAC 48 kHz. Players without AAC need `faad` transcoding (`convert.conf:109-111` `aac mp3`, `:331` `aac flc`, `:357` `aac aac` passthrough). The squeezelite testbed needs `-Z 192000` (REF RUNBOOK "Audio output"). |
| On-demand **MP3** over https | yes, seekable | Seek needs bitrate + duration (`Slim/Player/Protocols/HTTP.pm:1150-1166`). The remote scanner derives duration from `Content-Length`, so the CDN must send `Content-Length` and honour `Range` (ARCH §6.1). Still pass `duration` in the OPML item (`XMLBrowser.pm:693-700` → `setRemoteMetadata`). |
| On-demand **M4A/MP4 (AAC)** over https | yes, from 8.x | `Slim/Utils/Scanner/Remote.pm:85,800-930` `parseMp4Header`. It handles `moov` after `mdat` by re-requesting with `Range` (`:822-845`), and `.m4a` URLs served as audio/mpeg (`:341-346`). Fixes in the changelogs: #585/#593 (8.1.2), #749 STCO offsets (8.3.0), #834 m4a without transcoding (8.3.1), #1056 (8.5.2). **Hence minVersion 8.3.** |
| **HLS `.m3u8`** | **no** | No HLS code in core. `types.conf:36` knows `m3u8` only as an M3U *playlist* extension. Core TuneIn says "Apple HLS m3u8 is supported through the PlayHLS plugin and ffmpeg" (`Slim/Plugin/InternetRadio/TuneIn.pm:181`). PlayHLS (bpa, v1.01, 2,946 installs) is a separate third-party plugin; don't depend on it. **Never hand LMS an `.m3u8` as `type audio`.** |
| HDS `.f4m` | no | Ignore it. |

**HTTPS and hardware.** `HTTPS.pm:75-96` direct-streams only if `$client->canHTTPS`; otherwise LMS
proxies the stream, which is fine but costs CPU on a Pi. Prefer the `https://` Icecast URL, as REF
LQ1 did. **HTTP/1.0:** LMS sends `HTTP/1.0` request lines (`HTTP.pm:950`), which matters only for the
container egress (§8).

**Volatile redirects.** Akamai and abc-cdn URLs redirect. LMS replaces the playlist track with the
redirected URL after the scan, and handles a gone redirect target on resume by retrying `$track->redir`
(`DEVELOPERS.txt:24-73`). A thin handler that restores its own URL in the scan callback avoids most of
this (`DEVELOPERS.txt:75-104`).

### 5.3 Recommended handler design: one thin `abclisten://` protocol handler

| URL | Resolves at `scanUrl` to | Why a handler, not the plain URL |
|---|---|---|
| `abclisten://live/<serviceId>` | that service's AAC (or MP3) Icecast URL from the cached station list, falling back to a constant table | Favourites survive stream-URL changes; the stream can be chosen per player/pref at play time; one place for `getMetadataFor`; the hook point for a later HLS path |
| `abclisten://episode/<arid>` | the episode's audio URL (MP3/M4A) from the cached episode metadata, else one API lookup by ARID | Stable favourites with full metadata after restarts; no CDN URLs in playlists or favourites |

Model the handler on REF `RTRFM/ProtocolHandler.pm`, which follows core
`Slim::Plugin::Podcast::ProtocolHandler` and the `DEVELOPERS.txt:75-104` rules.

`scanUrl` (`:108-169`):
1. Parse the URL and resolve it asynchronously.
2. On failure, call back with `undef` plus a string token, e.g. `PLUGIN_ABCLISTEN_UNAVAILABLE`.
3. Wrap `$args->{cb}` (don't capture `$args` in it, to avoid a reference cycle; `:138-139`). The
   wrapped callback:
   - sets `$song->streamUrl($track->url)`;
   - sets the title from `getMetadataFor`;
   - calls `$track->cover(0)`, so embedded art never overrides ours;
   - restores `$track->url($ourUrl)`;
   - bumps `currentPlaylistUpdateTime`.
4. Call `SUPER::scanUrl($realUrl, $args)` (`:165`).

The rest of the handler:
- **`new`** (`:171-178`): `$args->{url} = $song->streamUrl unless $args->{redir}`. This avoids the
  proxied-streaming redirect loop.
- **`getMetadataFor($class, $client, $url, $forceCurrent)`** (`:180-209`). Synchronous, no network,
  never dies.
  - Returns `{title, artist, album, cover, icon, duration}` from the metadata cache, else a fallback
    derived from the URL.
  - For live, `title` = song (from plays) or program, `artist` = song artist or presenter/network,
    `album` = program · network, `cover` = program/station image.
  - **`cover` is what Now Playing shows** (status `artwork_url`, `Queries.pm` `_songData`; ARCH §5.3).
- **`getCurrentTitle`** (`:239-242`): returns the same title, so `current_title` isn't the menu
  label or the blank `icy-name`.
- **`onStream`/`onStop`** (`:246-287`): start and stop per-player timers.
- **Song info:** `Slim::Menu::TrackInfo->registerInfoProvider(…)` (`:443-489`), e.g. "Program info"
  or episode notes.
- **Never** call `$song->duration`, `$song->startOffset` or `setCurrentTitle($url, $t, $client)` for
  episodes (`:53-54`). They break seeking and progress, and the last one fires `newsong`.

**Live now-playing push.** Use the REF `LiveMetadata.pm` engine (`:28-48` design notes; push at
`:371-386`):
- one `Slim::Utils::Timers` poll per **master** player;
- stop polling when the player stops or the URL changes;
- one shared upstream fetch;
- the push sequence `setCurrentTitle($url,$title)` (no client) → `$song->pluginData(wmaMeta => …)` →
  `$master->currentPlaylistUpdateTime(...)` → `notifyFromArray($master, ['newmetadata'])`.

Poll at ABC's `next_updated` (live.json has `last_updated`/`next_updated`), clamped, plus the plays
endpoint for music stations. If live URLs are `abclisten://`, the PH's `getMetadataFor` is the
provider. Without a PH (plain Icecast URLs), register `Slim::Formats::RemoteMetadata->registerProvider/
registerParser(match => qr{^https?://live-radio0\d\.mediahubaustralia\.com/<CODE>/}, …)` as REF
`LiveMetadata.pm:89-90` does, and return `{}` for URLs we don't own. `Plugins::ABCListen` initialises
before `Plugins::RadioNowPlaying` (2,828 installs), and RNP defers to an existing provider (ARCH §5.3).

**ICY.** ABC Icecast may send its own `StreamTitle`. Decide from a real capture: either let it
through, or swallow it with a parser that returns 1, as REF does. A protocol handler that overrides
`getMetadataFor` makes ICY irrelevant for display.

**HLS stretch.** This would mean our own `sysread`-based handler: fetch the media playlist, then the
`.ts` segments, demux MPEG-TS (188-byte packets, audio PID, PES) to ADTS AAC, and present
`contentType aac`. Precedent: BBC Sounds does this for DASH/fMP4 in ~3,000 lines
(`BBCSounds/ProtocolHandler.pm`, `M4a.pm`). Do it only if Icecast turns out to be unusable for real
users (e.g. geo-blocked); the container block alone isn't a reason.

---

## 6. Settings and credentials storage

**Pattern.** `package Plugins::ABCListen::Settings; use base qw(Slim::Web::Settings);` with
`name` → string token, `page` → `plugins/ABCListen/settings/basic.html`, and
`prefs` → `(preferences('plugin.abclisten'), qw(…))`. Create it in `initPlugin` only
`if (main::WEBUI)`, never "WEB_UI" (ARCH §1 "Settings page", gotcha 15). The template is
`[% PROCESS settings/header.html %]` … `[% WRAPPER setting title="TOKEN" desc="TOKEN_DESC" %]<input name="pref_x">[% END %]`
… `[% PROCESS settings/footer.html %]`. Form fields **must** be named `pref_<name>`
(`Slim/Web/Settings.pm:154-174` logs an error otherwise). Override `handler` for anything special.
Use `$prefs->init({...})` for defaults and `setValidate`/`setChange` for validation
(`Slim/Utils/Prefs/Namespace.pm:93-150`).

**Where prefs live and who can read them.** Prefs are plain YAML in
`<prefsdir>/plugin/abclisten.prefs` (`Slim::Utils::Prefs::dir()`, `Prefs.pm:645`). They are
**readable by any CLI/JSON-RPC client**: `prefQuery` (`Slim/Control/Queries.pm:3011-3050`) serves
`["pref","plugin.abclisten:<name>","?"]` for any namespace without restriction. LMS has no auth by
default, so anything in prefs is effectively readable on the LAN.

**Recommendation** (only if OPEN-QUESTIONS #1 decides login is worth it):
1. **Never store the password.** The settings `handler` takes `pref_password`, exchanges it once for
   a session/refresh token through the ABC login API (ABC listen uses Gigya: `login.abc.net.au/js/gigya.js`
   appears in the listen HTML; the API agent to confirm the flow), then **deletes** it from the params
   before the base handler saves. Core AudioScrobbler is precedent for rewriting `pref_password`
   before save (`Slim/Plugin/AudioScrobbler/Settings.pm:69-76`), and its template uses
   `type="password" … value=""` (`…/AudioScrobbler/settings/basic.html:29`).
2. **Keep the token out of the prefs namespace.** Write it to a small JSON file next to the prefs,
   e.g. `catfile(Slim::Utils::Prefs::dir(), 'plugin', 'abclisten-token.json')`, `chmod 0600`, owned
   by the LMS user. That keeps it out of `pref` CLI responses and the settings page HTML. Store only
   a non-secret "logged in as <display name>" flag in prefs.
3. **Show status, not secrets.** The page shows "Signed in as X" with a "Sign out" button that
   deletes the file. Never echo the token or password back into the form.
4. **Never log credentials or tokens.** HTTP.pm logs URLs at DEBUG (`HTTP.pm:84`), so send tokens
   as headers, not query strings. Redact in our own logs.
5. Without login, every menu must work. Login-only items appear only when a token exists, through
   the hook API.

**Other prefs worth having** (all optional):
- menu placement, Radio vs My Apps (`is_app`; ARCH §3.1, gotcha 16);
- preferred live format, `aac` or `mp3`, for players without AAC;
- local-radio home state, to sort that state's stations first.

---

## 7. Testing approach (port REF's harness; it is already LMS-free)

**Unit tests** run with `prove -lr -It/lib t` and are offline only.
- `t/lib` holds stubs of every `Slim::` API the plugin uses: OPMLBased, Base, Log, Prefs, Strings,
  Cache, Timers, Misc, SimpleAsyncHTTP (routes URLs to fixtures, synchronous, records requests),
  RemoteMetadata, ProtocolHandlers, Protocols::HTTP(S), Playlist, Source, Scanner::Remote,
  Music::Info, Control::Request and Menu::TrackInfo.
- `JSON::XS::VersionOneAndTwo` is shimmed on top of core JSON::PP.
- `RTRFMTest.pm` provides the `main::DEBUGLOG/INFOLOG/WEBUI/SCANNER` constants, a fake clock that
  fires the `Timers` stub, `route()`/`fixture()` and a callback `collector()`.
- `RTRFMTest/FakeClient.pm` is a fake player with master/slave, mode, song and pluginData.
- The symlink `t/lib/Plugins/RTRFM -> ../../../RTRFM` maps packages to the repo directory.
- Stubs carry the real LMS signatures in their header comments.

**Conventions to keep** (REF `ai-state/streams.md` "Parallel-work rules"):
- Test-number prefixes per stream: `1x` foundation, `2x` live, `3x` on-demand; add `4x` discovery
  and `5x` account.
- Fixtures go in `t/data/<stream>/`. Record **real ABC responses** for them: copy from
  `ai-state/research/abc-samples/`, trimmed but unedited in shape, plus synthetic edge cases (missing
  fields, entity-encoded text, empty lists, HTTP errors, bad JSON).
- Stubs change additively only.
- Parsers stay pure (JSON → hashes) and are tested directly. Builders are tested on item shape (exact
  keys) and on "exactly one callback on every path".

**Quality gate.** `scripts/check.sh` is the single command for local runs and CI. It runs:
1. compile of every `.pm` against the stubs;
2. prove;
3. `xmllint` on install.xml and repo.xml;
4. the strings lint (format, and every `PLUGIN_ABCLISTEN*` token used is defined);
5. the package checks (zip layout, sha1, repo.xml targets equal install.xml);
6. shellcheck.

CI (`.github/workflows/ci.yml`) apt-installs `libxml2-utils liburi-perl libhtml-parser-perl zip unzip
shellcheck curl jq` and runs check.sh. **In this container**, `URI::Escape`, `HTML::Entities` and
`shellcheck` are **missing**. `t/12-http.t`/`HTTP.pm` need URI::Escape and shellcheck is skipped
locally, so agents must `apt-get install liburi-perl libhtml-parser-perl shellcheck` before running
check.sh.

**Acceptance smoke.** `scripts/smoke.sh <lms-url> <player-mac>` (bash, curl, jq) walks menus **by
name**; names are hard-coded and `t/18-smoke-strings.t` keeps them equal to strings.txt. Redefine
the checks for ABC:
1. server up;
2. player connected;
3. plugin enabled;
4. Radio lists ABC listen;
5. the top level has the expected items;
6. a live station plays (time advances);
7. Programs is non-empty;
8. an episode plays and seeks;
9. search returns results.

Check 6 can't pass in the container while mediahubaustralia blocks us (§5.1): make it skippable
with an explicit `SKIP` result. Keep `t/19-smoke-cli.t`, which tests smoke.sh against a fake JSON-RPC
server.

**Runtime verification.** Use the testbed (§8): link the plugin, restart, drive JSON-RPC
(`["abclisten","items",0,50,"item_id:…"]`, `["abclisten","playlist","play","item_id:…"]`,
`["status","-",1,"tags:aclKNdrux"]`), take headless screenshots of the Default skin, and check
`server.log`.

---

## 8. Dev testbed

**What it is** (REF `ai-state/RUNBOOK.md`, `dev/common.sh`):
- **LMS 9.1.1**: the full src tarball, md5 `11a05b8a79515fb4dfb303c5e0abc6e1`, bundled CPAN, system
  perl 5.38, in `/opt/lms-dev/server`. It runs in the foreground under `setsid` as root with
  `--user root`. Prefs, cache and pids live under `/opt/lms-dev`, logs in `<repo>/dev/logs/`.
- **DevPlayer**: squeezelite `00:00:00:00:00:01` with
  `-o - -a 16 -r 44100-44100 -u mX -Z 192000 | pv -L 176400`, i.e. real-time paced PCM discarded.
- **Egress:**
  - LMS and squeezelite run under **proxychains4**. Every TCP connect is sent to
    `dev/egress-proxy.mjs` on 127.0.0.1:3129.
  - The helper sniffs TLS SNI and tunnels to `<sni>:443` through `$HTTPS_PROXY`.
  - It re-issues plain HTTP/1.0 as HTTP/1.1 and de-chunks the response, because the container's
    Envoy gateway answers HTTP/1.0 with `426`.
  - `proxy_dns` is off. Keep `webproxy` empty and `insecureHTTPS` at 0.
- **Driving it:**
  - `dev/rpc.sh <dev|-|mac> '<json array>'` for JSON-RPC;
  - `dev/link-plugin.sh --restart` symlinks `<repo>/ABCListen` into `<LMS>/Plugins/ABCListen`;
  - `dev/restart-lms.sh` to reload Perl, since there is no hot reload;
  - `dev/logs.sh [server|stdout|squeezelite|egress]`;
  - `dev/testbed-lock.sh acquire|release <task>`, because only one agent may use the single LMS at a
    time;
  - `node dev/browser/screenshot.mjs <url> <png>`: playwright 1.56.1 pinned to the preinstalled
    `/opt/pw-browsers/chromium-1194`. Never run `playwright install`.
- **Logging gotcha:** `warn`/`info` during `initPlugin` is dropped unless LMS starts with
  `LMS_EXTRA_ARGS="--debug plugin.abclisten=DEBUG"`.

**State observed now.** `/opt/lms-dev` exists with LMS 9.1.1 running (pid files for lms, squeezelite
and the egress proxy), and a throwaway `Plugins/ABCProbe` symlink to the dev-env agent's scratchpad.
The dev-env agent has **already ported `dev/` into this repo**. Against REF, only these differ:
- `PLUGIN_NAME/PLUGIN_SRC` default to `ABCListen`;
- comments name `abclisten`;
- `link-plugin.sh` exits 0 with a hint when `ABCListen/` doesn't exist yet.

**Still to do for this project** (dev-env agent / orchestrator):
- `ai-state/RUNBOOK.md`: port REF's version, record the **mediahubaustralia 403** and what it means
  for verification, and add the `apt-get install liburi-perl libhtml-parser-perl shellcheck` step
  for check.sh.
- `dev/browser/package.json` `"name": "squeezertrfm-dev-browser"` → `squeezeabclisten-dev-browser`
  (cosmetic).
- Optional: install **MaterialSkin** in the testbed to verify the Material rendering REF never
  tested. It is in the official list (v6.4.14, `minTarget 7.9.0`):
  `scripts/lms-repo-install.sh http://127.0.0.1:9000 https://lms-community.github.io/lms-plugin-repository/extensions.xml`
  with `PLUGIN=MaterialSkin`, then restart. The UI is at `/material/`.
- Verification split: browsing, metadata, on-demand episodes and HLS reachability are tested in the
  container. **Live Icecast playback is verified by the stakeholder on pi14** (brief "Environment &
  verification", geo/IP restrictions).

---

## 9. Release and distribution

Port REF as-is with the names changed (REF `RELEASING.md` and `.github/workflows/release.yml`
explain every step).
- **Version.** `<version>` in `ABCListen/install.xml` is the single source. Feature PRs never touch
  it.
- **Triggers.** A push to `main` that touches `ABCListen/install.xml`, or a `workflow_dispatch`, runs
  `release.yml`. Tags can't be pushed from the container, so the workflow creates the tag and release
  server-side with `GITHUB_TOKEN` and `permissions: contents: write`.
- **Steps:** CI checks (`workflow_call` of ci.yml) → version/downgrade/tag guards →
  `scripts/build.sh` → `dist/ABCListen-X.Y.Z.zip` + `.sha1` (zip of the directory *contents*,
  `zip -X`, symlinks dereferenced) → `gh release create vX.Y.Z` with notes from
  `scripts/changelog-section.sh` (Keep a Changelog `CHANGELOG.md`) → download the asset and compare
  its sha1 → `scripts/update-repo-xml.pl --version --sha --url` → `xmllint` → commit **only**
  `repo.xml` to `main` with `[skip ci]`, retrying up to 3 times on non-fast-forward.
- **Safety.**
  - Re-runs are idempotent and include a repair path.
  - Pull requests touching release files get a dry run.
  - Never reuse a version, replace an asset or hand-edit `sha`.
  - The committed `repo.xml` starts with a 40-zero placeholder `sha`. The workflow refuses to run if
    `repo.xml` on `main` has no `name="ABCListen"` entry, so commit the entry in the foundation task.
- **User install URL:** `https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`
  (Settings → Manage Plugins → Additional Repositories → tick → Apply → confirm the third-party
  prompt → restart). LMS caches repository files for ~5 min, and raw.githubusercontent.com caches for
  a few minutes too.
- **Headless install test:** `scripts/lms-repo-install.sh` posts the Manage Plugins form; no
  JSON-RPC command installs plugins.
- **Official listing:** a PR to `include.json` (§2.4), after stakeholder acceptance. Port
  `docs/official-repository.md`.
- **Repo settings prerequisites:** Settings → Actions → General → Workflow permissions → Read and
  write, and `main` must let GitHub Actions push (REF RELEASING "Prerequisites").

---

## 10. Reuse inventory

The rename is mechanical: `RTRFM`→`ABCListen`, `rtrfm`→`abclisten`, `PLUGIN_RTRFM`→`PLUGIN_ABCLISTEN`,
`RTRFMTest`→`ABCListenTest`, `RTRFM_TEST_LOG`→`ABCLISTEN_TEST_LOG`, and
`wilsonwaters/SqueezeRTRFM`→`wilsonwaters/SqueezeABCListen`.

| Reference path | Our path | Action | Notes |
|---|---|---|---|
| `RTRFM/install.xml` | `ABCListen/install.xml` | adapt | New GUID, tokens, min 8.3, homepageURL, `optionsURL` if settings; version `0.1.0` |
| `RTRFM/strings.txt` | `ABCListen/strings.txt` | adapt | Keep the format, header comment and `# === <task> ===` sections; new tokens |
| `RTRFM/Plugin.pm` | `ABCListen/Plugin.pm` | adapt | Keep the hook engine (`:42-157`) verbatim; change the hook list, tag, names; add Settings init |
| `RTRFM/HTTP.pm` | `ABCListen/HTTP.pm` | port as-is | Rename only. Maybe append an extra-headers option (e.g. auth) |
| `RTRFM/Util.pm` | `ABCListen/Util.pm` | adapt | Keep `parseISO8601`, `decodeEntities`, the URL-contract and metadata-cache *pattern*. **Drop** the Perth fixed UTC+8 helpers: ABC times span AEST/AEDT/ACST/AWST with DST, so parse offsets and display in server local time |
| `RTRFM/Live.pm` | `ABCListen/Live.pm` | adapt (pattern) | Menu deadline + cached/last-good fallback (`:35-80`) and `_item` (`:131-146`) |
| `RTRFM/NowPlaying.pm` | `ABCListen/NowPlaying.pm` | adapt (pattern) | Coalesced fetch, TTL from next change, negative cache, `lastGood`; the data source changes |
| `RTRFM/LiveMetadata.pm` | `ABCListen/LiveMetadata.pm` | adapt | Reuse the poll/push/stop engine and `_titleChanged`; one poll per (master, service) |
| `RTRFM/OnDemand.pm` | `ABCListen/OnDemand.pm` | adapt (pattern) | Builders, `_respond`/`_textFeed`, link+play episode rows, submenu; drop the Airnet/WP merge |
| `RTRFM/ProtocolHandler.pm` | `ABCListen/ProtocolHandler.pm` | adapt | Keep `scanUrl`/`new`/`getMetadataFor`/`getCurrentTitle`/`onStop`/trackInfo; add the live branch; drop the boundary-timer code unless ABC gives timestamped episode tracklists |
| `RTRFM/Restream.pm` | `ABCListen/API/…` resolver | adapt or skip | A one-callback `{url}|{unavailable}|{error}` resolver is a good contract for ARID→audio URL |
| `RTRFM/Tracklist.pm` | — | skip (borrow) | Airnet-specific. `trackAt`/`formatOffset` are reusable pure functions if ABC has cue points |
| `RTRFM/Airnet.pm`, `Shows.pm`, `EpisodeWindow.pm` | — | skip | RTRFM data sources and the 28-day window |
| `RTRFM/HTML/EN/plugins/RTRFM/html/images/icon.png` | `ABCListen/HTML/EN/plugins/ABCListen/html/images/icon.png` | replace | New 512×512 PNG |
| `t/lib/Slim/**` (16 stubs) | `t/lib/Slim/**` | port as-is | `Strings.pm:75-77` loads `RTRFM/strings.txt`, so change it to `ABCListen`; `Log.pm` env var; comments |
| `t/lib/JSON/XS/VersionOneAndTwo.pm` | same | port as-is | — |
| `t/lib/RTRFMTest.pm`, `t/lib/RTRFMTest/FakeClient.pm` | `t/lib/ABCListenTest.pm`, `t/lib/ABCListenTest/FakeClient.pm` | port as-is | Rename |
| `t/lib/Plugins/RTRFM` (symlink) | `t/lib/Plugins/ABCListen -> ../../../ABCListen` | recreate | Symlink, not a file |
| `t/10-compile.t`, `t/12-http.t` | same | port + rename | Change 10's list of expected modules |
| `t/11-util.t`, `t/13-plugin-feed.t` | same | adapt | 13: hook list and strings |
| `t/14-plugin-files.t`, `t/14-repo-xml.t`, `t/15-update-repo-xml.t`, `t/15-release-workflow.t`, `t/16-package.t`, `t/17-changelog-section.t`, `t/18-smoke-strings.t`, `t/19-smoke-cli.t` | same | adapt (mechanical) | 14-plugin-files pins minVersion `8.0` and the icon path; 17-changelog expects a `1.0.0` section; fix both when porting |
| `t/17-docs.t` | same | adapt later | Asserts README/RELEASING content. Port when docs exist (final task) |
| `t/20-23`, `t/30-39` | — | skip (templates) | RTRFM feature tests; use as style models (exact item keys, one-callback, fake clock) |
| `t/data/**` | `t/data/{foundation,live,ondemand,discover}/` | skip | Record ABC fixtures |
| `scripts/check.sh` | same | adapt | Paths and module dir |
| `scripts/build.sh`, `check-package.sh` | same | adapt | Name, src dir, forbidden prefixes |
| `scripts/update-repo-xml.pl` | same | adapt | `$PLUGIN` and default URL |
| `scripts/lint-strings.pl` | same | adapt | Path, token prefix |
| `scripts/changelog-section.sh` | same | port as-is | — |
| `scripts/lms-repo-install.sh` | same | adapt | `PLUGIN` default and docs URL; generic otherwise |
| `scripts/smoke.sh` | same | adapt heavily | New checks and menu names; skippable live check |
| `.github/workflows/ci.yml` | same | port as-is | — |
| `.github/workflows/release.yml` | same | adapt | Rename. Decide the commit identity (`COMMIT_NAME/EMAIL`, `:268-270`); see §11 item 14 |
| `repo.xml` | same | adapt | New entry, placeholder sha, version `0.0.0` or the first release; absolute icon URL |
| `dev/*.sh`, `dev/egress-proxy.mjs`, `dev/browser/*` | `dev/` | **done** (dev-env agent) | Name changes only; rename `package.json` (cosmetic) |
| `README.md`, `RELEASING.md`, `CHANGELOG.md` | same | adapt | Good templates (install, troubleshooting, self-test, compatibility, disclaimer) |
| `docs/official-repository.md` | same | adapt | Rename; re-run the name-uniqueness check |
| `docs/images/*` | `docs/images/*` | skip | New screenshots |
| `LICENSE`, `.gitignore` | — | already present | Our `.gitignore` is identical to REF's |
| `ai-state/RUNBOOK.md` | `ai-state/RUNBOOK.md` | adapt (dev-env agent) | Add the ABC egress findings |
| `ai-state/research/lms-plugin-architecture.md` | — | reference only | Cite it; don't copy |
| `ai-state/{brief,streams,PROGRESS,OPEN-QUESTIONS,HANDOFF}.md`, `ai-state/streams/*/master-plan.md` | own versions | pattern only | The ownership table and rules in REF `streams.md` are worth copying (§12) |
| `ai-state/research/rtrfm-api.md` | — | skip | RTRFM-specific |

---

## 11. Deviations from standard, and gotchas

**REF choices that differ from the bare standard.** All are fine to keep.

1. **`X.Y.Z` only.** LMS accepts versions like `1.1a`; REF's build and release scripts allow only
   `X.Y.Z`.
2. **The release workflow writes `repo.xml` back to `main`.** The standard only needs a reachable
   repo XML. Keep `repo.xml` valid at all times: invalid XML kills the official aggregate build for
   everyone.
3. **Hook API with a 25 s timeout** in `Plugin.pm`. This is not an LMS concept, but it is what lets
   streams work in parallel.
4. **No settings page and no `optionsURL`** in REF. We will likely need both.
5. **Element-style repo.xml.** The aggregator emits attributes; either works because XML::Simple
   treats them the same.
6. **REF claims 8.0 but was only tested on 9.1.1.** We claim 8.3 (§5.2), also tested only on 9.1.1.
   Say so in the README.

**Gotchas** (ARCH "Gotchas" 1-20 all still apply; these are the ABC-specific additions and the
critical ones):

1. **HLS isn't playable by core LMS.** Use `audio_streams[type=AAC|MP3]`. Normalise `;*.mp3`
   suffixes and prefer https.
2. **mediahubaustralia blocks this container** (Cloudflare 403). The container can't verify live
   audio, so plan pi14 acceptance, a skippable smoke check, and fixtures for every API path.
3. **Time zones.** ABC is national: Sydney, Adelaide, Darwin, Brisbane and Perth, with DST. Don't
   port RTRFM's fixed-offset Perth helpers. Parse ISO-8601 with offsets (REF `parseISO8601` handles
   `+0000` and `+10:00`) and format with `localtime` (the LMS host's zone) or a station-zone table.
   LMS doesn't guarantee DateTime::TimeZone.
4. **`type => 'audio'` is a leaf.** An item that is browsable *and* playable is a `link` with
   `play`, and no `on_select`.
5. **Coderefs** can't go into `Slim::Utils::Cache` (Storable) or favourites. Favourites must be
   string URLs, i.e. our `abclisten://` URLs.
6. **Answer every feed exactly once**, on error too, or the UI spins until XMLBrowser's 35 s
   timeout.
7. **Never block.** All HTTP goes through `SimpleAsyncHTTP` (`HTTP.pm`); there is no LWP in server
   code (DOC).
8. **Metadata precedence.** A provider's non-empty hash suppresses ICY/`wmaMeta`, and the first
   matching regex wins. Return `{}` for foreign URLs, and keep live and episode matching disjoint.
9. **Sync groups.** Key timers on `$client->master`; kill them when stopped or when the URL changes.
   ABC has many stations, so don't poll services nobody is playing.
10. **Default skin hides `line2`.** Put essential info (date) in `name`; put rich text in
    `description`/`textarea`.
11. **No hot reload.** Restart LMS after code or strings changes. The plugin name under `Plugins/`
    must equal the namespace. Don't keep a repo-installed copy and a dev symlink at the same time.
12. **Credentials.** The `pref` CLI query exposes any plugin pref (`Queries.pm:3011-3050`), so keep
    tokens out of prefs and never store passwords (§6).
13. **Local test deps.** `URI::Escape`, `HTML::Entities` and `shellcheck` are missing in this
    container. CI installs them; locally run `apt-get install liburi-perl libhtml-parser-perl shellcheck`
    before `scripts/check.sh`.
14. **Commit identity.** Same rule as REF (REF OPEN-QUESTIONS #5): everything is authored as
    Wilson Waters <wilsonwaters@users.noreply.github.com> with no tool/vendor attribution, and REF
    `release.yml:268-270` uses that identity for the `repo.xml` commit (see OPEN-QUESTIONS, Resolved).
15. **Squeezelite sample rates.** The testbed player needs `-Z 192000`, or LMS rejects 48 kHz AAC
    (already in `dev/common.sh`). Real Squeezebox Classic/Boom/Transporter players need `faad` for
    AAC (README troubleshooting, as REF item b).
16. **RadioNowPlaying overlap.** RNP may already provide metadata for ABC Icecast URLs. Our
    provider/PH registers first (ASCII order) and RNP defers. Verify there's no double push if a
    user has both.

---

## 12. Suggested foundation task (for the stream planner)

Mirror REF F1 + F2:
- `ABCListen/` skeleton: install.xml, strings.txt with per-task sections, `Plugin.pm` with the hook
  API, `HTTP.pm`, `Util.pm`, stub hook modules, a `ProtocolHandler.pm` registered for `abclisten`,
  and the icon.
- The ported `t/lib` harness and `t/10`–`t/16`.
- The `scripts/` set, `ci.yml`, `release.yml`, and `repo.xml` with a placeholder sha.
- README install section and `RELEASING.md`.

Runtime demo:
1. Link the plugin and restart.
2. `["pref","plugin.state:ABCListen","?"]` returns `enabled`.
3. "ABC listen" appears in the Radio menu with its icon.
4. One live item plays on DevPlayer, through HLS-free Icecast if reachable, otherwise shown as
   browse-only, with the block documented.

Then cut v0.1.0 through the workflow.

Ownership rules worth copying from REF `ai-state/streams.md`:
- `Plugin.pm` is frozen after F1;
- strings are edited in the owner's section only;
- only release commits change `install.xml` `<version>`;
- foundation owns `scripts/`, `.github/`, `repo.xml` and the docs;
- `t/lib` stubs change additively only;
- test-number prefixes per stream.
