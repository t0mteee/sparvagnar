# sparvagnar

Göteborgs spårvagnar i rörelse på en schematisk linjekarta. Plan, faser och
hur rörelserna räknas står i README.md. Det här dokumentet ger sammanhang till
en Claude-session som kör i den här mappen på servern.

## Läge

- Fas 0–3 körs på servern. Fas 4 (kul och informativ för barn) är byggd:
  dag/natt, Åk med, avgångstavla, uppdrag, Visste du?, spårvagnsklocka.
  Efter git pull: docker compose restart sparvagnar (layouten läses vid start).
- Två områden, flik på sidan: Göteborg (spårvagnar) och Kungsbacka kommun
  (bussar och tåg), se `server/omraden.py`. Varje område har egen layout i
  `layout/` respektive `layout/kungsbacka/`.
- iOS-appen ligger i `ios/` (Swift, SwiftUI, XcodeGen) och byggs på en Mac med
  Xcode, inte på servern. Serverns adress står i `ios/Konfig/Lokal.xcconfig`,
  som inte checkas in.
- Sidan är till för ett barn: tydlig, rolig, inga tekniska ord i gränssnittet.
- Västtrafiks officiella spårvagnskarta har ingen öppen licens; använd den inte,
  länka till den.
- `poc/` är den första prototypen, publicerad som en fristående sida.

## Servern

- Gammal Intel-MacBook, macOS 15, 16 GB RAM. Delas med Spelkompisen
  (LaunchAgents `com.saman.*`) och Home Assistant-stacken i repot `rahbari`.
  Rör inte dem. Det här projektet har egen mapp, egen `docker compose` och
  egen `.env`.
- Upptagna portar: 8002, 5175, 3100, 3000, 8123 och 8124. Kartan använder
  8125 (`PORT` i `.env`). Ändras porten, uppdatera listan i rahbaris CLAUDE.md
  också.
- Ingen Homebrew, ingen sudo och ingen Python på Macen. Allt körs i Docker.

## Kommandon

- Kontroll av port, nycklar och tidtabell: `./scripts/check.sh`
- Starta: `docker compose up -d`. Efter `git pull`: `docker compose restart sparvagnar`
- Utifrån via Cloudflare Tunnel: `docker compose --profile natet up -d`, token i
  `.env` (`TUNNEL_TOKEN`). Adressen ställs in i Cloudflare, inte i repot.
- Logg: `docker compose logs -f sparvagnar`
- Läge: `curl -s localhost:8125/api/status`
- LOOM för layouten: `docker build -t loom https://github.com/ad-freiburg/loom.git`,
  sedan `docker run -i loom <verktyg>`.

## Regler

- Inga hemligheter i git: `.env` och `data/`. Får du en nyckel i chatten,
  använd den men skriv den aldrig till en fil i repot.
- Repot är publikt. Inget om hemmet eller familjen här. Domänen och adressen
  till sidan står bara i Cloudflare, inte i repot.
  Områden beskrivs på kommunnivå; peka inte ut enskilda orter eller hållplatser.
- Kontona hos Västtrafik och Trafiklab skapar användaren själv.
- Layouten är vår egen. Rita inte av Västtrafiks linjenätskarta.
- Servern skrivs i Python med bara standardbiblioteket, som familjesidan i
  rahbari. Nycklarna stannar i containern.
- Hushåll med anropen: Trafiklab tillåter 60 hämtningar av tidtabellen på
  30 dagar. Västtrafiks positioner hämtas bara medan någon har sidan öppen.
- Committa och pusha efter varje avklarad fas.
