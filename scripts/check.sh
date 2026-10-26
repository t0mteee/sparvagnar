#!/usr/bin/env bash
# Kontrollerar det fas 0 ska ge (se README.md): att porten är ledig, att
# nycklarna fungerar, hur många spårvagnar Västtrafiks positions-API ser just
# nu, och om Trafiklabs GTFS har spårgeometri (shapes.txt) för spårvagnarna.
#
# Nycklarna läses från .env. Kör från repots rotmapp:
#   ./scripts/check.sh
#
# GTFS-filen sparas i data/ (gitignorerad) och hämtas högst en gång i veckan
# av det här skriptet; Trafiklabs gratisnivå tillåter 60 hämtningar på 30 dagar.
# Python körs i Docker, i samma image som familjesidan i rahbari, så inget
# installeras på Macen.
set -euo pipefail
cd "$(dirname "$0")/.."

env_val() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -n 1 | tr -d "\"'"; }
export VASTTRAFIK_KEY="${VASTTRAFIK_KEY:-$(env_val VASTTRAFIK_KEY)}"
export VASTTRAFIK_SECRET="${VASTTRAFIK_SECRET:-$(env_val VASTTRAFIK_SECRET)}"
TRAFIKLAB_KEY="${TRAFIKLAB_KEY:-$(env_val TRAFIKLAB_KEY)}"
PORT="$(env_val PORT)"
PORT="${PORT:-8125}"

lyssnar=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1}' || true)
if [ -n "$lyssnar" ]; then
  echo "Port $PORT: upptagen av $lyssnar. Är det inte kartan själv, välj en annan med PORT i .env."
else
  echo "Port $PORT: ledig."
fi
echo

mkdir -p data
ZIP=data/vt.zip
if [ -n "$TRAFIKLAB_KEY" ] && { [ ! -f "$ZIP" ] || [ -n "$(find "$ZIP" -mtime +6)" ]; }; then
  echo "Hämtar Västtrafiks GTFS från Trafiklab ..."
  # Utan Accept-Encoding svarar Trafiklab 406, därav --compressed.
  curl -fsS --compressed -o "$ZIP.tmp" \
    "https://opendata.samtrafiken.se/gtfs/vt/vt.zip?key=$TRAFIKLAB_KEY" \
    && mv "$ZIP.tmp" "$ZIP" \
    || { rm -f "$ZIP.tmp"; echo "Trafiklab: hämtningen misslyckades. Rätt nyckel, och är GTFS Regional Static tillagd i projektet?"; }
fi

docker run --rm -i -e VASTTRAFIK_KEY -e VASTTRAFIK_SECRET \
  -v "$PWD/data:/data:ro" python:3.12-alpine python3 - <<'PY'
import base64
import csv
import io
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter

API = "https://ext-api.vasttrafik.se"
# Spårvägsnätet i Göteborg med marginal. Ett anrop ger högst 200 turer, så
# rektangeln delas i fyra rutor.
SYD, NORR, VAST, OST = 57.60, 57.83, 11.80, 12.12
# GTFS route_type för spårvagn: 0, eller 900-906 i den utökade listan.
SPARVAGN = {"0"} | {str(t) for t in range(900, 907)}


def linjeordning(namn):
    return (not namn.isdigit(), namn.zfill(4))


def vasttrafik():
    key, secret = os.environ.get("VASTTRAFIK_KEY"), os.environ.get("VASTTRAFIK_SECRET")
    if not (key and secret):
        print("Västtrafik: VASTTRAFIK_KEY och VASTTRAFIK_SECRET saknas i .env, hoppar över.")
        return
    req = urllib.request.Request(
        f"{API}/token",
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": "Basic " + base64.b64encode(f"{key}:{secret}".encode()).decode(),
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            token = json.load(resp)["access_token"]
    except urllib.error.HTTPError as e:
        print(f"Västtrafik: nyckel eller hemlighet stämmer inte ({e.code}): {e.read().decode()[:200]}")
        return
    print("Västtrafik: nyckel och hemlighet fungerar.")

    mitt_lat, mitt_lon = (SYD + NORR) / 2, (VAST + OST) / 2
    rutor = [
        (SYD, VAST, mitt_lat, mitt_lon), (SYD, mitt_lon, mitt_lat, OST),
        (mitt_lat, VAST, NORR, mitt_lon), (mitt_lat, mitt_lon, NORR, OST),
    ]
    turer, kvot = {}, {}
    for lat1, lon1, lat2, lon2 in rutor:
        q = urllib.parse.urlencode({
            "lowerLeftLat": lat1, "lowerLeftLong": lon1,
            "upperRightLat": lat2, "upperRightLong": lon2,
            "transportModes": "tram", "limit": 200,
        })
        req = urllib.request.Request(
            f"{API}/pr/v4/positions?{q}", headers={"Authorization": f"Bearer {token}"}
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                svar = json.load(resp)
                kvot.update({k: v for k, v in resp.headers.items()
                             if any(o in k.lower() for o in ("limit", "quota", "remaining", "retry"))})
        except urllib.error.HTTPError as e:
            tips = " Prenumererar applikationen på Planera Resa v4?" if e.code in (401, 403) else ""
            print(f"Västtrafik: positions svarade {e.code}.{tips} {e.read().decode()[:200]}")
            return
        if len(svar) >= 200:
            print("  En ruta gav 200 turer, taket. Rutorna behöver delas mer i fas 2.")
        for t in svar:
            turer[t["detailsReference"]] = t

    realtid = sum(1 for t in turer.values() if t["line"].get("isRealtimeJourney"))
    print(f"Västtrafik: {len(turer)} spårvagnar i trafik just nu, {realtid} med realtid.")
    if not turer:
        print("  Inga alls? Mitt i natten går nästan inga spårvagnar, prova igen dagtid.")
    per_linje = Counter(t["line"]["name"] for t in turer.values())
    if per_linje:
        print("  Per linje: " + ", ".join(
            f"{l}: {n}" for l, n in sorted(per_linje.items(), key=lambda x: linjeordning(x[0]))))
    for t in list(turer.values())[:1]:
        print(f"  Exempel: linje {t['line']['name']} mot {t['direction']}, "
              f"{t['latitude']:.5f}, {t['longitude']:.5f}, färg {t['line'].get('backgroundColor')}")
    print("  Kvotuppgifter i svaret: " + (", ".join(f"{k}={v}" for k, v in kvot.items()) or "inga"))


def gtfs():
    path = "/data/vt.zip"
    if not os.path.exists(path):
        print("Trafiklab: ingen GTFS-fil, TRAFIKLAB_KEY saknas i .env eller hämtningen misslyckades.")
        return
    z = zipfile.ZipFile(path)
    namn = set(z.namelist())

    def rader(fil):
        with z.open(fil) as f:
            yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig"))

    feed = next(rader("feed_info.txt"), {}) if "feed_info.txt" in namn else {}
    print(f"Trafiklab: GTFS {os.path.getsize(path) // 1_000_000} MB, "
          f"gäller {feed.get('feed_start_date', '?')} till {feed.get('feed_end_date', '?')}.")

    linjer = {r["route_id"]: r for r in rader("routes.txt") if r["route_type"] in SPARVAGN}
    if not linjer:
        print("  Inga spårvagnslinjer i routes.txt. Fas 1 får ta linjerna från Västtrafik.")
        return
    turer, former, utan_form = Counter(), set(), 0
    for r in rader("trips.txt"):
        if r["route_id"] in linjer:
            turer[r["route_id"]] += 1
            if r.get("shape_id"):
                former.add(r["shape_id"])
            else:
                utan_form += 1
    print(f"  {len(linjer)} spårvagnslinjer, {sum(turer.values())} turer i filen:")
    for rid, r in sorted(linjer.items(), key=lambda x: linjeordning(x[1].get("route_short_name", ""))):
        farg = f", färg #{r['route_color']}" if r.get("route_color") else ""
        print(f"    {r.get('route_short_name', '?'):>4} {r.get('route_long_name', '')[:40]:40} "
              f"{turer[rid]:6} turer{farg}")

    if "shapes.txt" not in namn:
        print("  Spårgeometri: shapes.txt saknas. Geometrin får hämtas från Västtrafik i stället.")
        return
    print("  Läser shapes.txt ...")
    finns, punkter = set(), 0
    for r in rader("shapes.txt"):
        if r["shape_id"] in former:
            finns.add(r["shape_id"])
            punkter += 1
    with z.open("stop_times.txt") as f:
        avstand = "shape_dist_traveled" in f.readline().decode("utf-8-sig")
    print(f"  Spårgeometri: {len(finns)} av {len(former)} former finns, {punkter} punkter, "
          f"{utan_form} turer saknar form. Avstånd längs spåret i stop_times: "
          f"{'ja' if avstand else 'nej'}.")


vasttrafik()
print()
gtfs()
PY
