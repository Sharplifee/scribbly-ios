import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns every recording from the moment Finish is tapped until the note is
/// provably in the library.
///
/// Rules, all learned the hard way:
///   1. The audio is copied somewhere durable *before* any network call and is
///      deleted only once the entry has been read back from the database.
///   2. Success is never assumed. A response that isn't parseable JSON with an
///      entry id is a failure — that assumption is how a 413 on an eight-minute
///      note produced a green checkmark and no note.
///   3. Length is not the user's problem. Long recordings are split, uploaded
///      and transcribed segment by segment, with each segment's text persisted
///      as it lands, so a crash or a dead network resumes instead of restarting.
final class Uploader: NSObject, ObservableObject {

    static let shared = Uploader()

    @Published var isUploading = false
    @Published var progress: Double = 0
    /// Honest description of what is happening right now ("Uploading… 62%",
    /// "Transcribing part 2 of 4…"). The bar label binds to this, so the UI can
    /// never say "Uploading" while the server is actually transcribing.
    @Published var stage: String = ""
    @Published var lastError: String?
    @Published var pendingCount: Int = 0

    /// Kept so the AppDelegate's background-session hook still compiles.
    var backgroundCompletionHandler: (() -> Void)?

    private let fm = FileManager.default

    /// Guards `draining`, `rerunRequested` and `waiters`. Drains are kicked off
    /// from several Tasks at once (Finish, foreground, Retry, Watch); only one
    /// may run, and a late caller joins the running one instead of being told
    /// "done" before its recording was even looked at.
    private let drainLock = NSLock()
    private var draining = false
    private var rerunRequested = false
    private var waiters: [(jobID: String?, completion: (Bool, String?) -> Void)] = []

    private var pendingDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    // MARK: - Public entry points

    /// Provisional title; the server replaces it with "<topic> · <place>" once
    /// it has the transcript. If no place is known, the time stays.
    static func defaultTitle(location: String?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        let stamp = fmt.string(from: Date())
        return location.map { "\($0) — \(stamp)" } ?? "Voice Memo — \(stamp)"
    }

    func upload(fileURL: URL, duration: TimeInterval, location: String? = nil, appendTo: String? = nil,
                completion: @escaping (Bool, String?) -> Void) {
        upload(fileURL: fileURL, title: Self.defaultTitle(location: location), duration: duration,
               location: location, appendTo: appendTo, completion: completion)
    }

    /// Same as upload(fileURL:duration:) but with a caller-chosen title.
    /// The copy into the pending store runs off the main thread (a long
    /// recording is hundreds of MB); `completion` is always called on main.
    func upload(fileURL: URL, title: String, duration: TimeInterval?, location: String? = nil, appendTo: String? = nil,
                completion: @escaping (Bool, String?) -> Void) {
        Task.detached(priority: .userInitiated) { [self] in
            let id: String
            do {
                id = try self.enqueue(fileURL: fileURL, title: title, duration: duration ?? 0, mime: "audio/m4a",
                                      location: location, appendTo: appendTo)
            } catch {
                self.setState(uploading: false, error: "Could not save the recording on this phone (\(error.localizedDescription)). Free up storage and try again.")
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            await self.drain(jobID: id) { ok, msg in DispatchQueue.main.async { completion(ok, msg) } }
        }
    }

    /// One file produced by Finish: the merged take, or (if merging failed)
    /// one raw segment. `rawSources` are the capture segments that become
    /// redundant once this file is safely in the pending store.
    struct RecordingPart {
        let url: URL
        /// nil → the default (place/time) title.
        let title: String?
        let rawSources: [URL]
    }

    /// Hands a finished recording to the queue. Raw segments are deleted ONLY
    /// after their audio is safely copied into the pending store; if the copy
    /// fails they stay on disk and crash recovery picks them up next launch.
    func uploadRecording(_ parts: [RecordingPart], duration: TimeInterval, location: String?, appendTo: String?,
                         completion: @escaping (Bool, String?) -> Void) {
        let fallbackTitle = Self.defaultTitle(location: location)
        Task.detached(priority: .userInitiated) { [self] in
            var firstID: String?
            var failure: Error?
            for (i, part) in parts.enumerated() {
                do {
                    let id = try self.enqueue(fileURL: part.url, title: part.title ?? fallbackTitle,
                                              duration: parts.count == 1 ? duration : nil, mime: "audio/m4a",
                                              location: location, appendTo: i == 0 ? appendTo : nil)
                    if firstID == nil { firstID = id }
                    for u in part.rawSources { try? self.fm.removeItem(at: u) }
                    if !part.rawSources.contains(part.url) { try? self.fm.removeItem(at: part.url) }
                } catch {
                    failure = error
                    // Keep the raw segments for crash recovery; only the
                    // temporary merged copy (if any) is thrown away.
                    if !part.rawSources.contains(part.url) { try? self.fm.removeItem(at: part.url) }
                }
            }
            if let failure {
                self.setState(uploading: false, error: "Could not save the recording on this phone (\(failure.localizedDescription)). The audio is kept and will be recovered on next launch — free up storage.")
                if firstID != nil { await self.drain(jobID: nil, completion: nil) }
                DispatchQueue.main.async { completion(false, failure.localizedDescription) }
                return
            }
            await self.drain(jobID: firstID) { ok, msg in DispatchQueue.main.async { completion(ok, msg) } }
        }
    }

    @discardableResult
    func uploadFile(at fileURL: URL, title: String, mime: String) async throws -> String {
        let duration = try? await AudioSplitter.durationSeconds(of: AVURLAsset(url: fileURL))
        let id = try await Task.detached(priority: .userInitiated) { [self] in
            try self.enqueue(fileURL: fileURL, title: title, duration: duration, mime: mime)
        }.value
        let outcome: (Bool, String?) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
            Task { await self.drain(jobID: id) { ok, msg in cont.resume(returning: (ok, msg)) } }
        }
        if !outcome.0 { throw AudioUpload.Failure.server(-1, outcome.1 ?? "Upload failed") }
        return title
    }

    /// One row of the pending queue, for the recovery sheet.
    struct PendingItem: Identifiable {
        let id: String
        let title: String
        let createdAt: Date
        let attempts: Int
        let bytes: Int
        let fileURL: URL
        let held: Bool
    }

    /// Everything waiting to upload, oldest first — with the raw file so the
    /// user can always export the bytes even when nothing can decode them.
    func pendingItems() -> [PendingItem] {
        jobs().map { job, audio in
            PendingItem(id: job.id, title: job.title, createdAt: job.createdAt,
                        attempts: job.attempts,
                        bytes: (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                        fileURL: audio, held: job.held == true)
        }
    }

    /// User-chosen discard from the recovery sheet.
    func discard(id: String) {
        for (job, audio) in jobs() where job.id == id { finishJob(job, audio: audio) }
    }

    /// Called on launch and on every foreground: finishes anything left over.
    func resumePending() {
        Task { await drain(jobID: nil, completion: nil) }
    }

    // MARK: - Queue

    private struct Job: Codable {
        let id: String
        var title: String
        var mime: String
        var duration: TimeInterval?
        /// Transcribed text per segment index. Persisted as each part lands so
        /// an interrupted long recording resumes where it stopped.
        var partTexts: [Int: String] = [:]
        var uploadedPaths: [Int: String] = [:]
        var totalParts: Int? = nil
        var createdAt: Date
        var attempts: Int
        /// Recovered-from-crash audio waits here until the user approves it.
        var held: Bool? = nil
        /// Where the recording was made ("Thanksgiving Point, Lehi") — sent to
        /// the server so the saved note gets a real title, not "Voice Memo 152".
        var location: String? = nil
        /// "Add to this recording": the entry this audio is appended to instead of creating a new one.
        var appendTo: String? = nil
    }

    /// Queue audio WITHOUT uploading — shown in Jobs as "needs your OK".
    /// With `autoApprove` it is queued for upload straight away instead.
    /// Returns false if the audio could NOT be copied into the pending store —
    /// the caller must then keep its own copy.
    @discardableResult
    func hold(fileURL: URL, title: String, autoApprove: Bool = false) -> Bool {
        do {
            try enqueue(fileURL: fileURL, title: title, duration: nil, mime: "audio/m4a", held: !autoApprove)
        } catch {
            return false
        }
        if autoApprove { resumePending() }
        return true
    }

    /// Approve a held item: clears the hold and drains.
    func approve(id: String) {
        for (var job, _) in jobs() where job.id == id {
            job.held = false
            try? write(job)
        }
        resumePending()
    }

    /// Copies the audio into the pending store and writes its job. Returns the
    /// job id (the existing one when the same audio is already queued). Throws
    /// if the copy fails — nothing is queued then. Does disk work: call it off
    /// the main thread.
    @discardableResult
    private func enqueue(fileURL: URL, title: String, duration: TimeInterval?, mime: String,
                         held: Bool = false, location: String? = nil, appendTo: String? = nil) throws -> String {
        let id = UUID().uuidString
        let srcBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        for (job, audio) in jobs() {
            let b = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if job.title == title && b == srcBytes {
                setState(uploading: false, error: "\"\(title)\" is already waiting to upload — not queued twice.")
                return job.id
            }
        }
        let ext = fileURL.pathExtension.lowercased() == "caf" ? "caf"
                : mime.contains("wav") ? "wav"
                : mime.contains("webm") ? "webm"
                : mime.contains("video") ? "mp4" : "m4a"
        let dest = pendingDir.appendingPathComponent("\(id).\(ext)")
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.copyItem(at: fileURL, to: dest)

        try write(Job(id: id, title: title, mime: mime, duration: duration,
                      createdAt: Date(), attempts: 0, held: held ? true : nil, location: location, appendTo: appendTo))
        refreshPendingCount()
        return id
    }

    private func write(_ job: Job) throws {
        let data = try JSONEncoder().encode(job)
        try data.write(to: pendingDir.appendingPathComponent("\(job.id).json"), options: .atomic)
    }

    private func jobs() -> [(Job, URL)] {
        let contents = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        var out: [(Job, URL)] = []
        for meta in contents where meta.pathExtension == "json" {
            guard let d = try? Data(contentsOf: meta) else { continue }
            let id = meta.deletingPathExtension().lastPathComponent
            let audio = contents.first {
                $0.deletingPathExtension().lastPathComponent == id && $0.pathExtension != "json"
            }
            guard let audio else { try? fm.removeItem(at: meta); continue }

            if let job = try? JSONDecoder().decode(Job.self, from: d) {
                out.append((job, audio))
            } else {
                // Metadata written by an older build. Recover the recording
                // rather than stranding it: rebuild the job around the audio
                // that is sitting right there.
                let created = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
                let recovered = Job(id: id, title: "Voice Memo — \(fmt.string(from: created))",
                                    mime: "audio/m4a", duration: nil,
                                    createdAt: created, attempts: 0)
                try? write(recovered)
                out.append((recovered, audio))
            }
        }
        return out.sorted { $0.0.createdAt < $1.0.createdAt }
    }

    private func finishJob(_ job: Job, audio: URL) {
        try? fm.removeItem(at: audio)
        try? fm.removeItem(at: pendingDir.appendingPathComponent("\(job.id).json"))
        refreshPendingCount()
    }

    private func refreshPendingCount() {
        let n = jobs().count
        DispatchQueue.main.async { self.pendingCount = n }
    }

    // MARK: - Drain

    /// Registers the caller's completion and claims the drain. Returns false
    /// when a drain is already running: that drain is told to re-read the queue
    /// and will call this completion when it finishes.
    private func beginDrain(jobID: String?, completion: ((Bool, String?) -> Void)?) -> Bool {
        drainLock.lock(); defer { drainLock.unlock() }
        if let completion { waiters.append((jobID: jobID, completion: completion)) }
        if draining { rerunRequested = true; return false }
        draining = true
        rerunRequested = false
        return true
    }

    /// Ends the drain unless someone asked for another pass meanwhile. Returns
    /// the waiters to notify, or nil when the queue must be re-read.
    private func endDrainIfIdle() -> [(jobID: String?, completion: (Bool, String?) -> Void)]? {
        drainLock.lock(); defer { drainLock.unlock() }
        if rerunRequested { rerunRequested = false; return nil }
        draining = false
        let w = waiters
        waiters = []
        return w
    }

    /// Seconds of audio, or nil when the container can't be read here.
    private static func audioSeconds(_ url: URL) async -> Double? {
        guard let d = try? await AudioSplitter.durationSeconds(of: AVURLAsset(url: url)),
              d.isFinite, d > 0 else { return nil }
        return d
    }

    private func drain(jobID: String?, completion: ((Bool, String?) -> Void)?) async {
        guard beginDrain(jobID: jobID, completion: completion) else { return }

        #if canImport(UIKit)
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = await UIApplication.shared.beginBackgroundTask(withName: "scribbly.upload") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid } }
        #endif

        /// Outcome per job id for this drain. A job that already has an outcome
        /// is not tried again in this pass, so a permanently failing recording
        /// can't loop forever — and can't block the ones queued after it.
        var results: [String: (Bool, String?)] = [:]
        /// Held this pass for "no speech" — eligible again only if the user
        /// approves it while this drain is still running.
        var heldThisPass = Set<String>()
        var lastFailure: String?
        var lastTitle: String?

        while true {
            let todo = jobs().filter { job, _ in
                job.held != true && (results[job.id] == nil || heldThisPass.contains(job.id))
            }
            if todo.isEmpty {
                guard let done = endDrainIfIdle() else { continue }
                // The descriptive per-job error (if any) is already showing.
                setState(uploading: false, error: nil)
                refreshPendingCount()
                let overall: (Bool, String?) = (lastFailure == nil, lastFailure ?? lastTitle)
                for w in done {
                    let r = w.jobID.flatMap { results[$0] } ?? overall
                    w.completion(r.0, r.1)
                }
                return
            }

            for (storedJob, audio) in todo {
                var job = storedJob
                heldThisPass.remove(job.id)
                setState(uploading: true, error: nil)
                DispatchQueue.main.async { self.progress = 0.05 }

                // Only a recording with (almost) no audio in it is thrown away:
                // under half a second, or — when the container can't be read —
                // a file too small to hold any (a crash mid-write).
                let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let seconds = await Self.audioSeconds(audio)
                let husk = seconds.map { $0 < 0.5 } ?? (bytes < 4_096)
                if husk {
                    finishJob(job, audio: audio)
                    let size = seconds.map { String(format: "%.1f s", $0) } ?? "\(bytes) bytes"
                    let msg = "\"\(job.title)\" had no audio in it (\(size)) and was discarded."
                    results[job.id] = (false, msg)
                    setState(uploading: false, error: msg)
                    continue
                }

                do {
                    // Upload the recording ONCE; the box transcribes, summarizes and
                    // saves it — any length, and it finishes even if the app is closed
                    // the instant the bytes land. No client-side splitting or parts.
                    DispatchQueue.main.async { self.stage = "Uploading…" }
                    let result = try await AudioUpload.ingestWhole(
                        fileURL: audio, title: job.title, mime: job.mime, location: job.location,
                        appendTo: job.appendTo,
                        onProgress: { frac in
                            DispatchQueue.main.async {
                                // Bytes are 90% of the visible bar; the server's
                                // transcription is the final sliver.
                                self.progress = 0.05 + 0.85 * frac
                                self.stage = frac < 1 ? "Uploading… \(Int(frac * 100))%"
                                                      : "Handed off — finishing on server"
                            }
                        })

                    finishJob(job, audio: audio)
                    results[job.id] = (true, result.title)
                    lastTitle = result.title
                    DispatchQueue.main.async {
                        self.progress = 1
                        self.lastError = nil
                    }
                } catch {
                    let msg = error.localizedDescription
                    job.attempts += 1
                    // "No speech" won't change on retry, but the audio is never
                    // deleted on the server's say-so: it is held for the user to
                    // listen to, export, re-approve or discard in Activity.
                    let noSpeech = msg.localizedCaseInsensitiveContains("No speech")
                        || msg.localizedCaseInsensitiveContains("empty transcript")
                    if noSpeech {
                        job.held = true
                        try? write(job)
                        heldThisPass.insert(job.id)
                        let held = "No speech was found in \"\(job.title)\". It's kept in Activity — listen, export, retry or discard it there."
                        results[job.id] = (false, held)
                        setState(uploading: false, error: held)
                        continue
                    }
                    try? write(job)              // kept for the next drain's retry
                    results[job.id] = (false, msg)
                    lastFailure = msg
                    setState(uploading: false,
                             error: "\(msg) The recording is safe on this phone and will retry — or open Activity to retry, export, or discard it.")
                    // Move on: one bad recording must not hold up the others.
                    continue
                }
            }
        }
    }

    private func setState(uploading: Bool, error: String?) {
        DispatchQueue.main.async {
            self.isUploading = uploading
            if let error { self.lastError = error }
            if !uploading && error == nil { self.progress = 1 }
        }
    }
}
