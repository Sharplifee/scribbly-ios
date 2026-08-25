import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Fallback and verification engine. WhisperKit, running whisper on CoreML.
///
/// Slower and heavier than Apple's recognizer — the model is a real download
/// and a real chunk of memory — but materially better on names, jargon,
/// crosstalk, and noisy rooms. It is the reason a bad Apple result is
/// recoverable instead of lost.
///
/// Add via SPM: https://github.com/argmaxinc/WhisperKit
/// Without the package present this compiles to a permanently-unavailable
/// engine, so the dual-engine coordinator degrades to Apple-only rather than
/// failing to build.
public actor WhisperTranscriber: Transcribing {
    public nonisolated let name = "whisper"

    private let modelVariant: String
    private var loaded = false

    #if canImport(WhisperKit)
    private var kit: WhisperKit?
    #endif

    public init(modelVariant: String = "openai_whisper-base.en") {
        self.modelVariant = modelVariant
    }

    public func isAvailable() async -> Bool {
        #if canImport(WhisperKit)
        if loaded { return true }
        do {
            try await load()
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(WhisperKit)
    private func load() async throws {
        guard !loaded else { return }
        let config = WhisperKitConfig(model: modelVariant, download: true)
        kit = try await WhisperKit(config)
        loaded = true
    }
    #endif

    public func transcribe(fileURL: URL) async throws -> Transcript {
        #if canImport(WhisperKit)
        try await load()
        guard let kit else { throw TranscriptionError.engineUnavailable(name) }

        let results = try await kit.transcribe(audioPath: fileURL.path)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.hasPrefix("[") else { continue }
                segments.append(
                    TranscriptSegment(
                        text: text,
                        start: TimeInterval(seg.start),
                        end: TimeInterval(seg.end),
                        // Whisper reports avg log-prob; map to a rough 0…1.
                        confidence: Self.normalize(logProb: seg.avgLogprob),
                        speakerID: nil
                    )
                )
            }
        }

        let transcript = Transcript(
            segments: segments,
            engine: name,
            duration: segments.last?.end ?? 0,
            producedAt: Date()
        )
        if transcript.isEmpty { throw TranscriptionError.emptyResult(name) }
        return transcript
        #else
        throw TranscriptionError.engineUnavailable(name)
        #endif
    }

    /// avgLogprob is roughly -1.0 (bad) … 0.0 (confident).
    private static func normalize(logProb: Float) -> Float {
        max(0, min(1, 1 + logProb))
    }
}
