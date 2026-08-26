import AppIntents
import Foundation

/// Runs when the Control Center button is tapped (iOS 18+). Opens Scribbly via
/// its URL scheme; RootView.onOpenURL then auto-starts recording. No App Group
/// needed — the URL scheme is the cross-process handoff.
@available(iOS 18.0, *)
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Scribbly Recording"
    static var description = IntentDescription("Opens Scribbly and begins recording immediately.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "scribbly://record")!))
    }
}
