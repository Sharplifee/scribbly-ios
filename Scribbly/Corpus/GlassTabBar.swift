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
                Color.clear.frame(width: 76)          // room under the mic
                ForEach(right) { tab(for: $0) }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
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
        .padding(.horizontal, 16).padding(.bottom, 4)
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

/// "More" page: the sections that don't get a bar slot.
struct MoreSection: View {
    let store: LibraryStore
    var body: some View {
        List {
            NavigationLink { CollectionsSection(store: store).navigationTitle("Collections") } label: { Label("Collections", systemImage: "square.stack.fill") }
            NavigationLink { QuerySection().navigationTitle("Query") } label: { Label("Query", systemImage: "sparkle.magnifyingglass") }
            NavigationLink { JobsSection().navigationTitle("Activity") } label: { Label("Activity", systemImage: "waveform.path.ecg") }
        }
        .scrollContentBackground(.hidden)
        .tint(P.accent)
    }
}
