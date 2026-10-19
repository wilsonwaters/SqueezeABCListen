# StationData.pm generator

`ABCListen/StationData.pm` is the plugin's static catalogue of live stations, and it is generated. Don't
edit its records by hand. Change the inputs, or the tables at the top of `scripts/gen-station-data.py`,
and then regenerate the file.

This is maintainer tooling. It isn't in the plugin zip: `scripts/build.sh` packages only `ABCListen/`,
and `scripts/check-package.sh` rejects any `scripts/` entry. Neither CI nor `scripts/check.sh` runs it.
It needs Python 3 and nothing outside the standard library.

## Commands

Run these from the repository root (the script finds the root itself, so any directory works):

```sh
scripts/gen-station-data.py            # regenerate ABCListen/StationData.pm from the committed inputs (offline)
scripts/gen-station-data.py --check    # exit 1 if ABCListen/StationData.pm differs from what the inputs give
scripts/gen-station-data.py --capture  # refresh the captured inputs from ABC, then regenerate
```

`--capture` makes about 110 GET requests, one at a time and one a second. It only contacts
`www.abc.net.au`, `program.abcradio.net.au` and `streaming.abc-cdn.net.au`. If any request fails, it
writes nothing. Run it by hand only, and not in a loop.

## Inputs

The inputs are committed captures, so regenerating needs no network and always gives the same file.
Most of them are also the `t/data/live` fixtures that `t/20-stations.t` checks the catalogue against,
which keeps the catalogue and its tests in step.

| Input | Used for | Source | Rewritten by `--capture` |
|---|---|---|---|
| `t/data/live/papi-services-offset{0,100}.json` | names, `tz`, synopses | PAPI `services.json`, trimmed to the fields that are read | yes |
| `t/data/live/bff-collection-national.json` | network and sport logos | BFF collection 12872264 (body as served) | yes |
| `t/data/live/bff-collection-state-<ST>.json` | local stations, their states and logos | BFF state collections (bodies as served) | yes |
| `t/data/live/icecast-pls-probe.tsv` | mounts missing from the research data (Wide Bay); a cross-check of every mount | every catalogue `.pls` (slug, status, File1) | yes |
| `scripts/station-data/capture.json` | the capture date in the header; logos of 8 sport live pages | `/listen/live/<slug>` `__NEXT_DATA__` | yes |
| `ai-state/research/abc-samples/derived-station-streams-{national,local}.json` | live-page slugs, HLS names, Icecast mounts, mediahub streams | research crawl | no (edited by hand) |
| `scripts/station-data/StationData.pm.in` | the module text around the records (`@CAPTURED@`, `@RECORDS@`) | hand-written | no |

The script holds the decisions made by hand as tables: the group of each service and its order,
time-zone versions, event-only services, the dedupe winners, capital cities, HLS masters, and name
overrides (`NAME_OVERRIDE`). If ABC adds a station or card it doesn't know, the script stops with a
message. Add the new station to the tables, and to the research data, then run it again.

## After a `--capture`

1. Review `git diff`. Expect the five captured inputs to change, and then `ABCListen/StationData.pm`.
2. Update the capture dates in the fixture notes at the top of `t/20-stations.t`.
3. Run `scripts/check.sh`. Then refresh whatever the tests pin to the capture:
   - `t/20-stations.t`
     - "catalogue: ids, groups and fields": the record count; the group sizes; the event-only, HLS-only,
       `dupOf`, `hls` and capital lists.
     - "catalogue: mounts against the Icecast probes": the mounts that are not in
       `derived-icecast-probe.tsv`.
     - "catalogue: every BFF card maps to an entry": the local card count and the stations per state.
     - "byPageSlug": the cases.
     - The enrichment subtests: the card order and the sport names.
   - `t/21-live-menu.t`: the network names, the capital stations and station counts per state, and the
     Sport menu names.

`--capture` doesn't touch the other `t/data/live` files, which keep their shapes:

- the `epgNowPlaying` samples
- `live-ice-triplejnsw.pls` and `derived-icecast-probe.tsv`, which are research samples
- the synthetic `pls-*` and `epg-*` edge cases
