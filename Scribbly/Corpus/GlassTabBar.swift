import SwiftUI

/// The bottom bar: four glass tabs with the Record button as the largest
/// element, a 64pt circle standing proud of the bar (per Connor's reference).
/// Replaces the system tab bar so the mic can overflow it.
struct GlassTabBar: View {
    @Binding var selection: LibraryScreen.Section
    var onRecord: () -> Void

    private let left: [LibraryScreen.Section]  = [.home, .library]
    private let right: [LibraryScreen.Section] = [.groups, .more]

    @State private var recordTaps = 0
    @Namespace private var glassNS

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(left) { tab(for: $0) }
                Spacer().frame(width: 76)             // room under the record button (fixed size)
                ForEach(right) { tab(for: $0) }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .sinkyGlass(Capsule())
            // Sinky record button: an ink disc with a copper dot, ringed off the glass.
            Button { recordTaps += 1; onRecord() } label: {
                ZStack {
                    Circle().fill(P.bg).frame(width: 76, height: 76)
                    Circle().stroke(P.border, lineWidth: 1).frame(width: 76, height: 76)
                    Circle().fill(P.ink).frame(width: 62, height: 62)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                    Circle().fill(P.accent).frame(width: 20, height: 20)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record")
            .sinkyHaptic(recordTaps)
        }
        .frame(height: 74)
        .padding(.horizontal, 16).padding(.bottom, 2)
        .sinkyHaptic(selection)
    }

    private func tab(for s: LibraryScreen.Section) -> some View {
        let on = selection == s
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = s }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: s.icon).font(.system(size: 19, weight: on ? .semibold : .regular))
                Text(s.rawValue).font(.geist(size: 10.5, weight: .medium))
            }
            .foregroundColor(on ? P.ink : P.textDim)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background {
                if on {
                    Capsule().fill(Color.white.opacity(0.09))
                        .matchedGeometryEffect(id: "sel", in: glassNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
                row(icon: "exclamationmark.triangle.fill", title: "Didn't work", sub: "Every video, link or recording that failed — see why, retry, or remove.") {
                    FailedSection().background(P.bg.ignoresSafeArea()).navigationTitle("Didn't work").navigationBarTitleDisplayMode(.inline)
                }
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
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(P.surface2).frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(P.border))
                    Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundColor(P.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.geist(size: 16, weight: .semibold)).tracking(-0.3).foregroundColor(P.ink)
                        if badge > 0 {
                            Text("\(badge)").monoLabel(10, color: Color(hex: 0xF2A57F))
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(P.accent.opacity(0.16)).clipShape(Capsule())
                        }
                    }
                    Text(sub).font(.geist(size: 12.5)).foregroundColor(P.textSec).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(P.textDim)
            }
            .padding(14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.border))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
