import AppIntents
import SwiftUI
import WidgetKit

// Every recording action as its own control — Control Center, Lock Screen,
// the Action button, and (watchOS 26+) your Apple Watch's Control Center and
// complications, which list iPhone controls. Each one runs in place, no unlock
// and no opening the app; the intents run in Scribbly's own process.

/// Start a recording.
@available(iOS 18.0, *)
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.record") {
            ControlWidgetButton(action: StartScribblyRecordingIntent()) {
                Label("Record", image: "scribbly.mark")   // our own mark, not a stock mic
            }
            .tint(Sinky.copper)
        }
        .displayName("Scribbly Record")
        .description("Start a Scribbly recording instantly, even when locked.")
    }
}

/// Stop & save the recording in progress.
@available(iOS 18.0, *)
struct StopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.stop") {
            ControlWidgetButton(action: StopScribblyRecordingIntent()) {
                Label("Stop & Save", systemImage: "stop.circle.fill")
            }
            .tint(Sinky.copper)
        }
        .displayName("Scribbly Stop & Save")
        .description("Stops the recording in progress and saves it to your library.")
    }
}

/// One button: starts when idle, stops & saves when recording.
@available(iOS 18.0, *)
struct ToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.toggle") {
            ControlWidgetButton(action: ToggleScribblyRecordingIntent()) {
                Label("Start / Stop", systemImage: "record.circle")
            }
            .tint(Sinky.copper)
        }
        .displayName("Scribbly Start or Stop")
        .description("Tap to start recording; tap again to stop and save.")
    }
}

/// Pause / resume the recording in progress.
@available(iOS 18.0, *)
struct PauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.pause") {
            ControlWidgetButton(action: PauseScribblyRecordingIntent()) {
                Label("Pause / Resume", systemImage: "pause.circle")
            }
            .tint(Sinky.copper)
        }
        .displayName("Scribbly Pause / Resume")
        .description("Pauses the recording in progress, or resumes it.")
    }
}
