import Foundation
import WatchConnectivity

/// Receives recordings from the Apple Watch and feeds them into the normal
/// upload path — so a watch memo lands in the library exactly like a phone memo.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private var activated = false

    /// Called from ScribblyApp.init (so watch transfers arrive even when the app
    /// is launched in the background) and again from the UI; only the first counts.
    func activate() {
        guard WCSession.isSupported() else { return }
        guard !activated else { return }   // both callers run on the main thread
        activated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The incoming file is deleted when this method returns — copy it first.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).m4a")
        do { try FileManager.default.copyItem(at: file.fileURL, to: dst) } catch { return }
        let title = (file.metadata?["title"] as? String) ?? "Watch memo"
        let duration = (file.metadata?["duration"] as? TimeInterval) ?? 0
        DispatchQueue.main.async {
            // Only a place fixed in the last 15 minutes — never a stale one.
            Uploader.shared.upload(fileURL: dst, title: title, duration: duration,
                                   location: PlaceTagger.shared.recentPlace) { _, _ in }
        }
    }

    // Required by the protocol on iOS.
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
