# RUNBOOK: local LMS dev environment

This container runs a local **Lyrion Music Server 9.1.1** and a headless **squeezelite** player
called "DevPlayer". We use it to load the ABC listen plugin (`Plugins::ABCListen`, repo dir
`ABCListen/`) straight from the repo, browse its menus (web UI and JSON-RPC) and check that ABC
streams really play. The user's own LMS can't be reached from here, so this is our only runtime
test bed.

The testbed is ported from the user's earlier plugin, wilsonwaters/SqueezeRTRFM (`dev/` and its
`ai-state/RUNBOOK.md`); only the names changed (RTRFM -> ABCListen), plus the small fixes listed
under [Changes from the reference](#changes-from-the-squeezertrfm-testbed).

## TL;DR

```bash
dev/setup.sh                      # one-time install (idempotent, re-run safe)
dev/start.sh                      # start egress-proxy + LMS + DevPlayer, wait until ready
dev/rpc.sh - '["players",0,10]'   # should list DevPlayer (00:00:00:00:00:01)
dev/link-plugin.sh --restart      # load <repo>/ABCListen into LMS (symlink), restart LMS
dev/restart-lms.sh                # reload plugin Perl code after edits
dev/logs.sh -n 50                 # last 50 lines of LMS server.log
dev/stop.sh                       # stop everything
```

Web UI: <http://localhost:9000/> (Default skin) · <http://localhost:9000/material/> ([Material skin](#material-skin)) ·
JSON-RPC: `http://localhost:9000/jsonrpc.js` · CLI port 9090.

**Most important ABC findings (2026-10-19, details in [Playback results](#playback-results-by-stream-format)):**
from this container, `live-radio0N.mediahubaustralia.com` (the MP3/AAC Icecast streams) is
**blocked by Cloudflare (403)**, and LMS 9.1.1 **cannot play HLS** (`.m3u8`). What plays here:
the StreamGuys HE-AAC Icecast streams (`https://abc.streamguys1.com/live/<station>/icecast.audio`)
and on-demand MP3s (`https://mediacore-live-production.akamaized.net/audio/...mp3`).

## What is installed where

| Thing | Location / detail |
|---|---|
| LMS 9.1.1 (full "src" tarball, which bundles CPAN for every arch incl. perl 5.38 x86_64). 9.1.1 is still the newest release in `latest.xml` as of 2026-10-19. | `/opt/lms-dev/lyrionmusicserver-9.1.1`, symlinked as `/opt/lms-dev/server` |
| Tarball cache | `/opt/lms-dev/dl/lyrionmusicserver-9.1.1.tgz` (118 MB, md5 `11a05b8a79515fb4dfb303c5e0abc6e1`, from `latest.xml`) |
| LMS prefs / cache | `/opt/lms-dev/prefs` (`server.prefs`, `plugin/*.prefs`, `log.conf`), `/opt/lms-dev/cache` |
| PID files, test-bed lock | `/opt/lms-dev/run/{lms,squeezelite,egress-proxy}.pid`, `/opt/lms-dev/run/testbed.lock/` |
| proxychains config (generated on every start) | `/opt/lms-dev/proxychains.conf` |
| Logs (git-ignored) | `<repo>/dev/logs/` (see [Logs](#logs-and-debugging)) |
| Plugin dev link | `/opt/lms-dev/server/Plugins/ABCListen -> <repo>/ABCListen` (created by `dev/link-plugin.sh`) |
| Material Skin 6.4.14 (third-party web UI plugin) | `/opt/lms-dev/server/Plugins/MaterialSkin` (real dir, from `/opt/lms-dev/dl/lms-material-6.4.14.zip`); see [Material skin](#material-skin) |
| apt packages | `squeezelite` (1.9.9-1449), `proxychains4` (4.17), `pv`, `jq`, `unzip`, `libio-socket-ssl-perl`, `libnet-ssleay-perl` (LMS does not bundle the SSL modules) |
| Perl / Node | system `/usr/bin/perl` 5.38; `/opt/node22/bin/node` (v22) for the egress helper and browser tool |
| Headless browser helper | `<repo>/dev/browser/` (`playwright@1.56.1`, pinned to match `/opt/pw-browsers/chromium-1194`) |

All settings live in `dev/common.sh` and can be overridden with environment variables
(`LMS_PORT`, `PLAYER_NAME`, `PLAYER_MAC`, `PLUGIN_SRC`, `PLUGIN_NAME`, `LMS_EXTRA_ARGS`, ...).

LMS runs **in the foreground, not as a daemon**, detached with `setsid`, as root with `--user root`.
Without `--user root`, LMS refuses to run as root and switches to `nobody`, which can't write our
directories. Because of that it logs a harmless "must not be run as root" warning. The first-run
wizard is turned off: `start.sh` sets the `wizardDone` pref through JSON-RPC every time it runs.
LMS 9 needs no online account.

## Scripts (`dev/`)

| Script | Purpose |
|---|---|
| `setup.sh` | Installs apt packages, downloads, verifies and extracts LMS, creates dirs, installs Material Skin (`install-material.sh`; skip with `INSTALL_MATERIAL=0`), runs `npm install` in `dev/browser`. Starts nothing. About 30 s on a fresh container. |
| `install-material.sh` | `[--force] [--uninstall]` installs the pinned Material Skin into `<LMS>/Plugins/MaterialSkin`; no-op if that version is already there. LMS loads it on its next (re)start. |
| `start.sh` | Starts `egress-proxy.mjs`, then LMS (wrapped in proxychains4), then squeezelite. Waits for JSON-RPC and for DevPlayer to connect. Idempotent: anything already running is left alone (and it waits for an already-running DevPlayer to reconnect). About 4 s. |
| `stop.sh` | Stops squeezelite, LMS and egress-proxy. Uses SIGTERM, then SIGKILL, then sweeps each process group. |
| `restart-lms.sh` | Restarts LMS only, to reload plugin code. squeezelite reconnects by itself within a few seconds; the script waits for it. |
| `rpc.sh` | `dev/rpc.sh [--raw] <playerid\|-\|dev> '<json array>'` prints `.result`. `dev` is short for DevPlayer's MAC. |
| `link-plugin.sh` | `[--restart] [--unlink] [src_dir [name]]` symlinks the plugin dir into `<LMS>/Plugins/<name>`. The default is `<repo>/ABCListen`; if that dir doesn't exist yet it logs a hint, links nothing and exits 0. |
| `logs.sh` | `[server\|stdout\|squeezelite\|egress] [-n N] [-f\|--no-follow]`. Follows only when run on a TTY. |
| `testbed-lock.sh` | `acquire <owner> [timeout]` / `release <owner>` / `status`: mutual exclusion for parallel agents (see the last section). |
| `egress-proxy.mjs` | The local CONNECT helper described below. Dev tooling only. |
| `common.sh` | Shared settings and functions, sourced by all the scripts. |
| `browser/screenshot.mjs` | Headless Chromium screenshot of any URL (see [Screenshots](#headless-browser-screenshots)). |

To run with extra LMS options, e.g. debug logging from startup:
`LMS_EXTRA_ARGS="--debug plugin.abclisten=DEBUG" dev/restart-lms.sh`

## How outgoing network access works, and why

### What the sandbox allows (re-measured in this container, 2026-10-19)

The container's only egress is `$HTTPS_PROXY` (a local relay on `127.0.0.1:42301` in front of a
policy-enforcing egress proxy; CA bundle `/root/.ccr/ca-bundle.crt`, also in the system trust store
as `ccr-agent-proxy.pem` / `egress-gateway-ca-*.pem`). Behaviour matches what the SqueezeRTRFM
testbed measured:

- CONNECT tunnels to **:443** carry the origin's real certificate (e.g. `www.abc.net.au` showed its
  DigiCert cert) and **HTTP/1.0 inside TLS works**.
- CONNECT tunnels to **:80** are inspected: HTTP/1.1 works, **HTTP/1.0 gets `426 Upgrade Required`**,
  and CONNECT to an IP followed by a hostname in `Host:` gets `403 Host header does not match`.
- Hosts the policy doesn't allow get **`502` to CONNECT** (seen for `program.abc.net.au` and
  `live-radio05.mediahubaustralia.com`). `curl -sS "$HTTPS_PROXY/__agentproxy/status"` lists recent
  refusals under `recentRelayFailures`.
- **LMS speaks HTTP/1.0 everywhere** (`Slim::Networking::Async::HTTP`,
  `Slim::Player::Protocols::HTTP::requestString`), and squeezelite sends the request string LMS
  gives it. LMS also has no CONNECT/HTTPS-proxy support.

### The chosen setup: proxychains4 + a local helper

Both LMS and squeezelite run under `proxychains4` (LD_PRELOAD, works with the system perl). Every
non-local TCP `connect()` becomes `CONNECT <ip>:<port>` sent to `dev/egress-proxy.mjs` on
`127.0.0.1:3129`. The helper:

1. Answers `200` straight away, so LMS's single-threaded event loop never blocks on remote connects.
2. Sniffs the first bytes the client sends:
   - **TLS** (0x16): reads the SNI and opens an upstream tunnel to `<sni>:<port>` through
     `$HTTPS_PROXY`, then pipes the bytes through unchanged.
   - **HTTP**: re-sends the request as **HTTP/1.1** (`Connection: close`) through a tunnel to
     `<Host header>:<port>`, **de-chunks** the response and returns it close-delimited, which HTTP/1.0
     clients understand. `Range`, `Icy-MetaData` and other end-to-end headers pass through.
   - **Anything else**: a raw tunnel.

If `$HTTPS_PROXY` isn't set, the helper connects directly instead.

- **No allowlist in the helper.** It forwards every host; the upstream policy proxy is the only
  gate. Nothing needed adjusting for ABC hosts (see the table below).
- **DNS:** `proxy_dns` is deliberately **off**. LMS resolves names itself (`AnyEvent::DNS`, IPv4) and
  passes the resolved IP to squeezelite for direct streaming; the helper recovers the hostname from
  SNI or the Host header.
- **TLS verification stays on** (`insecureHTTPS: 0`). Ubuntu's `IO::Socket::SSL` uses the system
  trust store, which includes the proxy/gateway CAs, and :443 tunnels carry real certificates anyway.
- **Don't set LMS's `webproxy` pref.** It only applies to `http://`, sends plain forward-proxy
  requests (upstream answers 405) and mangles https request lines.
- proxychains `localnet` entries exclude 127/8, the RFC1918 ranges and the container's own IPs, so
  LMS can still reach local services (e.g. a local `repo.xml` server).

The helper logs one line per connection to `dev/logs/egress-proxy.log` (`dev/logs.sh egress`): the
quickest way to see what LMS and the plugin fetch, and whether anything failed.

### ABC hosts through the LMS egress path

Measured with `proxychains4 -q -f /opt/lms-dev/proxychains.conf curl --noproxy '*' --http1.0 ...`
(same path LMS uses), 2026-10-19:

| Host | Result | Notes |
|---|---|---|
| `www.abc.net.au` | 200 (https), 301 (http -> https) | Station pages embed stream `sources` JSON |
| `api.abc.net.au` | reachable; 403 at `/`, 401 on `/terminus/api/v1/...` without a key | Origin answers, so network is fine |
| `music.abcradio.net.au` | 200 JSON on `/api/v1/plays/search.json?limit=1&station=triplej` | Now-playing / plays API works |
| `abcmedia.akamaized.net` | reachable (302 at `/`, 404 on a guessed path) | Akamai origin answers |
| `mediacore-live-production.akamaized.net` | 206 `audio/mpeg` | On-demand episode MP3s |
| `streaming.abc-cdn.net.au` | 200/206 (`.m3u8`, `.pls`) | HLS masters and Icecast `.pls` files |
| `mediaserviceslive.akamaized.net` | 200 `application/vnd.apple.mpegURL` | HLS variant playlists / `.ts` segments |
| `abc.streamguys1.com` | 200 `audio/aacp` | Icecast HE-AAC live streams: **plays** |
| `resize.abcradio.net.au` | reachable (400 at `/`) | Image resizer |
| `live-radio01..04.mediahubaustralia.com` | **403 from Cloudflare** ("Sorry, you have been blocked", `cf-ray …-IAD`) | WAF block on this container's egress IP, any User-Agent; not fixable here |
| `live-radio05.mediahubaustralia.com`, `program.abc.net.au` | **502 to CONNECT** | Refused by the sandbox egress policy |

The mediahub block is about where this container's traffic exits (a US datacenter), not about LMS;
it presumably works from an Australian home network, but that is **unverified** from here. The real
plugin should treat a mediahub 403 as a possible failure and have a fallback (e.g. the StreamGuys URL).

## Audio output (squeezelite)

There's no sound card, and the ALSA `null` device doesn't keep real time, so squeezelite writes PCM
to stdout and `pv` throttles it to real time:

```
proxychains4 … squeezelite -n DevPlayer -m 00:00:00:00:00:01 -s 127.0.0.1 -o - -a 16 \
    -r 44100-44100 -u mX -Z 192000 -d all=info -f dev/logs/squeezelite.log | pv -q -L 176400 >/dev/null
```

- `-o - -a 16` writes 16-bit PCM to stdout; `-r 44100-44100 -u mX` async-resamples everything to
  44.1 kHz (a 48 kHz stream is logged as `resampling from 48000 -> 44100`).
- `pv -L 176400` throttles the pipe to exactly real time (44100 × 2 ch × 2 bytes), so LMS's
  elapsed `time` is meaningful.
- `-Z 192000` still advertises a realistic max sample rate; without it LMS rejects 48 kHz streams.
- DevPlayer advertises `CanHTTPS=1` and codecs `aac,mp3,flc,ogg,ops,pcm,…` in its HELO.

### Direct versus proxied streaming

LMS's default is **direct streaming**: squeezelite fetches the stream URL itself (it's under
proxychains too). Both modes were verified with the StreamGuys AAC stream. To switch:

```bash
dev/rpc.sh dev '["playerpref","mp3StreamingMethod","1"]'   # 1 = proxied via LMS
dev/rpc.sh dev '["playerpref","mp3StreamingMethod","0"]'   # back to default (direct)
```

`dev/logs/squeezelite.log` shows which mode was used: `connecting to 127.0.0.1:9000` +
`GET /stream.mp3?player=…` (proxied), or `connecting to <remote ip>:443` (direct).

## Loading the plugin under development

On Unix, LMS scans `<LMS>/Plugins/` (`$Bin/Plugins`) for `install.xml`. `File::Next` follows
symlinks and `$Bin` is on `@INC`, so a symlink named after the namespace is enough; LMS then reads
the code straight from the repo working tree:

```bash
dev/link-plugin.sh --restart      # /opt/lms-dev/server/Plugins/ABCListen -> /home/user/SqueezeABCListen/ABCListen
# ...edit ABCListen/*.pm...
dev/restart-lms.sh                # Perl code is only loaded at startup
dev/link-plugin.sh --unlink       # remove the dev link
```

- **`ABCListen/` doesn't exist yet** (as of 2026-10-19). Until it does, `dev/link-plugin.sh` just
  prints `plugin dir … does not exist yet - nothing linked` and exits 0 (and removes a dangling link
  if one is left). Create `ABCListen/install.xml` (module `Plugins::ABCListen::Plugin`), `Plugin.pm`
  and `strings.txt`, then run `dev/link-plugin.sh --restart`.
- The name under `Plugins/` must match the namespace: `Plugins::ABCListen::Plugin` means
  `Plugins/ABCListen`. A different dir/name can be linked with `dev/link-plugin.sh <src_dir> [name]`,
  and unlinked with `dev/link-plugin.sh --unlink <src_dir_or_anything> <name>`.
- New plugins default to **enabled**. Check with `dev/rpc.sh - '["pref","plugin.state:ABCListen","?"]'`.
- The plugin manifest cache (`/opt/lms-dev/cache/plugin-data.yaml`) is rebuilt automatically when
  the set of `install.xml` files or their mtimes change.
- `--restart` also prints `server.log` lines mentioning the plugin since the restart. Load errors show
  up as `Couldn't load ABCListen` / perl compile errors in `server.log`, with `lms-stdout.log` as a backup.
  (A standalone `perl -c Plugin.pm` doesn't work: `Slim::Plugin::OPMLBased` needs LMS's bootstrap.)
- **Don't** also install the plugin through the Extension Manager: a copy in
  `/opt/lms-dev/cache/InstalledPlugins/Plugins/ABCListen` would clash; `link-plugin.sh` warns about it.
- **Logging gotcha:** a brand-new log category only gets its level after LMS re-inits logging, which
  happens after plugins load, so `warn`/`info`/`debug` calls made **during `initPlugin`** are dropped
  (only `error` gets through). To see init-time logs, preset the category:
  `LMS_EXTRA_ARGS="--debug plugin.abclisten=DEBUG" dev/restart-lms.sh`.
- **Removing a throwaway plugin completely:** unlink it, then with LMS stopped delete its
  `<Name>:` and `_ts_<Name>:` lines from `/opt/lms-dev/prefs/plugin/state.prefs` (LMS rewrites prefs
  on shutdown, so edit while it's stopped), then start again:
  `bash -c 'source dev/common.sh; stop_lms; sed -i "/^Name:/d; /^_ts_Name:/d" "$LMS_PREFS/plugin/state.prefs"'; dev/start.sh`

### Testing the "install from repository" flow (not yet tried)

Serve the build output locally, e.g. `python3 -m http.server 8765 --bind 127.0.0.1 -d dist`, then add
`http://127.0.0.1:8765/repo.xml` under *Settings → Manage Plugins → Additional Repositories*. Run
`dev/link-plugin.sh --unlink` first so the two copies don't clash. Downloaded zips are extracted into
`/opt/lms-dev/cache/InstalledPlugins/Plugins/` on the next restart.

## Playback results by stream format

Smoke test on 2026-10-19 with a throwaway OPMLBased plugin (`Plugins::ABCProbe`, five `type =>
'audio'` items, kept in the scratchpad outside the repo, linked with `dev/link-plugin.sh --restart
<dir>`, browsed with `["abcprobe","items",0,20]`, played with `["abcprobe","playlist","play","item_id:<id>"]`,
then unlinked, deleted and its state pref removed). Station: triple j unless noted.

| Format / URL | Result in LMS 9.1.1 + squeezelite |
|---|---|
| **MP3 Icecast**, `https://live-radio01.mediahubaustralia.com/2TJW/mp3/` (also tried `2RNW/mp3/`, `live-radio02..04`) | **Fails here**: Cloudflare 403. `server.log`: `Scanner::Remote … Can't connect to remote server to retrieve playlist for, …/2TJW/mp3/: 403 Forbidden.` `mode` goes to `stop`. Environment block, not an LMS problem. |
| **AAC Icecast (mediahub)**, `https://live-radio01.mediahubaustralia.com/2TJW/aac/` (the URL ABC's own web player lists as `type: "aac"`) | **Fails here**: same Cloudflare 403. |
| **HE-AAC Icecast (StreamGuys)**, `https://abc.streamguys1.com/live/triplejnsw/icecast.audio` (`audio/aacp`, `icy-br: 56`, server Nimble; no `icy-metaint` seen) | **Plays.** LMS type "AAC Radio", "56kbps CBR"; faad decodes ADTS at 44.1 kHz stereo (no resampling). `time` 1.26 → 13.41 s over 12 s wall clock; player `bytes_received` 1,458,061 → 1,701,271 over 9 s. Works in both direct and proxied mode. |
| **HLS**, `https://streaming.abc-cdn.net.au/audio/hls/triplejnsw.m3u8` (master → `mediaserviceslive.akamaized.net/hls/live/2109456/triplejnsw/v0-221.m3u8` AAC-LC / `v0-222.m3u8` HE-AACv2, 10 s MPEG-TS segments) | **Does not play.** LMS core has no HLS support (`types.conf` maps `m3u8` to a plain `m3u` playlist; TuneIn.pm notes HLS needs the third-party *PlayHLS* plugin + ffmpeg). Shown as "M3U Radio", `mode: play` but `time` stuck at 0; `server.log`: `Can't call method "scanUrl" on an undefined value at Slim/Utils/Scanner/Remote.pm line 1299`. |
| **On-demand MP3**, `https://mediacore-live-production.akamaized.net/audio/02/pi/Z/kj.mp3` (an RN *Conversations* episode; 128 kbps, 48 kHz, 43 MB, from the episode page's `renditions`) | **Plays.** "MP3 Radio", "128kbps CBR", `duration` 2704.08 s; `time` 2.98 → 15.10 s over 13 s; 206 Partial Content with `Range`. **Seeking works**: `["time",600]` → new request `Range: bytes=9600000-` → `time` 603.4 → 607.4. |

Where the URLs came from (for the record; the stream research lives in `ai-state/research/`): ABC
station pages (e.g. `https://www.abc.net.au/triplej/live/triplej`, `/listen/live/classic`,
`/listen/live/jazz`, `/listen/doublej/live`, `/listen/live/sydney`, `/listen/live/news`) embed
`"sources":[{"file":"https://streaming.abc-cdn.net.au/audio/hls/<station>.m3u8?source=web","type":"hls"},
{"file":"https://live-radio01.mediahubaustralia.com/<code>/aac/?source=web","type":"aac"}]`, and some
also list `https://www.abc.net.au/res/streaming/audio-live/shout-aac/<name>.pls`, which 302s to
`https://streaming.abc-cdn.net.au/audio/ice/<station>.pls` → `File1=https://abc.streamguys1.com/live/<station>/icecast.audio`
(seen for `abcjazz`, `doublejnsw`, `triplejnsw`, `classicfmnsw`, `newsradio`, `localsydney`).

**Implications for the plugin:** prefer Icecast URLs (StreamGuys, or mediahub MP3/AAC for users in
Australia) over HLS; in this container, test live playback with StreamGuys URLs. Since StreamGuys
sent no ICY metadata, now-playing info has to come from an API (e.g. `music.abcradio.net.au`).

## JSON-RPC cheat sheet

```bash
dev/rpc.sh - '["serverstatus",0,10]'                         # version, player count
dev/rpc.sh - '["players",0,10]'                              # list players
dev/rpc.sh dev '["playlist","play","https://abc.streamguys1.com/live/triplejnsw/icecast.audio"]'
dev/rpc.sh dev '["status","-",1,"tags:aluKo"]'               # mode/time/current_title/remoteMeta
dev/rpc.sh dev '["time",600]'                                # seek (on-demand)
dev/rpc.sh dev '["stop"]'        # also: ["pause"], ["power",0|1], ["mixer","volume",50]
dev/rpc.sh dev '["playlist","clear"]'
dev/rpc.sh - '["apps",0,50]'                                 # plugin menus under My Apps
dev/rpc.sh - '["radios",0,50]'                               # plugin menus under Radio
dev/rpc.sh dev '["abclisten","items",0,50]'                  # the plugin's OPML top level (if tag = abclisten)
dev/rpc.sh dev '["abclisten","items",0,50,"item_id:<id>"]'   # drill down
dev/rpc.sh dev '["abclisten","playlist","play","item_id:<id>"]'  # play an OPML item
dev/rpc.sh - '["debug","plugin.abclisten","DEBUG"]'          # runtime log level (see gotcha above)
dev/rpc.sh - '["pref","wizardDone","?"]'                     # read/write server prefs
```

Raw curl equivalent:
`curl -s -H 'Content-Type: application/json' -d '{"id":1,"method":"slim.request","params":["00:00:00:00:00:01",["status","-",1]]}' http://localhost:9000/jsonrpc.js`

A small playback check. `time` should grow by about 3 s per sample while `mode` stays `play`:

```bash
dev/rpc.sh dev '["playlist","play","https://abc.streamguys1.com/live/triplejnsw/icecast.audio"]' >/dev/null
for i in 1 2 3 4; do sleep 3; dev/rpc.sh dev '["status","-",1]' | jq -c '{mode,time,current_title}'; done
dev/rpc.sh dev '["stop"]'
```

To prove bytes are arriving at the player, briefly enable slimproto debug and read the STAT
`bytes_received` counter (there's no `ss` in this container):

```bash
dev/rpc.sh - '["debug","network.protocol.slimproto","DEBUG"]'; sleep 10
dev/rpc.sh - '["debug","network.protocol.slimproto","WARN"]'
grep -a 'bytes_received ' dev/logs/server.log | tail -n 3
```

## Headless browser screenshots

```bash
node dev/browser/screenshot.mjs http://localhost:9000/ dev/logs/lms-webui.png [--full] [--wait-ms 3000] [--width 1280 --height 900]
node dev/browser/screenshot.mjs http://localhost:9000/material/ dev/logs/lms-material.png   # Material skin
#   [--wait-until load|domcontentloaded|networkidle|commit] [--selector CSS] [--timeout MS]
# prints {"url","status","title","out","waitUntil","selector","pageErrors"}; works from any cwd
```

It uses the Chromium in `$PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`. **Never run
`playwright install`.** If you bump playwright, it must match the installed `chromium-1194`
(playwright 1.56.x). Save screenshots under `dev/logs/` (git-ignored) or the scratchpad; don't commit them.

The Default skin is at `/` (default wait: `networkidle`). Material skin is at `/material/`; see
[Material skin](#material-skin) for why it needs a different wait. Plugin OPML menus appear under *My Apps*
or *Radio* depending on `menu`/`is_app`. Deep links such as
`http://localhost:9000/plugins/ABCListen/settings/basic.html` work once the plugin has a settings page.

## Material skin

[Material Skin](https://github.com/CDrummond/lms-material) is the most popular LMS web UI. It's a
third-party plugin, installed here so runtime checks can screenshot the plugin in both skins.

- **Version 6.4.14**, pinned in `dev/common.sh` (`MATERIAL_VERSION`, `MATERIAL_ZIP_URL`, `MATERIAL_ZIP_SHA1`)
  to the entry in the official repository's
  [`extensions.xml`](https://github.com/LMS-Community/lms-plugin-repository/blob/master/extensions.xml):
  `https://github.com/CDrummond/lms-material/releases/download/6.4.14/lms-material-6.4.14.zip`,
  sha1 `e8981b27c955a8fd7f151c848be85aa14171ea36` (1.9 MB).
- **How it's installed:** `dev/setup.sh` calls `dev/install-material.sh`. That script downloads the zip
  once to `/opt/lms-dev/dl/`, checks the sha1, unzips it to `/opt/lms-dev/server/Plugins/MaterialSkin`
  (a real dir, next to the ABCListen dev link) and does nothing if `install.xml` already has that version.
  This is LMS's *manual install* location, so the Extension Manager never auto-updates or uninstalls it.
  If it were in `cache/InstalledPlugins` without a matching `plugin.extensions` pref, LMS would flag it
  for uninstall. `install.xml` has `defaultState: enabled`. Check that with
  `dev/rpc.sh - '["pref","plugin.state:MaterialSkin","?"]'` (should print `enabled`).
  After installing, or after changing `MATERIAL_VERSION` and running `install-material.sh`, restart LMS
  under the test-bed lock (`dev/restart-lms.sh`). `install-material.sh --uninstall` removes it.
- **URLs:** <http://localhost:9000/material/> (layout picked from the window width). Forced layouts:
  `/material/desktop`, `/material/mobile`, `/material/now-playing`, `/material/mini`. (Root-level
  `/desktop` etc. return an empty 200, so keep the `/material/` prefix.) Material's JS also reads a `?player=` query
  parameter, but DevPlayer is auto-selected anyway as the only player. Material's settings page
  is at `/plugins/MaterialSkin/settings/basic.html`.
- **Screenshot tip:** Material is a Vue/Vuetify app that keeps a cometd long-poll open, so
  Playwright's `networkidle` **never fires** (`goto` timed out at 30 s). For `/material…` URLs,
  `screenshot.mjs` therefore defaults to `--wait-until load --selector '#main-toolbar'`, then the
  usual `--wait-ms` settle. The UI renders within about 1 s, and a screenshot takes about 3 s.
  Use `--selector '#browse-list'` to wait for list content after navigating. Other stable ids:
  `#browse-view`, `#queue-view`, `#np-bar`. To drill into *Radio*/*Apps* to reach a plugin menu, write
  a small Playwright script modelled on `screenshot.mjs` that clicks through. Material's JS also parses an
  `expand=` query parameter, which isn't tried yet. Material uses a dark theme by default.

## Logs and debugging

| Log | What |
|---|---|
| `dev/logs/server.log` | Main LMS log (`dev/logs.sh`) |
| `dev/logs/lms-stdout.log` | LMS stdout/stderr (perl warnings, startup failures) (`dev/logs.sh stdout`) |
| `dev/logs/squeezelite.log` | squeezelite at info level: stream connects, request/response headers, codec, resampling (`dev/logs.sh squeezelite`) |
| `dev/logs/egress-proxy.log` | Every outbound connection LMS/squeezelite makes, with status codes (`dev/logs.sh egress`) |
| `dev/logs/scanner.log`, `perfmon.log` | LMS scanner / perf monitor (usually empty) |

For more detail from LMS subsystems: `dev/rpc.sh - '["debug","player.streaming.remote","DEBUG"]'`,
or `player.source` (transcoding decisions), `network.asynchttp`, `plugin.abclisten`. Set them back to
`WARN` afterwards. Set `EGRESS_DEBUG=1` before `start.sh` for more detail from the helper.

## Known limitations and gotchas

- **mediahubaustralia.com live streams can't be tested here** (Cloudflare 403); use StreamGuys URLs
  for live playback tests. **HLS doesn't play in stock LMS** at all (see above).
- **Processes don't survive a container restart.** Run `dev/start.sh` again. If `/opt/lms-dev` is
  gone (fresh container), run `dev/setup.sh` first; it re-downloads about 118 MB (~7 s) and takes ~30 s.
- `start.sh` must run where `$HTTPS_PROXY` is set (the helper reads it at startup). Without it the
  helper connects directly: plain HTTP still works thanks to the 1.1 upgrade, but HTTPS then fails.
- Right after a (re)start LMS may drop a request or two (`curl: (52) Empty reply from server`) while
  its post-start scan finishes; `start_lms` now waits for that, but scripts that hammer LMS straight
  after a restart should retry.
- The helper handles one HTTP request per tunnel (`Connection: close`); no HTTP/2, no WebSockets. The
  upstream proxy may block TLS on ports other than 443.
- proxychains does its CONNECT handshake with the helper synchronously inside `connect()`. Harmless
  because the helper replies at once, but a hung helper would freeze LMS. If LMS seems frozen, check
  `dev/logs.sh egress` and restart with `dev/stop.sh && dev/start.sh`.
- Don't set LMS's `webproxy` pref. Leave `insecureHTTPS` at 0 so we test with real certificate checks.
- LMS runs as root (`--user root`): fine for this sandbox, not how users run it.
- Audio is discarded: we can prove streams decode and advance in real time, not judge audio quality.
  Output is always resampled to 44.1 kHz/16-bit; squeezelite reports 192 kHz max to LMS.
- The media library is empty (no music folder); "Fulltext index missing" lines are normal.
- On startup LMS contacts `lyrion.org`, `lms-community.github.io`, `api.lms-community.org` and
  `opml.radiotime.com` (TuneIn) through the helper. That's normal and all of them work.

## Changes from the SqueezeRTRFM testbed

- Renamed RTRFM → ABCListen (`PLUGIN_NAME`, `PLUGIN_SRC`, docs, `dev/browser` package name,
  `rpc.sh` example tag `abclisten`, testbed-lock paths `/home/user/SqueezeABCListen/dev`).
- `link-plugin.sh`: a missing default `ABCListen/` is a no-op with a hint (exit 0) instead of an error.
- `common.sh`: `start_lms` re-checks JSON-RPC after a 2 s settle; `start_player` waits for an
  already-running squeezelite to reconnect (so `start.sh` after an LMS-only restart is reliable).
- `restart-lms.sh` reuses `start_player` for the reconnect wait.
- `rpc.sh` / `logs.sh`: usage text no longer prints the `set -euo pipefail` line; `rpc.sh` example
  plays an ABC stream.
- `egress-proxy.mjs`: comment only (no allowlist; the upstream policy decides). Logic unchanged.

## Verification record (2026-10-19)

- `dev/setup.sh` on a fresh container: apt packages, LMS 9.1.1 tarball (md5 OK), npm install; ~29 s.
  Re-run is a no-op.
- `dev/start.sh`: ready in ~4 s. `["serverstatus",0,10]` → version 9.1.1, 1 player;
  `["players",0,10]` → DevPlayer `00:00:00:00:00:01`, connected, model squeezelite.
  `http://localhost:9000/` → 200. `stop.sh` → `start.sh` → `restart-lms.sh` cycles all clean.
- Throwaway plugin: loaded from the symlink, listed in `["radios",0,50]` as "ABC Probe (dev)",
  `["abcprobe","items",0,20]` returned its 5 items, items played as in the table above, then it was
  unlinked, deleted, and its `state.prefs` entries removed. `server.log` had no errors other than the
  expected mediahub 403s and the HLS scanner crash.
- Headless Chromium screenshot of `http://localhost:9000/` → 200, title "Lyrion Music Server", no page
  errors, DevPlayer selected and playing the StreamGuys AAC stream (`dev/logs/lms-webui.png`).
- LMS + DevPlayer were left running with an empty playlist and no plugin linked.
- Material Skin 6.4.14 added later the same day: `dev/setup.sh` installed it (sha1 OK), a re-run printed
  `already installed`, `restart-lms.sh` → `plugin.state:MaterialSkin` = `enabled`, `/material/` → 200,
  no errors in `server.log`. Screenshot `dev/logs/lms-material.png`: Home view (My Music, Radio,
  Favorites, Apps, Extras) with DevPlayer selected, no page errors. LMS + DevPlayer were left running.

## Sharing the test bed between agents

There is exactly one LMS + DevPlayer. Any agent that re-links the plugin, restarts LMS or plays
audio must hold the test-bed lock, and must run the dev scripts from the **main checkout**
(`/home/user/SqueezeABCListen/dev/…`) so logs/pids resolve to the running instance, pointing
`PLUGIN_SRC` at its own worktree:

```bash
/home/user/SqueezeABCListen/dev/testbed-lock.sh acquire <TASK-ID>          # waits (default 30 min) if busy
PLUGIN_SRC=<worktree>/ABCListen /home/user/SqueezeABCListen/dev/link-plugin.sh --restart
# ... runtime checks via dev/rpc.sh, dev/browser/screenshot.mjs, dev/logs.sh ...
/home/user/SqueezeABCListen/dev/rpc.sh 00:00:00:00:00:01 '["stop"]'
/home/user/SqueezeABCListen/dev/link-plugin.sh --restart                   # back to the main checkout
/home/user/SqueezeABCListen/dev/testbed-lock.sh release <TASK-ID>
```

Stale locks (> 60 min) are broken automatically. Keep lock hold times short.
