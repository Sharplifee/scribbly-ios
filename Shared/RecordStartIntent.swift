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


/// Stops the current recording and saves it (same as the ✓ on the Live Activity).
/// "Hey Siri, stop Scribbly" — works locked or unlocked, without opening the app.
/// A LiveActivityIntent so it always runs in the APP's process (where the
/// recorder lives) — from a widget or Control Center too, not just Siri. As a
/// plain AppIntent it ran inside the widget extension and did nothing there.
@available(iOS 18.0, *)
struct StopScribblyRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Scribbly Recording"
    static let description = IntentDescription("Stops the recording in progress and saves it to your library.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard RecordingControl.isRecording?() == true || RecordingControl.isActive?() == true else {
            return .result(dialog: "Scribbly isn't recording.")
        }
        RecordingControl.handler?("finish")
        return .result(dialog: "Saved.")
    }
}

/// One phrase that does both: starts a recording when idle, stops and saves it
/// when one is running. Best fit for an iPhone Vocal Shortcut ("Scribbly").
@available(iOS 18.0, *)
struct ToggleScribblyRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Scribbly Recording"
    static let description = IntentDescription("Starts recording if Scribbly is idle; stops and saves if it's recording.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        if RecordingControl.isRecording?() == true || RecordingControl.isActive?() == true {
            RecordingControl.handler?("finish")
            return .result()
        }
        RecordingControl.handler?("start")
        for _ in 0..<40 {
            if RecordingControl.isRecording?() == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .result()
    }
}


/// Pause / resume from a widget or Control Center (runs in the app's process).
@available(iOS 18.0, *)
struct PauseScribblyRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Scribbly Recording"
    static let description = IntentDescription("Pauses the recording in progress, or resumes it if paused.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        if RecordingControl.isActive?() == true { RecordingControl.handler?("toggle") }
        return .result()
    }
}
