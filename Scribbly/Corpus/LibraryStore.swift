import Foundation
import SwiftUI

/// Backing store for the five Library sub-tabs. Loads lazily, paginates the
/// entries feed, and derives groups from collections in memory.
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
    @Published var groupCount = 0

    @Published var loadingEntries = false
    @Published var loadingCollections = false
    @Published var reachedEnd = false
    @Published var error: String?

    private var offset = 0
    private let pageSize = 100

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

    func loadFirstPageIfNeeded() async {
        guard entries.isEmpty else { return }
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !loadingEntries, !reachedEnd else { return }
        loadingEntries = true
        defer { loadingEntries = false }
        do {
            let page = try await CorpusAPI.entries(limit: pageSize, offset: offset)
            entries.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { reachedEnd = true }
        } catch {
            self.error = error.localizedDescription
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
            groupCount = groups.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshAll() async {
        offset = 0; reachedEnd = false; entries = []
        await loadNextPage()
        await reloadCollections()
        await loadCounts()
    }
}
