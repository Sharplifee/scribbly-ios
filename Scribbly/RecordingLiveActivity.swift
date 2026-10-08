import Foundation
import Combine
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Mirrors Recorder.shared into a Live Activity so a recording stays visible in
/// the Dynamic Island and on the Lock Screen whenever you leave the app.
@MainActor
final class RecordingLiveActivity {
    static let shared = RecordingLiveActivity()
    private var bag = Set<AnyCancellable>()
    private var started = false

    private var levelLoop: Task<Void, Never>?
    private var recentLevels: [Double] = Array(repeating: 0.05, count: 12)

    func bind() {
        guard !started else { return }
        started = true
        RecordingControl.handler = { action in
            let rec = Recorder.shared
            switch action {
            case "toggle": rec.state == .recording ? rec.pause() : rec.resume()
            case "finish": rec.finishAndUpload()
            default: break
            }
        }
        let rec = Recorder.shared
        // Sample the input level a few times a second; push to the Live
        // Activity about once a second (the system throttles faster updates).
        rec.$level.receive(on: RunLoop.main).sink { [weak self] l in
            guard let self, Recorder.shared.state == .recording else { return }
            self.recentLevels.append(Double(min(1, max(0.05, l))))
            if self.recentLevels.count > 12 { self.recentLevels.removeFirst(self.recentLevels.count - 12) }
        }.store(in: &bag)
        levelLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, Recorder.shared.state == .recording else { continue }
                self.sync(state: .recording, appending: Recorder.shared.appendTo != nil)
            }
        }
        rec.$state.combineLatest(rec.$appendTo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, appendTo in self?.sync(state: state, appending: appendTo != nil) }
            .store(in: &bag)
    }

    private func sync(state: Recorder.State, appending: Bool) {
        guard #available(iOS 16.2, *) else { return }
        let elapsed = Recorder.shared.elapsed
        switch state {
        case .recording, .paused:
            let cs = RecordingActivityAttributes.ContentState(
                timerStart: Date().addingTimeInterval(-elapsed),
                paused: state == .paused,
                pausedElapsed: Int(elapsed),
                appending: appending,
                levels: state == .paused ? Array(repeating: 0.05, count: 12) : recentLevels)
            let content = ActivityContent(state: cs, staleDate: nil)
            if let a = Activity<RecordingActivityAttributes>.activities.first {
                Task { await a.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                _ = try? Activity.request(attributes: RecordingActivityAttributes(title: "Scribbly"),
                                          content: content, pushType: nil)
            }
        case .finishing, .idle:
            for a in Activity<RecordingActivityAttributes>.activities {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}

extension Recorder {
    /// The ✓ action, shared by the in-app bar and the Live Activity button:
    /// finish the recording and hand it to the uploader.
    @MainActor func finishAndUpload() {
        let rec = self
        let up = Uploader.shared
        rec.finish { url, dur in
            guard let url else { return }
            let appending = rec.appendTo != nil
            up.upload(fileURL: url, duration: dur, location: rec.place, appendTo: rec.appendTo) { ok, msg in
                BottomChrome.shared.savedTitle = ok ? (appending ? "Added to the recording" : (msg ?? "Saved to your library")) : nil
            }
            rec.appendTo = nil
        }
    }
}
