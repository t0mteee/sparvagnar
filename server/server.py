"""Kartan: sidan, dagens tidtabell och Västtrafiks positioner, för flera områden.

Körs i Docker på servern (se docker-compose.yml). Håller nycklarna på
serversidan. Bara standardbiblioteket, ingen pip.

  GET /                     sidan (web/index.html, läses per anrop)
  GET /manifest.webmanifest och /ikon-*.png   för att lägga sidan på hemskärmen
  GET /karta.svg?omrade=    områdets karta
  GET /api/dag?omrade=      dagens turer, vägar och linjer
  GET /api/live?omrade=     senaste positionerna, kopplade till turerna
  GET /api/status           vad servern håller på med, per område
  GET /api/karta?omrade=    kartan som vektordata, för appen (se vektor.py)
  GET /api/platser, /api/resa, /api/resa/detaljer   reseplanering (se resa.py)

omrade är goteborg (spårvagnarna, standard) eller kungsbacka (bussar och tåg),
se omraden.py. Tidtabellen hämtas från Trafiklab högst en gång per dygn.
Positionerna hämtas var 5:e sekund, men bara för områden som någon har öppna.
"""
import gzip
import hashlib
import json
import os
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import realtid  # noqa: E402
import resa  # noqa: E402
import tidtabell  # noqa: E402
from omraden import OMRADEN  # noqa: E402
from vektor import vektor  # noqa: E402

ROT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("DATA", ROT / "data"))
PORT = int(os.environ.get("PORT", "8125"))
VT_NYCKEL = os.environ.get("VASTTRAFIK_KEY", "")
VT_HEMLIGHET = os.environ.get("VASTTRAFIK_SECRET", "")
TL_NYCKEL = os.environ.get("TRAFIKLAB_KEY", "")
ZIP = DATA / "vt.zip"
INTERVALL = 5
FEL_NYCKEL = "VASTTRAFIK_KEY och VASTTRAFIK_SECRET saknas i .env."
TITTAR_S = 60          # så länge efter senaste anropet räknas sidan som öppen
STANDARD = "goteborg"
# Filer i web/ som serveras som de är. Bara de här, så att inget annat i
# mappen kan hämtas.
STATISKA = {"/manifest.webmanifest": "application/manifest+json", "/ikon-180.png": "image/png",
            "/ikon-192.png": "image/png", "/ikon-512.png": "image/png",
            "/resa.js": "text/javascript; charset=utf-8"}

lager = threading.Lock()
RESOR = resa.Resor(VT_NYCKEL, VT_HEMLIGHET)


class Omrade:
    """Ett områdes karta, dagens tidtabell och senaste positioner."""

    def __init__(self, nyckel, conf):
        self.nyckel, self.conf = nyckel, conf
        mapp = ROT / conf["layout"]
        # Kartan och layouten läses en gång, tillsammans, och får ett gemensamt
        # versionsnummer. Sidan hämtar kartan med versionen i adressen, så att en
        # gammal kopia i webbläsarens cache aldrig kan blandas med nya vagnlägen.
        self.karta = (mapp / "karta.svg").read_bytes()
        text = (mapp / "layout.json").read_bytes()
        self.layout = json.loads(text)
        self.version = hashlib.sha1(self.karta + text).hexdigest()[:12]
        self.vektor = gzip.compress(json.dumps(dict(vektor(self.karta), version=self.version),
                                               ensure_ascii=False, separators=(",", ":")).encode())
        self.dag = None          # intern dagsdata
        self.klient = None       # gzippad JSON till sidan
        self.matchning = None
        self.live = {"vagnar": [], "tid": 0}
        self.tittare = 0.0
        self.status = {"tidtabell": "startar", "realtid": "väntar"}


# Ett område utan layout (inte byggd än) visas inte.
OMR = {k: Omrade(k, c) for k, c in OMRADEN.items() if (ROT / c["layout"] / "layout.json").exists()}
LISTA = [[k, o.conf["namn"]] for k, o in OMR.items()]


def logg(*a):
    print(tidtabell.stockholm_nu().strftime("%H:%M:%S"), *a, flush=True)


def dolj(text):
    """Felmeddelanden syns på sidan, som kan vara öppen för alla: aldrig en nyckel i dem."""
    for hemligt in (VT_NYCKEL, VT_HEMLIGHET, TL_NYCKEL):
        if hemligt:
            text = text.replace(hemligt, "…")
    return text


def satt_status(omr, **kw):
    with lager:
        omr.status.update({k: dolj(v) if isinstance(v, str) else v for k, v in kw.items()})


# ---------- Tidtabellen ----------

def hamta_gtfs():
    """Hämtar Västtrafiks GTFS från Trafiklab om filen saknas eller är äldre än 20 timmar."""
    if not TL_NYCKEL:
        return
    if ZIP.exists() and time.time() - ZIP.stat().st_mtime < 20 * 3600:
        return
    logg("hämtar tidtabellen från Trafiklab")
    for omr in OMR.values():
        satt_status(omr, tidtabell="hämtar från Trafiklab")
    req = urllib.request.Request(f"https://opendata.samtrafiken.se/gtfs/vt/vt.zip?key={TL_NYCKEL}",
                                 headers={"Accept-Encoding": "gzip"})
    tmp = ZIP.with_suffix(".tmp")
    with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
        kalla = gzip.GzipFile(fileobj=r) if r.headers.get("Content-Encoding") == "gzip" else r
        while bit := kalla.read(1 << 20):
            f.write(bit)
    tmp.replace(ZIP)
    logg("tidtabellen hämtad,", ZIP.stat().st_size // 1_000_000, "MB")


def bygg(omr, dag):
    cache = DATA / f"dag-{omr.nyckel}-v{tidtabell.VERSION}-{dag.isoformat()}.json.gz"
    if cache.exists() and cache.stat().st_mtime >= ZIP.stat().st_mtime:
        with gzip.open(cache, "rt", encoding="utf-8") as f:
            d = json.load(f)
        d["former"] = {k: [tuple(p) for p in v] for k, v in d["former"].items()}
        d["stationer"] = {k: tuple(v) for k, v in d["stationer"].items()}
        return d
    logg(f"bygger tidtabellen för {omr.conf['namn']} {dag}")
    satt_status(omr, tidtabell=f"bygger {dag}")
    t0 = time.time()
    d = tidtabell.bygg_dag(ZIP, dag, omr.conf["typer"], omr.conf["ruta"])
    with gzip.open(cache, "wt", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    # dag-<område>-ÅÅÅÅ-MM-DD.json.gz; äldre än i förrgår tas bort.
    for gammal in DATA.glob("dag-*.json.gz"):
        if gammal.name[-18:-8] < (dag - timedelta(days=2)).isoformat():
            gammal.unlink()
    logg(f"tidtabellen för {omr.conf['namn']} {dag}: {len(d['turer'])} turer på {time.time() - t0:.0f} s")
    return d


def tidtabell_loop():
    while True:
        for omr in OMR.values():
            try:
                DATA.mkdir(parents=True, exist_ok=True)
                hamta_gtfs()
                if not ZIP.exists():
                    satt_status(omr, tidtabell="ingen tidtabell: TRAFIKLAB_KEY saknas i .env")
                    continue
                idag = tidtabell.stockholm_nu().date()
                with lager:
                    aktuell = omr.dag and omr.dag["dag"]
                if aktuell != idag.isoformat():
                    d = bygg(omr, idag)
                    k = dict(tidtabell.klientdata(d, omr.layout), layout=omr.version, omrade=omr.nyckel, omraden=LISTA)
                    klient = gzip.compress(json.dumps(k, ensure_ascii=False, separators=(",", ":")).encode())
                    with lager:
                        omr.dag, omr.klient, omr.matchning = d, klient, realtid.Matchning(d)
                    satt_status(omr, tidtabell=f"{idag}, version {d['version']}, {len(d['turer'])} turer")
            except Exception as e:
                logg(f"tidtabellen för {omr.conf['namn']}:", repr(e))
                traceback.print_exc()
                satt_status(omr, tidtabell=f"fel: {e}")
        time.sleep(60)


# ---------- Realtiden ----------

def realtid_loop():
    if not (VT_NYCKEL and VT_HEMLIGHET):
        for omr in OMR.values():
            satt_status(omr, realtid=FEL_NYCKEL)
        return
    vt = realtid.Vasttrafik(VT_NYCKEL, VT_HEMLIGHET)
    paus = {k: INTERVALL for k in OMR}
    nasta = {k: 0.0 for k in OMR}
    while True:
        for omr in OMR.values():
            with lager:
                tittar = time.time() - omr.tittare < TITTAR_S
                matchning = omr.matchning
            if not tittar or not matchning:
                satt_status(omr, realtid="vilar, ingen tittar" if matchning else "väntar på tidtabellen")
                continue
            if time.time() < nasta[omr.nyckel]:
                continue
            start = time.time()
            try:
                vagnar = vt.positioner(omr.conf["positioner"], omr.conf["lagen"])
                nu_dt = tidtabell.stockholm_nu()
                nu = nu_dt.hour * 3600 + nu_dt.minute * 60 + nu_dt.second + nu_dt.microsecond / 1e6
                ut = matchning.matcha(vagnar, nu)
                with lager:
                    omr.live = {"vagnar": ut, "tid": time.time(), "nu": round(nu, 1), "dag": matchning.dag["dag"]}
                satt_status(omr, realtid=f"{len(ut)} vagnar, {sum(1 for v in ut if v['tur'] >= 0)} kopplade",
                            realtid_fel=None)
                paus[omr.nyckel] = INTERVALL
            except Exception as e:
                logg(f"realtiden för {omr.conf['namn']}:", repr(e))
                satt_status(omr, realtid_fel=str(e))
                paus[omr.nyckel] = min(60, paus[omr.nyckel] * 2)
            nasta[omr.nyckel] = start + paus[omr.nyckel]
        time.sleep(0.5)


# ---------- Webben ----------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def skicka(self, kod, data, typ, gz=False, cache="no-store"):
        if not gz and len(data) > 2000 and "gzip" in self.headers.get("Accept-Encoding", ""):
            data, gz = gzip.compress(data), True
        elif gz and "gzip" not in self.headers.get("Accept-Encoding", ""):
            data, gz = gzip.decompress(data), False
        self.send_response(kod)
        self.send_header("Content-Type", typ)
        self.send_header("Cache-Control", cache)
        if gz:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def json(self, kod, obj):
        self.skicka(kod, json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_GET(self):
        vag, _, fraga = self.path.partition("?")
        omr = OMR.get(urllib.parse.parse_qs(fraga).get("omrade", [STANDARD])[0])
        if vag in ("/", "/index.html"):
            self.skicka(200, (ROT / "web" / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif vag in STATISKA:
            self.skicka(200, (ROT / "web" / vag[1:]).read_bytes(), STATISKA[vag], cache="max-age=86400")
        elif vag == "/api/status":
            with lager:
                self.json(200, {k: dict(o.status, tittare_for_s=round(time.time() - o.tittare)) for k, o in OMR.items()})
        elif vag in resa.VAGAR:
            kod, svar = RESOR.svara(vag, fraga)
            self.json(kod, svar)
        elif omr is None:
            self.json(404, {"fel": "området finns inte"})
        elif vag == "/karta.svg":
            self.skicka(200, omr.karta, "image/svg+xml")
        elif vag == "/api/karta":
            self.skicka(200, omr.vektor, "application/json; charset=utf-8", gz=True)
        elif vag == "/api/dag":
            with lager:
                klient = omr.klient
            if klient:
                self.skicka(200, klient, "application/json; charset=utf-8", gz=True)
            else:
                self.json(503, {"fel": omr.status["tidtabell"]})
        elif vag == "/api/live":
            with lager:
                omr.tittare = time.time()
                live, status = dict(omr.live), dict(omr.status)
            live["fel"] = status.get("realtid_fel") or (None if VT_NYCKEL and VT_HEMLIGHET else FEL_NYCKEL)
            live["alder"] = round(time.time() - live["tid"], 1) if live["tid"] else None
            live["layout"] = omr.version
            self.json(200, live)
        else:
            self.json(404, {"fel": "finns inte"})


if __name__ == "__main__":
    threading.Thread(target=tidtabell_loop, daemon=True).start()
    threading.Thread(target=realtid_loop, daemon=True).start()
    logg(f"kartan på port {PORT}, områden: {', '.join(o.conf['namn'] for o in OMR.values())}")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
