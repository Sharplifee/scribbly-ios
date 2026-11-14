import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import AppIntents

/// Live Activity shown in the Dynamic Island / Lock Screen / CarPlay while
/// Scribbly is recording. Shared by the app (starts/updates/ends it) and the
/// widget extension (draws it).
@available(iOS 16.1, *)
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock moment the timer reads 00:00 (now - elapsed), so the
        /// system ticks the timer without the app.
        var timerStart: Date
        var paused: Bool
        /// Frozen elapsed seconds, shown while paused.
        var pausedElapsed: Int
        var appending: Bool
        /// Recent input levels 0...1 (oldest first) for the waveform.
        var levels: [Double] = []
    }
    var title: String
}

/// Bridge from the Live Activity buttons (which run in the APP's process) to
/// the recorder. The app sets the handler at launch; the widget never runs it.
enum RecordingControl {
    @MainActor static var handler: ((String) -> Void)?
    @MainActor static var isRecording: (() -> Bool)?
    /// Recording or paused — anything a stop command should finish.
    @MainActor static var isActive: (() -> Bool)?
    /// Microphone permission (false = denied / not yet asked).
    @MainActor static var micAllowed: (() -> Bool)?
    /// Writes to the app's permanent event log (set by the app).
    @MainActor static var log: ((String, String) -> Void)?
}

@available(iOS 17.0, *)
struct RecordingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription("The pause button on Scribbly's Live Activity.")
    /// Only for the Live Activity's own button — hidden from Shortcuts/Siri
    /// (the full "Pause or Resume Scribbly Recording" is the one to use there).
    static let isDiscoverable: Bool = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        RecordingControl.handler?("toggle")
        return .result()
    }
}

@available(iOS 17.0, *)
struct RecordingFinishIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish Recording"
    static let description = IntentDescription("The ✓ button on Scribbly's Live Activity.")
    /// Live Activity button only — "Stop Scribbly Recording" is the Shortcuts one.
    static let isDiscoverable: Bool = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        RecordingControl.handler?("finish")
        return .result()
    }
}
#endif
