import Foundation
import UIKit
import MetricKit
import Darwin

/// Crash capture so a crash is never a mystery again.
///  • MetricKit crash diagnostics (full stack, binary UUIDs) are forwarded to the
///    Scribbly server on the next launch.
///  • A breadcrumb trail (last ~60 app events) is written to disk as the app runs;
///    if the previous run died while in the FOREGROUND, the trail is sent too.
///  • Uncaught ObjC exceptions and fatal signals write a backtrace to disk first.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var crumbsURL: URL { dir.appendingPathComponent("crumbs.txt") }
    private var prevCrumbsURL: URL { dir.appendingPathComponent("crumbs.prev.txt") }
    private var fgMarker: URL { dir.appendingPathComponent("foreground.flag") }
    private var signalURL: URL { dir.appendingPathComponent("signal.txt") }
    private var exceptionURL: URL { dir.appendingPathComponent("exception.txt") }
    private let q = DispatchQueue(label: "scribbly.crumbs")
    private var crumbs: [String] = []
    private var started = false

    private var endpoint: URL? {
        URL(string: CorpusAPI.voiceIngestURL.replacingOccurrences(of: "/upload", with: "/crash"))
    }

    func start() {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        // Did the last run die in the foreground?
        let diedInForeground = fm.fileExists(atPath: fgMarker.path)
        let signalText = try? String(contentsOf: signalURL, encoding: .utf8)
        let exceptionText = try? String(contentsOf: exceptionURL, encoding: .utf8)
        if fm.fileExists(atPath: crumbsURL.path) {
            try? fm.removeItem(at: prevCrumbsURL)
            try? fm.moveItem(at: crumbsURL, to: prevCrumbsURL)
        }
        if diedInForeground || signalText != nil || exceptionText != nil {
            let prev = (try? String(contentsOf: prevCrumbsURL, encoding: .utf8)) ?? ""
            send(kind: "unclean", json: [
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                "os": UIDevice.current.systemVersion,
                "model": Self.model(),
                "diedInForeground": diedInForeground,
                "signal": signalText ?? "",
                "exception": exceptionText ?? "",
                "crumbs": prev,
            ])
        }
        try? fm.removeItem(at: signalURL)
        try? fm.removeItem(at: exceptionURL)
        try? fm.removeItem(at: fgMarker)

        installHandlers()
        MXMetricManager.shared.add(self)
        // Diagnostics delivered before we subscribed (iOS 14+ keeps them).
        if #available(iOS 14.0, *) {
            for p in MXMetricManager.shared.pastDiagnosticPayloads { forward(p) }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setForeground(true); self?.add("active")
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setForeground(false); self?.add("background")
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setForeground(false); self?.add("terminate")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.add("memory warning")
        }
        add("launch build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") state \(UIApplication.shared.applicationState.rawValue)")
    }

    /// Record one breadcrumb (cheap; written through to disk off the main thread).
    func add(_ s: String) {
        let line = "\(Self.stamp()) \(s)"
        q.async { [self] in
            crumbs.append(line)
            if crumbs.count > 60 { crumbs.removeFirst(crumbs.count - 60) }
            try? crumbs.joined(separator: "\n").write(to: crumbsURL, atomically: true, encoding: .utf8)
        }
    }

    private func setForeground(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: fgMarker.path, contents: Data()) }
        else { try? FileManager.default.removeItem(at: fgMarker) }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) { payloads.forEach(forward) }
    func didReceive(_ payloads: [MXMetricPayload]) {}

    private func forward(_ p: MXDiagnosticPayload) {
        guard (p.crashDiagnostics?.isEmpty == false) || (p.hangDiagnostics?.isEmpty == false) else { return }
        let key = "mx.sent.\(p.timeStampEnd.timeIntervalSince1970)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        post(kind: "metrickit", body: p.jsonRepresentation()) { ok in
            if ok { UserDefaults.standard.set(true, forKey: key) }
        }
    }

    // MARK: transport

    private func send(kind: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        post(kind: kind, body: data) { _ in }
    }

    private func post(kind: String, body: Data, done: @escaping (Bool) -> Void) {
        guard let u = endpoint else { return done(false) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue(kind, forHTTPHeaderField: "x-kind")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 30
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            done((resp as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    // MARK: fatal handlers

    private func installHandlers() {
        CrashReporter.signalPath = strdup(signalURL.path)
        CrashReporter.exceptionPath = exceptionURL.path
        NSSetUncaughtExceptionHandler { ex in
            guard let path = CrashReporter.exceptionPath else { return }
            let text = "\(ex.name.rawValue): \(ex.reason ?? "")\n" + ex.callStackSymbols.joined(separator: "\n")
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        for s in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(s, crashSignalHandler)
        }
    }
    static var signalPath: UnsafeMutablePointer<CChar>?
    static var exceptionPath: String?

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
    }
    private static func model() -> String {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Fatal-signal handler: write the signal number and raw backtrace (with image
/// names + offsets) to disk, then re-raise so iOS still records its own report.
private func crashSignalHandler(_ sig: Int32) {
    if let p = CrashReporter.signalPath {
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            var head = Array("signal \(sig)\n".utf8)
            _ = write(fd, &head, head.count)
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let n = backtrace(&frames, 64)
            backtrace_symbols_fd(&frames, n, fd)
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
