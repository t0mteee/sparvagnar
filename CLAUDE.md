# sparvagnar

Göteborgs spårvagnar i rörelse på en schematisk linjekarta. Plan, faser och
hur rörelserna räknas står i README.md. Det här dokumentet ger sammanhang till
en Claude-session som kör i den här mappen på servern.

## Läge

- Fas 0 klar: båda nycklarna fungerar, se "i praktiken" i README.md. På Macen
  ska de in i `.env`. Kontrollera med `./scripts/check.sh`.
- Fas 1 pågår: en första prototyp finns i `poc/` (layout med LOOM, vagnar
  enligt tidtabell). Se `poc/README.md` för hur den byggs och vad som brister.

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
- LOOM för layouten: `docker build -t loom https://github.com/ad-freiburg/loom.git`,
  sedan `docker run -i loom <verktyg>`.

## Regler

- Inga hemligheter i git: `.env` och `data/`. Får du en nyckel i chatten,
  använd den men skriv den aldrig till en fil i repot.
- Repot är publikt. Inget om hemmet eller familjen här.
- Kontona hos Västtrafik och Trafiklab skapar användaren själv.
- Layouten är vår egen. Rita inte av Västtrafiks linjenätskarta.
- Servern skrivs i Python med bara standardbiblioteket, som familjesidan i
  rahbari. Nycklarna stannar i containern.
- Hushåll med anropen: Trafiklab tillåter 60 hämtningar av tidtabellen på
  30 dagar. Västtrafiks positioner hämtas bara medan någon har sidan öppen.
- Committa och pusha efter varje avklarad fas.
