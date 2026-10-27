"""Plockar ut ett områdes linjer ur Västtrafiks GTFS, som underlag för kartan.

  python3 verktyg/plocka_gtfs.py data/vt.zip data/tram goteborg
  python3 verktyg/plocka_gtfs.py data/vt.zip data/kungsbacka kungsbacka

Området (server/omraden.py) anger vilka slags fordon som tas med och rutan.
Har området en ruta tas bara den del av turen som ligger inom den, och bara om
turen stannar vid minst två hållplatser där; tåg till Göteborg och
expressbussar slutar då vid gränsen.
Linjerna får samma namn som på sidan (se tidtabell.linjenamn), så att till
exempel Västtågen och Öresundståg blir två linjer. Närtrafik som måste bokas
(route_type 1501) är varken buss eller tåg och kommer inte med.
"""
import argparse
import csv
import io
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
import tidtabell  # noqa: E402
from omraden import OMRADEN  # noqa: E402

arg = argparse.ArgumentParser()
arg.add_argument("zip")
arg.add_argument("ut")
arg.add_argument("omrade", choices=sorted(OMRADEN))
a = arg.parse_args()
typer, ruta = OMRADEN[a.omrade]["typer"], OMRADEN[a.omrade]["ruta"]
z = zipfile.ZipFile(a.zip)
ut = Path(a.ut)
ut.mkdir(parents=True, exist_ok=True)


def rader(f):
    with z.open(f) as fh:
        yield from csv.DictReader(io.TextIOWrapper(fh, "utf-8-sig"))


def falt(f):
    with z.open(f) as fh:
        return next(csv.reader(io.TextIOWrapper(fh, "utf-8-sig")))


def skriv(f, rad_lista):
    with open(ut / f, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, falt(f))
        w.writeheader()
        w.writerows(rad_lista)
    print(f"{f}: {len(rad_lista)}", file=sys.stderr)


routes = {r["route_id"]: dict(r, route_short_name=tidtabell.linjenamn(r))
          for r in rader("routes.txt") if r["route_type"] in typer}
stopp = {r["stop_id"]: r for r in rader("stops.txt")}


def inne(stop_id):
    if not ruta:
        return True
    s = stopp[stop_id]
    return ruta[0] <= float(s["stop_lat"]) <= ruta[2] and ruta[1] <= float(s["stop_lon"]) <= ruta[3]


turer = {r["trip_id"]: r for r in rader("trips.txt") if r["route_id"] in routes}

# stop_times är grupperad per tur. Ur varje tur behålls den längsta
# sammanhängande delen inom rutan.
behallna, klara = [], set()
tur, grupp = None, []


def avsluta():
    if tur is None:
        return
    klara.add(tur)
    grupp.sort(key=lambda r: int(r["stop_sequence"]))
    bast, del_ = [], []
    for r in grupp + [None]:
        if r is not None and inne(r["stop_id"]):
            del_.append(r)
        else:
            if len(del_) > len(bast):
                bast = del_
            del_ = []
    if len(bast) >= 2:
        behallna.extend(bast)


for r in rader("stop_times.txt"):
    if r["trip_id"] not in turer:
        continue
    if r["trip_id"] != tur:
        avsluta()
        if r["trip_id"] in klara:
            sys.exit("stop_times.txt är inte grupperad per tur")
        tur, grupp = r["trip_id"], []
    grupp.append(r)
avsluta()

med = {r["trip_id"] for r in behallna}
turer = {t: r for t, r in turer.items() if t in med}
anvanda = {r["stop_id"] for r in behallna}
anvanda |= {stopp[s]["parent_station"] for s in anvanda if stopp[s].get("parent_station")}
former = {r["shape_id"] for r in turer.values()}
tjanster = {r["service_id"] for r in turer.values()}

skriv("routes.txt", [r for r in routes.values() if r["route_id"] in {t["route_id"] for t in turer.values()}])
skriv("trips.txt", list(turer.values()))
skriv("stop_times.txt", behallna)
skriv("stops.txt", [r for r in stopp.values() if r["stop_id"] in anvanda])
skriv("shapes.txt", [r for r in rader("shapes.txt") if r["shape_id"] in former])
skriv("calendar.txt", [r for r in rader("calendar.txt") if r["service_id"] in tjanster])
skriv("calendar_dates.txt", [r for r in rader("calendar_dates.txt") if r["service_id"] in tjanster])
for f in ("agency.txt", "feed_info.txt"):
    skriv(f, list(rader(f)))
