import Foundation
import os

/// Runs both engines with an explicit policy instead of picking one.
///
/// Policy, in order:
///   1. Run Apple. It's free and fast.
///   2. If Apple fails, is empty, or comes back under the confidence floor,
///      run Whisper and take its result.
///   3. If BOTH produce a transcript and they disagree badly, keep Whisper
///      (better on the hard cases) but retain Apple's as an alternate so the
///      extraction layer can be re-run without re-transcribing.
///   4. If both fail, throw with both errors named — never a silent empty.
///
/// This is the redundancy you asked for: neither engine being broken,
/// unavailable, or wrong loses the recording.
public actor TranscriptionCoordinator {

    public struct Outcome: Codable {
        public let primary: Transcript
        public let alternate: Transcript?
        public let reason: String
        /// Word-level agreement between engines, 0…1. Nil when only one ran.
        public let agreement: Float?
    }

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "stt")
    private let apple: Transcribing
    private let whisper: Transcribing
    private let confidenceFloor: Float
    private let disagreementFloor: Float

    public init(
        apple: Transcribing = AppleTranscriber(),
        whisper: Transcribing = WhisperTranscriber(),
        confidenceFloor: Float = 0.62,
        disagreementFloor: Float = 0.75
    ) {
        self.apple = apple
        self.whisper = whisper
        self.confidenceFloor = confidenceFloor
        self.disagreementFloor = disagreementFloor
    }

    public func transcribe(fileURL: URL) async throws -> Outcome {
        var errors: [String: String] = [:]

        // --- Stage 1: Apple
        var appleResult: Transcript?
        do {
            appleResult = try await apple.transcribe(fileURL: fileURL)
        } catch {
            errors[apple.name] = error.localizedDescription
            log.notice("apple failed: \(error.localizedDescription, privacy: .public)")
        }

        let appleConfidence = appleResult?.meanConfidence ?? 0
        let appleGoodEnough = appleResult != nil
            && !(appleResult!.isEmpty)
            && appleConfidence >= confidenceFloor

        if appleGoodEnough {
            log.info("apple accepted, confidence=\(appleConfidence, privacy: .public)")
            return Outcome(
                primary: appleResult!,
                alternate: nil,
                reason: "apple above confidence floor",
                agreement: nil
            )
        }

        // --- Stage 2: Whisper
        var whisperResult: Transcript?
        if await whisper.isAvailable() {
            do {
                whisperResult = try await whisper.transcribe(fileURL: fileURL)
            } catch {
                errors[whisper.name] = error.localizedDescription
                log.error("whisper failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            errors[whisper.name] = "engine unavailable (package or model missing)"
        }

        // --- Stage 3: resolve
        switch (appleResult, whisperResult) {
        case let (a?, w?):
            let agree = Self.agreement(a.text, w.text)
            log.info("both engines ran, agreement=\(agree, privacy: .public)")
            return Outcome(
                primary: w,
                alternate: a,
                reason: agree < disagreementFloor
                    ? "engines disagreed; kept whisper"
                    : "apple below confidence floor; kept whisper",
                agreement: agree
            )

        case let (nil, w?):
            return Outcome(primary: w, alternate: nil, reason: "apple failed; whisper recovered", agreement: nil)

        case let (a?, nil):
            // Low confidence beats nothing. Flag it so downstream can discount.
            return Outcome(primary: a, alternate: nil, reason: "whisper unavailable; kept low-confidence apple", agreement: nil)

        case (nil, nil):
            throw TranscriptionError.allEnginesFailed(errors)
        }
    }

    /// Jaccard overlap on lowercased word sets. Crude on purpose — it only
    /// needs to answer "did these two engines hear the same conversation."
    static func agreement(_ a: String, _ b: String) -> Float {
        let setA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let setB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !setA.isEmpty || !setB.isEmpty else { return 1 }
        let union = setA.union(setB).count
        guard union > 0 else { return 1 }
        return Float(setA.intersection(setB).count) / Float(union)
    }
}
