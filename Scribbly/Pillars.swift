import SwiftUI
import UIKit

// MARK: - The Sinky pillar banner
//
// One brand header for every page: a row of solid columns standing side by
// side, each its own colour from the copper → tan → teal ramp (with lighter
// and deeper steps so neighbours never match), each lit from the top-left —
// a bright capital and edge, a deep foot, a shadowed right flank — with a crisp
// black seam between neighbours. The art fades into the black page over its
// bottom 30%.

/// RGB in 0…1, so ramp colours can be mixed (SwiftUI Color can't be on iOS 16).
struct PillarRGB {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    func mix(_ o: PillarRGB, _ t: Double) -> PillarRGB {
        let u = min(max(t, 0), 1)
        return PillarRGB(r: r + (o.r - r) * u, g: g + (o.g - g) * u, b: b + (o.b - b) * u)
    }
    func lighter(_ t: Double) -> PillarRGB { mix(PillarRGB(r: 1, g: 1, b: 1), t) }
    func darker(_ t: Double) -> PillarRGB { mix(PillarRGB(r: 0, g: 0, b: 0), t) }
    /// Positive lightens, negative deepens.
    func step(_ t: Double) -> PillarRGB { t >= 0 ? lighter(t) : darker(-t) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

enum PillarPalette {
    /// Deep copper → copper → light copper → tan → sand → teal → light teal → deep teal.
    static let ramp: [PillarRGB] = [
        PillarRGB(0x8A4122), PillarRGB(0xE8875A), PillarRGB(0xF2A57F), PillarRGB(0xC9A27A),
        PillarRGB(0xDDBE98), PillarRGB(0x4FA3AE), PillarRGB(0x7CC3CB), PillarRGB(0x235E67)
    ]
    /// Brightness steps cycled across the row, so no two neighbours share a tone.
    static let steps: [Double] = [0, -0.26, 0.10, -0.12, 0.16, -0.34]

    /// The ramp at t (0…1), blended between its stops.
    static func sample(_ t: Double) -> PillarRGB {
        let x = min(max(t, 0), 1) * Double(ramp.count - 1)
        let i = min(Int(x), ramp.count - 2)
        return ramp[i].mix(ramp[i + 1], x - Double(i))
    }

    /// Base colour of pillar i of n.
    static func base(_ i: Int, of n: Int) -> PillarRGB {
        let t = n > 1 ? Double(i) / Double(n - 1) : 0
        return sample(t).step(steps[i % steps.count])
    }

    /// A stable pillar colour for anything keyed by name (creator tiles).
    static func tone(for key: String) -> PillarRGB {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return base(Int(h % 12), of: 12)
    }
}

/// The pillar art on its own. Size it with `.frame`; it fills whatever it gets.
struct PillarBanner: View {
    /// Share of the height (from the bottom) that melts into the black page.
    var fade: Double = 0.3

    var body: some View {
        Canvas { ctx, size in
            PillarBanner.draw(in: &ctx, size: size)
        }
        .mask(
            LinearGradient(stops: [
                Gradient.Stop(color: .white, location: 0),
                Gradient.Stop(color: .white, location: 1 - fade),
                Gradient.Stop(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Roughly one pillar per 26pt of width; at least ten.
    static func pillarCount(for width: CGFloat) -> Int { max(10, Int((width / 26).rounded())) }

    static func draw(in ctx: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let gap: CGFloat = 1.5                       // the black seam between columns
        let n = pillarCount(for: size.width)
        let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let h = size.height
        for i in 0..<n {
            let x = CGFloat(i) * (w + gap)
            // A gently stepped skyline: each column stands at its own height.
            let lift = CGFloat((i * 5 + 3) % 7) / 6
            let top = h * (0.02 + 0.10 * lift)
            drawPillar(in: &ctx, rect: CGRect(x: x, y: top, width: w, height: h - top),
                       base: PillarPalette.base(i, of: n))
        }
    }

    private static func drawPillar(in ctx: inout GraphicsContext, rect: CGRect, base: PillarRGB) {
        let shape = Path(rect)

        // 1. Body, lit from above: bright head → base → deep foot.
        let vertical = Gradient(stops: [
            Gradient.Stop(color: base.lighter(0.20).color, location: 0),
            Gradient.Stop(color: base.color, location: 0.35),
            Gradient.Stop(color: base.darker(0.35).color, location: 0.75),
            Gradient.Stop(color: base.darker(0.60).color, location: 1)
        ])
        ctx.fill(shape, with: .linearGradient(vertical,
                                              startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                              endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        // 2. Rounded column: highlight on the left flank, shadow on the right.
        let flank = Gradient(stops: [
            Gradient.Stop(color: Color.white.opacity(0.22), location: 0),
            Gradient.Stop(color: Color.white.opacity(0.05), location: 0.22),
            Gradient.Stop(color: Color.clear, location: 0.45),
            Gradient.Stop(color: Color.black.opacity(0.14), location: 0.70),
            Gradient.Stop(color: Color.black.opacity(0.45), location: 1)
        ])
        ctx.fill(shape, with: .linearGradient(flank,
                                              startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                              endPoint: CGPoint(x: rect.maxX, y: rect.midY)))

        // 3. Two flutes down the shaft (when there's room for them).
        if rect.width >= 14 {
            let fluteTop = rect.minY + 7
            let fluteHeight = max(rect.height - 7, 0)
            for f in [CGFloat(0.36), CGFloat(0.64)] {
                let fx = rect.minX + rect.width * f
                ctx.fill(Path(CGRect(x: fx, y: fluteTop, width: 1, height: fluteHeight)),
                         with: .color(Color.black.opacity(0.16)))
                ctx.fill(Path(CGRect(x: fx + 1, y: fluteTop, width: 0.5, height: fluteHeight)),
                         with: .color(Color.white.opacity(0.08)))
            }
        }

        // 4. Lit left edge, strongest at the top.
        let edge = Gradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.06)])
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)),
                 with: .linearGradient(edge,
                                       startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                       endPoint: CGPoint(x: rect.minX, y: rect.maxY)))

        // 5. Capital: a bright cap with a hairline shadow under it.
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3)),
                 with: .color(base.lighter(0.42).color))
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY + 3, width: rect.width, height: 1)),
                 with: .color(Color.black.opacity(0.28)))
    }
}

/// Height of the top safe area (status bar / Dynamic Island) of the key window.
@MainActor
enum SafeTop {
    static var value: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { s in s as? UIWindowScene }
        let windows = scenes.flatMap { s in s.windows }
        let win = windows.first { w in w.isKeyWindow } ?? windows.first
        return win?.safeAreaInsets.top ?? 47
    }
}

/// The top of every page — the same striped teal→copper card as Home's hero
/// (pure-black gaps between the stripes), the SAME height on every tab and
/// pushed page, with the page title and a mono subtitle inside it.
/// The "Scribbly®" wordmark is on every page: top-left on Home (saved count on
/// the right), top-right everywhere else so the other pages aren't weighted to
/// the left — with "‹ More" on the left of that row for More's sub-pages.
struct PageHeader: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil
    /// Pushed pages keep a nav bar (back button) above the header.
    var underNavBar = false
    /// More's sub-pages: a "‹ More" button on the left of the wordmark row.
    var back: (() -> Void)? = nil
    var backLabel = "More"
    /// Mono text opposite the wordmark ("12,108 saved").
    var trailing: String? = nil
    /// Home only: wordmark on the left.
    var brandLeading = false
    /// One card height for every page.
    var cardHeight: CGFloat = PageHeader.height

    static let height: CGFloat = FinsBackground.bannerHeight
    static let navBar: CGFloat = 44
    private static let rowHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 14) {
            topRow
            ZStack(alignment: .bottomLeading) {
                FinsBackground()
                titles
            }
            .frame(height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(P.edge, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 16)
        .padding(.top, underNavBar ? 2 : 8)
    }

    private var wordmark: some View {
        HStack(alignment: .top, spacing: 1) {
            Text("Scribbly").font(.geist(size: 24, weight: .semibold)).tracking(-1.1).foregroundColor(P.ink)
            Text("®").font(.geist(size: 9)).foregroundColor(P.textSec)
        }
        .accessibilityLabel("Scribbly")
    }

    @ViewBuilder private var trailingText: some View {
        if let trailing, !trailing.isEmpty { Text(trailing).monoLabel(10) }
    }

    @ViewBuilder private var topRow: some View {
        HStack(alignment: .center) {
            if brandLeading {
                wordmark
                Spacer()
                trailingText
            } else {
                if let back {
                    Button(action: back) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            Text(backLabel).font(.geist(size: 15, weight: .medium))
                        }
                        .foregroundColor(P.ink)
                        .padding(.horizontal, 12).frame(height: 34)
                        .sinkyGlass(Capsule(), interactive: true)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to \(backLabel)")
                } else {
                    trailingText
                }
                Spacer()
                wordmark
            }
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 4)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow).monoLabel(9.5, color: Color(hex: 0xD9DCDD))
            }
            if !title.isEmpty {
                Text(title)
                    .font(.geist(size: 32, weight: .semibold)).tracking(-1.4).lineSpacing(-2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(P.ink).lineLimit(3).minimumScaleFactor(0.55)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).monoLabel(9.5, color: Color(hex: 0xD9DCDD))
                    .lineLimit(2).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

extension View {
    /// Pushed pages show their title in the PageHeader, so the nav bar keeps
    /// only its buttons (the title still names the back button of the next page).
    func headerOwnsTitle() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
    }
}
