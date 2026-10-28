import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import PhotosUI
import CoreTransferable
import Vision

/// Picks an audio OR video file and sends it through the same
/// transcribe-and-summarize path a live recording uses.
///
/// Video (mp4/mov/m4v): Whisper and AssemblyAI both accept a video container
/// and transcribe its audio track server-side, so for files under the 25MB
/// Whisper ceiling we upload the container as-is. For larger video we strip
/// the audio to m4a first with AVAssetExportSession — otherwise a 300MB video
/// would blow past every size limit for no reason, since only the audio matters.
///
/// Uploads go to Supabase Storage first and only the object path is posted to
/// /api/voice, so nothing here is bound by Vercel's 4.5 MB body limit.
@MainActor
final class FileIngestModel: ObservableObject {
    static let shared = FileIngestModel()
    @Published var picking = false
    /// Photos library picker (videos). Photos never appear in the Files picker.
    @Published var pickingPhotos = false
    @Published var working = false
    @Published var status: String?
    @Published var lastError: String?

    private let whisperCeilingBytes = 24 * 1024 * 1024

    /// Several files from the Files picker, one after another.
    func handleFiles(_ urls: [URL]) async {
        EventLog.shared.log("files.picked", ["count": urls.count, "names": urls.prefix(50).map { $0.lastPathComponent }])
        for (i, url) in urls.enumerated() {
            if urls.count > 1 { batchLabel = "\(i + 1) of \(urls.count)" }
            let ext = url.pathExtension.lowercased()
            if let t = UTType(filenameExtension: ext), t.conforms(to: .image) {
                let scoped = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                if let data { await handleImage(data, name: url.deletingPathExtension().lastPathComponent) }
            } else {
                await handle(url)
            }
        }
        batchLabel = nil
    }

    /// Several picks from Photos (videos and/or photos), one after another.
    func handlePhotos(_ items: [PhotosPickerItem]) async {
        EventLog.shared.log("photos.picked", ["count": items.count])
        for (i, item) in items.enumerated() {
            if items.count > 1 { batchLabel = "\(i + 1) of \(items.count)" }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }) {
                await handlePhoto(item)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                await handleImage(data, name: "Photo")
            } else {
                lastError = "Photos didn't hand over one of the items. If it's in iCloud, open it in Photos once, then try again."
            }
        }
        batchLabel = nil
    }

    /// "2 of 7" while a multi-pick is working through its items.
    @Published var batchLabel: String?

    /// A photo or screenshot: read its text on the phone, save it as an entry.
    func handleImage(_ data: Data, name: String) async {
        working = true; lastError = nil; status = "Reading text from the image…"
        defer { working = false }
        let text = await Self.recognizeText(data)
        guard !text.isEmpty else {
            lastError = "No readable text in that image, so nothing was saved."
            status = nil
            return
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? name
        let title = String(firstLine.prefix(80))
        do {
            try await CorpusAPI.saveEntry(id: "image_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 100...999))",
                                          title: title, type: "Image", tags: "image",
                                          summary: "", transcript: text)
            status = "Saved — the image's text is in your Library."
            EventLog.shared.log("image.saved", status: "ok", ["chars": text.count])
        } catch {
            lastError = "Couldn't save the image's text: \(error.localizedDescription)"
            status = nil
        }
    }

    private nonisolated static func recognizeText(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            guard let img = UIImage(data: data), let cg = img.cgImage else { return "" }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    func handle(_ url: URL, fromPhotos: Bool = false) async {
        working = true; lastError = nil; status = "Preparing…"
        defer { working = false }

        // Security-scoped access for Files-provided URLs.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            // What it is (read from the ORIGINAL file, before any audio extraction)
            // and where it was submitted from — both shown on the saved entry.
            let kind = await Self.kind(of: url, fromPhotos: fromPhotos)
            async let place = Self.currentPlace()
            let (local, mime, name, temporary) = try await prepare(url)
            let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            status = "Uploading \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))…"
            // Photos hands over "photos-<uuid>" — show what it is until the server titles it.
            _ = try await Uploader.shared.uploadFile(at: local, title: fromPhotos ? kind : name, mime: mime,
                                                     kind: kind, location: await place)
            if temporary { try? FileManager.default.removeItem(at: local) }
            status = "Saved — transcript is in your Library."
            EventLog.shared.log("file.uploaded", status: "ok", ["kind": kind, "bytes": size])
        } catch {
            lastError = error.localizedDescription
            EventLog.shared.error("file.failed", error.localizedDescription, ["name": url.lastPathComponent])
            status = nil
        }
    }

    /// Returns (fileURL, mimeType, title, isTemporaryCopy) ready to upload.
    private func prepare(_ url: URL) async throws -> (URL, String, String, Bool) {
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        // Any video container (mp4, mov, m4v, hevc, 3gp, avi, mkv, webm…), by UTType not a hand list.
        let type = UTType(filenameExtension: ext)
        let isVideo = type?.conforms(to: .movie) == true || ["mkv", "webm", "avi", "3gp", "3g2", "mts", "m2ts", "ts", "wmv", "flv"].contains(ext)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Audio, or small video: copy into our sandbox FIRST. The picker URL is
        // security-scoped — the scope is gone by the time a background upload
        // task reads it, which sends zero bytes and comes back "no speech".
        // A local copy made while the scope is held can be read forever.
        if !isVideo || size <= whisperCeilingBytes {
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick-\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
            try? FileManager.default.removeItem(at: local)
            try await Self.copyOffMain(url, to: local)
            let copied = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard copied > 0 else {
                throw NSError(domain: "Ingest", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't read that file from Files (0 bytes) — try saving it locally (On My iPhone) first."])
            }
            return (local, mime(for: ext), base, true)
        }

        // Large video: extract audio to m4a to avoid uploading the video stream.
        status = "Extracting audio from video…"
        if let m4a = try? await extractAudio(from: url) {
            return (m4a, "audio/m4a", base, true)
        }
        // A container AVFoundation can't read (mkv, avi, wmv…): send it whole —
        // the server's ffmpeg pulls the audio out.
        status = "Preparing video…"
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
        try await Self.copyOffMain(url, to: local)
        return (local, mime(for: ext), base, true)
    }

    /// Multi-hundred-MB copies must not freeze the UI: this class is
    /// @MainActor, so the copy itself runs on a background task.
    private nonisolated static func copyOffMain(_ src: URL, to dst: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: src, to: dst)
        }.value
    }

    /// A video chosen from the Photos library: copy it out, then the same path as Files.
    func handlePhoto(_ item: PhotosPickerItem) async {
        working = true; lastError = nil; status = "Getting the video from Photos…"
        CrashReporter.shared.add("photos picked")
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw NSError(domain: "Ingest", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Photos didn't hand over that video. If it's in iCloud, open it in Photos once so it downloads, then try again."])
            }
            working = false
            await handle(movie.url, fromPhotos: true)
            try? FileManager.default.removeItem(at: movie.url)
        } catch {
            working = false
            lastError = error.localizedDescription
            status = nil
        }
    }

    /// "Screen recording" / "Video" for Photos picks; the file type ("MP4",
    /// "MOV", "M4A", "MP3"…) for files. Screen recordings carry no camera
    /// make/model and match the screen's aspect ratio; camera video has both.
    nonisolated static func kind(of url: URL, fromPhotos: Bool) async -> String {
        let ext = url.pathExtension.lowercased()
        guard fromPhotos else { return ext.isEmpty ? "File" : ext.uppercased() }
        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.metadata)) ?? []
        var hasCamera = false
        for item in meta {
            let key = (item.identifier?.rawValue ?? "").lowercased()
            if key.contains("make") || key.contains("model") || key.contains("camera") { hasCamera = true; break }
        }
        if !hasCamera, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            let screen = await MainActor.run { UIScreen.main.nativeBounds.size }
            let a = max(size.width, size.height) / max(1, min(size.width, size.height))
            let b = max(screen.width, screen.height) / max(1, min(screen.width, screen.height))
            if abs(a - b) < 0.03 { return "Screen recording" }
        }
        return "Video"
    }

    /// Where the upload is being submitted from (nil if location is off / slow).
    static func currentPlace() async -> String? {
        await withCheckedContinuation { cont in
            PlaceTagger.shared.tag { cont.resume(returning: $0) }
        }
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

    private func mime(for ext: String) -> String {
        if let m = UTType(filenameExtension: ext)?.preferredMIMEType, !m.isEmpty { return m }
        switch ext {
        case "mkv": return "video/x-matroska"
        case "opus", "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/m4a"
        case "webm": return "audio/webm"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "audio/m4a"
        }
    }

    /// Accepted content types for the picker: any audio or video the server can
    /// normalize. The box runs ffmpeg on whatever arrives, so we accept broadly
    /// (all audio + all movie/video UTTypes) rather than a hand-picked list.
    static var contentTypes: [UTType] {
        var t: [UTType] = [.image, .audiovisualContent, .audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie, .mpeg4Movie,
                           .quickTimeMovie, .video, .mpeg2Video, .avi, .mpeg, .appleProtectedMPEG4Audio,
                           .appleProtectedMPEG4Video]
        // Containers iOS doesn't classify as audio/video still get picked by extension;
        // the server's ffmpeg pulls the audio out of whatever arrives.
        for ext in ["mkv", "mka", "webm", "flac", "ogg", "oga", "ogv", "opus", "spx", "amr", "awb", "caf",
                    "3gp", "3g2", "wma", "wmv", "asf", "aac", "m4a", "m4b", "m4r", "m4v", "aif", "aifc",
                    "ac3", "eac3", "mp2", "mpga", "mpg", "mpeg", "vob", "ts", "mts", "m2ts", "flv", "f4v",
                    "divx", "dv", "mxf", "rm", "rmvb", "ape", "wv", "dsf", "alac"] {
            if let u = UTType(filenameExtension: ext), !t.contains(u) { t.append(u) }
        }
        return t
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

/// A Photos video, copied into our sandbox so it can be read after the picker closes.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("photos-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
