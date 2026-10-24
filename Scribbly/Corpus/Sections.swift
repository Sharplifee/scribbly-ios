import SwiftUI

// MARK: - Groups
//
// The Groups tab lists PEOPLE (see People.swift). GroupDetail / ReassignSheet
// below are batch-management screens kept out of the main flow.

struct GroupDetail: View {
    let group: Group
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showReassign = false
    @State private var moving = false
    @State private var moveError: String?
    private var detailSubtitle: String {
        let n = group.totalVideos
        let b = group.batchCount
        return "\(n.formatted()) videos · \(b) batch" + (b == 1 ? "" : "es")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: group.isFiling ? Group.filingName : group.channel, subtitle: detailSubtitle, underNavBar: true)
            LazyVStack(spacing: 10) {
                if let err = moveError {
                    Text("Couldn't reassign: \(err)").font(.geist(size: 13)).foregroundColor(P.danger)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                }
                ForEach(group.collections.sorted { ($0.batch_number ?? 0) > ($1.batch_number ?? 0) }) { col in
                    NavigationLink(value: Route.collection(col)) { CollectionCard(collection: col) }
                        .buttonStyle(.plain)
                }
            }.padding(.vertical, 14)
            }
        }
        .background(SinkyBackdrop())
        .navigationTitle(group.channel).navigationBarTitleDisplayMode(.inline)
        .headerOwnsTitle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // "Filing…" is a mix of holding buckets, not one creator — nothing to reassign as a whole.
                if group.isFiling { EmptyView() }
                else if moving { ProgressView().tint(P.accent) }
                else {
                    Button("Reassign") { showReassign = true }
                        .font(.geist(size: 14, weight: .semibold)).foregroundColor(P.accent)
                }
            }
        }
        .sheet(isPresented: $showReassign) {
            ReassignSheet(group: group, groups: store.groups) { newChannel in
                moving = true
                moveError = nil
                Task {
                    do {
                        try await CorpusAPI.reassignCollections(ids: group.collections.map(\.id), to: newChannel)
                        await store.reloadCollections()
                        moving = false
                        dismiss()
                    } catch {
                        moving = false
                        moveError = error.localizedDescription   // stay here so the failure is visible
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Move an entire group's collections under another group, or a new name.
struct ReassignSheet: View {
    let group: Group
    let groups: [Group]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Move \"\(group.channel)\" into…") {
                    ForEach(groups.filter { $0.channel != group.channel && !$0.isFiling }) { g in
                        Button {
                            onPick(g.channel); dismiss()
                        } label: {
                            HStack {
                                Text(g.channel).foregroundColor(P.ink)
                                Spacer()
                                Text("\(g.totalVideos)").foregroundColor(P.textSec).font(.geist(size: 13))
                            }
                        }
                    }
                }
                Section("Or a new group name") {
                    HStack {
                        TextField("New group name", text: $custom)
                            .textInputAutocapitalization(.words)
                        Button("Move") {
                            let t = custom.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            onPick(t); dismiss()
                        }
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Reassign group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Collections

struct CollectionsSection: View {
    @ObservedObject var store: LibraryStore
    @State private var q = ""
    @State private var state = "All"
    @State private var sort = "Newest"

    /// Collections with no recorded total (total_videos 0/nil — imports, voice
    /// memos, link batches) have nothing outstanding, so they count as Complete.
    private static func passes(_ c: Collection, state: String) -> Bool {
        let saved = c.saved_videos ?? 0, total = c.total_videos ?? 0
        switch state {
        case "Has skips": return (c.skipped_videos ?? 0) > 0
        case "Complete":  return saved >= total
        case "Active":    return saved < total
        default: return true
        }
    }
    private func passes(_ c: Collection) -> Bool { Self.passes(c, state: state) }
    /// Only chips that match at least one collection.
    private var states: [String] {
        ["All"] + ["Active", "Complete", "Has skips"].filter { st in store.collections.contains { c in Self.passes(c, state: st) } }
    }
    private var shown: [Collection] {
        var xs = store.collections.filter(passes)
        if !q.isEmpty { let s = q.lowercased(); xs = xs.filter { $0.name.lowercased().contains(s) || ($0.channel ?? "").lowercased().contains(s) } }
        switch sort {
        case "Oldest":      return xs.sorted { ($0.created_at ?? "") < ($1.created_at ?? "") }
        case "A–Z":         return xs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "Most videos": return xs.sorted { ($0.saved_videos ?? 0) > ($1.saved_videos ?? 0) }
        default:            return xs.sorted { ($0.created_at ?? "") > ($1.created_at ?? "") }
        }
    }
    private var grouped: [(String, [Collection])] {
        var order: [String] = []; var b: [String: [Collection]] = [:]
        for c in shown { let k = c.channel ?? c.name; if b[k] == nil { order.append(k) }; b[k, default: []].append(c) }
        return order.map { ($0, b[$0]!) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: "Collections",
                       subtitle: store.collections.isEmpty ? "Every batch you've queued" : "\(store.collections.count) collections",
                       back: { BottomChrome.shared.moreSub = nil })
            LazyVStack(spacing: 10) {
                ListSearch(placeholder: "Search \(store.collections.count) collections…", text: $q,
                           sorts: ["Newest", "Oldest", "Most videos", "A–Z"], sort: $sort)
                FilterSortRow(filters: states, filter: $state)
                if q.isEmpty {
                    ForEach(shown) { col in
                        NavigationLink(value: Route.collection(col)) { CollectionCard(collection: col) }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(grouped, id: \.0) { group, cols in
                        GroupHeader(title: group, detail: "\(cols.count) collection" + (cols.count == 1 ? "" : "s"))
                        Nested {
                            ForEach(cols) { col in
                                NavigationLink(value: Route.collection(col)) { CollectionCard(collection: col) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if grouped.isEmpty { Text("No collections match.").font(.geist(size: 13)).foregroundColor(P.textDim).padding(30) }
                }
            }.padding(.vertical, 8)
            }
        }
        .task { await store.loadCollectionsIfNeeded() }
        .onChange(of: states) { now in if !now.contains(state) { state = "All" } }
        .overlay { if store.loadingCollections && store.collections.isEmpty { ProgressView().tint(P.accent) } }
    }
}

struct CollectionCard: View {
    let collection: Collection
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(collection.badge).font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(P.accent.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(collection.displayName).font(.geist(size: 17, weight: .semibold))
                        .foregroundColor(P.ink).lineLimit(1)
                }
                if let ch = collection.channel, !ch.isEmpty, ch != collection.displayName {
                    Text("↳ \(ch)").font(.geist(size: 13)).foregroundColor(P.textSec)
                }
                Text("\(collection.saved_videos ?? 0) saved · \(collection.skipped_videos ?? 0) skipped")
                    .font(.geist(size: 12)).foregroundColor(P.textDim)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("\(collection.saved_videos ?? 0)").font(.geist(size: 22, weight: .semibold)).foregroundStyle(P.brand)
                Text("videos").font(.geist(size: 11)).foregroundColor(P.textDim)
            }
        }
        .padding(16).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
        .padding(.horizontal, 16)
    }
}

/// One collection's entries, newest first, loaded 100 at a time as you scroll.
struct CollectionDetail: View {
    let collection: Collection
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var error: String?
    private let pageSize = 100

    private var detailSubtitle: String {
        var parts: [String] = []
        if let ch = collection.creatorName, ch != collection.displayName { parts.append(ch) }
        parts.append("\((collection.saved_videos ?? entries.count).formatted()) saved")
        if let b = collection.batch_number { parts.append("#\(b)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: collection.displayName, subtitle: detailSubtitle, underNavBar: true)
            LazyVStack(spacing: 0) {
                if entries.isEmpty && !reachedEnd && error == nil { SkeletonRows() }
                ForEach(entries) { e in
                    NavigationLink(value: Route.entry(e.id, e)) { LibraryRow(entry: e) }
                        .buttonStyle(.plain)
                }
                // Next page only once the user scrolls near the end.
                if !entries.isEmpty && !reachedEnd { LoadMoreSentinel(space: "collectionScroll") }
                if loading && !entries.isEmpty { ProgressView().tint(P.accent).padding(20) }
                if let error {
                    VStack(spacing: 8) {
                        Text(error).font(.geist(size: 12)).foregroundColor(P.danger).multilineTextAlignment(.center)
                        Button("Try again") { self.error = nil; Task { await loadMore() } }
                            .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                    }.padding(24)
                } else if reachedEnd && entries.isEmpty {
                    Text("Nothing saved in this collection yet.").font(.geist(size: 13)).foregroundColor(P.textDim).padding(30)
                }
            }
            }
        }
        .onNearEnd(space: "collectionScroll") {
            guard !loading, !reachedEnd, error == nil, !entries.isEmpty else { return }
            Task { @MainActor in await loadMore() }
        }
        .background(SinkyBackdrop())
        .navigationTitle(collection.name).navigationBarTitleDisplayMode(.inline)
        .headerOwnsTitle()
        .task {
            await CreatorDirectory.shared.loadIfNeeded()
            if entries.isEmpty { await loadMore() }
        }
        // Refresh keeps the rows on screen and swaps in the fresh first page.
        .refreshable { await Task { @MainActor in await refreshFirstPage() }.value }
    }

    private func refreshFirstPage() async {
        do {
            let page = try await CorpusAPI.entries(collectionID: collection.id, sort: .newest, after: nil,
                                                   limit: pageSize, select: Self.select)
            entries = page
            reachedEnd = page.count < pageSize
            error = nil
        } catch {
            if !CorpusAPI.isCancellation(error) && entries.isEmpty { self.error = error.localizedDescription }
        }
    }
    private static let select = "id,title,type,tags,date,created_at,collection_id,duration_seconds"

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await CorpusAPI.entries(collectionID: collection.id, sort: .newest, after: entries.last,
                                                   limit: pageSize, select: Self.select)
            entries.append(contentsOf: page)
            if page.count < pageSize { reachedEnd = true }
        } catch {
            if !CorpusAPI.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Query

struct QuerySection: View {
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var ran = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: "Query", subtitle: "Titles · summaries · transcripts · tags",
                       back: { BottomChrome.shared.moreSub = nil })
            VStack(spacing: 14) {
                HStack {
                    TextField("Topic, phrase, keyword, concept…", text: $query)
                        .textInputAutocapitalization(.never).submitLabel(.search)
                        .onSubmit { Task { await run() } }
                        .padding(12).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(P.edge))
                    Button { Task { await run() } } label: {
                        Text("Search").font(.geist(size: 15, weight: .semibold)).foregroundColor(P.ink)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6)

                if searching { ProgressView().tint(P.accent).padding(.top, 30) }
                else if ran && hits.isEmpty {
                    Text("No matches.").foregroundColor(P.textDim).padding(.top, 30)
                } else if !ran {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.geist(size: 30)).foregroundColor(P.textDim)
                        Text("Search your corpus").font(.geist(size: 18, weight: .semibold))
                        Text("Searches titles, summaries, transcripts, and tags. Ranked by relevance.")
                            .font(.geist(size: 13)).foregroundColor(P.textSec).multilineTextAlignment(.center)
                    }.padding(.top, 40).padding(.horizontal, 40)
                }

                ForEach(hits) { hit in
                    NavigationLink(value: Route.hit(hit)) { HitRow(hit: hit, query: query) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
            }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; ran = true
        defer { searching = false }
        let raw = (try? await CorpusAPI.search(q)) ?? []
        let terms = q.split(separator: " ").map(String.init)
        hits = raw.sorted { Ranker.score($0, terms: terms) > Ranker.score($1, terms: terms) }
    }
}

struct HitRow: View {
    let hit: SearchHit
    let query: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hit.title).font(.geist(size: 16, weight: .semibold)).foregroundColor(P.ink).lineLimit(2)
            Text("\(hit.date ?? "") · \(hit.origin ?? "")").font(.geist(size: 11)).foregroundColor(P.textDim)
            Text(hit.snippet(for: query)).font(.geist(size: 13)).foregroundColor(P.textSec).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.edge))
        .padding(.horizontal, 16)
    }
}

/// Opens a search hit. Scribbly-origin rows (mirror ids notes_/batches_/scribbly_ +
/// entry id) open the full entry; anything else in the corpus opens a read-only page.
struct HitDestination: View {
    let hit: SearchHit
    @State private var entry: Entry?
    @State private var loaded = false

    private var entryID: String {
        for p in ["notes_", "batches_", "scribbly_"] where hit.id.hasPrefix(p) { return String(hit.id.dropFirst(p.count)) }
        return hit.id
    }

    var body: some View {
        SwiftUI.Group {
            if let e = entry {
                EntryDetail(entryID: e.id, preloaded: e)
            } else if loaded {
                ScrollView {
                    VStack(spacing: 0) {   // no gap above the banner
                    PageHeader(title: "", subtitle: hit.origin ?? "From your corpus", underNavBar: true)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(hit.title).font(.geist(size: 22, weight: .semibold)).foregroundColor(P.ink)
                        Text("\(hit.date ?? "") · \(hit.origin ?? "")").font(.geist(size: 12)).foregroundColor(P.textDim)
                        if let s = hit.summary, !s.isEmpty {
                            Text(s).font(.geist(size: 15)).foregroundColor(P.textSec)
                        }
                        if let u = hit.source_url, let url = URL(string: u) {
                            Link("Open source", destination: url).font(.geist(size: 15, weight: .semibold)).foregroundColor(P.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    }
                }
                .background(SinkyBackdrop())
            } else {
                ProgressView().tint(P.accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(SinkyBackdrop())
            }
        }
        .task {
            if let e = try? await CorpusAPI.entry(id: entryID) { entry = e }
            loaded = true
        }
    }
}

// MARK: - Ingest (native shell; submission still goes through the server routes)

struct IngestSection: View {
    var store: LibraryStore? = nil
    @FocusState private var pasteFocused: Bool
    @State private var progressTotal = 0
    @State private var progressDone = 0
    @State private var progressFailed = 0
    @State private var progressActive = false
    @State private var progressCollection: String? = nil
    @State private var previewName = ""
    @State private var previewVideos: [[String: Any]] = []
    @State private var previewExisting = 0
    @State private var countdown = -1
    @State private var countdownTask: Task<Void, Never>? = nil
    /// The live progress poller; cancelled when Home leaves the screen, restarted when it returns.
    @State private var progressTask: Task<Void, Never>? = nil
    @State private var nowProcessing = ""
    @State private var progressSkipped = 0
    /// Real batch progress from scribbly_queue (0…100), the current row's stage,
    /// and which item of how many is being worked on.
    @State private var progressPercent: Double = 0
    @State private var progressStage = ""
    @State private var progressPosition = 0
    @State private var progressRows = 0
    /// The bar's displayed value: glides in real time toward the next server
    /// milestone between polls and snaps forward when a poll lands. Held in
    /// @State (not @StateObject) so its 10 Hz ticks redraw only the bar.
    @State private var eased = EasedProgress()
    /// The paste field's previous value — used to spot a Return keypress
    /// (a vertical TextField inserts "\n" instead of calling onSubmit).
    @State private var lastText = ""
    @State private var skippedNoCaptions: [[String: String]] = []
    @State private var batchChips: [(label: String, done: Int, total: Int)] = []
    @State private var showWalkAway = true
    @State private var text = ""
    @State private var status: String?
    @State private var showPicker = false
    @ObservedObject private var files = FileIngestModel.shared
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            // any tap outside the field puts the keyboard away
            VStack(spacing: 14) {

                // ── Hero: the same pillar banner as every page, with the wordmark,
                // the line, and what the library holds.
                PageHeader(title: "One link.\nOne library.", subtitle: "Transcribed · summarized · searchable",
                           trailing: homeSavedLabel, cardHeight: FinsBackground.bannerHeight)
                    .id(ScrollTop.anchor)
                    .task { if let store { await store.loadRecent() } }

                // ── ONE open tile. Paste anything — a channel grabs every video, one
                // link or twenty queue together; Return does exactly what Fetch does.
                // Upload lives inside the tile as a button, not a second box.
                let det = detect(text)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste anything").monoLabel(9.5)
                    // Return = Go (same as Fetch) and the keyboard goes away; pasted blocks keep their lines.
                    TextField("A channel, a playlist, one link or twenty…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.geist(size: 14)).foregroundColor(P.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($pasteFocused)
                        .onSubmit { pasteFocused = false; Task { await submit() } }
                        // A multi-line field turns Return into a newline (onSubmit never
                        // fires), so a single typed "\n" is treated as Go — exactly like
                        // Fetch — whether the link was typed or pasted. Pasted blocks
                        // keep their own line breaks.
                        .onChange(of: text) { new in
                            let old = lastText
                            lastText = new
                            if let stripped = Self.returnKeyStripped(old: old, new: new) {
                                text = stripped
                                lastText = stripped
                                pasteFocused = false
                                Task { await submit() }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 14)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { pasteFocused = false }.font(.geist(size: 15, weight: .semibold)).foregroundColor(P.accent)
                            }
                        }
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(text.isEmpty ? P.border : P.accent.opacity(0.6)))

                    if !det.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(det, id: \.self) { d in
                                Text(d).monoLabel(9.5, color: Color(hex: 0xF2A57F))
                                    .padding(.horizontal, 8).frame(height: 20)
                                    .background(P.accent.opacity(0.16)).clipShape(Capsule())
                            }
                        }
                        .transition(.opacity)
                    }

                    HStack(spacing: 10) {
                        // Upload: a video from Photos, or any audio/video file from Files.
                        Menu {
                            Button { pasteFocused = false; CrashReporter.shared.add("upload photos tapped"); files.pickingPhotos = true } label: {
                                Label("Photo Library", systemImage: "photo.on.rectangle")
                            }
                            Button { pasteFocused = false; CrashReporter.shared.add("upload tapped"); files.picking = true } label: {
                                Label("Files", systemImage: "folder")
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                                Text("Upload").lineLimit(1).fixedSize()
                            }
                            .font(.geist(size: 15, weight: .medium)).foregroundColor(P.ink)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .sinkyGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
                        }
                        .frame(maxWidth: .infinity)
                        Button { pasteFocused = false; Task { await submit() } } label: {
                            Text(fetchLabel(det))
                        }
                        .buttonStyle(SinkyPrimaryButtonStyle(enabled: !det.isEmpty))
                        .frame(maxWidth: .infinity)
                        .disabled(det.isEmpty)
                    }
                }
                .padding(14)
                .animation(.easeOut(duration: 0.18), value: det.isEmpty)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(P.surface)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(P.edge)))
                .padding(.horizontal, 16)
                if files.working && up.isUploading {
                    UploadProgressBar().padding(.horizontal, 32)
                }
                if let st = files.status {
                    Text(st).font(.geist(size: 13)).foregroundColor(P.textSec).multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                if let fe = files.lastError {
                    Text(fe).font(.geist(size: 13)).foregroundColor(P.danger).multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                SwiftUI.Group {

                    if progressActive && showWalkAway {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(P.good).font(.geist(size: 13))
                            Text("Queue and walk away — processing runs on the server. Lock the phone, close the app; it keeps going.")
                                .font(.geist(size: 12)).foregroundColor(P.textSec)
                            Spacer()
                            Button { showWalkAway = false } label: {
                                Image(systemName: "xmark").font(.geist(size: 11)).foregroundColor(P.textDim)
                            }
                        }
                        .padding(10).background(P.surface.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                    }

                    if !previewVideos.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(previewName).font(.geist(size: 15, weight: .semibold)).foregroundColor(P.ink)
                            Text("\(previewVideos.count) to process" + (previewExisting > 0 ? " · \(previewExisting) already in your Library" : ""))
                                .font(.geist(size: 12)).foregroundColor(P.textSec)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(previewVideos.prefix(60).enumerated()), id: \.offset) { i, v in
                                        Text("\(i + 1).  \((v["title"] as? String) ?? (v["videoId"] as? String) ?? "")")
                                            .font(.geist(size: 12)).foregroundColor(P.textSec).lineLimit(1)
                                    }
                                    if previewVideos.count > 60 {
                                        Text("… and \(previewVideos.count - 60) more").font(.geist(size: 12)).foregroundColor(P.textSec)
                                    }
                                }
                            }.frame(maxHeight: 190)
                            HStack(spacing: 10) {
                                Button { cancelPreview() } label: {
                                    Text("Cancel").font(.geist(size: 14, weight: .semibold)).foregroundColor(.red)
                                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                Button { Task { await startQueue() } } label: {
                                    Text(countdown > 0 ? "Starting in \(countdown)…" : "Start now")
                                        .font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink)
                                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                        .padding(14).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 16)
                    }

                    batchProgressView

                    if !progressActive && !skippedNoCaptions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Skipped — no captions (\(skippedNoCaptions.count))")
                                .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.ink)
                            ForEach(skippedNoCaptions.prefix(8), id: \.self) { v in
                                Text(v["title"] ?? v["videoId"] ?? "").font(.geist(size: 12)).foregroundColor(P.textSec).lineLimit(1)
                            }
                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = skippedNoCaptions
                                        .compactMap { $0["videoId"].map { "https://www.youtube.com/watch?v=\($0)" } }
                                        .joined(separator: "\n")
                                } label: {
                                    Text("Copy URLs").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.textSec)
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                Button {
                                    Task {
                                        guard let cid = progressCollection else { return }
                                        _ = try? await ingest(["action": "resume-collection", "collectionId": cid])
                                        skippedNoCaptions = []
                                        startProgress(collection: cid, total: progressTotal)
                                    }
                                } label: {
                                    Text("Retry").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.ink)
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        .padding(14).background(P.surface.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                }

                if let s = status {
                    Text(s).font(.geist(size: 13)).foregroundColor(P.textSec)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                if let store {
                    RecentList(store: store)
                }
            }
            .padding(.bottom, 30)
            .contentShape(Rectangle())
            .onTapGesture { pasteFocused = false }
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollsToTopOnReselect(.home)
        .refreshable { if let store { await store.loadRecent() } }
        .onChange(of: pasteFocused) { BottomChrome.shared.keyboardUp = $0 }
        .onAppear {
            if progressActive, progressTask == nil, let cid = progressCollection { pollProgress(collection: cid, total: progressTotal) }
        }
        .onDisappear { progressTask?.cancel(); progressTask = nil }
        .onReceive(BottomChrome.shared.$savedTitle) { if $0 != nil, let store { Task { await store.loadRecent() } } }
    }

    private var homeSavedLabel: String? {
        guard let store, store.libraryCount > 0 else { return nil }
        return "\(store.libraryCount.formatted()) saved"
    }

    private var homeSubtitle: String {
        if let store, store.libraryCount > 0 {
            return "\(store.libraryCount.formatted()) saved · transcribed · summarized · searchable"
        }
        return "Transcribed · summarized · searchable"
    }

    /// What the pasted text contains, as pills: "1 channel", "12 videos", "2 podcasts", "3 articles".
    private func detect(_ t: String) -> [String] {
        let urls = extractURLs(t)
        var ch = 0, vid = 0, pod = 0, art = 0, soc = 0
        for u in urls {
            let l = u.lowercased()
            if isChannelOrPlaylist(u) { ch += 1 }
            else if CorpusAPI.youtubeID(from: u) != nil { vid += 1 }
            else if l.contains("podcasts.apple.com") || l.contains("open.spotify.com") { pod += 1 }
            else if ["instagram.com", "tiktok.com", "facebook.com", "fb.watch", "vimeo.com", "x.com/", "twitter.com/"].contains(where: { l.contains($0) }) { soc += 1 }
            else { art += 1 }
        }
        var out: [String] = []
        if ch > 0 { out.append("\(ch) channel" + (ch == 1 ? "" : "s")) }
        if vid > 0 { out.append("\(vid) video" + (vid == 1 ? "" : "s")) }
        if pod > 0 { out.append("\(pod) podcast" + (pod == 1 ? "" : "s")) }
        if soc > 0 { out.append("\(soc) social video" + (soc == 1 ? "" : "s")) }
        if art > 0 { out.append("\(art) article" + (art == 1 ? "" : "s")) }
        return out
    }
    private func fetchLabel(_ det: [String]) -> String {
        if det.isEmpty { return "Fetch →" }
        let n = det.compactMap { Int($0.split(separator: " ").first ?? "") }.reduce(0, +)
        return n > 1 ? "Fetch \(n) →" : "Fetch →"
    }

    /// The live batch bar after Fetch: "Processing 3 of 12" + a real percentage.
    @ViewBuilder private var batchProgressView: some View {
        if progressActive || progressTotal > 0 {
            VStack(spacing: 6) {
                // Live, determinate: average of the batch's queue rows (done = 100,
                // pending = 0, processing = its own progress), glided between polls.
                BatchProgressBar(progress: eased, headline: progressHeadline)
                if progressActive && !progressStage.isEmpty {
                    Text(progressStage)
                        .font(.geist(size: 12)).foregroundColor(P.textSec).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if progressActive && batchChips.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(batchChips, id: \.label) { c in
                                Text("\(c.label) · \(c.done)/\(c.total)")
                                    .font(.geist(size: 11, weight: .semibold))
                                    .foregroundColor(c.done >= c.total ? P.good : P.textSec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(P.surface).clipShape(Capsule())
                            }
                        }
                    }
                }
                if progressActive && progressStage.isEmpty && !nowProcessing.isEmpty {
                    Text("Now: \(nowProcessing)")
                        .font(.geist(size: 12)).foregroundColor(P.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("\(progressDone) saved")
                        .font(.geist(size: 12, weight: .semibold)).foregroundColor(P.textSec)
                    if progressSkipped > 0 {
                        Text("· \(progressSkipped) skipped").font(.geist(size: 12)).foregroundColor(.yellow)
                    }
                    if progressFailed > 0 {
                        NavigationLink(value: Route.failed) {
                            Text("· \(progressFailed) failed ›").font(.geist(size: 12)).foregroundColor(.orange)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    if progressActive {
                        Button {
                            Task { await cancelBatch() }
                        } label: {
                            Text("Cancel").font(.geist(size: 12, weight: .semibold)).foregroundColor(.red)
                        }
                        ProgressView().controlSize(.small).tint(P.accent)
                    }
                }
            }.padding(.horizontal, 16)
        }
    }

    /// "Processing 3 of 12" (or "Finished · 12 of 12") for the live batch bar.
    private var progressHeadline: String {
        let total = max(progressRows, progressTotal)
        if !progressActive { return "Finished · \(progressDone + progressSkipped + progressFailed) of \(total)" }
        if total <= 0 { return "Processing…" }
        let pos = min(max(progressPosition, 1), total)
        return "Processing \(pos) of \(total)"
    }

    /// If `new` is `old` with exactly one "\n" inserted (the Return key), returns
    /// the text without it; nil for anything else (typing, pasting, deleting).
    static func returnKeyStripped(old: String, new: String) -> String? {
        guard new.count == old.count + 1 else { return nil }
        var o = old.startIndex, n = new.startIndex
        while o < old.endIndex, old[o] == new[n] {
            o = old.index(after: o)
            n = new.index(after: n)
        }
        guard new[n] == "\n" || new[n] == "\r\n" || new[n] == "\r" else { return nil }
        let after = new.index(after: n)
        guard new[after...] == old[o...] else { return nil }
        return old
    }

    /// Pull every URL out of whatever was pasted — newlines, spaces, commas,
    /// surrounding prose, it doesn't matter.
    private func extractURLs(_ raw: String) -> [String] {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let ns = raw as NSString
        var out: [String] = []
        det?.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let r = m?.range, let u = m?.url?.absoluteString, !u.hasPrefix("mailto:") { out.append(u); _ = r }
        }
        if out.isEmpty {
            // Bare YouTube id or a URL without scheme — still try.
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out = [t.contains("://") ? t : (t.contains(".") ? "https://" + t : t)] }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// A channel or playlist link means "fetch the whole list"; anything else is
    /// handled link-by-link. Detected, never chosen.
    private func isChannelOrPlaylist(_ u: String) -> Bool {
        let l = u.lowercased()
        guard l.contains("youtube.com") || l.contains("youtu.be") else { return false }
        if l.contains("list=") { return true }
        if l.contains("/@") || l.contains("/channel/") || l.contains("/c/") || l.contains("/user/") { return true }
        return CorpusAPI.youtubeID(from: u) == nil
    }

    private func submit() async {
        let urls = extractURLs(text)
        guard !urls.isEmpty else { return }
        // Channel / playlist links always take the whole-list path, even when
        // pasted alongside other links; everything else is handled link-by-link.
        let channelURLs = urls.filter(isChannelOrPlaylist)
        let linkURLs = urls.filter { !isChannelOrPlaylist($0) }
        // Submitted = the field resets immediately (restored only if the request errors out).
        let original = text
        text = ""
        pasteFocused = false
        do {
            if channelURLs.isEmpty {
                try await submitLinks(linkURLs)
            } else {
                try await submitChannels(channelURLs, plusLinks: linkURLs)
            }
        } catch { status = error.localizedDescription; if text.isEmpty { text = original } }
    }

    private func isPodcast(_ u: String) -> Bool {
        u.contains("podcasts.apple.com") || u.contains("open.spotify.com/episode") || u.contains("open.spotify.com/show")
    }

    /// Podcasts, social videos, articles and direct media — everything that isn't
    /// a YouTube video. Returns a status note like " 2 podcast(s) saved."
    private func processNonYouTube(_ urls: [String]) async -> String {
        let podcasts = urls.filter(isPodcast)
        var note = ""
        if !podcasts.isEmpty {
            status = "Processing \(podcasts.count) podcast link(s)…"
            var okCount = 0, failCount = 0
            for pu in podcasts {
                if let r = try? await ingest(["action": "process-podcast", "podcastUrl": pu]),
                   (r["success"] as? Bool) == true { okCount += 1 } else { failCount += 1 }
            }
            note += " \(okCount) podcast(s) saved" + (failCount > 0 ? ", \(failCount) not saved." : ".")
        }
        // Instagram + any other direct URL: social links go to Sharp's Cloud Computer,
        // the rest through the pipeline endpoint (fetch, transcribe, summarise, save).
        let others = urls.filter { CorpusAPI.youtubeID(from: $0) == nil && !$0.contains("podcasts.apple.com") && !$0.contains("open.spotify.com") }
        var otherSaved = 0, otherFailed = 0
        for u in others {
            status = "Processing \(u.contains("instagram.com") ? "Instagram" : "web") link…"
            if await processDirectURL(u) { otherSaved += 1 } else { otherFailed += 1 }
        }
        if !others.isEmpty {
            note += " \(otherSaved) link(s) queued" + (otherFailed > 0 ? ", \(otherFailed) failed" : "") + " — transcribing on the server; see Activity."
        }
        return note
    }

    /// Individual links: YouTube videos become one "Links" batch; the rest are processed one by one.
    private func submitLinks(_ urls: [String]) async throws {
        let note = await processNonYouTube(urls)
        let videos: [[String: Any]] = urls.compactMap { u in
            guard let id = CorpusAPI.youtubeID(from: u) else { return nil }
            return ["videoId": id, "title": u, "url": u]
        }
        guard !videos.isEmpty else {
            status = note.isEmpty ? "No links recognised." : "Done —\(note)"
            return
        }
        status = "Queuing \(videos.count) link(s)…"
        let col = try await ingest(["action": "create-collection", "name": "Links — \(Date().formatted(date: .abbreviated, time: .shortened))", "videos": videos])
        guard let cid = col["collectionId"] as? String else { status = "Could not create the collection (server). Tap Fetch again."; return }
        let q = try await ingest(["action": "enqueue", "videos": videos, "collectionId": cid])
        let n = (q["queued"] as? Int) ?? 0
        status = "Queued \(n) YouTube link(s)." + note
        startProgress(collection: cid, total: n)
    }

    /// Channel / playlist: resolve every list -> preview with countdown -> queue.
    /// Single YouTube videos pasted alongside join the same batch; other links
    /// (podcasts, social, articles) are processed right away.
    private func submitChannels(_ channels: [String], plusLinks links: [String]) async throws {
        let note = await processNonYouTube(links)
        status = "Fetching video list…"
        var names: [String] = []
        var videos: [[String: Any]] = []
        var seen = Set<String>()
        var problems: [String] = []
        for ch in channels {
            let resolved = try await ingest(["action": "resolve", "url": ch])
            guard let vs = resolved["videos"] as? [[String: Any]], !vs.isEmpty else {
                problems.append((resolved["error"] as? String) ?? "No videos found for \(ch).")
                continue
            }
            names.append((resolved["name"] as? String) ?? "Batch")
            for v in vs { if let id = v["videoId"] as? String, seen.insert(id).inserted { videos.append(v) } }
        }
        for u in links {
            if let id = CorpusAPI.youtubeID(from: u), seen.insert(id).inserted { videos.append(["videoId": id, "title": u, "url": u]) }
        }
        guard !videos.isEmpty else {
            status = (problems.first ?? "No videos found.") + note; return
        }
        let ids = videos.compactMap { $0["videoId"] as? String }
        let existing = try await CorpusAPI.existingVideoIDs(ids)
        let fresh = videos.filter { v in
            guard let id = v["videoId"] as? String else { return false }
            return !existing.contains(id)
        }
        if fresh.isEmpty { status = "All \(videos.count) videos are already in your Library." + note; return }
        // Preview + a 3-2-1 auto-start the user can stop or skip.
        previewName = names.isEmpty ? "Links" : (names.count == 1 ? names[0] : names.joined(separator: " + "))
        previewVideos = fresh
        previewExisting = videos.count - fresh.count
        let extra = (problems.isEmpty ? "" : " " + problems.joined(separator: " ")) + note
        status = extra.isEmpty ? nil : extra.trimmingCharacters(in: .whitespaces)
        countdown = 3
        countdownTask = Task {
            for t in stride(from: 3, through: 1, by: -1) {
                await MainActor.run { countdown = t }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            // Detach from this countdown task before queuing: startQueue()
            // cancels countdownTask, and cancelling the task we're running in
            // aborted every network call with "cancelled".
            await MainActor.run { countdown = 0; countdownTask = nil }
            Task { await startQueue() }
        }
    }

    /// Stops a running batch: everything still queued is parked server-side;
    /// the handful already in flight finish, then the workers go idle.
    private func cancelBatch() async {
        guard let cid = progressCollection else { return }
        if let r = try? await ingest(["action": "cancel-collection", "collectionId": cid]) {
            let n = (r["cancelled"] as? Int) ?? 0
            progressActive = false
            status = "Cancelled — \(n) videos stopped, \(progressDone) already saved."
        } else {
            status = "Couldn't reach the server to cancel. Tap Stop again."
        }
    }

    private func startQueue() async {
        countdownTask?.cancel(); countdownTask = nil; countdown = -1
        let fresh = previewVideos
        guard !fresh.isEmpty else { return }
        let name = previewName
        previewVideos = []
        do {
            status = "Queuing \(fresh.count) new videos…"
            let col = try await ingest(["action": "create-collection", "name": name, "videos": fresh])
            guard let cid = col["collectionId"] as? String else { status = "Could not create the collection (server). Tap Fetch again."; return }
            var queued = 0
            for chunk in stride(from: 0, to: fresh.count, by: 100).map({ Array(fresh[$0..<min($0 + 100, fresh.count)]) }) {
                let q = try await ingest(["action": "enqueue", "videos": chunk, "collectionId": cid])
                queued += (q["queued"] as? Int) ?? 0
            }
            status = "Queued \(queued) new videos from \(name)."
            startProgress(collection: cid, total: queued)
        } catch { status = error.localizedDescription }
    }

    private func cancelPreview() {
        countdownTask?.cancel(); countdownTask = nil; countdown = -1
        previewVideos = []; previewName = ""
        status = "Cancelled before starting — nothing was queued."
    }

    private func startProgress(collection: String, total: Int) {
        progressCollection = collection
        progressTotal = total
        progressDone = 0
        progressFailed = 0
        progressSkipped = 0
        progressPercent = 0
        progressStage = ""
        progressPosition = 1
        progressRows = total
        progressActive = true
        // Before the first poll: "Starting" on the first item (ceiling 5 − 2).
        eased.reset()
        eased.update(server: 0, ceiling: ProgressMilestones.ceiling(after: 0) / Double(max(total, 1)),
                     tau: ProgressMilestones.stageSeconds(at: 0))
        pollProgress(collection: collection, total: total)
    }

    /// Polls the batch's queue rows every 2s while Home is on screen and the
    /// batch is running: a real percentage (BatchProgress) and the current
    /// row's stage. The ingest queue-status call (per-batch chips and the
    /// "no captions" list) is only needed every few ticks.
    private func pollProgress(collection: String, total: Int) {
        progressTask?.cancel()
        progressTask = Task {
            var tick = 0
            while !Task.isCancelled, progressActive, progressCollection == collection {
                if tick > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                if Task.isCancelled { break }
                tick += 1

                var rowsFinished = false
                var haveRows = false
                if let rows = try? await CorpusAPI.queueRows(collection: collection), !rows.isEmpty {
                    if Task.isCancelled { break }
                    haveRows = true
                    let snap = BatchProgress(rows: rows, expected: total)
                    progressPercent = snap.percent
                    eased.update(server: snap.percent, ceiling: snap.ceiling, tau: snap.tau)
                    progressStage = snap.stage
                    progressPosition = snap.position
                    progressRows = snap.total
                    progressDone = snap.done
                    progressFailed = snap.failed
                    progressSkipped = snap.skipped
                    rowsFinished = snap.active == 0
                }

                if tick % 3 == 1 || rowsFinished || !haveRows {
                    if let st = try? await ingest(["action": "queue-status", "collectionId": collection]),
                       let byLabel = st["byLabel"] as? [String: [String: Int]] {
                        if Task.isCancelled { break }
                        applyQueueStatus(st, byLabel: byLabel, total: total, countsFromRows: haveRows)
                    }
                }

                if rowsFinished && progressActive {
                    progressActive = false
                    progressPercent = 100
                    eased.finish()
                    status = "Done — \(progressDone) added to Library"
                        + (progressFailed > 0 ? ", \(progressFailed) failed" : "")
                        + (progressSkipped > 0 ? ", \(progressSkipped) skipped" : "") + "."
                }
            }
            // A cancelled poller was replaced or stopped by whoever cancelled it.
            if !Task.isCancelled { progressTask = nil }
        }
    }

    /// Batch chips + the skipped-for-no-captions list from queue-status. When
    /// the queue rows couldn't be read, its counts drive the bar instead.
    private func applyQueueStatus(_ st: [String: Any], byLabel: [String: [String: Int]], total: Int, countsFromRows: Bool) {
        var done = 0, failed = 0, pending = 0, skipped = 0
        var chips: [(label: String, done: Int, total: Int)] = []
        for (key, c) in byLabel {
            done += c["done"] ?? 0
            failed += c["failed"] ?? 0
            skipped += c["skipped"] ?? 0
            pending += (c["pending"] ?? 0) + (c["processing"] ?? 0)
            let d: Int = (c["done"] ?? 0) + (c["skipped"] ?? 0) + (c["failed"] ?? 0)
            var t = 0
            for v in c.values { t += v }
            chips.append((label: "Batch \(key)", done: d, total: t))
        }
        chips.sort { a, b in a.label < b.label }
        batchChips = chips
        nowProcessing = (st["nowProcessing"] as? [String])?.first ?? ""
        skippedNoCaptions = ((st["skippedNoCaptions"] as? [[String: Any]]) ?? []).map { d in
            ["videoId": (d["videoId"] as? String) ?? "", "title": (d["title"] as? String) ?? ""]
        }
        guard !countsFromRows else { return }
        progressDone = done
        progressFailed = failed
        progressSkipped = skipped
        let finished = done + failed + skipped
        let all = max(total, finished + pending)
        progressRows = all
        progressPercent = all > 0 ? Double(finished) / Double(all) * 100 : 0
        progressPosition = min(all, finished + 1)
        // Counts only (no per-row stage): glide through the current item, up to
        // most of its share, until the next count lands.
        let itemShare = all > 0 ? 100 / Double(all) : 0
        let cap = pending > 0 ? min(100, progressPercent + itemShare * 0.88) : progressPercent
        eased.update(server: progressPercent, ceiling: cap, tau: 20)
        // Skipped videos are finished too — without them a batch with skips never completed.
        if pending == 0 && finished >= total && progressActive {
            progressActive = false
            progressPercent = 100
            eased.finish()
            status = "Done — \(done) added to Library"
                + (failed > 0 ? ", \(failed) failed" : "")
                + (skipped > 0 ? ", \(skipped) skipped" : "") + "."
        }
    }

    /// Instagram / direct-audio URL: transcript -> summarize -> save, via /api/pipeline.
    private func processDirectURL(_ url: String) async -> Bool {
        func pipeline(_ body: [String: Any]) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/pipeline")!)
            req.httpMethod = "POST"; req.timeoutInterval = 300
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, r) = try await URLSession.shared.data(for: req)
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            if ((r as? HTTPURLResponse)?.statusCode ?? 0) != 200 {
                throw NSError(domain: "Pipeline", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: (j["error"] as? String) ?? "Pipeline failed"])
            }
            return j
        }
        // Social video (Instagram / TikTok / Facebook / Vimeo / X) → Sharp's Cloud Computer pulls the audio
        // and transcribes it on its own clock, exactly like a recording. Accepted instantly; shows in Activity.
        let low0 = url.lowercased()
        if ["instagram.com", "tiktok.com", "facebook.com", "fb.watch", "vimeo.com", "x.com/", "twitter.com/"].contains(where: { low0.contains($0) }) {
            do {
                var req = URLRequest(url: URL(string: CorpusAPI.voiceIngestURL.replacingOccurrences(of: "/upload", with: "/link"))!)
                req.httpMethod = "POST"; req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["url": url])
                let (d, r) = try await URLSession.shared.data(for: req)
                let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                if code == 202 { return true }
                let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                status = "Couldn't queue that link: " + ((j["error"] as? String) ?? "HTTP \(code)") + " — check it opens publicly and try again."
                return false
            } catch {
                status = "Couldn't reach Sharp's Cloud Computer (\(error.localizedDescription)). The link wasn't queued — try again."
                return false
            }
        }
        // (Instagram never reaches here — it's a social link, handled above.)
        do {
            let low = url.lowercased()
            let audioExts = [".mp3", ".m4a", ".wav", ".aac", ".ogg", ".mp4", ".mov", ".m4v", ".flac"]
            let isAudio = audioExts.contains { low.split(separator: "?").first?.hasSuffix($0) ?? false }
            let body: [String: Any] = isAudio ? ["action": "transcribe-url", "audioUrl": url, "sourceType": "Media"]
                                              : ["action": "article-text", "url": url]
            let t = try await pipeline(body)
            guard let transcript = t["transcript"] as? String, !transcript.isEmpty else { return false }
            let sourceType = isAudio ? "Media" : "Article"
            let pageTitle = (t["title"] as? String) ?? ""
            let sum = try await pipeline(["action": "summarize", "transcript": transcript, "sourceType": sourceType, "title": pageTitle])
            var summary = (sum["summary"] as? String) ?? ""
            if let kp = sum["key_points"] as? [String], !kp.isEmpty { summary += "\n\nKey Points:\n" + kp.map { "• " + $0 }.joined(separator: "\n") }
            if let tp = sum["topics"] as? [String], !tp.isEmpty { summary += "\n\nTopics: " + tp.joined(separator: ", ") }
            let finalTitle = (sum["title"] as? String) ?? (pageTitle.isEmpty ? "Untitled" : pageTitle)
            // Same URL → same id, so a retry updates the entry instead of duplicating it.
            try await CorpusAPI.saveEntry(id: CorpusAPI.stableEntryID(for: url),
                                          title: finalTitle, type: sourceType,
                                          tags: (sum["tags"] as? String) ?? "",
                                          summary: summary, transcript: transcript)
            return true
        } catch {
            status = "Couldn't save \(url): \(error.localizedDescription)"
            return false
        }
    }

    private func ingest(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/ingest")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code != 200 {
            throw NSError(domain: "Ingest", code: code,
                          userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "Ingest returned HTTP \(code)."])
        }
        return json
    }
}


/// "Recent" on Home — the four newest entries, then a link to the whole library.
private struct RecentList: View {
    @ObservedObject var store: LibraryStore
    /// Shared with Activity — one poller for both, running only while either is visible.
    @ObservedObject private var jobs = JobsModel.shared
    @ObservedObject private var up = Uploader.shared
    @ObservedObject private var creators = CreatorDirectory.shared

    /// Anything still moving: server voice/file jobs that aren't finished,
    /// uploads waiting on this phone, and YouTube batches with videos queued.
    private var liveJobs: [JobsModel.VoiceJob] {
        // Failures stay on Home for 30 minutes so a fresh problem is seen,
        // then live only in Activity — old silent takes don't clutter Home.
        let cutoff = (Date().timeIntervalSince1970 - 30 * 60) * 1000
        return jobs.voiceJobs.filter { j in
            if ["pending", "transcribing", "saving", "paused"].contains(j.state) { return true }
            if j.state == "failed" || j.state == "no_speech" { return j.createdAt > cutoff }
            return false
        }
    }
    private var liveBatches: [JobsModel.Batch] { jobs.batches.filter { $0.pending > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT ACTIVITY").sectionHead()
            VStack(spacing: 0) {
                // ── Live: what's processing right now
                ForEach(up.pendingItems()) { item in
                    liveRow(icon: "iphone", tint: .orange, title: item.title,
                            sub: item.held ? "Recovered after a crash — approve it in Activity" : "Waiting on this phone to upload")
                    Divider().background(P.border)
                }
                ForEach(liveJobs) { j in
                    liveRow(icon: icon(j.state), tint: tint(j.state), title: j.title ?? "Recording",
                            sub: label(j.state) + (j.error.map { " — \($0)" } ?? ""), spinning: j.isRunning)
                    if j.isRunning {
                        // Real percentage + stage from the voice server, glided between polls.
                        VoiceJobProgress(progress: j.progress, stage: j.stage, state: j.state)
                            .padding(.leading, 28).padding(.bottom, 10).padding(.top, -4)
                    }
                    Divider().background(P.border)
                }
                ForEach(liveBatches) { b in
                    NavigationLink(value: Route.collection(Collection(id: b.id, name: b.name, channel: nil, type: nil, source_url: nil, total_videos: b.total, saved_videos: b.done, skipped_videos: nil, failed_videos: nil, batch_number: nil, created_at: nil))) {
                        liveRow(icon: "play.rectangle.fill", tint: P.accent, title: b.name,
                                sub: "\(b.done)/\(b.total) saved · \(b.pending) queued" + (b.now.map { " · Now: \($0)" } ?? ""), spinning: true)
                    }
                    .buttonStyle(.plain)
                    Divider().background(P.border)
                }

                // ── Saved: newest entries
                if store.recent.isEmpty {
                    HStack(spacing: 8) {
                        if store.recentError == nil { ProgressView().tint(P.accent) }
                        Text(store.recentError == nil ? "Loading…" : "Couldn't load recent entries — pull down to retry.")
                            .font(.geist(size: 13)).foregroundColor(P.textDim)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                ForEach(Array(store.recent.prefix(5))) { e in
                    NavigationLink(value: Route.entry(e.id, e)) { row(e) }
                        .buttonStyle(.plain)
                    Divider().background(P.border)
                }
                Button { BottomChrome.shared.currentTab = .library } label: {
                    Text(store.libraryCount > 0 ? "See all \(store.libraryCount.formatted()) ›" : "See all ›")
                        .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
        }
        .padding(.horizontal, 16)
        // Live feed comes from the shared jobs poller while Home is on screen; when
        // something finishes (fewer live items), the saved list reloads to show it.
        .onAppear { jobs.watch("home") }
        .onDisappear { jobs.unwatch("home") }
        .onChange(of: liveJobs.count + liveBatches.count) { [old = liveJobs.count + liveBatches.count] now in
            if now < old { Task { await store.loadRecent() } }
        }
    }

    private func liveRow(icon: String, tint: Color, title: String, sub: String, spinning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinning { ProgressView().tint(tint).scaleEffect(0.8).frame(width: 18).padding(.top, 2) }
            else { Image(systemName: icon).foregroundColor(tint).frame(width: 18).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text(sub).font(.geist(size: 11)).foregroundColor(P.textDim).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
    }
    private func icon(_ s: String) -> String {
        switch s { case "failed": return "exclamationmark.triangle.fill"; case "no_speech": return "speaker.slash.fill"; case "paused": return "pause.circle.fill"; default: return "waveform" }
    }
    private func tint(_ s: String) -> Color {
        switch s { case "failed", "no_speech": return P.danger; case "paused": return .orange; default: return P.accent }
    }
    private func label(_ s: String) -> String {
        switch s {
        case "pending": return "Queued on the cloud computer"
        case "transcribing": return "Transcribing…"
        case "saving": return "Saving to your library…"
        case "paused": return "Paused"
        case "failed": return "Failed — retry in Activity"
        case "no_speech": return "No speech found"
        default: return s
        }
    }
    private func row(_ e: Entry) -> some View {
        let creator = creators.creator(for: e)
        let title = e.displayTitle(creator: creator)
        let meta = e.metaLine(creator: creator)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).lineLimit(2).multilineTextAlignment(.leading)
            Text(meta).font(.geist(size: 11)).foregroundColor(P.textDim).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
    }
}

/// The Home batch bar's headline row and gradient bar, observing the eased
/// value directly so its real-time ticks redraw only this, not all of Home.
private struct BatchProgressBar: View {
    @ObservedObject var progress: EasedProgress
    let headline: String

    var body: some View {
        let pct = "\(Int(progress.shown.rounded(.down)))%"
        return VStack(spacing: 6) {
            HStack {
                Text(headline)
                    .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.ink).lineLimit(1)
                Spacer()
                Text(pct)
                    .font(.geist(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .foregroundColor(P.textSec)
            }
            GradientProgress(value: progress.shown, total: 100, height: 6, duration: 0.12)
        }
    }
}
