"""Reseplanering: platssökning och reseförslag från Västtrafiks Planera Resa v4.

Servern går vidare till Västtrafik med samma slags token som realtid.py och
skickar tillbaka ett litet, förenklat JSON med det appen och sidan visar.
Nycklarna lämnar aldrig servern. Svaren cachas en kort stund, så att samma
sökning från flera skärmar bara blir ett anrop.

  GET /api/platser?q=text              hållplatser och platser som matchar
  GET /api/platser?lat=&lon=           hållplatserna närmast en punkt
  GET /api/resa?fran=&till=&tid=&avser=avgang|ankomst
                                       reseförslag; fran och till är ett id från
                                       /api/platser, tid ISO 8601 (tom = nu)
  GET /api/resa/detaljer?ref=          ett förslags hållplatser, per delresa

Ett plats-id är en hållplats gid (bara siffror) eller "lat,lon" för en adress
eller annan plats, som Västtrafik då får som koordinater.
"""
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

from realtid import API, Vasttrafik

VAGAR = ("/api/platser", "/api/resa", "/api/resa/detaljer")
CACHE_S = {"platser": 3600, "nara": 600, "resa": 30, "detaljer": 30}
MAX_CACHE = 300
TYPER = {"stoparea": "hallplats", "address": "adress", "pointofinterest": "plats", "metastation": "hallplats"}
SLAG = {"tram": "sparvagn", "bus": "buss", "train": "tag", "ferry": "bat", "taxi": "taxi"}
GID = re.compile(r"^\d{16}$")
KOORD = re.compile(r"^(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)$")


class Fel(Exception):
    """Något som går att säga till den som söker, med en HTTP-kod."""

    def __init__(self, kod, text):
        super().__init__(text)
        self.kod = kod


def _tid(s):
    """Västtrafiks tider har sju decimaler på sekunderna; bort med dem."""
    return re.sub(r"\.\d+", "", s) if s else None


def _sek(s):
    try:
        return datetime.fromisoformat(_tid(s)).timestamp()
    except (TypeError, ValueError):
        return None


def _minuter(a, b):
    sa, sb = _sek(a), _sek(b)
    return round((sb - sa) / 60) if sa is not None and sb is not None else None


def _farg(f):
    return f if isinstance(f, str) and re.fullmatch(r"#[0-9A-Fa-f]{6}", f) else None


def _namn(stopp):
    """Hållplatsens namn och läge (A, B, spår 3)."""
    sp = (stopp or {}).get("stopPoint") or {}
    omr = sp.get("stopArea") or {}
    return sp.get("name") or omr.get("name") or (stopp or {}).get("name") or "", sp.get("platform")


def _punkt(stopp):
    """Hållplatsen i en delresa: namn, läge, planerad och beräknad tid, koordinater."""
    namn, lage = _namn(stopp)
    sp = (stopp or {}).get("stopPoint") or {}
    omr = sp.get("stopArea") or {}
    plan = _tid(stopp.get("plannedTime"))
    ber = _tid(stopp.get("estimatedTime"))
    ut = {"namn": namn, "lage": lage, "plan": plan, "tid": ber or plan, "realtid": ber is not None}
    lat, lon = omr.get("latitude", sp.get("latitude")), omr.get("longitude", sp.get("longitude"))
    if lat is not None and lon is not None:
        ut["lat"], ut["lon"] = round(lat, 6), round(lon, 6)
    return ut


def _anteckningar(obj):
    return [n["text"] for n in obj.get("notes") or [] if n.get("text")]


def _fard(ben):
    sj = ben.get("serviceJourney") or {}
    linje = sj.get("line") or {}
    fran, till = _punkt(ben.get("origin") or {}), _punkt(ben.get("destination") or {})
    return {
        "typ": "fard", "index": ben.get("journeyLegIndex"),
        "linje": linje.get("shortName") or linje.get("designation") or linje.get("name") or "?",
        "farg": _farg(linje.get("backgroundColor")) or "#8a97a6",
        "text": _farg(linje.get("foregroundColor")) or "#ffffff",
        "kant": _farg(linje.get("borderColor")),
        "slag": SLAG.get(linje.get("transportMode"), linje.get("transportMode") or ""),
        "mot": sj.get("direction") or "",
        "fran": fran, "till": till,
        "minuter": ben.get("estimatedDurationInMinutes") or ben.get("plannedDurationInMinutes")
        or _minuter(fran["tid"], till["tid"]),
        "installd": bool(ben.get("isCancelled")), "delvisInstalld": bool(ben.get("isPartCancelled")),
        "info": _anteckningar(ben) + _anteckningar(sj),
    }


def _gang(lank, index=None):
    fran, _ = _namn(lank.get("origin"))
    till, _ = _namn(lank.get("destination"))
    return {
        "typ": "gang", "index": lank.get("journeyLegIndex", index),
        "fran": fran, "till": till,
        "minuter": lank.get("estimatedDurationInMinutes") or lank.get("plannedDurationInMinutes") or 0,
        "meter": lank.get("distanceInMeters"),
    }


def forenkla_resa(r):
    """Ett reseförslag från Västtrafik som det appen behöver."""
    delar = [_fard(b) for b in r.get("tripLegs") or []]
    delar += [_gang(c) for c in r.get("connectionLinks") or [] if c.get("transportMode", "walk") == "walk"]
    delar.sort(key=lambda d: d["index"] if d["index"] is not None else 0)
    if r.get("departureAccessLink"):
        delar.insert(0, _gang(r["departureAccessLink"], -1))
    if r.get("arrivalAccessLink"):
        delar.append(_gang(r["arrivalAccessLink"], 999))
    if not delar and r.get("destinationLink"):
        delar = [_gang(r["destinationLink"], 0)]
    delar = [d for d in delar if d["typ"] == "fard" or d["minuter"] or d["meter"]]
    farder = [d for d in delar if d["typ"] == "fard"]

    # Avgång och ankomst: första och sista fordonet, plus gång före och efter.
    gang_fore = sum(d["minuter"] for d in delar[:delar.index(farder[0])]) if farder else 0
    gang_efter = sum(d["minuter"] for d in delar[delar.index(farder[-1]) + 1:]) if farder else 0
    if farder:
        avg, ank = farder[0]["fran"], farder[-1]["till"]
        avgang, ankomst = _flytta(avg["tid"], -gang_fore), _flytta(ank["tid"], gang_efter)
        avgang_plan, ankomst_plan = _flytta(avg["plan"], -gang_fore), _flytta(ank["plan"], gang_efter)
    else:
        lank = r.get("destinationLink") or {}
        avgang = avgang_plan = _tid((lank.get("origin") or {}).get("plannedTime"))
        ankomst = ankomst_plan = _tid((lank.get("destination") or {}).get("plannedTime"))
    return {
        "ref": r.get("detailsReference"),
        "avgang": avgang, "avgangPlan": avgang_plan, "ankomst": ankomst, "ankomstPlan": ankomst_plan,
        "minuter": _minuter(avgang, ankomst),
        "byten": max(0, len(farder) - 1),
        "installd": any(d["installd"] for d in farder),
        "delar": delar,
    }


def _flytta(iso, minuter):
    if not iso or not minuter:
        return iso
    d = datetime.fromisoformat(iso)
    return datetime.fromtimestamp(d.timestamp() + minuter * 60, d.tzinfo).isoformat()


def forenkla_detaljer(d):
    """Hållplatserna för varje delresa i ett förslag, i ordning."""
    ut = []
    for ben in d.get("tripLegs") or []:
        stopp = []
        for c in ben.get("callsOnTripLeg") or []:
            namn, lage = _namn(c)
            omr = (c.get("stopPoint") or {}).get("stopArea") or {}
            plan = _tid(c.get("plannedDepartureTime") or c.get("plannedArrivalTime"))
            ber = _tid(c.get("estimatedDepartureTime") or c.get("estimatedArrivalTime"))
            s = {"namn": namn, "lage": lage, "plan": plan, "tid": ber or plan,
                 "installd": bool(c.get("isCancelled") or c.get("isDepartureCancelled"))}
            lat, lon = c.get("latitude", omr.get("latitude")), c.get("longitude", omr.get("longitude"))
            if lat is not None and lon is not None:
                s["lat"], s["lon"] = round(lat, 6), round(lon, 6)
            stopp.append(s)
        ut.append({"index": ben.get("journeyLegIndex"), "stopp": stopp})
    return {"delar": ut}


def forenkla_plats(p):
    typ = TYPER.get(p.get("locationType"), "plats")
    lat, lon = p.get("latitude"), p.get("longitude")
    pid = p.get("gid") if typ == "hallplats" and GID.match(str(p.get("gid", ""))) else None
    if pid is None and lat is not None and lon is not None:
        pid = f"{lat:.6f},{lon:.6f}"
    if pid is None:
        return None
    ut = {"id": pid, "namn": p.get("name", ""), "typ": typ}
    if lat is not None and lon is not None:
        ut["lat"], ut["lon"] = round(lat, 6), round(lon, 6)
    if p.get("straightLineDistanceInMeters") is not None:
        ut["meter"] = p["straightLineDistanceInMeters"]
    return ut


class Resor:
    def __init__(self, nyckel, hemlighet):
        self.vt = Vasttrafik(nyckel, hemlighet) if nyckel and hemlighet else None
        self.cache = {}
        self.lock = threading.Lock()

    def _hamta(self, vag, params, slag):
        if not self.vt:
            raise Fel(503, "Reseplaneringen är inte igång på servern.")
        q = urllib.parse.urlencode(params, doseq=True)
        nyckel = f"{vag}?{q}"
        with self.lock:
            hit = self.cache.get(nyckel)
            if hit and time.time() - hit[0] < CACHE_S[slag]:
                return hit[1]
        for forsok in range(2):
            req = urllib.request.Request(f"{API}/pr/v4{vag}?{q}", headers={
                "Authorization": f"Bearer {self.vt._token()}", "Accept": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    svar = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 401 and forsok == 0:
                    self.vt.token = None
                    continue
                if e.code in (400, 404):
                    raise Fel(400, "Västtrafik hittade ingen resa med de valen.")
                if e.code == 429:
                    raise Fel(503, "Västtrafik har för mycket att göra just nu. Försök igen om en stund.")
                raise
        with self.lock:
            if len(self.cache) > MAX_CACHE:
                gamla = sorted(self.cache, key=lambda k: self.cache[k][0])[:MAX_CACHE // 2]
                for k in gamla:
                    del self.cache[k]
            self.cache[nyckel] = (time.time(), svar)
        return svar

    def platser(self, f):
        if "lat" in f and "lon" in f:
            try:
                lat, lon = float(f["lat"]), float(f["lon"])
            except ValueError:
                raise Fel(400, "Fel på platsen.")
            # Avrundat till ungefär 100 meter, så att cachen träffar.
            svar = self._hamta("/locations/by-coordinates", {
                "latitude": round(lat, 3), "longitude": round(lon, 3), "radiusInMeters": 1500,
                "limit": 8, "types": "stoparea"}, "nara")
        else:
            q = " ".join(f.get("q", "").split())[:60]
            if len(q) < 2:
                return {"platser": []}
            svar = self._hamta("/locations/by-text", {
                "q": q, "limit": 10, "types": ["stoparea", "address", "pointofinterest"]}, "platser")
        lista = [forenkla_plats(p) for p in svar.get("results") or []]
        return {"platser": [p for p in lista if p]}

    @staticmethod
    def _plats(namn, pid, params):
        if GID.match(pid):
            params[f"{namn}Gid"] = pid
        elif m := KOORD.match(pid):
            params[f"{namn}Latitude"], params[f"{namn}Longitude"] = m.group(1), m.group(2)
        else:
            raise Fel(400, "Välj var resan ska börja och sluta.")

    def resa(self, f):
        params = {"limit": 6}
        self._plats("origin", f.get("fran", ""), params)
        self._plats("destination", f.get("till", ""), params)
        if f.get("fran") == f.get("till"):
            raise Fel(400, "Du är redan framme!")
        if f.get("tid"):
            try:
                d = datetime.fromisoformat(f["tid"].replace("Z", "+00:00"))
            except ValueError:
                raise Fel(400, "Fel på tiden.")
            # Hel minut, så att cachen träffar.
            params["dateTime"] = d.replace(second=0, microsecond=0).isoformat()
            params["dateTimeRelatesTo"] = "arrival" if f.get("avser") == "ankomst" else "departure"
        svar = self._hamta("/journeys", params, "resa")
        return {"forslag": [forenkla_resa(r) for r in svar.get("results") or []]}

    def detaljer(self, f):
        ref = f.get("ref", "")
        if not ref or len(ref) > 4000:
            raise Fel(400, "Fel på resan.")
        svar = self._hamta(f"/journeys/{urllib.parse.quote(ref, safe='')}/details",
                           {"includes": ["servicejourneycalls"]}, "detaljer")
        return forenkla_detaljer(svar)

    def svara(self, vag, fraga):
        """(kod, JSON) för ett anrop till en av VAGAR."""
        f = {k: v[0] for k, v in urllib.parse.parse_qs(fraga).items()}
        try:
            if vag == "/api/platser":
                return 200, self.platser(f)
            if vag == "/api/resa":
                return 200, self.resa(f)
            return 200, self.detaljer(f)
        except Fel as e:
            return e.kod, {"fel": str(e)}
        except Exception as e:  # noqa: BLE001
            print("resa:", repr(e), flush=True)
            return 502, {"fel": "Fick inget svar från Västtrafik. Försök igen om en stund."}
