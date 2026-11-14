import AppIntents

/// Siri on Apple Watch: "Hey Siri, start Scribbly" / "Hey Siri, stop Scribbly".
/// Raise to Speak works too. The watch mic only records while the app is open,
/// so these bring the Scribbly watch app forward and start or stop it there.

struct StartWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Scribbly Recording"
    static let description = IntentDescription("Opens Scribbly on your watch and starts recording.")
    static let openAppWhenRun: Bool = true
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        let r = WatchRecorder.shared
        if !r.isRecording { r.start() }
        return .result()
    }
}

struct StopWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Scribbly Recording"
    static let description = IntentDescription("Stops the watch recording and sends it to your library.")
    static let openAppWhenRun: Bool = true
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        let r = WatchRecorder.shared
        if r.isRecording { r.finish() }
        return .result()
    }
}

struct ToggleWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Scribbly Recording"
    static let description = IntentDescription("Starts recording on your watch, or stops and saves if one is running.")
    static let openAppWhenRun: Bool = true
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        let r = WatchRecorder.shared
        r.isRecording ? r.finish() : r.start()
        return .result()
    }
}

struct ScribblyWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWatchRecordingIntent(),
                    phrases: ["Hey \(.applicationName)", "Start \(.applicationName)",
                              "Start a \(.applicationName) recording", "Record with \(.applicationName)",
                              "\(.applicationName) record"],
                    shortTitle: "Start Recording", systemImageName: "waveform")
        AppShortcut(intent: StopWatchRecordingIntent(),
                    phrases: ["Stop \(.applicationName)", "Stop \(.applicationName) recording",
                              "Finish \(.applicationName) recording", "Save \(.applicationName) recording",
                              "\(.applicationName) stop"],
                    shortTitle: "Stop & Save", systemImageName: "stop.circle")
        AppShortcut(intent: ToggleWatchRecordingIntent(),
                    phrases: ["Toggle \(.applicationName)", "\(.applicationName) start or stop"],
                    shortTitle: "Start or Stop", systemImageName: "record.circle")
    }
}
