import Foundation
import Speech

/// Primary engine. Uses Apple's on-device recognizer.
///
/// Chosen as primary because it ships with the OS: no model download, no
/// bundle weight, no cold-start penalty, and it is the fastest of the two on
/// Apple silicon. Its weaknesses are proper nouns, domain jargon, and long
/// files — which is exactly what the Whisper fallback is for.
///
/// NOT VERIFIED: iOS 26 introduced SpeechAnalyzer/SpeechTranscriber as a
/// replacement for SFSpeechRecognizer. This implementation uses the stable
/// SFSpeechRecognizer path, which still works on 26. Migrating is an
/// optimization, not a prerequisite.
public struct AppleTranscriber: Transcribing {
    public let name = "apple"
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func isAvailable() async -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        guard recognizer.isAvailable else { return false }
        guard recognizer.supportsOnDeviceRecognition else { return false }
        return await Self.requestAuthorization()
    }

    public func transcribe(fileURL: URL) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.engineUnavailable(name)
        }
        guard await Self.requestAuthorization() else {
            throw TranscriptionError.permissionDenied
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        // Never let audio leave the device.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let started = Date()
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result)
                }
            }
        }

        let segments = result.bestTranscription.segments.map { seg in
            TranscriptSegment(
                text: seg.substring,
                start: seg.timestamp,
                end: seg.timestamp + seg.duration,
                confidence: seg.confidence,
                speakerID: nil
            )
        }

        let transcript = Transcript(
            segments: segments,
            engine: name,
            duration: segments.last?.end ?? Date().timeIntervalSince(started),
            producedAt: Date()
        )

        if transcript.isEmpty { throw TranscriptionError.emptyResult(name) }
        return transcript
    }

    private static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
