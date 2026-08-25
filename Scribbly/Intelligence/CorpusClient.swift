import Foundation
import os

/// Writes finished captures into Supabase.
///
/// Two tables: one row per capture, many rows per commitment. Commitments are
/// separate so they can be queried, filtered by due date, and marked done
/// without dragging the whole transcript along.
public struct CorpusClient {

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "corpus")
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(projectRef: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = URL(string: "https://\(projectRef).supabase.co/rest/v1")!
        self.apiKey = apiKey
        self.session = session
    }

    public struct CaptureRecord: Encodable {
        public let id: UUID
        public let captured_at: Date
        public let source: String          // "ambient" | "call" | "imported"
        public let duration_seconds: Double
        public let engine: String
        public let alternate_engine: String?
        public let engine_agreement: Float?
        public let summary: String
        public let transcript: String
        public let speaker_ids: [String]
        public let discarded_reason: String?
    }

    public struct CommitmentRecord: Encodable {
        public let id: UUID
        public let capture_id: UUID
        public let kind: String
        public let direction: String
        public let statement: String
        public let source_quote: String
        public let speaker_id: String?
        public let counterparty: String?
        public let due_date: Date?
        public let due_date_phrase: String?
        public let offset_seconds: Double
        public let confidence: Float
        public let status: String          // "open" | "done" | "dismissed"
    }

    public func write(
        capture: CaptureRecord,
        commitments: [Commitment]
    ) async throws {
        try await post(path: "ambient_captures", body: [capture])

        guard !commitments.isEmpty else { return }
        let rows = commitments.map { c in
            CommitmentRecord(
                id: c.id,
                capture_id: capture.id,
                kind: c.kind.rawValue,
                direction: c.direction.rawValue,
                statement: c.statement,
                source_quote: c.sourceQuote,
                speaker_id: c.speakerID,
                counterparty: c.counterparty,
                due_date: c.dueDate,
                due_date_phrase: c.dueDatePhrase,
                offset_seconds: c.timestamp,
                confidence: c.confidence,
                status: "open"
            )
        }
        try await post(path: "ambient_commitments", body: rows)
        log.info("wrote capture + \(rows.count, privacy: .public) commitments")
    }

    private func post<T: Encodable>(path: String, body: [T]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? ""
            log.error("supabase \(status, privacy: .public) on \(path, privacy: .public): \(detail, privacy: .public)")
            throw CorpusError.write(status: status, body: detail)
        }
    }
}

public enum CorpusError: Error, LocalizedError {
    case write(status: Int, body: String)
    public var errorDescription: String? {
        switch self {
        case .write(let s, let b): return "corpus write failed \(s): \(b.prefix(200))"
        }
    }
}
