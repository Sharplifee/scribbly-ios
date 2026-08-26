import Foundation
import SwiftUI

/// Backing store for the five Library sub-tabs. Loads lazily, paginates the
/// entries feed, and derives groups from collections in memory.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var entries: [Entry] = []
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

    func loadCounts() async {
        async let lib = try? CorpusAPI.count(table: "scribbly_entries")
        async let col = try? CorpusAPI.count(table: "scribbly_collections")
        libraryCount = (await lib) ?? libraryCount
        collectionCount = (await col) ?? collectionCount
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
