import AppIntents
import Foundation

/// Runs when the Control Center button is tapped. It opens Scribbly; the app
/// then auto-starts recording. Without an App Group we can't share a flag file
/// cross-process, so the app treats "opened via the control/URL" as the arm
/// signal (see RootView.onOpenURL and the openAppWhenRun path).
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Scribbly Recording"
    static var description = IntentDescription("Opens Scribbly and begins recording immediately.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        // Hand off to the app via its URL scheme so RootView.onOpenURL arms recording.
        return .result(opensIntent: OpenURLIntent(URL(string: "scribbly://record")!))
    }
}
