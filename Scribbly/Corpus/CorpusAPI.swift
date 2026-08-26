import Foundation

/// Direct Supabase REST client for the read paths, plus the app's own API
/// routes for anything that writes (dedupe, queue, collection creation all
/// live server-side and must not be reimplemented on-device).
///
/// Field names, filters and thresholds here are taken from the live blueprint,
/// not from memory. Notable corrections baked in vs the web app:
///   • Library paginates (web hard-caps at 5000 against 7,975 rows).
///   • Sorting is by created_at, never the text `date` column.
///   • saved_videos is never trusted — collection counts derive from entries.
enum CorpusAPI {

    static let supabaseURL = "https://lbvaosyfikkpvcwksiph.supabase.co"
    static let restBase = "\(supabaseURL)/rest/v1"
    static let appBase  = "https://getscribbly.vercel.app"

    /// Anon key — client-scoped, same key the web app ships in plain JS.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4"

    private static var restHeaders: [String: String] {
        ["apikey": anonKey, "Authorization": "Bearer \(anonKey)"]
    }

    // MARK: - Entries (Library)

    /// One page of the library, newest first. `limit`/`offset` give real
    /// pagination — the fix for the web app's silent 5000-row truncation.
    static func entries(limit: Int = 100, offset: Int = 0) async throws -> [Entry] {
        var c = URLComponents(string: "\(restBase)/scribbly_entries")!
        c.queryItems = [
            .init(name: "select", value: "id,title,type,tags,summary,date,created_at,collection_id"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset))
        ]
        return try await getJSON(c.url!, as: [Entry].self)
    }

    /// Full single entry for the detail view (includes transcript).
    static func entry(id: String) async throws -> Entry? {
        var c = URLComponents(string: "\(restBase)/scribbly_entries")!
        c.queryItems = [
            .init(name: "id", value: "eq.\(id)"),
            .init(name: "select", value: "*")
        ]
        return try await getJSON(c.url!, as: [Entry].self).first
    }

    /// Entries belonging to one collection, in ingest order.
    static func entries(inCollection id: String) async throws -> [Entry] {
        var c = URLComponents(string: "\(restBase)/scribbly_entries")!
        c.queryItems = [
            .init(name: "collection_id", value: "eq.\(id)"),
            .init(name: "select", value: "id,title,type,tags,date,created_at,collection_id"),
            .init(name: "order", value: "created_at.asc")
        ]
        return try await getJSON(c.url!, as: [Entry].self)
    }

    // MARK: - Collections & Groups

    static func collections() async throws -> [Collection] {
        var c = URLComponents(string: "\(restBase)/scribbly_collections")!
        c.queryItems = [
            .init(name: "select", value: "*"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: "500")
        ]
        return try await getJSON(c.url!, as: [Collection].self)
    }

    /// Groups are computed, not stored: GROUP BY channel (falling back to the
    /// name's pre-dash segment), summed by real saved counts, sorted desc.
    static func groups(from collections: [Collection]) -> [Group] {
        var map: [String: Group] = [:]
        for col in collections {
            let key = col.groupKey
            var g = map[key] ?? Group(channel: key, collections: [], totalVideos: 0)
            g.collections.append(col)
            g.totalVideos += col.saved_videos ?? 0
            map[key] = g
        }
        return map.values.sorted { $0.totalVideos > $1.totalVideos }
    }

    // MARK: - Query (search)

    /// Searches master_corpus. Uses the maintained full-text index
    /// (search_doc) rather than the web app's unranked ILIKE scan, ordered by
    /// the real normalized_date, not the lexicographic text date.
    static func search(_ query: String, limit: Int = 100) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = URLComponents(string: "\(restBase)/master_corpus")!
        var items: [URLQueryItem] = [
            .init(name: "select", value: "id,title,type,tags,summary,date,source_url,origin,collection,normalized_date"),
            .init(name: "order", value: "normalized_date.desc.nullslast"),
            .init(name: "limit", value: String(limit))
        ]
        if !trimmed.isEmpty {
            // PostgREST full-text against the GIN-indexed tsvector column.
            items.append(.init(name: "search_doc", value: "fts(english).\(trimmed)"))
        }
        c.queryItems = items
        do {
            return try await getJSON(c.url!, as: [SearchHit].self)
        } catch {
            // Fallback: the unranked substring path, still better than nothing
            // if a query can't be parsed as a tsquery.
            return try await searchILIKE(trimmed, limit: limit)
        }
    }

    private static func searchILIKE(_ q: String, limit: Int) async throws -> [SearchHit] {
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        var c = URLComponents(string: "\(restBase)/master_corpus")!
        c.queryItems = [
            .init(name: "select", value: "id,title,type,tags,summary,date,source_url,origin,collection,normalized_date"),
            .init(name: "or", value: "(title.ilike.*\(enc)*,summary.ilike.*\(enc)*,tags.ilike.*\(enc)*)"),
            .init(name: "order", value: "normalized_date.desc.nullslast"),
            .init(name: "limit", value: String(limit))
        ]
        return try await getJSON(c.url!, as: [SearchHit].self)
    }

    // MARK: - Counts (tab bar badges)

    /// Exact row count via a HEAD-style request reading the content-range header.
    static func count(table: String) async throws -> Int {
        var c = URLComponents(string: "\(restBase)/\(table)")!
        c.queryItems = [.init(name: "select", value: "id")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "HEAD"
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "content-range"),
              let total = range.split(separator: "/").last,
              let n = Int(total) else { return 0 }
        return n
    }

    // MARK: - Mutations that are safe to do directly

    static func delete(entryID: String) async throws {
        var c = URLComponents(string: "\(restBase)/scribbly_entries")!
        c.queryItems = [.init(name: "id", value: "eq.\(entryID)")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "DELETE"
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        _ = try await URLSession.shared.data(for: req)
    }

    static func update(entryID: String, title: String?, tags: String?) async throws {
        var c = URLComponents(string: "\(restBase)/scribbly_entries")!
        c.queryItems = [.init(name: "id", value: "eq.\(entryID)")]
        var body: [String: String] = [:]
        if let title { body["title"] = title }
        if let tags { body["tags"] = tags }
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PATCH"
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await URLSession.shared.data(for: req)
    }

    /// Re-group: point selected collections at a new channel. Groups recompute.
    static func setChannel(collectionIDs: [String], to channel: String) async throws {
        for id in collectionIDs {
            var c = URLComponents(string: "\(restBase)/scribbly_collections")!
            c.queryItems = [.init(name: "id", value: "eq.\(id)")]
            var req = URLRequest(url: c.url!)
            req.httpMethod = "PATCH"
            restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["channel": channel])
            _ = try await URLSession.shared.data(for: req)
        }
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
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["answer"] as? String) ?? "No answer."
    }

    // MARK: - Core GET

    private static func getJSON<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw CorpusAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum CorpusAPIError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .http(let s, let b): return "HTTP \(s): \(b.prefix(160))" }
    }
}
