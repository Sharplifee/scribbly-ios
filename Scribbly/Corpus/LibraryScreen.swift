import SwiftUI

/// Native iOS tab shell. Home · Library · Collections · Groups · Query · Activity
/// (Activity is last on purpose — it's the utility page). On iPhone iOS puts
/// anything past the 4th tab under "More", which is native behaviour.
struct LibraryScreen: View {
    @StateObject private var store = LibraryStore()
    @ObservedObject private var chrome = BottomChrome.shared
    init(initial: Section = .home) { BottomChrome.shared.currentTab = initial }

    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", library = "Library", collections = "Collections",
             groups = "Groups", query = "Query", jobs = "Activity"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home:        return "house.fill"
            case .library:     return "books.vertical.fill"
            case .collections: return "square.stack.fill"
            case .groups:      return "person.2.fill"
            case .query:       return "sparkle.magnifyingglass"
            case .jobs:        return "waveform.path.ecg"
            }
        }
    }

    var body: some View {
        TabView(selection: $chrome.currentTab) {
            ForEach(Section.allCases) { s in
                NavigationStack {
                    ZStack {
                        P.bg.ignoresSafeArea()
                        content(for: s)
                    }
                    .navigationTitle(s == .home ? "Scribbly" : s.rawValue)
                    .navigationBarTitleDisplayMode(s == .home ? .large : .inline)
                    .toolbarBackground(P.bg, for: .navigationBar)
                }
                .tabItem { Label(s.rawValue, systemImage: s.icon) }
                .badge(badgeInt(for: s))
                .tag(s)
            }
        }
        .tint(P.accent)
        .task { await store.loadCounts() }
    }

    private func badgeInt(for s: Section) -> Int {
        switch s {
        case .groups:      return store.groupCount
        case .collections: return store.collectionCount
        default:           return 0
        }
    }

    @ViewBuilder private func content(for s: Section) -> some View {
        switch s {
        case .home:        IngestSection()
        case .jobs:        JobsSection()
        case .groups:      GroupsSection(store: store)
        case .collections: CollectionsSection(store: store)
        case .library:     LibrarySection(store: store)
        case .query:       QuerySection()
        }
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Library section (flat feed, paginated)

struct LibrarySection: View {
    @ObservedObject var store: LibraryStore
    @State private var filter = ""

    private var shown: [Entry] {
        guard !filter.isEmpty else { return store.entries }
        let q = filter.lowercased()
        return store.entries.filter {
            $0.title.lowercased().contains(q) ||
            ($0.summary ?? "").lowercased().contains(q) ||
            ($0.tags ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                searchBar
                exportAllRow
                ForEach(shown) { entry in
                    NavigationLink { EntryDetail(entryID: entry.id, preloaded: entry) } label: {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if entry.id == store.entries.last?.id { Task { await store.loadNextPage() } }
                    }
                    Divider().overlay(P.border).padding(.leading, 18)
                }
                if store.loadingEntries {
                    ProgressView().tint(P.accent).padding(24)
                }
            }
        }
        .task { await store.loadFirstPageIfNeeded() }
        .refreshable { await store.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: .init("scribblyEntryDeleted"))) { _ in
            Task { await store.refreshAll() }
        }
    }

    @State private var exportURL: URL?
    @State private var exporting = false

    private var exportAllRow: some View {
        HStack {
            Spacer()
            if let u = exportURL {
                ShareLink(item: u) {
                    Label("Share export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(P.good)
                }
            } else {
                Button {
                    exporting = true
                    Task {
                        // Titles, tags and summaries for the whole library; transcripts
                        // stay per-entry (Export… on an entry) to keep the file sane.
                        let all = (try? await CorpusAPI.allEntriesLight()) ?? []
                        var text = "SCRIBBLY LIBRARY EXPORT — \(all.count) entries\n\n"
                        for e in all {
                            text += "— \(e.title)\n  \(e.type ?? "") · \(e.date ?? "")\n"
                            if let t = e.tags, !t.isEmpty { text += "  Tags: \(t)\n" }
                            if let s = e.summary, !s.isEmpty { text += "  \(s.replacingOccurrences(of: "\n", with: "\n  "))\n" }
                            text += "\n"
                        }
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("Scribbly Library \(Date().formatted(.dateTime.year().month().day())).txt")
                        try? text.write(to: url, atomically: true, encoding: .utf8)
                        await MainActor.run { exportURL = url; exporting = false }
                    }
                } label: {
                    if exporting { ProgressView().controlSize(.mini).tint(P.accent) }
                    else {
                        Label("Export all", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(P.textSec)
                    }
                }.disabled(exporting)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 2)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(P.textDim)
            TextField("Search loaded entries…", text: $filter)
                .textInputAutocapitalization(.never)
        }
        .padding(12).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.border))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.title).font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white).lineLimit(2)
            Text("\(entry.date ?? "") · \(entry.displayType)")
                .font(.system(size: 12)).foregroundColor(P.textDim)
            if !entry.tagList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(entry.tagList.prefix(6), id: \.self) { TagChip($0) } }
                }
            }
            if !entry.summaryLead.isEmpty {
                Text(entry.summaryLead).font(.system(size: 14)).foregroundColor(P.textSec)
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
        Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(P.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(P.accent.opacity(0.13)).clipShape(Capsule())
            .overlay(Capsule().stroke(P.accent.opacity(0.35)))
    }
}
