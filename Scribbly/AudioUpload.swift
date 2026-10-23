import Foundation
import ObjectiveC

/// The transport for every recording and audio file Scribbly sends: one file
/// streamed whole to the box, which transcribes, summarizes and saves it.
enum AudioUpload {

    struct Result {
        let entryID: String
        let title: String
        /// Set when the box accepted the upload as an async job (202 + jobId).
        var jobID: String? = nil
    }

    enum Failure: LocalizedError {
        case storage(Int, String)
        case server(Int, String)
        case noEntryID(String)
        case unverified(String)
        case emptyTranscript

        /// Plain-words cause. Strips JSON so a person never reads a raw server body.
        static func human(_ code: Int, _ body: String) -> String {
            var msg = body
            if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                msg = (o["error"] as? String) ?? (o["message"] as? String) ?? body
            }
            msg = msg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            switch code {
            case -1, 0:      return msg.isEmpty ? "no connection to the server." : String(msg.prefix(120)) + " (no connection)"
            case 500...599:  return "the server had a problem (HTTP \(code))." + (msg.isEmpty ? "" : " " + String(msg.prefix(100)))
            case 429:        return "the server is busy right now."
            default:         return (msg.isEmpty ? "HTTP \(code)." : String(msg.prefix(140)))
            }
        }

        var errorDescription: String? {
            switch self {
            case .storage(let c, let b): return "Upload failed: " + Failure.human(c, b)
            case .server(let c, let b):  return "Processing failed: " + Failure.human(c, b)
            case .noEntryID(let b):      return "Server did not confirm a saved note: \(b.prefix(140))"
            case .unverified(let id):    return "Note \(id) was not found in the library after saving."
            case .emptyTranscript:       return "No speech was found in that recording."
            }
        }
    }

    // MARK: - One-shot server pipeline

    /// Streams one audio file to the box, which transcribes + summarizes + saves
    /// it whole — no client-side splitting, no per-part calls, no length ceiling.
    /// Returns the saved entry. Progress reflects real bytes on the wire; once
    /// the upload completes the work continues on the server even if the app dies.
    static func ingestWhole(fileURL: URL, title: String?, mime: String = "audio/m4a", location: String? = nil,
                            appendTo: String? = nil,
                            onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        var req = URLRequest(url: URL(string: CorpusAPI.voiceIngestURL)!)
        req.httpMethod = "POST"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        // Tell the box the true container so it names the temp file correctly and
        // ffmpeg/Groq see the real format — otherwise everything looks like m4a.
        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty { req.setValue(ext, forHTTPHeaderField: "x-ext") }
        #if targetEnvironment(simulator)
        // QA rig / simulator: the server accepts and discards it, so test
        // recordings never land in the real library or Activity.
        req.setValue("1", forHTTPHeaderField: "x-qa")
        #endif
        if let title, let enc = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            req.setValue(enc, forHTTPHeaderField: "x-title")
        }
        if let location, let enc = location.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            req.setValue(enc, forHTTPHeaderField: "x-location")
        }
        if let a = appendTo, let enc = a.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            req.setValue(enc, forHTTPHeaderField: "x-append-to")
        }
        // The server transcribes before answering, so a long recording legitimately
        // holds the response open for minutes — no per-request idle cap here.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        let session = URLSession(configuration: cfg)

        let (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.uploadTask(with: req, fromFile: fileURL) { d, r, e in
                if let e { cont.resume(throwing: e) }
                else { cont.resume(returning: (d ?? Data(), r ?? URLResponse())) }
            }
            if let onProgress {
                let obs = task.progress.observe(\.fractionCompleted) { pr, _ in onProgress(pr.fractionCompleted) }
                objc_setAssociatedObject(task, "scribblyIngestObs", obs, .OBJC_ASSOCIATION_RETAIN)
            }
            task.resume()
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else { throw Failure.server(code, body) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // New async box: upload is accepted the instant bytes land (202) and the
        // box finishes transcription + save on its own clock. The phone is done.
        if let obj, obj["accepted"] as? Bool == true, let jobId = obj["jobId"] as? String {
            return Result(entryID: jobId, title: title ?? "Recording", jobID: jobId)
        }
        // Back-compat: an older synchronous box returns the finished entry inline.
        if let entry = obj?["entry"] as? [String: Any], let id = entry["id"] as? String {
            return Result(entryID: id, title: (entry["title"] as? String) ?? title ?? "Recording")
        }
        if let id = obj?["entryId"] as? String {
            return Result(entryID: id, title: title ?? "Recording")
        }
        throw Failure.server(code, (obj?["error"] as? String) ?? body)
    }
}
