# Trafiken för iOS

En riktig app för kartan, skriven i Swift och SwiftUI (iOS 17 och senare).
Den ritar linjekartan och vagnarna själv och hämtar allt från samma server som
sidan (`server/`): `/api/dag`, `/api/live` och `/api/karta`. Nycklarna till
Västtrafik och Trafiklab stannar på servern.

## Bygga

Kräver Xcode och [XcodeGen](https://github.com/yonaskolb/XcodeGen), som gör
Xcode-projektet av `project.yml`.

```
brew install xcodegen          # en gång
cd ios
cp Konfig/Lokal.exempel.xcconfig Konfig/Lokal.xcconfig   # fyll i server, bundle-id och team
xcodegen generate
open Trafiken.xcodeproj
```

`Konfig/Lokal.xcconfig` checkas inte in: där står serverns adress, appens
bundle-id och ditt utvecklarteam. Utan den pratar appen med en server på
`localhost:8125`, vilket fungerar i simulatorn när servern körs på samma Mac.

Från kommandoraden, för simulatorn:

```
xcodebuild -project Trafiken.xcodeproj -scheme Trafiken \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Filerna

- `Modell.swift`: serverns JSON och dagens tidtabell färdig att räkna med.
- `Lage.swift`: var en tur är vid en viss tid, samma räkning som sidan.
- `AppModell.swift`: område, klocka, realtid, kartans utsnitt, val och min position.
- `KartVy.swift`: kartan och vagnarna, ritade med SwiftUI Canvas.
- `Vyer.swift`: appen, panelerna och kortet med vagn eller avgångar.
- `Tema.swift`: dag och natt, och linjeskylten.

## Min position

Knappen med pilen letar upp hållplatsen närmast dig i verkligheten, markerar
den på kartan och visar dess avgångar. Är du närmare ett annat område byter
appen dit.
