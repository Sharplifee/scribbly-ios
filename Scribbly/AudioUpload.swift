import Foundation

/// The transport for every recording and audio file Scribbly sends.
///
/// Audio goes to Supabase Storage first and only its *path* is posted to
/// /api/voice. The old design sent the whole file base64-encoded inside the
/// JSON body, which Vercel rejects at 4.5 MB — about seven minutes of audio —
/// with a plain-text 413 the app then reported as success.
///
/// Long recordings are split into segments (see AudioSplitter) and each one is
/// transcribed by its own short request, then stitched into a single note by
/// `finalize`. There is no length limit and nothing to decide: a two-hour
/// recording is just more segments.
enum AudioUpload {

    static let bucket = "voice-notes"

    struct Result {
        let entryID: String
        let title: String
    }

    enum Failure: LocalizedError {
        case storage(Int, String)
        case server(Int, String)
        case noEntryID(String)
        case unverified(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .storage(let c, let b): return "Upload failed (HTTP \(c)): \(b.prefix(140))"
            case .server(let c, let b):  return "Transcription failed (HTTP \(c)): \(b.prefix(140))"
            case .noEntryID(let b):      return "Server did not confirm a saved note: \(b.prefix(140))"
            case .unverified(let id):    return "Note \(id) was not found in the library after saving."
            case .emptyTranscript:       return "No speech was found in that recording."
            }
        }
    }

    // MARK: - Storage

    /// Session tuned for cellular reality: 30s of silence on the wire fails the
    /// attempt (instead of a 10-minute frozen bar), the whole transfer gets 5
    /// minutes, and iOS waits for connectivity rather than erroring instantly.
    private static let uploadSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// Uploads one file into the private bucket with live byte progress and
    /// three attempts. Returns the object path.
    static func putToStorage(fileURL: URL, path: String, mime: String = "audio/m4a",
                             onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let url = URL(string: "\(CorpusAPI.supabaseURL)/storage/v1/object/\(bucket)/\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(CorpusAPI.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")

        var lastError: Error = Failure.storage(-1, "upload never started")
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000) }
            do {
                let (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                    let task = uploadSession.uploadTask(with: req, fromFile: fileURL) { d, r, e in
                        if let e { cont.resume(throwing: e) }
                        else { cont.resume(returning: (d ?? Data(), r ?? URLResponse())) }
                    }
                    var obs: NSKeyValueObservation?
                    if let onProgress {
                        obs = task.progress.observe(\.fractionCompleted) { pr, _ in onProgress(pr.fractionCompleted) }
                    }
                    task.resume()
                    // Keep the observation alive for the task's lifetime.
                    if obs != nil { objc_setAssociatedObject(task, "scribblyProgressObs", obs, .OBJC_ASSOCIATION_RETAIN) }
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(code) else {
                    throw Failure.storage(code, String(data: data, encoding: .utf8) ?? "")
                }
                return path
            } catch {
                lastError = error
                // 4xx server verdicts won't change on retry — only retry transport/5xx.
                if case Failure.storage(let c, _) = error, (400..<500).contains(c) { throw error }
            }
        }
        throw lastError
    }

    // MARK: - Server calls

    private static func post(_ body: [String: Any], timeout: TimeInterval = 300) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/voice")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else { throw Failure.server(code, text) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A 2xx we can't parse is not a success. This exact assumption is
            // what hid the 413 that lost an eight-minute note.
            throw Failure.server(code, text)
        }
        return obj
    }

    /// Transcribes one segment. Short by construction, so it never runs into
    /// the function time limit however long the whole recording is.
    static func transcribePart(storagePath: String, mime: String = "audio/m4a") async throws -> String {
        let obj = try await post(["action": "transcribe-part", "storagePath": storagePath, "mimeType": mime])
        return (obj["text"] as? String) ?? ""
    }

    /// Summarizes the stitched transcript and saves the note.
    static func finalize(transcript: String, title: String,
                         audioPath: String?, duration: TimeInterval?) async throws -> Result {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyTranscript
        }
        var body: [String: Any] = ["action": "finalize", "transcript": transcript, "title": title]
        if let audioPath { body["audioPath"] = audioPath }
        if let duration { body["durationSeconds"] = Int(duration) }
        let obj = try await post(body)

        let entryID = (obj["entryId"] as? String) ?? ((obj["entry"] as? [String: Any])?["id"] as? String)
        guard let entryID else { throw Failure.noEntryID(String(describing: obj)) }
        let savedTitle = ((obj["entry"] as? [String: Any])?["title"] as? String) ?? title
        return Result(entryID: entryID, title: savedTitle)
    }

    /// Independent proof the row exists. A response body is a claim; this is
    /// the check that lets us delete the local copy.
    static func verify(entryID: String) async throws {
        for attempt in 0..<3 {
            if let entry = try? await CorpusAPI.entry(id: entryID), entry.id == entryID { return }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        throw Failure.unverified(entryID)
    }
}
