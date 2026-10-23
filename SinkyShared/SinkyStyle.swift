import SwiftUI

/// The Sinky look for the targets outside the main app (widgets, Live Activity,
/// Control, Apple Watch). Same colours and fonts as the app's Theme/P.
enum Sinky {
    static let ink     = Color(red: 0.953, green: 0.949, blue: 0.933)   // #F3F2EE
    static let copper  = Color(red: 0.910, green: 0.529, blue: 0.353)   // #E8875A
    /// Lit copper for keylines / borders on black, where #E8875A reads dim.
    static let copperBright = Color(red: 1.0, green: 0.616, blue: 0.396) // #FF9D65
    static let tan     = Color(red: 0.788, green: 0.635, blue: 0.478)   // #C9A27A
    static let teal    = Color(red: 0.310, green: 0.639, blue: 0.682)   // #4FA3AE
    static let surface = Color(red: 0.055, green: 0.059, blue: 0.063)   // #0E0F10
    static let border  = Color(red: 0.141, green: 0.153, blue: 0.165)   // #24272A
    static let dim     = Color(red: 0.486, green: 0.510, blue: 0.522)   // #7C8285
    static let good    = Color(red: 0.424, green: 0.788, blue: 0.631)   // #6CC9A1

    static var rule: LinearGradient {
        LinearGradient(colors: [copper, tan, teal], startPoint: .leading, endPoint: .trailing)
    }

    /// Geist / Geist Mono (bundled in each target), falling back to system.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        let name: String
        if mono { name = weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium" }
        else {
            switch weight {
            case .medium: name = "Geist-Medium"
            case .semibold: name = "Geist-SemiBold"
            case .bold, .heavy, .black: name = "Geist-Bold"
            default: name = "Geist-Regular"
            }
        }
        return .custom(name, size: size)
    }

    /// Copper → tan → teal, sampled at position i of n (for wave bars).
    static func rampColor(_ i: Int, of n: Int) -> Color {
        let t = n > 1 ? Double(i) / Double(n - 1) : 0
        let a: (Double, Double, Double) = (0.910, 0.529, 0.353)
        let b: (Double, Double, Double) = (0.788, 0.635, 0.478)
        let c: (Double, Double, Double) = (0.310, 0.639, 0.682)
        func mix(_ x: (Double, Double, Double), _ y: (Double, Double, Double), _ u: Double) -> Color {
            Color(red: x.0 + (y.0 - x.0) * u, green: x.1 + (y.1 - x.1) * u, blue: x.2 + (y.2 - x.2) * u)
        }
        return t < 0.5 ? mix(a, b, t * 2) : mix(b, c, (t - 0.5) * 2)
    }
}

/// The record mark: an ink disc with a copper dot — the app's centre button.
struct SinkyRecordMark: View {
    var size: CGFloat = 60
    var ring = true
    var body: some View {
        ZStack {
            if ring {
                Circle().fill(Color.black).frame(width: size * 1.22, height: size * 1.22)
                Circle().stroke(Sinky.border, lineWidth: 1).frame(width: size * 1.22, height: size * 1.22)
            }
            Circle().fill(Sinky.ink).frame(width: size, height: size)
            Circle().fill(Sinky.copper).frame(width: size * 0.32, height: size * 0.32)
        }
    }
}

/// The striped teal→copper "fins" panel from the Sinky hero.
struct SinkyFins: View {
    var dim: Double = 1
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(red: 0.027, green: 0.067, blue: 0.075), location: 0),
                .init(color: Color(red: 0.114, green: 0.298, blue: 0.329), location: 0.34),
                .init(color: Color(red: 0.310, green: 0.604, blue: 0.643), location: 0.52),
                .init(color: Color(red: 0.910, green: 0.529, blue: 0.353), location: 0.78),
                .init(color: Color(red: 0.165, green: 0.086, blue: 0.043), location: 1),
            ], startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
            GeometryReader { geo in
                Path { p in
                    var x: CGFloat = 5
                    while x < geo.size.width { p.addRect(CGRect(x: x, y: 0, width: 1.5, height: geo.size.height)); x += 7 }
                }
                .fill(Color.black.opacity(0.5))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom)
            if dim < 1 { Color.black.opacity(1 - dim) }
        }
    }
}
