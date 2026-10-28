"""Bygger en fristående förhandsvisning av sidan, utan server.

  python3 verktyg/bygg_forhandsvisning.py ut.html goteborg=dag-goteborg.json kungsbacka=dag-kungsbacka.json

Varje dag-fil är det /api/dag?omrade= svarar för området. Sidan
(web/index.html) används som den är; ett litet skript framför den svarar på
sidans anrop med områdenas kartor och tidtabeller inbakade, och säger att
realtid saknas. Resultatet är skrivet som en sida att publicera, utan egna
html-, head- och body-taggar.
"""
import json
import re
import sys
from pathlib import Path

ROT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROT / "server"))
from omraden import OMRADEN  # noqa: E402

ut, *par = sys.argv[1:]
sida = (ROT / "web" / "index.html").read_text()
data = {}
for p in par:
    omrade, dag_path = p.split("=", 1)
    svg = (ROT / OMRADEN[omrade]["layout"] / "karta.svg").read_text()
    dag = json.loads(Path(dag_path).read_text())
    # Bara de områden som är inbakade går att byta till.
    dag["omraden"] = [o for o in dag.get("omraden", []) if any(q.startswith(o[0] + "=") for q in par)]
    data[omrade] = {"svg": svg, "dag": dag}
text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
assert "</script" not in text

head = re.search(r"<head>(.*?)</head>", sida, re.S).group(1)
body = re.search(r"<body>(.*?)</body>", sida, re.S).group(1)
head = re.sub(r'<meta (charset|name="viewport")[^>]*>\s*', "", head)
# Manifest och ikoner finns bara på servern.
head = re.sub(r'<link rel="(manifest|apple-touch-icon)"[^>]*>\s*', "", head)
titel = re.search(r"<title>.*?</title>", head).group(0)
head = head.replace(titel, "")

shim = """<script>
// Förhandsvisning: sidans anrop besvaras härifrån i stället för av servern.
(() => {
  const data = JSON.parse(document.getElementById("forhand-data").textContent);
  const svar = (text, typ) => Promise.resolve(new Response(text, { headers: { "Content-Type": typ } }));
  const fetch_ = window.fetch.bind(window);
  window.fetch = (url, ...rest) => {
    const u = new URL(String(url), "http://forhand/"), omr = data[u.searchParams.get("omrade")] || Object.values(data)[0];
    if (u.pathname === "/karta.svg") return svar(omr.svg, "image/svg+xml");
    if (u.pathname === "/api/dag") return svar(JSON.stringify(omr.dag), "application/json");
    if (u.pathname === "/api/live") return svar(JSON.stringify({ vagnar: [], tid: 0, fel: "Förhandsvisningen har ingen realtid." }), "application/json");
    return fetch_(url, ...rest);
  };
})();
</script>
"""
Path(ut).write_text(f"{titel}\n{head.strip()}\n<script type=\"application/json\" id=\"forhand-data\">{text}</script>\n"
                    f"{shim}{body.strip()}\n")
print(ut, Path(ut).stat().st_size // 1000, "kB")
