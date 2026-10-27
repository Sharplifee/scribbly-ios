import Foundation
import SwiftUI

/// Backing store for the Library and its sibling pages. The Library feed is
/// filtered, sorted, searched and paginated by the server (keyset cursor), so
/// filters and search cover the whole library, not just the rows loaded so far.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var entries: [Entry] = []
    /// Home → Recent: served from disk instantly, then refreshed with a tiny request.
    @Published var recent: [Entry] = []
    @Published var recentError: String?
    @Published var collections: [Collection] = []
    @Published var groups: [Group] = []

    @Published var libraryCount = 0
    @Published var collectionCount = 0
    /// Rows per entry type ("Voice Note", "YouTube", …); a type missing here hasn't been counted yet.
    @Published var typeCounts: [String: Int] = [:]

    @Published var loadingEntries = false
    @Published var loadingCollections = false
    @Published var reachedEnd = false
    @Published var error: String?
    @Published var collectionsError: String?

    /// What the Library feed currently shows. Changing it reloads from the server.
    struct Query: Equatable {
        var type: String? = nil          // scribbly_entries.type, nil = all
        var sort: CorpusAPI.EntrySort = .newest
        var search = ""
        var range: DateRange = .any
        /// A creator (Groups channel) and the ids of its collections.
        var creator: String? = nil
        var creatorIDs: [String] = []

        /// Anything narrower than "everything, newest first".
        var hasFilters: Bool { type != nil || range != .any || creator != nil || sort.isDuration }
        var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    @Published private(set) var query = Query()
    /// True when a search returned the maximum number of matches (there may be more).
    @Published var searchCapped = false

    /// The loaded rows, grouped for display: time sections (Today, Yesterday,
    /// This week, This month, then by month) for Newest/Oldest, letters for
    /// A–Z, one untitled section for Longest/Shortest. Appended page by page.
    @Published private(set) var sections: [EntrySection] = []
    /// Exact server counts per time section (by section id), filled in as each appears.
    @Published var sectionCounts: [String: Int] = [:]
    /// Exact number of entries matching the current filters (nil = no filters / not counted yet).
    @Published var matchCount: Int?
    /// Voice notes this month (count + total recorded seconds) for the Voice summary card.
    @Published var voiceMonth: VoiceMonth?
    struct VoiceMonth { let count: Int; let seconds: Double; let allTime: Int }

    /// "Now" for the current section boundaries; reset with each new list.
    private var buckets = TimeBuckets()

    /// Bumped on every reset so a slow page from an old query is dropped.
    private var generation = 0
    private let pageSize = 100

    /// The entry types the Library filters by, in chip order.
    static let filterTypes: [(chip: String, type: String)] = [
        ("Recordings", "Voice Note"), ("YouTube", "YouTube"), ("Instagram", "Instagram"), ("Notes", "Note")
    ]

    /// The server filters a query adds beyond type/search/sort: its date range
    /// (local midnight → UTC instant), its creator's collections, and
    /// "has a length" for Longest/Shortest. Type is included too.
    static func filters(for q: Query, now: Date = Date()) -> [URLQueryItem] {
        var f: [URLQueryItem] = []
        if let t = q.type { f.append(URLQueryItem(name: "type", value: "eq.\(t)")) }
        if let start = q.range.start(now: now) {
            f.append(URLQueryItem(name: "created_at", value: "gte.\(EntryDates.utc(start))"))
        }
        if q.creator != nil {
            // A creator with no collections matches nothing (never "everything").
            let ids = q.creatorIDs.isEmpty ? ["-"] : q.creatorIDs
            let list = ids.map { id in CorpusAPI.quoted(id) }.joined(separator: ",")
            f.append(URLQueryItem(name: "collection_id", value: "in.(\(list))"))
        }
        if q.sort.isDuration { f.append(URLQueryItem(name: "duration_seconds", value: "gt.0")) }
        return f
    }

    private static var recentCacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent.json")
    }

    init() {
        libraryCount = UserDefaults.standard.integer(forKey: "libraryCount")
        collectionCount = UserDefaults.standard.integer(forKey: "collectionCount")
        if let d = try? Data(contentsOf: Self.recentCacheURL), let cached = try? JSONDecoder().decode([Entry].self, from: d) {
            recent = cached
        }
    }

    /// Fast path for Home: one small request, retried once, cached on success.
    func loadRecent() async {
        for attempt in 0..<2 {
            do {
                let r = try await CorpusAPI.recentEntries(limit: 20)
                recent = r; recentError = nil
                if libraryCount == 0 { await loadCounts() }
                if let d = try? JSONEncoder().encode(r) { try? d.write(to: Self.recentCacheURL, options: .atomic) }
                return
            } catch {
                recentError = error.localizedDescription
                if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
    }

    /// Counts are cached on disk so a bad connection shows the last known
    /// number instead of "0"; a failed request never overwrites a good value.
    func loadCounts() async {
        async let lib = try? CorpusAPI.count(table: "scribbly_entries")
        async let col = try? CorpusAPI.count(table: "scribbly_collections")
        if let n = await lib, n > 0 { libraryCount = n; UserDefaults.standard.set(n, forKey: "libraryCount") }
        if let n = await col, n > 0 { collectionCount = n; UserDefaults.standard.set(n, forKey: "collectionCount") }
    }

    /// One exact count per Library type, so chips with no entries can be hidden.
    func loadTypeCounts() async {
        for t in Self.filterTypes {
            if let n = try? await CorpusAPI.count(table: "scribbly_entries", filters: [URLQueryItem(name: "type", value: "eq.\(t.type)")]) {
                typeCounts[t.type] = n
            }
        }
    }

    func loadFirstPageIfNeeded() async {
        guard entries.isEmpty, !loadingEntries else { return }
        await reloadEntries()
    }

    /// Switches the feed to a new filter / sort / search and loads its first page.
    func setQuery(_ q: Query) async {
        guard q != query else { return }
        query = q
        await reloadEntries()
    }

    /// Drops what's loaded and fetches the first page of the current query
    /// (used when the filter / sort / search changes — a different list).
    func reloadEntries() async {
        generation += 1
        entries = []
        sections = []
        sectionCounts = [:]
        buckets = TimeBuckets()
        reachedEnd = false
        searchCapped = false
        loadingEntries = false
        error = nil
        countMatches()
        await loadNextPage()
    }

    /// The exact size of a filtered list ("342 entries"), counted on the server.
    private func countMatches() {
        let q = query
        let gen = generation
        matchCount = nil
        guard q.hasFilters, !q.isSearching else { return }
        let f = Self.filters(for: q, now: buckets.now)
        Task { @MainActor [weak self] in
            guard let n = try? await CorpusAPI.count(table: "scribbly_entries", filters: f) else { return }
            guard let self, self.generation == gen else { return }
            self.matchCount = n
        }
    }

    /// Voice notes this month: how many and how long, plus the all-time count.
    func loadVoiceMonth() async {
        guard let start = DateRange.month.start() else { return }
        if typeCounts["Voice Note"] == nil { await loadTypeCounts() }
        guard let stats = try? await CorpusAPI.voiceStats(since: start) else { return }
        voiceMonth = VoiceMonth(count: stats.count, seconds: stats.seconds,
                                allTime: typeCounts["Voice Note"] ?? 0)
    }

    // MARK: Sections

    private func sectionInfo(for e: Entry, sort: CorpusAPI.EntrySort) -> TimeBuckets.Bucket {
        switch sort {
        case .newest, .oldest:
            guard let d = EntryDates.parse(e.created_at) else {
                return TimeBuckets.Bucket(key: "undated", title: "Undated", start: nil, end: nil)
            }
            return buckets.bucket(for: d)
        case .title:
            let first = e.title.trimmingCharacters(in: .whitespacesAndNewlines).first
            let letter = first.map { c in String(c).uppercased() } ?? "#"
            let key = (letter.count == 1 && letter >= "A" && letter <= "Z") ? letter : "#"
            return TimeBuckets.Bucket(key: "l:" + key, title: key, start: nil, end: nil)
        case .longest, .shortest:
            return TimeBuckets.Bucket(key: "all", title: "", start: nil, end: nil)
        }
    }

    /// Files a page of rows into sections (new sections are appended in the
    /// order they first appear) and counts any new time sections on the server.
    private func appendSections(_ page: [Entry], query q: Query, gen: Int) {
        guard !q.isSearching, !page.isEmpty else { return }
        var secs = sections
        var fresh: [EntrySection] = []
        for e in page {
            let b = sectionInfo(for: e, sort: q.sort)
            if let last = secs.indices.last, secs[last].id == b.key {
                secs[last].entries.append(e)
            } else if let i = secs.firstIndex(where: { s in s.id == b.key }) {
                secs[i].entries.append(e)
            } else {
                let s = EntrySection(id: b.key, title: b.title, start: b.start, end: b.end, entries: [e])
                secs.append(s)
                fresh.append(s)
            }
        }
        sections = secs
        countSections(fresh, query: q, gen: gen)
    }

    private func countSections(_ new: [EntrySection], query q: Query, gen: Int) {
        guard q.sort.isByDate else { return }
        let base = Self.filters(for: q, now: buckets.now)
        for s in new {
            guard let start = s.start else { continue }
            var f = base
            f.append(URLQueryItem(name: "created_at", value: "gte.\(EntryDates.utc(start))"))
            if let end = s.end { f.append(URLQueryItem(name: "created_at", value: "lt.\(EntryDates.utc(end))")) }
            let key = s.id
            Task { @MainActor [weak self] in
                guard let n = try? await CorpusAPI.count(table: "scribbly_entries", filters: f) else { return }
                guard let self, self.generation == gen else { return }
                self.sectionCounts[key] = n
            }
        }
    }

    /// Pull-to-refresh for the feed: keeps the rows on screen and swaps in the
    /// fresh first page when it arrives. A failure (or a cancelled request)
    /// never blanks the list; an error is shown only when there's nothing to show.
    func refreshEntries() async {
        generation += 1
        let gen = generation
        let q = query
        let searchText = q.search.trimmingCharacters(in: .whitespacesAndNewlines)
        loadingEntries = true
        do {
            let page: [Entry]
            let f = Self.filters(for: q, now: buckets.now)
            if searchText.isEmpty {
                page = try await CorpusAPI.entries(sort: q.sort, after: nil, limit: pageSize, filters: f)
            } else {
                page = try await CorpusAPI.searchEntries(q.search, type: nil, sort: q.sort, filters: f)
            }
            guard gen == generation else { return }
            entries = page
            sections = []
            appendSections(page, query: q, gen: gen)
            error = nil
            if searchText.isEmpty {
                reachedEnd = page.count < pageSize
                searchCapped = false
            } else {
                reachedEnd = true
                searchCapped = page.count >= CorpusAPI.entrySearchLimit
            }
        } catch {
            guard gen == generation else { return }
            if !CorpusAPI.isCancellation(error) && entries.isEmpty {
                self.error = error.localizedDescription
            }
        }
        loadingEntries = false
    }

    func loadNextPage() async {
        guard !loadingEntries, !reachedEnd else { return }
        let gen = generation
        let q = query
        let after = entries.last
        loadingEntries = true
        let result: Result<[Entry], Error>
        let f = Self.filters(for: q, now: buckets.now)
        do {
            if q.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .success(try await CorpusAPI.entries(sort: q.sort, after: after, limit: pageSize, filters: f))
            } else {
                result = .success(try await CorpusAPI.searchEntries(q.search, type: nil, sort: q.sort, filters: f))
            }
        } catch {
            result = .failure(error)
        }
        // A newer query took over while this was in flight; it owns the state now.
        guard gen == generation else { return }
        loadingEntries = false
        switch result {
        case .success(let page):
            error = nil
            entries.append(contentsOf: page)
            appendSections(page, query: q, gen: gen)
            if !q.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reachedEnd = true                     // search returns its matches in one go
                searchCapped = page.count >= CorpusAPI.entrySearchLimit
            } else if page.count < pageSize {
                reachedEnd = true
            }
        case .failure(let e):
            // Cancelled requests (pull-to-refresh, leaving the page) are not errors.
            if CorpusAPI.isCancellation(e) { return }
            self.error = e.localizedDescription
        }
    }

    func loadCollectionsIfNeeded() async {
        guard collections.isEmpty else { return }
        await reloadCollections()
    }

    func reloadCollections() async {
        loadingCollections = true
        defer { loadingCollections = false }
        do {
            let cols = try await CorpusAPI.collections()
            collections = cols
            groups = CorpusAPI.groups(from: cols)
            collectionCount = cols.count
            CreatorDirectory.shared.update(cols)
            collectionsError = nil
        } catch {
            // Never surfaces on the Library feed; a cancelled refresh isn't an error at all.
            if !CorpusAPI.isCancellation(error) { collectionsError = error.localizedDescription }
        }
    }

    /// Pull-to-refresh: refreshes the current filter/sort/search in place, then
    /// collections and counts. Runs in its own task so the refresh control
    /// going away can't cancel it half-way (that used to blank the list and
    /// show "cancelled").
    func refreshAll() async {
        let work = Task { @MainActor in
            await self.refreshEntries()
            await self.reloadCollections()
            await self.loadCounts()
            await self.loadTypeCounts()
        }
        await work.value
    }
}

/// One block of the Library feed ("Today", "September 2026", "A", …).
struct EntrySection: Identifiable {
    let id: String
    let title: String
    /// Time sections: the [start, end) window, for an exact server count.
    var start: Date?
    var end: Date?
    var entries: [Entry]
}

/// Library date filters, as local calendar windows ending now.
enum DateRange: String, CaseIterable, Identifiable {
    case any = "Any time", today = "Today", week = "This week", month = "This month", year = "This year"
    var id: String { rawValue }

    /// Local midnight at the start of the window (nil = no limit).
    func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .any:   return nil
        case .today: return calendar.startOfDay(for: now)
        case .week:  return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return calendar.dateInterval(of: .month, for: now)?.start
        case .year:  return calendar.dateInterval(of: .year, for: now)?.start
        }
    }
}

/// Today · Yesterday · This week · This month · then one section per month.
/// The windows never overlap, so each section's server count is exact.
struct TimeBuckets {
    struct Bucket {
        let key: String
        let title: String
        let start: Date?
        let end: Date?
    }

    let now: Date
    private let calendar: Calendar
    private let today: Date
    private let yesterday: Date
    private let week: Date
    private let month: Date
    /// Anything older than this is grouped by calendar month.
    private let cutoff: Date

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    init(now: Date = Date(), calendar cal: Calendar = .current) {
        self.now = now
        calendar = cal
        let t = cal.startOfDay(for: now)
        today = t
        yesterday = cal.date(byAdding: .day, value: -1, to: t) ?? t
        week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? t
        month = cal.dateInterval(of: .month, for: now)?.start ?? t
        cutoff = min(yesterday, min(week, month))
    }

    func bucket(for d: Date) -> Bucket {
        if d >= today { return Bucket(key: "today", title: "Today", start: today, end: nil) }
        if d >= yesterday { return Bucket(key: "yesterday", title: "Yesterday", start: yesterday, end: today) }
        if week < yesterday && d >= week {
            return Bucket(key: "week", title: "This week", start: week, end: yesterday)
        }
        let recent = min(week, yesterday)
        if month < recent && d >= month {
            return Bucket(key: "month", title: "This month", start: month, end: recent)
        }
        let interval = calendar.dateInterval(of: .month, for: d)
        let start = interval?.start ?? d
        let end = min(interval?.end ?? cutoff, cutoff)
        let title = Self.monthTitle.string(from: start)
        return Bucket(key: "m:" + title, title: title, start: start, end: end)
    }
}

/// Collection id → collection, loaded once and shared, so every row can name
/// its creator without another request.
@MainActor
final class CreatorDirectory: ObservableObject {
    static let shared = CreatorDirectory()
    @Published private(set) var byID: [String: Collection] = [:]
    private var loading = false

    func update(_ cols: [Collection]) {
        byID = Dictionary(cols.map { c in (c.id, c) }, uniquingKeysWith: { a, _ in a })
    }

    func loadIfNeeded() async {
        guard byID.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        if let cols = try? await CorpusAPI.collections() { update(cols) }
    }

    /// The creator to show for an entry: its collection's channel, for
    /// non-voice, non-note entries in a real creator's collection.
    func creator(for e: Entry) -> String? {
        guard !e.isVoice, e.displayType != "Note", let cid = e.collection_id else { return nil }
        return byID[cid]?.creatorName
    }
}
