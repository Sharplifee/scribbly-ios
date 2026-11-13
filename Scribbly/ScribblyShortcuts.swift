import AppIntents

/// Siri phrases (iPhone). Siri requires the app's name in every phrase.
/// For a phrase with NO "Hey Siri" (e.g. just "Scribbly"), set up an iPhone
/// Vocal Shortcut that runs "Start or Stop Scribbly Recording".
@available(iOS 18.0, *)
struct ScribblyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartScribblyRecordingIntent(),
            phrases: [
                "Hey \(.applicationName)",
                "Start \(.applicationName)",
                "Start a \(.applicationName) recording",
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)",
                "New \(.applicationName) note",
                "\(.applicationName) record"
            ],
            shortTitle: "Start Recording",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StopScribblyRecordingIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop \(.applicationName) recording",
                "Stop recording in \(.applicationName)",
                "Finish \(.applicationName) recording",
                "Save \(.applicationName) recording",
                "\(.applicationName) stop"
            ],
            shortTitle: "Stop & Save",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: ToggleScribblyRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "\(.applicationName) start or stop"
            ],
            shortTitle: "Start or Stop",
            systemImageName: "record.circle"
        )
    }
}
