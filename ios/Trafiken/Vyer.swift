import SwiftUI

@main
struct TrafikenApp: App {
    @State private var app = AppModell()

    var body: some Scene {
        WindowGroup {
            Huvudvy().environment(app)
        }
    }
}

/// Kartan över hela skärmen, med paneler ovanpå och kortet längst ner.
struct Huvudvy: View {
    @Environment(AppModell.self) private var app
    @Environment(\.scenePhase) private var fas

    var body: some View {
        @Bindable var app = app
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
                Spacer()
                Docka()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .preferredColorScheme(app.natt ? .dark : .light)
        .sheet(item: $app.valt) { v in
            Kort(valt: v)
                .environment(app)
                .presentationDetents([.height(260), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
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

/// Uppe till höger: tillbaka till mitten, min position, dag eller natt.
private struct Knappar: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        VStack(spacing: 8) {
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

/// Kortet längst ner: en vagn eller en hållplats avgångar.
struct Kort: View {
    @Environment(AppModell.self) private var app
    let valt: Valt

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let t = app.nu(tl.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch valt {
                    case .vagn(let id): VagnKort(id: id, t: t)
                    case .hallplats(let namn): Tavla(namn: namn, t: t)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .presentationBackground(app.tema.panel)
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
                    Text(vi.live ? "Live från Västtrafik" : "Enligt tidtabellen").font(.footnote).foregroundStyle(tema.muted)
                }
            }
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
                    } else if let lg, let mot = lg.mot {
                        GridRow {
                            Text("Nästa").foregroundStyle(tema.muted)
                            Text("\(dag.namn[tur.stopp[mot]])  ") + Text(Tid.klocka(tur.ank[mot] + vi.f)).foregroundColor(tema.signal)
                        }
                    }
                    GridRow {
                        Text("Slutstation").foregroundStyle(tema.muted)
                        Text("\(dag.namn[tur.stopp[tur.stopp.count - 1]])  ") + Text(Tid.klocka(tur.slut + vi.f)).foregroundColor(tema.signal)
                    }
                }
                .font(.body)
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

private struct Tavla: View {
    @Environment(AppModell.self) private var app
    let namn: String
    let t: Double

    var body: some View {
        let tema = app.tema, lista = app.avgangar(namn, t: t)
        VStack(alignment: .leading, spacing: 1) {
            Text(namn).font(.title3.weight(.semibold))
            Text(app.minPosition == namn ? "Närmast dig" : app.visarLive ? "Avgångar, live" : "Avgångar enligt tidtabellen")
                .font(.footnote)
                .foregroundStyle(app.minPosition == namn ? Color(red: 0.16, green: 0.52, blue: 1) : tema.muted)
        }
        if lista.isEmpty {
            Text(app.dag?.tysta.contains(namn) == true
                 ? "Inga \(app.dag?.ord.flera ?? "vagnar") stannar här idag. Därför är hållplatsen grå på kartan."
                 : "Inga avgångar den närmaste timmen.")
                .foregroundStyle(tema.muted)
        }
        ForEach(lista) { a in
            Button { app.valt = .vagn(a.id) } label: {
                HStack(spacing: 10) {
                    Bricka(linje: a.linje)
                    Text(a.mot).lineLimit(1).foregroundStyle(tema.text)
                    Spacer()
                    if a.sen > 120 { Text("+\(Int((a.sen / 60).rounded()))").bold().foregroundStyle(tema.signal) }
                    Text(a.tid - t > 1200 ? Tid.klocka(a.tid) : Tid.om(a.tid, fran: t))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(a.tid - t < 60 ? tema.live : tema.text)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
