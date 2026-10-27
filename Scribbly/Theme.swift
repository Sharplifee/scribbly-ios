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
            // Automatic visibility: clear while the page's pillar banner is under
            // it, solid black once content scrolls beneath it.
            self.toolbarBackground(P.bg, for: .navigationBar)
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
    /// Home's hero card height; every page's top banner uses the same.
    static let bannerHeight: CGFloat = 196
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
                .fill(Color.black)   // pure black: each stripe reads as a real gap
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

// MARK: - Gradient everywhere (copper → tan → teal)

extension P {
    /// Card / field outline: copper at one corner, teal at the other, quiet in between.
    static var edge: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.55), border, border, teal.opacity(0.5)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var brandVertical: LinearGradient {
        LinearGradient(colors: [accent, tan, teal], startPoint: .top, endPoint: .bottom)
    }
}

/// Every page sits on true black. The brand banner is no longer painted
/// behind the page (rows used to scroll over it and it hid under cards on
/// Groups): each page starts with a PageHeader — the pillar banner plus the
/// title — as the first thing in its scroll content (see Pillars.swift).
/// The parameters are kept so existing call sites compile unchanged.
struct SinkyBackdrop: View {
    var intensity: Double = 1
    var banner: Bool = true
    var body: some View {
        Color.black
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Bottom chrome clearance (tab bar + recorder/upload bar)

/// Height of the floating bottom chrome, reported by LibraryScreen.
struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Reserves room at the bottom of a scrolling page equal to the floating bars
/// (glass tab bar + recording/upload capsule when it shows), so the last row can
/// always be scrolled fully above them and tapped.
struct ChromeInset: ViewModifier {
    @ObservedObject private var chrome = BottomChrome.shared
    func body(content: Content) -> some View {
        let h = (chrome.barHeights[chrome.currentTab] ?? 96) + 8
        return content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: h).allowsHitTesting(false)
        }
    }
}

/// Tapping the already-selected tab scrolls its root page back to the top.
enum ScrollTop { static let anchor = "scribbly.scrollTop" }
struct ScrollTopOnReselect: ViewModifier {
    let tab: LibraryScreen.Section
    @ObservedObject private var chrome = BottomChrome.shared
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: chrome.reselectTick) { _ in
                guard chrome.reselectTab == tab else { return }
                withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(ScrollTop.anchor, anchor: .top) }
            }
        }
    }
}

/// Zero-height marker at the very top of a scroll view's content.
struct ScrollTopAnchor: View {
    var body: some View { Color.clear.frame(height: 0).id(ScrollTop.anchor) }
}

/// Distance (in the scroll view's own coordinate space) from the top of the
/// visible area to the end-of-list sentinel. Infinity when it isn't laid out.
struct NearEndKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// Put this after the last row of a paged list. It reports where it is; the
/// list loads more only when the user has actually scrolled within reach of it,
/// so a freshly appended page (which pushes it far down) never chains another.
struct LoadMoreSentinel: View {
    let space: String
    var body: some View {
        Color.clear.frame(height: 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: NearEndKey.self, value: g.frame(in: .named(space)).minY)
            })
    }
}

extension View {
    func chromeInset() -> some View { modifier(ChromeInset()) }
    func scrollsToTopOnReselect(_ tab: LibraryScreen.Section) -> some View { modifier(ScrollTopOnReselect(tab: tab)) }
    /// Use on the ScrollView that contains a `LoadMoreSentinel(space:)`.
    func onNearEnd(space: String, within distance: CGFloat = 1600, perform: @escaping () -> Void) -> some View {
        self.coordinateSpace(name: space)
            .onPreferenceChange(NearEndKey.self) { y in
                if y < distance { perform() }
            }
    }
}

/// The vertical fin stripes on their own, drawn over whatever is behind them.
struct FinsStripes: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 7
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(.black))
                x += 9
            }
        }
    }
}

/// 1.5pt copper → teal hairline (under headers, between sections).
struct GradientRule: View {
    var width: CGFloat? = nil
    var body: some View {
        Capsule().fill(P.brand).frame(width: width, height: 1.5)
    }
}

/// Progress in the brand gradient instead of a flat tint.
struct GradientProgress: View {
    var value: Double
    var total: Double = 1
    var height: CGFloat = 4
    /// How long the bar glides to a new value (live pollers use ~their interval).
    var duration: Double = 0.3
    var body: some View {
        GeometryReader { geo in
            let f = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(P.divider)
                Capsule().fill(P.brand).frame(width: max(height, geo.size.width * f))
                    .animation(.easeInOut(duration: duration), value: f)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((total > 0 ? value / total : 0) * 100)) percent")
    }
}

/// Section heading: a short copper→teal tick, then the mono label.
struct SectionHead: ViewModifier {
    func body(content: Content) -> some View {
        HStack(spacing: 8) {
            GradientRule(width: 14)
            content.monoLabel(10, color: P.textSec)
        }
    }
}
extension View {
    func sectionHead() -> some View { modifier(SectionHead()) }
}

// MARK: - Text size (Settings → Text size)

/// App-wide text size. Every Geist font is relative to .body, so this scales
/// the whole app. "Default" follows the iPhone's own Text Size setting, which
/// reads smaller than "Small" on Connor's phone, so it comes first in the row.
enum TextSizeOption: String, CaseIterable, Identifiable {
    case standard = "Default", small = "Small", large = "Large", xLarge = "Larger", xxLarge = "Largest"
    var id: String { rawValue }
    var size: DynamicTypeSize? {
        switch self {
        case .small: return .small
        case .standard: return nil
        case .large: return .xLarge
        case .xLarge: return .xxLarge
        case .xxLarge: return .xxxLarge
        }
    }
    /// Sample size for the picker's "A".
    var sample: CGFloat {
        switch self { case .standard: return 13; case .small: return 16; case .large: return 19; case .xLarge: return 22; case .xxLarge: return 25 }
    }
    static let storageKey = "scribbly.textSize"
}

struct AppTextSize: ViewModifier {
    @AppStorage(TextSizeOption.storageKey) private var raw = TextSizeOption.standard.rawValue
    @ViewBuilder
    func body(content: Content) -> some View {
        if let s = (TextSizeOption(rawValue: raw) ?? .standard).size {
            content.dynamicTypeSize(s)
        } else {
            content.dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
    }
}

/// Pushed pages hide the system nav bar (their back button lives in the
/// PageHeader row), which would normally also kill the edge swipe-back.
/// Keep it: the pop gesture is allowed whenever there's something to pop.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
