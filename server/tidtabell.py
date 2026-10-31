"""Dagens spårvagnsturer ur Västtrafiks GTFS (zip från Trafiklab).

Läser zip-filen direkt, rad för rad, och behåller bara spårvagnarna som går
den valda dagen. Turer från dagen före som går efter midnatt tas med,
förskjutna ett dygn bakåt, så att alla tider räknas från dagens midnatt.
"""
import csv
import io
import math
import zipfile
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

# Höjs när bygg_dag ändras, så att servern inte använder en gammal dagsfil.
VERSION = 2
SPARVAGN = {"0"} | {str(t) for t in range(900, 907)}
BUSS = {"3"} | {str(t) for t in range(700, 717)}
TAG = {"2"} | {str(t) for t in range(100, 118)}
# Tågen heter "TÅG" i tidtabellen; tågbolaget skiljer dem åt.
TAGNAMN = {"Västtågen": "Tåg", "Öresundståg": "Öresund"}


def linjenamn(route):
    """Linjens namn på kartan: linjenumret, och för tåg tågbolaget."""
    if route["route_type"] in TAG and route["route_short_name"] in ("", "TÅG"):
        return TAGNAMN.get(route.get("route_long_name", ""), "Tåg")
    return route["route_short_name"]


def fordonstyp(route_type):
    return "sparvagn" if route_type in SPARVAGN else "tag" if route_type in TAG else "buss"
VECKODAG = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

# Lokala meter runt Göteborg, räcker för avstånd inom staden.
LAT0, LON0 = 57.70, 11.97
KX, KY = 111320 * math.cos(math.radians(LAT0)), 110540


def meter(lat, lon):
    return (lon - LON0) * KX, (lat - LAT0) * KY


def stockholm_nu():
    """Svensk tid utan tidszonsdatabas: CET, CEST mellan sista söndagen i mars och oktober."""
    utc = datetime.now(timezone.utc)

    def sista_sondag(manad):
        d = datetime(utc.year, manad, 31, 1, tzinfo=timezone.utc)
        return d - timedelta(days=(d.weekday() + 1) % 7)

    sommar = sista_sondag(3) <= utc < sista_sondag(10)
    return (utc + timedelta(hours=2 if sommar else 1)).replace(tzinfo=None)


def _rader(z, fil):
    with z.open(fil) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig"))


def _sek(t):
    h, m, s = map(int, t.split(":"))
    return h * 3600 + m * 60 + s


def _tjanster(z, d):
    ds = d.strftime("%Y%m%d")
    aktiva = {r["service_id"] for r in _rader(z, "calendar.txt")
              if r["start_date"] <= ds <= r["end_date"] and r[VECKODAG[d.weekday()]] == "1"}
    for r in _rader(z, "calendar_dates.txt"):
        if r["date"] == ds:
            (aktiva.add if r["exception_type"] == "1" else aktiva.discard)(r["service_id"])
    return aktiva


def bygg_dag(zip_path, dag, typer=SPARVAGN, ruta=None):
    """Dagens turer av de valda slagen, med hållplatser, tider, avstånd längs spåret och form.

    Med ruta (syd, väst, nord, öst) tas bara turer som stannar inom rutan, även
    de som bara stannar en gång där (tåg och expressbussar), så att de syns på
    avgångstavlan. Turen behåller alla sina hållplatser, så att slutstationen
    syns, men "inne" säger vilka som ligger inom rutan.

    Returnerar {"dag", "version", "turer", "former", "stationer", "typer"} där varje tur är
    {"linje", "mot", "skylt", "form", "stopp": [(namn, ankomst, avgång, avstånd)], "inne": [bool]}.
    """
    z = zipfile.ZipFile(zip_path)
    feed = next(_rader(z, "feed_info.txt"), {}) if "feed_info.txt" in z.namelist() else {}
    routes = {r["route_id"]: r for r in _rader(z, "routes.txt") if r["route_type"] in typer}
    linje = {rid: linjenamn(r) for rid, r in routes.items()}
    typ = {linje[rid]: fordonstyp(r["route_type"]) for rid, r in routes.items()}
    idag, igar = _tjanster(z, dag), _tjanster(z, dag - timedelta(days=1))

    # En tur kan gå båda dagarna (samma service_id måndag–fredag). Då tas den med
    # två gånger: dagens, och gårdagens förskjuten ett dygn bakåt.
    turer = {}
    for r in _rader(z, "trips.txt"):
        if r["route_id"] not in linje:
            continue
        forskj = ([0] if r["service_id"] in idag else []) + ([-86400] if r["service_id"] in igar else [])
        if forskj:
            turer[r["trip_id"]] = (linje[r["route_id"]], r["shape_id"], forskj)

    stopp = {r["stop_id"]: r for r in _rader(z, "stops.txt")}

    def station(stop_id):
        s = stopp[stop_id]
        return stopp[s["parent_station"]] if s.get("parent_station") else s

    def inom(stop_id):
        s = stopp[stop_id]
        return ruta is None or (ruta[0] <= float(s["stop_lat"]) <= ruta[2] and ruta[1] <= float(s["stop_lon"]) <= ruta[3])

    # stop_times är grupperad per tur. Turer som inte stannar inom rutan släpps
    # direkt, så att inte alla regionens bussar hålls i minnet.
    anrop, forra = defaultdict(list), None
    for r in _rader(z, "stop_times.txt"):
        tur = r["trip_id"]
        if tur not in turer:
            continue
        if tur != forra:
            if forra and not any(a[6] for a in anrop[forra]):
                del anrop[forra]
            forra = tur
        st_ = station(r["stop_id"])
        anrop[tur].append((int(r["stop_sequence"]), st_["stop_name"],
                           _sek(r["arrival_time"]), _sek(r["departure_time"]),
                           float(r.get("shape_dist_traveled") or 0), r.get("stop_headsign", ""), inom(r["stop_id"]),
                           st_["stop_id"]))
    if forra and not any(a[6] for a in anrop[forra]):
        del anrop[forra]

    behov = {turer[t][1] for t in anrop}
    punkter = defaultdict(list)
    for r in _rader(z, "shapes.txt"):
        if r["shape_id"] in behov:
            x, y = meter(float(r["shape_pt_lat"]), float(r["shape_pt_lon"]))
            punkter[r["shape_id"]].append((int(r["shape_pt_sequence"]), x, y, r.get("shape_dist_traveled") or ""))
    former = {}
    for form, p in punkter.items():
        p.sort()
        if all(d != "" for *_, d in p):
            former[form] = [(x, y, float(d)) for _, x, y, d in p]
        else:  # inga avstånd i filen: räkna själv
            ut, acc = [], 0.0
            for i, (_, x, y, _) in enumerate(p):
                if i:
                    acc += math.dist((x, y), ut[-1][:2])
                ut.append((x, y, acc))
            former[form] = ut

    resultat = []
    for trip_id, a in anrop.items():
        a.sort()
        linje_, form, forskjutningar = turer[trip_id]
        for forskj in forskjutningar:
            if a[-1][2] + forskj < 0:  # gårdagens tur som slutade före midnatt
                continue
            resultat.append({
                "linje": linje_, "mot": a[-1][1], "skylt": a[0][5] or a[-1][1], "form": form,
                "stopp": [(n, ank + forskj, avg + forskj, d) for _, n, ank, avg, d, *_ in a],
                "inne": [x[6] for x in a],
            })
    resultat.sort(key=lambda t: t["stopp"][0][2])

    # Hållplatserna inom rutan, med läge i meter. Läget tas från den hållplats
    # turerna stannar vid; samma namn finns på flera orter i Västtrafiks område.
    stationer = {}
    for a in anrop.values():
        for x in a:
            if x[6]:
                s = stopp[x[7]]
                stationer[x[1]] = meter(float(s["stop_lat"]), float(s["stop_lon"]))
    return {"dag": dag.isoformat(), "version": feed.get("feed_version", ""), "turer": resultat,
            "former": former, "stationer": stationer, "typer": typ}


def klientdata(dag, layout):
    """Det sidan behöver: linjer, namn, vägar längs kartan och turerna med tider.

    Turernas ordning är densamma som i dag["turer"], så realtiden kan peka ut en
    tur med dess index.
    """
    farger = {l["namn"]: l for l in layout["linjer"]}
    linjer = sorted({t["linje"] for t in dag["turer"]}, key=lambda s: (not s.isdigit(), s.zfill(3)))
    pos = defaultdict(list)
    for n, x, y in layout["stationer"]:
        pos[n].append((x, y))
    namn = sorted({n for n, _, _ in layout["stationer"]} | {t["mot"] for t in dag["turer"]}
                  | {s[0] for t in dag["turer"] for s in t["stopp"]})
    namn_idx = {n: i for i, n in enumerate(namn)}

    hopp, hopp_idx = [], {}

    def hopp_for(l, a, b):
        nyckel = f"{l}|{a}|{b}"
        if nyckel not in hopp_idx:
            pts = layout["hopp"].get(nyckel)
            if pts is None and pos.get(a) and pos.get(b):  # rakt mellan hållplatserna
                p, q = min(((p, q) for p in pos[a] for q in pos[b]), key=lambda pq: math.dist(*pq))
                pts = [p[0], p[1], q[0], q[1]]
            if pts is None:
                hopp_idx[nyckel] = -1
            else:
                hopp.append(pts)
                hopp_idx[nyckel] = len(hopp) - 1
        return hopp_idx[nyckel]

    turer = []
    for t in dag["turer"]:
        st = t["stopp"]
        tider, forra = [], st[0][2]
        for _, ank, avg, _ in st:
            tider += [ank - forra, avg - ank]
            forra = avg
        inne = t.get("inne") or [True] * len(st)
        turer.append([linjer.index(t["linje"]), namn_idx[t["mot"]], st[0][2],
                      [hopp_for(t["linje"], a[0], b[0]) if i and j else -1
                       for a, b, i, j in zip(st, st[1:], inne, inne[1:])],
                      [namn_idx[s[0]] for s in st], tider])
    return {
        "dag": dag["dag"], "version": dag["version"], "storlek": layout["storlek"],
        "linjebredd": layout.get("linjebredd", 4.4),
        "linjer": [{"namn": l, "farg": farger.get(l, {}).get("farg", "#8a97a6"),
                    "text": farger.get(l, {}).get("text", "#0b1016"),
                    "typ": dag.get("typer", {}).get(l, "sparvagn")} for l in linjer],
        "namn": namn,
        "stationer": [[namn_idx[n], x, y] for n, x, y in layout["stationer"]],
        "hopp": hopp,
        "strackor": layout.get("strackor", []),
        # Hållplatsernas riktiga lägen, så att appen kan hitta den närmaste.
        "geo": [[namn_idx[n], round(y / KY + LAT0, 5), round(x / KX + LON0, 5)]
                for n, (x, y) in sorted(dag["stationer"].items()) if n in namn_idx],
        "turer": turer,
    }
