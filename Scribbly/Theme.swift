import SwiftUI
import UIKit

// MARK: - Sinky type: Geist for everything, Geist Mono for small uppercase labels.

extension Font {
    /// Drop-in for `.system(size:weight:design:)` — same metrics, Geist faces.
    /// `design: .monospaced` maps to Geist Mono. Scales with Dynamic Type.
    static func geist(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if design == .monospaced {
            let name = (weight == .regular || weight == .light || weight == .thin || weight == .ultraLight)
                ? "GeistMono-Regular" : "GeistMono-Medium"
            return .custom(name, size: size, relativeTo: .body)
        }
        let name: String
        switch weight {
        case .medium:          name = "Geist-Medium"
        case .semibold:        name = "Geist-SemiBold"
        case .bold, .heavy, .black: name = "Geist-Bold"
        default:               name = "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }
}

/// Small uppercase Geist Mono label — section heads, counts, meta lines.
struct MonoLabel: ViewModifier {
    var size: CGFloat = 10.5
    var color: Color = P.textSec
    func body(content: Content) -> some View {
        content.font(.geist(size: size, design: .monospaced))
            .tracking(size * 0.06).textCase(.uppercase).foregroundColor(color)
    }
}
extension View {
    func monoLabel(_ size: CGFloat = 10.5, color: Color = P.textSec) -> some View {
        modifier(MonoLabel(size: size, color: color))
    }
}

// MARK: - Liquid Glass (iOS 26+), with a frosted fallback for older iOS.
// On iOS 27 the same glass picks up Apple's refinements (darker edge, brighter
// highlights, the system transparency slider) automatically.

extension View {
    @ViewBuilder
    func sinkyGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(glass(interactive: interactive, tint: tint), in: shape)
        } else {
            self.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.stroke(Color.white.opacity(0.10)))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            )
        }
    }

    @available(iOS 26.0, *)
    private func glass(interactive: Bool, tint: Color?) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// Nav bar: on iOS 26+ let the system Liquid Glass bar and its soft scroll
    /// edge do the work; on older iOS keep the solid black bar.
    @ViewBuilder
    func sinkyNavBar() -> some View {
        if #available(iOS 26.0, *) {
            self.toolbarColorScheme(.dark, for: .navigationBar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.toolbarBackground(P.bg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// Bottom chrome (recorder + tab bar). On iOS 26+ it is a safe-area *bar*, so
    /// lists fade softly under the glass instead of being cut off.
    @ViewBuilder
    func sinkyBottomBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

    /// Light haptic whenever `trigger` changes (iOS 17+).
    @ViewBuilder
    func sinkyHaptic<T: Equatable>(_ trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else { self }
    }
}

/// Secondary action: Liquid Glass button on iOS 26+, hairline outline before.
struct SinkySecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 46
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(size: 15, weight: .medium)).foregroundColor(P.ink)
            .frame(maxWidth: .infinity).frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sinkyGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Primary action: solid ink (Sinky's off-white) with black text.
struct SinkyPrimaryButtonStyle: ButtonStyle {
    var enabled = true
    var height: CGFloat = 46
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(size: 15, weight: .semibold))
            .foregroundColor(enabled ? .black : P.textDim)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(enabled ? P.ink : P.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(enabled ? Color.clear : P.border))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Sinky surfaces

/// The striped teal→copper "fins" panel from the Sinky hero.
struct FinsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x071113), location: 0),
                .init(color: Color(hex: 0x1D4C54), location: 0.34),
                .init(color: Color(hex: 0x4F9AA4), location: 0.52),
                .init(color: Color(hex: 0xE8875A), location: 0.78),
                .init(color: Color(hex: 0x2A160B), location: 1),
            ], startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
            GeometryReader { geo in
                Path { p in
                    var x: CGFloat = 7
                    while x < geo.size.width { p.addRect(CGRect(x: x, y: 0, width: 2, height: geo.size.height)); x += 9 }
                }
                .fill(Color.black.opacity(0.5))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum SinkyAppearance {
    /// UIKit-drawn chrome (nav titles, back buttons, segmented controls) in Geist.
    static func apply() {
        guard let title = UIFont(name: "Geist-SemiBold", size: 17),
              let large = UIFont(name: "Geist-SemiBold", size: 32),
              let button = UIFont(name: "Geist-Regular", size: 17) else { return }
        let ink = UIColor(P.ink)
        let nav = UINavigationBar.appearance()
        nav.titleTextAttributes = [.font: title, .foregroundColor: ink]
        nav.largeTitleTextAttributes = [.font: large, .foregroundColor: ink, .kern: -1.2]
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: button], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.font: UIFont(name: "Geist-Medium", size: 13) ?? button], for: .normal)
    }
}
