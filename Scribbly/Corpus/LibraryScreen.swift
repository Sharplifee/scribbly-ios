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
    /// One navigation path per tab. Every push is value-based (Route), so
    /// clearing a tab's path really pops it to its root.
    @State private var paths: [Section: NavigationPath] = [:]

    private func pathBinding(_ s: Section) -> Binding<NavigationPath> {
        Binding(get: { paths[s] ?? NavigationPath() }, set: { paths[s] = $0 })
    }

    var body: some View {
        TabView(selection: $chrome.currentTab) {
            ForEach(Section.pages) { s in
                tabPage(s)
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
        // Tapping the tab you're already on: back to its root (and the page
        // scrolls to the top — see ScrollTopOnReselect).
        .onChange(of: chrome.reselectTick) { _ in
            let t = chrome.reselectTab
            paths[t] = NavigationPath()
            if t == .more { chrome.moreSub = nil }
        }
        .task {
            // Screenshot/QA hook: SCRIBBLY_TAB=home|library|groups|more opens that page on launch.
            let env = ProcessInfo.processInfo.environment
            if let t = env["SCRIBBLY_TAB"], let sec = Section(rawValue: t.capitalized) { chrome.currentTab = sec }
            if let m = env["SCRIBBLY_MORE"], let sec = Section(rawValue: m.capitalized) { chrome.moreSub = sec; chrome.currentTab = .more }
            if let id = env["SCRIBBLY_ENTRY"], !id.isEmpty {
                chrome.currentTab = .library
                try? await Task.sleep(nanoseconds: 800_000_000)
                paths[.library, default: NavigationPath()].append(id)
            }
            if env["SCRIBBLY_REC"] == "1" {
                try? await Task.sleep(nanoseconds: 1_500_000_000); startRecording()
                // QA: SCRIBBLY_REC_SECS=n finishes (✓) after n seconds, exercising finish → upload → Live Activity end.
                if let s = env["SCRIBBLY_REC_SECS"], let n = UInt64(s) {
                    try? await Task.sleep(nanoseconds: n * 1_000_000_000)
                    Recorder.shared.finishAndUpload()
                }
            }
            await CreatorDirectory.shared.loadIfNeeded()
            await store.loadCounts()
        }
    }

    /// One tab: its navigation stack, the shared backdrop, and the floating
    /// bottom chrome (recorder capsule above the glass tab bar).
    private func tabPage(_ s: Section) -> some View {
        NavigationStack(path: pathBinding(s)) {
            ZStack {
                // True black; each page's PageHeader carries the pillar banner + title.
                SinkyBackdrop()
                content(for: s)
                    .chromeInset()
            }
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(for: String.self) { id in
                EntryDetail(entryID: id, preloaded: nil).chromeInset().toolbar(.visible, for: .navigationBar)
            }
            .navigationDestination(for: Route.self) { r in destination(r) }
            .navigationTitle(title(for: s))
            .navigationBarTitleDisplayMode(.inline)
            // Root pages draw their own title in the pillar banner (PageHeader),
            // well below the Dynamic Island; pushed pages bring the bar back.
            .toolbar(.hidden, for: .navigationBar)
            .sinkyNavBar()
        }
        // On the NavigationStack (not its root) so the live recorder bar
        // stays at the bottom of EVERY screen, including pushed entries.
        // It floats (overlay) and reports its height; every scroll page
        // insets its content by exactly that (ChromeInset), so the last
        // row can always scroll fully above the bars.
        .overlay(alignment: .bottom) { bottomChrome(s) }
    }

    private func title(for s: Section) -> String {
        switch s {
        case .home: return ""
        case .more: return chrome.moreSub?.rawValue ?? "More"
        default:    return s.rawValue
        }
    }

    /// The recorder bar stacks ABOVE the tab bar, so every tab stays reachable while recording.
    private func bottomChrome(_ s: Section) -> some View {
        VStack(spacing: 6) {
            RecordBar(armToken: chrome.armToken, tab: s)
            if !chrome.keyboardUp && (recorderOwnsBar || !chrome.hideRecordBar) {
                GlassTabBar(selection: $chrome.currentTab, onRecord: startRecording)
            }
        }
        // On iPad / wide windows the recorder + tab bar stay thumb-sized, centred.
        .frame(maxWidth: 620)
        .background(GeometryReader { g in
            Color.clear.preference(key: ChromeHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(ChromeHeightKey.self) { h in
            Task { @MainActor in BottomChrome.shared.setBarHeight(h, for: s) }
        }
        .frame(maxWidth: .infinity)
    }

    /// Every pushed screen, by value, so a tab can always be popped to its root.
    private func destination(_ r: Route) -> some View {
        destinationContent(r).toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder private func destinationContent(_ r: Route) -> some View {
        switch r {
        case .entry(let id, let pre):
            EntryDetail(entryID: id, preloaded: pre).chromeInset()
        case .collection(let c):
            CollectionDetail(collection: c).chromeInset()
        case .group(let g):
            GroupDetail(group: g, store: store).chromeInset()
        case .hit(let h):
            HitDestination(hit: h).chromeInset()
        case .failed:
            FailedSection().background(SinkyBackdrop()).navigationTitle("Didn't work")
                .navigationBarTitleDisplayMode(.inline).chromeInset()
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

/// Everything that can be pushed onto a tab's stack.
enum Route: Hashable {
    case entry(String, Entry?)
    case collection(Collection)
    case group(Group)
    case hit(SearchHit)
    case failed
}

// MARK: - Library section (server-filtered feed, keyset-paginated, sectioned)

struct LibrarySection: View {
    @ObservedObject var store: LibraryStore
    @State private var filter = ""
    @State private var typeFilter = "All"
    @State private var sort: CorpusAPI.EntrySort = .newest
    @State private var range: DateRange = .any
    /// A creator (Groups channel name) the feed is narrowed to.
    @State private var creator: String? = nil

    private static let voiceChip = "Recordings"

    // MARK: Derived

    /// All · Voice notes · YouTube · Instagram · Notes, with counts; a type is
    /// hidden once its count is known to be zero.
    private var chips: [TypeChip] {
        let all = TypeChip(name: "All", count: store.libraryCount > 0 ? store.libraryCount : nil)
        let types = LibraryStore.filterTypes
            .filter { t in (store.typeCounts[t.type] ?? 1) > 0 }
            .map { t in TypeChip(name: t.chip, count: store.typeCounts[t.type]) }
        return [all] + types
    }
    private var chipNames: [String] { chips.map { c in c.name } }

    /// Real creators (not the Filing… bucket), most videos first.
    private var creatorGroups: [Group] { store.groups.filter { g in !g.isFiling } }

    private var creatorIDs: [String] {
        guard let c = creator else { return [] }
        return store.groups.first(where: { g in g.channel == c })?.collections.map { col in col.id } ?? []
    }

    /// The query the controls describe; the store reloads from the server when it changes.
    private var requested: LibraryStore.Query {
        var q = LibraryStore.Query()
        q.type = LibraryStore.filterTypes.first(where: { t in t.chip == typeFilter })?.type
        q.sort = sort
        q.search = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        q.range = range
        q.creator = creator
        q.creatorIDs = creatorIDs
        return q
    }
    private var searching: Bool { !store.query.search.isEmpty }
    private var activeFilterCount: Int {
        (sort == .newest ? 0 : 1) + (range == .any ? 0 : 1) + (creator == nil ? 0 : 1)
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if store.libraryCount > 0 { parts.append("\(store.libraryCount.formatted()) entries") }
        if !creatorGroups.isEmpty { parts.append("\(creatorGroups.count) creators") }
        return parts.isEmpty ? "Everything you've saved" : parts.joined(separator: " · ")
    }

    private var showCreators: Bool {
        !searching && !creatorGroups.isEmpty && (typeFilter == "All" || typeFilter == "YouTube")
    }

    /// "342 entries · this week · Dan Martell", or how the list is ordered.
    private var resultLine: String {
        if store.query.hasFilters {
            if let n = store.matchCount {
                let noun: String = n == 1 ? " entry" : " entries"
                let tail: String = sort.isDuration ? " with a length" : ""
                return n.formatted() + noun + tail
            }
            return "Counting…"
        }
        switch sort {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .title: return "A to Z"
        case .longest: return "Longest first"
        case .shortest: return "Shortest first"
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ScrollTopAnchor()
                PageHeader(title: "Library", subtitle: headerSubtitle)
                controls
                if showCreators {
                    CreatorsStrip(groups: Array(creatorGroups.prefix(16)), selected: creator,
                                  onPick: { name in creator = (creator == name ? nil : name) },
                                  onSeeAll: { BottomChrome.shared.currentTab = .groups })
                }
                if typeFilter == Self.voiceChip && !searching {
                    VoiceSummaryCard(month: store.voiceMonth)
                }
                if !searching { metaRow }
                listBody
                footer
            }
        }
        .onNearEnd(space: "libraryScroll") {
            guard !searching, !store.loadingEntries, !store.reachedEnd, store.error == nil, !store.entries.isEmpty else { return }
            Task { @MainActor in await store.loadNextPage() }
        }
        .scrollsToTopOnReselect(.library)
        .task {
            await CreatorDirectory.shared.loadIfNeeded()
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
        .task(id: typeFilter) {
            if typeFilter == Self.voiceChip { await store.loadVoiceMonth() }
        }
        .onChange(of: chipNames) { now in
            if !now.contains(typeFilter) { typeFilter = "All" }
        }
        .refreshable { await store.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: .init("scribblyEntryDeleted"))) { _ in
            Task { await store.refreshAll() }
        }
    }

    // MARK: Controls

    /// Search field + sort/filter button on one row, active filters as tokens,
    /// then the type chips on their own row.
    private var controls: some View {
        let n: String = store.libraryCount > 0 ? store.libraryCount.formatted() + " " : ""
        let placeholder = "Search " + n + "entries…"
        return VStack(alignment: .leading, spacing: 8) {
            ListSearch(placeholder: placeholder, text: $filter, accessory: AnyView(filterMenu))
            if activeFilterCount > 0 { tokenRow }
            TypeChipRow(chips: chips, selection: $typeFilter)
        }
        .padding(.top, 2)
    }

    private var filterMenu: some View {
        Menu {
            Section("Sort") {
                ForEach(CorpusAPI.EntrySort.allCases, id: \.self) { s in
                    Button { sort = s } label: { checkLabel(s.rawValue, on: sort == s) }
                }
            }
            Section("Date") {
                ForEach(DateRange.allCases) { r in
                    Button { range = r } label: { checkLabel(r.rawValue, on: range == r) }
                }
            }
            Section("Creator") {
                Menu {
                    Button { creator = nil } label: { checkLabel("All creators", on: creator == nil) }
                    ForEach(creatorGroups) { g in
                        Button { creator = g.channel } label: {
                            checkLabel(g.channel + " · " + g.totalVideos.formatted(), on: creator == g.channel)
                        }
                    }
                } label: {
                    Label(creator ?? "All creators", systemImage: "person.2")
                }
            }
            if activeFilterCount > 0 {
                Button(role: .destructive) { clearFilters() } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            FilterButtonLabel(active: activeFilterCount)
        }
    }

    @ViewBuilder private func checkLabel(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    private var tokenRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if sort != .newest {
                    FilterToken(label: sort.rawValue) { sort = .newest }
                }
                if range != .any {
                    FilterToken(label: range.rawValue) { range = .any }
                }
                if let c = creator {
                    FilterToken(label: c) { creator = nil }
                }
                if activeFilterCount > 1 {
                    Button { clearFilters() } label: {
                        Text("Clear all").font(.geist(size: 12, weight: .semibold)).foregroundColor(P.textSec)
                            .padding(.horizontal, 8).frame(height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func clearFilters() {
        sort = .newest
        range = .any
        creator = nil
    }

    /// "342 entries · Newest first" on the left, Export on the right.
    private var metaRow: some View {
        HStack(spacing: 10) {
            Text(resultLine).sectionHead()
            Spacer()
            exportControl
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
    }

    // MARK: List

    @ViewBuilder private var listBody: some View {
        if searching {
            searchResults
        } else if store.entries.isEmpty && !store.reachedEnd && store.error == nil {
            SkeletonRows()
        } else {
            ForEach(store.sections) { sec in
                Section(header: LibrarySectionHeader(title: sec.title, count: countText(sec))) {
                    ForEach(sec.entries) { entry in
                        NavigationLink(value: Route.entry(entry.id, entry)) {
                            LibraryRow(entry: entry, showLength: sort.isDuration)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Exact server count when it has arrived; otherwise what's loaded.
    private func countText(_ sec: EntrySection) -> String {
        if let n = store.sectionCounts[sec.id] { return n.formatted() }
        let loaded = sec.entries.count.formatted()
        let isLast = store.sections.last?.id == sec.id
        return (isLast && !store.reachedEnd) ? loaded + "+" : loaded
    }

    @ViewBuilder private var footer: some View {
        if !searching && !store.entries.isEmpty && !store.reachedEnd {
            // Next page only when the user has scrolled near the end (never a chain reaction).
            LoadMoreSentinel(space: "libraryScroll")
        }
        if store.loadingEntries && !store.entries.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(P.accent)
                Text("Loading more…").font(.geist(size: 12)).foregroundColor(P.textDim)
            }
            .frame(maxWidth: .infinity).padding(24)
        }
        if let err = store.error, !store.loadingEntries {
            LibraryNotice(symbol: "wifi.exclamationmark",
                          title: store.entries.isEmpty ? "Couldn't load the library" : "Couldn't load more",
                          message: err, actionTitle: "Try again") {
                Task {
                    if store.entries.isEmpty { await store.reloadEntries() }
                    else { store.error = nil; await store.loadNextPage() }
                }
            }
        } else if store.entries.isEmpty && store.reachedEnd && !searching {
            if activeFilterCount > 0 {
                LibraryNotice(symbol: "tray", title: emptyTitle,
                              message: "Nothing matches these filters.",
                              actionTitle: "Clear filters") { clearFilters() }
            } else {
                LibraryNotice(symbol: "tray", title: emptyTitle,
                              message: store.query.hasFilters ? "Nothing of this type yet."
                                                              : "Paste a link on Home or record a voice note to start.")
            }
        } else if !store.entries.isEmpty && store.reachedEnd && !searching {
            Text("That's everything").monoLabel(9.5, color: P.textDim)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private var emptyTitle: String {
        if range != .any { return "Nothing from " + range.rawValue.lowercased() }
        if let c = creator { return "Nothing from " + c }
        return typeFilter == "All" ? "Nothing here yet" : "No \(typeFilter.lowercased()) yet"
    }

    // MARK: Search results (grouped by where each entry lives)

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
                header = col.creatorName ?? (CreatorName.isFiling(col.groupKey) ? Group.filingName : col.groupKey)
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
        case "Voice Note": return "Recordings"
        case "Note":       return "Notes"
        default:           return t
        }
    }

    @ViewBuilder private var searchResults: some View {
        if store.loadingEntries && store.entries.isEmpty {
            SkeletonRows(count: 4)
        }
        ForEach(groupedHits, id: \.key) { g in
            GroupHeader(title: g.header, detail: g.detail)
            Nested {
                ForEach(g.items) { entry in
                    NavigationLink(value: Route.entry(entry.id, entry)) { LibraryRow(entry: entry) }
                        .buttonStyle(.plain)
                }
            }
        }
        if store.searchCapped {
            Text("Showing the first \(CorpusAPI.entrySearchLimit) matches — add words to narrow it, or use Query.")
                .font(.geist(size: 12)).foregroundColor(P.textDim).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(20)
        }
        if store.entries.isEmpty && store.reachedEnd && store.error == nil {
            LibraryNotice(symbol: "magnifyingglass",
                          title: "No matches",
                          message: "Nothing matches \"\(store.query.search)\"" + (typeFilter == "All" ? "." : " in \(typeFilter)."))
        }
    }

    // MARK: Export

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    @ViewBuilder private var exportControl: some View {
        if let u = exportURL {
            ShareLink(item: u) {
                Label("Share export", systemImage: "square.and.arrow.up")
                    .font(.geist(size: 12, weight: .semibold)).foregroundColor(P.good)
            }
        } else {
            Button { runExport() } label: {
                if exporting { ProgressView().controlSize(.mini).tint(P.accent) }
                else {
                    Label(exportError == nil ? "Export" : "Retry export", systemImage: "square.and.arrow.up")
                        .font(.geist(size: 12, weight: .semibold))
                        .foregroundColor(exportError == nil ? P.textSec : P.danger)
                }
            }
            .disabled(exporting)
            .accessibilityHint(exportError ?? "Exports titles, tags and summaries of the whole library as a text file.")
        }
    }

    private func runExport() {
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
                if !CorpusAPI.isCancellation(error) { exportError = "Export failed: \(error.localizedDescription)" }
            }
            exporting = false
        }
    }
}

struct EntryRow: View {
    let entry: Entry
    @ObservedObject private var creators = CreatorDirectory.shared
    var body: some View {
        let creator = creators.creator(for: entry)
        let title = entry.displayTitle(creator: creator)
        let meta = entry.metaLine(creator: creator)
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.geist(size: 16, weight: .medium)).tracking(-0.2)
                .foregroundColor(P.ink).lineLimit(2)
            Text(meta).font(.geist(size: 12)).foregroundColor(P.textDim).lineLimit(2)
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


/// The More page: cards, or one of its sub-pages (Collections / Query / Activity / Settings / Apple Watch).
struct MoreHost: View {
    let store: LibraryStore
    @ObservedObject private var chrome = BottomChrome.shared

    var body: some View {
        // Each sub-page starts with its own PageHeader, whose "‹ More" capsule comes back here.
        if let sub = chrome.moreSub {
            subPage(sub)
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
