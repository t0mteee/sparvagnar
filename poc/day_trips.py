"""Dagens spårvagnsturer ur tram-GTFS: linje, destination och hållplatser med tider.

Tider i sekunder efter midnatt på den valda dagen. Turer från dagen före som
går efter midnatt tas med, förskjutna ett dygn bakåt.
"""
import csv, json, sys
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

gtfs, dag, ut = Path(sys.argv[1]), date.fromisoformat(sys.argv[2]), sys.argv[3]

def rader(f):
    with open(gtfs / f, encoding="utf-8") as fh:
        yield from csv.DictReader(fh)

VECKODAG = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

def tjanster(d):
    ds = d.strftime("%Y%m%d")
    aktiva = {r["service_id"] for r in rader("calendar.txt")
              if r["start_date"] <= ds <= r["end_date"] and r[VECKODAG[d.weekday()]] == "1"}
    for r in rader("calendar_dates.txt"):
        if r["date"] == ds:
            (aktiva.add if r["exception_type"] == "1" else aktiva.discard)(r["service_id"])
    return aktiva

idag, igar = tjanster(dag), tjanster(dag - timedelta(days=1))
linje = {r["route_id"]: r["route_short_name"] for r in rader("routes.txt")}
# En tur kan gå båda dagarna (samma service_id måndag–fredag). Då tas den med
# två gånger: dagens, och gårdagens förskjuten ett dygn bakåt.
turer = {}
for r in rader("trips.txt"):
    forskj = ([0] if r["service_id"] in idag else []) + ([-86400] if r["service_id"] in igar else [])
    if forskj:
        turer[r["trip_id"]] = (linje[r["route_id"]], forskj)

stopp = {r["stop_id"]: r for r in rader("stops.txt")}
def namn(stop_id):
    s = stopp[stop_id]
    return stopp[s["parent_station"]]["stop_name"] if s.get("parent_station") else s["stop_name"]

def sek(t):
    h, m, s = map(int, t.split(":"))
    return h * 3600 + m * 60 + s

anrop = defaultdict(list)
for r in rader("stop_times.txt"):
    if r["trip_id"] in turer:
        anrop[r["trip_id"]].append((int(r["stop_sequence"]), namn(r["stop_id"]),
                                    sek(r["arrival_time"]), sek(r["departure_time"])))

resultat = []
for tid, a in anrop.items():
    a.sort()
    for forskj in turer[tid][1]:
        if a[-1][2] + forskj < 0:          # gårdagens tur som slutade före midnatt
            continue
        resultat.append({"linje": turer[tid][0], "mot": a[-1][1],
                         "stopp": [[n, ank + forskj, avg + forskj] for _, n, ank, avg in a]})
resultat.sort(key=lambda t: t["stopp"][0][2])
json.dump({"dag": dag.isoformat(), "turer": resultat}, open(ut, "w"), ensure_ascii=False)
print(len(resultat), "turer", dag, "| första", resultat[0]["stopp"][0][2] / 3600, "h | hållplatsnamn:",
      len({s[0] for t in resultat for s in t["stopp"]}))
