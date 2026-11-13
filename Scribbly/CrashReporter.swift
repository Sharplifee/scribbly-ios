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
        let prev = (try? String(contentsOf: prevCrumbsURL, encoding: .utf8)) ?? ""
        let prevLines = prev.split(separator: "\n").map(String.init)
        // A clean exit leaves "background" or "terminate" as the last crumb. If the
        // last run stopped on anything else (jetsam, watchdog, power loss, a crash
        // MetricKit hasn't delivered yet) it ended uncleanly — log it even when it
        // happened in the background, which the foreground flag alone can't see.
        let lastCrumb = prevLines.last ?? ""
        // A run that iOS started in the background (state 2) and never brought to
        // the foreground gets no "background" crumb either — that's normal too.
        let lastLaunch = prevLines.lastIndex { $0.contains(" launch build ") }
        let bgOnlyRun = lastLaunch.map { li in prevLines[li].hasSuffix("state 2") && !prevLines[li...].contains { $0.hasSuffix(" active") } } ?? false
        // Killed while a recording was still running (in the background, where
        // the last crumb is "background") is NOT a clean exit — the recording
        // was cut off. Recording is open if its Live Activity started and
        // never ended.
        let startedAt = prevLines.lastIndex { $0.hasSuffix("live activity started") }
        let endedAt = prevLines.lastIndex { $0.contains("live activity ended") }
        let diedRecording = startedAt.map { s in endedAt.map { $0 < s } ?? true } ?? false
        let endedClean = (lastCrumb.hasSuffix(" background") || lastCrumb.hasSuffix(" terminate") || bgOnlyRun) && !diedRecording
        let rebooted = Self.deviceRebootedSinceLastRun()
        if rebooted {
            EventLog.shared.log(.system, "device.rebooted", status: "info",
                                payload: Self.envelope(["boot_time": Self.bootTime(), "prev_last_crumb": lastCrumb], crumbs: prevLines))
        }
        if !prevLines.isEmpty && (!endedClean || diedInForeground || signalText != nil || exceptionText != nil) {
            EventLog.shared.log(.system, "app.prev_unclean", status: "fail",
                                payload: Self.envelope(["died_in_foreground": diedInForeground, "device_rebooted": rebooted,
                                                        "prev_last_crumb": lastCrumb, "died_while_recording": diedRecording, "signal": signalText ?? "",
                                                        "exception": exceptionText ?? ""], crumbs: prevLines))
        }
        if diedInForeground || signalText != nil || exceptionText != nil {
            send(kind: "unclean", json: [
                "build": Self.build,
                "os": UIDevice.current.systemVersion,
                "model": Self.model(),
                "simulator": Self.isSimulator,
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
        add("launch build \(Self.build) state \(UIApplication.shared.applicationState.rawValue)")
    }

    /// Record one breadcrumb (cheap; written through to disk off the main thread).
    func add(_ s: String) {
        EventLog.shared.log("app.step", ["note": s])
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
    /// Daily energy/performance report from iOS (CPU, GPU, background audio
    /// time, network, exit reasons). Logged so energy use can be assessed later.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            guard let obj = try? JSONSerialization.jsonObject(with: p.jsonRepresentation()) as? [String: Any] else { continue }
            var out: [String: Any] = ["begin": "\(p.timeStampBegin)", "end": "\(p.timeStampEnd)",
                                      "build": p.latestApplicationVersion]
            for k in ["cpuMetrics", "gpuMetrics", "applicationTimeMetrics", "applicationExitMetrics",
                      "networkTransferMetrics", "memoryMetrics", "displayMetrics", "diskIOMetrics",
                      "locationActivityMetrics", "cellularConditionMetrics"] {
                if let v = obj[k], let d = try? JSONSerialization.data(withJSONObject: v),
                   let s = String(data: d, encoding: .utf8) { out[k] = String(s.prefix(1900)) }
            }
            EventLog.shared.log(.system, "metrickit.metrics", status: "info", payload: out)
        }
    }

    private func forward(_ p: MXDiagnosticPayload) {
        guard (p.crashDiagnostics?.isEmpty == false) || (p.hangDiagnostics?.isEmpty == false)
              || (p.cpuExceptionDiagnostics?.isEmpty == false) || (p.diskWriteExceptionDiagnostics?.isEmpty == false) else { return }
        let stamp = p.timeStampEnd.timeIntervalSince1970
        // Every MetricKit crash/hang also goes to the permanent event_log (once).
        let logKey = "mx.logged.\(stamp)"
        if !UserDefaults.standard.bool(forKey: logKey) {
            let json = String(decoding: p.jsonRepresentation(), as: UTF8.self)
            var pl: [String: Any] = ["build": Self.build, "os": UIDevice.current.systemVersion, "model": Self.model(),
                                     "window_start": p.timeStampBegin, "window_end": p.timeStampEnd,
                                     "crashes": p.crashDiagnostics?.count ?? 0, "hangs": p.hangDiagnostics?.count ?? 0]
            if let c = p.crashDiagnostics?.first {
                pl["exception_type"] = c.exceptionType?.intValue ?? -1
                pl["signal"] = c.signal?.intValue ?? -1
                pl["termination_reason"] = c.terminationReason ?? ""
                pl["app_version"] = c.applicationVersion
            }
            if let h = p.hangDiagnostics?.first { pl["hang_duration_s"] = h.hangDuration.converted(to: .seconds).value }
            // The full report, chunked so nothing is cut (2000 chars per field, max 60).
            var chunks: [String: Any] = [:]
            var i = json.startIndex; var n = 0
            while i < json.endIndex && n < 60 {
                let j = json.index(i, offsetBy: 2000, limitedBy: json.endIndex) ?? json.endIndex
                chunks[String(format: "part_%02d", n)] = String(json[i..<j]); i = j; n += 1
            }
            pl["report"] = chunks; pl["report_parts"] = n; pl["report_truncated"] = i < json.endIndex
            let name = (p.crashDiagnostics?.isEmpty == false) ? "metrickit.crash" : "metrickit.hang"
            EventLog.shared.log(.system, name, status: "fail", payload: pl)
            UserDefaults.standard.set(true, forKey: logKey)
        }
        let key = "mx.sent.\(stamp)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Tag the payload with build + device so the box can sort it.
        var body = p.jsonRepresentation()
        if var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            obj["scribbly"] = ["build": Self.build, "model": Self.model(), "os": UIDevice.current.systemVersion,
                               "simulator": Self.isSimulator]
            body = (try? JSONSerialization.data(withJSONObject: obj)) ?? body
        }
        post(kind: "metrickit", body: body) { ok in
            if ok { UserDefaults.standard.set(true, forKey: key) }
        }
    }

    // MARK: device facts

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    /// Seconds since 1970 when the phone last booted (kern.boottime).
    static func bootTime() -> Int {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }
    /// True when the boot time differs from the one stored on the previous launch.
    static func deviceRebootedSinceLastRun() -> Bool {
        let now = bootTime(); let key = "crash.lastBootTime"
        let prev = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(now, forKey: key)
        // Allow a few seconds of drift; 0 means first launch on this install.
        return prev != 0 && now != 0 && abs(now - prev) > 5
    }
    /// Common fields + the last 60 crumbs, split so event_log's 50-item cap keeps them all.
    static func envelope(_ extra: [String: Any], crumbs: [String]) -> [String: Any] {
        var p = extra
        p["build"] = build; p["os"] = UIDevice.current.systemVersion; p["model"] = model()
        let last = Array(crumbs.suffix(60))
        p["crumbs_1"] = Array(last.prefix(30)); p["crumbs_2"] = Array(last.dropFirst(30))
        p["crumb_count"] = last.count
        return p
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
    static func model() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "Simulator \(sim)" }
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
