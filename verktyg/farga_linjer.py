"""Ger linjerna egna färger, när Västtrafiks färger inte skiljer dem åt.

  python3 verktyg/farga_linjer.py data/kungsbacka > layout/kungsbacka/farger.json

Alla bussar i Kungsbacka är gula hos Västtrafik. Här får varje linje en färg
ur en palett med lätt åtskilda färger, mörka nog att synas på den ljusa
kartan. Linjer som kör samma sträcka bredvid varandra får aldrig samma färg,
och linjer som bara möts vid en hållplats helst inte. Linjer med flest grannar
färgas först. Tågen får fasta färger. Textfärgen på linjeskylten blir vit
eller mörk efter vad som syns bäst.
"""
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

PALETT = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#f032e6", "#42d4f4", "#9a6324",
          "#469990", "#ffe119", "#800000", "#bfef45", "#808000", "#e6a100"]
TAG = {"Tåg": "#1f3a93", "Öresund": "#c2185b"}

gtfs = Path(sys.argv[1])


def rader(f):
    with open(gtfs / f, encoding="utf-8-sig") as fh:
        yield from csv.DictReader(fh)


linje = {r["route_id"]: r["route_short_name"] for r in rader("routes.txt")}
tur_linje = {r["trip_id"]: linje[r["route_id"]] for r in rader("trips.txt")}
stopp = {r["stop_id"]: r.get("parent_station") or r["stop_id"] for r in rader("stops.txt")}
hpl, strackor, per_tur = defaultdict(set), defaultdict(set), defaultdict(list)
for r in rader("stop_times.txt"):
    hpl[tur_linje[r["trip_id"]]].add(stopp[r["stop_id"]])
    per_tur[r["trip_id"]].append((int(r["stop_sequence"]), stopp[r["stop_id"]]))
for tur, st in per_tur.items():
    st.sort()
    strackor[tur_linje[tur]] |= {frozenset((a[1], b[1])) for a, b in zip(st, st[1:])}

bredvid = {l: {m for m in hpl if m != l and strackor[l] & strackor[m]} for l in hpl}
mots = {l: {m for m in hpl if m != l and hpl[l] & hpl[m]} for l in hpl}
farg = dict(TAG)
for l in sorted((l for l in hpl if l not in TAG), key=lambda l: (-len(bredvid[l]), -len(mots[l]), l.zfill(5))):
    fria = [f for f in PALETT if f not in {farg.get(m) for m in bredvid[l]}] or PALETT
    anvant = [farg.get(m) for m in mots[l]]
    farg[l] = min(fria, key=lambda f: (anvant.count(f), list(farg.values()).count(f)))


def text(bg):
    r, g, b = (int(bg[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return "#0b1016" if 0.299 * r + 0.587 * g + 0.114 * b > 0.6 else "#ffffff"


json.dump({l: {"backgroundColor": f, "foregroundColor": text(f)} for l, f in sorted(farg.items()) if l in hpl},
          sys.stdout, ensure_ascii=False, indent=1)
