import Foundation
import AppIntents

// Every way to drive a Scribbly recording without touching the app — Siri,
// Shortcuts, Vocal Shortcuts, the Action button, Back Tap, Control Center,
// Home/Lock Screen widgets, StandBy, CarPlay, Focus automations. Each intent
// runs in Scribbly's own process (AudioRecordingIntent / LiveActivityIntent),
// even when the app was closed, and answers with a spoken/visible result so
// a trigger never fails silently.

@MainActor
private enum Run {
    static func log(_ name: String, _ outcome: String) {
        RecordingControl.log?("intent.\(name)", outcome)
    }
    /// Starts recording and waits (up to 4 s) for it to be live.
    static func start() async -> String {
        guard let handler = RecordingControl.handler else {
            log("start", "no_handler"); return "Open Scribbly once to finish setting up, then try again."
        }
        if RecordingControl.micAllowed?() == false {
            log("start", "mic_denied"); return "Scribbly needs microphone access — open Scribbly to allow it."
        }
        if RecordingControl.isActive?() == true {
            log("start", "already"); return "Scribbly is already recording."
        }
        handler("start")
        for _ in 0..<40 {
            if RecordingControl.isRecording?() == true { log("start", "ok"); return "Recording." }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("start", "timeout")
        return "Scribbly couldn't start recording — open the app and try again."
    }
    static func stop() -> String {
        guard RecordingControl.isActive?() == true, let handler = RecordingControl.handler else {
            log("stop", "idle"); return "Scribbly isn't recording."
        }
        handler("finish")
        log("stop", "ok")
        return "Saved to your Scribbly library."
    }
    static func pause() -> String {
        guard RecordingControl.isActive?() == true, let handler = RecordingControl.handler else {
            log("pause", "idle"); return "Scribbly isn't recording."
        }
        let wasRecording = RecordingControl.isRecording?() == true
        handler("toggle")
        log("pause", wasRecording ? "paused" : "resumed")
        return wasRecording ? "Paused." : "Resumed."
    }
}

/// Start recording right away, even locked.
@available(iOS 18.0, *)
struct StartScribblyRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Scribbly Recording"
    static let description = IntentDescription("Starts recording right away, even from the Lock Screen.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await Run.start()))
    }
}

/// Stop the recording in progress and save it.
@available(iOS 18.0, *)
struct StopScribblyRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Scribbly Recording"
    static let description = IntentDescription("Stops the recording in progress and saves it to your library.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Run.stop()))
    }
}

/// One trigger for both: starts when idle, stops & saves when recording.
@available(iOS 18.0, *)
struct ToggleScribblyRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Scribbly Recording"
    static let description = IntentDescription("Starts recording if Scribbly is idle; stops and saves if it's recording.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        if RecordingControl.isActive?() == true {
            return .result(dialog: IntentDialog(stringLiteral: Run.stop()))
        }
        return .result(dialog: IntentDialog(stringLiteral: await Run.start()))
    }
}

/// Pause, or resume if paused.
@available(iOS 18.0, *)
struct PauseScribblyRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Scribbly Recording"
    static let description = IntentDescription("Pauses the recording in progress, or resumes it if paused.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Run.pause()))
    }
}
