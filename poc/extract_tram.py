"""Plockar ut spårvagnarna ur Västtrafiks GTFS till en egen, liten GTFS-mapp."""
import csv, io, sys, zipfile
from pathlib import Path

src, dst = zipfile.ZipFile(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
TRAM = {"0"} | {str(t) for t in range(900, 907)}

def rader(f):
    with src.open(f) as fh:
        r = csv.DictReader(io.TextIOWrapper(fh, "utf-8-sig"))
        yield r.fieldnames
        yield from r

def filtrera(f, behall):
    it = rader(f)
    falt = next(it)
    n = 0
    with open(dst / f, "w", newline="", encoding="utf-8") as out:
        w = csv.DictWriter(out, falt)
        w.writeheader()
        for r in it:
            if behall(r):
                w.writerow(r); n += 1
    print(f"{f}: {n}")

routes = {r["route_id"]: r for r in list(rader("routes.txt"))[1:] if r["route_type"] in TRAM}
filtrera("routes.txt", lambda r: r["route_id"] in routes)
trips, shapes, services = set(), set(), set()
for r in list(rader("trips.txt"))[1:]:
    if r["route_id"] in routes:
        trips.add(r["trip_id"]); shapes.add(r["shape_id"]); services.add(r["service_id"])
filtrera("trips.txt", lambda r: r["route_id"] in routes)
stops = set()
def st(r):
    if r["trip_id"] in trips:
        stops.add(r["stop_id"]); return True
filtrera("stop_times.txt", st)
parents = set()
for r in list(rader("stops.txt"))[1:]:
    if r["stop_id"] in stops and r.get("parent_station"):
        parents.add(r["parent_station"])
filtrera("stops.txt", lambda r: r["stop_id"] in stops or r["stop_id"] in parents)
filtrera("shapes.txt", lambda r: r["shape_id"] in shapes)
filtrera("calendar.txt", lambda r: r["service_id"] in services)
filtrera("calendar_dates.txt", lambda r: r["service_id"] in services)
agencies = {r["agency_id"] for r in routes.values()}
filtrera("agency.txt", lambda r: r["agency_id"] in agencies)
filtrera("feed_info.txt", lambda r: True)
