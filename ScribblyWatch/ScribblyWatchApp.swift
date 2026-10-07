import SwiftUI
import WatchKit

/// Finishes background URLSession wake-ups so uploads that complete while the
/// app is suspended are recorded (and the watch app isn't penalised for them).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let t = task as? WKURLSessionRefreshBackgroundTask {
                _ = WatchRecorder.shared   // re-attaches the background session
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { t.setTaskCompletedWithSnapshot(false) }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct ScribblyWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { WatchRecordView() }
    }
}
