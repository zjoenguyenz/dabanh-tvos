#!/usr/bin/env python3
"""DaBanhTV 1.5.1 FL-361 merge harness.

Replicates TeamNameNorm.pipeline (the SHARED pipeline behind
groupKey/canonicalKey — they differ only in the women's-marker
edge strip) + MatchPairKey + the MatchStateStore binding lookup
(own date key, then +-1 day seam with <=3h kickoff agreement).
All tables are PARSED from the Swift source so the replica
cannot drift from the code under test.

SWIFT_PATH env var selects the TeamNameNorm.swift to parse
(used to re-run the BEFORE numbers against the pre-edit table).

Usage: harness.py
"""
import json, os, re, sys, unicodedata, urllib.request
from datetime import datetime, timedelta, timezone

SWIFT_PATH = os.environ.get(
    'SWIFT_PATH', '/home/hatch/workspace/dabanh-tvos/DaBanh/TeamNameNorm.swift')
SWIFT = open(SWIFT_PATH).read()
ICT = timezone(timedelta(hours=7))

def parse_swift_set(name):
    m = re.search(name + r': Set<String> = \[(.*?)\]', SWIFT, re.S)
    return set(re.findall(r'"([^"]+)"', m.group(1)))

def parse_swift_dict(name):
    m = re.search(name + r': \[String: String\] = \[(.*?)\]', SWIFT, re.S)
    return dict(re.findall(r'"([^"]+)":\s*"([^"]+)"', m.group(1)))

FILLER = parse_swift_set('fillerTokens')
TOKEN_ALIASES = parse_swift_dict('tokenAliases')
WHOLE = parse_swift_dict('wholeNameAliases')
WOMEN = parse_swift_set('womenMarkers')
CITY_Q = parse_swift_set('cityQualifiers')
STATE_CODES = parse_swift_set('stateSuffixTokens')
GENERIC = FILLER | WOMEN | {'al', 'el', 'the'}

def crests_norm(s):
    s = s.lower()
    for a, b in [('ø', 'o'), ('æ', 'ae'), ('œ', 'oe'), ('ß', 'ss'),
                 ('ł', 'l'), ('đ', 'd'), ('ð', 'd'), ('þ', 'th')]:
        s = s.replace(a, b)
    s = unicodedata.normalize('NFD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r'[^a-z0-9 ]', ' ', s)
    return re.sub(r'\s+', ' ', s).strip()

def is_age_token(t):
    return (len(t) in (2, 3) and t.startswith('u')
            and t[1:].isdigit())

def drop_state_suffix(joined):
    toks = joined.split(' ')
    if len(toks) >= 2 and toks[-1] in STATE_CODES:
        toks = toks[:-1]
    return ' '.join(toks)

def pipeline(name, strip_women):
    tokens = crests_norm(name).split(' ') if crests_norm(name) else []
    # Step 2: leading VN club decoration.
    if len(tokens) >= 5 and tokens[:5] == ['cau', 'lac', 'bo', 'bong', 'da']:
        tokens = tokens[5:]
    elif len(tokens) >= 3 and tokens[:3] == ['cau', 'lac', 'bo']:
        tokens = tokens[3:]
    # Step 3: age marker extract (re-attached at the end).
    age, stem, i = None, [], 0
    while i < len(tokens):
        t = tokens[i]
        if is_age_token(t):
            if age is None:
                age = t
            i += 1
            continue
        if (t == 'u' and i + 1 < len(tokens)
                and len(tokens[i + 1]) <= 2 and tokens[i + 1].isdigit()):
            if age is None:
                age = 'u' + tokens[i + 1]
            i += 2
            continue
        stem.append(t)
        i += 1
    # Steps 4-5: filler + numeric drop, token aliases.
    stem = [TOKEN_ALIASES.get(t, t) for t in stem
            if t not in FILLER and not t.isdigit()]
    # Step 6: women's markers off the edges (canonical only).
    if strip_women:
        while stem and stem[0] in WOMEN:
            stem.pop(0)
        while stem and stem[-1] in WOMEN:
            stem.pop()
    # Step 7: trailing city qualifiers with the generic guard.
    while (len(stem) >= 2 and stem[-1] in CITY_Q
           and any(t not in GENERIC for t in stem[:-1])):
        stem.pop()
    # Step 8: aliases -> state suffix -> aliases.
    joined = ' '.join(stem)
    joined = WHOLE.get(joined, joined)
    joined = drop_state_suffix(joined)
    joined = WHOLE.get(joined, joined)
    if age:
        joined = (joined + ' ' + age) if joined else age
    return joined

def canonical(raw):
    return pipeline(raw, strip_women=True)

def group_key(raw):
    return pipeline(raw, strip_women=False)

def pair_key(home, away):
    a, b = canonical(home), canonical(away)
    if not a or not b:
        return None
    return ' vs '.join(sorted([a, b]))

def stamp_key(dt):
    return dt.astimezone(ICT).strftime('%Y%m%d')

# ---------- playlist ----------
TITLE_RE = re.compile(r'(\d{1,2}):(\d{2})\s+(\d{1,2})/(\d{1,2})')
def parse_playlist(path):
    chans = []
    for line in open(path, encoding='utf-8'):
        if not line.startswith('#EXTINF'):
            continue
        title = line.split(',', 1)[1].strip() if ',' in line else ''
        m = TITLE_RE.search(title)
        if not m or ' vs ' not in title:
            continue
        hh, mm, dd, mo = map(int, m.groups())
        ko = datetime(2026, mo, dd, hh, mm, tzinfo=ICT)
        clean = TITLE_RE.sub('', title)
        clean = re.sub(r'[🟢⚽🔴🟡]', '', clean)
        clean = re.sub(r'\s+', ' ', clean).strip()
        mmatch = re.match(r'^(.*?)\s+vs\s+(.*?)$', clean)
        if not mmatch:
            continue
        home, away = mmatch.group(1), mmatch.group(2)
        away = re.sub(r'\(.*?\)|\[.*?\]', '', away).strip()
        home = re.sub(r'\(.*?\)|\[.*?\]', '', home).strip()
        chans.append({'home': home, 'away': away, 'ko': ko, 'title': title})
    groups = {}
    for c in chans:
        gk_h, gk_a = group_key(c['home']), group_key(c['away'])
        if not gk_h or not gk_a:
            continue
        gk = ' vs '.join(sorted([gk_h, gk_a]))
        groups.setdefault((gk, stamp_key(c['ko'])), []).append(c)
    return groups, chans

# ---------- feeds ----------
def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))

SLUGS = ["eng.1", "eng.2", "esp.1", "esp.2", "ita.1", "ita.2",
         "fra.1", "fra.2", "ger.1", "ger.2", "bra.1",
         "uefa.champions", "uefa.europa", "uefa.europa.conf",
         "uefa.womens.champions", "fifa.worldq.uefa"]

CACHE = '/home/hatch/workspace/dabanh-tvos/harness-151/feed-states.json'

def feed_states():
    if os.path.exists(CACHE):
        raw = json.load(open(CACHE))
        return {k: (v[0], datetime.fromisoformat(v[1]), v[2])
                for k, v in raw.items()}
    states = {}
    for day in ('20261120', '20261121', '20261122'):
        for slug in SLUGS:
            try:
                d = fetch(f'https://site.api.espn.com/apis/site/v2/sports/soccer/{slug}/scoreboard?dates={day}')
            except Exception:
                continue
            for e in d.get('events') or []:
                try:
                    comp = (e.get('competitions') or [{}])[0]
                    cs = {c['homeAway']: c for c in comp.get('competitors') or []}
                    h, a = cs['home']['team']['displayName'], cs['away']['team']['displayName']
                    ko = datetime.fromisoformat(e['date'].replace('Z', '+00:00'))
                except Exception:
                    continue
                pk = pair_key(h, a)
                if pk:
                    states[pk + '|' + stamp_key(ko)] = (pk, ko, 'espn')
    for day in ('20261121', '20261122'):
        try:
            d = fetch(f'https://www.fotmob.com/api/data/matches?date={day}')
        except Exception:
            continue
        for lg in d.get('leagues') or []:
            for mt in lg.get('matches') or []:
                try:
                    h = mt['home']['name']; a = mt['away']['name']
                    t = (mt.get('timeTS') or mt.get('status', {}).get('utcTime'))
                    if isinstance(t, (int, float)):
                        ko = datetime.fromtimestamp(t / 1000 if t > 1e12 else t, tz=timezone.utc)
                    else:
                        ko = datetime.fromisoformat(str(t).replace('Z', '+00:00'))
                except Exception:
                    continue
                pk = pair_key(h, a)
                if pk:
                    states.setdefault(pk + '|' + stamp_key(ko), (pk, ko, 'fotmob'))
    json.dump({k: (v[0], v[1].isoformat(), v[2])
               for k, v in states.items()}, open(CACHE, 'w'))
    return states

def main():
    groups, chans = parse_playlist('/home/hatch/workspace/dabanh-tvos/harness-151/tttt.m3u')
    states = feed_states()
    bound, unbound_with_feed, unbound_no_feed = 0, [], 0
    bound_channels = 0
    for (gk, dk), members in sorted(groups.items()):
        ko = members[0]['ko']
        hit = False
        for c in members:
            pk = pair_key(c['home'], c['away'])
            if not pk:
                continue
            if pk + '|' + stamp_key(ko) in states:
                hit = True; break
            for delta in (-86400, 86400):
                k2 = pk + '|' + stamp_key(ko + timedelta(seconds=delta))
                if k2 in states and abs((states[k2][1] - ko).total_seconds()) <= 3 * 3600:
                    hit = True; break
            if hit:
                break
        if hit:
            bound += 1
            bound_channels += len(members)
            continue
        near = []
        want = set()
        for c in members:
            want.add(canonical(c['home'])); want.add(canonical(c['away']))
        for (pk, fko, src) in states.values():
            if abs((fko - ko).total_seconds()) > 3 * 3600:
                continue
            sides = pk.split(' vs ')
            if len(sides) == 2 and len(want & set(sides)) == 1:
                near.append((pk, src))
        if near:
            unbound_with_feed.append((members[0], near))
        else:
            unbound_no_feed += 1
    print(f'table source: {SWIFT_PATH}')
    print(f'playlist channels parsed: {len(chans)}')
    print(f'fixture groups: {len(groups)}')
    print(f'BOUND groups: {bound}  (channels in bound groups: {bound_channels})')
    print(f'UNBOUND but feed fixture at same instant: {len(unbound_with_feed)}')
    print(f'unbound, no feed fixture near: {unbound_no_feed}')
    print()
    for c, near in unbound_with_feed:
        pk = pair_key(c['home'], c['away'])
        print(f"PLAYLIST {c['home']} vs {c['away']}  -> pair '{pk}'")
        for npk, src in near[:4]:
            print(f"   feed[{src}]: '{npk}'")
    print()
    print('SPECIMENS (canonical keys):')
    for raw in ['RC Strasbourg Alsace', 'Strasbourg', 'Stade Brestois 29',
                'Brest', 'Lille OSC', 'LOSC Lille', 'Lille', 'Lyonnais',
                'Olympique Lyonnais', 'Lyon', 'RC Celta', 'Celta',
                'Celta Vigo', 'Real Betis Balompie', 'Real Betis',
                'AS Monaco', 'Monaco', 'AJ Auxerre', 'Auxerre',
                'Inter Milan', 'Internazionale', 'Inter']:
        print(f'  {raw!r:28} -> {canonical(raw)!r}')
    print()
    print('SPECIMEN GROUPS (playlist groupKey pairs):')
    for h, a in [('Lille OSC', 'Lyonnais'), ('LOSC Lille', 'Lyon'),
                 ('RC Strasbourg Alsace', 'Stade Brestois 29'),
                 ('Real Madrid', 'Celta'), ('Real Madrid', 'RC Celta'),
                 ('Real Madrid', 'Celta Vigo')]:
        gk = ' vs '.join(sorted([group_key(h), group_key(a)]))
        print(f'  {h} vs {a}  -> group {gk!r}')

if __name__ == '__main__':
    main()
