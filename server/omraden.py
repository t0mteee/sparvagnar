"""Områdena sidan visar: var sin karta, sina slags fordon och sin ruta.

ruta (syd, väst, nord, öst) avgränsar området; turer som går ut ur den
ritas bara inom den. Utan ruta tas linjerna med i sin helhet. positioner är
rutorna Västtrafiks positioner hämtas för; ett anrop ger högst 200 fordon, och
får en ruta fler delas den (realtid.py). bara(linjenamn, typ) väljer linjer
när området inte ska ha alla av sina slag. Rutorna följer ungefär kommunerna.

Ordningen är ordningen i menyn på sidan och i appen.
"""
import re

import tidtabell

BUSS_TAG = tidtabell.BUSS | tidtabell.TAG
ALLA = tidtabell.BUSS | tidtabell.TAG | tidtabell.BAT


def stadsbuss(namn, typ):
    """Göteborgs egna bussar (16–99), båtarna och tågen. Regionbussarna med tre
    siffror och X-linjerna hör till grannkommunerna, och E-linjerna (som 4E)
    ersätter spårvagnar bara en tid."""
    return typ != "buss" or bool(re.fullmatch(r"\d+", namn)) and 16 <= int(namn) <= 99


def inte_skolbuss(namn, typ):
    """Linjerna 900–999 kör till och från skolor, bara skoldagar."""
    return typ != "buss" or not re.fullmatch(r"9\d\d", namn)


def omrade(namn, layout, ruta, typer=BUSS_TAG, lagen=("bus", "train"), bara=inte_skolbuss, **extra):
    return dict(namn=namn, layout=layout, typer=typer, ruta=ruta, positioner=[ruta], lagen=list(lagen), bara=bara, **extra)


OMRADEN = {
    "goteborg": {
        "namn": "Göteborg",
        "layout": "layout",
        "typer": tidtabell.SPARVAGN,
        "ruta": None,
        "positioner": [(57.60, 11.80, 57.83, 11.97), (57.60, 11.97, 57.83, 12.12)],
        "lagen": ["tram"],
    },
    # Bussar, båtar och tåg i Göteborgs kommun, på en egen karta bredvid
    # spårvagnarna: alla ihop blir för trångt på en linjekarta.
    "goteborg-buss": dict(omrade("Göteborg, bussar och båtar", "layout/goteborg-buss",
                                 (57.58, 11.72, 57.86, 12.15), ALLA, ("bus", "ferry", "train"), bara=stadsbuss),
                          positioner=[(57.58, 11.72, 57.72, 11.95), (57.72, 11.72, 57.86, 11.95),
                                      (57.58, 11.95, 57.72, 12.15), (57.72, 11.95, 57.86, 12.15)]),
    "kungsbacka": omrade("Kungsbacka", "layout/kungsbacka", (57.29, 11.85, 57.56, 12.42), bara=None),
    "molndal": omrade("Mölndal och Härryda", "layout/molndal", (57.56, 11.95, 57.68, 12.20)),
    "partille": omrade("Partille", "layout/partille", (57.71, 12.05, 57.78, 12.25)),
    "lerum": omrade("Lerum", "layout/lerum", (57.70, 12.15, 57.90, 12.55)),
    "kungalv": omrade("Kungälv", "layout/kungalv", (57.83, 11.70, 58.02, 12.15)),
    "alingsas": omrade("Alingsås", "layout/alingsas", (57.85, 12.35, 58.05, 12.75)),
    "boras": omrade("Borås", "layout/boras", (57.55, 12.65, 57.85, 13.25)),
    "trollhattan": omrade("Trollhättan och Vänersborg", "layout/trollhattan", (58.18, 12.05, 58.50, 12.55)),
    "uddevalla": omrade("Uddevalla", "layout/uddevalla", (58.22, 11.55, 58.50, 12.05)),
    "lidkoping": omrade("Lidköping", "layout/lidkoping", (58.35, 12.90, 58.65, 13.40)),
    "skovde": omrade("Skövde", "layout/skovde", (58.25, 13.65, 58.55, 14.15)),
}
