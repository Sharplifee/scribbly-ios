import Foundation

/// Nothing is allowed to just "fail". Every link in a batch gets 4 tries:
///  • try 1 — the batch's normal run (the rest of the batch keeps going past a failure);
///  • tries 2–4 — once the WHOLE batch has finished, everything that failed is
///    sent back in, again and again (right away, then after 1 min, then 5 min);
///  • a daily checkup (every 24 h, on open or by background refresh) sends
///    every item still in "Didn't work" through 4 fresh tries, so that list
///    never just piles up.
/// Recordings that failed on the server get the same treatment ("no speech"
/// is final — there's nothing to transcribe).
final class RetryEngine {
    static let shared = RetryEngine()
    static let maxRetries = 3                       // + the first run = 4 attempts
    private static let backoff: [TimeInterval] = [0, 60, 300]
    static let sweepEvery: TimeInterval = 24 * 3600

    private let d = UserDefaults.standard
    private var busy = false

    /// rowID → [retries done, time of last retry]
    private var ledger: [String: [Double]] {
        get { d.dictionary(forKey: "retry.ledger") as? [String: [Double]] ?? [:] }
        set {
            // Keep it small: drop entries untouched for 10 days.
            let cutoff = Date().timeIntervalSince1970 - 10 * 86400
            d.set(newValue.filter { $0.value.count == 2 && $0.value[1] > cutoff }, forKey: "retry.ledger")
        }
    }
    private var lastSweep: Double {
        get { d.double(forKey: "retry.lastSweep") }
        set { d.set(newValue, forKey: "retry.lastSweep") }
    }

    func retriesDone(_ id: String) -> Int { Int(ledger[id]?.first ?? 0) }
    func exhausted(_ id: String) -> Bool { retriesDone(id) >= Self.maxRetries }
    /// The NEXT try, "try 2 of 4", for the UI (try 1 was the batch's own run).
    func attemptLabel(_ id: String) -> String { "try \(min(retriesDone(id) + 2, Self.maxRetries + 1)) of \(Self.maxRetries + 1)" }

    private func due(_ id: String) -> Bool {
        guard let e = ledger[id], e.count == 2 else { return true }
        let n = Int(e[0])
        guard n < Self.maxRetries else { return false }
        return Date().timeIntervalSince1970 - e[1] >= Self.backoff[min(n, Self.backoff.count - 1)]
    }
    private func record(_ ids: [String]) {
        var l = ledger
        let now = Date().timeIntervalSince1970
        for id in ids { l[id] = [Double(retriesDone(id) + 1), now] }
        ledger = l
    }
    private func forget(_ ids: [String]) {
        var l = ledger
        for id in ids { l[id] = nil }
        ledger = l
    }

    struct QRow: Decodable { let id: String; let collection_id: String?; let status: String; let title: String? }

    /// One pass. Called by the live status loop (every 15 s while open), right
    /// after a batch finishes on Home, and by background refresh.
    /// Returns how many items were sent back in.
    @discardableResult
    func run(reason: String) async -> Int {
        let signedIn = await MainActor.run { AuthSession.shared.user != nil }
        guard !busy, signedIn else { return 0 }
        busy = true
        defer { busy = false }
        var sent = 0

        // Daily checkup: everything still failed gets a fresh set of 4 tries.
        let sweeping = Date().timeIntervalSince1970 - lastSweep >= Self.sweepEvery
        if sweeping {
            lastSweep = Date().timeIntervalSince1970
            if let rows = try? await failedRows() { forget(rows.map(\.id)) }
            let voice = await voiceFailures()
            forget(voice.map { "job:\($0.id)" })
            EventLog.shared.log("retry.daily_sweep", ["queue": (try? await failedRows().count) ?? -1, "voice": voice.count])
        }

        // Links: only batches with nothing still running — the batch finishes
        // first, then its failures go back in.
        if let failed = try? await failedRows(), !failed.isEmpty {
            let active = Set(((try? await activeCollections()) ?? []))
            let ready = failed.filter { r in !active.contains(r.collection_id ?? "") && due(r.id) }
            let byCol = Dictionary(grouping: ready, by: { $0.collection_id ?? "" })
            for (cid, rows) in byCol {
                let ids = rows.map(\.id)
                if await requeue(ids: ids, collection: cid.isEmpty ? nil : cid) {
                    record(ids)
                    sent += ids.count
                    EventLog.shared.log("retry.requeued", ["collection": cid, "count": ids.count,
                                                           "round": retriesDone(ids[0]), "reason": reason])
                }
            }
        }

        // Recordings that failed on the Scribbly® server.
        let voiceNow = await voiceFailures()
        for j in voiceNow where j.state == "failed" {
            let key = "job:\(j.id)"
            guard due(key) else { continue }
            if await voiceOp(j.id, "retry") {
                record([key]); sent += 1
                EventLog.shared.log("retry.voice", ["job": j.id, "round": retriesDone(key), "reason": reason])
            }
        }
        if sweeping { StatusWatcher.shared.markActivitySeen() }
        return sent
    }

    /// Home's "Retry now" — the user asked, so it goes in immediately and gets
    /// a fresh set of tries.
    func retryNow(collection: String) async -> Int {
        guard let rows = try? await failedRows(collection: collection), !rows.isEmpty else { return 0 }
        let ids = rows.map(\.id)
        forget(ids)
        guard await requeue(ids: ids, collection: collection) else { return 0 }
        record(ids)
        EventLog.shared.log("retry.manual", ["collection": collection, "count": ids.count])
        return ids.count
    }

    /// After a batch's normal run: sends its failures straight back in (try 2).
    func batchFinished(collection: String) async -> Int {
        guard let rows = try? await failedRows(collection: collection) else { return 0 }
        let ids = rows.map(\.id).filter { due($0) }
        guard !ids.isEmpty, await requeue(ids: ids, collection: collection) else { return 0 }
        record(ids)
        EventLog.shared.log("retry.requeued", ["collection": collection, "count": ids.count, "round": retriesDone(ids[0]), "reason": "batch_finished"])
        return ids.count
    }

    /// Failed rows in a batch that still have tries left (waiting on backoff).
    func retriesLeft(collection: String) async -> Int {
        guard let rows = try? await failedRows(collection: collection) else { return 0 }
        return rows.filter { !exhausted($0.id) }.count
    }

    func failedCount(collection: String) async -> Int {
        (try? await failedRows(collection: collection).count) ?? 0
    }

    /// Failed rows in a batch that have used all 4 tries.
    func exhaustedCount(ids: [String]) -> Int { ids.filter { exhausted($0) }.count }

    // MARK: Network

    private func failedRows(collection: String? = nil) async throws -> [QRow] {
        var items = [URLQueryItem(name: "select", value: "id,collection_id,status,title"),
                     URLQueryItem(name: "status", value: "eq.failed"),
                     URLQueryItem(name: "order", value: "id.asc"),
                     URLQueryItem(name: "limit", value: "1000")]
        if let collection { items.append(URLQueryItem(name: "collection_id", value: "eq.\(collection)")) }
        return try await CorpusAPI.getJSON(CorpusAPI.restURL("scribbly_queue", items), as: [QRow].self)
    }
    private func activeCollections() async throws -> [String] {
        let rows = try await CorpusAPI.getJSON(CorpusAPI.restURL("scribbly_queue", [
            URLQueryItem(name: "select", value: "id,collection_id,status,title"),
            URLQueryItem(name: "status", value: "in.(pending,processing)"),
            URLQueryItem(name: "limit", value: "1000")]), as: [QRow].self)
        return Array(Set(rows.compactMap(\.collection_id)))
    }

    /// Back to pending, then nudge the server to pick the batch up again.
    private func requeue(ids: [String], collection: String?) async -> Bool {
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let list = chunk.map(CorpusAPI.quoted).joined(separator: ",")
            let url = CorpusAPI.restURL("scribbly_queue", [URLQueryItem(name: "id", value: "in.(\(list))")])
            guard let req = try? CorpusAPI.restRequest(url, method: "PATCH",
                                                       body: ["status": "pending", "attempts": 0, "error": NSNull()]),
                  (try? await CorpusAPI.send(req)) != nil else { return false }
        }
        // Nudge the server to pick the batch back up — but never on a batch
        // that has cancelled ("skipped") rows, so a cancel is never undone.
        if let collection, await skippedCount(collection) == 0 {
            var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/ingest")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "resume-collection", "collectionId": collection])
            _ = try? await URLSession.shared.data(for: req)
        }
        return true
    }

    private func skippedCount(_ collection: String) async -> Int {
        (try? await CorpusAPI.count(table: "scribbly_queue", filters: [
            URLQueryItem(name: "collection_id", value: "eq.\(collection)"),
            URLQueryItem(name: "status", value: "eq.skipped")])) ?? 1
    }

    private var voiceBase: String {
        var u = CorpusAPI.voiceIngestURL
        if let r = u.range(of: "/upload", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }
    private func voiceFailures() async -> [JobsModel.VoiceJob] {
        let owner = await MainActor.run { AuthSession.shared.isLibraryOwner }
        guard owner, let url = URL(string: voiceBase + "/jobs") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        struct R: Decodable { let jobs: [JobsModel.VoiceJob] }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let r = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return r.jobs.filter { $0.state == "failed" || $0.state == "no_speech" }
    }
    private func voiceOp(_ id: String, _ op: String) async -> Bool {
        guard var c = URLComponents(string: voiceBase + "/job") else { return false }
        c.queryItems = [URLQueryItem(name: "jobId", value: id), URLQueryItem(name: "op", value: op)]
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        return (try? await CorpusAPI.send(req)) != nil
    }
}
