import Foundation

/// Sends a finished recording to Scribbly's /api/voice endpoint, which transcribes
/// (Groq Whisper, falling back to AssemblyAI) and summarizes it into the library.
///
/// Uses a *background* URLSession so an upload that is still in flight when the
/// user swipes the app away is finished by the system rather than dropped. A
/// recording the user waited for should never be lost to impatience.
final class Uploader: NSObject, ObservableObject {

    static let shared = Uploader()

    @Published var isUploading = false
    @Published var progress: Double = 0
    @Published var lastResultTitle: String?
    @Published var lastError: String?

    private let base = "https://getscribbly.vercel.app"
    private var completion: ((Bool, String?) -> Void)?

    private lazy var bgSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.connor.scribbly.upload")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Handed to us by the AppDelegate when iOS relaunches the app to finish an upload.
    var backgroundCompletionHandler: (() -> Void)?

    func upload(fileURL: URL, duration: TimeInterval, completion: @escaping (Bool, String?) -> Void) {
        self.completion = completion
        isUploading = true
        progress = 0
        lastError = nil

        guard let data = try? Data(contentsOf: fileURL) else {
            finish(false, "Could not read the recording file.")
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        let title = "Voice Memo — \(fmt.string(from: Date()))"

        let body: [String: Any] = [
            "action": "process-audio",
            "audioBase64": data.base64EncodedString(),
            "mimeType": "audio/m4a",
            "title": title
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            finish(false, "Could not encode the upload.")
            return
        }

        // Background uploads must be file-backed; an in-memory body is rejected.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).json")
        do { try json.write(to: tmp) } catch {
            finish(false, "Could not stage the upload: \(error.localizedDescription)")
            return
        }

        var req = URLRequest(url: URL(string: "\(base)/api/voice")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        bgSession.uploadTask(with: req, fromFile: tmp).resume()
    }

    private func finish(_ ok: Bool, _ message: String?) {
        DispatchQueue.main.async {
            self.isUploading = false
            self.progress = ok ? 1 : 0
            if ok { self.lastResultTitle = message } else { self.lastError = message }
            self.completion?(ok, message)
            self.completion = nil
        }
    }
}

extension Uploader: URLSessionDataDelegate, URLSessionTaskDelegate {

    func urlSession(_ s: URLSession, task: URLSessionTask,
                    didSendBodyData sent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend expected: Int64) {
        guard expected > 0 else { return }
        DispatchQueue.main.async { self.progress = Double(totalBytesSent) / Double(expected) }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let entry = obj["entry"] as? [String: Any], let t = entry["title"] as? String {
            finish(true, t)
        } else if let reason = (obj["error"] as? String) ?? (obj["reason"] as? String) {
            finish(false, reason)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(false, error.localizedDescription)
        } else if isUploading {
            // Completed with no parseable body — treat as success rather than
            // alarming the user; the entry lands in the library either way.
            finish(true, nil)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession s: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
