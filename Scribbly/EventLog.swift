import Foundation
import UIKit

/// Permanent, append-only event log. Every action the app takes is written
/// here with a timestamp, then sent to Supabase `scribbly_events` in batches.
/// Events are kept on disk until the server accepts them, so nothing is lost
/// offline, in the background or across a crash. The database refuses any
/// edit or delete of a logged event.
final class EventLog {
    static let shared = EventLog()

    private let q = DispatchQueue(label: "scribbly.eventlog")
    private var pending: [[String: Any]] = []
    private var flushing = false
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events-pending.json")
    }()
    private let device = UIDevice.current.model + " " + UIDevice.current.systemVersion
    private let version: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private init() {
        if let d = try? Data(contentsOf: fileURL),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { pending = arr }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.flush() }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.log("app.background"); self?.flush()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.log("app.foreground")
        }
    }

    /// Record one event. `action` is dotted (record.start, upload.failed…).
    func log(_ action: String, subject: String? = nil, status: String = "info", _ detail: [String: Any] = [:]) {
        #if targetEnvironment(simulator)
        let src = "app-sim"
        #else
        let src = "app"
        #endif
        var row: [String: Any] = ["at": iso.string(from: Date()), "source": src, "action": action, "status": status,
                                  "device": device, "app_version": version]
        if let subject { row["subject"] = subject }
        if !detail.isEmpty, JSONSerialization.isValidJSONObject(detail) { row["detail"] = detail }
        q.async { [self] in
            pending.append(row)
            if pending.count > 5000 { pending.removeFirst(pending.count - 5000) }
            persist()
            if pending.count >= 25 { flushLocked() }
        }
    }

    func error(_ action: String, subject: String? = nil, _ message: String, _ detail: [String: Any] = [:]) {
        var d = detail; d["error"] = String(message.prefix(1000))
        log(action, subject: subject, status: "error", d)
    }

    func flush() { q.async { [self] in flushLocked() } }

    private func persist() {
        if let d = try? JSONSerialization.data(withJSONObject: pending) { try? d.write(to: fileURL, options: .atomic) }
    }

    private func flushLocked() {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        let batch = Array(pending.prefix(200))
        var rows = batch
        if let uid = AuthTokens.userID { rows = rows.map { var r = $0; r["actor"] = uid; return r } }
        var req = URLRequest(url: URL(string: CorpusAPI.restBase + "/scribbly_events")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        CorpusAPI.restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: rows)
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self else { return }
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
            self.q.async {
                if ok {
                    self.pending.removeFirst(min(batch.count, self.pending.count))
                    self.persist()
                }
                self.flushing = false
                if ok && !self.pending.isEmpty { self.flushLocked() }
            }
        }.resume()
    }
}
