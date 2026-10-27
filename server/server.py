"""Spårvagnskartan: sidan, dagens tidtabell och Västtrafiks positioner.

Körs i Docker på servern (se docker-compose.yml). Håller nycklarna på
serversidan. Bara standardbiblioteket, ingen pip.

  GET /             sidan (web/index.html, läses per anrop)
  GET /karta.svg    kartan (layout/karta.svg)
  GET /api/dag      dagens turer, vägar och linjer
  GET /api/live     senaste positionerna, kopplade till turerna
  GET /api/status   vad servern håller på med

Tidtabellen hämtas från Trafiklab högst en gång per dygn. Positionerna
hämtas var 5:e sekund, men bara medan någon har sidan öppen.
"""
import gzip
import json
import os
import sys
import threading
import time
import traceback
import urllib.request
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import realtid  # noqa: E402
import tidtabell  # noqa: E402

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

lager = threading.Lock()
tillstand = {
    "dag": None,         # intern dagsdata
    "klient": None,      # gzippad JSON till sidan
    "matchning": None,
    "live": {"vagnar": [], "tid": 0},
    "tittare": 0.0,
    "status": {"tidtabell": "startar", "realtid": "väntar"},
}


def logg(*a):
    print(tidtabell.stockholm_nu().strftime("%H:%M:%S"), *a, flush=True)


def satt_status(**kw):
    with lager:
        tillstand["status"].update(kw)


# ---------- Tidtabellen ----------

def hamta_gtfs():
    """Hämtar Västtrafiks GTFS från Trafiklab om filen saknas eller är äldre än 20 timmar."""
    if not TL_NYCKEL:
        return
    if ZIP.exists() and time.time() - ZIP.stat().st_mtime < 20 * 3600:
        return
    logg("hämtar tidtabellen från Trafiklab")
    satt_status(tidtabell="hämtar från Trafiklab")
    req = urllib.request.Request(f"https://opendata.samtrafiken.se/gtfs/vt/vt.zip?key={TL_NYCKEL}",
                                 headers={"Accept-Encoding": "gzip"})
    tmp = ZIP.with_suffix(".tmp")
    with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
        kalla = gzip.GzipFile(fileobj=r) if r.headers.get("Content-Encoding") == "gzip" else r
        while bit := kalla.read(1 << 20):
            f.write(bit)
    tmp.replace(ZIP)
    logg("tidtabellen hämtad,", ZIP.stat().st_size // 1_000_000, "MB")


def bygg(dag, layout):
    cache = DATA / f"dag-{dag.isoformat()}.json.gz"
    if cache.exists() and cache.stat().st_mtime >= ZIP.stat().st_mtime:
        with gzip.open(cache, "rt", encoding="utf-8") as f:
            d = json.load(f)
        d["former"] = {k: [tuple(p) for p in v] for k, v in d["former"].items()}
        d["stationer"] = {k: tuple(v) for k, v in d["stationer"].items()}
        return d
    logg("bygger tidtabellen för", dag)
    satt_status(tidtabell=f"bygger {dag}")
    t0 = time.time()
    d = tidtabell.bygg_dag(ZIP, dag)
    with gzip.open(cache, "wt", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    for gammal in DATA.glob("dag-*.json.gz"):
        if gammal.name < f"dag-{(dag - timedelta(days=2)).isoformat()}":
            gammal.unlink()
    logg(f"tidtabellen för {dag}: {len(d['turer'])} turer på {time.time() - t0:.0f} s")
    return d


def tidtabell_loop():
    layout = json.loads((ROT / "layout" / "layout.json").read_text())
    while True:
        try:
            DATA.mkdir(parents=True, exist_ok=True)
            hamta_gtfs()
            if not ZIP.exists():
                satt_status(tidtabell="ingen tidtabell: TRAFIKLAB_KEY saknas i .env")
            else:
                idag = tidtabell.stockholm_nu().date()
                with lager:
                    aktuell = tillstand["dag"] and tillstand["dag"]["dag"]
                if aktuell != idag.isoformat():
                    d = bygg(idag, layout)
                    klient = gzip.compress(json.dumps(tidtabell.klientdata(d, layout), ensure_ascii=False,
                                                      separators=(",", ":")).encode())
                    with lager:
                        tillstand.update(dag=d, klient=klient, matchning=realtid.Matchning(d))
                    satt_status(tidtabell=f"{idag}, version {d['version']}, {len(d['turer'])} turer")
        except Exception as e:
            logg("tidtabellen:", repr(e))
            traceback.print_exc()
            satt_status(tidtabell=f"fel: {e}")
        time.sleep(60)


# ---------- Realtiden ----------

def realtid_loop():
    if not (VT_NYCKEL and VT_HEMLIGHET):
        satt_status(realtid=FEL_NYCKEL)
        return
    vt = realtid.Vasttrafik(VT_NYCKEL, VT_HEMLIGHET)
    paus = INTERVALL
    while True:
        start = time.time()
        with lager:
            tittar = time.time() - tillstand["tittare"] < TITTAR_S
            matchning = tillstand["matchning"]
        if not tittar or not matchning:
            satt_status(realtid="vilar, ingen tittar" if matchning else "väntar på tidtabellen")
            time.sleep(1)
            continue
        try:
            vagnar = vt.positioner()
            nu_dt = tidtabell.stockholm_nu()
            nu = nu_dt.hour * 3600 + nu_dt.minute * 60 + nu_dt.second + nu_dt.microsecond / 1e6
            ut = matchning.matcha(vagnar, nu)
            with lager:
                tillstand["live"] = {"vagnar": ut, "tid": time.time(), "nu": round(nu, 1),
                                     "dag": matchning.dag["dag"]}
            satt_status(realtid=f"{len(ut)} vagnar, {sum(1 for v in ut if v['tur'] >= 0)} kopplade",
                        realtid_fel=None)
            paus = INTERVALL
        except Exception as e:
            logg("realtiden:", repr(e))
            satt_status(realtid_fel=str(e))
            paus = min(60, paus * 2)
        time.sleep(max(0.5, paus - (time.time() - start)))


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
        vag = self.path.split("?")[0]
        if vag in ("/", "/index.html"):
            self.skicka(200, (ROT / "web" / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif vag == "/karta.svg":
            self.skicka(200, (ROT / "layout" / "karta.svg").read_bytes(), "image/svg+xml")
        elif vag == "/api/dag":
            with lager:
                klient = tillstand["klient"]
            if klient:
                self.skicka(200, klient, "application/json; charset=utf-8", gz=True)
            else:
                self.json(503, {"fel": tillstand["status"]["tidtabell"]})
        elif vag == "/api/live":
            with lager:
                tillstand["tittare"] = time.time()
                live, status = dict(tillstand["live"]), dict(tillstand["status"])
            live["fel"] = status.get("realtid_fel") or (None if VT_NYCKEL and VT_HEMLIGHET else FEL_NYCKEL)
            live["alder"] = round(time.time() - live["tid"], 1) if live["tid"] else None
            self.json(200, live)
        elif vag == "/api/status":
            with lager:
                self.json(200, dict(tillstand["status"], tittare_for_s=round(time.time() - tillstand["tittare"])))
        else:
            self.json(404, {"fel": "finns inte"})


if __name__ == "__main__":
    threading.Thread(target=tidtabell_loop, daemon=True).start()
    threading.Thread(target=realtid_loop, daemon=True).start()
    logg(f"spårvagnskartan på port {PORT}")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
