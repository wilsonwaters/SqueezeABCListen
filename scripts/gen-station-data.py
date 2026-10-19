#!/usr/bin/env python3
"""gen-station-data.py - generate ABCListen/StationData.pm, the static live station catalogue.

Usage (from any directory; every path is relative to the repository root):
  scripts/gen-station-data.py            regenerate ABCListen/StationData.pm from the committed
                                         inputs (offline, deterministic)
  scripts/gen-station-data.py --check    regenerate in memory and exit 1 if ABCListen/StationData.pm
                                         differs (nothing is written)
  scripts/gen-station-data.py --capture  first refresh the captured inputs from ABC's public endpoints
                                         (about 110 GET requests, one at a time, one a second), then
                                         regenerate. Manual only: never run by CI or scripts/check.sh.

Inputs (scripts/station-data/README.md has the details):
  t/data/live/papi-services-offset{0,100}.json   PAPI services: names, time zones, synopses
  t/data/live/bff-collection-national.json       BFF national collection: network logos and order
  t/data/live/bff-collection-state-<ST>.json     BFF state collections: local stations and logos
  t/data/live/icecast-pls-probe.tsv              probe of every catalogue .pls (slug, status, File1)
  scripts/station-data/capture.json              the capture date and the logos of sport live pages
  ai-state/research/abc-samples/derived-station-streams-{national,local}.json
                                                 research data: live-page slugs, HLS names, Icecast
                                                 mounts, mediahub streams (not refreshed by --capture)
  scripts/station-data/StationData.pm.in         the module around the records (@CAPTURED@, @RECORDS@)
The tables below (NETWORKS, SPORT, VARIANTS, NAME_OVERRIDE, ...) hold the hand-made decisions.

--capture writes the first five inputs only; it fetches only https://www.abc.net.au,
https://program.abcradio.net.au and https://streaming.abc-cdn.net.au, and writes nothing unless every
request succeeded. Python 3 standard library only.
"""

import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OUT = 'ABCListen/StationData.pm'
TEMPLATE = 'scripts/station-data/StationData.pm.in'
CAPTURE_JSON = 'scripts/station-data/capture.json'
PAPI_FILE = 't/data/live/papi-services-offset%s.json'
PAPI_PAGES = ('0', '100')
BFF_NATIONAL_FILE = 't/data/live/bff-collection-national.json'
BFF_STATE_FILE = 't/data/live/bff-collection-state-%s.json'
PROBE_FILE = 't/data/live/icecast-pls-probe.tsv'
DERIVED_FILES = ('ai-state/research/abc-samples/derived-station-streams-national.json',
                 'ai-state/research/abc-samples/derived-station-streams-local.json')

# ---- capture endpoints ----------------------------------------------------------------------------
BFF_URL = 'https://www.abc.net.au/core-next/api/collection/listen/radio?collectionId=%s&metaInMeta=false&rootMetaCollectionId=%s'
BFF_NATIONAL = ('12872264', '14139428')
BFF_STATES = [('NSW', '14126370'), ('ACT', '14126436'), ('NT', '14128062'), ('VIC', '14128070'),
              ('SA', '14128508'), ('TAS', '14128536'), ('QLD', '14128542'), ('WA', '14128996')]
BFF_STATE_ROOT = '14123276'
PAPI_URL = {'0': 'https://program.abcradio.net.au/api/v1/services.json',
            '100': 'https://program.abcradio.net.au/api/v1/services.json?offset=100'}
PAGE_URL = 'https://www.abc.net.au/listen/live/%s'
PLS_URL = 'https://streaming.abc-cdn.net.au/audio/ice/%s.pls'
ALLOWED_HOSTS = {'www.abc.net.au', 'program.abcradio.net.au', 'streaming.abc-cdn.net.au'}
USER_AGENT = 'SqueezeABCListen station-data capture (python)'
REQUEST_GAP = 1.0  # seconds between requests
TIMEOUT = 30
# PAPI fields the generator and t/20 read (the fixtures keep only these)
PAPI_KEEP = ['service_id', 'title', 'mini_synopsis', 'service_timezone', 'exclude_from_display', 'linked_services']

STATE_FILES = [st for st, _ in BFF_STATES]
ICECAST_RE = re.compile(r'https://abc\.streamguys1\.com/live/([^/]+)/icecast\.audio$')

# ---- hand-made decisions ----------------------------------------------------------------------------
# the national-collection card of each network and listed sport service (its logo)
NATIONAL_LINK = {
    'RN': 'https://www.abc.net.au/listen/radionational/',
    'NEWS': 'https://www.abc.net.au/listen/news',
    'GRANDSTAND': 'https://www.abc.net.au/listen/live/sport',
    'KIDSLISTEN': 'https://www.abc.net.au/kidslisten/',
    'RA_ML': 'https://www.abc.net.au/pacific/live/',
    'CLASSIC': 'https://www.abc.net.au/listen/classic/',
    'TRIPLEJ': 'https://www.abc.net.au/triplej/',
    'DOUBLEJ': 'https://www.abc.net.au/listen/doublej/',
    'COUNTRY': 'https://www.abc.net.au/listen/live/country/',
    'JAZZ': 'https://www.abc.net.au/listen/jazz/',
    'UNEARTHED': 'https://www.triplejunearthed.com/',
    'ITINERANT_THREE': 'https://abc.net.au/listen/live/sportextra',
    'ITINERANT_FOUR': 'https://www.abc.net.au/listen/live/cricket',
    'SPORT_WORLDCUP': 'https://abc.net.au/listen/live/worldcup',
    'ABC_AFL_RAPID': 'https://www.abc.net.au/listen/live/worldcuprapid',
    'SPORT_AFLW': 'https://www.abc.net.au/listen/live/aflw',
    'CLASSIC2': 'https://www.abc.net.au/listen/live/classic2',
    'H100': 'https://www.abc.net.au/triplejhottest/',
}
# sport live pages whose logo (radioHeadingPrepared.logoPrepared) is used by services without a card
PAGE_LOGO_SLUGS = ['afl', 'aflextra', 'sportrapid', 'bbl', 'wbbl', 'tennis', 'cricket', 'sportextra']
PAGE_LOGO_OF = {'ABCSPORTSYNC': 'sportrapid', 'SPORT_BBL': 'bbl', 'SPORT_WBBL': 'wbbl', 'SPORT_TENNIS': 'tennis',
                'SPORT_AFL': 'afl', 'SPORT_AFL_EXTRA': 'aflextra', 'GRANDSTAND_EXTRA': 'sportextra',
                'SPORT_CRICKET': 'cricket'}
# dedupe winners take the logo of the card ABC lists for their stream (their name is that card's event)
CARD_LOGO_OF = {'ITINERANT_ONE': 'SPORT_WORLDCUP', 'ITINERANT_TWO': 'SPORT_AFLW'}

NETWORKS = ['RN', 'NEWS', 'KIDSLISTEN', 'RA_ML', 'CLASSIC', 'TRIPLEJ', 'DOUBLEJ', 'COUNTRY', 'JAZZ', 'UNEARTHED', 'CLASSIC2', 'H100']
SPORT = ['GRANDSTAND', 'ITINERANT_THREE', 'ITINERANT_ONE', 'ITINERANT_TWO', 'SPORT_WORLDCUP', 'SPORT_AFLW',
         'SPORT_BBL', 'SPORT_WBBL', 'SPORT_TENNIS', 'GRANDSTAND_EXTRA', 'SPORT_AFL', 'SPORT_AFL_EXTRA', 'SPORT_CRICKET',
         'ABCSPORTSYNC', 'ABC_AFL_RAPID', 'ITINERANT_FOUR']
EVENT_ONLY = {'SPORT_BBL', 'SPORT_WBBL', 'SPORT_TENNIS', 'GRANDSTAND_EXTRA', 'SPORT_AFL', 'SPORT_AFL_EXTRA', 'SPORT_CRICKET'}
DUP = {'SPORT_WORLDCUP': 'ITINERANT_ONE', 'SPORT_AFLW': 'ITINERANT_TWO'}
EVENT_SLUG = {'SPORT_BBL': 'bbl', 'SPORT_WBBL': 'wbbl', 'SPORT_TENNIS': 'tennis'}
CITY_STATE = {'Adelaide': 'SA', 'Brisbane': 'QLD', 'Darwin': 'NT', 'Perth': 'WA'}
VARIANTS = [  # id, parent, city
    ('RN_SA', 'RN', 'Adelaide'), ('RN_QLD', 'RN', 'Brisbane'), ('RN_NT', 'RN', 'Darwin'), ('RN_WA', 'RN', 'Perth'),
    ('RA', 'RA_ML', None),
    ('CLASSIC_ADELAIDE', 'CLASSIC', 'Adelaide'), ('CLASSIC_BRISBANE', 'CLASSIC', 'Brisbane'),
    ('CLASSIC_DARWIN', 'CLASSIC', 'Darwin'), ('CLASSIC_PERTH', 'CLASSIC', 'Perth'),
    ('TRIPLEJ_ADELAIDE', 'TRIPLEJ', 'Adelaide'), ('TRIPLEJ_BRISBANE', 'TRIPLEJ', 'Brisbane'),
    ('TRIPLEJ_DARWIN', 'TRIPLEJ', 'Darwin'), ('TRIPLEJ_PERTH', 'TRIPLEJ', 'Perth'),
    ('DOUBLEJ_ADELAIDE', 'DOUBLEJ', 'Adelaide'), ('DOUBLEJ_BRISBANE', 'DOUBLEJ', 'Brisbane'),
    ('DOUBLEJ_DARWIN', 'DOUBLEJ', 'Darwin'), ('DOUBLEJ_PERTH', 'DOUBLEJ', 'Perth'),
]
HIDDEN = [('KIDSLISTEN_NT', 'Darwin'), ('KIDSLISTEN_QLD', 'Brisbane'), ('KIDSLISTEN_SA', 'Adelaide'), ('KIDSLISTEN_WA', 'Perth')]
MUSIC = {'TRIPLEJ': 'triplej', 'DOUBLEJ': 'doublej', 'UNEARTHED': 'unearthed', 'JAZZ': 'jazz', 'COUNTRY': 'country',
         'CLASSIC': 'classic', 'CLASSIC2': 'classic2', 'H100': 'h100', 'KIDSLISTEN': 'kidslisten'}
CAPITALS = {'LOCAL_SYDNEY', 'LOCAL_CANBERRA', 'LOCAL_DARWIN', 'LOCAL_MELBOURNE', 'LOCAL_ADELAIDE', 'LOCAL_HOBART',
            'LOCAL_BRISBANE', 'LOCAL_PERTH'}
# live-page slugs of other services' streams (the card is listed under that service)
LOCAL_ALIAS = {'katherine': 'LOCAL_DARWIN'}
# HLS masters not at https://streaming.abc-cdn.net.au/audio/hls/<hlsSlug>.m3u8 (for L5; L1 never plays them)
HLS = {
    'CLASSIC2': 'https://mediaserviceslive.akamaized.net/hls/live/2038317/classic2/index.m3u8',
    'LOCAL_WIDEBAY': 'https://mediaserviceslive.akamaized.net/hls/live/2038240/localwidebay/index.m3u8',
    'ABCSPORTSYNC': 'https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8',
    'ABC_AFL_RAPID': 'https://abc-hls.streamguys1.com/hls/sport-sync-afl/playlist.m3u8',
}
# .pls names missing from the research data (the probe gives their mount)
HLS_SLUG = {'LOCAL_WIDEBAY': 'localwidebay'}
# names that would be confused with another station's (said the same by a screen reader)
NAME_OVERRIDE = {
    'RA': 'Radio Australia (English)',  # RA_ML is "Radio Australia"
}

ORDER = ['id', 'name', 'group', 'network', 'state', 'city', 'capital', 'tz', 'slug', 'hlsSlug', 'mount', 'hls',
         'mediahub', 'logo', 'musicStation', 'hlsOnly', 'eventOnly', 'dupOf', 'synopsis']


class InputError(Exception):
    pass


def warn(msg):
    print('gen-station-data: warning: ' + msg, file=sys.stderr)


# ---- inputs ----------------------------------------------------------------------------------------

def read_file(rel):
    with open(os.path.join(ROOT, rel), 'rb') as f:
        return f.read()


def load_inputs(read):
    """All generator inputs, read through read(relative path) -> bytes."""
    def js(rel):
        return json.loads(read(rel).decode('utf-8'))

    inp = {'papi': {}, 'derived': {}, 'probe': {}, 'cards': {}}
    for page in PAPI_PAGES:
        for it in js(PAPI_FILE % page)['items']:
            inp['papi'][it['service_id'].upper()] = it
    for rel in DERIVED_FILES:
        for st in js(rel)['stations']:
            inp['derived'].setdefault(st['papiServiceId'], st)  # first wins (Katherine repeats LOCAL_DARWIN)
    for line in read(PROBE_FILE).decode('utf-8').splitlines():
        slug, code, file1 = (line.split('\t') + ['', ''])[:3]
        if code == '200' and file1:
            m = ICECAST_RE.match(file1)
            if not m:
                raise InputError('%s: %s File1 is not a StreamGuys Icecast URL: %s' % (PROBE_FILE, slug, file1))
            inp['probe'][slug] = m.group(1)
    inp['cards']['national'] = js(BFF_NATIONAL_FILE)['collection']['items']
    for st in STATE_FILES:
        inp['cards'][st] = js(BFF_STATE_FILE % st)['collection']['items']
    cap = js(CAPTURE_JSON)
    inp['captured'] = cap['captured']
    inp['pageLogos'] = cap['pageLogos']
    inp['template'] = read(TEMPLATE).decode('utf-8')
    return inp


# ---- records ---------------------------------------------------------------------------------------

def path_parts(link):
    p = re.sub(r'^https?://[^/]+', '', link).split('#')[0].split('?')[0].strip('/')
    return p.split('/')


def clean(s):
    if s is None:
        return None
    s = re.sub(r'\s+', ' ', s).strip()
    return s or None


def build_records(inp):
    papi, derived, probe = inp['papi'], inp['derived'], inp['probe']

    logo_by_link = {c['articleLink']: c['cardImagePrepared']['imgSrc'] for c in inp['cards']['national']}
    logo = {}
    for sid, link in NATIONAL_LINK.items():
        if link not in logo_by_link:
            raise InputError('no national-collection card %s (for %s)' % (link, sid))
        logo[sid] = logo_by_link[link]
    for sid, other in CARD_LOGO_OF.items():
        logo[sid] = logo[other]
    for sid, slug in PAGE_LOGO_OF.items():
        logo[sid] = inp['pageLogos'][slug]

    local_by_slug = dict(LOCAL_ALIAS)
    for sid, st in derived.items():
        if sid.startswith('LOCAL_'):
            local_by_slug[path_parts(st['page'])[-1]] = sid

    locals_ = []  # (id, state, logo), in collection order; a station listed twice is kept once
    seen = set()
    for state in STATE_FILES:
        for c in inp['cards'][state]:
            slug = path_parts(c['articleLink'])[-1]
            if slug not in local_by_slug:
                raise InputError('%s card %s is not a known local station' % (state, c['articleLink']))
            sid = local_by_slug[slug]
            if sid in seen:
                continue
            seen.add(sid)
            locals_.append((sid, state, c['cardImagePrepared']['imgSrc']))

    def mediahub_of(sid):
        aac = (derived.get(sid) or {}).get('aac_or_pls_from_page')
        return aac if aac and 'mediahubaustralia.com' in aac else None

    def hls_slug_of(sid):
        if sid in HLS_SLUG:
            return HLS_SLUG[sid]
        s = (derived.get(sid) or {}).get('hls_slug')
        return s.split()[0] if s else None

    def mount_of(sid, hls_slug):
        ice = (derived.get(sid) or {}).get('icecast')
        if ice:
            return ICECAST_RE.match(ice).group(1)
        if hls_slug and hls_slug in probe:
            return probe[hls_slug]
        return None

    def page_slug(sid):
        page = (derived.get(sid) or {}).get('page')
        if not page:
            return None
        parts = path_parts(page)
        return parts[-2] if parts[-1] == 'live' else parts[-1]  # /listen/doublej/live

    records = []

    def rec(sid, group, network, **kw):
        if sid not in papi:
            raise InputError('%s is not a PAPI service' % sid)
        p = papi[sid]
        hs = kw.pop('hlsSlug', 'auto')
        if hs == 'auto':
            hs = hls_slug_of(sid)
        r = {
            'id': sid,
            'name': NAME_OVERRIDE.get(sid) or clean(p['title']),
            'group': group,
            'network': network,
            'state': kw.pop('state', None),
            'tz': p['service_timezone'],
            'slug': kw.pop('slug', 'auto'),
            'hlsSlug': hs,
            'mount': mount_of(sid, hs),
            'mediahub': mediahub_of(sid),
            'logo': kw.pop('logo', None) or logo.get(sid),
            'musicStation': MUSIC.get(sid),
            'hlsOnly': 0,
            'eventOnly': 1 if sid in EVENT_ONLY else 0,
            'synopsis': clean(p.get('mini_synopsis')),
        }
        if r['slug'] == 'auto':
            r['slug'] = page_slug(sid) or EVENT_SLUG.get(sid)
        if not r['mount'] and not r['eventOnly']:
            r['hlsOnly'] = 1
        if sid in HLS:
            r['hls'] = HLS[sid]
        if sid in DUP:
            r['dupOf'] = DUP[sid]
        r.update(kw)
        if not (r['logo'] and 'cropW=' in r['logo']):
            raise InputError('%s: no logo with crop params' % sid)
        if not r['tz']:
            raise InputError('%s: no PAPI service_timezone' % sid)
        records.append(r)

    for sid in NETWORKS:
        rec(sid, 'network', sid)
    for sid in SPORT:
        rec(sid, 'sport', 'SPORT')
    for sid, state, lg in locals_:
        kw = {'state': state, 'logo': lg}
        if sid in CAPITALS:
            kw['capital'] = 1
        rec(sid, 'local', 'LOCAL', **kw)
    for sid, parent, city in VARIANTS:
        kw = {'slug': None, 'logo': logo[parent]}
        if city:
            kw['city'] = city
            kw['state'] = CITY_STATE[city]
        rec(sid, 'variant', parent, **kw)
    for sid, city in HIDDEN:
        rec(sid, 'hidden', 'KIDSLISTEN', slug=None, logo=logo['KIDSLISTEN'], city=city, state=CITY_STATE[city])

    return records


def check_against_probe(records, probe):
    for r in records:
        if r.get('hlsSlug') in probe and r.get('mount') != probe[r['hlsSlug']]:
            warn('%s: mount %s, but the probe of %s.pls says %s' % (r['id'], r.get('mount'), r['hlsSlug'], probe[r['hlsSlug']]))
        if r.get('hlsSlug') and r.get('mount') and r['hlsSlug'] not in probe:
            warn('%s: %s.pls has no Icecast File1 in the probe' % (r['id'], r['hlsSlug']))


# ---- output ----------------------------------------------------------------------------------------

def perl_val(v):
    if v is None:
        return 'undef'
    if isinstance(v, int):
        return str(v)
    if any(ord(ch) > 127 for ch in v):
        # keep the file ASCII: \x{...} escapes in a double-quoted string
        esc = ''.join(('\\x{%X}' % ord(ch)) if ord(ch) > 127 else ('\\' + ch if ch in '"\\$@' else ch) for ch in v)
        return '"' + esc + '"'
    return "'" + v.replace('\\', '\\\\').replace("'", "\\'") + "'"


def render(records, inp):
    blocks = []
    for r in records:
        lines = []
        for k in ORDER:
            if k not in r:
                continue
            v = r[k]
            if v is None and k not in ('id', 'name', 'group', 'network', 'tz', 'logo'):
                continue
            if k in ('hlsOnly', 'eventOnly') and not v:
                continue
            lines.append('\t\t%s => %s,' % (k, perl_val(v)))
        blocks.append('\t{\n' + '\n'.join(lines) + '\n\t},')

    template = inp['template']
    for marker in ('@CAPTURED@', '@RECORDS@\n'):
        if template.count(marker) != 1:
            raise InputError('%s must hold %r exactly once' % (TEMPLATE, marker))
    return template.replace('@CAPTURED@', inp['captured']).replace('@RECORDS@\n', '\n'.join(blocks) + '\n')


def generate(read=read_file):
    inp = load_inputs(read)
    records = build_records(inp)
    check_against_probe(records, inp['probe'])
    counts = {}
    for r in records:
        counts[r['group']] = counts.get(r['group'], 0) + 1
    summary = '%d records (%s)' % (len(records), ', '.join('%s %d' % kv for kv in counts.items()))
    return render(records, inp), summary


# ---- capture ---------------------------------------------------------------------------------------

_last_request = [0.0]


def fetch(url):
    """GET an ABC public URL, politely. -> (HTTP status, body bytes); raises on network errors."""
    u = urllib.parse.urlsplit(url)
    if u.scheme != 'https' or u.hostname not in ALLOWED_HOSTS:
        raise InputError('refusing to fetch %s (not an allowed ABC host)' % url)
    wait = _last_request[0] + REQUEST_GAP - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            status, body = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    finally:
        _last_request[0] = time.monotonic()
    print('%s %s' % (status, url), file=sys.stderr)
    return status, body


def fetch_ok(url):
    status, body = fetch(url)
    if status != 200:
        raise InputError('HTTP %s from %s' % (status, url))
    return body


def bff_collection(cid, root):
    body = fetch_ok(BFF_URL % (cid, root))
    items = json.loads(body.decode('utf-8')).get('collection', {}).get('items')
    if not isinstance(items, list) or not items:
        raise InputError('BFF collection %s has no cards' % cid)
    return body  # stored as served


def papi_trimmed(url):
    d = json.loads(fetch_ok(url).decode('utf-8'))
    items = []
    for it in d['items']:
        t = {k: it[k] for k in PAPI_KEEP if k in it}
        if 'linked_services' in t:
            t['linked_services'] = [{k: ls[k] for k in ('service_id', 'type') if k in ls} for ls in t['linked_services']]
        items.append(t)
    d['items'] = items
    return (json.dumps(d, ensure_ascii=False, indent=1) + '\n').encode('utf-8')


def page_logo(html):
    """radioHeadingPrepared.logoPrepared.imgSrc from a live page's __NEXT_DATA__."""
    m = re.search(r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        raise InputError('no __NEXT_DATA__')
    for comp in json.loads(m.group(1))['props']['pageProps']['data']['componentsContent']:
        heading = (comp.get('componentProps') or {}).get('radioHeadingPrepared')
        if heading:
            return heading['logoPrepared']['imgSrc']
    raise InputError('no radioHeadingPrepared')


def probe_line(slug):
    status, body = fetch(PLS_URL % slug)
    file1 = ''
    for line in body.decode('latin-1').split('\n'):
        if line.startswith('File1='):
            file1 = line.replace('\r', '').split('=', 1)[1]
            break
    return '%s\t%s\t%s\n' % (slug, status, file1)


def capture():
    """Fetch fresh inputs; returns {relative path: bytes}. Nothing is written here."""
    out = {BFF_NATIONAL_FILE: bff_collection(*BFF_NATIONAL)}
    for st, cid in BFF_STATES:
        out[BFF_STATE_FILE % st] = bff_collection(cid, BFF_STATE_ROOT)
    for page in PAPI_PAGES:
        out[PAPI_FILE % page] = papi_trimmed(PAPI_URL[page])

    logos = {}
    for slug in PAGE_LOGO_SLUGS:
        try:
            logos[slug] = page_logo(fetch_ok(PAGE_URL % slug).decode('utf-8', 'replace'))
        except (InputError, KeyError, TypeError, ValueError) as e:
            raise InputError('live page %s: %s' % (slug, e))
    cap = {
        '_note': 'Written by scripts/gen-station-data.py --capture: the capture date and the logo '
                 '(radioHeadingPrepared.logoPrepared.imgSrc) of each sport live page /listen/live/<slug>.',
        'captured': datetime.date.today().isoformat(),
        'pageLogos': logos,
    }
    out[CAPTURE_JSON] = (json.dumps(cap, ensure_ascii=False, indent=1) + '\n').encode('utf-8')

    # every catalogue .pls name, from the records these inputs give (the probe only adds mounts)
    out[PROBE_FILE] = b''
    inp = load_inputs(lambda rel: out[rel] if rel in out else read_file(rel))
    slugs = sorted({r['hlsSlug'] for r in build_records(inp) if r.get('hlsSlug')})
    out[PROBE_FILE] = ''.join(probe_line(s) for s in slugs).encode('utf-8')
    return out


# ---- main ------------------------------------------------------------------------------------------

def main(argv):
    args = argv[1:]
    if args not in ([], ['--check'], ['--capture']):
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    try:
        if args == ['--capture']:
            files = capture()
            for rel, data in files.items():
                with open(os.path.join(ROOT, rel), 'wb') as f:
                    f.write(data)
                print('wrote %s' % rel, file=sys.stderr)
        text, summary = generate()
    except (InputError, OSError, KeyError, ValueError) as e:
        print('gen-station-data: %s: %s' % (type(e).__name__, e), file=sys.stderr)
        return 1

    data = text.encode('utf-8')
    if args == ['--check']:
        if read_file(OUT) != data:
            print('gen-station-data: %s differs from what the inputs generate; run scripts/gen-station-data.py' % OUT, file=sys.stderr)
            return 1
        print('ok   %s matches its inputs: %s' % (OUT, summary))
        return 0
    with open(os.path.join(ROOT, OUT), 'wb') as f:
        f.write(data)
    print('wrote %s: %s' % (OUT, summary))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
