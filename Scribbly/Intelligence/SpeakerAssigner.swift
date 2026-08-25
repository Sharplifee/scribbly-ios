import Foundation
import os

/// Walks a transcript, embeds each speaker turn, and labels it.
///
/// Turn boundaries come from gaps in the transcript timing — a pause longer
/// than `turnGap` is assumed to be a handoff. This is cheaper and more robust
/// than running a full diarization model, and it is good enough because the
/// embedding does the real discrimination.
public struct SpeakerAssigner {

    public struct Question: Identifiable {
        public let id = UUID()
        public let provisionalID: String
        public let sampleQuote: String
        public let candidates: [(id: String, name: String, similarity: Float)]
        public let embedding: [Float]
    }

    public struct Outcome {
        public let transcript: Transcript
        /// Voices the system could not resolve — surface these as
        /// "who was that?" prompts, one at a time, never in a batch.
        public let questions: [Question]
    }

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "assign")
    private let embedder: SpeakerEmbedder
    private let registry: SpeakerRegistry
    private let turnGap: TimeInterval

    public init(embedder: SpeakerEmbedder, registry: SpeakerRegistry, turnGap: TimeInterval = 0.8) {
        self.embedder = embedder
        self.registry = registry
        self.turnGap = turnGap
    }

    public func assign(transcript: Transcript, audioURL: URL) async -> Outcome {
        guard await embedder.isAvailable else {
            log.notice("embedder unavailable — transcript left unlabeled")
            return Outcome(transcript: transcript, questions: [])
        }

        let turns = Self.groupIntoTurns(transcript.segments, gap: turnGap)
        var labeled = transcript.segments
        var questions: [Question] = []
        var askedFor = Set<String>()

        for turn in turns {
            guard turn.end - turn.start >= SpeakerEmbedder.minimumTurnDuration else { continue }

            let embedding: [Float]
            do {
                let samples = try SpeakerEmbedder.samples(from: audioURL, start: turn.start, end: turn.end)
                embedding = try await embedder.embed(samples: samples)
            } catch {
                log.notice("turn embed failed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            let match = await registry.match(embedding)
            let assignedID: String

            switch match {
            case .known(let profile, let similarity):
                assignedID = profile.id
                // Only reinforce on strong hits — feeding marginal matches
                // back in is how a centroid drifts into uselessness.
                if similarity >= 0.82 {
                    await registry.reinforce(
                        id: profile.id, displayName: nil, embedding: embedding, confirmed: profile.confirmed
                    )
                }

            case .ambiguous(let candidates):
                let provisional = candidates.first?.0.id ?? "spk-unknown"
                assignedID = provisional
                if !askedFor.contains(provisional) {
                    askedFor.insert(provisional)
                    questions.append(Question(
                        provisionalID: provisional,
                        sampleQuote: turn.text,
                        candidates: candidates.map { ($0.0.id, $0.0.displayName, $0.1) },
                        embedding: embedding
                    ))
                }

            case .unknown(let provisionalID):
                assignedID = provisionalID
                await registry.reinforce(
                    id: provisionalID, displayName: nil, embedding: embedding, confirmed: false
                )
                if !askedFor.contains(provisionalID) {
                    askedFor.insert(provisionalID)
                    questions.append(Question(
                        provisionalID: provisionalID,
                        sampleQuote: turn.text,
                        candidates: [],
                        embedding: embedding
                    ))
                }
            }

            for idx in turn.indices { labeled[idx].speakerID = assignedID }
        }

        let out = Transcript(
            segments: labeled,
            engine: transcript.engine,
            duration: transcript.duration,
            producedAt: transcript.producedAt
        )
        return Outcome(transcript: out, questions: questions)
    }

    /// Answer a "who was that?" prompt.
    public func resolve(question: Question, asExisting id: String?, orNewNamed name: String?) async {
        if let id {
            await registry.reinforce(id: id, displayName: nil, embedding: question.embedding, confirmed: true)
            await registry.merge(question.provisionalID, into: id)
        } else if let name {
            await registry.reinforce(
                id: question.provisionalID, displayName: name, embedding: question.embedding, confirmed: true
            )
        }
    }

    struct Turn {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let indices: [Int]
    }

    static func groupIntoTurns(_ segments: [TranscriptSegment], gap: TimeInterval) -> [Turn] {
        var turns: [Turn] = []
        var currentIdx: [Int] = []
        var currentText: [String] = []
        var start: TimeInterval = 0
        var previousEnd: TimeInterval?

        for (i, seg) in segments.enumerated() {
            if let prev = previousEnd, seg.start - prev > gap, !currentIdx.isEmpty {
                turns.append(Turn(start: start, end: prev, text: currentText.joined(separator: " "), indices: currentIdx))
                currentIdx = []
                currentText = []
                start = seg.start
            }
            if currentIdx.isEmpty { start = seg.start }
            currentIdx.append(i)
            currentText.append(seg.text)
            previousEnd = seg.end
        }

        if !currentIdx.isEmpty, let end = previousEnd {
            turns.append(Turn(start: start, end: end, text: currentText.joined(separator: " "), indices: currentIdx))
        }
        return turns
    }
}
