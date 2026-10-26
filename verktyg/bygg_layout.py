"""Bygger kartans layout: SVG från transitmap och vagnarnas vägar längs linjerna.

  python3 verktyg/bygg_layout.py octi.json data/tram colors.json transitmap layout/

Resultatet (layout/karta.svg och layout/layout.json) checkas in. Servern läser
det och behöver varken LOOM eller transitmap. Kör om när linjenätet ändras.

Varje linje får en tillfällig unik färg när transitmap ritar, så att varje
ritad polyline kan knytas till sin linje. Vagnarnas väg mellan två hållplatser
är kortaste vägen längs just den linjens ritade polylines.
"""
import heapq
import json
import math
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

octi_path, gtfs_dir, colors_path, transitmap, ut = sys.argv[1:6]
ut = Path(ut)
ut.mkdir(parents=True, exist_ok=True)

octi = json.load(open(octi_path))
farger = json.load(open(colors_path))
farger.setdefault("9", {"backgroundColor": "#d0edfb"})
farger.setdefault("13", {"backgroundColor": "#e6a1c4"})

# 1. Tillfälliga färger, en per linje-id.
tmp_till_linje = {}
for f in octi["features"]:
    for l in f["properties"].get("lines", []):
        if l["id"] not in tmp_till_linje.values():
            tmp = f"{len(tmp_till_linje) + 1:02x}00ff"
            tmp_till_linje.setdefault(tmp, l["id"])
id_till_tmp = {v: k for k, v in tmp_till_linje.items()}
id_till_etikett = {}
for f in octi["features"]:
    for l in f["properties"].get("lines", []):
        l["color"] = id_till_tmp[l["id"]]
        id_till_etikett[l["id"]] = l["label"]
svg = subprocess.run([transitmap, "-l", "--line-width", "44", "--line-spacing", "16", "--outline-width", "5", "--line-label-textsize", "70", "--station-label-textsize", "110"],
                     input=json.dumps(octi), capture_output=True, text=True, check=True).stdout

# 2. Kartans koordinatsystem: webbmercator, skalad och förskjuten.
def merc(lon, lat):
    return lon * 20037508.34 / 180, math.log(math.tan((90 + lat) * math.pi / 360)) * 20037508.34 / math.pi

m = re.search(r'height="([\d.]+)" latlng-box="([^"]+)" viewBox="0 0 ([\d.]+) ([\d.]+)"', svg)
H, (lon0, lat0, lon1, lat1), W = float(m.group(1)), map(float, m.group(2).split(",")), float(m.group(3))
X0, Y0 = merc(lon0, lat0)
X1, Y1 = merc(lon1, lat1)
skala = (W - H) / ((X1 - X0) - (Y1 - Y0))
pad = (W - (X1 - X0) * skala) / 2

def till_svg(lon, lat):
    x, y = merc(lon, lat)
    return (x - X0) * skala + pad, (Y1 - y) * skala + pad

# Kontroll mot stationernas polygoner.
poly = [[tuple(map(float, p.split(","))) for p in pts.split()]
        for pts in re.findall(r'class="station-poly"[^>]*points="([^"]+)"', svg)]
mitt = [(sum(p[0] for p in pp) / len(pp), sum(p[1] for p in pp) / len(pp)) for pp in poly]
stationer = []
for f in octi["features"]:
    p = f["properties"]
    if f["geometry"]["type"] == "Point" and p.get("station_label"):
        x, y = till_svg(*f["geometry"]["coordinates"])
        stationer.append((p["station_label"], x, y))
fel = sorted(min(math.dist((x, y), c) for c in mitt) for _, x, y in stationer)
print(f"stationer {len(stationer)}, avvikelse mot polygoner: median {fel[len(fel)//2]:.2f}, max {fel[-1]:.2f}")

# 3. Varje linjes ritade polylines som en graf.
STEG = 1.5
def tathet(pts):
    ut_ = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        n = max(1, int(math.dist(a, b) / STEG))
        ut_ += [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(1, n + 1)]
    return ut_

grafer = defaultdict(lambda: {"pts": [], "adj": defaultdict(list), "rut": defaultdict(list)})
def nod(g, p, eps=0.8):
    rx, ry = int(p[0] // 2), int(p[1] // 2)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for i in g["rut"][(rx + dx, ry + dy)]:
                if math.dist(g["pts"][i], p) < eps:
                    return i
    g["pts"].append(p)
    g["rut"][(rx, ry)].append(len(g["pts"]) - 1)
    return len(g["pts"]) - 1

antal = 0
for m_ in re.finditer(r'<polyline class="([^"]*)" points="([^"]+)" style="([^"]+)"', svg):
    klass, pts, stil = m_.groups()
    if "outline" in klass or not ("transit-edge" in klass or "inner-geom" in klass):
        continue
    farg = re.search(r"stroke:#([0-9a-f]{6})", stil).group(1)
    etikett = id_till_etikett[tmp_till_linje[farg]]
    g = grafer[etikett]
    p = tathet([tuple(map(float, q.split(","))) for q in pts.split()])
    ids = [nod(g, q) for q in p]
    for a, b in zip(ids, ids[1:]):
        if a != b:
            d = math.dist(g["pts"][a], g["pts"][b])
            g["adj"][a].append((b, d))
            g["adj"][b].append((a, d))
    antal += 1
print(f"polylines {antal}, linjer {sorted(grafer)}")

# Vid en del hållplatser byter linjen plats i knippet och de ritade bitarna
# möts inte. Knyt ihop lösa ändar som ligger nära varandra.
BRYGGA = 40
broar = 0
for g in grafer.values():
    andar = [i for i in range(len(g["pts"])) if len(g["adj"][i]) == 1]
    for n, i in enumerate(andar):
        for j in andar[n + 1:]:
            d = math.dist(g["pts"][i], g["pts"][j])
            if 0 < d < BRYGGA:
                g["adj"][i].append((j, d))
                g["adj"][j].append((i, d))
                broar += 1
print(f"broar mellan lösa ändar: {broar}")

def narmast(g, p, maxd=60):
    best, bd = None, maxd
    for i, q in enumerate(g["pts"]):
        d = math.dist(p, q)
        if d < bd:
            best, bd = i, d
    return best

def vag(g, a, b, gräns):
    dist, fore, ko = {a: 0}, {}, [(0, a)]
    while ko:
        d, u = heapq.heappop(ko)
        if u == b:
            break
        if d > gräns or d > dist.get(u, 1e18):
            continue
        for v, w in g["adj"][u]:
            nd = d + w
            if nd < dist.get(v, 1e18):
                dist[v], fore[v] = nd, u
                heapq.heappush(ko, (nd, v))
    if b not in dist:
        return None
    p, u = [b], b
    while u != a:
        u = fore[u]
        p.append(u)
    return [g["pts"][i] for i in reversed(p)], dist[b]

def rdp(pts, tol=0.3):
    if len(pts) < 3:
        return pts
    a, b = pts[0], pts[-1]
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy) or 1e-9
    dmax, idx = 0, 0
    for i in range(1, len(pts) - 1):
        d = abs(dy * pts[i][0] - dx * pts[i][1] + b[0] * a[1] - b[1] * a[0]) / n
        if d > dmax:
            dmax, idx = d, i
    if dmax <= tol:
        return [a, b]
    return rdp(pts[:idx + 1], tol)[:-1] + rdp(pts[idx:], tol)

# 4. Hållplatsernas anslutningspunkter per linje, och vägar mellan dem.
pos_per_namn = defaultdict(list)
for namn, x, y in stationer:
    pos_per_namn[namn].append((x, y))
ansl = {}
def anslutningar(linje, namn):
    if (linje, namn) not in ansl:
        g = grafer.get(linje)
        ansl[(linje, namn)] = [i for i in (narmast(g, p) for p in pos_per_namn.get(namn, [])) if i is not None] if g else []
    return ansl[(linje, namn)]

hopp, hopp_id = [], {}
saknas = defaultdict(int)
def hopp_for(linje, a, b):
    nyckel = (linje, a, b)
    if nyckel in hopp_id:
        return hopp_id[nyckel]
    g = grafer.get(linje)
    bast = None
    for i in anslutningar(linje, a):
        for j in anslutningar(linje, b):
            rak = math.dist(g["pts"][i], g["pts"][j])
            r = vag(g, i, j, rak * 4 + 200)
            if r and (bast is None or r[1] < bast[1]):
                bast = r
    if bast is None:
        saknas[(linje, a, b)] += 1
        pa, pb = pos_per_namn.get(a), pos_per_namn.get(b)
        if not (pa and pb):
            hopp_id[nyckel] = -1
            return -1
        bast = (min(((p, q) for p in pa for q in pb), key=lambda pq: math.dist(*pq)), 0)
    pts = rdp(bast[0])
    hopp.append([round(c, 1) for p in pts for c in p])
    hopp_id[nyckel] = len(hopp) - 1
    return hopp_id[nyckel]

# Alla par av hållplatser som följer på varandra någon gång i tidtabellen.
import csv
def rader(f):
    with open(Path(gtfs_dir) / f, encoding="utf-8") as fh:
        yield from csv.DictReader(fh)
linje_for_route = {r["route_id"]: r["route_short_name"] for r in rader("routes.txt")}
linje_for_tur = {r["trip_id"]: linje_for_route[r["route_id"]] for r in rader("trips.txt")}
stopp = {r["stop_id"]: r for r in rader("stops.txt")}
def namn(stop_id):
    s_ = stopp[stop_id]
    return stopp[s_["parent_station"]]["stop_name"] if s_.get("parent_station") else s_["stop_name"]
per_tur = defaultdict(list)
for r in rader("stop_times.txt"):
    per_tur[r["trip_id"]].append((int(r["stop_sequence"]), namn(r["stop_id"])))
par = set()
for tur, st in per_tur.items():
    st.sort()
    par |= {(linje_for_tur[tur], a[1], b[1]) for a, b in zip(st, st[1:])}
hopp_ut = {}
for linje, a, b in sorted(par):
    i = hopp_for(linje, a, b)
    if i >= 0 and (linje, a, b) not in saknas:
        hopp_ut[f"{linje}|{a}|{b}"] = hopp[i]
linjer = sorted({l for l, _, _ in par}, key=lambda s_: (not s_.isdigit(), s_.zfill(3)))
print(f"par {len(par)}, vägar längs linjen {len(hopp_ut)}, saknas {len(saknas)}")
for k in sorted(saknas)[:20]:
    print("  saknas:", k)

# 5. Kartan med riktiga färger.
riktig = {}
for tmp, lid in tmp_till_linje.items():
    riktig[tmp] = farger[id_till_etikett[lid]]["backgroundColor"].lstrip("#").lower()
klass_till_linje = {}
for m_ in re.finditer(r'<polyline class="[^"]*?(line-\d+)" points="[^"]+" style="[^"]*stroke:#([0-9a-f]{6})', svg):
    if m_.group(2) in tmp_till_linje:
        klass_till_linje[m_.group(1)] = id_till_etikett[tmp_till_linje[m_.group(2)]]
svg_ut = re.sub(r"#([0-9a-f]{6})", lambda m_: "#" + riktig.get(m_.group(1), m_.group(1)), svg)
svg_ut = re.sub(r"\b(line-\d+)\b(?!label)", lambda m_: "L L-" + klass_till_linje.get(m_.group(1), "okand"), svg_ut)
svg_ut = re.sub(r"(\d+\.\d)\d+", r"\1", svg_ut)
svg_ut = svg_ut[svg_ut.index("<svg"):]
(ut / "karta.svg").write_text(svg_ut)
json.dump({
    "storlek": [W, H],
    "linjer": [{"namn": l, "farg": farger[l]["backgroundColor"], "text": farger[l].get("foregroundColor", "#000")}
               for l in linjer],
    "stationer": [[n, round(x, 1), round(y, 1)] for n, x, y in stationer],
    "hopp": hopp_ut,
}, open(ut / "layout.json", "w"), ensure_ascii=False, separators=(",", ":"))
print("storlek:", (ut / "karta.svg").stat().st_size // 1000, "kB svg,", (ut / "layout.json").stat().st_size // 1000, "kB layout")
