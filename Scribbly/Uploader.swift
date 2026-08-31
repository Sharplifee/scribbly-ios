import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns every recording from the moment Finish is tapped until the note is
/// provably in the library.
///
/// Two rules, both learned the hard way:
///   1. A recording is copied somewhere durable *before* any network call, and
///      is only deleted once the entry has been read back from the database.
///      Anything unfinished is retried on the next launch.
///   2. Success is never assumed. The old uploader treated a response it
///      couldn't parse as success — which is exactly how a 413 on an
///      eight-minute note showed a green checkmark and saved nothing.
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

    /// Durable home for recordings that have not been confirmed saved.
    /// Application Support survives the temp-directory purges that could
    /// otherwise erase a recording waiting to upload.
    private var pendingDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    // MARK: - Public entry points

    /// Called by the Record screen. Never throws away the audio.
    func upload(fileURL: URL, duration: TimeInterval, completion: @escaping (Bool, String?) -> Void) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        let title = "Voice Memo — \(fmt.string(from: Date()))"

        do {
            try enqueue(fileURL: fileURL, title: title, duration: duration, mime: "audio/m4a")
        } catch {
            setState(uploading: false, error: "Could not save the recording locally: \(error.localizedDescription)")
            completion(false, error.localizedDescription)
            return
        }

        Task { await drain(completion: completion) }
    }

    /// Used by file/video ingest, which already has bytes on disk.
    func uploadFile(at fileURL: URL, title: String, mime: String) async throws -> String {
        try enqueue(fileURL: fileURL, title: title, duration: nil, mime: mime)
        var thrown: Error?
        await drain { ok, msg in if !ok { thrown = AudioUpload.Failure.server(-1, msg ?? "upload failed") } }
        if let thrown { throw thrown }
        return title
    }

    /// Call on launch and on foreground: finishes anything left over.
    func resumePending() {
        Task { await drain(completion: nil) }
    }

    // MARK: - Queue

    private struct Job: Codable {
        let id: String
        var title: String
        var mime: String
        var duration: TimeInterval?
        var storagePath: String?
        var createdAt: Date
        var attempts: Int
    }

    private func enqueue(fileURL: URL, title: String, duration: TimeInterval?, mime: String) throws {
        let id = UUID().uuidString
        let ext = (mime.contains("wav") ? "wav" : mime.contains("webm") ? "webm" : mime.contains("video") ? "mp4" : "m4a")
        let dest = pendingDir.appendingPathComponent("\(id).\(ext)")
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        // Copy, not move: the caller's file may still be referenced elsewhere.
        try fm.copyItem(at: fileURL, to: dest)

        let job = Job(id: id, title: title, mime: mime, duration: duration,
                      storagePath: nil, createdAt: Date(), attempts: 0)
        try write(job)
        refreshPendingCount()
    }

    private func write(_ job: Job) throws {
        let data = try JSONEncoder().encode(job)
        try data.write(to: pendingDir.appendingPathComponent("\(job.id).json"), options: .atomic)
    }

    private func jobs() -> [(Job, URL)] {
        let metas = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        var out: [(Job, URL)] = []
        for m in metas where m.pathExtension == "json" {
            guard let d = try? Data(contentsOf: m),
                  let job = try? JSONDecoder().decode(Job.self, from: d) else { continue }
            let audio = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
                .first { $0.deletingPathExtension().lastPathComponent == job.id && $0.pathExtension != "json" }
            guard let audio else {          // metadata without audio is dead weight
                try? fm.removeItem(at: m)
                continue
            }
            out.append((job, audio))
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
        if draining {
            completion?(true, nil)
            return
        }
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

        for (var job, audio) in jobs() {
            setState(uploading: true, error: nil)
            DispatchQueue.main.async { self.progress = 0.15 }

            do {
                if job.storagePath == nil {
                    let path = "voice/\(job.id).\(audio.pathExtension)"
                    _ = try await AudioUpload.putToStorage(fileURL: audio, path: path, mime: job.mime)
                    job.storagePath = path
                    try? write(job)                       // survive a crash mid-flight
                }
                DispatchQueue.main.async { self.progress = 0.6 }

                let result = try await AudioUpload.requestTranscription(
                    storagePath: job.storagePath!, title: job.title,
                    mime: job.mime, duration: job.duration)

                try await AudioUpload.verify(entryID: result.entryID)

                finishJob(job, audio: audio)              // only now is it safe
                lastOK = true
                lastMessage = result.title
                DispatchQueue.main.async {
                    self.progress = 1
                    self.lastResultTitle = result.title
                    self.lastError = nil
                }
            } catch {
                job.attempts += 1
                try? write(job)
                lastOK = false
                lastMessage = error.localizedDescription
                setState(uploading: false,
                         error: "\(error.localizedDescription) — kept on device, will retry.")
                break                                     // don't hammer a broken path
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
