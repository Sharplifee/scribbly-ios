import SwiftUI

/// The native replacement for the embedded web Library. One screen, a scrollable
/// segmented bar, five sections: Ingest · Groups · Collections · Library · Query.
struct LibraryScreen: View {
    @StateObject private var store = LibraryStore()
    @State private var section: Section = .library

    enum Section: String, CaseIterable, Identifiable {
        case ingest = "Ingest", groups = "Groups", collections = "Collections",
             library = "Library", query = "Query"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            P.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                sectionBar
                Divider().overlay(P.border)
                content
            }
        }
        .task { await store.loadCounts() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(P.brand).frame(width: 34, height: 34)
                .overlay(Image(systemName: "diamond.fill").font(.system(size: 14)).foregroundColor(.white))
            Text("Scribbly").font(.system(size: 26, weight: .heavy)).kerning(-0.6)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
    }

    private var sectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { s in
                    let count = badge(for: s)
                    Button { section = s } label: {
                        HStack(spacing: 6) {
                            Text(s.rawValue)
                            if let count { Text(count).foregroundColor(P.textDim) }
                        }
                        .font(.system(size: 15, weight: section == s ? .semibold : .regular))
                        .foregroundColor(section == s ? .white : P.textSec)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(section == s ? P.surface : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(section == s ? P.border : .clear))
                        )
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func badge(for s: Section) -> String? {
        switch s {
        case .groups:      return store.groupCount > 0 ? "\(store.groupCount)" : nil
        case .collections: return store.collectionCount > 0 ? "\(store.collectionCount)" : nil
        case .library:     return store.libraryCount > 0 ? fmt(store.libraryCount) : nil
        default:           return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .ingest:      IngestSection()
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
