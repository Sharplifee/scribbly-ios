import SwiftUI

/// The server's progress milestones for one item (scribbly_queue and the voice
/// server's /jobs): 5 Starting · 10 Fetching captions · 15 Downloading audio ·
/// 30–90 Transcribing i/n (60 = got captions) · 90 Summarizing & saving · 100 Done.
enum ProgressMilestones {
    static let marks: [Double] = [5, 10, 15, 30, 60, 90, 100]

    /// The next milestone strictly above `p` (100 at the end).
    static func next(after p: Double) -> Double {
        for m in marks where m > p + 0.01 { return m }
        return 100
    }

    /// How far the bar may glide on its own: the next milestone − 2, never below `p`.
    static func ceiling(after p: Double) -> Double {
        if p >= 100 { return 100 }
        return max(p, next(after: p) - 2)
    }

    /// Typical seconds the stage at `p` takes (the glide's time constant).
    static func stageSeconds(at p: Double) -> Double {
        switch p {
        case ..<10: return 3      // starting
        case ..<15: return 5      // fetching captions
        case ..<30: return 12     // downloading audio
        case ..<60: return 25     // transcribing
        case ..<90: return 20     // transcribing / got captions
        default:    return 10     // summarizing & saving
        }
    }
}

/// A progress value that moves in real time between server updates: it eases
/// toward (never past) a ceiling — the next milestone − 2 — and snaps forward
/// to the server's number whenever one arrives, so a job never sits at 0% and
/// then jumps to 100%.
@MainActor
final class EasedProgress: ObservableObject {
    /// 0…100, what the bar and the percentage show.
    @Published private(set) var shown: Double = 0
    private var server: Double = 0
    private var ceiling: Double = 0
    private var tau: Double = 8
    private var ticker: Task<Void, Never>?

    /// A fresh poll: `value` is the server's percentage, `ceiling` how far the
    /// bar may glide before the next poll, `tau` the stage's typical seconds.
    func update(server value: Double, ceiling cap: Double, tau t: Double) {
        let v = min(max(value, 0), 100)
        if v + 0.5 < server {
            // The server went backwards (a new job / retry): start again from its value.
            shown = v
        } else if v > shown {
            shown = v
        }
        server = v
        ceiling = min(max(cap, v), 100)
        tau = max(t, 1)
        if v >= 100 { shown = 100; stop(); return }
        start()
    }

    /// Convenience for a single item reporting one progress number.
    func update(single value: Double) {
        update(server: value, ceiling: ProgressMilestones.ceiling(after: value),
               tau: ProgressMilestones.stageSeconds(at: value))
    }

    func finish() { server = 100; ceiling = 100; shown = 100; stop() }

    func reset() { server = 0; ceiling = 0; shown = 0; stop() }

    private func start() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                let gap = self.ceiling - self.shown
                if gap <= 0.05 { continue }       // parked just under the next milestone
                let step = gap * (1 - exp(-dt / self.tau))
                self.shown = min(self.ceiling, self.shown + step)
            }
        }
    }

    /// (No deinit needed: the ticker holds `self` weakly and ends when it's gone.)
    private func stop() { ticker?.cancel(); ticker = nil }
}

/// "Transcribing 2/5 · 47%" + the gradient bar, driven by an EasedProgress.
struct EasedProgressBar: View {
    @ObservedObject var progress: EasedProgress
    var stage: String
    var height: CGFloat = 5

    var body: some View {
        let pct = Int(progress.shown.rounded(.down))
        let pctText = "\(pct)%"
        return VStack(alignment: .leading, spacing: 5) {
            GradientProgress(value: progress.shown, total: 100, height: height, duration: 0.12)
            HStack(spacing: 6) {
                Text(stage.isEmpty ? "Working…" : stage)
                    .font(.geist(size: 11.5)).foregroundColor(P.textSec).lineLimit(1)
                Spacer(minLength: 4)
                Text(pctText)
                    .font(.geist(size: 11.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit().foregroundColor(P.ink)
            }
        }
    }
}

/// Live progress for one voice-server job (GET /jobs returns progress + stage).
struct VoiceJobProgress: View {
    let progress: Int?
    let stage: String?
    let state: String
    @StateObject private var eased = EasedProgress()

    private var serverValue: Double {
        if let p = progress { return Double(p) }
        switch state {
        case "transcribing": return 30
        case "saving":       return 90
        default:             return 5
        }
    }
    private var stageText: String {
        if let s = stage, !s.isEmpty { return s }
        switch state {
        case "pending":      return "Queued"
        case "transcribing": return "Transcribing"
        case "saving":       return "Summarizing & saving"
        default:             return "Working…"
        }
    }

    var body: some View {
        EasedProgressBar(progress: eased, stage: stageText)
            .onAppear { eased.update(single: serverValue) }
            .onChange(of: serverValue) { v in eased.update(single: v) }
    }
}
