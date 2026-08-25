import Foundation

/// One transcript segment with timing, so downstream layers can map an
/// extracted commitment back to the exact moment it was said.
public struct TranscriptSegment: Codable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// 0…1. Nil when the engine does not report confidence.
    public let confidence: Float?
    /// Filled in later by the identity layer. Nil until then.
    public var speakerID: String?
}

public struct Transcript: Codable, Equatable {
    public let segments: [TranscriptSegment]
    public let engine: String
    public let duration: TimeInterval
    public let producedAt: Date

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Mean confidence across segments that reported one.
    public var meanConfidence: Float? {
        let scored = segments.compactMap(\.confidence)
        guard !scored.isEmpty else { return nil }
        return scored.reduce(0, +) / Float(scored.count)
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public protocol Transcribing: Sendable {
    var name: String { get }
    /// Whether this engine can run right now (model present, permission granted).
    func isAvailable() async -> Bool
    func transcribe(fileURL: URL) async throws -> Transcript
}

public enum TranscriptionError: Error, LocalizedError {
    case engineUnavailable(String)
    case allEnginesFailed([String: String])
    case emptyResult(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let n): return "\(n) unavailable"
        case .allEnginesFailed(let map):
            let detail = map.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return "all transcription engines failed — \(detail)"
        case .emptyResult(let n): return "\(n) returned empty transcript"
        case .permissionDenied: return "speech recognition permission denied"
        }
    }
}
