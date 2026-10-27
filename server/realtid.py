"""Västtrafiks positioner, kopplade till dagens turer.

Varje vagn som Västtrafik rapporterar kopplas till den tur i tidtabellen som
den troligast kör: samma linje, samma skylt, och närmast i tid där positionen
ligger längs turens spår. Tåg rapporteras med tågnummer i stället för linje,
så de jämförs med alla tågturer. Skillnaden mellan när turen enligt tidtabellen
skulle vara där och nu är vagnens försening. Sidan visar sedan turen
förskjuten med förseningen, så vagnen rör sig mjukt mellan uppdateringarna.
"""
import base64
import hashlib
import json
import math
import time
import urllib.error
import urllib.parse
import urllib.request

from tidtabell import meter

API = "https://ext-api.vasttrafik.se"
MAX_AVSTAND = 150      # meter från turens spår
TIDIG, SEN = -600, 3600
ANNAN_SKYLT = 240      # sekunder: en tur med annan skylt godtas bara om tiden stämmer så här väl
DUBBLETT = 25          # meter: samma linje och skylt närmare än så är samma vagn


class Vasttrafik:
    def __init__(self, nyckel, hemlighet):
        self.auth = base64.b64encode(f"{nyckel}:{hemlighet}".encode()).decode()
        self.token, self.giltig = None, 0

    def _token(self):
        if self.token and time.time() < self.giltig - 300:
            return self.token
        req = urllib.request.Request(f"{API}/token", data=b"grant_type=client_credentials", headers={
            "Authorization": f"Basic {self.auth}", "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=20) as r:
            svar = json.load(r)
        self.token, self.giltig = svar["access_token"], time.time() + int(svar.get("expires_in", 3600))
        return self.token

    def positioner(self, rutor, lagen):
        """Fordonen i rutorna (syd, väst, nord, öst), av slagen i lagen (tram, bus, train)."""
        vagnar = {}
        for lat1, lon1, lat2, lon2 in rutor:
            q = urllib.parse.urlencode({"lowerLeftLat": lat1, "lowerLeftLong": lon1, "upperRightLat": lat2,
                                        "upperRightLong": lon2, "transportModes": lagen, "limit": 200}, doseq=True)
            req = urllib.request.Request(f"{API}/pr/v4/positions?{q}",
                                         headers={"Authorization": f"Bearer {self._token()}"})
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    svar = json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    self.token = None
                raise
            for v in svar:
                vagnar[v["detailsReference"]] = v
        return list(vagnar.values())


def _norm(skylt):
    return skylt.lower().split(" via ")[0].split(",")[0].strip()


def _projicera(form, p, fran=None, till=None):
    """Närmaste punkt på formen: (avstånd längs spåret, avstånd från spåret)."""
    bast, bd = None, 1e18
    for (x1, y1, d1), (x2, y2, d2) in zip(form, form[1:]):
        if fran is not None and (d2 < fran or d1 > till):
            continue
        dx, dy = x2 - x1, y2 - y1
        n = dx * dx + dy * dy
        t = 0.0 if n == 0 else max(0.0, min(1.0, ((p[0] - x1) * dx + (p[1] - y1) * dy) / n))
        qx, qy = x1 + dx * t, y1 + dy * t
        d = (p[0] - qx) ** 2 + (p[1] - qy) ** 2
        if d < bd:
            bast, bd = d1 + (d2 - d1) * t, d
    return bast, math.sqrt(bd)


def _tid_vid(stopp, s):
    """Tiden enligt tidtabellen när turen är s meter in på spåret."""
    if s <= stopp[0][3]:
        return stopp[0][2]
    for (_, _, avg, d1), (_, ank, _, d2) in zip(stopp, stopp[1:]):
        if s < d2:
            return avg + (s - d1) / max(1.0, d2 - d1) * (ank - avg)
    return stopp[-1][1]


def _plats_vid(stopp, t):
    """Var turen enligt tidtabellen är vid tiden t, i meter längs spåret."""
    if t <= stopp[0][2]:
        return stopp[0][3]
    for (_, ank1, avg1, d1), (_, ank2, _, d2) in zip(stopp, stopp[1:]):
        if t < avg1:
            return d1
        if t < ank2:
            return d1 + (t - avg1) / max(1.0, ank2 - avg1) * (d2 - d1)
    return stopp[-1][3]


class Matchning:
    def __init__(self, dag):
        self.dag = dag
        self.per_linje = {}
        for i, t in enumerate(dag["turer"]):
            self.per_linje.setdefault(t["linje"], []).append(i)
        self.tag = [i for i, t in enumerate(dag["turer"]) if dag.get("typer", {}).get(t["linje"]) == "tag"]
        self.koppling = {}  # detailsReference -> turindex

    def _kandidat(self, i, p, nu, skylt, forra):
        t = self.dag["turer"][i]
        st, form = t["stopp"], self.dag["former"].get(t["form"])
        if not form or not (st[0][2] + TIDIG - 300 <= nu <= st[-1][1] + SEN):
            return None
        # Sök bara där turen rimligen kan vara: från en timme sen till tio minuter tidig.
        fran, till = _plats_vid(st, nu - SEN) - 300, _plats_vid(st, nu - TIDIG) + 300
        s, avst = _projicera(form, p, fran, till)
        if s is None or avst > MAX_AVSTAND:
            return None
        forsening = nu - _tid_vid(st, s)
        if not TIDIG <= forsening <= SEN:
            return None
        # En vagn med en skylt som ingen tur i tidtabellen har (till exempel vid en
        # omledning) får inte kopplas till en tur åt andra hållet med stor försening.
        # Skylten kan vara kortare än turens, som "Göteborg" för "Göteborg Central".
        t_skylt = _norm(t["skylt"])
        samma_skylt = skylt == t_skylt or bool(skylt and t_skylt) and (t_skylt.startswith(skylt) or skylt.startswith(t_skylt))
        if not samma_skylt and abs(forsening) > ANNAN_SKYLT:
            return None
        poang = abs(forsening) + avst * 2 + (0 if samma_skylt else 900)
        if forra == i:
            poang -= 600
        return poang, forsening

    @staticmethod
    def _utan_dubbletter(vagnar):
        """Samma vagn rapporteras ibland för två turer på samma plats; behåll en."""
        kvar = []
        for v in vagnar:
            p, skylt = meter(v["latitude"], v["longitude"]), _norm(v.get("direction", ""))
            if not any(w["line"]["name"] == v["line"]["name"] and _norm(w.get("direction", "")) == skylt
                       and math.dist(p, meter(w["latitude"], w["longitude"])) < DUBBLETT for w in kvar):
                kvar.append(v)
        return kvar

    def matcha(self, vagnar, nu):
        """Kopplar vagnarna till turer. nu är sekunder efter dagens midnatt."""
        vagnar = self._utan_dubbletter(vagnar)
        forslag = []
        for v in vagnar:
            p = meter(v["latitude"], v["longitude"])
            skylt, forra = _norm(v.get("direction", "")), self.koppling.get(v["detailsReference"])
            tag = v["line"].get("transportMode") == "train"
            for i in self.tag if tag else self.per_linje.get(v["line"]["name"], []):
                k = self._kandidat(i, p, nu, skylt, forra)
                if k:
                    forslag.append((k[0], v["detailsReference"], i, k[1]))
        forslag.sort()
        vald, upptagen = {}, set()
        for _, ref, i, forsening in forslag:
            if ref not in vald and i not in upptagen:
                vald[ref] = (i, forsening)
                upptagen.add(i)

        ut = []
        for v in vagnar:
            ref = v["detailsReference"]
            post = {"ref": hashlib.sha1(ref.encode()).hexdigest()[:12], "l": v["line"]["name"],
                    "m": v.get("direction", "")}
            if ref in vald:
                post["tur"], post["f"] = vald[ref][0], round(vald[ref][1])
                post["l"] = self.dag["turer"][vald[ref][0]]["linje"]
                self.koppling[ref] = vald[ref][0]
            else:
                p = meter(v["latitude"], v["longitude"])
                post["tur"] = -1
                post["nara"] = min(self.dag["stationer"].items(), key=lambda kv: math.dist(kv[1], p))[0]
            ut.append(post)
        aktiva = {v["detailsReference"] for v in vagnar}
        self.koppling = {r: i for r, i in self.koppling.items() if r in aktiva}
        return ut
