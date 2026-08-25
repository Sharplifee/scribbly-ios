import Foundation
import os

/// Wires every layer together: audio in, commitments out.
///
///   ambient buffer ─┐
///   import inbox   ─┼→ transcribe (dual) → identify speakers → extract → corpus
///   twilio leg     ─┘
///
/// Every stage degrades instead of failing the whole run: no Whisper means
/// Apple-only, no embedding model means unlabeled speakers, no network means
/// the item stays queued.
public actor CapturePipeline {

    public struct Result {
        public let captureID: UUID
        public let summary: String
        public let commitments: [Commitment]
        public let questions: [SpeakerAssigner.Question]
        public let discarded: Bool
    }

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "pipeline")
    private let transcription: TranscriptionCoordinator
    private let assigner: SpeakerAssigner
    private let registry: SpeakerRegistry
    private let extractor: CommitmentExtractor
    private let corpus: CorpusClient?

    private var queue: [URL] = []
    private var processing = false

    public init(
        transcription: TranscriptionCoordinator,
        assigner: SpeakerAssigner,
        registry: SpeakerRegistry,
        extractor: CommitmentExtractor,
        corpus: CorpusClient?
    ) {
        self.transcription = transcription
        self.assigner = assigner
        self.registry = registry
        self.extractor = extractor
        self.corpus = corpus
    }

    public func enqueue(_ url: URL, source: String = "ambient") {
        queue.append(url)
        Task { await drain(source: source) }
    }

    private func drain(source: String) async {
        guard !processing else { return }
        processing = true
        defer { processing = false }

        while !queue.isEmpty {
            let url = queue.removeFirst()
            do {
                _ = try await process(url: url, source: source)
            } catch {
                log.error("pipeline failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Requeue once on transport failure; drop on parse failure.
                if error is URLError { queue.append(url) }
            }
        }
    }

    @discardableResult
    public func process(url: URL, source: String) async throws -> Result {
        let captureID = UUID()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let capturedAt = (attrs?[.creationDate] as? Date) ?? Date()

        // 1 — transcribe with redundancy
        let stt = try await transcription.transcribe(fileURL: url)
        log.info("transcribed via \(stt.primary.engine, privacy: .public): \(stt.reason, privacy: .public)")

        // 2 — label speakers
        let identified = await assigner.assign(transcript: stt.primary, audioURL: url)

        // 3 — extract commitments
        let names = await registry.nameMap()
        let extraction = try await extractor.extract(
            transcript: identified.transcript,
            capturedAt: capturedAt,
            knownSpeakers: names
        )

        if extraction.isDiscardable {
            log.info("discarded: \(extraction.discardReason ?? "", privacy: .public)")
            return Result(
                captureID: captureID,
                summary: extraction.summary,
                commitments: [],
                questions: [],
                discarded: true
            )
        }

        // 4 — persist
        if let corpus {
            let speakerIDs = Array(Set(identified.transcript.segments.compactMap(\.speakerID)))
            let record = CorpusClient.CaptureRecord(
                id: captureID,
                captured_at: capturedAt,
                source: source,
                duration_seconds: identified.transcript.duration,
                engine: stt.primary.engine,
                alternate_engine: stt.alternate?.engine,
                engine_agreement: stt.agreement,
                summary: extraction.summary,
                transcript: identified.transcript.text,
                speaker_ids: speakerIDs,
                discarded_reason: nil
            )
            try await corpus.write(capture: record, commitments: extraction.commitments)
        }

        return Result(
            captureID: captureID,
            summary: extraction.summary,
            commitments: extraction.commitments,
            questions: identified.questions,
            discarded: false
        )
    }
}
