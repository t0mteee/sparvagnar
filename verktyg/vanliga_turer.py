"""Plockar ut turerna som visar det vanliga linjenätet, som underlag för kartan.

  python3 verktyg/vanliga_turer.py data/tram data/tram_vanlig [ÅÅÅÅ-MM-DD] [dagar]

Tidtabellen täcker flera månader och har med omledningar, turer till och från
vagnhallen och vändslingor. Ritas allt blir knippena breda av linjer som nästan
aldrig går där. Här räknas de närmaste veckorna (åtta veckor från i dag om
inget annat anges). En sträcka hör till det vanliga nätet om minst ANDEL av
linjens turer kör den, på minst hälften av de dagar linjen går. Bara turer där
varje sträcka hör till det vanliga nätet behålls. Linjer som går färre än
hälften av dagarna, som ersättningsbussar, ritas inte, och inte heller
extralinjen X och säsongslinjen 13.

Vagnarna på de turer som tas bort får ändå en väg: bygg_layout.py lånar då en
annan linjes väg mellan samma hållplatser.
"""
import csv
import shutil
import sys
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path

ANDEL = 0.04
UTAN = {"X", "13"}
VECKODAG = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
forsta = date.fromisoformat(sys.argv[3]) if len(sys.argv) > 3 else date.today()
sista = forsta + timedelta(days=(int(sys.argv[4]) if len(sys.argv) > 4 else 56) - 1)
dst.mkdir(parents=True, exist_ok=True)


def rader(f):
    with open(src / f, encoding="utf-8-sig") as fh:
        yield from csv.DictReader(fh)


def skriv(f, behall):
    with open(src / f, encoding="utf-8-sig") as fh, open(dst / f, "w", newline="", encoding="utf-8") as ut:
        r = csv.DictReader(fh)
        w = csv.DictWriter(ut, r.fieldnames)
        w.writeheader()
        for rad in r:
            if behall(rad):
                w.writerow(rad)


linje = {r["route_id"]: r["route_short_name"] for r in rader("routes.txt")}
# X och 13 är spårvagnarnas; bussar med samma nummer i andra städer ritas.
UTAN = {linje[r["route_id"]] for r in rader("routes.txt") if r["route_short_name"] in UTAN and r["route_type"] in ("0", "900")}
turer = {r["trip_id"]: (linje[r["route_id"]], r["service_id"]) for r in rader("trips.txt")}
stopp = {r["stop_id"]: r for r in rader("stops.txt")}

anrop = defaultdict(list)
for r in rader("stop_times.txt"):
    s = stopp[r["stop_id"]]
    anrop[r["trip_id"]].append((int(r["stop_sequence"]), s["parent_station"] or r["stop_id"]))
strackor = {}
for tur, a in anrop.items():
    a.sort()
    strackor[tur] = {(x[1], y[1]) for x, y in zip(a, a[1:])}

# Per trafikdygn (service_id): turer och sträckor per linje.
turer_per, strackor_per = defaultdict(Counter), defaultdict(Counter)
for tur, (l, tj) in turer.items():
    turer_per[tj][l] += 1
    for p in strackor.get(tur, ()):
        strackor_per[tj][(l, p)] += 1

kalender = list(rader("calendar.txt"))
undantag = defaultdict(dict)
for r in rader("calendar_dates.txt"):
    undantag[r["date"]][r["service_id"]] = r["exception_type"]
dagar_linje, dagar_stracka, i_fonstret, antal_dagar = Counter(), Counter(), set(), 0
d = forsta
while d <= sista:
    ds = d.strftime("%Y%m%d")
    aktiva = {r["service_id"] for r in kalender
              if r["start_date"] <= ds <= r["end_date"] and r[VECKODAG[d.weekday()]] == "1"}
    for s, typ in undantag[ds].items():
        (aktiva.add if typ == "1" else aktiva.discard)(s)
    i_fonstret |= aktiva
    antal_dagar += 1
    antal, anvant = Counter(), Counter()
    for tj in aktiva:
        antal.update(turer_per[tj])
        anvant.update(strackor_per[tj])
    dagar_linje.update(antal.keys())
    dagar_stracka.update(k for k, n in anvant.items() if n >= ANDEL * antal[k[0]])
    d += timedelta(days=1)

vanlig = {k for k, n in dagar_stracka.items() if n >= dagar_linje[k[0]] / 2}
behall = {tur for tur, s in strackor.items()
          if turer[tur][0] not in UTAN and dagar_linje[turer[tur][0]] >= antal_dagar / 2
          and all((turer[tur][0], p) in vanlig for p in s)}
print(f"{forsta}–{sista}: behåller {len(behall)} av {len(turer)} turer", file=sys.stderr)
for l in sorted(set(linje.values()), key=lambda s: s.zfill(3)):
    alla = [t for t, (l_, tj) in turer.items() if l_ == l and tj in i_fonstret]
    kvar = sum(1 for t in alla if t in behall)
    print(f"  linje {l:>2}: {kvar / (len(alla) or 1):4.0%} av turerna de dagarna", file=sys.stderr)

skriv("trips.txt", lambda r: r["trip_id"] in behall)
skriv("stop_times.txt", lambda r: r["trip_id"] in behall)
for f in ("agency.txt", "routes.txt", "stops.txt", "shapes.txt", "calendar.txt", "calendar_dates.txt", "feed_info.txt"):
    if (src / f).exists():
        shutil.copy(src / f, dst / f)
