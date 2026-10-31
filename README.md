# sparvagnar

Göteborgs alla spårvagnar i rörelse på en schematisk linjekarta: raka linjer,
45°-vinklar, prickar som glider mellan hållplatserna i takt med verkligheten.
En meny byter till Göteborgs bussar och båtar, eller till bussarna och tågen i
någon av de andra kommunerna i Västtrafiks område, var och en på sin egen
karta. Ett filter väljer vilka slags fordon och vilka linjer som syns.
Körs i Docker på en hemmaserver och nås på http://localhost:8125.

## Faser

- **Fas 0, klar:** konton och nycklar hos Västtrafik och Trafiklab.
- **Fas 1, klar:** layouten genereras ur tidtabellen med LOOM och ritas i
  webbläsaren. Finjustering för hand återstår.
- **Fas 2, klar:** alla vagnar rör sig enligt tidtabellen, med uppspelning i
  10× och 60×.
- **Fas 3, klar att köra på servern:** Västtrafiks positioner var 5:e sekund,
  bara medan någon har sidan öppen, kopplade till turerna med försening.
- **Fas 4, kul och informativ:** dag- och nattema, ledade spårvagnar som
  följer spåret när man zoomar in eller väljer en linje, Åk med (kameran
  följer vagnen och visar hållplatsraden som i vagnen), avgångstavla per
  hållplats, uppdrag (hitta en viss vagn), Visste du?-fakta ur dagens
  tidtabell och en spårvagnsklocka. Kvar: störningar, helskärm för TV:n.
  Vagnmodellen finns inte i Västtrafiks öppna data, så formen är generisk.
- **Fas 6, iOS-app (påbörjad):** en riktig app i Swift i `ios/`, som ritar
  kartan och vagnarna själv och hämtar från samma server. Se `ios/README.md`.
- **Fas 5, fler områden:** Kungsbacka kommun med bussar och tåg, på en egen
  linjekarta bakom en flik. Bussar ritas som bussar och tåg som tåg. Områdena
  står i `server/omraden.py`.
- **Fas 7, hela Västtrafik:** Göteborgs bussar, båtar och tåg, och tio
  områden till (se Områdena nedan). Flikarna har blivit en meny, och ett
  filter (tratten) gömmer slag av fordon eller enskilda linjer.

Västtrafiks officiella spårvagnskarta har ingen öppen licens och används
därför inte; sidan länkar till den. `verktyg/bygg_forhandsvisning.py` gör en
fristående förhandsvisning av sidan med tidtabellen inbakad.

## Köra på servern

```
git clone https://github.com/t0mteee/sparvagnar.git
cd sparvagnar
cp .env.example .env       # fyll i de tre nycklarna
./scripts/check.sh         # port, nycklar och tidtabell
docker compose up -d
```

Sidan finns sedan på http://localhost:8125, och från andra enheter på
hemmanätet på samma port med serverns namn. Namnet uppe till vänster öppnar
listan över områden; `?omrade=kungsbacka` i adressen går direkt dit.

På iPhone går sidan att lägga på hemskärmen (Dela, Lägg till på hemskärmen).
Den öppnas då i helskärm som en egen app, med ikon och namnet Trafiken
(`web/manifest.webmanifest`, ikonerna ritas av `verktyg/rita_ikon.py`). Sidan
sitter fast i fönstret och går inte att zooma utanför kartan, så att menyn
längst ner inte kan hamna utanför skärmen. Har appen legat i bakgrunden mer
än en halvtimme laddas den om när den öppnas. Första starten hämtar
tidtabellen och bygger dagens turer, vilket tar en eller ett par minuter;
sidan väntar och säger till under tiden. Läget syns på `/api/status`.

### Nå sidan utifrån

Sidan kan nås från hela nätet genom en Cloudflare Tunnel. Ingen port öppnas i
routern och serverns adress syns inte; tunneln går ut från Macen till
Cloudflare. Domänens DNS ska ligga hos Cloudflare.

1. I Cloudflare: Zero Trust, Networks, Tunnels, Create a tunnel. Välj
   Cloudflared, döp den till `sparvagnar` och välj Docker som miljö.
   Kopiera token, den långa strängen efter `--token`, till `TUNNEL_TOKEN` i
   `.env`. Kör inte kommandot Cloudflare visar; tunneln startas av compose.
2. Lägg till en publik adress (Public hostname, även kallat Published
   application route): välj en underdomän och domänen, Type `HTTP` och URL
   `sparvagnar:8125`.
3. Starta med tunneln:

```
docker compose --profile natet up -d
docker compose logs tunnel        # ska visa "Registered tunnel connection"
```

Sidan är öppen för alla som har adressen; den visar bara spårvagnar och
nycklarna stannar i containern. Vagnarnas lägen hämtas en gång var femte
sekund så länge någon har sidan öppen, hur många som än tittar.

Servern (`server/`) är Python med bara standardbiblioteket:

- `tidtabell.py` hämtar Västtrafiks GTFS från Trafiklab högst en gång per
  dygn och bygger dagens spårvagnsturer, cachade i `data/`.
- `realtid.py` hämtar positionerna och kopplar varje vagn till sin tur: samma
  linje och skylt, och den tur där positionen ligger längs spåret närmast i
  tid. Skillnaden blir vagnens försening.
- `server.py` serverar sidan (`web/index.html`), områdets karta och tre
  API-anrop: `/api/dag`, `/api/live` och `/api/status`. Kartan och de två
  första tar `?omrade=` (`goteborg` är standard).
- `omraden.py` anger områdena: vilka slags fordon, rutan de avgränsas av,
  vilka linjer och var kartan ligger.
- `vektor.py` gör om kartan till vektordata för iOS-appen, på `/api/karta`.

Sidan visar varje vagn som sin tur, förskjuten med förseningen. Ändras
förseningen glider vagnen ikapp eller stannar en stund, men backar aldrig.
Vagnar som inte går att koppla till en tur visas som en ring vid närmaste
hållplats.

## Linjekartan

Layouten är vår egen; Västtrafiks linjenätskarta är deras och ritas inte av.
Den genereras en gång per område ur tidtabellen med det öppna verktyget
[LOOM](https://github.com/ad-freiburg/loom), som gör om ett linjenät till en
schematisk karta. Spårvagnarna i Göteborg:

```
python3 verktyg/plocka_gtfs.py data/vt.zip data/tram goteborg
python3 verktyg/vanliga_turer.py data/tram data/tram_vanlig
gtfs2graph -m tram data/tram_vanlig > graph.json
topo -d 110 < graph.json > topo.json
python3 verktyg/forstora_centrum.py topo.json 0.55 | loom | octi > layout/octi.json
python3 verktyg/jamna_avstand.py layout/octi.json > layout/octi_jamn.json
python3 verktyg/bygg_layout.py layout/octi_jamn.json data/tram colors.json "$(command -v transitmap)" layout/
```

Bussarna och tågen i Kungsbacka. Västtrafik ger alla bussar där samma gula
färg, så `farga_linjer.py` väljer egna färger, och fisheye-centrum är
Kungsbacka station:

```
python3 verktyg/plocka_gtfs.py data/vt.zip data/kungsbacka kungsbacka
python3 verktyg/vanliga_turer.py data/kungsbacka data/kungsbacka_vanlig
python3 verktyg/farga_linjer.py data/kungsbacka_vanlig > layout/kungsbacka/farger.json
gtfs2graph data/kungsbacka_vanlig > graph.json
topo -d 110 < graph.json > topo.json
python3 verktyg/forstora_centrum.py topo.json 0.6 57.4905 12.0797 | loom | octi > layout/kungsbacka/octi.json
python3 verktyg/jamna_avstand.py layout/kungsbacka/octi.json > layout/kungsbacka/octi_jamn.json
python3 verktyg/bygg_layout.py layout/kungsbacka/octi_jamn.json data/kungsbacka layout/kungsbacka/farger.json \
    "$(command -v transitmap)" layout/kungsbacka/ --knutar "Kungsbacka station"
```

De andra områdena byggs på samma sätt; bara fisheye-centrum, styrkan och
bytespunkterna skiljer (se Områdena nedan). `<omr>` är områdets nyckel i
`server/omraden.py`:

```
python3 verktyg/plocka_gtfs.py data/vt.zip data/<omr> <omr>
python3 verktyg/vanliga_turer.py data/<omr> data/<omr>_vanlig
python3 verktyg/farga_linjer.py data/<omr>_vanlig > layout/<omr>/farger.json
gtfs2graph data/<omr>_vanlig > graph.json
topo -d 110 < graph.json > topo.json
python3 verktyg/forstora_centrum.py topo.json <styrka> <lat> <lon> | loom | octi > layout/<omr>/octi.json
python3 verktyg/jamna_avstand.py layout/<omr>/octi.json > layout/<omr>/octi_jamn.json
python3 verktyg/bygg_layout.py layout/<omr>/octi_jamn.json data/<omr>_vanlig layout/<omr>/farger.json \
    "$(command -v transitmap)" layout/<omr>/ --knutar "<bytespunkt>,<bytespunkt>"
```

LOOM:s egen Dockerfile bygger inte längre (för gammal cmake i Ubuntu 20.04).
Den här gör det, utan Gurobi:

```
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install --no-install-recommends -y ca-certificates libglpk-dev glpk-utils \
    coinor-libcbc-dev coinor-cbc libprotobuf-dev libzip-dev protobuf-compiler make cmake g++ git
RUN git clone --recurse-submodules https://github.com/ad-freiburg/loom /loom
RUN cd /loom && mkdir -p build && cd build && cmake .. && make -j6 install
CMD ["loom"]
```

`docker build -t loom .` i en mapp med den filen, sedan `docker run --rm -i loom
<verktyg>`. `gtfs2graph` läser en mapp, så den skickas in som tar:
`tar -C data/<omr>_vanlig -cf - . | docker run --rm -i loom sh -c 'mkdir /g &&
tar -C /g -xf - && gtfs2graph /g'`.

### Områdena

Varje område är en kommun (eller två som hänger ihop) och har sin egen
karta. Rutorna i `server/omraden.py` följer ungefär kommungränserna. En linje
som går ut ur rutan ritas bara inom den.

| Nyckel | Område | Fordon | Styrka | Bytespunkter |
| --- | --- | --- | --- | --- |
| `goteborg` | Göteborg | spårvagnar | 0.55 | se ovan |
| `goteborg-buss` | Göteborg, bussar och båtar | bussar 16–99, båtar, tåg | 0.55 | Frölunda Torg, Hjalmar Brantingsplatsen, Angered Centrum, Marklandsgatan, Korsvägen, Brunnsparken, Nils Ericson Terminalen |
| `kungsbacka` | Kungsbacka | bussar och tåg | 0.6 | Kungsbacka station |
| `molndal` | Mölndal och Härryda | bussar och tåg | 0.6 | Mölndals bro, Mölnlycke resecentrum |
| `partille` | Partille | bussar och tåg | 0.6 | Partille centrum |
| `lerum` | Lerum | bussar och tåg | 0.6 | Lerum station, Floda station, Gråbo busstation |
| `kungalv` | Kungälv | bussar och tåg | 0.6 | Kungälv resecentrum, Ytterby station |
| `alingsas` | Alingsås | bussar och tåg | 0.6 | Alingsås station, Lendahlsgatan |
| `boras` | Borås | bussar och tåg | 0.45, `topo -d 150` | Borås resecentrum, Södra Älvsborgs sjukhus |
| `trollhattan` | Trollhättan och Vänersborg | bussar och tåg | 0.7 | Trollhättan resecentrum, Vänersborg resecentrum, NÄL |
| `uddevalla` | Uddevalla | bussar och tåg | 0.6 | Kampenhof, Uddevalla central |
| `lidkoping` | Lidköping | bussar och tåg | 0.6 | Nya stadens torg, Lidköping resecentrum |
| `skovde` | Skövde | bussar och tåg | 0.6 | Skövde resecentrum |

Fisheye-centrum är den största bytespunkten. Skollinjerna 900–999 ritas inte,
eftersom de bara kör skoldagar.

Göteborgs bussar har en egen karta i stället för att ritas på
spårvagnskartan. Spårvagnskartan har 12 linjer; med stadsbussarna blir det
över 60, och knippena genom centrum blir då så breda att spårvagnarna
försvinner i dem. Regionbussarna (tre siffror) och X-linjerna kör till
grannkommunerna och syns på deras kartor, och E-linjerna ersätter spårvagnar
en tid och ritas inte. Båtarna i älven och skärgården och pendeltågen inom
kommunen kommer med, eftersom de hör till samma resor.

`plocka_gtfs.py` plockar ut områdets linjer ur hela Västtrafiks tidtabell.
Har området en ruta tas bara den del av turerna som ligger inom den, så att
tåg och expressbussar slutar vid gränsen.

`vanliga_turer.py` tar bara med det vanliga linjenätet de närmaste åtta
veckorna: sträckor som minst 4 % av linjens turer kör, minst varannan dag.
Omledningar, turer till vagnhallen, ersättningsbussar, extralinjen X och
säsongslinjen 13 ritas inte, annars blir knippena breda av linjer som nästan
aldrig går där. Vagnar på
sådana turer lånar en annan linjes väg mellan samma hållplatser.

`topo -d 110` slår ihop spår som ligger inom 110 meter från varandra, så att
centrum får färre små korsningar; längre avstånd slår ihop riktiga
hållplatser. `forstora_centrum.py` förstorar centrum och krymper förorterna
innan kartan görs schematisk, som på en klassisk linjekarta.
`jamna_avstand.py` sprider ut hållplatserna jämnt mellan korsningarna.

`bygg_layout.py` ritar linjerna med transitmap och lägger sedan till det som
gör den till en linjekarta: en vit prick på varje linje som stannar, ihopbunden
tvärs över knippet; en vit cirkel vid de stora bytespunkterna, eller en kapsel
när bytespunkten ligger i flera noder (som Kungsbacka station); och alla
hållplatsnamn, utplacerade så att de inte krockar med linjer eller varandra.
Varje linjebit och hållplats i kartan märks dessutom med sträckorna och namnet
den hör till, så att sidan kan tona ner det som ingen vagn kör idag, till
exempel ett avstängt spår.

Resultatet ligger i `layout/` för Göteborgs spårvagnar och i `layout/<omr>/`
för de andra:
LOOM:s graf (`octi.json` och den utjämnade `octi_jamn.json`), kartan
(`karta.svg`) och vagnarnas vägar längs varje linje mellan hållplatserna
(`layout.json`). Servern läser bara det, så varken LOOM
eller transitmap behövs på servern. Görs om när linjenätet ändras.
Tidtabellsdatan från Trafiklab är CC0.

## Filtret

Tratten bland knapparna (i appen knappen med de tre strecken) öppnar filtret:
en knapp per slag av fordon i området (spårvagnar, bussar, tåg, båtar) och en
per linje. Det som är avslaget göms på kartan, i linjeraden, bland vagnarna
och på avgångstavlorna. Med något gömt göms också linjer och hållplatser som
ingen kör idag, så att bara det valda syns. Filtret sparas per område, i
webbläsaren (`localStorage`) och i appen (`UserDefaults`).

Västtrafik ger högst 200 fordon per anrop. Får servern så många för en ruta
delas rutan i fyra och hämtas igen (`realtid.py`), så att Göteborgs bussar
mitt på dagen inte tappas.

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

## Tidtabellen i praktiken

Västtrafiks GTFS från Trafiklab, version 2026-10-26 med trafik till juni 2027:

- 96 MB packad. 15 spårvagnslinjer: 1–13 och två X-linjer (extravagnar).
  Linje 13 har bara 55 turer.
- Spårgeometri finns för alla turer: 500 former med 160 000 punkter, och
  `stop_times.txt` anger avståndet längs spåret vid varje hållplats. Det är
  precis vad "mellan A och B" behöver.
- Linjefärger och långa linjenamn saknas. Färgerna tas från Västtrafik.
- `shapes.txt` och `stop_times.txt` är runt 280 MB var uppackade, så servern
  plockar ut spårvagnarna en gång per hämtning och sparar ett litet utdrag.

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
