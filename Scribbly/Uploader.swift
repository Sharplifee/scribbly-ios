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
    @Published var lastResultTitle: String?
    @Published var lastError: String?
    @Published var pendingCount: Int = 0

    /// Kept so the AppDelegate's background-session hook still compiles.
    var backgroundCompletionHandler: (() -> Void)?

    private let fm = FileManager.default
    private var draining = false

    private var pendingDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    // MARK: - Public entry points

    func upload(fileURL: URL, duration: TimeInterval, completion: @escaping (Bool, String?) -> Void) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        upload(fileURL: fileURL, title: "Voice Memo — \(fmt.string(from: Date()))",
               duration: duration, completion: completion)
    }

    /// Same as upload(fileURL:duration:) but with a caller-chosen title —
    /// used by crash recovery so rescued audio is labelled honestly.
    func upload(fileURL: URL, title: String, duration: TimeInterval?, completion: @escaping (Bool, String?) -> Void) {

        do {
            try enqueue(fileURL: fileURL, title: title, duration: duration ?? 0, mime: "audio/m4a")
        } catch {
            setState(uploading: false, error: "Could not save the recording locally: \(error.localizedDescription)")
            completion(false, error.localizedDescription)
            return
        }
        Task { await drain(completion: completion) }
    }

    @discardableResult
    func uploadFile(at fileURL: URL, title: String, mime: String) async throws -> String {
        let duration = try? await AudioSplitter.durationSeconds(of: AVURLAsset(url: fileURL))
        try enqueue(fileURL: fileURL, title: title, duration: duration, mime: mime)
        var failure: String?
        await drain { ok, msg in if !ok { failure = msg ?? "Upload failed" } }
        if let failure { throw AudioUpload.Failure.server(-1, failure) }
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
    }

    /// Everything waiting to upload, oldest first — with the raw file so the
    /// user can always export the bytes even when nothing can decode them.
    func pendingItems() -> [PendingItem] {
        jobs().map { job, audio in
            PendingItem(id: job.id, title: job.title, createdAt: job.createdAt,
                        attempts: job.attempts,
                        bytes: (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                        fileURL: audio)
        }
    }

    /// User-chosen discard from the recovery sheet.
    func discard(id: String) {
        for (job, audio) in jobs() where job.id == id { finishJob(job, audio: audio) }
    }

    /// Called on launch and on every foreground: finishes anything left over.
    func resumePending() {
        Task { await drain(completion: nil) }
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
    }

    private func enqueue(fileURL: URL, title: String, duration: TimeInterval?, mime: String) throws {
        let id = UUID().uuidString
        let ext = fileURL.pathExtension.lowercased() == "caf" ? "caf"
                : mime.contains("wav") ? "wav"
                : mime.contains("webm") ? "webm"
                : mime.contains("video") ? "mp4" : "m4a"
        let dest = pendingDir.appendingPathComponent("\(id).\(ext)")
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.copyItem(at: fileURL, to: dest)

        try write(Job(id: id, title: title, mime: mime, duration: duration,
                      createdAt: Date(), attempts: 0))
        refreshPendingCount()
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

    private func drain(completion: ((Bool, String?) -> Void)?) async {
        if draining { completion?(true, nil); return }
        draining = true
        defer { draining = false }

        #if canImport(UIKit)
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = await UIApplication.shared.beginBackgroundTask(withName: "scribbly.upload") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid } }
        #endif

        var lastOK = true
        var lastMessage: String?

        for (storedJob, audio) in jobs() {
            var job = storedJob
            setState(uploading: true, error: nil)
            DispatchQueue.main.async { self.progress = 0.05 }

            var segments: [AudioSplitter.Segment] = []
            do {
                do {
                    segments = try await AudioSplitter.segments(for: audio)
                } catch {
                    // AVFoundation can't parse the file ("Cannot Open"): a crash
                    // mid-write or an interrupted copy left it damaged. A husk
                    // under 25 KB holds no speech — discard it instead of
                    // wedging the retry loop forever. Anything bigger goes up
                    // whole; the server transcribes it fine without splitting.
                    let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if bytes < 25_000 {
                        finishJob(job, audio: audio)
                        lastOK = true
                        lastMessage = nil
                        setState(uploading: false,
                                 error: "One damaged recording (\(bytes) bytes — no audio) was discarded.")
                        continue
                    }
                    segments = [AudioSplitter.Segment(url: audio, index: 0, isTemporary: false)]
                }
                job.totalParts = segments.count
                try? write(job)

                for segment in segments {
                    // Skip work already done in an earlier attempt.
                    if job.partTexts[segment.index]?.isEmpty == false { continue }

                    let path = job.uploadedPaths[segment.index]
                        ?? "voice/\(job.id)/part-\(String(format: "%03d", segment.index)).\(segment.url.pathExtension)"
                    if job.uploadedPaths[segment.index] == nil {
                        _ = try await AudioUpload.putToStorage(fileURL: segment.url, path: path,
                                                               mime: segment.isTemporary ? "audio/m4a" : job.mime)
                        job.uploadedPaths[segment.index] = path
                        try? write(job)
                    }

                    let text = try await AudioUpload.transcribePart(
                        storagePath: path, mime: segment.isTemporary ? "audio/m4a" : job.mime)
                    job.partTexts[segment.index] = text
                    try? write(job)          // durable: never transcribe the same minute twice

                    let done = Double(job.partTexts.count)
                    let total = Double(max(segments.count, 1))
                    DispatchQueue.main.async { self.progress = 0.05 + 0.85 * (done / total) }
                }

                let transcript = job.partTexts.keys.sorted()
                    .compactMap { job.partTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                let result = try await AudioUpload.finalize(
                    transcript: transcript, title: job.title,
                    audioPath: job.uploadedPaths[0], duration: job.duration)

                try await AudioUpload.verify(entryID: result.entryID)

                AudioSplitter.cleanUp(segments)
                finishJob(job, audio: audio)
                lastOK = true
                lastMessage = result.title
                DispatchQueue.main.async {
                    self.progress = 1
                    self.lastResultTitle = result.title
                    self.lastError = nil
                }
            } catch {
                AudioSplitter.cleanUp(segments)
                // A format/transcoding rejection is PERMANENT: the file itself is
                // damaged (crash mid-write), so no retry will ever succeed. Discard
                // it honestly instead of wedging the queue on a corpse.
                let msg = error.localizedDescription
                let permanent = ["Transcoding failed", "may be unsupported", "unsupported",
                                 "could not decode", "Invalid file", "corrupt"]
                    .contains { msg.localizedCaseInsensitiveContains($0) }
                if permanent {
                    let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
                    finishJob(job, audio: audio)
                    lastOK = true
                    lastMessage = nil
                    setState(uploading: false,
                             error: "One recording (\(mb) MB) was damaged in a crash and can't be recovered — discarded.")
                    continue
                }
                job.attempts += 1
                try? write(job)              // partial transcripts survive for the retry
                lastOK = false
                lastMessage = msg
                setState(uploading: false,
                         error: "\(msg) — kept on device, will retry.")
                break
            }
        }

        setState(uploading: false, error: lastOK ? nil : lastMessage)
        refreshPendingCount()
        completion?(lastOK, lastMessage)
    }

    private func setState(uploading: Bool, error: String?) {
        DispatchQueue.main.async {
            self.isUploading = uploading
            if let error { self.lastError = error }
            if !uploading && error == nil { self.progress = 1 }
        }
    }
}
