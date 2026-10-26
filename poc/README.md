# Prototyp

Första versionen av kartan: LOOM:s schematiska layout, ritad mörk, med
vagnarna som rör sig enligt en dags tidtabell. Ingen realtid ännu. Den kördes
i en Claude-session i molnet och publicerades som en enda HTML-sida.

## Så byggs den

Kräver LOOM (`gtfs2graph`, `topo`, `loom`, `octi`, `transitmap`) och Python 3.
Allt utom `colors.py` klarar sig utan nycklar när tidtabellen väl är hämtad.

```
python3 poc/extract_tram.py data/vt.zip data/tram          # bara spårvagnarna, 122 MB
gtfs2graph -m tram data/tram | topo | loom | octi > data/octi.json
VASTTRAFIK_KEY=... VASTTRAFIK_SECRET=... python3 poc/colors.py data/colors.json
python3 poc/day_trips.py data/tram 2026-10-27 data/day.json
python3 poc/build_poc.py data/octi.json data/day.json data/colors.json "$(command -v transitmap)" data/poc
python3 poc/assemble.py poc/page_template.html data/poc data/sparvagnskartan.html
```

- `colors.py` tar linjefärgerna från de vagnar som är ute just då. Linje 9 och
  13 har reservfärger i `build_poc.py` om de inte syns.
- `build_poc.py` låter transitmap rita varje linje i en tillfällig unik färg,
  så att varje ritad bit kan knytas till sin linje. Vagnens väg mellan två
  hållplatser är kortaste vägen längs just den linjens ritade bitar. Där en
  linje byter plats i knippet vid en hållplats knyts lösa ändar ihop.

## Kända brister

- 12 av 844 sträckor hittar ingen väg längs sin linje och går rakt mellan
  hållplatserna i stället (främst Svingeln–Olskrokstorget och linje 8 genom
  Domkyrkan).
- Stora stationer i centrum blir stora vita block, och hållplatsnamnen är små
  tills man zoomar.
- Layouten görs om vid varje körning och är inte finjusterad för hand.
