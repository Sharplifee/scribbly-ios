import Foundation
import AVFoundation
import WatchConnectivity

/// Records on the watch itself (no phone needed at record time) and hands the
/// finished file to the iPhone over WatchConnectivity, which uploads it exactly
/// like a phone recording. If the phone is out of reach, the transfer waits and
/// completes automatically the next time the two are together.
final class WatchRecorder: NSObject, ObservableObject, WCSessionDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var status: String = ""
    @Published var pendingTransfers = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var fileURL: URL?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch { status = "Mic unavailable: \(error.localizedDescription)"; return }
        session.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else { self.status = "Microphone access is off — allow it in the Watch app settings."; return }
                self.begin()
            }
        }
    }

    private func begin() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { status = "Could not start recording. Tap again."; return }
            recorder = r; fileURL = url; startedAt = Date()
            isRecording = true; elapsed = 0; status = ""
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = max(self.elapsed, Date().timeIntervalSince(s))
            }
        } catch { status = "Could not start recording (\(error.localizedDescription)). Tap again." }
    }

    func finish() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let url = fileURL else { return }
        let dur = elapsed
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
        let meta: [String: Any] = ["title": "Watch memo — \(fmt.string(from: Date()))", "duration": dur]
        if WCSession.default.activationState == .activated {
            WCSession.default.transferFile(url, metadata: meta)
            pendingTransfers = WCSession.default.outstandingFileTransfers.count
            status = WCSession.default.isReachable ? "Sent to iPhone." : "Saved — sends to iPhone when it's nearby."
        } else {
            status = "Saved on watch — open the iPhone app to sync."
        }
        fileURL = nil; elapsed = 0
    }

    func discard() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false; elapsed = 0
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil; status = "Discarded."
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            self.pendingTransfers = session.outstandingFileTransfers.count
            if let error { self.status = "Send failed (\(error.localizedDescription)) — will retry." }
            else { self.status = "Delivered to iPhone."; try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
        }
    }
}
