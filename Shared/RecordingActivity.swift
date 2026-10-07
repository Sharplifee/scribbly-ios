import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Live Activity shown in the Dynamic Island / Lock Screen while Scribbly is
/// recording. Shared by the app (starts/updates/ends it) and the widget
/// extension (draws it).
@available(iOS 16.1, *)
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock moment the timer reads 00:00 (now - elapsed). Lets the
        /// system tick the timer without the app running.
        var timerStart: Date
        var paused: Bool
        /// Frozen elapsed seconds, shown while paused.
        var pausedElapsed: Int
        var appending: Bool
    }
    var title: String
}
#endif
