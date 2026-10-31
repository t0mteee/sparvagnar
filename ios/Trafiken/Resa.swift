import CoreLocation
import Observation
import SwiftUI

// MARK: - Serverns JSON (server/resa.py)

/// En hållplats, adress eller plats att resa från eller till.
struct ResPlats: Decodable, Identifiable, Equatable {
    let id: String
    let namn: String
    let typ: String
    var lat: Double?
    var lon: Double?

    /// "Brunnsparken, Göteborg" blir "Brunnsparken".
    var kort: String { namn.components(separatedBy: ", ").first ?? namn }
    var kommun: String? {
        let delar = namn.components(separatedBy: ", ")
        return delar.count > 1 ? delar.dropFirst().joined(separator: ", ") : nil
    }
    var ikon: String { typ == "hallplats" ? "tram.fill" : typ == "adress" ? "house.fill" : "star.fill" }
}

struct ResPunkt: Decodable, Equatable {
    let namn: String
    let lage: String?
    let plan: String?
    let tid: String?
    let realtid: Bool?
    var lat: Double?
    var lon: Double?
}

struct ResDel: Decodable, Equatable, Identifiable {
    let typ: String
    let index: Int?
    // Gång
    let meter: Double?
    // Färd
    let linje: String?
    let farg: String?
    let text: String?
    let kant: String?
    let slag: String?
    let mot: String?
    let minuter: Int?
    let installd: Bool?
    let delvisInstalld: Bool?
    let info: [String]?
    let fran: ResPunktEllerNamn
    let till: ResPunktEllerNamn

    var id: String { "\(index ?? -1)\(typ)\(fran.namn)" }
    var gang: Bool { typ == "gang" }

    var bricka: Linje {
        let f = farg ?? "#8a97a6", l = Color.ljushet(hex: f)
        let typ: Fordonstyp = slag == "buss" ? .buss : slag == "tag" ? .tag : .sparvagn
        return Linje(namn: linje ?? "?", farg: Color(hex: f), text: Color(hex: text ?? "#ffffff"), typ: typ,
                     ljus: l > 0.9, mork: l < 0.25)
    }
}

/// En gångsträcka har bara namnen; en färd har hela hållplatsen.
enum ResPunktEllerNamn: Decodable, Equatable {
    case punkt(ResPunkt)
    case namn(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .namn(s) } else { self = .punkt(try c.decode(ResPunkt.self)) }
    }

    var namn: String {
        switch self {
        case .punkt(let p): return p.namn
        case .namn(let n): return n
        }
    }

    var punkt: ResPunkt? { if case .punkt(let p) = self { return p } else { return nil } }
}

struct ResForslag: Decodable, Equatable, Identifiable {
    let ref: String?
    let avgang: String?
    let avgangPlan: String?
    let ankomst: String?
    let ankomstPlan: String?
    let minuter: Int?
    let byten: Int
    let installd: Bool
    let delar: [ResDel]

    var id: String { (ref ?? "") + (avgang ?? "") }
    var farder: [ResDel] { delar.filter { !$0.gang } }
}

struct ResDetaljer: Decodable {
    struct Del: Decodable {
        let index: Int?
        let stopp: [Stopp]
    }
    struct Stopp: Decodable, Hashable {
        let namn: String
        let lage: String?
        let plan: String?
        let tid: String?
        let installd: Bool?
        let lat: Double?
        let lon: Double?
    }
    let delar: [Del]
}

private struct PlatsSvar: Decodable { let platser: [ResPlats] }
private struct ResaSvar: Decodable { let forslag: [ResForslag] }
private struct FelSvar: Decodable { let fel: String }

enum ResTid {
    private static let las: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func datum(_ s: String?) -> Date? { s.flatMap { las.date(from: $0) } }

    static func klocka(_ s: String?) -> String {
        guard let d = datum(s) else { return "–" }
        return d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func restid(_ m: Int?) -> String {
        guard let m else { return "" }
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) tim" : "\(m / 60) tim \(m % 60) min"
    }

    /// Hur många minuter senare än planerat, om det är minst en.
    static func sen(_ tid: String?, _ plan: String?) -> Int? {
        guard let a = datum(tid), let b = datum(plan) else { return nil }
        let m = Int((a.timeIntervalSince(b) / 60).rounded())
        return m >= 1 ? m : nil
    }
}

private enum ResServer {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    static func hamta<T: Decodable>(_ typ: T.Type, _ vag: String, _ fraga: [String: String]) async throws -> T {
        var u = URLComponents(url: Server.bas.appendingPathComponent(vag), resolvingAgainstBaseURL: false)!
        u.queryItems = fraga.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, svar) = try await session.data(from: u.url!)
        let kod = (svar as? HTTPURLResponse)?.statusCode ?? 0
        guard kod == 200 else {
            if let fel = try? JSONDecoder().decode(FelSvar.self, from: data) { throw ResFel.text(fel.fel) }
            throw ServerFel.status(kod)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum ResFel: LocalizedError {
    case text(String)
    var errorDescription: String? { if case .text(let t) = self { return t } else { return nil } }
}

// MARK: - Reseplanen

@MainActor @Observable
final class Resplan {
    enum Falt { case fran, till }
    enum Nar: Hashable { case nu, vald }

    var fran: ResPlats?
    var till: ResPlats?
    /// Fältet man skriver i, och det man har skrivit.
    var soker: Falt?
    var text = ""
    var traffar: [ResPlats] = []
    var letar = false

    var nar: Nar = .nu
    var tid = Date()
    var framme = false

    var forslag: [ResForslag] = []
    var hamtar = false
    var fel: String?
    var valt: ResForslag?
    var detaljer: ResDetaljer?
    /// Den egna positionen, medan den letas fram.
    var minPlatsText: String?

    @ObservationIgnored private var sokning: Task<Void, Never>?
    @ObservationIgnored private var plats = Plats()

    /// Det som ritas på kartan: valt förslag, annars inget.
    var paKartan: ResForslag? { valt }

    func borja(fran p: ResPlats?) {
        if let p { fran = p }
        valt = nil
        detaljer = nil
        if till == nil { soker = .till; text = "" }
        Task { await sok() }
    }

    func borja(till p: ResPlats) {
        till = p
        valt = nil
        detaljer = nil
        soker = nil
        Task { await sok() }
    }

    func skriv(_ s: String) {
        text = s
        sokning?.cancel()
        let q = s.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { traffar = []; letar = false; return }
        letar = true
        sokning = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let svar = try? await ResServer.hamta(PlatsSvar.self, "api/platser", ["q": q])
            guard !Task.isCancelled else { return }
            traffar = svar?.platser ?? []
            letar = false
        }
    }

    func valj(_ p: ResPlats) {
        if soker == .fran { fran = p; minPlatsText = nil } else { till = p }
        soker = nil
        text = ""
        traffar = []
        Task { await sok() }
    }

    func byt() {
        (fran, till) = (till, fran)
        Task { await sok() }
    }

    /// Hållplatsen närmast en punkt, helst den som heter namn.
    func narmast(lat: Double, lon: Double, namn: String? = nil) async -> ResPlats? {
        let svar = try? await ResServer.hamta(PlatsSvar.self, "api/platser",
                                              ["lat": String(format: "%.5f", lat), "lon": String(format: "%.5f", lon)])
        let lista = svar?.platser ?? []
        if let namn, let p = lista.first(where: { $0.kort == namn || $0.namn.hasPrefix(namn) }) { return p }
        return lista.first
    }

    /// Hållplatsen på kartan som en plats att resa från eller till.
    func hallplats(_ namn: String, dag: Dag?) async -> ResPlats? {
        if let g = dag?.geo.first(where: { $0.namn == namn }), let p = await narmast(lat: g.lat, lon: g.lon, namn: namn) {
            return p
        }
        let svar = try? await ResServer.hamta(PlatsSvar.self, "api/platser", ["q": namn])
        return svar?.platser.first { $0.typ == "hallplats" }
    }

    /// Från: hållplatsen närmast telefonen.
    func franMig() {
        minPlatsText = "Letar efter dig"
        plats.hamta { [weak self] svar in
            Task { @MainActor in
                guard let self else { return }
                switch svar {
                case .failure:
                    self.minPlatsText = "Appen får inte veta var du är. Skriv var du är i stället."
                case .success(let p):
                    if let n = await self.narmast(lat: p.coordinate.latitude, lon: p.coordinate.longitude) {
                        self.minPlatsText = nil
                        self.fran = n
                        if self.soker == .fran { self.soker = nil; self.text = "" }
                        await self.sok()
                    } else {
                        self.minPlatsText = "Hittade ingen hållplats nära dig."
                    }
                }
            }
        }
    }

    func sok() async {
        guard let fran, let till else { forslag = []; return }
        hamtar = true
        fel = nil
        var fraga = ["fran": fran.id, "till": till.id]
        if nar == .vald {
            fraga["tid"] = ISO8601DateFormatter().string(from: tid)
            fraga["avser"] = framme ? "ankomst" : "avgang"
        }
        do {
            let svar = try await ResServer.hamta(ResaSvar.self, "api/resa", fraga)
            guard fran == self.fran, till == self.till else { return }
            forslag = svar.forslag
            if svar.forslag.isEmpty { fel = "Hittade ingen resa. Prova en annan tid." }
        } catch {
            forslag = []
            fel = error.localizedDescription
        }
        hamtar = false
    }

    func visa(_ f: ResForslag) {
        valt = f
        detaljer = nil
        guard let ref = f.ref else { return }
        Task {
            let d = try? await ResServer.hamta(ResDetaljer.self, "api/resa/detaljer", ["ref": ref])
            if valt?.id == f.id { detaljer = d }
        }
    }

    /// Delresans hållplatser från detaljerna, eller bara början och slutet.
    func stopp(_ del: ResDel) -> [ResDetaljer.Stopp] {
        if let d = detaljer?.delar.first(where: { $0.index == del.index }), !d.stopp.isEmpty { return d.stopp }
        return [del.fran, del.till].compactMap(\.punkt).map {
            ResDetaljer.Stopp(namn: $0.namn, lage: $0.lage, plan: $0.plan, tid: $0.tid, installd: nil, lat: $0.lat, lon: $0.lon)
        }
    }
}

// MARK: - Kortet

/// Reseplaneringen i kortet längst ner: från, till, tid och förslagen. Ett
/// tryck på ett förslag visar delresorna, och resan ritas på kartan.
struct ResKort: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var plan

    var body: some View {
        if let f = plan.valt {
            ResDetalj(forslag: f)
        } else {
            ResSok()
        }
    }
}

private struct ResSok: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var plan
    @FocusState private var fokus: Bool

    var body: some View {
        @Bindable var plan = plan
        let tema = app.tema
        VStack(alignment: .leading, spacing: 10) {
            Text("Vart vill du åka?").font(.title3.weight(.semibold)).padding(.trailing, 36)
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    falt(.fran, "Från", plan.fran, tema)
                    falt(.till, "Till", plan.till, tema)
                }
                Button { plan.byt() } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(tema.text)
                        .background(tema.knapp, in: Circle())
                }
                .accessibilityLabel("Byt håll")
            }
            if let m = plan.minPlatsText { Text(m).font(.footnote).foregroundStyle(tema.muted) }
            if plan.soker != nil {
                traffar(tema)
            } else {
                tidVal(tema)
                resultat(tema)
            }
        }
    }

    private func falt(_ f: Resplan.Falt, _ etikett: String, _ p: ResPlats?, _ tema: Tema) -> some View {
        HStack(spacing: 8) {
            Text(etikett).font(.footnote.weight(.semibold)).foregroundStyle(tema.muted).frame(width: 34, alignment: .leading)
            if plan.soker == f {
                TextField(f == .fran ? "Skriv var du är" : "Skriv vart du ska",
                          text: Binding(get: { plan.text }, set: { plan.skriv($0) }))
                    .focused($fokus)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { if let forsta = plan.traffar.first { plan.valj(forsta) } }
                    .onAppear { fokus = true }
                if plan.letar { ProgressView().controlSize(.small) }
            } else {
                Text(p?.kort ?? (f == .fran ? "Var är du?" : "Vart ska du?"))
                    .foregroundStyle(p == nil ? tema.muted : tema.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .background(tema.knapp, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(plan.soker == f ? tema.signal : tema.rule))
        .contentShape(Rectangle())
        .onTapGesture {
            if plan.soker != f { plan.soker = f; plan.text = ""; plan.traffar = [] }
        }
    }

    @ViewBuilder private func traffar(_ tema: Tema) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if plan.soker == .fran {
                rad(ikon: "location.fill", farg: Color(red: 0.16, green: 0.52, blue: 1), "Närmast mig", nil) { plan.franMig() }
            }
            ForEach(plan.traffar) { p in
                rad(ikon: p.ikon, farg: tema.muted, p.kort, p.kommun) { plan.valj(p) }
            }
            if !plan.letar && plan.traffar.isEmpty && plan.text.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("Hittade inget som heter så.").font(.subheadline).foregroundStyle(tema.muted).padding(.vertical, 6)
            }
            Button("Avbryt") { plan.soker = nil; plan.text = ""; plan.traffar = [] }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tema.signal)
                .padding(.top, 6)
        }
    }

    private func rad(ikon: String, farg: Color, _ namn: String, _ under: String?, _ gor: @escaping () -> Void) -> some View {
        Button(action: gor) {
            HStack(spacing: 10) {
                Image(systemName: ikon).foregroundStyle(farg).frame(width: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(namn).foregroundStyle(app.tema.text)
                    if let under { Text(under).font(.caption).foregroundStyle(app.tema.muted) }
                }
                Spacer()
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func tidVal(_ tema: Tema) -> some View {
        @Bindable var plan = plan
        VStack(alignment: .leading, spacing: 8) {
            Picker("När", selection: $plan.nar) {
                Text("Åka nu").tag(Resplan.Nar.nu)
                Text("Välj tid").tag(Resplan.Nar.vald)
            }
            .pickerStyle(.segmented)
            if plan.nar == .vald {
                Picker("Åka eller vara framme", selection: $plan.framme) {
                    Text("Åka då").tag(false)
                    Text("Vara framme då").tag(true)
                }
                .pickerStyle(.segmented)
                DatePicker("Tid", selection: $plan.tid, in: Date().addingTimeInterval(-3600)..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "sv_SE"))
            }
        }
        .onChange(of: plan.nar) {
            if plan.nar == .vald && plan.tid < Date() { plan.tid = Date() }
            Task { await plan.sok() }
        }
        .onChange(of: plan.framme) { Task { await plan.sok() } }
        .onChange(of: plan.tid) { Task { await plan.sok() } }
    }

    @ViewBuilder private func resultat(_ tema: Tema) -> some View {
        if plan.hamtar && plan.forslag.isEmpty {
            HStack(spacing: 8) { ProgressView(); Text("Letar efter resor").foregroundStyle(tema.muted) }
        } else if let fel = plan.fel {
            Text(fel).foregroundStyle(tema.muted)
        } else if plan.fran != nil, plan.till != nil {
            VStack(spacing: 8) {
                ForEach(plan.forslag) { f in
                    Button { plan.visa(f); visaPaKartan(f) } label: { ForslagRad(forslag: f) }
                        .buttonStyle(.plain)
                }
                Button { Task { await plan.sok() } } label: {
                    Label("Uppdatera", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(tema.signal)
                .padding(.top, 2)
            }
            .opacity(plan.hamtar ? 0.5 : 1)
        }
    }

    /// Hela resan i den övre delen av skärmen, ovanför kortet.
    private func visaPaKartan(_ f: ResForslag) {
        guard let r = ResLinje.ruta(f, plan: plan, dag: app.dag), app.storlek.width > 0 else { return }
        let w = app.storlek.width, bred = w >= 700
        let topp = 150.0, botten = bred ? app.storlek.height - 40 : app.storlek.height * 0.45
        let vanster = bred ? 450.0 : 30, hoger = w - 70
        let k = max(app.minK, min(2, min((hoger - vanster) / max(r.width, 1), (botten - topp) / max(r.height, 1))))
        app.animera(till: Vy(x: r.midX - (vanster + hoger) / 2 / k, y: r.midY - (topp + botten) / 2 / k, k: k))
    }
}

/// Ett förslag i listan: tiderna, restiden, linjerna i ordning och bytena.
private struct ForslagRad: View {
    @Environment(AppModell.self) private var app
    let forslag: ResForslag

    var body: some View {
        let tema = app.tema, f = forslag
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                tid(f.avgang, f.avgangPlan, tema)
                Image(systemName: "arrow.right").font(.footnote.weight(.bold)).foregroundStyle(tema.muted)
                tid(f.ankomst, f.ankomstPlan, tema)
                Spacer()
                Text(ResTid.restid(f.minuter)).font(.subheadline.weight(.semibold)).foregroundStyle(tema.text)
            }
            HStack(spacing: 4) {
                ForEach(Array(f.delar.enumerated()), id: \.offset) { i, d in
                    if i > 0 { Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(tema.muted) }
                    if d.gang {
                        HStack(spacing: 1) {
                            Image(systemName: "figure.walk")
                            Text("\(d.minuter ?? 0)").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(tema.muted)
                    } else {
                        Bricka(linje: d.bricka, storlek: 15).opacity(d.installd == true ? 0.4 : 1)
                    }
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                if f.installd {
                    Text("Inställd").bold().foregroundStyle(.red)
                } else {
                    Text(f.byten == 0 ? "Inga byten" : f.byten == 1 ? "1 byte" : "\(f.byten) byten")
                        .foregroundStyle(tema.muted)
                    if let start = f.farder.first?.fran.punkt {
                        Text("· från \(start.namn.components(separatedBy: ", ").first ?? start.namn)\(start.lage.map { ", läge \($0)" } ?? "")")
                            .foregroundStyle(tema.muted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 15)) { tl in
                    if let d = ResTid.datum(f.avgang) {
                        let m = Int((d.timeIntervalSince(tl.date) / 60).rounded(.down))
                        if m >= 0 && m < 60 && !f.installd {
                            Text(m == 0 ? "Gå nu!" : "om \(m) min").bold().foregroundStyle(m < 3 ? tema.signal : tema.live)
                        }
                    }
                }
            }
            .font(.footnote)
        }
        .padding(10)
        .background(tema.knapp, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(f.installd ? Color.red.opacity(0.6) : tema.rule))
        .contentShape(Rectangle())
    }

    private func tid(_ t: String?, _ p: String?, _ tema: Tema) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(ResTid.klocka(t))
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(ResTid.sen(t, p) != nil ? tema.signal : tema.text)
            if ResTid.sen(t, p) != nil {
                Text(ResTid.klocka(p)).font(.caption).strikethrough().foregroundStyle(tema.muted)
            }
        }
    }
}

/// Ett förslag i detalj: varje delresa med hållplatser och tider, och gången emellan.
private struct ResDetalj: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var plan
    let forslag: ResForslag
    @State private var oppna = Set<String>()

    var body: some View {
        let tema = app.tema, f = forslag
        VStack(alignment: .leading, spacing: 10) {
            Button { plan.valt = nil; plan.detaljer = nil } label: {
                Label("Alla resor", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(tema.signal)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(ResTid.klocka(f.avgang)) – \(ResTid.klocka(f.ankomst))")
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                Text(ResTid.restid(f.minuter)).foregroundStyle(tema.muted)
            }
            .padding(.trailing, 36)
            if f.installd {
                Text("Någon del av resan är inställd. Välj en annan resa.").bold().foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(f.delar) { d in
                    if d.gang { gang(d, tema) } else { fard(d, tema) }
                }
                HStack(spacing: 10) {
                    Image(systemName: "flag.checkered").frame(width: 22)
                    Text("Framme vid \(plan.till?.kort ?? f.delar.last?.till.namn ?? "")").bold()
                    Spacer()
                    Text(ResTid.klocka(f.ankomst)).font(.system(.subheadline, design: .monospaced).weight(.bold))
                }
                .padding(.top, 6)
            }
        }
    }

    private func gang(_ d: ResDel, _ tema: Tema) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk").foregroundStyle(tema.muted).frame(width: 22)
            let till = d.till.namn.isEmpty ? "" : kort(d.till.namn) == kort(d.fran.namn) ? " till nästa läge" : " till \(kort(d.till.namn))"
            Text("Gå \(d.minuter ?? 0) min\(d.meter.map { ", \(Int($0)) meter" } ?? "")\(till)")
                .font(.subheadline)
                .foregroundStyle(tema.muted)
        }
        .padding(.vertical, 8)
    }

    private func fard(_ d: ResDel, _ tema: Tema) -> some View {
        let farg = d.bricka.farg, stopp = plan.stopp(d), oppen = oppna.contains(d.id)
        let mellan = stopp.count > 2 ? Array(stopp[1..<(stopp.count - 1)]) : []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Bricka(linje: d.bricka, storlek: 18)
                Text("mot \(kort(d.mot ?? ""))").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if d.installd == true { Text("Inställd").bold().foregroundStyle(.red) }
                else if d.delvisInstalld == true { Text("Delvis inställd").font(.footnote.bold()).foregroundStyle(.red) }
            }
            .padding(.vertical, 4)
            if let p = d.fran.punkt { hallplats(p.namn, p.lage, p.tid, p.plan, farg: farg, forst: true, sist: false, tema) }
            if !mellan.isEmpty {
                Button { if oppen { oppna.remove(d.id) } else { oppna.insert(d.id) } } label: {
                    HStack(spacing: 10) {
                        Rectangle().fill(farg).frame(width: 4, height: 26).frame(width: 22)
                        Text("\(oppen ? "Dölj" : "Visa") \(mellan.count) hållplatser till, \(ResTid.restid(d.minuter))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tema.signal)
                    }
                }
                .buttonStyle(.plain)
                if oppen {
                    ForEach(mellan, id: \.self) { s in
                        hallplats(s.namn, nil, s.tid, s.plan, farg: farg, forst: false, sist: false, tema, liten: true)
                    }
                }
            } else if plan.detaljer == nil, d.fran.punkt != nil {
                Rectangle().fill(farg).frame(width: 4, height: 14).frame(width: 22)
            }
            if let p = d.till.punkt { hallplats(p.namn, p.lage, p.tid, p.plan, farg: farg, forst: false, sist: true, tema) }
            ForEach(d.info ?? [], id: \.self) { t in
                Text(t).font(.footnote).foregroundStyle(tema.signal).padding(.leading, 32).padding(.bottom, 4)
            }
        }
    }

    private func hallplats(_ namn: String, _ lage: String?, _ tid: String?, _ plan_: String?, farg: Color,
                           forst: Bool, sist: Bool, _ tema: Tema, liten: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(forst ? .clear : farg)
                    Rectangle().fill(sist ? .clear : farg)
                }
                .frame(width: 4)
                Circle().fill(tema.panel).overlay(Circle().strokeBorder(farg, lineWidth: 2.5))
                    .frame(width: liten ? 9 : 13, height: liten ? 9 : 13)
            }
            .frame(width: 22, height: liten ? 26 : 32)
            Button { visa(namn) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(kort(namn)).font(liten ? .footnote : .subheadline.weight(.semibold)).lineLimit(1)
                    if let lage, !liten { Text("Läge \(lage)").font(.caption).foregroundStyle(tema.muted) }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            if let s = ResTid.sen(tid, plan_) {
                Text("+\(s)").font(.caption.bold()).foregroundStyle(tema.signal)
            }
            Text(ResTid.klocka(tid))
                .font(.system(liten ? .footnote : .subheadline, design: .monospaced).weight(liten ? .regular : .bold))
                .foregroundStyle(liten ? tema.muted : tema.text)
        }
    }

    /// Hållplatsen på kartan, om den finns där.
    private func visa(_ namn: String) {
        guard let dag = app.dag, let s = dag.stationer.first(where: { $0.namn == kort(namn) }) else { return }
        app.flygTill(CGRect(x: s.p.x - 60, y: s.p.y - 60, width: 120, height: 120), maxK: 2.5)
    }

    private func kort(_ s: String) -> String { s.components(separatedBy: ", ").first ?? s }
}

// MARK: - Resan på kartan

/// Resan ritad ovanpå linjekartan: varje delresa i sin linjes färg, längs
/// spåren där linjen finns på kartan, annars rakt mellan hållplatserna.
@MainActor enum ResLinje {
    struct Bit { let p: [CGPoint]; let farg: Color; let gang: Bool }

    /// Hållplatsen på kartan som ligger närmast en verklig punkt, inom 400 meter,
    /// eller som heter samma sak.
    static func station(_ s: ResDetaljer.Stopp, dag: Dag) -> Station? {
        let namn = s.namn.components(separatedBy: ", ").first ?? s.namn
        if let lat = s.lat, let lon = s.lon {
            let p = CLLocation(latitude: lat, longitude: lon)
            let bast = dag.geo.map { g in (g.namn, p.distance(from: CLLocation(latitude: g.lat, longitude: g.lon))) }
                .min { $0.1 < $1.1 }
            if let b = bast, b.1 < 400, let st = dag.stationer.first(where: { $0.namn == b.0 }) { return st }
        }
        return dag.stationer.first { $0.namn == namn }
    }

    static func bitar(_ f: ResForslag, plan: Resplan, dag: Dag) -> [Bit] {
        var ut: [Bit] = [], forra: CGPoint?
        for d in f.delar where !d.gang {
            let stationer = plan.stopp(d).compactMap { station($0, dag: dag) }
            guard let forsta = stationer.first else { continue }
            if let forra, forra != forsta.p { ut.append(Bit(p: [forra, forsta.p], farg: .gray, gang: true)) }
            var p = [forsta.p]
            for (a, b) in zip(stationer, stationer.dropFirst()) where a.namn != b.namn {
                p += vag(d.linje ?? "", a.namn, b.namn, dag: dag) ?? [b.p]
            }
            ut.append(Bit(p: p, farg: d.bricka.farg, gang: false))
            forra = p.last
        }
        return ut
    }

    /// Kartans väg för linjen mellan två hållplatser i rad, om någon tur kör den.
    private static func vag(_ linje: String, _ a: String, _ b: String, dag: Dag) -> [CGPoint]? {
        guard let li = dag.linjer.firstIndex(where: { $0.namn == linje }) else { return nil }
        for tur in dag.turer where tur.linje == li {
            for i in 0..<(tur.stopp.count - 1) where i < tur.hopp.count && tur.hopp[i] >= 0
                && dag.namn[tur.stopp[i]] == a && dag.namn[tur.stopp[i + 1]] == b {
                return dag.vagar[tur.hopp[i]].p
            }
        }
        return nil
    }

    static func ruta(_ f: ResForslag, plan: Resplan, dag: Dag?) -> CGRect? {
        guard let dag else { return nil }
        let p = bitar(f, plan: plan, dag: dag).flatMap(\.p)
        guard let x0 = p.map(\.x).min(), let x1 = p.map(\.x).max(), let y0 = p.map(\.y).min(), let y1 = p.map(\.y).max()
        else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Lagret på kartan med den valda resan.
struct ResLager: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var plan

    var body: some View {
        let vy = app.vy, tema = app.tema
        if case .resa = app.valt, let f = plan.paKartan, let dag = app.dag {
            let bitar = ResLinje.bitar(f, plan: plan, dag: dag)
            Canvas { c, _ in
                let skarm = { (p: CGPoint) in CGPoint(x: (p.x - vy.x) * vy.k, y: (p.y - vy.y) * vy.k) }
                let bredd = max(5, min(14, dag.linjebredd * vy.k * 1.6))
                for b in bitar {
                    var path = Path()
                    path.addLines(b.p.map(skarm))
                    if b.gang {
                        c.stroke(path, with: .color(tema.muted), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 6]))
                    } else {
                        c.stroke(path, with: .color(tema.bg), style: StrokeStyle(lineWidth: bredd + 5, lineCap: .round, lineJoin: .round))
                        c.stroke(path, with: .color(b.farg), style: StrokeStyle(lineWidth: bredd, lineCap: .round, lineJoin: .round))
                    }
                }
                // Början, bytena och slutet.
                for (i, b) in bitar.enumerated() where !b.gang {
                    for (j, p) in [b.p.first, b.p.last].compactMap({ $0 }).enumerated() {
                        let s = skarm(p), r = 8.0
                        let cirkel = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r))
                        c.fill(cirkel, with: .color(.white))
                        let slut = i == bitar.count - 1 && j == 1, start = i == 0 && j == 0
                        c.stroke(cirkel, with: .color(start || slut ? tema.signal : b.farg), lineWidth: start || slut ? 4 : 3)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Vägarna in

extension Resplan {
    /// Knappen uppe till höger: från den valda hållplatsen, annars den närmaste.
    func oppna(_ app: AppModell) {
        let fore = app.valt
        app.valt = .resa
        if case .hallplats(let namn) = fore {
            Task { borja(fran: await hallplats(namn, dag: app.dag)) }
        } else if fran == nil {
            if till == nil { soker = .till }
            franMig()
        }
    }

    func res(_ namn: String, hit: Bool, _ app: AppModell) {
        app.valt = .resa
        Task {
            guard let p = await hallplats(namn, dag: app.dag) else { return }
            if hit {
                borja(till: p)
                if fran == nil { franMig() }
            } else {
                borja(fran: p)
            }
        }
    }
}

/// "Res härifrån" och "Res hit" på hållplatsens kort.
struct ResKnappar: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var plan
    let namn: String

    var body: some View {
        let tema = app.tema
        HStack(spacing: 8) {
            knapp("Res härifrån", "arrow.up.right", tema) { plan.res(namn, hit: false, app) }
            knapp("Res hit", "flag.fill", tema) { plan.res(namn, hit: true, app) }
        }
    }

    private func knapp(_ text: String, _ ikon: String, _ tema: Tema, _ gor: @escaping () -> Void) -> some View {
        Button(action: gor) {
            Label(text, systemImage: ikon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(tema.text)
                .background(tema.knapp, in: Capsule())
                .overlay(Capsule().strokeBorder(tema.rule))
        }
        .buttonStyle(.plain)
    }
}
