import SwiftUI

/// Vad som syns på kartan: de slags fordon och linjer man har gömt. Sparas per
/// område, så att Göteborgs båtar kan vara gömda medan Borås visar allt.
@MainActor @Observable
final class Filter {
    private(set) var typer = Set<Fordonstyp>()
    private(set) var linjer = Set<String>()
    @ObservationIgnored private var omrade = ""

    var nagot: Bool { !typer.isEmpty || !linjer.isEmpty }

    /// Läser områdets filter. Anropas när området byts.
    func las(_ omrade: String) {
        self.omrade = omrade
        let d = UserDefaults.standard.dictionary(forKey: "filter-\(omrade)") ?? [:]
        typer = Set((d["typer"] as? [String] ?? []).compactMap(Fordonstyp.init(rawValue:)))
        linjer = Set(d["linjer"] as? [String] ?? [])
    }

    private func spara() {
        UserDefaults.standard.set(["typer": typer.map(\.rawValue), "linjer": Array(linjer)], forKey: "filter-\(omrade)")
    }

    func syns(_ l: Linje) -> Bool { !typer.contains(l.typ) && !linjer.contains(l.namn) }

    /// En linje på kartan, efter namnet. Okända linjer (fordon från realtiden som
    /// inte finns i områdets tidtabell) syns bara när inget är gömt, eftersom man
    /// inte vet vad de är för slags fordon.
    func syns(_ namn: String, i dag: Dag) -> Bool { dag.linje(namn).map(syns) ?? !nagot }

    /// En hållplats göms när alla linjer som stannar där idag är gömda, eller
    /// när ingen stannar där idag och något är gömt.
    func gomd(hallplats namn: String, i dag: Dag) -> Bool {
        guard nagot else { return false }
        guard let l = dag.hplLinjer[namn], !l.isEmpty else { return true }
        return !l.contains { syns($0, i: dag) }
    }

    func vaxla(_ t: Fordonstyp, i dag: Dag) {
        if typer.contains(t) {
            typer.remove(t)
            // Slår man på ett slag igen syns alla dess linjer.
            for l in dag.linjer where l.typ == t { linjer.remove(l.namn) }
        } else { typer.insert(t) }
        spara()
    }

    func vaxla(_ l: Linje) {
        if linjer.contains(l.namn) { linjer.remove(l.namn) } else { linjer.insert(l.namn) }
        spara()
    }

    func visaAlla() { typer = []; linjer = []; spara() }

    func gomAlla(i dag: Dag) {
        linjer = Set(dag.linjer.filter { !typer.contains($0.typ) }.map(\.namn))
        spara()
    }
}

extension Fordonstyp {
    var ordFlera: String {
        switch self {
        case .sparvagn: return "Spårvagnar"
        case .buss: return "Bussar"
        case .tag: return "Tåg"
        case .bat: return "Båtar"
        }
    }

    var ikon: String {
        switch self {
        case .sparvagn: return "tram.fill"
        case .buss: return "bus.fill"
        case .tag: return "lightrail.fill"
        case .bat: return "ferry.fill"
        }
    }
}

/// Panelen där man väljer vad som syns: slagen överst, linjerna under.
struct FilterVy: View {
    @Environment(AppModell.self) private var app
    @Environment(\.dismiss) private var stang

    var body: some View {
        let tema = app.tema, filter = app.filter
        NavigationStack {
            ScrollView {
                if let dag = app.dag {
                    VStack(alignment: .leading, spacing: 14) {
                        let typer = Fordonstyp.allCases.filter { t in dag.linjer.contains { $0.typ == t } }
                        if typer.count > 1 {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                                ForEach(typer, id: \.self) { t in
                                    let pa = !filter.typer.contains(t)
                                    Button { filter.vaxla(t, i: dag) } label: {
                                        Label(t.ordFlera, systemImage: t.ikon)
                                            .font(.system(size: 18, weight: .semibold))
                                            .strikethrough(!pa)
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                            .foregroundStyle(tema.text)
                                            .background(tema.knapp, in: RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pa ? tema.text : tema.rule, lineWidth: pa ? 2 : 1))
                                            .opacity(pa ? 1 : 0.45)
                                    }
                                    .accessibilityLabel("\(t.ordFlera), \(pa ? "syns" : "gömda")")
                                }
                            }
                        }
                        Text("Linjer").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(tema.muted)
                        Rader(mellanrum: 6) {
                            ForEach(dag.linjer.filter { !filter.typer.contains($0.typ) }, id: \.namn) { l in
                                let pa = !filter.linjer.contains(l.namn)
                                Button { filter.vaxla(l) } label: { Bricka(linje: l, storlek: 18) }
                                    .opacity(pa ? 1 : 0.3)
                                    .accessibilityLabel("Linje \(l.namn), \(pa ? "syns" : "gömd")")
                            }
                        }
                        HStack {
                            Button("Visa alla") { filter.visaAlla() }
                            Spacer()
                            Button("Göm alla") { filter.gomAlla(i: dag) }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 4)
                    }
                    .padding()
                }
            }
            .background(tema.panel)
            .navigationTitle("Vad vill du se?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klar") { stang() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Knappen som öppnar filtret. Lyser när något är gömt.
struct FilterKnapp: View {
    @Environment(AppModell.self) private var app
    @State private var visa = false

    var body: some View {
        let tema = app.tema, pa = app.filter.nagot
        Button { visa = true } label: {
            Image(systemName: pa ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(pa ? Color.black : tema.text)
                .background(pa ? tema.signal : tema.panel, in: Circle())
                .overlay(Circle().strokeBorder(tema.rule))
        }
        .accessibilityLabel("Välj vad som syns")
        .sheet(isPresented: $visa) { FilterVy().environment(app) }
        .onChange(of: app.filter.linjer) { if let m = app.markerad, let d = app.dag, !app.filter.syns(m, i: d) { app.markerad = nil } }
        .onChange(of: app.filter.typer) { if let m = app.markerad, let d = app.dag, !app.filter.syns(m, i: d) { app.markerad = nil } }
    }
}

/// Områdets namn uppe till vänster. Ett tryck visar alla områden.
struct OmradesMeny: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        let tema = app.tema, namn = app.omraden.first { $0.nyckel == app.omrade }?.namn ?? app.omrade
        Menu {
            ForEach(app.omraden, id: \.self) { o in
                Button { app.omrade = o.nyckel } label: {
                    if o.nyckel == app.omrade { Label(o.namn, systemImage: "checkmark") } else { Text(o.namn) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(namn).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 14, weight: .bold).width(.condensed))
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(tema.bg)
            .background(tema.text, in: Capsule())
        }
        .accessibilityLabel("\(namn). Byt stad")
    }
}

/// Lägger vyerna i rader, som ord i en text, och bryter när raden är full.
struct Rader: Layout {
    var mellanrum: Double = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let bredd = proposal.width ?? .infinity
        var x = 0.0, y = 0.0, rad = 0.0, storst = 0.0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bredd { x = 0; y += rad + mellanrum; rad = 0 }
            x += s.width + mellanrum
            rad = max(rad, s.height)
            storst = max(storst, x - mellanrum)
        }
        return CGSize(width: proposal.width ?? storst, height: y + rad)
    }

    func placeSubviews(in ruta: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = ruta.minX, y = ruta.minY, rad = 0.0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > ruta.minX && x + s.width > ruta.maxX { x = ruta.minX; y += rad + mellanrum; rad = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + mellanrum
            rad = max(rad, s.height)
        }
    }
}
