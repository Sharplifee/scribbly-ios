import Foundation
import AVFoundation
import WatchConnectivity

/// Records on the watch itself and uploads the finished file STRAIGHT to Sharp's
/// Cloud Computer (background URLSession — over the phone's connection, Wi-Fi or
/// cellular), so it's transcribed and saved without the iPhone app ever opening.
/// Only if that upload fails does it fall back to handing the file to the
/// iPhone over WatchConnectivity.
final class WatchRecorder: NSObject, ObservableObject, WCSessionDelegate, URLSessionTaskDelegate {
    static let shared = WatchRecorder()
    static let uploadURL = URL(string: "https://207-148-6-194.sslip.io/v/aa6edc0decd726d1aef6f3e7ec489965/upload")!
    private lazy var uploads: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "com.connor.scribbly.watch.upload")
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var outbox: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
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
        _ = uploads   // reconnect to any upload still running from a previous launch
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
        let title = "Watch memo — \(fmt.string(from: Date()))"
        // Move out of tmp so the background upload can always read it.
        let kept = outbox.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: kept)
        upload(kept, title: title, duration: dur)
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

    private func upload(_ file: URL, title: String, duration: TimeInterval) {
        var req = URLRequest(url: Self.uploadURL)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Watch%20memo", forHTTPHeaderField: "x-title")
        req.setValue("m4a", forHTTPHeaderField: "x-ext")
        let task = uploads.uploadTask(with: req, fromFile: file)
        // Remember what to fall back with if the upload fails.
        task.taskDescription = [file.path, title, String(duration)].joined(separator: "\n")
        task.resume()
        status = "Uploading — no need to open your iPhone."
    }

    // MARK: URLSession (direct upload)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let parts = (task.taskDescription ?? "").components(separatedBy: "\n")
        guard parts.count == 3 else { return }
        let file = URL(fileURLWithPath: parts[0])
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, (200..<300).contains(code) {
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async { self.status = "Sent — transcribing on the server." }
        } else {
            // Fallback: hand it to the iPhone, which uploads it the same way.
            let meta: [String: Any] = ["title": parts[1], "duration": Double(parts[2]) ?? 0]
            DispatchQueue.main.async {
                if WCSession.default.activationState == .activated {
                    WCSession.default.transferFile(file, metadata: meta)
                    self.pendingTransfers = WCSession.default.outstandingFileTransfers.count
                    self.status = "Couldn't reach the server — sending through your iPhone instead."
                } else {
                    self.status = "Couldn't upload — saved on the watch, will retry."
                }
            }
        }
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
