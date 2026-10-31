import SwiftUI

/// Dag och natt, samma färger som sidan (web/index.html).
struct Tema {
    let bg: Color
    let panel: Color
    let rule: Color
    let knapp: Color
    let text: Color
    let muted: Color
    let signal: Color
    let live: Color
    /// Kanten runt linjerna på kartan.
    let kant: Color
    let prick: Color
    let prickKant: Color
    let namn: Color
    /// Kanten runt vita linjer på dagen och svarta linjer på natten.
    let vitKant: Color
    let svartKant: Color
    /// Kanten runt vagnarna.
    let fordonKant: Color

    static let natt = Tema(
        bg: Color(hex: "#0b1016"), panel: Color(red: 16 / 255, green: 23 / 255, blue: 31 / 255).opacity(0.95),
        rule: Color(hex: "#223040"), knapp: Color(hex: "#182230"), text: Color(hex: "#dce5ee"),
        muted: Color(hex: "#8395a7"), signal: Color(hex: "#ffb547"), live: Color(hex: "#5fd38d"),
        kant: Color(hex: "#0b1016"), prick: Color(hex: "#e4ebf2"), prickKant: Color(hex: "#0b1016"),
        namn: Color(hex: "#a7b6c4"), vitKant: Color(hex: "#0b1016"), svartKant: Color(hex: "#7b8a99"),
        fordonKant: Color(hex: "#0b1016"))

    static let dag = Tema(
        bg: Color(hex: "#f2f5f7"), panel: Color.white.opacity(0.96),
        rule: Color(hex: "#d3dbe2"), knapp: Color(hex: "#eef2f5"), text: Color(hex: "#14212c"),
        muted: Color(hex: "#586a7a"), signal: Color(hex: "#b85f00"), live: Color(hex: "#14874a"),
        kant: Color.white, prick: Color.white, prickKant: Color(hex: "#14212c"),
        namn: Color(hex: "#23313e"), vitKant: Color(hex: "#8a98a6"), svartKant: Color.white,
        fordonKant: Color(hex: "#14212c"))
}

extension AppModell {
    var tema: Tema { natt ? .natt : .dag }
}

/// Linjens skylt: numret på linjens färg.
struct Bricka: View {
    let linje: Linje
    var storlek: Double = 17

    var body: some View {
        Text(linje.namn)
            .font(.system(size: storlek, weight: .bold).width(.condensed))
            .foregroundStyle(linje.text)
            .padding(.horizontal, storlek * 0.35)
            .frame(minWidth: storlek * 1.9, minHeight: storlek * 1.3)
            .background(linje.farg, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if linje.ljus || linje.mork {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: "#7b8a99"), lineWidth: 1)
                }
            }
    }
}
