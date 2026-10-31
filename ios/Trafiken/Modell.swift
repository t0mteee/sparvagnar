import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// MARK: - Serverns JSON

/// /api/dag: dagens turer, vägar, linjer och hållplatser för ett område
/// (server/tidtabell.py, klientdata).
struct DagJSON: Decodable {
    let dag: String
    let storlek: [Double]
    let linjebredd: Double?
    let linjer: [LinjeJSON]
    let namn: [String]
    let stationer: [[Double]]
    let hopp: [[Double]]
    let strackor: [String]?
    let geo: [[Double]]?
    let turer: [TurJSON]
    let layout: String?
    let omrade: String?
    let omraden: [[String]]?
}

struct LinjeJSON: Decodable {
    let namn: String
    let farg: String
    let text: String
    let typ: String?
}

/// En tur är en lista: [linje, mot, start, vägar, hållplatser, tider]. Tiderna
/// är parvis restid till hållplatsen och väntan där, i sekunder.
struct TurJSON: Decodable {
    let linje: Int
    let mot: Int
    let start: Double
    let hopp: [Int]
    let stopp: [Int]
    let tider: [Double]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        linje = try c.decode(Int.self)
        mot = try c.decode(Int.self)
        start = try c.decode(Double.self)
        hopp = try c.decode([Int].self)
        stopp = try c.decode([Int].self)
        tider = try c.decode([Double].self)
    }
}

/// /api/live: Västtrafiks positioner, kopplade till dagens turer.
struct LiveJSON: Decodable {
    let vagnar: [VagnJSON]
    let tid: Double?
    let dag: String?
    let fel: String?
    let alder: Double?
    let layout: String?
}

struct VagnJSON: Decodable {
    let ref: String
    let l: String
    let m: String?
    let tur: Int
    let f: Double?
    let nara: String?
}

/// /api/karta: kartan som vektordata (server/vektor.py).
struct KartaJSON: Decodable {
    let storlek: [Double]
    let version: String?
    let streck: [StreckJSON]
    let prickar: [PrickJSON]
    let band: [BandJSON]
    let knutar: [KnutJSON]
    let kapslar: [BandJSON]
    let namn: [NamnJSON]
}

/// [kant, linje, färg, bredd, [x, y, ...], [sträcka, ...]]
struct StreckJSON: Decodable {
    let kant: Bool, linje: String, farg: String, bredd: Double, punkter: [Double], strackor: [Int]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        kant = try c.decode(Int.self) == 1
        linje = try c.decode(String.self)
        farg = try c.decode(String.self)
        bredd = try c.decode(Double.self)
        punkter = try c.decode([Double].self)
        strackor = try c.decode([Int].self)
    }
}

/// [x, y, r, linje, namn]
struct PrickJSON: Decodable {
    let x: Double, y: Double, r: Double, linje: String, namn: String
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); r = try c.decode(Double.self)
        linje = try c.decode(String.self); namn = try c.decode(String.self)
    }
}

/// [x1, y1, x2, y2, bredd, kant, namn]
struct BandJSON: Decodable {
    let x1: Double, y1: Double, x2: Double, y2: Double, bredd: Double, kant: Bool, namn: String
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x1 = try c.decode(Double.self); y1 = try c.decode(Double.self)
        x2 = try c.decode(Double.self); y2 = try c.decode(Double.self)
        bredd = try c.decode(Double.self); kant = try c.decode(Int.self) == 1; namn = try c.decode(String.self)
    }
}

/// [x, y, r, namn]
struct KnutJSON: Decodable {
    let x: Double, y: Double, r: Double, namn: String
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); r = try c.decode(Double.self)
        namn = try c.decode(String.self)
    }
}

/// [[rad, ...], x, y, storlek, ankare, knut, namn]
struct NamnJSON: Decodable {
    let rader: [String], x: Double, y: Double, storlek: Double, ankare: String, knut: Bool, namn: String
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        rader = try c.decode([String].self)
        x = try c.decode(Double.self); y = try c.decode(Double.self); storlek = try c.decode(Double.self)
        ankare = try c.decode(String.self); knut = try c.decode(Bool.self); namn = try c.decode(String.self)
    }
}

// MARK: - Dagens tidtabell, färdig att räkna med

struct OmradeVal: Hashable {
    let nyckel: String
    let namn: String
}

enum Fordonstyp: String {
    case sparvagn, buss, tag
}

struct Linje {
    let namn: String
    let farg: Color
    let text: Color
    let typ: Fordonstyp
    /// Mycket ljus (vit) eller mörk (svart, mörkblå) linje, som behöver en kant för att synas.
    let ljus: Bool
    let mork: Bool
}

/// En väg mellan två hållplatser längs kartan, med sträckan räknad i kartenheter.
final class Vag {
    let p: [CGPoint]
    let acc: [Double]
    var langd: Double { acc.last ?? 0 }

    init(_ tal: [Double]) {
        var p: [CGPoint] = []
        for i in stride(from: 0, to: tal.count - 1, by: 2) { p.append(CGPoint(x: tal[i], y: tal[i + 1])) }
        if p.isEmpty { p = [.zero] }
        var acc = [0.0]
        for i in 1..<max(1, p.count) { acc.append(acc[i - 1] + hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y)) }
        self.p = p
        self.acc = acc
    }
}

struct Tur {
    let index: Int
    let linje: Int
    let mot: Int
    let hopp: [Int]
    let stopp: [Int]
    let ank: [Double]
    let avg: [Double]
    var start: Double { avg[0] }
    var slut: Double { ank[ank.count - 1] }
}

struct Station {
    let namn: String
    let p: CGPoint
}

final class Dag {
    let datum: String
    let storlek: CGSize
    let linjebredd: Double
    let linjer: [Linje]
    let namn: [String]
    let vagar: [Vag]
    let turer: [Tur]
    let stationer: [Station]
    let strackor: [String]
    let layout: String?
    let omrade: String
    let omraden: [OmradeVal]
    /// Hållplatsernas riktiga lägen, för "min position".
    let geo: [(namn: String, lat: Double, lon: Double)]
    /// Avgångar per hållplats: turen och hållplatsens plats i den.
    let avgangar: [String: [(tur: Int, i: Int)]]
    /// Sträckor (linje|från|till) som någon tur kör idag, och hållplatser där någon stannar.
    let korda: Set<String>
    let stannar: Set<String>
    /// Hållplatser på kartan utan trafik idag (vändslingor räknas inte).
    let tysta: [String]
    /// Varje linjes utbredning på kartan, för att visa hela linjen.
    let linjeRuta: [String: CGRect]

    init(_ j: DagJSON, omrade: String) {
        let linjer = j.linjer.map { l in
            let ljushet = Color.ljushet(hex: l.farg)
            return Linje(namn: l.namn, farg: Color(hex: l.farg), text: Color(hex: l.text),
                         typ: Fordonstyp(rawValue: l.typ ?? "") ?? .sparvagn, ljus: ljushet > 0.9, mork: ljushet < 0.25)
        }
        let vagar = j.hopp.map(Vag.init)
        let turer: [Tur] = j.turer.enumerated().map { index, t in
            var ank: [Double] = [], avg: [Double] = []
            var forra = t.start
            for i in 0..<t.stopp.count {
                let a = forra + t.tider[2 * i]
                ank.append(a)
                avg.append(a + t.tider[2 * i + 1])
                forra = avg[i]
            }
            return Tur(index: index, linje: t.linje, mot: t.mot, hopp: t.hopp, stopp: t.stopp, ank: ank, avg: avg)
        }
        let stationer = j.stationer.map { Station(namn: j.namn[Int($0[0])], p: CGPoint(x: $0[1], y: $0[2])) }

        var avgangar: [String: [(tur: Int, i: Int)]] = [:]
        var korda = Set<String>(), stannar = Set<String>()
        var rutor: [String: CGRect] = [:]
        for tur in turer {
            let l = linjer[tur.linje].namn
            for (i, n) in tur.stopp.enumerated() {
                let namn_ = j.namn[n]
                stannar.insert(namn_)
                if i > 0 { korda.insert("\(l)|\(j.namn[tur.stopp[i - 1]])|\(namn_)") }
                if i < tur.stopp.count - 1 { avgangar[namn_, default: []].append((tur: tur.index, i: i)) }
            }
            for h in tur.hopp where h >= 0 {
                for p in vagar[h].p {
                    let r = CGRect(x: p.x, y: p.y, width: 0, height: 0)
                    rutor[l] = rutor[l].map { $0.union(r) } ?? r
                }
            }
        }

        datum = j.dag
        storlek = CGSize(width: j.storlek[0], height: j.storlek[1])
        linjebredd = j.linjebredd ?? 4.4
        self.linjer = linjer
        namn = j.namn
        self.vagar = vagar
        self.turer = turer
        self.stationer = stationer
        strackor = j.strackor ?? []
        layout = j.layout
        self.omrade = j.omrade ?? omrade
        omraden = (j.omraden ?? [[omrade, omrade]]).compactMap { $0.count == 2 ? OmradeVal(nyckel: $0[0], namn: $0[1]) : nil }
        geo = (j.geo ?? []).map { (namn: j.namn[Int($0[0])], lat: $0[1], lon: $0[2]) }
        self.avgangar = avgangar
        self.korda = korda
        self.stannar = stannar
        linjeRuta = rutor
        tysta = Set(stationer.map(\.namn)).filter { !stannar.contains($0) && !$0.contains("Vändslinga") }.sorted()
    }

    func linje(_ namn: String) -> Linje? { linjer.first { $0.namn == namn } }

    /// Vad fordonen heter i området: "spårvagnar", "bussar och tåg" eller "bussar".
    var ord: (ental: String, flera: String) {
        let typer = Set(linjer.map(\.typ))
        if typer.contains(.sparvagn) { return ("spårvagn", "spårvagnar") }
        if typer.contains(.tag) { return ("buss eller tåg", "bussar och tåg") }
        return ("buss", "bussar")
    }
}

// MARK: - Kartan, färdig att rita

/// Kartans delar som färdiga figurer i kartenheter, med en ruta var för att
/// bara rita det som syns.
final class Karta {
    struct Streck { let path: Path; let ruta: CGRect; let kant: Bool; let linje: String; let farg: Color; let bredd: Double; let strackor: [Int] }
    struct Prick { let p: CGPoint; let r: Double; let linje: String; let namn: String }
    struct Band { let a: CGPoint; let b: CGPoint; let bredd: Double; let kant: Bool; let namn: String }
    struct Knut { let p: CGPoint; let r: Double; let namn: String }
    /// ruta är ytan namnet tar på kartan, för att kunna trycka på det.
    struct Namn { let rader: [String]; let p: CGPoint; let storlek: Double; let ankare: String; let knut: Bool; let namn: String; let ruta: CGRect }

    let storlek: CGSize
    let version: String?
    let streck: [Streck]
    let prickar: [Prick]
    let band: [Band]
    let knutar: [Knut]
    let kapslar: [Band]
    let namn: [Namn]

    init(_ j: KartaJSON) {
        storlek = CGSize(width: j.storlek[0], height: j.storlek[1])
        version = j.version
        streck = j.streck.map { s in
            var path = Path()
            var ruta = CGRect.null
            for i in stride(from: 0, to: s.punkter.count - 1, by: 2) {
                let p = CGPoint(x: s.punkter[i], y: s.punkter[i + 1])
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                ruta = ruta.union(CGRect(origin: p, size: .zero))
            }
            return Streck(path: path, ruta: ruta.insetBy(dx: -s.bredd, dy: -s.bredd), kant: s.kant, linje: s.linje,
                          farg: Color(hex: s.farg), bredd: s.bredd, strackor: s.strackor)
        }
        prickar = j.prickar.map { Prick(p: CGPoint(x: $0.x, y: $0.y), r: $0.r, linje: $0.linje, namn: $0.namn) }
        band = j.band.map { Band(a: CGPoint(x: $0.x1, y: $0.y1), b: CGPoint(x: $0.x2, y: $0.y2), bredd: $0.bredd, kant: $0.kant, namn: $0.namn) }
        knutar = j.knutar.map { Knut(p: CGPoint(x: $0.x, y: $0.y), r: $0.r, namn: $0.namn) }
        kapslar = j.kapslar.map { Band(a: CGPoint(x: $0.x1, y: $0.y1), b: CGPoint(x: $0.x2, y: $0.y2), bredd: $0.bredd, kant: $0.kant, namn: $0.namn) }
        namn = j.namn.map { n in
            let p = CGPoint(x: n.x, y: n.y)
            return Namn(rader: n.rader, p: p, storlek: n.storlek, ankare: n.ankare, knut: n.knut, namn: n.namn,
                        ruta: Karta.ruta(n.rader, p, storlek: n.storlek, ankare: n.ankare, knut: n.knut))
        }
    }

    /// Ytan ett namn tar på kartan i kartenheter, mätt med samma typsnitt som
    /// KartVy ritar det med: raderna storlek * 1.12 isär, ankaret 78 % ned.
    static func ruta(_ rader: [String], _ p: CGPoint, storlek: Double, ankare: String, knut: Bool) -> CGRect {
        let font = UIFont.systemFont(ofSize: storlek, weight: knut ? .bold : .semibold, width: .condensed)
        let ax: Double = ankare == "end" ? 1 : ankare == "middle" ? 0.5 : 0
        var ruta = CGRect.null
        for (r, rad) in rader.enumerated() {
            let s = (rad as NSString).size(withAttributes: [.font: font])
            let y = p.y + Double(r) * storlek * 1.12
            ruta = ruta.union(CGRect(x: p.x - ax * s.width, y: y - 0.78 * s.height, width: s.width, height: s.height))
        }
        return ruta
    }

    /// Den stora bytespunkten, där kartan börjar.
    var mitt: CGPoint {
        if let k = knutar.first { return k.p }
        if let k = kapslar.first { return k.a }
        return CGPoint(x: storlek.width / 2, y: storlek.height / 2)
    }
}

// MARK: - Färger

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8a97a6
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func ljushet(hex: String) -> Double {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8a97a6
        return (0.299 * Double(v >> 16 & 0xff) + 0.587 * Double(v >> 8 & 0xff) + 0.114 * Double(v & 0xff)) / 255
    }
}
