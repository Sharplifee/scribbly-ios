import Foundation

/// The unit of value this whole app exists to produce.
public struct Commitment: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        /// Someone said they would do something.
        case promise
        /// Something was agreed or settled.
        case decision
        /// A concrete task with an owner.
        case actionItem
        /// A date, time, or deadline that matters.
        case deadline
        /// A number that was quoted — price, quantity, rate.
        case figure
        /// Something to follow up on that isn't yet a commitment.
        case openQuestion
    }

    public enum Direction: String, Codable {
        /// You owe someone.
        case owed
        /// Someone owes you.
        case owing
        /// Neither — informational.
        case neutral
    }

    public let id: UUID
    public let kind: Kind
    public let direction: Direction
    /// One clean sentence, rewritten from the messy spoken original.
    public let statement: String
    /// The words actually said, verbatim from the transcript.
    public let sourceQuote: String
    /// Who said it — a speakerID from the identity layer, or nil.
    public let speakerID: String?
    /// Who it's about, if different from the speaker.
    public let counterparty: String?
    /// Resolved absolute date when the transcript implied one.
    public let dueDate: Date?
    /// The phrase that produced the date, e.g. "end of next week".
    public let dueDatePhrase: String?
    /// Offset into the recording where this was said.
    public let timestamp: TimeInterval
    /// 0…1 — how sure the extractor is this is a real commitment.
    public let confidence: Float

    public init(
        id: UUID = UUID(),
        kind: Kind,
        direction: Direction,
        statement: String,
        sourceQuote: String,
        speakerID: String? = nil,
        counterparty: String? = nil,
        dueDate: Date? = nil,
        dueDatePhrase: String? = nil,
        timestamp: TimeInterval,
        confidence: Float
    ) {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.statement = statement
        self.sourceQuote = sourceQuote
        self.speakerID = speakerID
        self.counterparty = counterparty
        self.dueDate = dueDate
        self.dueDatePhrase = dueDatePhrase
        self.timestamp = timestamp
        self.confidence = confidence
    }
}

public struct ExtractionResult: Codable {
    public let commitments: [Commitment]
    /// Two or three sentences. What this conversation was.
    public let summary: String
    /// Present when the model judged the audio to be not a real conversation.
    public let discardReason: String?

    public var isDiscardable: Bool { discardReason != nil }
}
