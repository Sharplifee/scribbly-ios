import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Picks an audio OR video file and sends it through the same
/// transcribe-and-summarize path a live recording uses.
///
/// Video (mp4/mov/m4v): Whisper and AssemblyAI both accept a video container
/// and transcribe its audio track server-side, so for files under the 25MB
/// Whisper ceiling we upload the container as-is. For larger video we strip
/// the audio to m4a first with AVAssetExportSession — otherwise a 300MB video
/// would blow past every size limit for no reason, since only the audio matters.
@MainActor
final class FileIngestModel: ObservableObject {
    @Published var picking = false
    @Published var working = false
    @Published var status: String?
    @Published var lastError: String?

    private let whisperCeilingBytes = 24 * 1024 * 1024

    func handle(_ url: URL) async {
        working = true; lastError = nil; status = "Preparing…"
        defer { working = false }

        // Security-scoped access for Files-provided URLs.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let (data, mime, name) = try await prepare(url)
            status = "Uploading \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))…"
            try await upload(data: data, mime: mime, title: name)
            status = "Done — transcribing on the server. It'll appear in Library."
        } catch {
            lastError = error.localizedDescription
            status = nil
        }
    }

    /// Returns (bytes, mimeType, title) ready to POST.
    private func prepare(_ url: URL) async throws -> (Data, String, String) {
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        let isVideo = ["mp4", "mov", "m4v", "webm"].contains(ext)

        // Audio, or small video: send the container directly.
        let raw = try Data(contentsOf: url)
        if !isVideo || raw.count <= whisperCeilingBytes {
            return (raw, mime(for: ext), base)
        }

        // Large video: extract audio to m4a to avoid uploading the video stream.
        status = "Extracting audio from video…"
        let m4a = try await extractAudio(from: url)
        let audio = try Data(contentsOf: m4a)
        try? FileManager.default.removeItem(at: m4a)
        return (audio, "audio/m4a", base)
    }

    private func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IngestError.exportFailed
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString).m4a")
        export.outputURL = out
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw IngestError.exportFailed
        }
        return out
    }

    private func upload(data: Data, mime: String, title: String) async throws {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/voice")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let body: [String: Any] = [
            "action": "process-audio",
            "audioBase64": data.base64EncodedString(),
            "mimeType": mime,
            "title": title
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: respData, encoding: .utf8) ?? ""
            throw IngestError.server(code, msg)
        }
    }

    private func mime(for ext: String) -> String {
        switch ext {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/m4a"
        case "webm": return "audio/webm"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "audio/m4a"
        }
    }

    /// Accepted content types for the picker: all audio + common video.
    static var contentTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .movie, .mpeg4Movie, .quickTimeMovie, .video]
    }
}

enum IngestError: LocalizedError {
    case exportFailed
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .exportFailed: return "Could not extract audio from that video."
        case .server(let c, let m): return "Server \(c): \(m.prefix(160))"
        }
    }
}
