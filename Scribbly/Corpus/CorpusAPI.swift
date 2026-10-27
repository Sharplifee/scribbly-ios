import Foundation

/// Direct Supabase REST client for the read paths, plus the app's own API
/// routes for anything that writes (dedupe, queue, collection creation all
/// live server-side and must not be reimplemented on-device).
///
/// Field names, filters and thresholds here are taken from the live blueprint,
/// not from memory. Notable corrections baked in vs the web app:
///   • Library paginates with a keyset cursor (no offset duplicates, no 1000-row cap).
///   • Sorting is by created_at, never the text `date` column.
///   • saved_videos is never trusted — collection counts derive from entries.
///   • master_corpus is never written from the app: a database trigger mirrors
///     every scribbly_entries insert/update/delete into it.
enum CorpusAPI {

    static let supabaseURL = "https://lbvaosyfikkpvcwksiph.supabase.co"
    static let restBase = "\(supabaseURL)/rest/v1"
    static let appBase  = "https://getscribbly.vercel.app"
    /// Phone-off voice pipeline: the box at sharp-cloud-01 accepts one raw-audio
    /// POST, transcribes with Groq Whisper (auto-chunking any length), summarizes
    /// and saves — the connection has no size or time limit. The phone's only job
    /// is to finish the upload; everything after that survives the app closing.
    static let voiceIngestURL = "https://207-148-6-194.sslip.io/v/aa6edc0decd726d1aef6f3e7ec489965/upload"

    /// Anon key — client-scoped, same key the web app ships in plain JS.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4"

    /// Every PostgREST call carries these; Content-Type is harmless on reads and
    /// required on writes (without it PostgREST rejects the JSON body).
    static var restHeaders: [String: String] {
        ["apikey": anonKey, "Authorization": "Bearer \(anonKey)", "Content-Type": "application/json"]
    }

    // MARK: - Request plumbing

    /// A REST URL with the query items encoded the way PostgREST needs them.
    /// URLComponents leaves "+" untouched and PostgREST reads a bare "+" as a
    /// space — which breaks timestamps ("+00:00") and searches like "c++".
    static func restURL(_ table: String, _ items: [URLQueryItem]) -> URL {
        var c = URLComponents(string: "\(restBase)/\(table)")!
        c.queryItems = items.isEmpty ? nil : items
        if let q = c.percentEncodedQuery {
            c.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    /// A REST request with the auth headers, JSON content type, optional Prefer and body.
    static func restRequest(_ url: URL, method: String, prefer: String? = nil, body: Any? = nil) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    /// Sends a request and throws a readable error unless the server answered 2xx.
    @discardableResult
    static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw CorpusAPIError.http(status, errorText(data))
        }
        return data
    }

    /// The server's own error message if it sent one, else the raw body.
    static func errorText(_ data: Data) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = j["message"] as? String { return m }
            if let e = j["error"] as? String { return e }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Escapes a value for a double-quoted PostgREST filter value ("…").
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Mutations

    /// Permanently removes an entry from the library. The database trigger
    /// removes its master_corpus copy. Throws if nothing was actually deleted.
    static func deleteEntry(id: String) async throws {
        let url = restURL("scribbly_entries", [.init(name: "id", value: "eq.\(id)"), .init(name: "select", value: "id")])
        let req = try restRequest(url, method: "DELETE", prefer: "return=representation")
        let data = try await send(req)
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        if rows.isEmpty {
            throw CorpusAPIError.message("Nothing was deleted — the entry may already be gone. Pull to refresh.")
        }
    }

    /// Moves every collection in a group under a new channel name.
    static func reassignCollections(ids: [String], to channel: String) async throws {
        guard !ids.isEmpty else { return }
        let list = ids.map(quoted).joined(separator: ",")
        let url = restURL("scribbly_collections", [.init(name: "id", value: "in.(\(list))"), .init(name: "select", value: "id")])
        let req = try restRequest(url, method: "PATCH", prefer: "return=representation", body: ["channel": channel])
        let data = try await send(req)
        let moved = ((try? JSONSerialization.jsonObject(with: data) as? [Any]) ?? []).count
        if moved < ids.count {
            throw CorpusAPIError.message("Only \(moved) of \(ids.count) collections were moved.")
        }
    }

    /// Writes an entry to scribbly_entries (the trigger mirrors it into
    /// master_corpus). Upserts on `id`, so a retry with the same id — use
    /// `stableEntryID(for:)` — updates the row instead of duplicating it.
    /// (The pipeline "save" action only makes a Notion page and reports success
    /// unconditionally — it is NOT a library write.)
    static func saveEntry(id: String, title: String, type: String, tags: String,
                          summary: String, transcript: String) async throws {
        let body: [String: Any] = ["id": id, "title": title, "type": type, "tags": tags,
                                   "summary": summary, "transcript": transcript,
                                   "date": EntryDates.display.string(from: Date())]
        let url = restURL("scribbly_entries", [.init(name: "on_conflict", value: "id")])
        let req = try restRequest(url, method: "POST", prefer: "resolution=merge-duplicates,return=minimal", body: body)
        try await send(req)
    }

    /// Deterministic entry id for a source URL ("entry_" + FNV-1a 64 of the
    /// URL without its fragment or share-tracking params), so saving the same
    /// link twice lands on the same row.
    static func stableEntryID(for url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if var c = URLComponents(string: key) {
            c.fragment = nil
            let tracking: Set<String> = ["igsh", "igshid", "si", "fbclid", "gclid", "feature"]
            let kept = (c.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !tracking.contains($0.name.lowercased()) }
            c.queryItems = kept.isEmpty ? nil : kept
            key = c.string ?? key
        }
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "entry_" + String(h, radix: 16)
    }

    // MARK: - Ingest helpers

    /// Which of these YouTube ids are already saved as entries (id = yt_<videoId>).
    static func existingVideoIDs(_ ids: [String]) async throws -> Set<String> {
        var found = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let list = chunk.map { quoted("yt_" + $0) }.joined(separator: ",")
            struct Row: Decodable { let id: String }
            let rows = try await getJSON(restURL("scribbly_entries", [.init(name: "select", value: "id"), .init(name: "id", value: "in.(\(list))")]), as: [Row].self)
            for r in rows { found.insert(String(r.id.dropFirst(3))) }
        }
        return found
    }

    /// Extract an 11-char YouTube id from any watch / youtu.be / shorts / embed URL, or a bare id.
    static func youtubeID(from s: String) -> String? {
        let pattern = #"(?:v=|youtu\.be/|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})"#
        if let r = s.range(of: pattern, options: .regularExpression) {
            let m = String(s[r]); return String(m.suffix(11))
        }
        return s.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? s : nil
    }

    // MARK: - Entries (Library)

    /// Library sort orders, all done by the server.
    enum EntrySort: String, CaseIterable {
        case newest = "Newest", oldest = "Oldest", title = "A–Z", longest = "Longest", shortest = "Shortest"
        /// Longest / Shortest order by duration_seconds (an integer column) and
        /// only list entries that have a real length (> 0).
        var isDuration: Bool { self == .longest || self == .shortest }
        /// Newest / Oldest — the feed is grouped into time sections.
        var isByDate: Bool { self == .newest || self == .oldest }
    }

    static let listSelect = "id,title,type,tags,summary,date,created_at,collection_id,duration_seconds,place,kind"

    /// PostgREST order clause for a sort; `id` breaks ties so the keyset cursor is exact.
    static func orderClause(_ sort: EntrySort) -> String {
        switch sort {
        case .newest: return "created_at.desc,id.desc"
        case .oldest: return "created_at.asc,id.asc"
        case .title:  return "title.asc,id.asc"
        case .longest:  return "duration_seconds.desc.nullslast,id.desc"
        case .shortest: return "duration_seconds.asc.nullslast,id.asc"
        }
    }

    /// Newest few entries without summaries — tiny payload, used for Home → Recent at launch.
    static func recentEntries(limit: Int = 6) async throws -> [Entry] {
        let url = restURL("scribbly_entries", [
            .init(name: "select", value: "id,title,type,date,created_at,collection_id,duration_seconds,place,kind"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: String(limit))
        ])
        return try await getJSON(url, as: [Entry].self, timeout: 20)
    }

    /// One page of entries, filtered and sorted on the server. Pages with a
    /// keyset cursor (the last row of the previous page), never an offset, so
    /// rows inserted while scrolling can't shift the window and duplicate rows.
    /// `filters` are extra PostgREST filters (date range, creator's collections,
    /// duration > 0) — see LibraryStore.filters(for:).
    static func entries(type: String? = nil, collectionID: String? = nil, sort: EntrySort = .newest,
                        after last: Entry? = nil, limit: Int = 100,
                        select: String = listSelect, filters: [URLQueryItem] = []) async throws -> [Entry] {
        var items: [URLQueryItem] = [
            .init(name: "select", value: select),
            .init(name: "limit", value: String(limit))
        ]
        items.append(URLQueryItem(name: "order", value: orderClause(sort)))
        if let type { items.append(.init(name: "type", value: "eq.\(type)")) }
        if let collectionID { items.append(.init(name: "collection_id", value: "eq.\(collectionID)")) }
        items.append(contentsOf: filters)
        if let last {
            let id = quoted(last.id)
            switch sort {
            case .newest, .oldest:
                guard let ts = last.created_at else {
                    throw CorpusAPIError.message("Can't continue paging: an entry has no created_at.")
                }
                let op = sort == .newest ? "lt" : "gt"
                let t = quoted(ts)
                items.append(.init(name: "or", value: "(created_at.\(op).\(t),and(created_at.eq.\(t),id.\(op).\(id)))"))
            case .title:
                let t = quoted(last.title)
                items.append(.init(name: "or", value: "(title.gt.\(t),and(title.eq.\(t),id.gt.\(id)))"))
            case .longest, .shortest:
                guard let d = last.duration_seconds, d.isFinite else {
                    throw CorpusAPIError.message("Can't continue paging: an entry has no length.")
                }
                let op = sort == .longest ? "lt" : "gt"
                let v = String(Int(d.rounded()))      // integer column
                items.append(.init(name: "or", value: "(duration_seconds.\(op).\(v),and(duration_seconds.eq.\(v),id.\(op).\(id)))"))
            }
        }
        return try await getJSON(restURL("scribbly_entries", items), as: [Entry].self)
    }

    /// Every entry's metadata + summary (no transcripts — that would be tens of MB),
    /// newest first, paged with the keyset cursor until the server runs out.
    static func allEntriesLight() async throws -> [Entry] {
        var out: [Entry] = []
        var last: Entry? = nil
        while true {
            let page = try await entries(sort: .newest, after: last, limit: 1000)
            out += page
            guard page.count == 1000, let l = page.last else { break }
            last = l
        }
        return out
    }

    /// Full single entry for the detail view (includes transcript).
    static func entry(id: String) async throws -> Entry? {
        let url = restURL("scribbly_entries", [
            .init(name: "id", value: "eq.\(id)"),
            .init(name: "select", value: "*")
        ])
        return try await getJSON(url, as: [Entry].self).first
    }

    // MARK: - Collections & Groups

    static func collections() async throws -> [Collection] {
        let url = restURL("scribbly_collections", [
            .init(name: "select", value: "*"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: "1000")
        ])
        return try await getJSON(url, as: [Collection].self)
    }

    /// Groups are computed, not stored: one group per creator. Channel names
    /// are grouped on a normalized key (trim, case, accents, punctuation,
    /// leading "The ", middle initials) so one creator never shows as two; the
    /// group takes the spelling with the most saved videos. Holding buckets
    /// (Unsorted / Mixed Creators / Links / Imported) collapse into one
    /// "Filing…" group, always last. Creators sorted by saved videos, desc.
    static func groups(from collections: [Collection]) -> [Group] {
        var map: [String: Group] = [:]
        var spellings: [String: [String: Int]] = [:]
        var filing = Group(channel: Group.filingName, collections: [], totalVideos: 0)
        for col in collections {
            let raw = col.groupKey
            if CreatorName.isFiling(raw) || CreatorName.isFiling(col.channel) {
                filing.collections.append(col)
                filing.totalVideos += col.saved_videos ?? 0
                continue
            }
            let key = CreatorName.normalizedKey(raw)
            var g = map[key] ?? Group(channel: raw, collections: [], totalVideos: 0)
            g.collections.append(col)
            g.totalVideos += col.saved_videos ?? 0
            map[key] = g
            spellings[key, default: [:]][raw, default: 0] += max(col.saved_videos ?? 0, 1)
        }
        var out: [Group] = []
        for (key, group) in map {
            var g = group
            if let best = spellings[key]?.max(by: { a, b in a.value < b.value })?.key { g.channel = best }
            out.append(g)
        }
        out.sort { a, b in a.totalVideos > b.totalVideos }
        if !filing.collections.isEmpty { out.append(filing) }
        return out
    }

    // MARK: - Live batch progress (scribbly_queue)

    struct QueueRow: Decodable {
        let id: String
        let status: String
        let progress: Int?
        let stage: String?
        let title: String?
    }

    /// Every queue row of one batch (paged by id past PostgREST's 1,000 cap).
    static func queueRows(collection: String) async throws -> [QueueRow] {
        var out: [QueueRow] = []
        var lastID: String? = nil
        while true {
            var items: [URLQueryItem] = [
                .init(name: "select", value: "id,status,progress,stage,title"),
                .init(name: "collection_id", value: "eq.\(collection)"),
                .init(name: "order", value: "id.asc"),
                .init(name: "limit", value: "1000")
            ]
            if let lastID { items.append(.init(name: "id", value: "gt.\(quoted(lastID))")) }
            let page = try await getJSON(restURL("scribbly_queue", items), as: [QueueRow].self, timeout: 15)
            out += page
            guard page.count == 1000, let l = page.last else { break }
            lastID = l.id
        }
        return out
    }
    // MARK: - Query (search)

    /// Searches master_corpus with the maintained full-text index (search_doc).
    /// websearch syntax (wfts) accepts any words — "behavioral psychology",
    /// quotes, apostrophes — where plain fts needs tsquery operators. If the
    /// index finds nothing (e.g. only stop words like "don't") or the query
    /// fails, falls back to a substring match.
    static func search(_ query: String, limit: Int = 100) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = [
            .init(name: "select", value: "id,title,type,tags,summary,date,source_url,origin,collection,normalized_date"),
            .init(name: "order", value: "normalized_date.desc.nullslast"),
            .init(name: "limit", value: String(limit))
        ]
        guard !trimmed.isEmpty else { return try await getJSON(restURL("master_corpus", items), as: [SearchHit].self) }
        items.append(.init(name: "search_doc", value: "wfts(english).\(trimmed)"))
        if let hits = try? await getJSON(restURL("master_corpus", items), as: [SearchHit].self), !hits.isEmpty {
            return hits
        }
        return try await searchILIKE(trimmed, limit: limit)
    }

    private static func searchILIKE(_ q: String, limit: Int) async throws -> [SearchHit] {
        let url = restURL("master_corpus", [
            .init(name: "select", value: "id,title,type,tags,summary,date,source_url,origin,collection,normalized_date"),
            .init(name: "or", value: ilikeAny(q, fields: ["title", "summary", "tags"])),
            .init(name: "order", value: "normalized_date.desc.nullslast"),
            .init(name: "limit", value: String(limit))
        ])
        return try await getJSON(url, as: [SearchHit].self)
    }

    /// `(f1.ilike."*q*",f2.ilike."*q*")` — the value is quoted so commas,
    /// parentheses and apostrophes in the query can't break the filter.
    private static func ilikeAny(_ q: String, fields: [String]) -> String {
        let v = quoted("*\(q)*")
        return "(" + fields.map { "\($0).ilike.\(v)" }.joined(separator: ",") + ")"
    }

    /// Library search: the same full-text index as Query, limited to the
    /// Scribbly mirror rows (id "scribbly_<entry id>"), then the matching
    /// entries are fetched with the type filter and sort applied by the server.
    /// Falls back to a substring match on the entries when the index finds nothing.
    static let entrySearchLimit = 200
    static func searchEntries(_ query: String, type: String?, sort: EntrySort,
                              filters: [URLQueryItem] = []) async throws -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let order = orderClause(sort)
        struct Row: Decodable { let id: String }
        let ftsURL = restURL("master_corpus", [
            .init(name: "select", value: "id"),
            .init(name: "search_doc", value: "wfts(english).\(q)"),
            .init(name: "id", value: "like.scribbly_*"),
            .init(name: "limit", value: String(entrySearchLimit))
        ])
        if let rows = try? await getJSON(ftsURL, as: [Row].self), !rows.isEmpty {
            let ids = rows.map { String($0.id.dropFirst("scribbly_".count)) }
            var items: [URLQueryItem] = [
                .init(name: "select", value: listSelect),
                .init(name: "id", value: "in.(\(ids.map(quoted).joined(separator: ",")))"),
                .init(name: "order", value: order),
                .init(name: "limit", value: String(entrySearchLimit))
            ]
            if let type { items.append(.init(name: "type", value: "eq.\(type)")) }
            items.append(contentsOf: filters)
            let found = try await getJSON(restURL("scribbly_entries", items), as: [Entry].self)
            if !found.isEmpty { return found }
        }
        var items: [URLQueryItem] = [
            .init(name: "select", value: listSelect),
            .init(name: "or", value: ilikeAny(q, fields: ["title", "summary", "tags"])),
            .init(name: "order", value: order),
            .init(name: "limit", value: String(entrySearchLimit))
        ]
        if let type { items.append(.init(name: "type", value: "eq.\(type)")) }
        items.append(contentsOf: filters)
        return try await getJSON(restURL("scribbly_entries", items), as: [Entry].self)
    }

    /// Voice notes since `start`: how many, and their total recorded length
    /// (PostgREST aggregates are disabled on this project, so it's summed here).
    static func voiceStats(since start: Date) async throws -> (count: Int, seconds: Double) {
        struct Row: Decodable { let duration_seconds: Double? }
        let url = restURL("scribbly_entries", [
            .init(name: "select", value: "duration_seconds"),
            .init(name: "type", value: "eq.Voice Note"),
            .init(name: "created_at", value: "gte.\(EntryDates.utc(start))"),
            .init(name: "limit", value: "1000")
        ])
        let rows = try await getJSON(url, as: [Row].self, timeout: 20)
        let secs = rows.reduce(0.0) { (sum: Double, r: Row) -> Double in
            guard let d = r.duration_seconds, d.isFinite, d > 0 else { return sum }
            return sum + d
        }
        return (rows.count, secs)
    }

    // MARK: - Counts

    /// Exact row count via a HEAD request reading the content-range header.
    static func count(table: String, filters: [URLQueryItem] = []) async throws -> Int {
        var req = try restRequest(restURL(table, [URLQueryItem(name: "select", value: "id")] + filters), method: "HEAD", prefer: "count=exact")
        req.timeoutInterval = 20
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw CorpusAPIError.http(http.statusCode, "count failed") }
        guard let range = http.value(forHTTPHeaderField: "content-range"),
              let total = range.split(separator: "/").last,
              let n = Int(total) else { throw URLError(.badServerResponse) }
        return n
    }

    // MARK: - Per-entry Ask (grounded chat) via the app's pipeline route

    static func ask(entry: Entry, question: String, history: [[String: String]]) async throws -> String {
        var req = URLRequest(url: URL(string: "\(appBase)/api/pipeline")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        let body: [String: Any] = [
            "action": "ask",
            "title": entry.title,
            "summary": entry.summary ?? "",
            "transcript": entry.transcript ?? "",
            "question": question,
            "history": history
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["answer"] as? String) ?? "No answer."
    }

    // MARK: - Core GET

    /// True for a cancelled request/task — never an error worth showing.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func getJSON<T: Decodable>(_ url: URL, as: T.Type, timeout: TimeInterval = 30) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout            // reads must fail fast and be retried, never hang for minutes
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let data = try await send(req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// A batch's real progress from its queue rows: done / failed / skipped (and
/// any other finished state) count 100, pending 0, processing its own
/// `progress` (5 when the worker hasn't reported one yet).
struct BatchProgress {
    var total = 0, done = 0, failed = 0, skipped = 0, active = 0
    var percent: Double = 0
    /// Where the bar may glide to before the next poll: every running row at
    /// its next server milestone − 2 (never past it), averaged like `percent`.
    var ceiling: Double = 0
    /// Typical time (s) the current row's stage takes — how fast to glide.
    var tau: Double = 8
    var stage = ""

    init(rows: [CorpusAPI.QueueRow], expected: Int) {
        var sum = 0.0
        var capSum = 0.0
        var current: CorpusAPI.QueueRow? = nil
        for r in rows {
            switch r.status {
            case "pending":
                active += 1
            case "processing":
                active += 1
                let p = Double(min(max(r.progress ?? 5, 0), 100))
                sum += p
                capSum += ProgressMilestones.ceiling(after: p)
                if current == nil { current = r }
            case "done":    done += 1; sum += 100; capSum += 100
            case "failed":  failed += 1; sum += 100; capSum += 100
            case "skipped": skipped += 1; sum += 100; capSum += 100
            default:        sum += 100; capSum += 100
            }
        }
        total = max(rows.count, expected)
        // Rows not created yet (still being queued) count as pending.
        percent = total > 0 ? sum / Double(total) : 0
        ceiling = total > 0 ? max(percent, capSum / Double(total)) : 0
        if let c = current {
            tau = ProgressMilestones.stageSeconds(at: Double(c.progress ?? 5))
            if let s = c.stage, !s.isEmpty { stage = s }
            else if let t = c.title, !t.isEmpty { stage = "Now: " + t }
        }
    }

    /// 1-based index of the item being worked on ("Processing 3 of 12").
    var position: Int { min(total, max(1, total - active + 1)) }
}

enum CorpusAPIError: LocalizedError {
    case http(Int, String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(160))"
        case .message(let m):     return m
        }
    }
}
