"""Hämtar linjefärgerna för spårvagnarna från Västtrafiks positions-API."""
import base64, json, os, sys, urllib.parse, urllib.request
API = "https://ext-api.vasttrafik.se"
auth = base64.b64encode(f"{os.environ['VASTTRAFIK_KEY']}:{os.environ['VASTTRAFIK_SECRET']}".encode()).decode()
req = urllib.request.Request(f"{API}/token", data=b"grant_type=client_credentials",
    headers={"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"})
with urllib.request.urlopen(req, timeout=20) as r:
    tok = json.load(r)["access_token"]
q = urllib.parse.urlencode(dict(lowerLeftLat=57.60, lowerLeftLong=11.80, upperRightLat=57.83,
                                upperRightLong=12.12, transportModes="tram", limit=200))
with urllib.request.urlopen(urllib.request.Request(f"{API}/pr/v4/positions?{q}",
        headers={"Authorization": f"Bearer {tok}"}), timeout=20) as r:
    pos = json.load(r)
farger = {}
for t in pos:
    l = t["line"]
    farger[l["name"]] = {k: l.get(k) for k in ("backgroundColor", "foregroundColor", "borderColor")}
json.dump(farger, open(sys.argv[1], "w"), indent=1)
print(len(pos), "vagnar;", json.dumps(farger, indent=0))
