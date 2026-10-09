import AppIntents

/// Siri / Shortcuts / Action button phrases. Say any of these to Siri, or pick
/// "Start Scribbly Recording" in Shortcuts, the Action button, or a Voice
/// Control custom command.
@available(iOS 18.0, *)
struct ScribblyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartScribblyRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)",
                "New \(.applicationName) note",
                "\(.applicationName) record"
            ],
            shortTitle: "Start Recording",
            systemImageName: "waveform"
        )
    }
}
