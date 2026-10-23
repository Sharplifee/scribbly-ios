import Foundation

/// One ingested item — video, recording, audio file, or podcast episode.
struct Entry: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let type: String?
    let tags: String?
    let summary: String?
    let transcript: String?
    let date: String?
    let collection_id: String?
    let created_at: String?
    /// Only present on full rows (`select=*`); list rows leave it nil.
    var notion_url: String? = nil
    /// Length of a recording / audio file in seconds (nil when unknown).
    var duration_seconds: Double? = nil

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

    /// The day it was saved, in the phone's time zone ("Oct 23, 2026"), from
    /// created_at — the stored `date` text is only a fallback (older rows wrote
    /// the UTC day there).
    var displayDate: String {
        if let d = EntryDates.parse(created_at) { return EntryDates.display.string(from: d) }
        return date ?? ""
    }

    /// Where this entry came from, if it has a link: the YouTube video for
    /// yt_<videoId> ids (also scribbly_yt_ / batches_yt_ mirror ids), else the
    /// stored link (notion_url holds the original URL for YouTube/Instagram rows).
    var sourceLink: URL? {
        var core = id
        for p in ["scribbly_", "batches_", "notes_"] where core.hasPrefix(p) { core = String(core.dropFirst(p.count)) }
        if core.hasPrefix("yt_") {
            let vid = String(core.dropFirst(3))
            if vid.count == 11, let u = URL(string: "https://www.youtube.com/watch?v=" + vid) { return u }
        }
        if let n = notion_url?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty,
           let u = URL(string: n), let s = u.scheme?.lowercased(), s == "http" || s == "https" { return u }
        return nil
    }

    // MARK: Display helpers (rows + detail header)

    var isVoice: Bool {
        let t = (type ?? "").lowercased()
        return t.contains("voice") || t.contains("audio") || id.hasPrefix("voice_")
    }

    /// The place a recording was made: the part after the last " · " in its
    /// title ("Topic · University Place, Orem" → "University Place, Orem").
    var placeFromTitle: String? {
        let parts = title.components(separatedBy: " · ")
        guard parts.count >= 2, let last = parts.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty else { return nil }
        return last
    }

    /// "Oct 23, 5:12 AM" in the phone's time zone (year added when not this year).
    var recordedAtText: String? {
        guard let d = EntryDates.parse(created_at) else { return nil }
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        return (sameYear ? EntryDates.dayTime : EntryDates.dayTimeYear).string(from: d)
    }

    /// "4m 12s", "37s", "1h 4m".
    var durationText: String? {
        guard let s = duration_seconds, s.isFinite, s > 0 else { return nil }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// Title line: "Creator — Title" unless the title already names the creator.
    func displayTitle(creator: String?) -> String {
        guard let c = creator?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return title }
        if CreatorName.title(title, mentions: c) { return title }
        return c + " — " + title
    }

    /// The discreet line under the title.
    /// Voice: "Voice note · Oct 23, 5:12 AM · 4m 12s · University Place, Orem".
    /// Others: "YouTube · Jordan Peterson · Oct 23, 2026".
    func metaLine(creator: String?) -> String {
        var parts: [String] = []
        if isVoice {
            parts.append("Recording")
            parts.append(recordedAtText ?? displayDate)
            if let d = durationText { parts.append(d) }
            if let p = placeFromTitle { parts.append(p) }
        } else {
            parts.append(displayType)
            if let c = creator, !c.isEmpty { parts.append(c) }
            parts.append(displayDate)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Creator (channel) names: which ones are real creators, and a normalized key
/// so "The Jordan B. Peterson" and "Jordan Peterson" are one creator.
enum CreatorName {
    /// Holding collections whose channel is not a creator ("filing" buckets).
    static let filing: Set<String> = ["unsorted", "mixed creators", "links", "imported", "unknown", "unassigned"]
    /// Channels that are never shown as a creator on an entry.
    static let notCreators: Set<String> = filing.union([
        "voice memos", "recordings", "processing...", "failed", "uncategorized", "duplicate — already ingested", "filing…"
    ])

    static func isFiling(_ s: String?) -> Bool {
        filing.contains((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isCreator(_ s: String?) -> Bool {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !t.isEmpty && !notCreators.contains(t) && !t.hasPrefix("incomplete —")
    }

    /// trim · lowercase · no accents/punctuation · no leading "the " · middle
    /// initials dropped ("jordan b peterson" → "jordan peterson").
    static func normalizedKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        t = t.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        var words = t.split(separator: " ").map(String.init)
        if words.count >= 3 { words = words.filter { $0.count > 1 } }
        let key = words.joined(separator: " ")
        return key.isEmpty ? s.lowercased() : key
    }

    /// Whether a title already names the creator (case-insensitive; "The " ignored).
    static func title(_ title: String, mentions creator: String) -> Bool {
        if title.range(of: creator, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        if creator.lowercased().hasPrefix("the ") {
            let bare = String(creator.dropFirst(4))
            if !bare.isEmpty, title.range(of: bare, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        }
        let t = " " + normalizedKey(title) + " ", c = " " + normalizedKey(creator) + " "
        return t.contains(c)
    }
}

/// Date handling for entries: Postgres timestamptz in, local "MMM d, yyyy" out.
enum EntryDates {
    /// "Oct 23, 2026" in the current time zone.
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    /// "Oct 23, 5:12 AM" — when a recording was made, phone's time zone.
    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
    /// "Oct 23, 2025, 5:12 AM" for recordings from another year.
    static let dayTimeYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy, h:mm a"
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// "2026-10-01T06:00:00Z" — a local-time boundary as the UTC instant PostgREST compares against.
    static func utc(_ d: Date) -> String { iso.string(from: d) }

    /// Parses "2026-10-14T17:33:51.25486+00:00" (any number of fractional digits).
    static func parse(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        return iso.date(from: s)
    }
}

/// One ingest batch.
struct Collection: Decodable, Identifiable, Hashable {
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

    /// The creator this batch is from, or nil for holding buckets
    /// (Unsorted / Mixed Creators / Links / Imported / Voice Memos).
    var creatorName: String? {
        guard let ch = channel?.trimmingCharacters(in: .whitespacesAndNewlines), CreatorName.isCreator(ch) else { return nil }
        return ch
    }

    /// Batch-of-links collections are named "<Creator> — Links <date>" by the ingest; show the creator.
    var displayName: String {
        if let r = name.range(of: " — Links ") { return String(name[..<r.lowerBound]) }
        return name
    }
}

/// A runtime cluster of collections that share a channel.
struct Group: Identifiable, Hashable {
    /// The one row that collects every holding bucket (Unsorted, Mixed Creators, Links, Imported).
    static let filingName = "Filing…"
    var channel: String
    var collections: [Collection]
    var totalVideos: Int
    var id: String { channel }
    var batchCount: Int { collections.count }
    var isFiling: Bool { channel == Group.filingName }
    var badgeRange: String {
        let nums = collections.compactMap(\.batch_number).sorted()
        guard let lo = nums.first, let hi = nums.last else { return "" }
        return lo == hi ? "#\(lo)" : "#\(lo)–#\(hi)"
    }
}

/// A search result from master_corpus.
struct SearchHit: Decodable, Identifiable, Hashable {
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

// MARK: - Transcript clean-up

/// Speech-to-text sometimes "hears" stock Japanese/Chinese/Korean phrases in
/// silence or background noise (the classic Whisper hallucination:
/// "ご視聴ありがとうございました" = "thanks for watching"). This library is
/// English-only, so any run of CJK/kana/hangul script is dropped before display,
/// export, Send-to, or word counts.
enum TranscriptCleaner {
    private static let cjkRun =
        "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\u3000-\\u303F\\uFF00-\\uFFEF]" +
        "[\\s\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\u3000-\\u303F\\uFF00-\\uFFEF0-9]*"

    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: cjkRun, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " ([.,!?;:])", with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Entry {
    /// The transcript with foreign-script hallucinations removed.
    var cleanTranscript: String? { transcript.map(TranscriptCleaner.clean) }
}
