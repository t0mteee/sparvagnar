"""Ritar appikonen: en spårvagn rakt framifrån över tre linjer, som på kartan.

  python3 verktyg/rita_ikon.py web/

Ger ikon-180.png (iPhones hemskärm), ikon-192.png och ikon-512.png (manifestet).
Kräver Pillow, men bara här; servern behöver bara de färdiga bilderna.
Motivet håller sig inom mittersta 80 %, så att ikonen tål att beskäras
till en cirkel (maskable).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

S = 1024
BG, VAGN, FONSTER, LJUS = "#0b1016", "#ffb547", "#1b2836", "#fff6d6"
LINJER = ["#ffdd00", "#0071c1", "#d6001c"]

im = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(im)

# Tre linjer snett över ikonen, som ett knippe på kartan.
for i, farg in enumerate(LINJER):
    o = (i - 1) * 70
    d.line([(-100 + o, 900 + o), (1100 + o, -300 + o)], fill=farg, width=46)

# Vagnen: kropp, skylt, vindruta, strålkastare och strömavtagare.
x0, x1, y0, y1 = 300, 724, 300, 860
d.line([(512, 300), (430, 210), (512, 160), (594, 210), (512, 300)], fill=VAGN, width=16, joint="curve")
d.line([(400, 160), (624, 160)], fill=VAGN, width=16)
d.rounded_rectangle([x0, y0, x1, y1], radius=90, fill=VAGN, outline=BG, width=18)
d.rounded_rectangle([x0 + 50, y0 + 40, x1 - 50, y0 + 110], radius=20, fill=FONSTER)
d.rounded_rectangle([x0 + 50, y0 + 140, x1 - 50, y0 + 380], radius=40, fill=FONSTER)
for cx in (x0 + 95, x1 - 95):
    d.ellipse([cx - 38, y1 - 135, cx + 38, y1 - 59], fill=LJUS)
d.rounded_rectangle([x0 + 150, y1 - 60, x1 - 150, y1 - 30], radius=12, fill=BG)

ut = Path(sys.argv[1])
for storlek in (180, 192, 512):
    im.resize((storlek, storlek), Image.LANCZOS).save(ut / f"ikon-{storlek}.png", optimize=True)
print("ikoner i", ut)
