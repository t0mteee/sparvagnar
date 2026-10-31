import CoreGraphics
import Foundation

/// Var en tur är vid en viss tid: punkten på kartan, hållplatsen den står vid
/// eller är på väg till, och var på turens väg den är (k = vilken väg, s = hur
/// långt in på den). Samma räkning som sidan (web/index.html, lage).
struct Lage {
    var xy: CGPoint
    var star: Int?
    var mot: Int?
    var k: Int
    var s: Double
}

/// Mjuk start och inbromsning mellan hållplatserna.
private func mjuk(_ f: Double) -> Double { f * f * (3 - 2 * f) }

extension Dag {
    /// Punkten mal kartenheter in på vägen.
    func punkt(_ v: Vag, _ mal: Double) -> CGPoint {
        let a = v.acc, p = v.p
        if p.count == 1 { return p[0] }
        var lo = 0, hi = a.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if a[m] <= mal { lo = m } else { hi = m }
        }
        let seg = (a[hi] - a[lo]) == 0 ? 1 : a[hi] - a[lo]
        let t = (mal - a[lo]) / seg
        return CGPoint(x: p[lo].x + (p[hi].x - p[lo].x) * t, y: p[lo].y + (p[hi].y - p[lo].y) * t)
    }

    func lage(_ tur: Tur, _ t: Double) -> Lage? {
        if t < tur.start || t > tur.slut { return nil }
        let ank = tur.ank, avg = tur.avg, h = tur.hopp, n = ank.count
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if ank[m] <= t { lo = m } else { hi = m }
        }
        if t < avg[lo] || lo == n - 1 {
            // Står vid hållplats lo: i slutet av vägen dit, eller i början av den första.
            let k = lo > 0 ? lo - 1 : 0
            guard k < h.count, h[k] >= 0 else { return nil }
            let v = vagar[h[k]], s = lo > 0 ? v.langd : 0
            return Lage(xy: punkt(v, s), star: lo, mot: nil, k: k, s: s)
        }
        guard lo < h.count, h[lo] >= 0 else { return nil }
        let f = min(1, max(0, (t - avg[lo]) / max(1, ank[lo + 1] - avg[lo])))
        let v = vagar[h[lo]], s = v.langd * mjuk(f)
        return Lage(xy: punkt(v, s), star: nil, mot: lo + 1, k: lo, s: s)
    }

    /// Punkten d kartenheter bakom fronten, längs turens väg. Används för att
    /// låta vagnens moduler följa spåret i kurvorna.
    func bakom(_ tur: Tur, k: Int, s: Double, d: Double) -> CGPoint {
        var kk = k, ss = s - d
        while ss < 0 && kk > 0 && tur.hopp[kk - 1] >= 0 {
            kk -= 1
            ss += vagar[tur.hopp[kk]].langd
        }
        let v = vagar[tur.hopp[kk]]
        if ss >= 0 { return punkt(v, ss) }
        // Före vägens början: fortsätt rakt bakåt.
        let a = punkt(v, 0), b = punkt(v, min(v.langd, 2))
        let n = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
        return CGPoint(x: a.x + (a.x - b.x) / n * -ss, y: a.y + (a.y - b.y) / n * -ss)
    }
}

/// Svensk tid i sekunder efter midnatt.
enum Tid {
    static let zon = TimeZone(identifier: "Europe/Stockholm") ?? .current
    private static let kalender: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zon
        return c
    }()

    static func sekunder(_ d: Date = Date()) -> Double {
        let c = kalender.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        return Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
    }

    /// "08:05"
    static func klocka(_ s: Double) -> String {
        let v = ((Int(s.rounded()) % 86400) + 86400) % 86400
        return String(format: "%02d:%02d", v / 3600, v / 60 % 60)
    }

    /// "08:05:12"
    static func sekundklocka(_ s: Double) -> String {
        let v = ((Int(s.rounded(.down)) % 86400) + 86400) % 86400
        return String(format: "%02d:%02d:%02d", v / 3600, v / 60 % 60, v % 60)
    }

    /// "nu", "3 min"
    static func om(_ s: Double, fran t: Double) -> String {
        let m = Int(((s - t) / 60).rounded())
        return m <= 0 ? "nu" : "\(m) min"
    }
}
