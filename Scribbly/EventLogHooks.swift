import Foundation

/// Short forms used by Scribbly's hooks, written into the shared append-only
/// `public.event_log` (project "scribbly") through EventLog.
extension EventLog {
    func log(_ name: String, subject: String? = nil, status: String = "ok", _ detail: [String: Any] = [:]) {
        var p = detail
        if let subject { p["subject"] = subject }
        log(.action, name, status: status, payload: p, requestId: subject)
    }
    func error(_ name: String, subject: String? = nil, _ message: String, _ detail: [String: Any] = [:]) {
        var p = detail
        if let subject { p["subject"] = subject }
        log(.error, name, status: "fail", payload: p, requestId: subject, errorMessage: message)
    }
}
