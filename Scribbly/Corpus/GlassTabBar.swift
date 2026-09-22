import SwiftUI

/// The bottom bar: four glass tabs with the Record button as the largest
/// element, a 64pt circle standing proud of the bar (per Connor's reference).
/// Replaces the system tab bar so the mic can overflow it.
struct GlassTabBar: View {
    @Binding var selection: LibraryScreen.Section
    var onRecord: () -> Void

    private let left: [LibraryScreen.Section]  = [.home, .library]
    private let right: [LibraryScreen.Section] = [.groups, .more]

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(left) { tab(for: $0) }
                Spacer().frame(width: 76)             // room under the mic (fixed size)
                ForEach(right) { tab(for: $0) }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.10)))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            )
            Button(action: onRecord) {
                ZStack {
                    Circle().fill(P.bg).frame(width: 76, height: 76)   // dark ring separating mic from glass
                    Circle().fill(P.brand).frame(width: 64, height: 64)
                        .shadow(color: P.accent.opacity(0.6), radius: 14, y: 6)
                    Image(systemName: "mic.fill").font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record")
        }
        .frame(height: 74)
        .padding(.horizontal, 16).padding(.bottom, 2)
    }

    private func tab(for s: LibraryScreen.Section) -> some View {
        let on = selection == s
        return Button { selection = s } label: {
            VStack(spacing: 3) {
                Image(systemName: s.icon).font(.system(size: 20, weight: .medium))
                Text(s.rawValue).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(on ? P.accent : P.textSec)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(on ? Capsule().fill(P.accent.opacity(0.18)) : nil)
        }
        .buttonStyle(.plain)
    }
}

/// "More" page: Collections · Query · Activity · Apple Watch · Settings, as cards.
struct MoreSection: View {
    let store: LibraryStore
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                tap(icon: "square.stack.fill", title: "Collections", sub: "Every batch you've queued, with progress.", go: .collections)
                tap(icon: "sparkle.magnifyingglass", title: "Query", sub: "Ask a question across everything in the library.", go: .query)
                tap(icon: "waveform.path.ecg", title: "Activity", sub: "Everything processing right now — pause, resume, retry, or cancel.", badge: up.pendingCount, go: .jobs)
                tap(icon: "applewatch", title: "Apple Watch", sub: "Record on the wrist; it lands here with the same place title.", go: .watch)
                tap(icon: "gearshape.fill", title: "Settings", sub: "Permissions, recording, storage, server status.", go: .settings)
            }
            .padding(16)
        }
    }

    private func tap(icon: String, title: String, sub: String, badge: Int = 0, go: LibraryScreen.Section) -> some View {
        Button { BottomChrome.shared.moreSub = go } label: { rowLabel(icon: icon, title: title, sub: sub, badge: badge) }
            .buttonStyle(.plain)
    }
    private func row<D: View>(icon: String, title: String, sub: String, badge: Int = 0, @ViewBuilder dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: { rowLabel(icon: icon, title: title, sub: sub, badge: badge) }
            .buttonStyle(.plain)
    }
    private func rowLabel(icon: String, title: String, sub: String, badge: Int) -> some View {
        SwiftUI.Group {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)).frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundColor(P.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 7).padding(.vertical, 1).background(P.accent).clipShape(Capsule())
                        }
                    }
                    Text(sub).font(.system(size: 12.5)).foregroundColor(P.textSec).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(P.textDim)
            }
            .padding(14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
        }
    }
}
