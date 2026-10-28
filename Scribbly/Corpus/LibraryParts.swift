import SwiftUI

// Building blocks for the Library page: rows, type chips with counts, the
// creators strip, the filter menu tokens, the voice-notes summary, section
// headers and the designed loading / empty states.

/// A small pillar-coloured tile: lit top, deep foot, a highlight on the left
/// flank and shadow on the right — the banner's pillars in miniature.
struct PillarTile: View {
    let tone: PillarRGB
    var symbol: String? = nil
    var text: String? = nil
    var size: CGFloat = 36
    var corner: CGFloat = 9

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let shaft = LinearGradient(colors: [tone.lighter(0.18).color, tone.color, tone.darker(0.32).color],
                                  startPoint: .top, endPoint: .bottom)
        let flank = LinearGradient(stops: [
            Gradient.Stop(color: Color.white.opacity(0.22), location: 0),
            Gradient.Stop(color: Color.clear, location: 0.4),
            Gradient.Stop(color: Color.black.opacity(0.28), location: 1)
        ], startPoint: .leading, endPoint: .trailing)
        return ZStack {
            shape.fill(shaft)
            shape.fill(flank)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.72))
            }
            if let text {
                Text(text)
                    .font(.geist(size: size * 0.38, weight: .semibold)).tracking(-0.4)
                    .foregroundColor(Color.black.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .top) {
            // The capital: a bright cap line like the banner's pillars.
            Rectangle().fill(tone.lighter(0.45).color).frame(height: 2)
                .padding(.horizontal, corner * 0.6)
        }
        .accessibilityHidden(true)
    }

    /// Icon and tone for an entry's type (YouTube takes its creator's tone).
    static func style(for e: Entry, creator: String?) -> (symbol: String, tone: PillarRGB) {
        if e.isVoice { return ("waveform", PillarRGB(0xE8875A)) }
        if e.isPodcast { return ("mic.fill", PillarRGB(0xC9A27A)) }
        switch e.displayType {
        case "YouTube":   return ("play.fill", PillarPalette.tone(for: creator ?? "YouTube"))
        case "Instagram": return ("camera.fill", PillarRGB(0x4FA3AE))
        case "Note":      return ("note.text", PillarRGB(0xC9A27A))
        case "Article":   return ("doc.text.fill", PillarRGB(0xDDBE98))
        default:          return ("doc.fill", PillarRGB(0x7CC3CB))
        }
    }
}

/// One Library row: type tile · title · meta line (creator, time, length,
/// place) · first lines of the summary. Hairline under it.
struct LibraryRow: View {
    let entry: Entry
    /// Longest / Shortest: the length, trailing in mono.
    var showLength = false
    @ObservedObject private var creators = CreatorDirectory.shared

    var body: some View {
        let creator = creators.creator(for: entry)
        let title = entry.displayTitle(creator: creator)
        let meta = entry.metaLine(creator: creator)
        let lead = entry.summaryLead
        let length = showLength ? (entry.durationText ?? "") : ""
        let style = PillarTile.style(for: entry, creator: creator)
        return HStack(alignment: .top, spacing: 12) {
            PillarTile(tone: style.tone, symbol: style.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.geist(size: 15.5, weight: .medium)).tracking(-0.2)
                    .foregroundColor(P.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text(meta).font(.geist(size: 12)).foregroundColor(P.textDim).lineLimit(1)
                if !lead.isEmpty {
                    Text(lead).font(.geist(size: 13)).foregroundColor(P.textSec.opacity(0.9))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !length.isEmpty {
                Text(length).font(.geist(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(P.ink).padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(P.divider).frame(height: 1).padding(.leading, 64)
        }
        .contentShape(Rectangle())
    }
}

/// A pinned section header: "Today ·········· 7".
struct LibrarySectionHeader: View {
    let title: String
    let count: String

    @ViewBuilder var body: some View {
        if !title.isEmpty {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(P.brandVertical).frame(width: 3, height: 14)
                Text(title).font(.geist(size: 15, weight: .semibold)).tracking(-0.3).foregroundColor(P.ink)
                Spacer(minLength: 8)
                Text(count).monoLabel(10, color: P.textSec)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            // Seamless sticky header: in the list it's a plain black band; once it
            // pins to the top it fills up behind the status bar (no rows peeking
            // through above it) and fades softly into the list below — no hard bar.
            .background(GeometryReader { g in
                let minY = g.frame(in: .global).minY
                let pinned = minY <= SafeTop.value + 1
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.black)
                        .frame(height: g.size.height + (pinned ? max(0, minY) : 0))
                        .offset(y: pinned ? -max(0, minY) : 0)
                    LinearGradient(colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                        .offset(y: g.size.height)
                        .opacity(pinned ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.18), value: pinned)
            })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// One type chip: name + count.
struct TypeChip: Hashable {
    let name: String
    let count: Int?
}

/// All · Voice notes · YouTube · Instagram · Notes — each with its count, on
/// its own row, scrolling sideways when it doesn't fit.
struct TypeChipRow: View {
    let chips: [TypeChip]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.name) { c in chip(c) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 2)
    }

    private func chip(_ c: TypeChip) -> some View {
        let on = selection == c.name
        let countText = c.count.map { n in n.formatted() } ?? ""
        return Button { selection = c.name } label: {
            HStack(spacing: 6) {
                Text(c.name).font(.geist(size: 13, weight: on ? .semibold : .regular))
                if !countText.isEmpty {
                    Text(countText).font(.geist(size: 11, design: .monospaced)).opacity(on ? 0.6 : 0.55)
                }
            }
            .foregroundColor(on ? .black : Color(hex: 0xD9DCDD))
            .padding(.horizontal, 12).frame(height: 32)
            .background(on ? P.ink : Color.clear).clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : Color(hex: 0x2E3236)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(countText.isEmpty ? c.name : "\(c.name), \(countText)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A removable filter token under the search row ("This week ×").
struct FilterToken: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                Text(label).font(.geist(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(Color(hex: 0xF2A57F))
            .padding(.horizontal, 10).frame(height: 26)
            .background(P.accent.opacity(0.14)).clipShape(Capsule())
            .overlay(Capsule().stroke(P.accent.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(label)")
    }
}

/// The filter button that sits at the end of the search row.
struct FilterButtonLabel: View {
    let active: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(active > 0 ? P.accent : Color(hex: 0xD9DCDD))
                .frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .sinkyGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
            if active > 0 {
                Text("\(active)").font(.geist(size: 10, weight: .bold)).foregroundColor(.black)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(P.accent))
                    .offset(x: 4, y: -4)
            }
        }
        .accessibilityLabel(active > 0 ? "Sort and filter, \(active) active" : "Sort and filter")
    }
}

/// Top creators as pillar-coloured monogram tiles; tap filters the Library.
struct CreatorsStrip: View {
    let groups: [Group]
    let selected: String?
    let onPick: (String) -> Void
    let onSeeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Creators").sectionHead()
                Spacer()
                Button(action: onSeeAll) {
                    Text("See all ›").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(groups) { g in
                        Button { onPick(g.channel) } label: {
                            CreatorTile(name: g.channel, count: g.totalVideos, on: selected == g.channel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 14).padding(.bottom, 4)
    }
}

struct CreatorTile: View {
    let name: String
    let count: Int
    let on: Bool

    var body: some View {
        let tone = PillarPalette.tone(for: name)
        let mono = Self.initials(name)
        let countText = count.formatted() + " videos"
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            PillarTile(tone: tone, text: mono, size: 44, corner: 10)
            Text(name).font(.geist(size: 13, weight: .medium)).foregroundColor(P.ink).lineLimit(1)
            Text(countText).monoLabel(9, color: P.textDim).lineLimit(1)
        }
        .padding(10)
        .frame(width: 122, alignment: .leading)
        .background(shape.fill(on ? P.surface2 : P.surface))
        .overlay(shape.stroke(on ? P.accent : P.border, lineWidth: on ? 1.5 : 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(countText)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "Jordan Peterson" → "JP", "Dr. Ramani" → "DR", "Huberman" → "H".
    static func initials(_ s: String) -> String {
        let words = s.split(separator: " ").filter { w in w.first?.isLetter ?? false }
        let letters = words.prefix(2).compactMap { w in w.first }.map { c in String(c) }
        let out = letters.joined().uppercased()
        return out.isEmpty ? String(s.prefix(1)).uppercased() : out
    }
}

/// Voice notes filter: this month's count and recorded time.
struct VoiceSummaryCard: View {
    let month: LibraryStore.VoiceMonth?

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM"
        return f
    }()

    static func duration(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    var body: some View {
        let name = Self.monthName.string(from: Date())
        let time = month.map { m in Self.duration(m.seconds) } ?? "—"
        let count = month.map { m in "\(m.count)" } ?? "—"
        let allTime = month.flatMap { m in m.allTime > 0 ? "\(m.allTime.formatted()) all time" : nil } ?? ""
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return HStack(alignment: .center, spacing: 14) {
            MiniPillars().frame(width: 34, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(time).font(.geist(size: 28, weight: .semibold)).tracking(-1)
                    .foregroundStyle(P.brand)
                Text("Recorded in \(name)").monoLabel(9.5)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(count).font(.geist(size: 22, weight: .semibold)).foregroundColor(P.ink)
                Text("notes this month").monoLabel(9)
                if !allTime.isEmpty { Text(allTime).monoLabel(9, color: P.textDim) }
            }
        }
        .padding(14)
        .background(shape.fill(P.surface))
        .overlay(shape.stroke(P.edge))
        .padding(.horizontal, 16).padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Four tiny pillars — the banner's motif at icon size.
struct MiniPillars: View {
    private let heights: [CGFloat] = [0.58, 0.82, 1.0, 0.7]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let tone = PillarPalette.base(i * 3, of: 10)
                    Rectangle()
                        .fill(LinearGradient(colors: [tone.lighter(0.2).color, tone.darker(0.35).color],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: geo.size.height * heights[i])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Placeholder rows while the first page loads.
struct SkeletonRows: View {
    var count = 7
    @State private var dim = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let titleWidth: CGFloat = i % 2 == 0 ? 260 : 200
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(P.surface2)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(P.surface2).frame(width: titleWidth, height: 12)
                        Capsule().fill(P.surface2).frame(width: 150, height: 9)
                        Capsule().fill(P.surface).frame(height: 9)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
        .opacity(dim ? 0.4 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// Designed empty / error state.
struct LibraryNotice: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            PillarTile(tone: PillarRGB(0xC9A27A), symbol: symbol, size: 46, corner: 12)
            Text(title).font(.geist(size: 16, weight: .semibold)).foregroundColor(P.ink)
                .multilineTextAlignment(.center)
            Text(message).font(.geist(size: 13)).foregroundColor(P.textSec)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.accent)
                        .padding(.horizontal, 16).frame(height: 36)
                        .overlay(Capsule().stroke(P.accent.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.vertical, 36)
    }
}
