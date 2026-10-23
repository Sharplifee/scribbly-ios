import AVFoundation
import Foundation
import UIKit

/// Background-durable audio recorder.
///
/// The hard requirement: once recording starts, NOTHING stops it except the user
/// tapping Finish. iOS will otherwise happily kill a recording when a call comes
/// in, Siri activates, headphones are yanked, another app grabs the audio route,
/// or the screen locks. Each of those is handled explicitly below.
///
/// Design notes:
/// - `AVAudioSession` category `.playAndRecord` with `.mixWithOthers` so we are not
///   forcibly evicted when another app plays audio.
/// - `UIBackgroundModes: audio` in Info.plist keeps us alive when backgrounded.
/// - Recording is written in SEGMENTS. Every interruption closes the current file
///   and opens a new one; on Finish the segments are concatenated. This means an
///   interruption can never corrupt or truncate more than the instant it occurred,
///   and a crash still leaves every completed segment on disk.
/// - A background task assertion covers the moment of suspension so the final
///   segment is flushed to disk rather than lost.
final class Recorder: NSObject, ObservableObject {

    enum State: Equatable { case idle, recording, paused, finishing }

    @Published private(set) var state: State = .idle
    static let shared = Recorder()
    /// Where this recording started ("Riverside Country Club, Provo").
    @Published var place: String?
    /// Set before start() to append this take to an existing entry ("Add to this recording"); cleared after finish.
    @Published var appendTo: String? = nil
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1 for the waveform
    @Published private(set) var lastError: String?
    /// True while iOS has taken the mic away (call/Siri). UI shows "Interrupted —
    /// will resume automatically" rather than looking broken.
    @Published private(set) var interrupted = false

    private var recorder: AVAudioRecorder?
    private var segments: [URL] = []
    private var timer: Timer?
    private var accumulated: TimeInterval = 0            // completed segments
    private var segmentStartedAt: Date?                 // wall-clock guard for currentTime
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let session = AVAudioSession.sharedInstance()

    /// Set when the user explicitly pauses, so an interruption ending does not
    /// resume a recording the user deliberately paused.
    private var userPaused = false
    /// True between start() and the permission/session answer, so a second tap
    /// (or the Control Center intent firing twice) can't start two recordings.
    private var startPending = false
    /// Silence watchdog: iOS can hand the app a "live" mic that only delivers
    /// zeros (recording started while another audio client owns the input, or a
    /// background start that didn't get the hardware). Pure digital silence sits
    /// near -120…-160 dBFS; any real room never does. If the first seconds are
    /// all zeros we rebuild the session once, then tell the user plainly.
    private var heardSignal = false
    private var silentTicks = 0
    private var silenceHealAttempts = 0

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption),
                       name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(handleRouteChange),
                       name: AVAudioSession.routeChangeNotification, object: session)
        nc.addObserver(self, selector: #selector(handleMediaReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        recoverOrphanedRecording()
    }

    // MARK: - Session

    private func configureSession() throws {
        // .mixWithOthers keeps us from being torn down when another app plays audio.
        // .allowBluetooth so AirPods work. .defaultToSpeaker is irrelevant for pure
        // capture but harmless and avoids a silent-route surprise on playback.
        try session.setCategory(.playAndRecord,
                                mode: .spokenAudio,
                                options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: [])
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        } else {
            session.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        }
    }

    // MARK: - Controls

    func start() {
        guard state == .idle, !startPending else { return }
        startPending = true
        lastError = nil
        requestPermission { [weak self] granted in
            guard let self else { return }
            self.startPending = false
            guard self.state == .idle else { return }
            guard granted else {
                self.appendTo = nil
                self.lastError = "Microphone access is off. Enable it in Settings › Scribbly › Microphone."
                return
            }
            do {
                try self.configureSession()
                self.segments.removeAll()
                self.accumulated = 0
                self.elapsed = 0
                self.userPaused = false
                self.heardSignal = false
                self.silentTicks = 0
                self.silenceHealAttempts = 0
                try self.beginSegment()
                self.state = .recording
                self.startTimer()
            } catch {
                self.closeSegment()
                self.appendTo = nil
                self.lastError = "Could not start recording (\(error.localizedDescription)). Tap Record to try again."
            }
        }
    }

    /// User-initiated pause. Distinct from an interruption.
    func pause() {
        guard state == .recording else { return }
        userPaused = true
        recorder?.pause()
        state = .paused
        stopTimer()
    }

    /// Dismiss the error line under the record bar.
    func clearError() { lastError = nil }

    func resume() {
        guard state == .paused else { return }
        userPaused = false
        // If an interruption killed the session while paused, rebuild it.
        if recorder == nil || !(recorder?.record() ?? false) {
            try? configureSession()
            try? beginSegment()
        }
        state = .recording
        interrupted = false
        startTimer()
    }

    /// The ONLY path that ends a recording. Hands back what must be queued —
    /// the merged take, or every raw segment if merging failed — WITHOUT
    /// deleting anything: the uploader removes the raw segments only once the
    /// audio is safely in its pending store, so a failed copy leaves them for
    /// crash recovery instead of losing the recording.
    func finish(completion: @escaping ([Uploader.RecordingPart], TimeInterval) -> Void) {
        guard state == .recording || state == .paused else {
            if state == .idle { appendTo = nil }
            completion([], 0)
            return
        }
        state = .finishing
        stopTimer()
        closeSegment()
        let total = accumulated
        let segs = segments

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var parts: [Uploader.RecordingPart] = []
            if let merged = self?.merge(segs) {
                parts = [Uploader.RecordingPart(url: merged, title: nil, rawSources: segs)]
            } else {
                // Export failed: nothing is dropped — every raw segment goes to
                // the uploader on its own; the server transcodes each caf.
                let existing = segs.filter { FileManager.default.fileExists(atPath: $0.path) }
                let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
                let stamp = fmt.string(from: Date())
                for (i, seg) in existing.enumerated() {
                    parts.append(Uploader.RecordingPart(
                        url: seg,
                        title: i == 0 ? nil : "Recording — \(stamp) (part \(i + 1))",
                        rawSources: [seg]))
                }
            }
            let ready = parts
            DispatchQueue.main.async {
                try? self?.session.setActive(false, options: [.notifyOthersOnDeactivation])
                self?.state = .idle
                self?.elapsed = 0
                self?.level = 0
                self?.interrupted = false
                self?.segments = []
                self?.accumulated = 0
                if ready.isEmpty { self?.appendTo = nil }
                completion(ready, total)
            }
        }
    }

    func discard() {
        guard state != .finishing else { return }
        stopTimer()
        closeSegment()
        for u in segments { try? FileManager.default.removeItem(at: u) }
        segments = []
        accumulated = 0
        elapsed = 0
        level = 0
        interrupted = false
        userPaused = false
        appendTo = nil
        state = .idle
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Rescues a recording the OS killed mid-write. CAF segments left behind by
    /// a dead session are merged (the export writes a clean .m4a) and handed to
    /// the uploader, so the audio is SAVED — never silently lost, never a corpse.
    func recoverOrphanedRecording() {
        guard state == .idle, recorder == nil else { return }
        let fm = FileManager.default
        let leftovers = ((try? fm.contentsOfDirectory(at: Self.liveDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("scribbly-seg-") }
            .filter { (((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                        .timeIntervalSinceNow) < -10 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !leftovers.isEmpty else { return }
        let created = (try? leftovers[0].resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
        let title = "Recovered recording — \(fmt.string(from: created))"
        let autoApprove = (UserDefaults.standard.object(forKey: "autoApproveRecoveries") as? Bool) ?? false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var allSaved = true
            if let merged = self.merge(leftovers) {
                if Uploader.shared.hold(fileURL: merged, title: title, autoApprove: autoApprove) {
                    // The pending store owns a copy — only now can the segments go.
                    for u in leftovers { try? fm.removeItem(at: u) }
                } else {
                    allSaved = false
                }
                if !leftovers.contains(merged) { try? fm.removeItem(at: merged) }
            } else {
                // Can't compose: rescue every segment individually, deleting
                // each original only once its copy is safely queued.
                for (i, u) in leftovers.enumerated() {
                    if Uploader.shared.hold(fileURL: u, title: "\(title) (part \(i + 1))", autoApprove: autoApprove) {
                        try? fm.removeItem(at: u)
                    } else {
                        allSaved = false
                    }
                }
            }
            let saved = allSaved
            DispatchQueue.main.async {
                if !saved {
                    self.lastError = "A recording cut off by a crash could not be saved yet (storage full?). It is kept and will be retried on next launch."
                } else if autoApprove {
                    self.lastError = "A recording cut off by a crash was recovered and is uploading."
                } else {
                    self.lastError = "A recording cut off by a crash was recovered — open Activity to approve or discard it."
                }
            }
        }
    }

    // MARK: - Segments

    /// Segments live in Application Support (never purged by iOS) as CAF —
    /// a container that is valid at ANY truncation point. A crash, force-quit,
    /// or battery death mid-recording leaves a readable file, not a corpse.
    static var liveDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveRecording", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private func beginSegment() throws {
        let url = Self.liveDir
            .appendingPathComponent("scribbly-seg-\(segments.count)-\(UUID().uuidString).caf")
        // Linear PCM inside CAF: every sample already written is readable no
        // matter where the file is cut — the canonical crash-safe capture pair.
        // (AAC-in-CAF dies at the first buffer flush on device; the encoder
        // aborts silently after record() returns true. Never use it here.)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.record() else { throw NSError(domain: "Scribbly", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder refused to start"]) }
        recorder = r
        segmentStartedAt = Date()
        segments.append(url)
    }

    /// AVAudioRecorder.currentTime returns garbage (often a huge negative
    /// number) after an interruption or route change. Never trust it raw:
    /// clamp to [0, wall-clock length of this segment].
    private func sanePosition(_ r: AVAudioRecorder) -> TimeInterval {
        let wall = max(0, -(segmentStartedAt?.timeIntervalSinceNow ?? 0))
        let t = r.currentTime
        guard t.isFinite, t >= 0 else { return wall }
        return min(t, wall + 1)
    }

    private func closeSegment() {
        if let r = recorder {
            accumulated += sanePosition(r)
            // Detach first: our own stop() must not look like the encoder
            // dying, or the delegate would open a stray extra segment.
            r.delegate = nil
            r.stop()
        }
        recorder = nil
        segmentStartedAt = nil
    }

    /// Concatenate segments into one m4a. Single segment is returned as-is.
    private func merge(_ urls: [URL]) -> URL? {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        // A lone segment can only be returned as-is when it is already a clean
        // m4a. CAF (our crash-safe capture format) always goes through the
        // export below, which writes a proper indexed .m4a.
        if existing.count == 1 && existing[0].pathExtension.lowercased() != "caf" { return existing[0] }

        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for url in existing {
            let asset = AVURLAsset(url: url)
            guard let a = asset.tracks(withMediaType: .audio).first else { continue }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try? track.insertTimeRange(range, of: a, at: cursor)
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribbly-\(Int(Date().timeIntervalSince1970)).m4a")
        try? FileManager.default.removeItem(at: out)
        // nil (not existing[0]) on failure: callers then queue EVERY segment
        // rather than shipping the first one and deleting the rest.
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        ex.outputURL = out
        ex.outputFileType = .m4a
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        // Long recordings legitimately take a while to encode — give them the
        // time. On failure return nil so callers upload EVERY segment instead
        // of silently shipping only the first twelve minutes.
        _ = sem.wait(timeout: .now() + 600)
        return ex.status == .completed ? out : nil
    }

    // MARK: - Timer / metering

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let r = self.recorder, r.isRecording else {
                // The recorder died under us (encode error, media reset) while
                // the UI still says Recording. Rotate to a fresh segment so the
                // session heals instead of silently freezing.
                if self.state == .recording && !self.interrupted {
                    self.closeSegment()
                    if (try? self.beginSegment()) == nil {
                        self.lastError = "Recording stopped unexpectedly — what was captured is safe. Tap Finish to save it."
                        self.stopTimer()
                        self.state = .paused
                    }
                }
                return
            }
            r.updateMeters()
            // dBFS (-160...0) -> 0...1, weighted so normal speech fills the bar
            let db = r.averagePower(forChannel: 0)
            let norm = max(0, min(1, (db + 50) / 50))
            self.level = norm
            self.checkSilence(peak: r.peakPower(forChannel: 0))
            // Monotonic: the clock can only move forward while recording.
            self.elapsed = max(self.elapsed, self.accumulated + self.sanePosition(r))
        }
        // .common so the timer keeps firing while the user scrolls
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// Called every 50 ms while recording. 60 ticks = 3 s of pure zeros.
    private func checkSilence(peak: Float) {
        if heardSignal { return }
        if peak > -100 {               // anything a real microphone produces
            heardSignal = true
            silentTicks = 0
            if lastError?.hasPrefix("The microphone") == true { lastError = nil }
            return
        }
        silentTicks += 1
        guard silentTicks >= 60 else { return }
        silentTicks = 0
        if silenceHealAttempts == 0 {
            silenceHealAttempts = 1
            // Rebuild the audio session and start a fresh segment; the silent
            // segment stays in the list (harmless) so nothing is ever lost.
            closeSegment()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            do {
                try configureSession()
                try beginSegment()
                lastError = "The microphone wasn't picking anything up — reconnected it. Keep talking."
            } catch {
                lastError = "The microphone isn't picking anything up. Tap ✕ and Record again."
            }
        } else if silenceHealAttempts == 1 {
            silenceHealAttempts = 2
            lastError = "The microphone still isn't picking anything up — another app (a call, Siri or dictation) may be holding it. Tap ✕ and Record again."
        }
    }

    // MARK: - Interruption handling (the whole point)

    @objc private func handleInterruption(_ n: Notification) {
        // AVAudioSession posts these on its own thread; all state lives on main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleInterruption(n) }
            return
        }
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // Phone call, Siri, alarm. Close the segment so nothing is lost, and
            // remember that we were mid-recording so we can pick straight back up.
            guard state == .recording else { return }
            interrupted = true
            closeSegment()
            stopTimer()

        case .ended:
            guard interrupted else { return }
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            interrupted = false
            // Only auto-resume if the USER had not deliberately paused.
            guard !userPaused, state == .recording || state == .paused else { return }
            if opts.contains(.shouldResume) || true {
                // Retry a few times — the session is not always immediately available
                // after a call tears down.
                resumeAfterInterruption(attempt: 0)
            }

        @unknown default: break
        }
    }

    private func resumeAfterInterruption(attempt: Int) {
        // Finished/discarded meanwhile, or another path already restarted it.
        guard state == .recording || state == .paused, recorder == nil else { return }
        guard attempt < 8 else {
            lastError = "Recording was interrupted and could not restart. Audio up to that point is safe — tap Finish to save it."
            return
        }
        do {
            try configureSession()
            try beginSegment()
            state = .recording
            interrupted = false
            startTimer()
        } catch {
            let delay = pow(2.0, Double(attempt)) * 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.resumeAfterInterruption(attempt: attempt + 1)
            }
        }
    }

    /// Headphones unplugged, AirPods disconnected, Bluetooth dropped. Default iOS
    /// behavior on `.oldDeviceUnavailable` is to stop — we explicitly keep going.
    @objc private func handleRouteChange(_ n: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleRouteChange(n) }
            return
        }
        guard state == .recording,
              let info = n.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override:
            if recorder?.isRecording != true {
                closeSegment()
                try? configureSession()
                try? beginSegment()
                startTimer()
            }
        default: break
        }
    }

    /// Rare, but iOS can reset the whole media stack. Everything must be rebuilt.
    @objc private func handleMediaReset(_ n: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleMediaReset(n) }
            return
        }
        guard state == .recording else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
        startTimer()
    }

    /// Buy time on suspension so the current segment is flushed rather than truncated.
    @objc private func appDidEnterBackground() {
        guard state == .recording || state == .paused else { return }
        // Settings › "Keep recording in background" off: leaving the app ends
        // (and saves) the recording instead of capturing in the background.
        let keep = (UserDefaults.standard.object(forKey: "keepRecordingInBackground") as? Bool) ?? true
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ScribblyRecording") { [weak self] in
            guard let self else { return }
            if self.bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTask)
                self.bgTask = .invalid
            }
        }
        if !keep {
            Task { @MainActor [weak self] in self?.finishAndUpload() }
        }
    }

    /// An interruption that began (call, Siri) doesn't always deliver its
    /// `.ended` notification. Coming back to the app is proof the mic is free
    /// again, so pick the recording back up if it is still waiting.
    @objc private func appDidBecomeActive() {
        guard state == .recording, recorder == nil else { return }
        resumeAfterInterruption(attempt: 0)
    }
}

extension Recorder: AVAudioRecorderDelegate {
    /// Fired if the encoder dies. Never treat this as "done" — restart a segment.
    func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.audioRecorderDidFinishRecording(r, successfully: flag) }
            return
        }
        guard state == .recording, r === recorder else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
    }

    func audioRecorderEncodeErrorDidOccur(_ r: AVAudioRecorder, error: Error?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.audioRecorderEncodeErrorDidOccur(r, error: error) }
            return
        }
        guard state == .recording, r === recorder else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
    }
}
