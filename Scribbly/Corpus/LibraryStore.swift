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

    /// What the Library feed currently shows. Changing it reloads from the server.
    struct Query: Equatable {
        var type: String? = nil          // scribbly_entries.type, nil = all
        var sort: CorpusAPI.EntrySort = .newest
        var search = ""
    }
    @Published private(set) var query = Query()
    /// True when a search returned the maximum number of matches (there may be more).
    @Published var searchCapped = false

    /// Bumped on every reset so a slow page from an old query is dropped.
    private var generation = 0
    private let pageSize = 100

    /// The entry types the Library filters by, in chip order.
    static let filterTypes: [(chip: String, type: String)] = [
        ("Voice", "Voice Note"), ("YouTube", "YouTube"), ("Instagram", "Instagram"), ("Notes", "Note")
    ]

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
                let r = try await CorpusAPI.recentEntries(limit: 6)
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

    /// Drops what's loaded and fetches the first page of the current query.
    func reloadEntries() async {
        generation += 1
        entries = []
        reachedEnd = false
        searchCapped = false
        loadingEntries = false
        error = nil
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !loadingEntries, !reachedEnd else { return }
        let gen = generation
        let q = query
        let after = entries.last
        loadingEntries = true
        let result: Result<[Entry], Error>
        do {
            if q.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .success(try await CorpusAPI.entries(type: q.type, sort: q.sort, after: after, limit: pageSize))
            } else {
                result = .success(try await CorpusAPI.searchEntries(q.search, type: q.type, sort: q.sort))
            }
        } catch {
            result = .failure(error)
        }
        // A newer query took over while this was in flight; it owns the state now.
        guard gen == generation else { return }
        loadingEntries = false
        switch result {
        case .success(let page):
            entries.append(contentsOf: page)
            if !q.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reachedEnd = true                     // search returns its matches in one go
                searchCapped = page.count >= CorpusAPI.entrySearchLimit
            } else if page.count < pageSize {
                reachedEnd = true
            }
        case .failure(let e):
            if (e as? URLError)?.code == .cancelled { return }
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
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pull-to-refresh: reloads the current filter/sort/search, collections and counts.
    func refreshAll() async {
        await reloadEntries()
        await reloadCollections()
        await loadCounts()
        await loadTypeCounts()
    }
}
