"""Kartan som vektordata, för appen som ritar den själv i stället för att visa SVG.

Läser karta.svg (som bygg_layout.py skriver) och ger samma innehåll som enkla
listor, i ritordning:

  streck  [kant, linje, färg, bredd, [x, y, x, y, ...], [sträcka, ...]]
          kant är 1 för linjens kant (färgen väljs efter temat) och 0 för
          själva linjen. Sträckorna pekar in i dagens "strackor" och används
          för att tona ner det som inte trafikeras idag.
  prickar [x, y, r, linje, namn]            vit prick där en linje stannar
  band    [x1, y1, x2, y2, bredd, kant, namn]   bandet mellan prickarna
  knutar  [x, y, r, namn]                   bytespunkt som cirkel
  kapslar [x1, y1, x2, y2, bredd, kant, namn]   bytespunkt i flera noder
  namn    [[rad, ...], x, y, storlek, ankare, knut, namn]
          y är första radens baslinje, nästa rad ligger storlek * 1.12 under.

namn i prickar, band, knutar och kapslar är hållplatsens namn.
"""
import re
import xml.etree.ElementTree as ET

NS = "{http://www.w3.org/2000/svg}"


def _tal(v):
    return round(float(v), 1)


def _linje(klass):
    m = re.search(r"\bL-(\S+)", klass)
    return m.group(1) if m else ""


def vektor(svg):
    rot = ET.fromstring(svg)
    w, h = (float(v) for v in rot.get("viewBox").split()[2:])
    ut = {"storlek": [w, h], "streck": [], "prickar": [], "band": [], "knutar": [], "kapslar": [], "namn": []}
    for el in rot.iter():
        tagg, klass = el.tag.replace(NS, ""), el.get("class", "")
        if tagg == "polyline":
            stil = el.get("style", "")
            farg = re.search(r"stroke:(#[0-9a-fA-F]{6})", stil)
            bredd = re.search(r"stroke-width:([\d.]+)", stil)
            pts = [_tal(c) for p in el.get("points").split() for c in p.split(",")]
            s = [int(i) for i in el.get("data-s", "").split()]
            ut["streck"].append([1 if "outline" in klass else 0, _linje(klass), farg.group(1) if farg else "#8a97a6",
                                 float(bredd.group(1)) if bredd else 3.0, pts, s])
        elif tagg == "circle" and "hpl" in klass.split():
            ut["prickar"].append([_tal(el.get("cx")), _tal(el.get("cy")), float(el.get("r")), _linje(klass), el.get("data-n", "")])
        elif tagg == "circle" and "knut" in klass.split():
            ut["knutar"].append([_tal(el.get("cx")), _tal(el.get("cy")), float(el.get("r")), el.get("data-n", "")])
        elif tagg == "line":
            post = [_tal(el.get("x1")), _tal(el.get("y1")), _tal(el.get("x2")), _tal(el.get("y2")),
                    float(el.get("stroke-width")), 1 if klass.endswith("-kant") or "-kant " in klass else 0, el.get("data-n", "")]
            ut["kapslar" if klass.startswith("knut") else "band"].append(post)
        elif tagg == "text":
            rader = [t.text or "" for t in el.iter(NS + "tspan")] or [el.text or ""]
            ut["namn"].append([rader, _tal(el.get("x")), _tal(el.get("y")), float(el.get("font-size")),
                               el.get("text-anchor", "start"), "knut" in klass.split(), el.get("data-n", "")])
    return ut
