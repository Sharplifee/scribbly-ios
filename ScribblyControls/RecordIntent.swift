import AppIntents
import Foundation

/// Fired by the Control Center button and the Home Screen widget.
/// iOS does not allow a third-party control to capture audio in place, so this
/// opens Scribbly and sets a flag the app reads on foreground to auto-start
/// recording. One tap → app opens already recording.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Scribbly Recording"
    static var description = IntentDescription("Opens Scribbly and begins recording immediately.")

    /// Bring the app to the foreground — required for mic capture.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // App group flag; RootView reads and clears it on becomeActive.
        let defaults = UserDefaults(suiteName: "group.com.connor.scribbly")
        defaults?.set(true, forKey: "arm_recording")
        defaults?.set(Date().timeIntervalSince1970, forKey: "arm_recording_at")
        return .result()
    }
}
