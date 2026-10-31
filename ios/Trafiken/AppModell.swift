import CoreLocation
import Observation
import SwiftUI

/// Kartans utsnitt: övre vänstra hörnet i kartenheter och skalan i punkter per kartenhet.
struct Vy: Equatable {
    var x: Double = 0
    var y: Double = 0
    var k: Double = 1
}

/// Det som är valt på kartan och visas i kortet längst ner.
enum Valt: Identifiable, Equatable {
    case vagn(String)
    case hallplats(String)

    var id: String {
        switch self {
        case .vagn(let i): return "v" + i
        case .hallplats(let n): return "h" + n
        }
    }
}

/// En vagn på kartan just nu.
struct Fordon {
    let id: String
    let linje: Int          // -1 om linjen inte finns i dagens tidtabell
    let xy: CGPoint
    let sen: Double
    let tur: Tur?
    let lage: Lage?
    /// Västtrafik ser vagnen, men den gick inte att koppla till en tur.
    let los: Bool
}

/// En vagn från Västtrafik. Den visade förseningen följer den rapporterade
/// mjukt: vagnen kan stanna, men aldrig backa (samma som sidan).
struct LiveVagn {
    let ref: String
    let linje: String
    let mot: String?
    let tur: Int
    let nara: String?
    var fMal: Double
    var fVisad: Double
    var takt: Double
}

struct Avgang: Identifiable {
    let id: String
    let tur: Int
    let linje: Linje
    let mot: String
    let tid: Double
    let sen: Double
    let live: Bool
}

@MainActor @Observable
final class AppModell {
    var omrade: String { didSet { if omrade != oldValue { UserDefaults.standard.set(omrade, forKey: "omrade") } } }
    var dag: Dag?
    var karta: Karta?
    var meddelande: String? = "Laddar kartan"
    var natt: Bool { didSet { UserDefaults.standard.set(natt, forKey: "natt") } }
    var vy = Vy()
    var storlek: CGSize = .zero
    var valt: Valt?
    var markerad: String?
    var tystaStreck = Set<Int>()
    let filter = Filter()

    // Min position: hållplatsen närmast mig, och ett meddelande medan den letas fram.
    var minPosition: String?
    var platsMeddelande: String?

    // Klockan: följer verkligheten (live), eller spelar upp tidtabellen.
    var foljer = true
    var bas: Double = 0
    var ankare = Date()
    var fart: Double = 1
    var spelfart: Double = 1

    // Realtiden
    var liveFel: String?
    var liveHamtad: Date?
    @ObservationIgnored var live: [String: LiveVagn] = [:]
    @ObservationIgnored var senastRuta = Date()
    @ObservationIgnored var synliga: [Fordon] = []
    @ObservationIgnored var antalUte = 0
    @ObservationIgnored private var flygning: Task<Void, Never>?
    @ObservationIgnored private var vantandePosition: CLLocation?
    @ObservationIgnored private var plats = Plats()
    @ObservationIgnored private var doldSedan: Date?

    init() {
        omrade = UserDefaults.standard.string(forKey: "omrade") ?? "goteborg"
        if UserDefaults.standard.object(forKey: "natt") != nil {
            natt = UserDefaults.standard.bool(forKey: "natt")
        } else {
            let timme = Tid.sekunder() / 3600
            natt = timme < 6 || timme >= 20
        }
    }

    var omraden: [OmradeVal] {
        dag?.omraden ?? [OmradeVal(nyckel: "goteborg", namn: "Göteborg"), OmradeVal(nyckel: "kungsbacka", namn: "Kungsbacka")]
    }

    // MARK: Klockan

    func nu(_ d: Date = Date()) -> Double {
        if foljer { return Tid.sekunder(d) }
        let v = bas + d.timeIntervalSince(ankare) * fart
        return (v.truncatingRemainder(dividingBy: 86400) + 86400).truncatingRemainder(dividingBy: 86400)
    }

    func stall(_ b: Double, fart f: Double) {
        if f > 0 { spelfart = f }
        bas = b
        ankare = Date()
        fart = f
        foljer = false
    }

    func tillLive() { foljer = true }
    var spelar: Bool { foljer || fart > 0 }
    func spelaPaus() { stall(nu(), fart: spelar ? 0 : spelfart) }

    /// 1× → 10× → 60× → 1×, och uppspelningen startar i den farten.
    func nastaFart() {
        let farter: [Double] = [1, 10, 60]
        let i = farter.firstIndex(of: foljer ? 1 : spelfart) ?? 0
        stall(nu(), fart: farter[(i + 1) % farter.count])
    }

    var harLive: Bool { liveFel == nil && (liveHamtad.map { Date().timeIntervalSince($0) < 30 } ?? false) }
    var visarLive: Bool { foljer && harLive }

    // MARK: Hämta

    /// Hämtar områdets tidtabell och karta, och försöker igen tills det går.
    func ladda() async {
        let omr = omrade
        meddelande = "Laddar kartan"
        while !Task.isCancelled {
            do {
                async let d = Server.hamta(DagJSON.self, "api/dag", omrade: omr)
                async let k = Server.hamta(KartaJSON.self, "api/karta", omrade: omr)
                let (dj, kj) = try await (d, k)
                guard omr == omrade else { return }
                dag = Dag(dj, omrade: omr)
                filter.las(omr)
                karta = Karta(kj)
                live = [:]
                liveHamtad = nil
                valt = nil
                markerad = nil
                minPosition = nil
                rakaTysta()
                hem(animerat: false)
                meddelande = nil
                if let p = vantandePosition {
                    vantandePosition = nil
                    visaPosition(p)
                }
                return
            } catch {
                meddelande = "Kunde inte hämta kartan. \(error.localizedDescription) Försöker igen."
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Realtiden var femte sekund, så länge appen är öppen.
    func liveLoop() async {
        while !Task.isCancelled {
            await hamtaLive()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func hamtaLive() async {
        guard let dag else { return }
        let omr = omrade
        do {
            let j = try await Server.hamta(LiveJSON.self, "api/live", omrade: omr)
            guard omr == omrade, self.dag === dag else { return }
            liveFel = j.fel
            guard let tid = j.tid, tid > 0 else { return }
            var nya: [String: LiveVagn] = [:]
            for v in j.vagnar {
                let g = live[v.ref], f = v.f ?? 0, samma = g?.tur == v.tur
                nya[v.ref] = LiveVagn(ref: v.ref, linje: v.l, mot: v.m, tur: v.tur, nara: v.nara, fMal: f,
                                      fVisad: samma ? g!.fVisad : f, takt: samma ? g!.takt : 0)
            }
            live = nya
            liveHamtad = Date().addingTimeInterval(-(j.alder ?? 0))
            // Ny dag eller ny karta på servern: hämta om.
            if (j.dag.map { $0 != dag.datum } ?? false) || (j.layout.map { $0 != dag.layout } ?? false) {
                await ladda()
            }
        } catch {
            liveFel = "Får inget svar från servern."
        }
    }

    /// Har appen legat i bakgrunden länge hämtas allt om när den kommer tillbaka.
    func bakgrund(_ dold: Bool) {
        if dold { doldSedan = Date(); return }
        if let d = doldSedan, Date().timeIntervalSince(d) > 30 * 60 {
            doldSedan = nil
            Task { await ladda() }
        }
    }

    /// Linjebitar som ingen av dagens turer kör över, till exempel ett avstängt spår.
    private func rakaTysta() {
        guard let dag, let karta else { tystaStreck = []; return }
        var s = Set<Int>()
        for (i, st) in karta.streck.enumerated() where !st.strackor.isEmpty {
            let kors = st.strackor.contains { $0 < dag.strackor.count && dag.korda.contains(dag.strackor[$0]) }
            if !kors { s.insert(i) }
        }
        tystaStreck = s
    }

    // MARK: Kartans utsnitt

    var minK: Double {
        guard let karta, storlek.width > 0 else { return 0.05 }
        return min(storlek.width / karta.storlek.width, storlek.height / karta.storlek.height) * 0.95
    }

    func begransa(_ v: Vy) -> Vy {
        var v = v
        v.k = max(minK, min(minK * 40, v.k))
        return v
    }

    func satStorlek(_ s: CGSize) {
        let forra = storlek
        storlek = s
        if forra == .zero { hem(animerat: false) } else {
            vy.x += (forra.width - s.width) / 2 / vy.k
            vy.y += (forra.height - s.height) / 2 / vy.k
        }
    }

    func skarm(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - vy.x) * vy.k, y: (p.y - vy.y) * vy.k) }

    /// Tillbaka till områdets mitt, som när appen startar.
    func hem(animerat: Bool = true) {
        guard let karta, storlek.width > 0 else { return }
        let k = max(minK, min(storlek.width, storlek.height) / (karta.storlek.width * 0.5))
        let m = karta.mitt
        let mal = Vy(x: m.x - storlek.width / 2 / k, y: m.y - storlek.height / 2 / k, k: k)
        if animerat { animera(till: mal) } else { vy = mal }
    }

    /// Zoomar faktor gånger kring punkten p på skärmen, räknat från utsnittet start.
    func zooma(_ faktor: Double, kring p: CGPoint, fran start: Vy) -> Vy {
        let k2 = max(minK, min(minK * 40, start.k * faktor))
        return Vy(x: start.x + p.x / start.k - p.x / k2, y: start.y + p.y / start.k - p.y / k2, k: k2)
    }

    /// Flyger till en ruta på kartan, med plats för panelerna.
    func flygTill(_ ruta: CGRect, maxK: Double = 3) {
        guard storlek.width > 0 else { return }
        let w = max(ruta.width, 1), h = max(ruta.height, 1)
        let k = max(minK, min(maxK, min((storlek.width - 80) / w, (storlek.height - 320) / h)))
        animera(till: Vy(x: ruta.midX - storlek.width / 2 / k, y: ruta.midY - storlek.height * 0.45 / k, k: k))
    }

    func animera(till mal: Vy) {
        flygning?.cancel()
        let start = vy, t0 = Date(), w = storlek.width, h = storlek.height
        flygning = Task { @MainActor in
            while !Task.isCancelled {
                let f = min(1, Date().timeIntervalSince(t0) / 0.6), e = f * f * (3 - 2 * f)
                let k = exp(log(start.k) + (log(mal.k) - log(start.k)) * e)
                let cx0 = start.x + w / 2 / start.k, cy0 = start.y + h / 2 / start.k
                let cx1 = mal.x + w / 2 / mal.k, cy1 = mal.y + h / 2 / mal.k
                vy = Vy(x: cx0 + (cx1 - cx0) * e - w / 2 / k, y: cy0 + (cy1 - cy0) * e - h / 2 / k, k: k)
                if f >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func avbrytFlygning() { flygning?.cancel() }

    // MARK: Vagnarna

    /// Vagnarna på kartan vid tiden t. Anropas för varje bild som ritas.
    func fordon(_ t: Double, nu d: Date) -> [Fordon] {
        guard let dag else { return [] }
        let dt = min(1, max(0, d.timeIntervalSince(senastRuta)))
        senastRuta = d
        var lista: [Fordon] = []
        if visarLive {
            for (ref, var v) in live where filter.syns(v.linje, i: dag) {
                if v.tur >= 0, v.tur < dag.turer.count {
                    // takt är hur fort den visade förseningen ändras: 1 = vagnen står still,
                    // -2 = tre gånger fortare. Den ändras gradvis, så att vagnen bromsar mjukt.
                    let diff = v.fMal - v.fVisad
                    if abs(diff) > 300 { v.fVisad = v.fMal; v.takt = 0 } else {
                        let mal = max(-2, min(1, diff / 4))
                        v.takt += max(-0.8 * dt, min(0.8 * dt, mal - v.takt))
                        v.fVisad += v.takt * dt
                    }
                    live[ref] = v
                    let tur = dag.turer[v.tur]
                    if let lg = dag.lage(tur, min(tur.slut, max(tur.start, t - v.fVisad))) {
                        lista.append(Fordon(id: ref, linje: tur.linje, xy: lg.xy, sen: v.fMal, tur: tur, lage: lg, los: false))
                    }
                } else if let n = v.nara, let s = dag.stationer.first(where: { $0.namn == n }) {
                    let li = dag.linjer.firstIndex { $0.namn == v.linje } ?? -1
                    lista.append(Fordon(id: ref, linje: li, xy: s.p, sen: 0, tur: nil, lage: nil, los: true))
                }
            }
        } else {
            for tur in dag.turer where t >= tur.start && t <= tur.slut && filter.syns(dag.linjer[tur.linje]) {
                if let lg = dag.lage(tur, t) {
                    lista.append(Fordon(id: "t\(tur.index)", linje: tur.linje, xy: lg.xy, sen: 0, tur: tur, lage: lg, los: false))
                }
            }
        }
        antalUte = lista.count
        return lista
    }

    struct VagnInfo {
        let linje: Linje?
        let tur: Tur?
        let f: Double
        let mot: String
        /// Tåg som går längre än tidtabellen räcker: dit det egentligen ska.
        let vidare: String?
        let live: Bool
        let nara: String?
    }

    func vagnInfo(_ id: String) -> VagnInfo? {
        guard let dag else { return nil }
        if id.hasPrefix("t"), let i = Int(id.dropFirst()), i < dag.turer.count {
            let tur = dag.turer[i]
            return VagnInfo(linje: dag.linjer[tur.linje], tur: tur, f: 0, mot: dag.namn[tur.mot], vidare: nil, live: false, nara: nil)
        }
        guard let v = live[id] else { return nil }
        let tur = v.tur >= 0 && v.tur < dag.turer.count ? dag.turer[v.tur] : nil
        let mot = mot(tur, live: v), sista = tur.map { dag.namn[$0.mot] } ?? mot
        return VagnInfo(linje: tur.map { dag.linjer[$0.linje] } ?? dag.linje(v.linje), tur: tur, f: v.fMal, mot: mot,
                        vidare: sista.hasPrefix(mot) || mot.hasPrefix(sista) ? nil : mot, live: true, nara: v.nara)
    }

    /// Vart en tur går. Tågen går ofta längre än Västtrafiks tidtabell räcker,
    /// som Öresundståget till Malmö, så för dem gäller skylten från realtiden.
    func mot(_ tur: Tur?, live v: LiveVagn?) -> String {
        let skylt = v?.mot.map(Self.rensa) ?? ""
        guard let dag, let tur else { return skylt }
        return dag.linjer[tur.linje].typ == .tag && !skylt.isEmpty ? skylt : dag.namn[tur.mot]
    }

    /// Bussarnas skylt i realtiden har ofta ", Påstigning fram" efter målet.
    static func rensa(_ skylt: String) -> String {
        skylt.components(separatedBy: ", ").filter { !$0.hasPrefix("Påstigning") }.joined(separator: ", ")
    }

    /// Vad fordonet är, i ord.
    func typnamn(_ l: Linje) -> String {
        switch l.typ {
        case .sparvagn: return "Spårvagn"
        case .buss: return "Buss"
        case .tag: return l.namn == "Öresund" ? "Öresundståg" : "Tåg"
        case .bat: return "Båt"
        }
    }

    /// Avgångarna från en hållplats de närmaste fonster sekunderna, med
    /// förseningar när realtiden är igång.
    func avgangar(_ namn: String, t: Double, fonster: Double = 3600) -> [Avgang] {
        guard let dag else { return [] }
        let live_ = visarLive
        var perTur: [Int: LiveVagn] = [:]
        if live_ { for v in live.values where v.tur >= 0 { perTur[v.tur] = v } }
        var lista: [Avgang] = []
        for (ti, i) in dag.avgangar[namn] ?? [] {
            let tur = dag.turer[ti]
            if !filter.syns(dag.linjer[tur.linje]) { continue }
            var f = 0.0, id = "t\(ti)", arLive = false, v: LiveVagn?
            if live_ {
                if let lv = perTur[ti] { f = lv.fMal; id = lv.ref; arLive = true; v = lv }
                // Ej ute i realtid: turer som inte har startat än, och turer som är
                // utanför kartan, där inga positioner hämtas (tåg på väg in i området).
                else if tur.avg[i] < t - 120 || (tur.start < t && dag.lage(tur, t) != nil) { continue }
            }
            let avg = tur.avg[i] + f
            if avg < t - 20 || avg > t + fonster { continue }
            lista.append(Avgang(id: id, tur: ti, linje: dag.linjer[tur.linje], mot: mot(tur, live: v), tid: avg, sen: f, live: arLive))
        }
        return lista.sorted { $0.tid < $1.tid }
    }

    /// En avgång på tavlan: visa vagnen och flyg dit, om den syns på kartan.
    func valjAvgang(_ a: Avgang, t: Double) {
        valt = .vagn(a.id)
        guard let dag else { return }
        let tur = dag.turer[a.tur]
        if let lg = dag.lage(tur, min(tur.slut, max(tur.start, t - a.sen))) {
            flygTill(CGRect(x: lg.xy.x - 80, y: lg.xy.y - 80, width: 160, height: 160), maxK: 1.2)
        }
    }

    // MARK: Tryck

    /// En vagn mitt under fingret går först, sedan ett hållplatsnamn, sedan en
    /// vagn en bit bort och sist den närmaste hållplatsen.
    func tryck(_ p: CGPoint) {
        var bast: Fordon?, bd = 26.0
        for f in synliga {
            let s = skarm(f.xy), d = hypot(s.x - p.x, s.y - p.y)
            if d < bd { bd = d; bast = f }
        }
        if let b = bast, bd < 14 { valt = .vagn(b.id); ovanKortet(p); return }
        if let namn = namnVid(p) { valt = .hallplats(namn); ovanKortet(p); return }
        if let b = bast { valt = .vagn(b.id); ovanKortet(p); return }
        if let dag {
            var namn: String?, bd2 = max(22, 9 * vy.k)
            for s in dag.stationer where !s.namn.contains("Vändslinga") && !filter.gomd(hallplats: s.namn, i: dag) {
                let q = skarm(s.p), d = hypot(q.x - p.x, q.y - p.y)
                if d < bd2 { bd2 = d; namn = s.namn }
            }
            if let namn { valt = .hallplats(namn); ovanKortet(p); return }
        }
        valt = nil
    }

    /// På en smal skärm täcker kortet nedre halvan; det man tryckt på där
    /// flyttas upp så att det syns ovanför kortet.
    private func ovanKortet(_ p: CGPoint) {
        guard storlek.width < 700, p.y > storlek.height * 0.48 else { return }
        animera(till: Vy(x: vy.x, y: vy.y + (p.y - storlek.height * 0.36) / vy.k, k: vy.k))
    }

    /// Hållplatsnamnet under punkten p på skärmen, bland de namn som syns.
    private func namnVid(_ p: CGPoint) -> String? {
        guard let karta else { return nil }
        let q = CGPoint(x: vy.x + p.x / vy.k, y: vy.y + p.y / vy.k), marginal = 8 / vy.k
        return karta.namn.first { n in
            n.storlek * vy.k >= 6 && !n.namn.isEmpty && !n.namn.contains("Vändslinga") && !(dag.map { filter.gomd(hallplats: n.namn, i: $0) } ?? false)
                && n.ruta.insetBy(dx: -marginal, dy: -marginal).contains(q)
        }?.namn
    }

    func valjLinje(_ namn: String) {
        markerad = markerad == namn ? nil : namn
        if let m = markerad, let r = dag?.linjeRuta[m] { flygTill(r, maxK: 2.5) }
    }

    // MARK: Min position

    func hittaMig() {
        platsMeddelande = "Letar efter dig"
        plats.hamta { [weak self] svar in
            Task { @MainActor in
                guard let self else { return }
                switch svar {
                case .failure:
                    self.platsMeddelande = "Appen får inte veta var du är. Det går att ändra under Inställningar, Vagnkollen, Plats."
                case .success(let p):
                    await self.hittad(p)
                }
            }
        }
    }

    private func narmast(_ p: CLLocation, i dag: Dag) -> (namn: String, avstand: Double)? {
        dag.geo.map { g in (namn: g.namn, avstand: p.distance(from: CLLocation(latitude: g.lat, longitude: g.lon))) }
            .min { $0.avstand < $1.avstand }
    }

    /// Är man långt från alla hållplatser i området provas de andra områdena,
    /// och appen byter till det där man är.
    private func hittad(_ p: CLLocation) async {
        guard let dag else { return }
        let har = narmast(p, i: dag)
        if (har?.avstand ?? .infinity) > 3000 {
            for o in omraden where o.nyckel != omrade {
                guard let dj = try? await Server.hamta(DagJSON.self, "api/dag", omrade: o.nyckel) else { continue }
                if let dar = narmast(p, i: Dag(dj, omrade: o.nyckel)), dar.avstand < (har?.avstand ?? .infinity), dar.avstand < 3000 {
                    vantandePosition = p
                    omrade = o.nyckel
                    return
                }
            }
        }
        visaPosition(p)
    }

    private func visaPosition(_ p: CLLocation) {
        guard let dag, let n = narmast(p, i: dag), let s = dag.stationer.first(where: { $0.namn == n.namn }) else {
            platsMeddelande = "Hittade ingen hållplats."
            return
        }
        minPosition = n.namn
        platsMeddelande = n.avstand > 3000
            ? "Närmast är \(n.namn), \(String(format: "%.0f", n.avstand / 1000)) km bort."
            : nil
        animera(till: Vy(x: s.p.x - storlek.width / 2 / max(vy.k, 2.2), y: s.p.y - storlek.height * 0.35 / max(vy.k, 2.2),
                         k: max(vy.k, 2.2)))
        valt = .hallplats(n.namn)
    }
}

/// Telefonens position, en gång när den behövs.
final class Plats: NSObject, CLLocationManagerDelegate {
    private let hanterare = CLLocationManager()
    private var svar: ((Result<CLLocation, Error>) -> Void)?

    enum Fel: Error { case nekad }

    override init() {
        super.init()
        hanterare.delegate = self
        hanterare.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func hamta(_ klar: @escaping (Result<CLLocation, Error>) -> Void) {
        svar = klar
        switch hanterare.authorizationStatus {
        case .notDetermined: hanterare.requestWhenInUseAuthorization()
        case .denied, .restricted: svara(.failure(Fel.nekad))
        default: hanterare.requestLocation()
        }
    }

    private func svara(_ r: Result<CLLocation, Error>) {
        let s = svar
        svar = nil
        s?(r)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard svar != nil else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: svara(.failure(Fel.nekad))
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations platser: [CLLocation]) {
        if let p = platser.last { svara(.success(p)) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        svara(.failure(error))
    }
}
