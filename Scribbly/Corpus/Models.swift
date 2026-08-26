import Foundation

/// One ingested item — video, recording, audio file, or podcast episode.
struct Entry: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let type: String?
    let tags: String?
    let summary: String?
    let transcript: String?
    let date: String?
    let collection_id: String?
    let created_at: String?

    var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Just the summary paragraphs, without the assembled "Key Points/Topics" tail.
    var summaryLead: String {
        guard let s = summary else { return "" }
        if let r = s.range(of: "\n\nKey Points:") { return String(s[..<r.lowerBound]) }
        return s
    }
    var displayType: String { type ?? "Note" }
}

/// One ingest batch.
struct Collection: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let channel: String?
    let type: String?
    let source_url: String?
    let total_videos: Int?
    let saved_videos: Int?
    let skipped_videos: Int?
    let failed_videos: Int?
    let batch_number: Int?
    let created_at: String?

    /// The group this batch belongs to: channel, else the pre-dash name segment.
    var groupKey: String {
        if let ch = channel, !ch.isEmpty,
           !["Processing...", "Failed", "Uncategorized", "Duplicate — Already Ingested"].contains(ch),
           !ch.hasPrefix("Incomplete —") {
            return ch
        }
        if name.contains(" — ") { return name.components(separatedBy: " — ").first!.trimmingCharacters(in: .whitespaces) }
        if name.contains(" - ")  { return name.components(separatedBy: " - ").first!.trimmingCharacters(in: .whitespaces) }
        return name
    }
    var badge: String { batch_number.map { "#\($0)" } ?? "—" }
}

/// A runtime cluster of collections that share a channel.
struct Group: Identifiable, Equatable {
    var channel: String
    var collections: [Collection]
    var totalVideos: Int
    var id: String { channel }
    var batchCount: Int { collections.count }
    var badgeRange: String {
        let nums = collections.compactMap(\.batch_number).sorted()
        guard let lo = nums.first, let hi = nums.last else { return "" }
        return lo == hi ? "#\(lo)" : "#\(lo)–#\(hi)"
    }
}

/// A search result from master_corpus.
struct SearchHit: Decodable, Identifiable {
    let id: String
    let title: String
    let type: String?
    let tags: String?
    let summary: String?
    let date: String?
    let source_url: String?
    let origin: String?
    let collection: String?

    /// 80-before / 160-after window around the first hit, like the web app.
    func snippet(for query: String) -> String {
        let text = summary ?? ""
        guard !query.isEmpty,
              let r = text.range(of: query, options: .caseInsensitive) else {
            return String(text.prefix(200))
        }
        let lower = text.index(r.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(r.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
        let lead = lower > text.startIndex ? "…" : ""
        let tail = upper < text.endIndex ? "…" : ""
        return lead + text[lower..<upper] + tail
    }
}

/// Client-side weighted ranking, ported from the web fallback:
/// title 10, tags 6, summary 3. (Transcript isn't fetched in search results.)
enum Ranker {
    static func score(_ hit: SearchHit, terms: [String]) -> Int {
        let fields: [(String, Int)] = [
            (hit.title, 10), (hit.tags ?? "", 6), (hit.summary ?? "", 3)
        ]
        var total = 0
        for term in terms {
            let t = term.lowercased()
            guard !t.isEmpty else { continue }
            for (text, weight) in fields {
                total += text.lowercased().components(separatedBy: t).count.advanced(by: -1) * weight
            }
        }
        return total
    }
}
