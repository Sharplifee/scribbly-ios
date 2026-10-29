import SwiftUI

/// Live status of a batch (a channel, podcast show or set of links) with
/// Pause / Resume and Cancel. Shown at the top of any collection that still
/// has work queued, paused or running.
struct BatchProgressPanel: View {
    let collectionID: String
    @State private var s: Status?
    @State private var busy = false
    @State private var confirmCancel = false
    @State private var note: String?

    struct Current: Decodable { let title: String?; let progress: Int?; let status: String? }
    struct Status: Decodable {
        let total: Int; let done: Int; let pending: Int; let processing: Int
        let paused: Int; let cancelled: Int; let failed: Int; let already_saved: Int
        let current: Current?
    }

    private var active: Bool { (s?.pending ?? 0) + (s?.processing ?? 0) > 0 }
    private var isPaused: Bool { !active && (s?.paused ?? 0) > 0 }
    private var visible: Bool { guard let s else { return false }; return s.pending + s.processing + s.paused > 0 || s.cancelled > 0 }

    var body: some View {
        SwiftUI.Group {
            if visible, let s { panel(s) }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .confirmationDialog("Cancel this batch?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel remaining items", role: .destructive) { Task { await control("cancel") } }
        } message: {
            Text("Everything already saved stays. Items not yet processed are dropped.")
        }
    }

    private func panel(_ s: Status) -> some View {
        let finished = s.done
        let total = max(1, s.total - s.cancelled)
        let fraction = Double(finished) / Double(total)
        let state: String = active ? (s.processing > 0 ? "PROCESSING" : "QUEUED")
                          : isPaused ? "PAUSED" : "STOPPED"
        let left = s.pending + s.processing + s.paused
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state).font(.custom("GeistMono-Medium", fixedSize: 11)).tracking(0.8)
                    .foregroundColor(active ? P.accent : P.tan)
                Spacer()
                Text("\(finished.formatted()) of \(total.formatted()) done")
                    .font(.geist(size: 13, weight: .medium)).foregroundColor(P.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(P.surface2)
                    Capsule().fill(P.brand).frame(width: max(6, g.size.width * fraction))
                }
            }
            .frame(height: 6)
            if let c = s.current, let t = c.title, left > 0 {
                Text((c.status == "processing" ? "Now: " : "Next: ") + t + (c.progress.map { " · \($0)%" } ?? ""))
                    .font(.geist(size: 13)).foregroundColor(P.textSec).lineLimit(2)
            }
            Text(detailLine(s)).font(.geist(size: 12)).foregroundColor(P.textDim)
            if let note { Text(note).font(.geist(size: 12)).foregroundColor(P.textSec) }
            if left > 0 {
                HStack(spacing: 10) {
                    button(isPaused ? "Resume" : "Pause", icon: isPaused ? "play.fill" : "pause.fill", primary: true) {
                        Task { await control(isPaused ? "resume" : "pause") }
                    }
                    button("Cancel", icon: "xmark", primary: false) { confirmCancel = true }
                }
                .disabled(busy)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(P.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.border))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func detailLine(_ s: Status) -> String {
        var parts = ["\((s.pending + s.processing + s.paused).formatted()) left"]
        if s.failed > 0 { parts.append("\(s.failed) didn't work") }
        if s.cancelled > 0 { parts.append("\(s.cancelled) cancelled") }
        if s.already_saved > 0 { parts.append("\(s.already_saved) already in your library") }
        return parts.joined(separator: " · ")
    }

    private func button(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.geist(size: 15, weight: .semibold))
                .foregroundColor(primary ? .black : P.danger)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Capsule().fill(primary ? P.ink : P.surface2))
                .overlay(Capsule().stroke(primary ? Color.clear : P.border))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let d = try? await AuthSession.shared.rpc("scribbly_batch_status", ["p_collection": collectionID]),
              let st = try? JSONDecoder().decode(Status.self, from: d) else { return }
        s = st
    }

    private func control(_ op: String) async {
        busy = true; defer { busy = false }
        EventLog.shared.log("batch.\(op)", subject: collectionID)
        if (try? await AuthSession.shared.rpc("scribbly_batch_control", ["p_collection": collectionID, "p_op": op])) != nil {
            note = op == "pause" ? "Paused — nothing more will be processed until you resume."
                 : op == "resume" ? "Resumed." : "Cancelled. Everything already saved stays."
        } else {
            note = "Couldn't reach the server — try again."
        }
        await load()
    }
}
