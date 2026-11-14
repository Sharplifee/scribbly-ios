import Foundation
import Combine
import UIKit
import AVFoundation
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
    /// Every 1 s while the app is on screen, every 5 s in the background — the
    /// timer text ticks on its own, so background pushes only refresh the wave.
    private static let foregroundPush: UInt64 = 1_000_000_000
    private static let backgroundPush: UInt64 = 5_000_000_000
    private var inBackground = UIApplication.shared.applicationState == .background
    /// The "Pause or finish from here" pop-open fires once per recording.
    private var poppedThisRecording = false
    private var lastState: Recorder.State = .idle

    func bind() {
        guard !started else { return }
        started = true
        RecordingControl.isRecording = { Recorder.shared.state == .recording }
        RecordingControl.isActive = { Recorder.shared.state == .recording || Recorder.shared.state == .paused }
        RecordingControl.micAllowed = { AVAudioSession.sharedInstance().recordPermission == .granted }
        RecordingControl.log = { name, outcome in
            EventLog.shared.log(name, ["outcome": outcome, "state": "\(Recorder.shared.state)",
                                       "app_state": UIApplication.shared.applicationState.rawValue])
        }
        RecordingControl.handler = { action in
            let rec = Recorder.shared
            CrashReporter.shared.add("control \(action) (state \(rec.state))")
            EventLog.shared.log("voice_control.\(action)", ["state": "\(rec.state)"])
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
        endOrphans()
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
                let wait = (self?.inBackground ?? false) ? RecordingLiveActivity.backgroundPush : RecordingLiveActivity.foregroundPush
                try? await Task.sleep(nanoseconds: wait)
                guard let self, Recorder.shared.state == .recording else { continue }
                // Phone hot: stop the waveform pushes (the timer ticks by itself).
                guard PowerGovernor.shared.allowsWaveform else { continue }
                self.sync(state: .recording, appending: Recorder.shared.appendTo != nil)
            }
        }
        // Leaving the app mid-recording: pop the island open (silently) so
        // Pause and ✓ Finish are right there. iOS only allows buttons in the
        // expanded island — the small pill opens the app when tapped.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.inBackground = true; self?.popOpen() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.inBackground = false }
            .store(in: &bag)
        rec.$state.combineLatest(rec.$appendTo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, appendTo in self?.sync(state: state, appending: appendTo != nil) }
            .store(in: &bag)
    }

    private func popOpen() {
        guard #available(iOS 16.2, *) else { return }
        let rec = Recorder.shared
        guard !poppedThisRecording, rec.state == .recording || rec.state == .paused,
              let a = Activity<RecordingActivityAttributes>.activities.first else { return }
        poppedThisRecording = true
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

    /// At launch, a Live Activity left over while the recorder is idle (the app was
    /// killed mid-recording, or the phone rebooted) is ended so it can't linger.
    private func endOrphans() {
        guard #available(iOS 16.2, *) else { return }
        guard Recorder.shared.state == .idle else { return }
        for a in Activity<RecordingActivityAttributes>.activities {
            let id = a.id
            Task { await a.end(nil, dismissalPolicy: .immediate) }
            EventLog.shared.log(.system, "live_activity.ended", status: "ok", payload: ["reason": "orphan_at_launch", "activity": id])
        }
    }

    private func sync(state: Recorder.State, appending: Bool) {
        guard #available(iOS 16.2, *) else { return }
        let previous = lastState
        lastState = state
        if state == .recording && previous == .idle { poppedThisRecording = false }
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
                    let a = try Activity.request(attributes: RecordingActivityAttributes(title: "Scribbly"),
                                                 content: content, pushType: nil)
                    CrashReporter.shared.add("live activity started")
                    EventLog.shared.log(.system, "live_activity.started", status: "ok", payload: ["activity": a.id, "appending": appending])
                } catch {
                    CrashReporter.shared.add("live activity request failed: \(error.localizedDescription)")
                }
            }
        case .finishing, .idle:
            // finishing → the ✓ was tapped; idle straight from recording/paused → discarded.
            let reason = state == .finishing ? "finish" : (previous == .finishing ? "finish" : (previous == .idle ? "idle_sync" : "discard"))
            for a in Activity<RecordingActivityAttributes>.activities {
                let id = a.id
                Task { await a.end(nil, dismissalPolicy: .immediate) }
                EventLog.shared.log(.system, "live_activity.ended", status: "ok", payload: ["reason": reason, "activity": id])
                CrashReporter.shared.add("live activity ended (\(reason))")
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
        defer { rec.appendTo = nil; rec.place = nil }   // free for the next take immediately
        // Captured now: a second tap or a new recording must not change where
        // THIS take goes.
        let appendTo = rec.appendTo
        let place = rec.place
        rec.finish { parts, dur in
            guard !parts.isEmpty else { return }
            let appending = appendTo != nil
            // The uploader deletes the raw segments only after the audio is in
            // its pending store; on a failed copy they stay for crash recovery.
            // Uses only what was captured above — a new take may already be
            // recording with its own place / append target.
            up.uploadRecording(parts, duration: dur, location: place ?? PlaceTagger.shared.recentPlace, appendTo: appendTo) { ok, msg in
                BottomChrome.shared.savedTitle = ok ? (appending ? "Added to the recording" : (msg ?? "Saved to your library")) : nil
                StatusWatcher.shared.uploadFinished(ok: ok, title: ok ? msg : nil, error: ok ? nil : msg)
            }
        }
    }
}
