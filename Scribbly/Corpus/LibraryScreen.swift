import SwiftUI

/// Native iOS tab shell. Home · Library · RECORD · Groups · More(Collections · Query · Activity · Settings).
/// The centre tab is not a page: tapping it starts a recording and the glass
/// bar itself becomes the recorder (pause/resume, discard, finish) until you
/// tap ✓ — then the tabs come back.
struct LibraryScreen: View {
    @StateObject private var store = LibraryStore()
    @ObservedObject private var chrome = BottomChrome.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var uploader = Uploader.shared
    init(initial: Section = .home) {}

    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", library = "Library", record = "Record",
             groups = "Groups", more = "More", collections = "Collections", query = "Query", jobs = "Activity",
             settings = "Settings", watch = "Apple Watch"
        var id: String { rawValue }
        /// The four real pages. Collections · Query · Activity live inside More.
        static let pages: [Section] = [.home, .library, .groups, .more]
        var icon: String {
            switch self {
            case .home:        return "house.fill"
            case .library:     return "books.vertical.fill"
            case .record:      return "mic.circle.fill"
            case .groups:      return "person.2.fill"
            case .more:        return "ellipsis"
            case .collections: return "square.stack.fill"
            case .query:       return "sparkle.magnifyingglass"
            case .jobs:        return "waveform.path.ecg"
            case .settings:    return "gearshape.fill"
            case .watch:       return "applewatch"
            }
        }
    }
    @State private var lastRealTab: Section = .home
    @State private var libPath = NavigationPath()

    var body: some View {
        TabView(selection: $chrome.currentTab) {
            ForEach(Section.pages) { s in
                NavigationStack(path: s == .library ? $libPath : .constant(NavigationPath())) {
                    ZStack {
                        SinkyBackdrop(intensity: s == .home ? 0.5 : 1)
                        content(for: s)
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .navigationDestination(for: String.self) { id in EntryDetail(entryID: id, preloaded: nil) }
                    .navigationTitle(s == .home ? "" : (s == .more ? (chrome.moreSub?.rawValue ?? "More") : s.rawValue))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(s == .home ? .hidden : .visible, for: .navigationBar)
                    .sinkyNavBar()
                }
                // On the NavigationStack (not its root) so the live recorder bar
                // stays at the bottom of EVERY screen, including pushed entries.
                // While recording/uploading it replaces the tab bar.
                .sinkyBottomBar {
                    // The recorder bar stacks ABOVE the tab bar, so every tab stays
                    // reachable while recording (it used to replace the tab bar).
                    VStack(spacing: 6) {
                        RecordBar(armToken: chrome.armToken, tab: s)
                        if !chrome.keyboardUp && (recorderOwnsBar || !chrome.hideRecordBar) {
                            GlassTabBar(selection: $chrome.currentTab, onRecord: startRecording)
                        }
                    }
                    // On iPad / wide windows the recorder + tab bar stay thumb-sized, centred.
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .tabItem { Label(s.rawValue, systemImage: s.icon) }
                .tag(s)
            }
        }
        .tint(P.accent)
        .onChange(of: chrome.currentTab) { newTab in
            CrashReporter.shared.add("tab \(newTab.rawValue)")
            if newTab != .home { chrome.savedTitle = nil }
            switch newTab {
            case .record: chrome.currentTab = lastRealTab; startRecording()
            case .collections, .query, .jobs, .settings, .watch: chrome.moreSub = newTab; chrome.currentTab = .more
            default: lastRealTab = newTab
            }
        }
        .task {
            // Screenshot/QA hook: SCRIBBLY_TAB=home|library|groups|more opens that page on launch.
            let env = ProcessInfo.processInfo.environment
            if let t = env["SCRIBBLY_TAB"], let sec = Section(rawValue: t.capitalized) { chrome.currentTab = sec }
            if let m = env["SCRIBBLY_MORE"], let sec = Section(rawValue: m.capitalized) { chrome.moreSub = sec; chrome.currentTab = .more }
            if let id = env["SCRIBBLY_ENTRY"], !id.isEmpty { chrome.currentTab = .library; try? await Task.sleep(nanoseconds: 800_000_000); libPath.append(id) }
            if env["SCRIBBLY_REC"] == "1" {
                try? await Task.sleep(nanoseconds: 1_500_000_000); startRecording()
                // QA: SCRIBBLY_REC_SECS=n finishes (✓) after n seconds, exercising finish → upload → Live Activity end.
                if let s = env["SCRIBBLY_REC_SECS"], let n = UInt64(s) {
                    try? await Task.sleep(nanoseconds: n * 1_000_000_000)
                    Recorder.shared.finishAndUpload()
                }
            }
            await store.loadCounts()
        }
    }

    private func startRecording() {
        let rec = Recorder.shared
        // Uploads queue independently, so a new recording can start while one uploads.
        guard rec.state == .idle else { return }
        rec.place = nil
        PlaceTagger.shared.tag { Recorder.shared.place = $0 }
        rec.start()
    }

    /// True whenever the recorder capsule should replace the tab bar.
    private var recorderOwnsBar: Bool {
        recorder.state != .idle || uploader.isUploading
    }

    @ViewBuilder private func content(for s: Section) -> some View {
        switch s {
        case .home:        IngestSection(store: store)
        case .record:      IngestSection()   // never shown; the tab is an action
        case .more:        MoreHost(store: store)
        case .jobs:        JobsSection()
        case .groups:      GroupsSection(store: store)
        case .collections: CollectionsSection(store: store)
        case .library:     LibrarySection(store: store)
        case .query:       QuerySection()
        case .settings:    SettingsSection()
        case .watch:       WatchInfoSection()
        }
    }
}

// MARK: - Library section (server-filtered feed, keyset-paginated)

struct LibrarySection: View {
    @ObservedObject var store: LibraryStore
    @State private var filter = ""
    @State private var typeFilter = "All"
    @State private var sort = CorpusAPI.EntrySort.newest.rawValue

    /// All · Voice · YouTube · Instagram · Notes — a type chip is hidden once
    /// its count is known to be zero.
    private var chips: [String] {
        ["All"] + LibraryStore.filterTypes
            .filter { t in (store.typeCounts[t.type] ?? 1) > 0 }
            .map { t in t.chip }
    }
    /// The query the controls describe; the store reloads from the server when it changes.
    private var requested: LibraryStore.Query {
        LibraryStore.Query(
            type: LibraryStore.filterTypes.first(where: { t in t.chip == typeFilter })?.type,
            sort: CorpusAPI.EntrySort(rawValue: sort) ?? .newest,
            search: filter.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var searching: Bool { !store.query.search.isEmpty }

    /// Search results grouped by where each lives: group › collection, or by
    /// type for entries that aren't in a collection.
    private var groupedHits: [(key: String, header: String, detail: String, items: [Entry])] {
        var buckets: [String: (header: String, sub: String, items: [Entry])] = [:]
        var order: [String] = []
        for e in store.entries {
            let col = e.collection_id.flatMap { cid in store.collections.first { $0.id == cid } }
            let key: String, header: String, sub: String
            if let col {
                key = "col:" + col.id
                header = col.groupKey
                sub = "› " + col.displayName
            } else {
                key = "type:" + e.displayType
                header = Self.typeHeading(e.displayType)
                sub = "› no collection"
            }
            if buckets[key] == nil { buckets[key] = (header, sub, []); order.append(key) }
            buckets[key]!.items.append(e)
        }
        return order.compactMap { k in
            guard let b = buckets[k] else { return nil }
            return (key: k, header: b.header, detail: b.sub + " · \(b.items.count)", items: b.items)
        }
    }
    private static func typeHeading(_ t: String) -> String {
        switch t {
        case "Voice Note": return "Voice notes"
        case "Note":       return "Notes"
        default:           return t
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ListSearch(placeholder: "Search all \(store.libraryCount > 0 ? store.libraryCount.formatted() + " " : "")entries…", text: $filter)
                FilterSortRow(filters: chips, filter: $typeFilter,
                              sorts: CorpusAPI.EntrySort.allCases.map(\.rawValue), sort: $sort)
                exportAllRow
                if !searching {
                    ForEach(store.entries) { entry in
                        NavigationLink { EntryDetail(entryID: entry.id, preloaded: entry) } label: { EntryRow(entry: entry) }
                            .buttonStyle(.plain)
                            .onAppear { if entry.id == store.entries.last?.id { Task { await store.loadNextPage() } } }
                        Rectangle().fill(P.divider).frame(height: 1).padding(.leading, 18)
                    }
                } else {
                    ForEach(groupedHits, id: \.key) { g in
                        GroupHeader(title: g.header, detail: g.detail)
                        Nested {
                            ForEach(g.items) { entry in
                                NavigationLink { EntryDetail(entryID: entry.id, preloaded: entry) } label: { EntryRow(entry: entry) }
                                    .buttonStyle(.plain)
                                Rectangle().fill(P.divider).frame(height: 1).padding(.leading, 18)
                            }
                        }
                    }
                    if store.searchCapped {
                        Text("Showing the first \(CorpusAPI.entrySearchLimit) matches — add words to narrow it, or use Query.")
                            .font(.geist(size: 12)).foregroundColor(P.textDim).multilineTextAlignment(.center).padding(20)
                    }
                    if store.entries.isEmpty && store.reachedEnd && store.error == nil {
                        Text("No entries match \"\(store.query.search)\"" + (typeFilter == "All" ? "." : " in \(typeFilter)."))
                            .font(.geist(size: 13)).foregroundColor(P.textDim).multilineTextAlignment(.center).padding(30)
                    }
                }
                if store.loadingEntries { ProgressView().tint(P.accent).padding(24) }
                if let err = store.error, !store.loadingEntries {
                    VStack(spacing: 8) {
                        Text(store.entries.isEmpty ? "Couldn't load the library" : "Couldn't load more")
                            .font(.geist(size: 15, weight: .semibold)).foregroundColor(P.textSec)
                        Text(err).font(.geist(size: 12)).foregroundColor(P.textDim).multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { if store.entries.isEmpty { await store.reloadEntries() } else { store.error = nil; await store.loadNextPage() } }
                        }
                        .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                } else if store.entries.isEmpty && store.reachedEnd && !searching {
                    Text(typeFilter == "All" ? "Nothing here yet." : "No \(typeFilter) entries yet.")
                        .font(.geist(size: 13)).foregroundColor(P.textDim).padding(40)
                }
            }
        }
        .task {
            if let q = ProcessInfo.processInfo.environment["SCRIBBLY_SEARCH"], !q.isEmpty { filter = q }
            await store.loadFirstPageIfNeeded()
            await store.loadCollectionsIfNeeded()
            if store.typeCounts.isEmpty { await store.loadTypeCounts() }
        }
        // Filter / sort / search all go to the server; typing is debounced.
        .task(id: requested) {
            let q = requested
            if q.search != store.query.search { try? await Task.sleep(nanoseconds: 350_000_000) }
            if Task.isCancelled { return }
            await store.setQuery(q)
        }
        .onChange(of: chips) { now in
            if !now.contains(typeFilter) { typeFilter = "All" }
        }
        .refreshable { await store.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: .init("scribblyEntryDeleted"))) { _ in
            Task { await store.refreshAll() }
        }
    }

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    private var exportAllRow: some View {
        HStack(spacing: 10) {
            if let err = exportError {
                Text(err).font(.geist(size: 11)).foregroundColor(P.danger).lineLimit(2)
            }
            Spacer()
            if let u = exportURL {
                ShareLink(item: u) {
                    Label("Share export", systemImage: "square.and.arrow.up")
                        .font(.geist(size: 12, weight: .semibold)).foregroundColor(P.good)
                }
            } else {
                Button {
                    exporting = true
                    exportError = nil
                    Task {
                        // Titles, tags and summaries for the whole library; transcripts
                        // stay per-entry (Export… on an entry) to keep the file sane.
                        do {
                            let all = try await CorpusAPI.allEntriesLight()
                            var text = "SCRIBBLY LIBRARY EXPORT — \(all.count) entries\n\n"
                            for e in all {
                                text += "— \(e.title)\n  \(e.type ?? "") · \(e.displayDate)\n"
                                if let t = e.tags, !t.isEmpty { text += "  Tags: \(t)\n" }
                                if let s = e.summary, !s.isEmpty { text += "  \(s.replacingOccurrences(of: "\n", with: "\n  "))\n" }
                                text += "\n"
                            }
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("Scribbly Library \(EntryDates.display.string(from: Date())).txt")
                            try text.write(to: url, atomically: true, encoding: .utf8)
                            exportURL = url
                        } catch {
                            exportError = "Export failed: \(error.localizedDescription)"
                        }
                        exporting = false
                    }
                } label: {
                    if exporting { ProgressView().controlSize(.mini).tint(P.accent) }
                    else {
                        Label(exportError == nil ? "Export all" : "Retry export", systemImage: "square.and.arrow.up")
                            .font(.geist(size: 12, weight: .semibold)).foregroundColor(P.textSec)
                    }
                }.disabled(exporting)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 2)
    }

}

struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.title).font(.geist(size: 16, weight: .medium)).tracking(-0.2)
                .foregroundColor(P.ink).lineLimit(2)
            Text("\(entry.displayType) · \(entry.displayDate)").monoLabel(9.5, color: P.textDim)
            if !entry.tagList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(entry.tagList.prefix(6), id: \.self) { TagChip($0) } }
                }
            }
            if !entry.summaryLead.isEmpty {
                Text(entry.summaryLead).font(.geist(size: 14)).foregroundColor(P.textSec)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct TagChip: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.geist(size: 12)).foregroundColor(Color(hex: 0xD9DCDD))
            .padding(.horizontal, 10).frame(height: 24)
            .background(P.surface2).clipShape(Capsule())
            .overlay(Capsule().stroke(P.edge))
    }
}


/// The More page: cards, or one of its sub-pages (Collections / Query / Activity) with a ‹ More header.
struct MoreHost: View {
    let store: LibraryStore
    @ObservedObject private var chrome = BottomChrome.shared

    var body: some View {
        if let sub = chrome.moreSub {
            VStack(spacing: 0) {
                HStack {
                    Button { chrome.moreSub = nil } label: {
                        Label("More", systemImage: "chevron.left").font(.geist(size: 15, weight: .medium)).foregroundColor(P.ink)
                            .padding(.horizontal, 12).frame(height: 34)
                            .sinkyGlass(Capsule(), interactive: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                subPage(sub)
            }
        } else {
            MoreSection(store: store)
        }
    }

    @ViewBuilder private func subPage(_ s: LibraryScreen.Section) -> some View {
        switch s {
        case .collections: CollectionsSection(store: store)
        case .query:       QuerySection()
        case .settings:    SettingsSection()
        case .watch:       WatchInfoSection()
        default:           JobsSection()
        }
    }
}
