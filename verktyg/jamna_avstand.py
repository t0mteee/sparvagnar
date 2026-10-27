"""Sprider ut hållplatserna jämnt mellan korsningarna, som på en tryckt linjekarta.

  python3 verktyg/jamna_avstand.py octi.json > jamn.json

LOOM lägger hållplatserna ungefär där de ligger i verkligheten, så avståndet
mellan dem varierar mycket. Här flyttas varje hållplats som bara har en väg in
och en ut till jämna avstånd längs sträckan mellan de två närmaste korsningarna
eller ändhållplatserna. Linjernas form ändras inte, bara var på dem hållplatserna
sitter; kanterna delas om vid de nya lägena.
"""
import json
import math
import sys
from collections import defaultdict


def merc(lon, lat):
    return lon * 20037508.34 / 180, math.log(math.tan((90 + lat) * math.pi / 360)) * 20037508.34 / math.pi


def geo(x, y):
    return [x * 180 / 20037508.34, math.degrees(2 * math.atan(math.exp(y * math.pi / 20037508.34)) - math.pi / 2)]


def langder(p):
    acc = [0.0]
    for a, b in zip(p, p[1:]):
        acc.append(acc[-1] + math.dist(a, b))
    return acc


def punkt(p, acc, s):
    s = max(0.0, min(acc[-1], s))
    for i in range(1, len(p)):
        if acc[i] >= s:
            t = (s - acc[i - 1]) / ((acc[i] - acc[i - 1]) or 1)
            return (p[i - 1][0] + (p[i][0] - p[i - 1][0]) * t, p[i - 1][1] + (p[i][1] - p[i - 1][1]) * t)
    return p[-1]


def bit(p, acc, s1, s2):
    """Delen av polylinjen mellan båglängderna s1 och s2 (s1 < s2)."""
    ut = [punkt(p, acc, s1)]
    ut += [p[i] for i in range(len(p)) if s1 < acc[i] < s2]
    ut.append(punkt(p, acc, s2))
    return ut


graf = json.load(open(sys.argv[1]))
noder = {f["properties"]["id"]: f for f in graf["features"] if f["geometry"]["type"] == "Point"}
kanter = [f for f in graf["features"] if f["geometry"]["type"] != "Point"]
vid = defaultdict(list)
for k in kanter:
    vid[k["properties"]["from"]].append(k)
    vid[k["properties"]["to"]].append(k)


def linjer(k):
    return tuple(sorted(l["id"] for l in k["properties"].get("lines", [])))


def fast(n):
    """Korsningar, ändpunkter och ställen där en linje börjar eller slutar flyttas inte."""
    k = vid[n]
    return len(k) != 2 or linjer(k[0]) != linjer(k[1])


besokt, kedjor = set(), 0
for start in noder:
    if not fast(start):
        continue
    for forsta in vid[start]:
        if id(forsta) in besokt:
            continue
        # Följ kedjan från en fast nod genom noder med en väg in och en ut.
        led, nod, kant = [], start, forsta
        while True:
            besokt.add(id(kant))
            fram = kant["properties"]["to"] != nod
            nasta = kant["properties"]["to"] if fram else kant["properties"]["from"]
            led.append((kant, fram, nasta))
            if fast(nasta) or nasta == start:
                break
            nod, kant = nasta, next(k for k in vid[nasta] if k is not kant)
        if len(led) < 2:
            continue
        # Hela kedjan som en polylinje i mercator, i färdriktningen.
        p, gransar = [], [0]
        for kant, fram, _ in led:
            c = [merc(*q) for q in kant["geometry"]["coordinates"]]
            c = c if fram else c[::-1]
            p += c if not p else c[1:]
            gransar.append(len(p) - 1)
        acc = langder(p)
        mellan = [n for _, _, n in led[:-1]]
        gamla = [acc[i] for i in gransar[1:-1]]
        # Hållplatser med namn får jämna avstånd; noder utan namn behåller sin
        # relativa plats mellan grannarna.
        med_namn = [i for i, n in enumerate(mellan) if noder[n]["properties"].get("station_label")]
        nya = [None] * len(mellan)
        for j, i in enumerate(med_namn):
            nya[i] = acc[-1] * (j + 1) / (len(med_namn) + 1)
        ankare = [(-1, 0.0, 0.0)] + [(i, gamla[i], nya[i]) for i in med_namn] + [(len(mellan), acc[-1], acc[-1])]
        for (i1, g1, n1), (i2, g2, n2) in zip(ankare, ankare[1:]):
            for i in range(i1 + 1, i2):
                f = (gamla[i] - g1) / ((g2 - g1) or 1)
                nya[i] = n1 + (n2 - n1) * f
        lagen = [0.0] + nya + [acc[-1]]
        for i, n in enumerate(mellan):
            noder[n]["geometry"]["coordinates"] = geo(*punkt(p, acc, nya[i]))
        for i, (kant, fram, _) in enumerate(led):
            b = bit(p, acc, lagen[i], lagen[i + 1])
            kant["geometry"]["coordinates"] = [geo(*q) for q in (b if fram else b[::-1])]
        kedjor += 1

print(f"jämnade ut {kedjor} sträckor", file=sys.stderr)
json.dump(graf, sys.stdout)
