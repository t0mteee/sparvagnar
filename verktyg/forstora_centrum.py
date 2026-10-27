"""Förstorar centrum före schematiseringen, som på klassiska linjekartor.

Varje punkt i grafen flyttas längs sin radie från centrum: r -> R*(r/R)**p.
Med p under 1 blir centrum större och förorterna mindre. Centrum är
Brunnsparken om inget annat anges.

  python3 verktyg/forstora_centrum.py topo.json 0.55 > forstorad.json
  python3 verktyg/forstora_centrum.py topo.json 0.6 57.4925 12.0750 > forstorad.json
"""
import json
import math
import sys

R = 3000.0                              # radien som behåller sin längd, meter


def flytta(c, p):
    x, y = (c[0] - LON0) * KX, (c[1] - LAT0) * KY
    r = math.hypot(x, y)
    if r < 1e-6:
        return c
    s = R * (r / R) ** p / r
    return [LON0 + x * s / KX, LAT0 + y * s / KY]


graf, p = json.load(open(sys.argv[1])), float(sys.argv[2])
LAT0, LON0 = map(float, sys.argv[3:5]) if len(sys.argv) > 4 else (57.7071, 11.9689)   # Brunnsparken
KX, KY = 111320 * math.cos(math.radians(LAT0)), 110540
for f in graf["features"]:
    geo = f["geometry"]
    if geo["type"] == "Point":
        geo["coordinates"] = flytta(geo["coordinates"], p)
    else:
        geo["coordinates"] = [flytta(c, p) for c in geo["coordinates"]]
json.dump(graf, sys.stdout)
