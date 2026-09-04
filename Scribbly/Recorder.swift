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
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let session = AVAudioSession.sharedInstance()

    /// Set when the user explicitly pauses, so an interruption ending does not
    /// resume a recording the user deliberately paused.
    private var userPaused = false

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
        guard state == .idle else { return }
        lastError = nil
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.lastError = "Microphone access is off. Enable it in Settings › Scribbly › Microphone."
                return
            }
            do {
                try self.configureSession()
                self.segments.removeAll()
                self.accumulated = 0
                self.elapsed = 0
                self.userPaused = false
                try self.beginSegment()
                self.state = .recording
                self.startTimer()
            } catch {
                self.lastError = "Could not start recording: \(error.localizedDescription)"
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

    /// The ONLY path that ends a recording. Returns the merged audio file.
    func finish(completion: @escaping (URL?, TimeInterval) -> Void) {
        guard state == .recording || state == .paused else { completion(nil, 0); return }
        state = .finishing
        stopTimer()
        closeSegment()
        let total = accumulated
        let segs = segments

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let merged = self?.merge(segs)
            DispatchQueue.main.async {
                try? self?.session.setActive(false, options: [.notifyOthersOnDeactivation])
                self?.state = .idle
                self?.elapsed = 0
                self?.level = 0
                self?.interrupted = false
                self?.segments = []
                self?.accumulated = 0
                completion(merged, total)
            }
        }
    }

    func discard() {
        stopTimer()
        closeSegment()
        for u in segments { try? FileManager.default.removeItem(at: u) }
        segments = []
        accumulated = 0
        elapsed = 0
        level = 0
        interrupted = false
        userPaused = false
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let merged = self.merge(leftovers) ?? leftovers[0]
            Uploader.shared.upload(fileURL: merged, title: title, duration: nil) { _, _ in }
            for u in leftovers { try? fm.removeItem(at: u) }
            DispatchQueue.main.async {
                self.lastError = "A recording interrupted by a crash was recovered and is uploading."
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
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64000
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.record() else { throw NSError(domain: "Scribbly", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder refused to start"]) }
        recorder = r
        segments.append(url)
    }

    private func closeSegment() {
        if let r = recorder {
            accumulated += r.currentTime
            r.stop()
        }
        recorder = nil
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
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { return existing[0] }
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
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return existing[0] }
        ex.outputURL = out
        ex.outputFileType = .m4a
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        _ = sem.wait(timeout: .now() + 120)
        return ex.status == .completed ? out : existing[0]
    }

    // MARK: - Timer / metering

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder, r.isRecording else { return }
            r.updateMeters()
            // dBFS (-160...0) -> 0...1, weighted so normal speech fills the bar
            let db = r.averagePower(forChannel: 0)
            let norm = max(0, min(1, (db + 50) / 50))
            self.level = norm
            self.elapsed = self.accumulated + r.currentTime
        }
        // .common so the timer keeps firing while the user scrolls
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: - Interruption handling (the whole point)

    @objc private func handleInterruption(_ n: Notification) {
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
        guard attempt < 8 else {
            lastError = "Recording was interrupted and could not restart. Audio up to that point was saved."
            return
        }
        do {
            try configureSession()
            try beginSegment()
            state = .recording
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
        guard state == .recording else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
        startTimer()
    }

    /// Buy time on suspension so the current segment is flushed rather than truncated.
    @objc private func appDidEnterBackground() {
        guard state == .recording || state == .paused else { return }
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ScribblyRecording") { [weak self] in
            guard let self else { return }
            if self.bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTask)
                self.bgTask = .invalid
            }
        }
    }
}

extension Recorder: AVAudioRecorderDelegate {
    /// Fired if the encoder dies. Never treat this as "done" — restart a segment.
    func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        guard state == .recording else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
    }

    func audioRecorderEncodeErrorDidOccur(_ r: AVAudioRecorder, error: Error?) {
        guard state == .recording else { return }
        closeSegment()
        try? configureSession()
        try? beginSegment()
    }
}
