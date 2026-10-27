import Foundation
import Combine
import UIKit
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
    /// Waveform history for the Island / Lock Screen: one peak per quarter
    /// second, newest last — 16 samples ≈ the last 4 seconds of audio.
    static let levelSamples = 16
    private var recentLevels: [Double] = Array(repeating: 0.05, count: RecordingLiveActivity.levelSamples)
    private var windowPeak: Double = 0
    private var windowStart = Date()
    /// Seconds between Live Activity pushes while recording. ActivityKit
    /// throttles anything faster, and the timer ticks on its own
    /// (Text(timerInterval:)), so the only reason to push is the waveform.
    private static let pushInterval: UInt64 = 500_000_000

    func bind() {
        guard !started else { return }
        started = true
        RecordingControl.isRecording = { Recorder.shared.state == .recording }
        RecordingControl.handler = { action in
            let rec = Recorder.shared
            CrashReporter.shared.add("control \(action) (state \(rec.state))")
            switch action {
            case "start":
                guard rec.state == .idle else { return }
                rec.place = nil
                PlaceTagger.shared.tag { Recorder.shared.place = $0 }
                rec.start()
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
            // The meter ticks at 20 Hz; keep the loudest moment of each 0.25 s
            // window so the wave reads like speech, not a flat average.
            self.windowPeak = max(self.windowPeak, Double(min(1, max(0.05, l))))
            let now = Date()
            if now.timeIntervalSince(self.windowStart) >= 0.12 {
                self.recentLevels.append(self.windowPeak)
                let n = RecordingLiveActivity.levelSamples
                if self.recentLevels.count > n { self.recentLevels.removeFirst(self.recentLevels.count - n) }
                self.windowPeak = 0
                self.windowStart = now
            }
        }.store(in: &bag)
        levelLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: RecordingLiveActivity.pushInterval)
                guard let self, Recorder.shared.state == .recording else { continue }
                self.sync(state: .recording, appending: Recorder.shared.appendTo != nil)
            }
        }
        // Leaving the app mid-recording: pop the island open (silently) so
        // Pause and ✓ Finish are right there. iOS only allows buttons in the
        // expanded island — the small pill opens the app when tapped.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.popOpen() }
            .store(in: &bag)
        rec.$state.combineLatest(rec.$appendTo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, appendTo in self?.sync(state: state, appending: appendTo != nil) }
            .store(in: &bag)
    }

    private func popOpen() {
        guard #available(iOS 16.2, *) else { return }
        let rec = Recorder.shared
        guard rec.state == .recording || rec.state == .paused,
              let a = Activity<RecordingActivityAttributes>.activities.first else { return }
        let cs = RecordingActivityAttributes.ContentState(
            timerStart: Date().addingTimeInterval(-rec.elapsed),
            paused: rec.state == .paused,
            pausedElapsed: Int(rec.elapsed),
            appending: rec.appendTo != nil,
            levels: recentLevels)
        let alert = AlertConfiguration(title: "Recording", body: "Pause or finish from here.",
                                       sound: .named("silence.wav"))
        Task { await a.update(ActivityContent(state: cs, staleDate: nil), alertConfiguration: alert) }
        CrashReporter.shared.add("live activity popped open on background")
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
                levels: state == .paused ? Array(repeating: 0.05, count: Self.levelSamples) : recentLevels)
            let content = ActivityContent(state: cs, staleDate: nil)
            if let a = Activity<RecordingActivityAttributes>.activities.first {
                Task { await a.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity.request(attributes: RecordingActivityAttributes(title: "Scribbly"),
                                             content: content, pushType: nil)
                    CrashReporter.shared.add("live activity started")
                } catch {
                    CrashReporter.shared.add("live activity request failed: \(error.localizedDescription)")
                }
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
        // Captured now: a second tap or a new recording must not change where
        // THIS take goes.
        let appendTo = rec.appendTo
        let place = rec.place
        rec.finish { parts, dur in
            rec.appendTo = nil
            guard !parts.isEmpty else { return }
            let appending = appendTo != nil
            // The uploader deletes the raw segments only after the audio is in
            // its pending store; on a failed copy they stay for crash recovery.
            up.uploadRecording(parts, duration: dur, location: rec.place ?? place, appendTo: appendTo) { ok, msg in
                BottomChrome.shared.savedTitle = ok ? (appending ? "Added to the recording" : (msg ?? "Saved to your library")) : nil
            }
        }
    }
}
