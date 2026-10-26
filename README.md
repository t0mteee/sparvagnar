# sparvagnar

Göteborgs alla spårvagnar i rörelse på en schematisk linjekarta: raka linjer,
45°-vinklar, prickar som glider mellan hållplatserna i takt med verkligheten.
Körs i Docker på en hemmaserver och nås på http://localhost:8125.

## Faser

- **Fas 0, nu:** konton och nycklar hos Västtrafik och Trafiklab.
- **Fas 1, linjekartan:** layouten genereras ur tidtabellen och ritas i
  webbläsaren. Linjer och hållplatser, inga vagnar än.
- **Fas 2, vagnar enligt tidtabell:** alla vagnar rör sig som de ska enligt
  tidtabellen. Inga realtidsanrop.
- **Fas 3, realtid:** Västtrafiks positioner var 5:e sekund, bara medan någon
  har sidan öppen.
- **Fas 4, filmkänslan:** mörkt kontrollrumsutseende, klick på en vagn
  (linje, destination, försening, nästa hållplats), störningar, helskärm för
  TV:n.

## Linjekartan

Layouten är vår egen; Västtrafiks linjenätskarta är deras och ritas inte av.
Den genereras en gång ur tidtabellen med det öppna verktyget
[LOOM](https://github.com/ad-freiburg/loom), som gör om ett linjenät till en
schematisk karta:

```
gtfs2graph -m tram vt.zip | topo | loom | octi
```

Resultatet är en GeoJSON med hållplatser och linjesträckor, som checkas in och
finjusteras för hand där det behövs (namnplacering, raka huvudstråk). Den görs
om bara när linjenätet ändras.

## Så rör sig vagnarna

En schematisk karta stämmer inte med verkligheten, så en vagns läge beskrivs
som "mellan hållplats A och B, 40 % av vägen" och läggs sedan ut på kartan:

1. Västtrafiks positioner är inte GPS. De räknas fram från tiden sedan vagnen
   lämnade senaste hållplatsen, sträckan till nästa och en genomsnittsfart.
2. Servern lägger in positionen på linjens verkliga spår (GTFS `shapes.txt`)
   och räknar ut hur långt mellan hållplatserna vagnen har kommit.
3. Samma andel läggs ut på kartans sträcka mellan A och B.
4. Webbläsaren visar läget några sekunder i efterhand och låter vagnen glida
   mellan de två senaste lägena. Ingen vagn hoppar eller backar.
5. Turer utan realtid går efter tidtabellen, som ger A, B och andelen direkt.

## Västtrafiks API i praktiken

Uppmätt med `scripts/check.sh` en måndagskväll kl. 23.50:

- 41–50 spårvagnar i trafik på 13 linjer (1–12 och X). Allihop ryms i ett
  anrop, men dagtid är det fler, så fyra rutor används ändå.
- Varje position har linje, destination, Västtrafiks linjefärger och en
  turreferens. Riktning eller fart saknas.
- Positionerna ändras i steg, inte vid varje anrop. Efter 5 och 10 sekunder
  hade samma 32 av 50 vagnar flyttat sig, efter 20 sekunder 44. Var 5:e
  sekund räcker gott.
- Turdetaljerna (`includes=servicejourneycalls`) ger alla hållplatser med
  koordinater och planerade och beräknade tider. `servicejourneycoordinates`
  ger turens geometri, men gles: 46 punkter på 15 hållplatser.
- Inga kvotuppgifter i svaren. Token gäller ett dygn.
- `isRealtimeJourney` var falskt för alla vagnar och beräknade tider var
  lika med planerade. Kollas igen dagtid.

## Fas 0: konton

Båda är gratis. Nycklarna hamnar i `.env`, som aldrig committas.

```
git clone https://github.com/t0mteee/sparvagnar.git
cd sparvagnar
cp .env.example .env
```

### Västtrafik (positionerna)

1. Gå till developer.vasttrafik.se och skapa ett konto.
2. Skapa en applikation, till exempel "Spårvagnskartan".
3. Klicka på "Prenumerera på nytt API" och välj **Planera Resa v4**.
4. Kopiera applikationens nyckel och hemlighet till `.env` som
   `VASTTRAFIK_KEY` och `VASTTRAFIK_SECRET`.
5. Titta efter hur stor kvoten är på prenumerationen. Fas 3 behöver ungefär
   24 anrop i minuten medan sidan är öppen.

### Trafiklab (tidtabell och spårgeometri)

1. Gå till developer.trafiklab.se/register, skapa ett konto och bekräfta
   mejlet.
2. Klicka på "New project" uppe till höger, ge projektet ett namn och en kort
   beskrivning.
3. Välj **GTFS Regional Static** i listan och klicka på "Add API key to
   project".
4. Kopiera nyckeln till `.env` som `TRAFIKLAB_KEY`.

Gratisnivån tillåter 60 hämtningar av tidtabellen på 30 dagar. Kartan hämtar
en per dygn.

### Kontrollera

```
./scripts/check.sh
```

Skriptet visar om porten är ledig, om nycklarna fungerar, hur många
spårvagnar som är i trafik just nu per linje, vilka kvotuppgifter Västtrafik
skickar med, och om tidtabellen har spårgeometri för spårvagnarna.
Tidtabellen sparas i `data/`.
