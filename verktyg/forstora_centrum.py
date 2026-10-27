"""Förstorar centrum före schematiseringen, som på klassiska linjekartor.

Varje punkt i grafen flyttas längs sin radie från Brunnsparken: r -> R*(r/R)**p.
Med p under 1 blir centrum större och förorterna mindre.

  python3 verktyg/forstora_centrum.py topo.json 0.55 > forstorad.json
"""
import json, math, sys
g = json.load(open(sys.argv[1])); p = float(sys.argv[2])
LAT0, LON0 = 57.7071, 11.9689
KX, KY = 111320 * math.cos(math.radians(LAT0)), 110540
R = 3000.0
def f(c):
    x, y = (c[0] - LON0) * KX, (c[1] - LAT0) * KY
    r = math.hypot(x, y)
    if r < 1e-6: return c
    s = R * (r / R) ** p / r
    return [LON0 + x * s / KX, LAT0 + y * s / KY]
for ft in g["features"]:
    geo = ft["geometry"]
    if geo["type"] == "Point": geo["coordinates"] = f(geo["coordinates"])
    else: geo["coordinates"] = [f(c) for c in geo["coordinates"]]
json.dump(g, sys.stdout)
