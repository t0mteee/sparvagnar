"""Bygger kartans layout: SVG från transitmap och vagnarnas vägar längs linjerna.

  python3 verktyg/bygg_layout.py jamn.json data/tram colors.json transitmap layout/

jamn.json är LOOM:s graf efter verktyg/jamna_avstand.py.

Resultatet (layout/karta.svg och layout/layout.json) checkas in. Servern läser
det och behöver varken LOOM eller transitmap. Kör om när linjenätet ändras.

Varje linje får en tillfällig unik färg när transitmap ritar, så att varje
ritad polyline kan knytas till sin linje. Vagnarnas väg mellan två hållplatser
är kortaste vägen längs just den linjens ritade polylines.
"""
import heapq
import html
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

# Linjebredd, mellanrum och kant i transitmaps enheter (tiondels kartenheter).
# Tunna linjer ger smala knippen och luft mellan hållplatserna.
LINJE, MELLANRUM, KANT = 30, 9, 4
LB, MR = LINJE / 10, MELLANRUM / 10
NAMN_STORLEK, KNUT_STORLEK = 8.5, 10

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
svg = subprocess.run([transitmap, "--no-render-stations", "--line-width", str(LINJE), "--line-spacing", str(MELLANRUM),
                      "--outline-width", str(KANT)], input=json.dumps(octi), capture_output=True, text=True, check=True).stdout

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

stationer = []
for f in octi["features"]:
    p = f["properties"]
    if f["geometry"]["type"] == "Point" and p.get("station_label"):
        x, y = till_svg(*f["geometry"]["coordinates"])
        stationer.append((p["station_label"], x, y))
print(f"stationer {len(stationer)}")

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
# En linje räknas som förbi en hållplats om den ritas högst NARA från noden.
# Knippet runt de största knutpunkterna är knappt 20 enheter brett.
NARA = 25
pos_per_namn = defaultdict(list)
for namn, x, y in stationer:
    pos_per_namn[namn].append((x, y))
ansl = {}
def anslutningar(linje, namn, maxd=NARA):
    if (linje, namn, maxd) not in ansl:
        g = grafer.get(linje)
        ansl[(linje, namn, maxd)] = [i for i in (narmast(g, p, maxd) for p in pos_per_namn.get(namn, []))
                                     if i is not None] if g else []
    return ansl[(linje, namn, maxd)]

hopp, hopp_id = [], {}
saknas, lanade, egna_hopp = defaultdict(int), 0, set()
def kortaste(linje, a, b, maxd=NARA):
    g = grafer.get(linje)
    bast = None
    for i in anslutningar(linje, a, maxd):
        for j in anslutningar(linje, b, maxd):
            rak = math.dist(g["pts"][i], g["pts"][j])
            r = vag(g, i, j, rak * 4 + 200)
            if r and (bast is None or r[1] < bast[1]):
                bast = r
    return bast

def hopp_for(linje, a, b):
    global lanade
    nyckel = (linje, a, b)
    if nyckel in hopp_id:
        return hopp_id[nyckel]
    bast = kortaste(linje, a, b)
    if bast is not None:
        egna_hopp.add(f"{linje}|{a}|{b}")
    if bast is None:
        # Linjen är inte ritad här (X, 13 eller en omledning): låna den kortaste
        # vägen som någon annan linje har mellan samma hållplatser.
        for annan in grafer:
            if annan != linje:
                r = kortaste(annan, a, b)
                if r and (bast is None or r[1] < bast[1]):
                    bast = r
        lanade += bast is not None
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
turer_per_linje, stopp_per_linje = defaultdict(int), defaultdict(int)
for tur, st in per_tur.items():
    st.sort()
    par |= {(linje_for_tur[tur], a[1], b[1]) for a, b in zip(st, st[1:])}
    turer_per_linje[linje_for_tur[tur]] += 1
    for n_ in {n_ for _, n_ in st}:
        stopp_per_linje[(linje_for_tur[tur], n_)] += 1
hopp_ut = {}
for linje, a, b in sorted(par):
    i = hopp_for(linje, a, b)
    if i >= 0 and (linje, a, b) not in saknas:
        hopp_ut[f"{linje}|{a}|{b}"] = hopp[i]
linjer = sorted({l for l, _, _ in par}, key=lambda s_: (not s_.isdigit(), s_.zfill(3)))
print(f"par {len(par)}, vägar längs linjen {len(hopp_ut)}, varav lånade {lanade}, saknas {len(saknas)}")

for k in sorted(saknas)[:20]:
    print("  saknas:", k)

# Knutpunkter och namn. Noderna i LOOM:s graf, med antalet linjer på varje kant som går ut från dem.
noder = {f["properties"]["id"]: f for f in octi["features"] if f["geometry"]["type"] == "Point"}
ut_fran = defaultdict(list)
for f in octi["features"]:
    if f["geometry"]["type"] == "Point":
        continue
    antal = len(f["properties"].get("lines", []))
    ut_fran[f["properties"]["from"]].append(antal)
    ut_fran[f["properties"]["to"]].append(antal)

nod_info = {}
for nid, f in noder.items():
    namn_ = f["properties"].get("station_label")
    if not namn_:
        continue
    x, y = till_svg(*f["geometry"]["coordinates"])
    kanter_ = ut_fran[nid]
    halv = max((a_ * (LB + MR) / 2 for a_ in kanter_), default=LB)
    linjer_vid = {l["label"] for k in octi["features"] if k["geometry"]["type"] != "Point"
                  and nid in (k["properties"]["from"], k["properties"]["to"]) for l in k["properties"].get("lines", [])}
    nod_info[nid] = {"namn": namn_, "x": x, "y": y, "grad": len(kanter_), "halv": halv, "linjer": linjer_vid}

# De stora bytespunkterna ritas som en vit cirkel över korsningen, som på en
# tryckt linjekarta. Vilka det är går inte att räkna fram ur tidtabellen; det är
# platserna där man byter mellan många linjer åt olika håll.
KNUTAR = {"Brunnsparken", "Drottningtorget", "Gamlestads Torg", "Hjalmar Brantingsplatsen", "Järntorget",
          "Korsvägen", "Marklandsgatan", "Redbergsplatsen"}
knutar = set()
for namn_ in KNUTAR:
    kandidater = [nid for nid, n in nod_info.items() if n["namn"] == namn_]
    if kandidater:
        knutar.add(max(kandidater, key=lambda nid: (nod_info[nid]["grad"], nod_info[nid]["halv"])))
for k in knutar:
    nod_info[k]["radie"] = max(nod_info[k]["halv"] + 2.5, 13)
print(f"knutpunkter {len(knutar)}, saknas {sorted(KNUTAR - {nod_info[k]['namn'] for k in knutar})}")

# Hållplatsmärken: en vit prick på varje linje som stannar, där linjen passerar
# noden, och ett band tvärs över knippet som binder ihop prickarna. En linje
# räknas som stannande om minst 3 % av dess turer stannar där; enstaka turer
# vid omledningar och till vagnhallen ger ingen prick.
stannar = {k for k, n_ in stopp_per_linje.items() if n_ >= 0.03 * turer_per_linje[k[0]]}
prickar, band, utan = [], [], []
for nid, n in nod_info.items():
    if n["namn"] in KNUTAR or "Vändslinga" in n["namn"]:
        continue
    egna = []
    for linje in sorted(n["linjer"]):
        g = grafer.get(linje)
        if g and (linje, n["namn"]) in stannar:
            i = narmast(g, (n["x"], n["y"]), maxd=n["halv"] + LB + (6 if n["grad"] >= 3 else 0))
            if i is not None:
                egna.append((linje, g["pts"][i], n["namn"]))
    prickar += egna
    if not egna:
        utan.append(n["namn"])
    if len(egna) >= 2:
        a_, b_ = max(((a_, b_) for a_ in egna for b_ in egna), key=lambda ab: math.dist(ab[0][1], ab[1][1]))
        # I en korsning kan prickarna hamna på olika grenar; då inget band.
        if math.dist(a_[1], b_[1]) <= len(egna) * (LB + MR) + LB:
            band.append(([l for l, *_ in egna], a_[1], b_[1], n["namn"]))
print(f"hållplatsprickar {len(prickar)}, band {len(band)}, utan märke {sorted(utan)}")

# Hinder för namnen: alla linjers punkter, prickar och knutpunkter, i ett rutnät.
RUTA = 8
hinder = defaultdict(list)
for g in grafer.values():
    for q in g["pts"][::2]:
        hinder[(int(q[0] // RUTA), int(q[1] // RUTA))].append(q)
for _, q, _ in prickar:
    hinder[(int(q[0] // RUTA), int(q[1] // RUTA))].append(q)
for k in knutar:
    n = nod_info[k]
    r = n["radie"]
    for v in range(0, 360, 20):
        q = (n["x"] + r * math.cos(math.radians(v)), n["y"] + r * math.sin(math.radians(v)))
        hinder[(int(q[0] // RUTA), int(q[1] // RUTA))].append(q)

def traffar(ruta_):
    x1, y1, x2, y2 = ruta_
    antal = 0
    for i in range(int(x1 // RUTA), int(x2 // RUTA) + 1):
        for j in range(int(y1 // RUTA), int(y2 // RUTA) + 1):
            antal += sum(1 for q in hinder.get((i, j), ()) if x1 <= q[0] <= x2 and y1 <= q[1] <= y2)
    return antal

SLUT = ["sjukhuset", "platsen", "gatan", "torget", "parken", "vägen", "kyrkan", "skolan", "bommen",
        "vallen", "backen", "sgata", "torg", "plan", "gata"]
def radbrytningar(namn_):
    """Namnet på en rad, och om det är långt även på två: vid mellanslag eller som Wieselgrens-platsen."""
    val = [[namn_]]
    if len(namn_) > 11:
        if " " in namn_:
            delar = namn_.split(" ")
            bast_ = min(range(1, len(delar)), key=lambda i: abs(len(" ".join(delar[:i])) - len(" ".join(delar[i:]))))
            val.append([" ".join(delar[:bast_]), " ".join(delar[bast_:])])
        else:
            for slut in SLUT:
                if namn_.lower().endswith(slut) and len(namn_) - len(slut) >= 4:
                    val.append([namn_[:-len(slut)] + "-", namn_[-len(slut):]])
                    break
    return val

lagda, etiketter = [], []
ordning = sorted(nod_info, key=lambda k: (k not in knutar, nod_info[k]["grad"] != 1, -len(nod_info[k]["linjer"])))
gjorda = set()
for k in ordning:
    n = nod_info[k]
    if n["namn"] in gjorda or "Vändslinga" in n["namn"]:
        continue
    gjorda.add(n["namn"])
    fs = KNUT_STORLEK if k in knutar else NAMN_STORLEK
    avst = n["radie"] + 2.5 if k in knutar else n["halv"] + 2.5
    bast_ = None
    for rader_ in radbrytningar(n["namn"]):
        bredd_t = max(len(r) for r in rader_) * fs * 0.5
        hojd_t = fs * (1.12 * len(rader_))
        for v in range(0, 360, 45):
            dx, dy = round(math.cos(math.radians(v)), 3), round(math.sin(math.radians(v)), 3)
            # Snett ut ligger namnrutans hörn närmast, så där räcker det med kortare avstånd.
            a_ = avst * (0.8 if dx and dy else 1)
            px, py = n["x"] + dx * a_, n["y"] + dy * a_
            if dx > 0.3:
                ankare, x1 = "start", px
            elif dx < -0.3:
                ankare, x1 = "end", px - bredd_t
            else:
                ankare, x1 = "middle", px - bredd_t / 2
            if dy > 0.3:
                y1 = py
            elif dy < -0.3:
                y1 = py - hojd_t
            else:
                y1 = py - hojd_t / 2
            ruta_ = (x1, y1, x1 + bredd_t, y1 + hojd_t)
            krock = sum(1 for r in lagda if not (ruta_[2] < r[0] or ruta_[0] > r[2] or ruta_[3] < r[1] or ruta_[1] > r[3]))
            krock += ruta_[0] < 0 or ruta_[1] < 0 or ruta_[2] > W or ruta_[3] > H   # utanför kartan
            poang = traffar(ruta_) * 10 + krock * 1000 + (len(rader_) - 1) * 6 + {0: 0, 180: 1, 90: 2, 270: 2}.get(v, 4)
            if bast_ is None or poang < bast_[0]:
                bast_ = (poang, ruta_, rader_, ankare, px, fs)
    poang, ruta_, rader_, ankare, px, fs = bast_
    lagda.append(ruta_)
    etiketter.append((rader_, ankare, px, ruta_[1], fs, k in knutar, n["namn"]))
krockar = sum(1 for i, a_ in enumerate(lagda) for b_ in lagda[i + 1:]
              if not (a_[2] < b_[0] or a_[0] > b_[2] or a_[3] < b_[1] or a_[1] > b_[3]))
print(f"namn {len(etiketter)}, namn som krockar med varandra {krockar}")

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

# Varje ritad linjebit märks med de sträckor (linje|från|till) vars väg går över
# den. Sidan kan då tona ner bitar som ingen vagn kör idag, till exempel när ett
# spår är avstängt. Bara linjens egna vägar räknas, inte lånade.
strackor, strack_idx = [], {}
vag_rut = defaultdict(lambda: defaultdict(set))
for nyckel in sorted(egna_hopp & set(hopp_ut)):
    linje = nyckel.split("|")[0]
    pts = hopp_ut[nyckel]
    for q in tathet([(pts[i], pts[i + 1]) for i in range(0, len(pts), 2)]):
        vag_rut[linje][(int(q[0] // 2), int(q[1] // 2))].add(nyckel)

def strackor_for(linje, punkter):
    p = tathet(punkter)
    traff = defaultdict(int)
    for q in p:
        nara = set()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                nara |= vag_rut[linje].get((int(q[0] // 2) + dx, int(q[1] // 2) + dy), set())
        for k in nara:
            traff[k] += 1
    return sorted(k for k, n_ in traff.items() if n_ >= max(2, 0.3 * len(p)))

def marka(m_):
    klass, pts = m_.group(1), m_.group(2)
    linje = re.search(r"\bL-(\S+)", klass)
    if not linje:
        return m_.group(0)
    ks = strackor_for(linje.group(1), [tuple(map(float, q.split(","))) for q in pts.split()])
    if not ks:
        return m_.group(0)
    for k in ks:
        strack_idx.setdefault(k, len(strackor))
        if strack_idx[k] == len(strackor):
            strackor.append(k)
    return f'{m_.group(0)} data-s="{" ".join(str(strack_idx[k]) for k in ks)}"'

svg_ut = re.sub(r'<polyline class="([^"]*)" points="([^"]+)"', marka, svg_ut)
print(f"linjebitar märkta med {len(strackor)} sträckor")
svg_ut = re.sub(r"(\d+\.\d)\d+", r"\1", svg_ut)
svg_ut = svg_ut[svg_ut.index("<svg"):]
def text_svg(rader_, ankare, x, y_topp, fs, knut, namn_):
    y = y_topp + fs * 0.82
    klass = "station-label knut" if knut else "station-label"
    spann = "".join(f'<tspan x="{x:.1f}" dy="{0 if i == 0 else fs * 1.12:.1f}">{html.escape(r)}</tspan>' for i, r in enumerate(rader_))
    return (f'<text class="{klass}" data-n="{html.escape(namn_)}" x="{x:.1f}" y="{y:.1f}" font-size="{fs}" '
            f'text-anchor="{ankare}">{spann}</text>')

svg_ut = svg_ut.replace("</svg>",
    '<g class="hallplatser">'
    + "".join(f'<line class="hpl-kant L {" ".join("L-" + l for l in ls)}" data-n="{html.escape(nm)}" x1="{a[0]:.1f}" '
              f'y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke-width="{LB * 0.6 + 1.6:.2f}"/>' for ls, a, b, nm in band)
    + "".join(f'<line class="hpl-band L {" ".join("L-" + l for l in ls)}" data-n="{html.escape(nm)}" x1="{a[0]:.1f}" '
              f'y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke-width="{LB * 0.6:.2f}"/>' for ls, a, b, nm in band)
    + "".join(f'<circle class="hpl L L-{l}" data-n="{html.escape(nm)}" cx="{x:.1f}" cy="{y:.1f}" r="{LB * 0.55:.2f}"/>'
              for l, (x, y), nm in prickar)
    + "</g>"
    + '<g class="knutar">' + "".join(f'<circle class="knut" data-n="{html.escape(nod_info[k]["namn"])}" cx="{nod_info[k]["x"]:.1f}" cy="{nod_info[k]["y"]:.1f}" r="{nod_info[k]["radie"]:.1f}"/>'
                                     for k in sorted(knutar)) + "</g>"
    + '<g class="namn">' + "".join(text_svg(*e) for e in etiketter) + "</g></svg>")
(ut / "karta.svg").write_text(svg_ut)
json.dump({
    "storlek": [W, H],
    "linjebredd": LB,
    "linjer": [{"namn": l, "farg": farger[l]["backgroundColor"], "text": farger[l].get("foregroundColor", "#000")}
               for l in linjer],
    "stationer": [[n, round(x, 1), round(y, 1)] for n, x, y in stationer],
    "hopp": hopp_ut,
    "strackor": strackor,
}, open(ut / "layout.json", "w"), ensure_ascii=False, separators=(",", ":"))
print("storlek:", (ut / "karta.svg").stat().st_size // 1000, "kB svg,", (ut / "layout.json").stat().st_size // 1000, "kB layout")
