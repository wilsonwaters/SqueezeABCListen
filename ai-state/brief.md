# Project Brief — SqueezeABCListen

_Agreed brief for the orchestrated build. Source: stakeholder request (Wilson Waters), 2026-10-19._

## What we're building

A **Lyrion Music Server (LMS, formerly Logitech Media Server / Squeezebox Server) plugin** dedicated to
**ABC listen** (<https://www.abc.net.au/listen>, the Australian Broadcasting Corporation's radio and
on-demand audio service). It is deliberately ABC-listen-specific rather than a generic radio/podcast
plugin. The goal:

> Browse **all ABC listen channels** through Lyrion, with all the additional context ABC provides
> (artwork, descriptions, presenters, dates, durations, now-playing), and **select an episode to listen to**.

Core capabilities:

1. **Live stations** — every ABC listen live channel (national networks, music networks, local radio),
   with station artwork, the program currently on air, and now-playing song metadata where ABC publishes it.
2. **Programs → episodes** — browse ABC listen programs (by station/channel, category, A–Z) and their
   episodes with artwork, synopsis, broadcast date and duration; play any episode.
3. **Discovery** — the curated ABC listen collections (home-page featured items, categories) and search.
4. **Optional ABC login** — the plugin must be fully usable **without** logging in. If an ABC account
   unlocks extra functionality (e.g. followed programs / "continue listening"), support it as an opt-in
   setting, implemented securely (see Open Questions).

## Users

- The stakeholder, running LMS at `http://pi14.alintech.com.au:9000/` with Squeezebox players (in Australia).
- Other LMS users who want ABC listen — they must be able to **install the plugin easily** from the LMS UI.

## Platform & tech constraints

- LMS plugin in **Perl**, namespace `Plugins::ABCListen`, plugin directory `ABCListen/`, built on
  `Slim::Plugin::OPMLBased` (the standard LMS pattern for radio/podcast plugins). Target current LMS
  releases (9.x, with 8.x compatibility where free).
- Must work in the stock LMS web UI (Default skin), Material skin, and hardware players / apps (OPML menus).
- Follow the **standard Lyrion plugin process** (install.xml, repository XML, official plugin repository
  conventions), using the stakeholder's **SqueezeRTRFM** plugin (<https://github.com/wilsonwaters/SqueezeRTRFM>)
  as the reference implementation for structure, testbed, tests, CI and release tooling.
- Data comes from ABC's public web/app endpoints as used by the ABC listen clients. No credentials are
  committed to the repo; any user credentials/tokens live only in the user's LMS prefs.
- Repository: <https://github.com/wilsonwaters/SqueezeABCListen> (Apache-2.0, same as the reference).
  The stakeholder permits committing directly to `main`.

## Distribution ("install easily")

- Publish a **third-party LMS repository XML** (`repo.xml`) in the GitHub repo, pointing at a versioned
  plugin zip (GitHub release asset) with its SHA1, so users add one URL under *Settings → Manage Plugins →
  Additional Repositories* and install/update from the LMS UI.
- Automated, repeatable packaging (zip + sha1 + repo.xml) via a release workflow.
- Document how to submit to the official LMS-Community plugin repository.
- README with installation and usage instructions and screenshots.

## Success criteria (definition of done)

1. With the plugin installed, every ABC listen live station is listed with artwork and **plays audio**.
2. A user can browse programs and their episodes (artwork + description + date + duration visible in the
   LMS web UI) and **play an episode**.
3. Additional context is shown where ABC provides it: program on air for live stations, now-playing song
   info on music stations, episode/program descriptions.
4. Discovery: ABC listen featured collections/categories and search are browsable.
5. Everything above works **without logging in**; login-only features (if any) are optional and secure.
6. A user can install the plugin via the repository URL in LMS settings.
7. Automated tests + independent review pass; runtime verification on a real LMS instance passes.

## Environment & verification (adapted to this session)

- Work runs in a cloud development container. The stakeholder's LMS (pi14) is **not resolvable** from the
  container, so runtime/system verification runs against a **local LMS + squeezelite instance inside the
  container** (see `ai-state/RUNBOOK.md`). The stakeholder performs final acceptance on pi14.
- Because the stakeholder cannot start servers inside the container, a dev-environment sub-agent owns
  starting/stopping the local LMS (deviation from the orchestrator manual's "user starts the dev env" rule).
- No `gh` CLI: the board is GitHub Issues/PRs driven through the GitHub MCP tools.
- The container's internet egress exits outside Australia; any ABC geo-restriction found during testing is
  recorded, and the affected behaviour is verified by the stakeholder on pi14.

## Out of scope

- Non-ABC stations/podcasts; ABC video (iview), news articles and other non-audio content.
- Downloading/caching episodes for offline playback; transcoding beyond what LMS does natively.
- Writing back to ABC beyond what an opted-in login feature strictly needs.

## Timeline

Single orchestrated session, driven to completion.
