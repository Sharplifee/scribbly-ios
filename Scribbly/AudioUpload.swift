import Foundation

/// The transport for every recording and audio file Scribbly sends.
///
/// Audio goes to Supabase Storage first and only its *path* is posted to
/// /api/voice. The old design sent the whole file base64-encoded inside the
/// JSON body, which Vercel rejects at 4.5 MB — about seven minutes of audio —
/// with a plain-text 413 the app then reported as success. Nothing about this
/// path has a size ceiling short of the bucket's 50 MB (~50 minutes).
enum AudioUpload {

    static let bucket = "voice-notes"

    struct Result {
        let entryID: String
        let title: String
        let storagePath: String
    }

    enum Failure: LocalizedError {
        case storage(Int, String)
        case server(Int, String)
        case noEntryID(String)
        case unverified(String)

        var errorDescription: String? {
            switch self {
            case .storage(let c, let b): return "Upload failed (HTTP \(c)): \(b.prefix(140))"
            case .server(let c, let b):  return "Transcription failed (HTTP \(c)): \(b.prefix(140))"
            case .noEntryID(let b):      return "Server did not confirm a saved note: \(b.prefix(140))"
            case .unverified(let id):    return "Note \(id) was not found in the library after saving."
            }
        }
    }

    /// PUTs the audio into the private bucket. Returns the object path.
    static func putToStorage(fileURL: URL, path: String, mime: String = "audio/m4a") async throws -> String {
        let url = URL(string: "\(CorpusAPI.supabaseURL)/storage/v1/object/\(bucket)/\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(CorpusAPI.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw Failure.storage(code, String(data: data, encoding: .utf8) ?? "")
        }
        return path
    }

    /// Asks the server to transcribe an object already in the bucket.
    /// Only returns once the server hands back a real entry id.
    static func requestTranscription(storagePath: String,
                                     title: String,
                                     mime: String = "audio/m4a",
                                     duration: TimeInterval?) async throws -> Result {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/voice")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        var body: [String: Any] = [
            "action": "process-audio",
            "storagePath": storagePath,
            "mimeType": mime,
            "title": title
        ]
        if let duration { body["durationSeconds"] = Int(duration) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else { throw Failure.server(code, text) }

        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entryID = (obj?["entryId"] as? String)
            ?? ((obj?["entry"] as? [String: Any])?["id"] as? String)
        guard let entryID else { throw Failure.noEntryID(text) }

        let savedTitle = ((obj?["entry"] as? [String: Any])?["title"] as? String) ?? title
        return Result(entryID: entryID, title: savedTitle, storagePath: storagePath)
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
