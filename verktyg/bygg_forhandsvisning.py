"""Bygger en fristående förhandsvisning av sidan, utan server.

  python3 verktyg/bygg_forhandsvisning.py dag.json ut.html

dag.json är det /api/dag svarar. Sidan (web/index.html) används som den är;
ett litet skript framför den svarar på sidans anrop med kartan och
tidtabellen inbakade, och säger att realtid saknas. Resultatet är skrivet
som en sida att publicera, utan egna html-, head- och body-taggar.
"""
import json
import re
import sys
from pathlib import Path

ROT = Path(__file__).resolve().parent.parent
dag_path, ut = sys.argv[1:3]

sida = (ROT / "web" / "index.html").read_text()
svg = (ROT / "layout" / "karta.svg").read_text()
dag = json.loads(Path(dag_path).read_text())
assert "</script" not in svg and "</script" not in json.dumps(dag, ensure_ascii=False)

head = re.search(r"<head>(.*?)</head>", sida, re.S).group(1)
body = re.search(r"<body>(.*?)</body>", sida, re.S).group(1)
head = re.sub(r'<meta (charset|name="viewport")[^>]*>\s*', "", head)
titel = re.search(r"<title>.*?</title>", head).group(0)
head = head.replace(titel, "")

shim = """<script>
// Förhandsvisning: sidans anrop besvaras härifrån i stället för av servern.
(() => {
  const svg = document.getElementById("forhand-karta").textContent;
  const dag = document.getElementById("forhand-dag").textContent;
  const svar = (text, typ) => Promise.resolve(new Response(text, { headers: { "Content-Type": typ } }));
  const fetch_ = window.fetch.bind(window);
  window.fetch = (url, ...rest) => {
    if (url === "karta.svg") return svar(svg, "image/svg+xml");
    if (url === "api/dag") return svar(dag, "application/json");
    if (url === "api/live") return svar(JSON.stringify({ vagnar: [], tid: 0, fel: "Förhandsvisningen har ingen realtid." }), "application/json");
    return fetch_(url, ...rest);
  };
})();
</script>
"""
data = (f'<script type="text/plain" id="forhand-karta">{svg}</script>\n'
        f'<script type="application/json" id="forhand-dag">{json.dumps(dag, ensure_ascii=False, separators=(",", ":"))}</script>\n')
Path(ut).write_text(f"{titel}\n{head.strip()}\n{data}{shim}{body.strip()}\n")
print(ut, Path(ut).stat().st_size // 1000, "kB")
