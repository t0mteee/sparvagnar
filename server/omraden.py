"""Områdena sidan visar: var sin karta, sina slags fordon och sin ruta.

ruta (syd, väst, nord, öst) avgränsar området; turer som går ut ur den
ritas bara inom den. Utan ruta tas linjerna med i sin helhet. positioner är
rutorna Västtrafiks positioner hämtas för; ett anrop ger högst 200 fordon.
"""
import tidtabell

OMRADEN = {
    "goteborg": {
        "namn": "Göteborg",
        "layout": "layout",
        "typer": tidtabell.SPARVAGN,
        "ruta": None,
        "positioner": [(57.60, 11.80, 57.83, 11.97), (57.60, 11.97, 57.83, 12.12)],
        "lagen": ["tram"],
    },
    "kungsbacka": {
        # Ungefär Kungsbacka kommun.
        "namn": "Kungsbacka",
        "layout": "layout/kungsbacka",
        "typer": tidtabell.BUSS | tidtabell.TAG,
        "ruta": (57.29, 11.85, 57.56, 12.42),
        "positioner": [(57.29, 11.85, 57.56, 12.42)],
        "lagen": ["bus", "train"],
    },
}
