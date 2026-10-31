import SwiftUI

/// Kartan med vagnarna. Dra för att flytta, nyp för att zooma, dubbeltryck för
/// att zooma in, tryck på en vagn eller hållplats för att se mer.
struct KartVy: View {
    @Environment(AppModell.self) private var app
    @State private var drarFran: Vy?
    @State private var zoomarFran: Vy?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                StatiskKarta()
                Fordonslager().allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(zoom)
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                app.animera(till: app.zooma(2, kring: p, fran: app.vy))
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { p in app.tryck(p) }
            .onAppear { app.satStorlek(geo.size) }
            .onChange(of: geo.size) { _, ny in app.satStorlek(ny) }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard zoomarFran == nil else { return }
                if drarFran == nil { drarFran = app.vy; app.avbrytFlygning() }
                guard let s = drarFran else { return }
                app.vy = Vy(x: s.x - v.translation.width / s.k, y: s.y - v.translation.height / s.k, k: s.k)
            }
            .onEnded { _ in drarFran = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomarFran == nil { zoomarFran = app.vy; app.avbrytFlygning() }
                guard let s = zoomarFran else { return }
                app.vy = app.zooma(v.magnification, kring: v.startLocation, fran: s)
            }
            .onEnded { _ in
                zoomarFran = nil
                drarFran = nil
            }
    }
}

/// Själva linjekartan. Ritas om bara när utsnittet, temat eller markeringen ändras.
private struct StatiskKarta: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        let vy = app.vy, tema = app.tema, natt = app.natt, markerad = app.markerad
        let tysta = app.tystaStreck, karta = app.karta, dag = app.dag
        let goteborg = app.omrade == "goteborg"
        Canvas { ctx, size in
            guard let karta, let dag else { return }
            var c = ctx
            c.transform = CGAffineTransform(a: vy.k, b: 0, c: 0, d: vy.k, tx: -vy.x * vy.k, ty: -vy.y * vy.k)
            let synligt = CGRect(x: vy.x, y: vy.y, width: size.width / vy.k, height: size.height / vy.k).insetBy(dx: -30, dy: -30)
            let lb = dag.linjebredd
            let tyst = { (namn: String) in namn.isEmpty || dag.stannar.contains(namn) ? 1.0 : 0.28 }

            // Linjerna, med kanter, i transitmaps ordning.
            for (i, s) in karta.streck.enumerated() where s.ruta.intersects(synligt) {
                var alfa = tysta.contains(i) ? 0.28 : 1
                if let m = markerad, s.linje != m { alfa = 0.13 }
                var farg = s.farg, bredd = s.bredd
                if s.kant {
                    farg = tema.kant
                    // Spårvagnslinje 11 är svart och 1 och X vita: de får en tjockare kant.
                    if goteborg && s.linje == "11" { farg = tema.svartKant; bredd = lb + 1.6 }
                    if goteborg && !natt && (s.linje == "1" || s.linje == "X") { farg = tema.vitKant; bredd = lb + 1.6 }
                }
                c.opacity = alfa
                c.stroke(s.path, with: .color(farg), style: StrokeStyle(lineWidth: bredd, lineCap: .round, lineJoin: .round))
            }

            // Hållplatserna: band tvärs över knippet och en prick per linje.
            for b in karta.band where synligt.contains(b.a) {
                c.opacity = markerad == nil ? tyst(b.namn) : 0.5
                let p = Path { $0.move(to: b.a); $0.addLine(to: b.b) }
                c.stroke(p, with: .color(b.kant ? tema.prickKant : tema.prick), style: StrokeStyle(lineWidth: b.bredd, lineCap: .round))
            }
            for p in karta.prickar where synligt.contains(p.p) {
                c.opacity = markerad.map { $0 == p.linje ? 1 : 0.13 } ?? tyst(p.namn)
                let cirkel = Path(ellipseIn: CGRect(x: p.p.x - p.r, y: p.p.y - p.r, width: 2 * p.r, height: 2 * p.r))
                c.fill(cirkel, with: .color(tema.prick))
                c.stroke(cirkel, with: .color(tema.prickKant), lineWidth: 0.8)
            }

            // De stora bytespunkterna.
            c.opacity = 1
            for k in karta.kapslar {
                let p = Path { $0.move(to: k.a); $0.addLine(to: k.b) }
                c.stroke(p, with: .color(k.kant ? tema.prickKant : tema.prick), style: StrokeStyle(lineWidth: k.bredd, lineCap: .round))
            }
            for k in karta.knutar where synligt.insetBy(dx: -k.r, dy: -k.r).contains(k.p) {
                let cirkel = Path(ellipseIn: CGRect(x: k.p.x - k.r, y: k.p.y - k.r, width: 2 * k.r, height: 2 * k.r))
                c.fill(cirkel, with: .color(tema.prick))
                c.stroke(cirkel, with: .color(tema.prickKant), lineWidth: 1.4)
            }

            // Namnen, när de är stora nog att läsa, med en kant i bakgrundens färg.
            c.drawLayer { lager in
                lager.addFilter(.shadow(color: tema.bg, radius: 1.2))
                lager.addFilter(.shadow(color: tema.bg, radius: 1.2))
                for n in karta.namn where n.storlek * vy.k >= 6 && synligt.insetBy(dx: -120, dy: -40).contains(n.p) {
                    lager.opacity = tyst(n.namn)
                    let ax: Double = n.ankare == "end" ? 1 : n.ankare == "middle" ? 0.5 : 0
                    let font = Font.system(size: n.storlek, weight: n.knut ? .bold : .semibold).width(.condensed)
                    for (r, rad) in n.rader.enumerated() {
                        lager.draw(Text(rad).font(font).foregroundColor(n.knut ? tema.text : tema.namn),
                                   at: CGPoint(x: n.p.x, y: n.p.y + Double(r) * n.storlek * 1.12),
                                   anchor: UnitPoint(x: ax, y: 0.78))
                    }
                }
            }
        }
        .background(tema.bg)
    }
}

/// Vagnarna, ritade i varje bild.
private struct Fordonslager: View {
    @Environment(AppModell.self) private var app

    var body: some View {
        let vy = app.vy, tema = app.tema, natt = app.natt, markerad = app.markerad
        let valt = app.valt, minPosition = app.minPosition
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                guard let dag = app.dag else { return }
                let t = app.nu(tl.date)
                let lista = app.fordon(t, nu: tl.date)
                let skarm = { (p: CGPoint) in CGPoint(x: (p.x - vy.x) * vy.k, y: (p.y - vy.y) * vy.k) }
                let synliga = lista.filter {
                    let s = skarm($0.xy)
                    return s.x > -60 && s.y > -60 && s.x < size.width + 60 && s.y < size.height + 60
                }
                app.synliga = synliga
                let valdId: String? = { if case .vagn(let id) = valt { return id } else { return nil } }()
                let r = max(4, min(13, 1.2 * dag.linjebredd * vy.k))
                let linje = { (f: Fordon) -> Linje in
                    f.linje >= 0 && f.linje < dag.linjer.count ? dag.linjer[f.linje]
                        : Linje(namn: "?", farg: Color(hex: "#8a97a6"), text: Color(hex: "#0b1016"), typ: .sparvagn, ljus: false, mork: false)
                }
                // Inzoomat, eller för den valda linjen, ritas vagnarna som riktiga fordon.
                let somFordon = { (f: Fordon) in f.tur != nil && !f.los && (vy.k >= 0.9 || markerad == linje(f).namn) }

                var c = ctx
                // Ett sken under prickarna, så att de syns mot sin egen linje.
                for f in synliga where !somFordon(f) {
                    let l = linje(f), s = skarm(f.xy)
                    c.opacity = markerad != nil && markerad != l.namn ? 0.12 : 0.22
                    c.fill(Path(ellipseIn: CGRect(x: s.x - r * 1.9, y: s.y - r * 1.9, width: r * 3.8, height: r * 3.8)),
                           with: .color(l.mork && natt ? Color(hex: "#9aa8b6") : l.farg))
                }
                for f in synliga {
                    let l = linje(f), vald = f.id == valdId
                    c.opacity = markerad != nil && markerad != l.namn ? 0.2 : 1
                    if somFordon(f) {
                        ritaFordon(&c, f, l, dag: dag, vy: vy, tema: tema, natt: natt, vald: vald)
                        continue
                    }
                    let s = skarm(f.xy), rr = vald ? r * 1.35 : r
                    let cirkel = Path(ellipseIn: CGRect(x: s.x - rr, y: s.y - rr, width: 2 * rr, height: 2 * rr))
                    if f.sen > 180 {
                        c.stroke(Path(ellipseIn: CGRect(x: s.x - r * 1.5, y: s.y - r * 1.5, width: r * 3, height: r * 3)),
                                 with: .color(tema.signal), lineWidth: 2.5)
                    }
                    let ljusKant = (l.mork && natt) || (l.ljus && !natt)
                    c.fill(cirkel, with: .color(f.los ? tema.bg : l.farg))
                    c.stroke(cirkel, with: .color(vald ? tema.signal : f.los ? l.farg : ljusKant ? Color(hex: "#8a98a6") : tema.fordonKant),
                             lineWidth: vald ? 3.5 : f.los ? 2.5 : 1.5)
                    if r >= 9 && !f.los && l.namn.count <= 3 {
                        c.draw(Text(l.namn).font(.system(size: r * 1.15, weight: .bold).width(.condensed)).foregroundColor(l.text),
                               at: CGPoint(x: s.x, y: s.y + 0.5))
                    }
                }

                // Du är här: en pulserande ring vid hållplatsen närmast dig.
                c.opacity = 1
                if let namn = minPosition, let st = dag.stationer.first(where: { $0.namn == namn }) {
                    let s = skarm(st.p), puls = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 3)
                    let bla = Color(red: 0.16, green: 0.52, blue: 1)
                    let yttre = 14 + 8 * puls
                    c.fill(Path(ellipseIn: CGRect(x: s.x - yttre, y: s.y - yttre, width: 2 * yttre, height: 2 * yttre)),
                           with: .color(bla.opacity(0.25 * (1 - puls) + 0.1)))
                    let inre = Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14))
                    c.fill(inre, with: .color(bla))
                    c.stroke(inre, with: .color(.white), lineWidth: 2.5)
                }
            }
        }
    }
}

/// Fordonens form: antal moduler, längd (minst min punkter, annars skala gånger
/// zoomen) och hur runda fronten och bakdelen är. Som sidans FORM.
private struct Form {
    let moduler: Int
    let min: Double
    let skala: Double
    let fram: Double
    let bak: Double

    static func av(_ typ: Fordonstyp) -> Form {
        switch typ {
        case .sparvagn: return Form(moduler: 3, min: 48, skala: 38, fram: 1.3, bak: 1)
        case .buss: return Form(moduler: 1, min: 24, skala: 17, fram: 0.9, bak: 0.6)
        case .tag: return Form(moduler: 4, min: 66, skala: 56, fram: 1.7, bak: 1.7)
        }
    }
}

/// Ett fordon i moduler som var för sig följer spåret bakom fronten.
private func ritaFordon(_ c: inout GraphicsContext, _ f: Fordon, _ l: Linje, dag: Dag, vy: Vy, tema: Tema, natt: Bool, vald: Bool) {
    guard let tur = f.tur, let lg = f.lage else { return }
    let form = Form.av(l.typ), n = form.moduler, mitt = (n - 1) / 2
    let langd = max(form.min, form.skala * vy.k) / vy.k, glapp = langd * 0.03
    let modul = (langd - Double(n - 1) * glapp) / Double(n)
    let bredd = max(9, 1.6 * dag.linjebredd * vy.k), radie = bredd * 0.38
    let star = lg.star != nil
    let ljusKant = (l.mork && natt) || (l.ljus && !natt)
    let kant = ljusKant ? Color(hex: "#8a98a6") : tema.fordonKant
    let skarm = { (p: CGPoint) in CGPoint(x: (p.x - vy.x) * vy.k, y: (p.y - vy.y) * vy.k) }
    var fram0: CGPoint?, riktning = 0.0, mitten: CGPoint?, mittvinkel = 0.0

    for j in stride(from: n - 1, through: 0, by: -1) {
        let fs = skarm(dag.bakom(tur, k: lg.k, s: lg.s, d: Double(j) * (modul + glapp)))
        let bs = skarm(dag.bakom(tur, k: lg.k, s: lg.s, d: Double(j) * (modul + glapp) + modul))
        let len = max(4, hypot(fs.x - bs.x, fs.y - bs.y)), vinkel = atan2(fs.y - bs.y, fs.x - bs.x)
        if j == 0 { fram0 = fs; riktning = vinkel }
        var m = c
        m.translateBy(x: (fs.x + bs.x) / 2, y: (fs.y + bs.y) / 2)
        m.rotate(by: .radians(vinkel))
        // Svagt sken under vagnen, så att den syns mot sin egen linje.
        m.fill(Path(roundedRect: CGRect(x: -len / 2 - 3, y: -bredd / 2 - 3, width: len + 6, height: bredd + 6), cornerRadius: radie + 3),
               with: .color((ljusKant ? Color(hex: "#8a98a6") : l.farg).opacity(natt ? 0.3 : 0.18)))
        if vald {
            m.stroke(Path(roundedRect: CGRect(x: -len / 2 - 4, y: -bredd / 2 - 4, width: len + 8, height: bredd + 8), cornerRadius: radie + 4),
                     with: .color(tema.signal), lineWidth: 3)
        }
        // Fronten åt +x: hörnen där är runda, bakdelen mindre, lederna nästan raka.
        let led = radie * 0.5, framR = radie * form.fram, bakR = radie * form.bak
        let horn: RectangleCornerRadii = n == 1
            ? RectangleCornerRadii(topLeading: bakR, bottomLeading: bakR, bottomTrailing: framR, topTrailing: framR)
            : j == 0 ? RectangleCornerRadii(topLeading: led, bottomLeading: led, bottomTrailing: framR, topTrailing: framR)
            : j == n - 1 ? RectangleCornerRadii(topLeading: bakR, bottomLeading: bakR, bottomTrailing: led, topTrailing: led)
            : RectangleCornerRadii(topLeading: led, bottomLeading: led, bottomTrailing: led, topTrailing: led)
        let kropp = Path(roundedRect: CGRect(x: -len / 2, y: -bredd / 2, width: len, height: bredd), cornerRadii: horn)
        m.fill(kropp, with: .color(l.farg))
        m.stroke(kropp, with: .color(kant), lineWidth: 1.3)
        // Fönsterband; vid hållplats lyser det och dörrarna är öppna.
        let fonster = star ? Color(red: 1, green: 226 / 255, blue: 140 / 255).opacity(0.85)
            : l.mork ? Color(red: 200 / 255, green: 214 / 255, blue: 226 / 255).opacity(0.3) : Color(red: 8 / 255, green: 14 / 255, blue: 20 / 255).opacity(0.32)
        m.fill(Path(CGRect(x: -len / 2 + bredd * 0.25, y: -bredd * 0.17, width: len - bredd * 0.5, height: bredd * 0.34)), with: .color(fonster))
        if star && bredd >= 11 {
            for dx in [-len * 0.2, len * 0.2] {
                m.fill(Path(CGRect(x: dx - 1.5, y: -bredd / 2 - 1.2, width: 3, height: 2.4)), with: .color(Color(red: 1, green: 240 / 255, blue: 190 / 255)))
                m.fill(Path(CGRect(x: dx - 1.5, y: bredd / 2 - 1.2, width: 3, height: 2.4)), with: .color(Color(red: 1, green: 240 / 255, blue: 190 / 255)))
            }
        }
        if j == 0 && bredd >= 10 {
            for y in [-bredd * 0.3, bredd * 0.3] {
                m.fill(Path(ellipseIn: CGRect(x: len / 2 - 2.8, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(Color(hex: "#fff6d6")))
            }
        }
        if j == n - 1 && bredd >= 10 {
            m.fill(Path(CGRect(x: -len / 2 + 0.6, y: -bredd * 0.36, width: 1.4, height: 1.8)), with: .color(Color(hex: "#ff4d4d")))
            m.fill(Path(CGRect(x: -len / 2 + 0.6, y: bredd * 0.36 - 1.8, width: 1.4, height: 1.8)), with: .color(Color(hex: "#ff4d4d")))
        }
        if j == mitt {
            mitten = CGPoint(x: (fs.x + bs.x) / 2, y: (fs.y + bs.y) / 2)
            mittvinkel = vinkel
        }
    }
    // Linjenumret på mittenmodulen.
    if let mp = mitten, bredd >= 12, l.namn.count <= 3 {
        c.draw(Text(l.namn).font(.system(size: bredd * 0.9, weight: .bold).width(.condensed))
                .foregroundColor(l.mork ? .white : l.text), at: CGPoint(x: mp.x, y: mp.y + 0.5))
    }
    // Försenad vagn: en bricka med minuterna bredvid.
    if f.sen > 180, let mp = mitten {
        let rb = max(6, bredd * 0.5), av = bredd / 2 + rb + 2
        let p = CGPoint(x: mp.x - sin(mittvinkel) * av, y: mp.y + cos(mittvinkel) * av)
        let bricka = Path(ellipseIn: CGRect(x: p.x - rb, y: p.y - rb, width: 2 * rb, height: 2 * rb))
        c.fill(bricka, with: .color(tema.signal))
        c.stroke(bricka, with: .color(tema.bg), lineWidth: 1.5)
        if rb >= 8 {
            c.draw(Text("+\(Int((f.sen / 60).rounded()))").font(.system(size: rb * 1.05, weight: .bold).width(.condensed))
                    .foregroundColor(natt ? Color(hex: "#1a1205") : .white), at: CGPoint(x: p.x, y: p.y + 0.5))
        }
    }
    // Strålkastarljus framför vagnen på natten.
    if natt, let fp = fram0, bredd >= 10, !star {
        let ljus = bredd * 3.2
        var m = c
        m.translateBy(x: fp.x, y: fp.y)
        m.rotate(by: .radians(riktning))
        let kon = Path { p in
            p.move(to: CGPoint(x: 0, y: -bredd * 0.35))
            p.addLine(to: CGPoint(x: ljus, y: -bredd * 0.9))
            p.addLine(to: CGPoint(x: ljus, y: bredd * 0.9))
            p.addLine(to: CGPoint(x: 0, y: bredd * 0.35))
            p.closeSubpath()
        }
        m.fill(kon, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 244 / 255, blue: 200 / 255).opacity(0.35), .clear]),
                                          startPoint: .zero, endPoint: CGPoint(x: ljus, y: 0)))
    }
}
