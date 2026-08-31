import Foundation
import AVFoundation

/// Cuts long audio into upload-sized segments.
///
/// Nothing about this is exposed to the user. A ninety-minute recording and a
/// ninety-second one follow the same code path; the long one just produces more
/// segments. Segments are bounded by *time*, and are re-encoded to AAC, so their
/// size is predictable no matter what bitrate the source used — a 320 kbps
/// import and a 64 kbps recording both land well inside the storage bucket's
/// per-object limit and Whisper's 25 MB ceiling.
enum AudioSplitter {

    /// Twelve minutes of AAC is roughly 6-12 MB. Comfortably inside every limit
    /// while keeping the number of round trips small.
    static let segmentSeconds: TimeInterval = 12 * 60

    /// Files at or under this go up untouched — no re-encode, no quality loss,
    /// no wasted battery.
    static let singlePartMaxBytes = 20 * 1024 * 1024

    struct Segment {
        let url: URL
        let index: Int
        let isTemporary: Bool
    }

    /// Returns the pieces to upload. One element means "send it as-is".
    static func segments(for url: URL) async throws -> [Segment] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let asset = AVURLAsset(url: url)
        let duration = try await durationSeconds(of: asset)

        if size <= singlePartMaxBytes && duration <= segmentSeconds * 1.5 {
            return [Segment(url: url, index: 0, isTemporary: false)]
        }

        let count = max(1, Int(ceil(duration / segmentSeconds)))
        var out: [Segment] = []
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for i in 0..<count {
            let start = Double(i) * segmentSeconds
            let length = min(segmentSeconds, duration - start)
            if length <= 0.5 { break }
            let piece = dir.appendingPathComponent(String(format: "part-%03d.m4a", i))
            try await export(asset: asset, from: start, length: length, to: piece)
            out.append(Segment(url: piece, index: i, isTemporary: true))
        }
        return out
    }

    static func cleanUp(_ segments: [Segment]) {
        for s in segments where s.isTemporary {
            try? FileManager.default.removeItem(at: s.url)
            // Remove the split directory once it empties out.
            let dir = s.url.deletingLastPathComponent()
            if let left = try? FileManager.default.contentsOfDirectory(atPath: dir.path), left.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    static func durationSeconds(of asset: AVAsset) async throws -> TimeInterval {
        if #available(iOS 16.0, *) {
            return try await CMTimeGetSeconds(asset.load(.duration))
        }
        return CMTimeGetSeconds(asset.duration)
    }

    private static func export(asset: AVAsset, from start: TimeInterval,
                               length: TimeInterval, to out: URL) async throws {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SplitError.exportUnavailable
        }
        export.outputURL = out
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600))
        await export.export()
        guard export.status == .completed else {
            throw SplitError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }
    }

    enum SplitError: LocalizedError {
        case exportUnavailable
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .exportUnavailable: return "Could not prepare the audio for upload."
            case .exportFailed(let m): return "Could not split the audio: \(m)"
            }
        }
    }
}
