import Foundation
import os

/// Turns a transcript into commitments via Claude.
///
/// The prompt is the actual product here. Spoken commitments almost never
/// look like tasks — people say "yeah I'll get you that" and "let's do
/// Tuesday" and "I'll have Kayden swing by," and a naive summarizer throws
/// all of it away. The rules below exist because each one is a category of
/// thing that gets lost.
public struct CommitmentExtractor {

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "extract")
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func extract(
        transcript: Transcript,
        capturedAt: Date,
        knownSpeakers: [String: String] = [:],
        timeZone: TimeZone = TimeZone(identifier: "America/Denver") ?? .current
    ) async throws -> ExtractionResult {

        let prompt = Self.buildPrompt(
            transcript: transcript,
            capturedAt: capturedAt,
            knownSpeakers: knownSpeakers,
            timeZone: timeZone
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 90

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExtractionError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            log.error("anthropic \(http.statusCode, privacy: .public): \(detail, privacy: .public)")
            throw ExtractionError.api(status: http.statusCode, body: detail)
        }

        guard
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = envelope["content"] as? [[String: Any]]
        else {
            throw ExtractionError.malformedResponse
        }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        return try Self.decode(text, capturedAt: capturedAt, timeZone: timeZone)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You extract commitments from transcripts of real spoken conversations.

    Spoken commitments do not look like written tasks. People commit casually, \
    indirectly, and in fragments. Your job is to catch those, not to summarize.

    EXTRACT:
    - Promises, however casual. "I'll send that over" is a commitment. So is \
      "yeah I got you" and "leave it with me."
    - Commitments made ON someone's behalf. "I'll have him call you" creates an \
      obligation even though the speaker isn't doing the work.
    - Decisions that were settled, including ones settled by nobody objecting.
    - Dates and times, including vague ones. "Early next week", "after the \
      holiday", "end of month" are all dates.
    - Numbers that were quoted: prices, rates, quantities, headcounts.
    - Things left genuinely open that need a follow-up.

    DO NOT EXTRACT:
    - Hypotheticals. "We could maybe do X" is not a commitment.
    - Pleasantries, small talk, logistics of the call itself.
    - Anything you are inventing to fill out the list. An empty result is a \
      correct result.

    DIRECTION matters. Decide whether the obligation lands on the primary \
    speaker (owed), on someone else (owing), or nobody (neutral).

    CONFIDENCE matters. A clear explicit promise is 0.9+. An implied commitment \
    inferred from context is 0.5. Below 0.4, leave it out.

    If the transcript is not a real conversation — background TV, one-sided \
    noise, a few disconnected words, a podcast playing — set discardReason and \
    return no commitments. This runs on ambient audio; most of what you see \
    will be nothing, and saying so is the right answer.

    Respond with raw JSON only. No markdown fences, no preamble.
    """

    static func buildPrompt(
        transcript: Transcript,
        capturedAt: Date,
        knownSpeakers: [String: String],
        timeZone: TimeZone
    ) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"

        let speakerBlock = knownSpeakers.isEmpty
            ? "Speakers are unidentified."
            : knownSpeakers.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")

        let body = transcript.segments.map { seg in
            let stamp = String(format: "[%.1fs]", seg.start)
            let who = seg.speakerID.map { "\($0): " } ?? ""
            return "\(stamp) \(who)\(seg.text)"
        }.joined(separator: "\n")

        return """
        Captured: \(fmt.string(from: capturedAt)) (\(timeZone.identifier))
        Engine: \(transcript.engine)
        Duration: \(String(format: "%.0f", transcript.duration))s

        Speakers:
        \(speakerBlock)

        Transcript:
        \(body)

        Resolve every relative date against the capture time above. Output:

        {
          "summary": "two or three sentences",
          "discardReason": null,
          "commitments": [
            {
              "kind": "promise|decision|actionItem|deadline|figure|openQuestion",
              "direction": "owed|owing|neutral",
              "statement": "one clean sentence",
              "sourceQuote": "the words actually said",
              "speakerID": null,
              "counterparty": null,
              "dueDate": "2026-08-28",
              "dueDatePhrase": "end of next week",
              "timestamp": 42.5,
              "confidence": 0.85
            }
          ]
        }
        """
    }

    // MARK: - Decode

    static func decode(_ raw: String, capturedAt: Date, timeZone: TimeZone) throws -> ExtractionResult {
        // Models occasionally fence despite instructions. Strip defensively.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ExtractionError.malformedResponse }

        let summary = root["summary"] as? String ?? ""
        let discard = root["discardReason"] as? String

        let dateFmt = DateFormatter()
        dateFmt.timeZone = timeZone
        dateFmt.dateFormat = "yyyy-MM-dd"

        let items = (root["commitments"] as? [[String: Any]] ?? []).compactMap { dict -> Commitment? in
            guard
                let kindRaw = dict["kind"] as? String,
                let kind = Commitment.Kind(rawValue: kindRaw),
                let statement = dict["statement"] as? String,
                let quote = dict["sourceQuote"] as? String
            else { return nil }

            let confidence = Float(dict["confidence"] as? Double ?? 0)
            guard confidence >= 0.4 else { return nil }

            return Commitment(
                kind: kind,
                direction: Commitment.Direction(rawValue: dict["direction"] as? String ?? "neutral") ?? .neutral,
                statement: statement,
                sourceQuote: quote,
                speakerID: dict["speakerID"] as? String,
                counterparty: dict["counterparty"] as? String,
                dueDate: (dict["dueDate"] as? String).flatMap { dateFmt.date(from: $0) },
                dueDatePhrase: dict["dueDatePhrase"] as? String,
                timestamp: dict["timestamp"] as? Double ?? 0,
                confidence: confidence
            )
        }

        return ExtractionResult(commitments: items, summary: summary, discardReason: discard)
    }
}

public enum ExtractionError: Error, LocalizedError {
    case transport(String)
    case api(status: Int, body: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .transport(let m): return "extraction transport error: \(m)"
        case .api(let s, let b): return "Anthropic API \(s): \(b.prefix(300))"
        case .malformedResponse: return "extractor returned unparseable output"
        }
    }
}
