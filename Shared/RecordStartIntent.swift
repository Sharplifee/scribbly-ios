import Foundation
import AppIntents

/// Starts a Scribbly recording WITHOUT opening the app — from the Control
/// Center button, any widget (Home Screen, Lock Screen, StandBy, CarPlay), the
/// Action button, or Siri / "Hey Siri, start a Scribbly recording" — locked or
/// unlocked. AudioRecordingIntent runs in the app's process in the background;
/// the system requires a Live Activity while it records, which Scribbly shows
/// (Dynamic Island / Lock Screen) for the whole recording.
@available(iOS 18.0, *)
struct StartScribblyRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Scribbly Recording"
    static let description = IntentDescription("Starts recording right away, even from the Lock Screen.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        RecordingControl.handler?("start")
        // Hold the intent open until recording (and its Live Activity) is up,
        // so the system keeps us running through the hand-off.
        for _ in 0..<40 {
            if RecordingControl.isRecording?() == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .result()
    }
}

