import SwiftUI

@main
struct TrafikenApp: App {
    @State private var app = AppModell()
    @State private var resplan = Resplan()

    var body: some Scene {
        WindowGroup {
            Huvudvy().environment(app).environment(resplan)
        }
    }
}

/// Kartan över hela skärmen, med paneler ovanpå och kortet längst ner.
struct Huvudvy: View {
    @Environment(AppModell.self) private var app
    @Environment(\.scenePhase) private var fas
    @State private var yta: CGSize = .zero

    var body: some View {
        // Bred skärm: kortet till vänster. Stor skärm: plats för både kortet och
        // dockan. Annars tar kortet dockans plats så länge det är öppet.
        let bred = yta.width >= 700, stor = bred && yta.height >= 700
        ZStack(alignment: .top) {
            KartVy().ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    ToppPanel()
                    Spacer(minLength: 8)
                    Knappar()
                }
                if let m = app.meddelande ?? app.platsMeddelande {
                    Text(m)
                        .font(.subheadline)
                        .foregroundStyle(app.tema.text)
                        .padding(10)
                        .background(app.tema.panel, in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { app.platsMeddelande = nil }
                }
                Spacer(minLength: 0)
                if let v = app.valt {
                    KortPanel(valt: v, maxHojd: bred && !stor ? yta.height : yta.height * (stor ? 0.55 : 0.45))
                        .frame(maxWidth: bred ? 420 : 720)
                        .frame(maxWidth: .infinity, alignment: bred ? .leading : .center)
                        .layoutPriority(1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if app.valt == nil || stor { Docka() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { yta = $0 }
        }
        .animation(.snappy(duration: 0.3), value: app.valt)
        .preferredColorScheme(app.natt ? .dark : .light)
        .task(id: app.omrade) { await app.ladda() }
        .task(id: app.omrade) { await app.liveLoop() }
        .onChange(of: fas) { _, ny in app.bakgrund(ny != .active) }
    }
}

/// Uppe till vänster: område, klockan och hur många som är ute.
private struct ToppPanel: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        @Bindable var app = app
        let tema = app.tema
        VStack(alignment: .leading, spacing: 6) {
            if app.omraden.count > 1 {
                Picker("Område", selection: $app.omrade) {
                    ForEach(app.omraden, id: \.self) { o in Text(o.namn).tag(o.nyckel) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let t = app.nu(tl.date), ord = app.dag?.ord ?? (ental: "spårvagn", flera: "spårvagnar")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Tid.sekundklocka(t))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(app.foljer ? tema.text : tema.signal)
                    HStack(spacing: 8) {
                        (Text("\(app.antalUte) ").bold().foregroundColor(tema.signal)
                            + Text("\(app.antalUte == 1 ? ord.ental : ord.flera) ute\(app.foljer ? " nu" : "")"))
                            .font(.subheadline)
                            .foregroundStyle(tema.muted)
                        Text(lage(tl.date))
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(app.visarLive ? tema.live : tema.signal)
                    }
                    if !app.foljer {
                        HStack(spacing: 8) {
                            Text("Klockan är egentligen \(Tid.klocka(Tid.sekunder(tl.date)))")
                                .font(.footnote)
                                .foregroundStyle(tema.muted)
                            Button("Till live") { app.tillLive() }
                                .font(.footnote.weight(.semibold))
                        }
                    } else if !app.harLive, let fel = app.liveFel {
                        Text("Ingen realtid: \(fel)").font(.footnote).foregroundStyle(tema.muted)
                    }
                }
            }
        }
        .padding(10)
        .background(tema.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func lage(_ d: Date) -> String {
        if !app.foljer { return app.fart == 0 ? "Pausad" : "Tidtabell \(Int(app.fart))×" }
        if app.visarLive, let h = app.liveHamtad { return "Live, \(Int(d.timeIntervalSince(h))) s sedan" }
        return "Tidtabell"
    }
}

/// Uppe till höger: resa, tillbaka till mitten, min position, dag eller natt.
private struct Knappar: View {
    @Environment(AppModell.self) private var app
    @Environment(Resplan.self) private var resplan

    var body: some View {
        VStack(spacing: 8) {
            knapp("point.topleft.down.to.point.bottomright.curvepath.fill", "Planera en resa") { resplan.oppna(app) }
            knapp("house", "Tillbaka till mitten") { app.hem() }
            knapp("location.fill", "Min position") { app.hittaMig() }
            knapp(app.natt ? "sun.max" : "moon", app.natt ? "Byt till dag" : "Byt till natt") { app.natt.toggle() }
        }
    }

    private func knapp(_ ikon: String, _ etikett: String, _ gor: @escaping () -> Void) -> some View {
        Button(action: gor) {
            Image(systemName: ikon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(app.tema.text)
                .background(app.tema.panel, in: Circle())
                .overlay(Circle().strokeBorder(app.tema.rule))
        }
        .accessibilityLabel(etikett)
    }
}

/// Längst ner: tiden och linjerna.
private struct Docka: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        let tema = app.tema
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("Live") { app.tillLive() }
                    .buttonStyle(Dockknapp(aktiv: app.foljer, farg: tema.live, tema: tema))
                Button { app.spelaPaus() } label: { Image(systemName: app.spelar ? "pause.fill" : "play.fill") }
                    .buttonStyle(Dockknapp(aktiv: false, farg: tema.signal, tema: tema))
                    .accessibilityLabel(app.spelar ? "Pausa" : "Spela")
                Button("\(Int(app.foljer ? 1 : app.spelfart))×") { app.nastaFart() }
                    .buttonStyle(Dockknapp(aktiv: !app.foljer && app.fart > 1, farg: tema.signal, tema: tema))
                    .accessibilityLabel("Byt hastighet")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Slider(value: Binding(get: { app.nu() }, set: { app.stall($0, fart: app.foljer ? 1 : app.fart) }),
                           in: 0...86399)
                        .tint(tema.signal)
                }
            }
            if let dag = app.dag {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(dag.linjer, id: \.namn) { l in
                            Button { app.valjLinje(l.namn) } label: { Bricka(linje: l, storlek: 18) }
                                .opacity(app.markerad == nil || app.markerad == l.namn ? 1 : 0.35)
                                .overlay {
                                    if app.markerad == l.namn {
                                        RoundedRectangle(cornerRadius: 6).strokeBorder(tema.signal, lineWidth: 3).padding(-3)
                                    }
                                }
                                .accessibilityLabel("Linje \(l.namn)")
                        }
                    }
                    .padding(3)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 720)
        .background(tema.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct Dockknapp: ButtonStyle {
    let aktiv: Bool
    let farg: Color
    let tema: Tema

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold).width(.condensed))
            .padding(.horizontal, 11)
            .frame(minWidth: 40, minHeight: 36)
            .foregroundStyle(aktiv ? Color.black : tema.text)
            .background(aktiv ? farg : tema.knapp, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(aktiv ? farg : tema.rule))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Kortet med en vagn eller en hållplats avgångar. Lika högt som innehållet,
/// men högst maxHojd så att kartan syns. Greppet överst drar man uppåt för att
/// se allt och nedåt för att stänga.
private struct KortPanel: View {
    @Environment(AppModell.self) private var app
    let valt: Valt
    let maxHojd: Double
    @State private var innehall: Double = 200
    @State private var stort = false
    @State private var drag: Double = 0

    var body: some View {
        let tema = app.tema
        VStack(spacing: 0) {
            Capsule()
                .fill(tema.rule)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 20)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { stort.toggle() } }
                .gesture(greppa)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(stort ? "Mindre kort" : "Större kort")
            ScrollView {
                Kort(valt: valt)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { innehall = $0 }
            }
            .id(valt.id)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: stort ? innehall : min(innehall, maxHojd))
        }
        .overlay(alignment: .topTrailing) {
            Button { app.valt = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tema.muted)
                    .frame(width: 30, height: 30)
                    .background(tema.knapp, in: Circle())
            }
            .padding(10)
            .accessibilityLabel("Stäng")
        }
        // Kartan ska inte lysa igenom kortet.
        .background(tema.panel, in: RoundedRectangle(cornerRadius: 14))
        .background(tema.bg, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
        .offset(y: max(0, drag))
        .onChange(of: valt) { stort = false }
    }

    private var greppa: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { v in
                let dy = v.predictedEndTranslation.height
                withAnimation(.snappy) {
                    if dy < -60 { stort = true } else if dy > 80 { if stort { stort = false } else { app.valt = nil } }
                    drag = 0
                }
            }
    }
}

/// Innehållet i kortet, som räknas om varje sekund.
struct Kort: View {
    @Environment(AppModell.self) private var app
    let valt: Valt

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let t = app.nu(tl.date)
            VStack(alignment: .leading, spacing: 12) {
                switch valt {
                case .vagn(let id): VagnKort(id: id, t: t)
                case .hallplats(let namn): Tavla(namn: namn, t: t)
                case .resa: ResKort()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

private struct VagnKort: View {
    @Environment(AppModell.self) private var app
    let id: String
    let t: Double

    var body: some View {
        let tema = app.tema
        if let vi = app.vagnInfo(id), let dag = app.dag {
            HStack(spacing: 10) {
                if let l = vi.linje { Bricka(linje: l, storlek: 22) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("mot \(vi.mot)").font(.title3.weight(.semibold))
                    // Vad det är, om skylten inte redan säger det ("Öresund" är ett Öresundståg).
                    let typ = vi.linje.map(app.typnamn).flatMap { $0 == vi.linje?.namn ? nil : $0 }
                    Text([typ, vi.live ? "Live från Västtrafik" : "Enligt tidtabellen"].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(tema.muted)
                }
            }
            .padding(.trailing, 36)
            if let tur = vi.tur {
                let lg = dag.lage(tur, min(tur.slut, max(tur.start, t - vi.f)))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    if vi.live {
                        GridRow { Text("Läge").foregroundStyle(tema.muted); forsening(vi.f, tema) }
                    }
                    if let lg, let star = lg.star {
                        GridRow {
                            Text("Står vid").foregroundStyle(tema.muted)
                            Text("\(dag.namn[tur.stopp[star]])  ") + Text("avgår \(Tid.klocka(tur.avg[star] + vi.f))").foregroundColor(tema.signal)
                        }
                    }
                    GridRow {
                        Text("Framme").foregroundStyle(tema.muted)
                        Text("\(dag.namn[tur.stopp[tur.stopp.count - 1]])  ") + Text(Tid.klocka(tur.slut + vi.f)).foregroundColor(tema.signal)
                    }
                }
                .font(.body)
                Hallplatslista(tur: tur, farg: vi.linje?.farg ?? tema.muted, f: vi.f, t: t, vidare: vi.vidare)
            } else {
                Text("Västtrafik ser vagnen nära \(vi.nara ?? "?"), men den gick inte att koppla till en tur i tidtabellen.")
                    .foregroundStyle(tema.muted)
            }
        } else {
            Text("Vagnen är inte ute längre.").foregroundStyle(tema.muted)
        }
    }

    private func forsening(_ f: Double, _ tema: Tema) -> Text {
        if abs(f) < 60 { return Text("I tid").bold().foregroundColor(tema.live) }
        return f > 0 ? Text("\(Int((f / 60).rounded())) min sen").bold().foregroundColor(tema.signal)
            : Text("\(Int((-f / 60).rounded())) min tidig").bold().foregroundColor(tema.live)
    }
}

/// Turens hållplatser med tider, längs en linje i linjens färg. Det som är
/// passerat är grått och vagnen syns där den är. Tryck på en hållplats för
/// dess avgångar.
private struct Hallplatslista: View {
    @Environment(AppModell.self) private var app
    let tur: Tur
    let farg: Color
    let f: Double
    let t: Double
    let vidare: String?
    @State private var visaAlla = false

    private let radhojd = 32.0

    var body: some View {
        if let dag = app.dag {
            let tema = app.tema, n = tur.stopp.count, tt = t - f
            // Hållplatsen vagnen står vid eller är på väg till; n när turen är slut.
            let nasta = tt < tur.start ? 0 : (0..<n).first { tt <= tur.avg[$0] } ?? n
            let star = nasta < n && tt >= tur.ank[nasta] && tt >= tur.start
            let fran = visaAlla ? 0 : max(0, min(nasta, n) - 1)
            VStack(alignment: .leading, spacing: 0) {
                if fran > 0 {
                    Button("Visa \(fran) tidigare hållplatser") { visaAlla = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tema.signal)
                        .padding(.bottom, 6)
                }
                ForEach(fran..<n, id: \.self) { i in
                    rad(i, dag: dag, tema: tema, nasta: nasta, star: star)
                        .zIndex(i == nasta - 1 ? 1 : 0)
                        .overlay(alignment: .topLeading) {
                            // Vagnen på väg mellan hållplats i och nästa.
                            if i == nasta - 1, !star, tt >= tur.start, nasta < n {
                                let andel = min(1, max(0, (tt - tur.avg[i]) / max(1, tur.ank[nasta] - tur.avg[i])))
                                Capsule().fill(farg).overlay(Capsule().strokeBorder(tema.signal, lineWidth: 2))
                                    .frame(width: 12, height: 20)
                                    .offset(x: 5, y: radhojd / 2 + andel * radhojd - 10)
                            }
                        }
                }
                if let vidare {
                    Text("Fortsätter mot \(vidare)")
                        .font(.footnote)
                        .foregroundStyle(tema.muted)
                        .padding(.leading, 32)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func rad(_ i: Int, dag: Dag, tema: Tema, nasta: Int, star: Bool) -> some View {
        let n = tur.stopp.count, namn = dag.namn[tur.stopp[i]]
        let passerad = i < nasta, harNu = i == nasta && star
        let tid = i == 0 ? tur.avg[i] + f : tur.ank[i] + f
        let tidText = passerad ? Tid.klocka(tid) : harNu ? "avgår \(Tid.klocka(tur.avg[i] + f))"
            : tid - t > 1200 ? Tid.klocka(tid) : Tid.om(tid, fran: t)
        return Button { if dag.avgangar[namn] != nil { app.valt = .hallplats(namn) } } label: {
            HStack(spacing: 10) {
                ZStack {
                    // Linjen in till och ut från hållplatsen; den del vagnen har kört är grå.
                    VStack(spacing: 0) {
                        Rectangle().fill(i == 0 ? .clear : i < nasta || harNu ? tema.rule : farg)
                        Rectangle().fill(i == n - 1 ? .clear : i + 1 < nasta || (i + 1 == nasta && star) ? tema.rule : farg)
                    }
                    .frame(width: 4)
                    Circle()
                        .fill(harNu ? farg : tema.panel)
                        .overlay(Circle().strokeBorder(harNu ? tema.signal : passerad ? tema.rule : farg, lineWidth: harNu ? 3 : 2.5))
                        .frame(width: harNu ? 16 : 12, height: harNu ? 16 : 12)
                }
                .frame(width: 22, height: radhojd)
                Text(namn)
                    .font(.subheadline.weight(i == nasta ? .bold : .regular))
                    .foregroundStyle(passerad ? tema.muted : tema.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tidText)
                    .font(.system(.subheadline, design: .monospaced).weight(i == nasta ? .bold : .regular))
                    .foregroundStyle(passerad ? tema.muted : i == nasta ? tema.signal : tema.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Avgångstavlan: allt som går från hållplatsen den närmaste timmen, och
/// senare avgångar en timme i taget.
private struct Tavla: View {
    @Environment(AppModell.self) private var app
    let namn: String
    let t: Double
    @State private var timmar = 1

    var body: some View {
        let tema = app.tema, lista = app.avgangar(namn, t: t, fonster: Double(timmar) * 3600)
        let fler = timmar < 6 && app.avgangar(namn, t: t, fonster: Double(timmar + 1) * 3600).count > lista.count
        let tid = timmar == 1 ? "närmaste timmen" : "närmaste \(timmar) timmarna"
        VStack(alignment: .leading, spacing: 1) {
            Text(namn).font(.title3.weight(.semibold))
            Text(app.minPosition == namn ? "Närmast dig" : app.visarLive ? "Avgångar \(tid), live" : "Avgångar \(tid) enligt tidtabellen")
                .font(.footnote)
                .foregroundStyle(app.minPosition == namn ? Color(red: 0.16, green: 0.52, blue: 1) : tema.muted)
        }
        .padding(.trailing, 36)
        ResKnappar(namn: namn)
        if lista.isEmpty {
            Text(app.dag?.tysta.contains(namn) == true
                 ? "Inga \(app.dag?.ord.flera ?? "vagnar") stannar här idag. Därför är hållplatsen grå på kartan."
                 : "Inga avgångar den \(tid).")
                .foregroundStyle(tema.muted)
        }
        VStack(spacing: 0) {
            ForEach(lista) { a in
                Button { app.valjAvgang(a, t: t) } label: {
                    HStack(spacing: 10) {
                        Bricka(linje: a.linje)
                        Text(a.mot).lineLimit(1).foregroundStyle(tema.text)
                        Spacer()
                        if a.sen > 120 { Text("+\(Int((a.sen / 60).rounded()))").bold().foregroundStyle(tema.signal) }
                        Text(a.tid - t > 1200 ? Tid.klocka(a.tid) : Tid.om(a.tid, fran: t))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(a.tid - t < 60 ? tema.live : tema.text)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if fler {
            Button("Visa senare avgångar") { timmar += 1 }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tema.signal)
        }
    }
}
