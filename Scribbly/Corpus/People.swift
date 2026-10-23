import Foundation
import SwiftUI

// MARK: - People (the Groups tab)
//
// A group is a PERSON, not an ingest batch. The server keeps two read-only
// views for this:
//   • scribbly_people          — one row per person: entries, own_videos, appearances
//   • scribbly_person_entries  — one row per (person, entry), role 'creator' (their
//                                own channel) or 'featured' (they appear on someone
//                                else's show). A Jordan Peterson episode of Ed
//                                Mylett's podcast is listed under both people.
// Batches (collections) stay under More → Collections and never show here.

/// One person with everything that features them.
struct Person: Decodable, Identifiable, Hashable {
    let person: String
    let entries: Int
    let own_videos: Int
    let appearances: Int
    var id: String { person }

    private enum Keys: String, CodingKey { case person, entries, own_videos, appearances }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        person = try c.decode(String.self, forKey: .person)
        entries = (try? c.decodeIfPresent(Int.self, forKey: .entries)) ?? 0
        own_videos = (try? c.decodeIfPresent(Int.self, forKey: .own_videos)) ?? 0
        appearances = (try? c.decodeIfPresent(Int.self, forKey: .appearances)) ?? 0
    }

    /// "3,490 videos · 3 appearances" (appearances only when there are some).
    var countLine: String {
        let videos = entries.formatted() + (entries == 1 ? " video" : " videos")
        guard appearances > 0 else { return videos }
        let apps = appearances.formatted() + (appearances == 1 ? " appearance" : " appearances")
        return videos + " · " + apps
    }

    /// Holding buckets and placeholders are never people.
    static let notPeople: Set<String> = ["unknown", "unassigned", "unsorted", "none", "n/a", "other", "various"]

    var isRealPerson: Bool {
        let t = person.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries > 0 && CreatorName.isCreator(person) && !Self.notPeople.contains(t)
    }
}

/// One row of scribbly_person_entries: the entry plus how the person is in it.
struct PersonEntry: Decodable, Identifiable, Hashable {
    let role: String
    let entry: Entry
    var id: String { entry.id }
    var isAppearance: Bool { role == "featured" }

    private enum Keys: String, CodingKey { case role }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "creator"
        entry = try Entry(from: decoder)
    }
}

extension CorpusAPI {
    /// The person page's segments.
    enum PersonRole: String, CaseIterable, Identifiable {
        case all = "All", own = "Their videos", featured = "Appearances"
        var id: String { rawValue }
    }

    /// The person page's sort orders, all done by the server.
    enum PersonSort: String, CaseIterable {
        case newest = "Newest", oldest = "Oldest", title = "A–Z", longest = "Longest"
        var isByDate: Bool { self == .newest || self == .oldest }
    }

    static let personSelect = "person,role,id,title,type,tags,date,created_at,collection_id,duration_seconds,notion_url"

    /// Every query character outside the unreserved set is percent-encoded —
    /// names like "Sinclair & Saxon" must not split the query string (URLComponents
    /// leaves "&", "=" and "+" alone inside query item values).
    static func strictRestURL(_ table: String, _ items: [URLQueryItem]) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.map { item -> String in
            let n = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
            let v = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return n + "=" + v
        }.joined(separator: "&")
        let base = restBase + "/" + table
        return URL(string: query.isEmpty ? base : base + "?" + query) ?? URL(string: base)!
    }

    /// Everyone in the library, most entries first.
    static func people() async throws -> [Person] {
        let url = strictRestURL("scribbly_people", [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "entries.desc"),
            URLQueryItem(name: "limit", value: "1000")
        ])
        return try await getJSON(url, as: [Person].self, timeout: 20)
    }

    /// Person + segment + search filters (no ordering / paging).
    static func personFilters(person: String, role: PersonRole, search: String, sort: PersonSort) -> [URLQueryItem] {
        var f: [URLQueryItem] = [URLQueryItem(name: "person", value: "eq." + person)]
        switch role {
        case .all: break
        case .own: f.append(URLQueryItem(name: "role", value: "eq.creator"))
        case .featured: f.append(URLQueryItem(name: "role", value: "eq.featured"))
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let v = quoted("*" + q + "*")
            f.append(URLQueryItem(name: "or", value: "(title.ilike.\(v),tags.ilike.\(v))"))
        }
        if sort == .longest { f.append(URLQueryItem(name: "duration_seconds", value: "gt.0")) }
        return f
    }

    static func personOrder(_ sort: PersonSort) -> String {
        switch sort {
        case .newest:  return "created_at.desc,id.desc"
        case .oldest:  return "created_at.asc,id.asc"
        case .title:   return "title.asc,id.asc"
        case .longest: return "duration_seconds.desc,id.desc"
        }
    }

    /// The keyset cursor after `last`, as an `and=(or(…))` filter so it never
    /// collides with the search's own `or=` parameter.
    static func personCursor(after last: Entry, sort: PersonSort) throws -> URLQueryItem {
        let id = quoted(last.id)
        let cond: String
        switch sort {
        case .newest, .oldest:
            guard let ts = last.created_at else {
                throw CorpusAPIError.message("Can't continue paging: an entry has no created_at.")
            }
            let op = sort == .newest ? "lt" : "gt"
            let t = quoted(ts)
            cond = "or(created_at.\(op).\(t),and(created_at.eq.\(t),id.\(op).\(id)))"
        case .title:
            let t = quoted(last.title)
            cond = "or(title.gt.\(t),and(title.eq.\(t),id.gt.\(id)))"
        case .longest:
            guard let d = last.duration_seconds, d.isFinite else {
                throw CorpusAPIError.message("Can't continue paging: an entry has no length.")
            }
            let v = String(Int(d.rounded()))
            cond = "or(duration_seconds.lt.\(v),and(duration_seconds.eq.\(v),id.lt.\(id)))"
        }
        return URLQueryItem(name: "and", value: "(" + cond + ")")
    }

    /// One page of a person's entries, newest first by default, keyset-paged.
    static func personEntries(person: String, role: PersonRole, sort: PersonSort, search: String,
                              after last: Entry?, limit: Int) async throws -> [PersonEntry] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "select", value: personSelect),
            URLQueryItem(name: "order", value: personOrder(sort)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        items.append(contentsOf: personFilters(person: person, role: role, search: search, sort: sort))
        if let last { items.append(try personCursor(after: last, sort: sort)) }
        return try await getJSON(strictRestURL("scribbly_person_entries", items), as: [PersonEntry].self)
    }

    /// Exact number of person rows matching `filters` (HEAD + content-range).
    static func personCount(filters: [URLQueryItem]) async throws -> Int {
        let url = strictRestURL("scribbly_person_entries", [URLQueryItem(name: "select", value: "id")] + filters)
        var req = try restRequest(url, method: "HEAD", prefer: "count=exact")
        req.timeoutInterval = 20
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let range = http.value(forHTTPHeaderField: "content-range"),
              let total = range.split(separator: "/").last, let n = Int(total) else {
            throw URLError(.badServerResponse)
        }
        return n
    }
}

/// Everyone, loaded once and shared (Groups tab + anything else that names people).
@MainActor
final class PeopleDirectory: ObservableObject {
    static let shared = PeopleDirectory()
    @Published private(set) var people: [Person] = []
    @Published private(set) var loading = false
    /// True once a load has succeeded (so an empty list isn't shown as "loading").
    @Published private(set) var loaded = false
    @Published var error: String?

    func loadIfNeeded() async {
        guard people.isEmpty else { return }
        await reload()
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let all = try await CorpusAPI.people()
            people = all.filter { p in p.isRealPerson }
            loaded = true
            error = nil
        } catch {
            if !CorpusAPI.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Groups tab: the list of people

struct GroupsSection: View {
    @ObservedObject private var directory = PeopleDirectory.shared
    @State private var q = ""
    @State private var sort = "Most videos"
    private static let sorts = ["Most videos", "A–Z", "Most appearances"]

    private var shown: [Person] {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        var xs = directory.people
        if !s.isEmpty {
            xs = xs.filter { p in p.person.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        switch sort {
        case "A–Z":
            return xs.sorted { a, b in a.person.localizedCaseInsensitiveCompare(b.person) == .orderedAscending }
        case "Most appearances":
            return xs.sorted { a, b in
                a.appearances != b.appearances ? a.appearances > b.appearances : a.entries > b.entries
            }
        default:
            return xs.sorted { a, b in
                a.entries != b.entries ? a.entries > b.entries
                    : a.person.localizedCaseInsensitiveCompare(b.person) == .orderedAscending
            }
        }
    }

    /// "39 people" (a video total would double-count shared appearances).
    private var subtitle: String {
        let ps = directory.people
        if ps.isEmpty { return directory.loading ? "Loading people…" : "Everyone in your library" }
        let noun = ps.count == 1 ? " person" : " people"
        return ps.count.formatted() + noun
    }

    private var placeholder: String {
        let n = directory.people.count
        return n > 0 ? "Search \(n) people…" : "Search people…"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
                ScrollTopAnchor()
                PageHeader(title: "Groups", subtitle: subtitle)
                LazyVStack(spacing: 8) {
                    ListSearch(placeholder: placeholder, text: $q, sorts: Self.sorts, sort: $sort)
                    listBody
                }
                .padding(.bottom, 20)
            }
        }
        .scrollsToTopOnReselect(.groups)
        .refreshable { await Task { @MainActor in await PeopleDirectory.shared.reload() }.value }
        .task { await PeopleDirectory.shared.loadIfNeeded() }
    }

    @ViewBuilder private var listBody: some View {
        if directory.people.isEmpty && !directory.loaded && directory.error == nil {
            SkeletonRows(count: 6)
        } else if directory.people.isEmpty, let err = directory.error {
            LibraryNotice(symbol: "wifi.exclamationmark", title: "Couldn't load people",
                          message: err, actionTitle: "Try again") {
                Task { await PeopleDirectory.shared.reload() }
            }
        } else {
            ForEach(shown) { p in
                NavigationLink(value: Route.person(p)) { PersonRow(person: p) }
                    .buttonStyle(.plain)
            }
            if shown.isEmpty && !q.isEmpty {
                LibraryNotice(symbol: "magnifyingglass", title: "No matches",
                              message: "No one in the library matches \u{201C}\(q)\u{201D}.")
            } else if shown.isEmpty {
                LibraryNotice(symbol: "person.2", title: "No people yet",
                              message: "Save videos from a creator and they'll show up here.")
            }
        }
    }
}

/// Pillar monogram · name · "3,490 videos · 3 appearances" · descriptor.
struct PersonRow: View {
    let person: Person

    var body: some View {
        let tone = PillarPalette.tone(for: person.person)
        let mono = CreatorTile.initials(person.person)
        let descriptor = ChannelSubtitles.map[person.person]
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 12) {
            PillarTile(tone: tone, text: mono, size: 46, corner: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.person).font(.geist(size: 17, weight: .semibold)).tracking(-0.3)
                    .foregroundColor(P.ink).lineLimit(1)
                Text(person.countLine).font(.geist(size: 12.5)).foregroundColor(P.textSec).lineLimit(1)
                if let descriptor {
                    Text(descriptor).font(.geist(size: 11)).foregroundColor(P.textDim).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(P.textDim)
        }
        .padding(12)
        .background(shape.fill(P.surface))
        .overlay(shape.stroke(P.edge))
        .contentShape(shape)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Person page: every video that features them

struct PersonDetail: View {
    let person: Person

    @State private var role: CorpusAPI.PersonRole = .all
    @State private var sortName = CorpusAPI.PersonSort.newest.rawValue
    @State private var search = ""

    @State private var rows: [PersonEntry] = []
    @State private var sections: [EntrySection] = []
    @State private var sectionCounts: [String: Int] = [:]
    @State private var matchCount: Int?
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var error: String?
    @State private var generation = 0
    @State private var buckets = TimeBuckets()
    /// The request the loaded rows belong to (nil = nothing loaded yet).
    @State private var loaded: Request?

    private let pageSize = 60
    private static let space = "personScroll"

    struct Request: Equatable {
        var role: CorpusAPI.PersonRole
        var sort: CorpusAPI.PersonSort
        var search: String
    }

    private var sort: CorpusAPI.PersonSort { CorpusAPI.PersonSort(rawValue: sortName) ?? .newest }
    private var request: Request {
        Request(role: role, sort: sort, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Segments only when the person has both kinds.
    private var showSegments: Bool { person.own_videos > 0 && person.appearances > 0 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                PageHeader(title: person.person, subtitle: person.countLine, underNavBar: true)
                controls
                metaRow
                listBody
                footer
            }
        }
        .onNearEnd(space: Self.space) {
            guard !loading, !reachedEnd, error == nil, !rows.isEmpty else { return }
            Task { @MainActor in await loadMore() }
        }
        .background(SinkyBackdrop())
        .navigationTitle(person.person).navigationBarTitleDisplayMode(.inline)
        .headerOwnsTitle()
        .task(id: request) {
            let r = request
            // Coming back from an entry: keep what's loaded (and the scroll position).
            if loaded == r && (!rows.isEmpty || reachedEnd) { return }
            if !r.search.isEmpty && loaded != nil {
                try? await Task.sleep(nanoseconds: 350_000_000)   // typing debounce
                if Task.isCancelled { return }
            }
            await reload(r)
        }
        .task { await CreatorDirectory.shared.loadIfNeeded() }
        .refreshable {
            let r = request
            await Task { @MainActor in await reload(r) }.value
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListSearch(placeholder: "Search \(person.person)…", text: $search,
                       sorts: CorpusAPI.PersonSort.allCases.map { s in s.rawValue }, sort: $sortName)
            if showSegments {
                Picker("Show", selection: $role) {
                    ForEach(CorpusAPI.PersonRole.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    /// "3,487 videos · Newest first", or "12 matches" while searching.
    private var metaText: String {
        let r = request
        if !r.search.isEmpty || sort == .longest {
            guard let n = matchCount else { return "Counting…" }
            return n.formatted() + (n == 1 ? " match" : " matches")
        }
        let n: Int
        switch r.role {
        case .all: n = person.entries
        case .own: n = person.own_videos
        case .featured: n = person.appearances
        }
        let noun: String
        if r.role == .featured { noun = n == 1 ? " appearance" : " appearances" }
        else { noun = n == 1 ? " video" : " videos" }
        let order: String
        switch sort {
        case .newest: order = "Newest first"
        case .oldest: order = "Oldest first"
        case .title: order = "A to Z"
        case .longest: order = "Longest first"
        }
        return n.formatted() + noun + " · " + order
    }

    private var metaRow: some View {
        Text(metaText).sectionHead()
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
    }

    // MARK: List

    @ViewBuilder private var listBody: some View {
        if rows.isEmpty && !reachedEnd && error == nil {
            SkeletonRows()
        } else {
            ForEach(sections) { sec in
                Section(header: LibrarySectionHeader(title: sec.title, count: countText(sec))) {
                    ForEach(sec.entries) { entry in
                        NavigationLink(value: Route.entry(entry.id, entry)) {
                            LibraryRow(entry: entry, showLength: sort == .longest)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func countText(_ sec: EntrySection) -> String {
        if let n = sectionCounts[sec.id] { return n.formatted() }
        let loadedCount = sec.entries.count.formatted()
        let isLast = sections.last?.id == sec.id
        return (isLast && !reachedEnd) ? loadedCount + "+" : loadedCount
    }

    @ViewBuilder private var footer: some View {
        if !rows.isEmpty && !reachedEnd {
            LoadMoreSentinel(space: Self.space)
        }
        if loading && !rows.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(P.accent)
                Text("Loading more…").font(.geist(size: 12)).foregroundColor(P.textDim)
            }
            .frame(maxWidth: .infinity).padding(24)
        }
        if let err = error, !loading {
            LibraryNotice(symbol: "wifi.exclamationmark",
                          title: rows.isEmpty ? "Couldn't load \(person.person)" : "Couldn't load more",
                          message: err, actionTitle: "Try again") {
                Task { @MainActor in
                    if rows.isEmpty { await reload(request) } else { error = nil; await loadMore() }
                }
            }
        } else if rows.isEmpty && reachedEnd {
            LibraryNotice(symbol: request.search.isEmpty ? "tray" : "magnifyingglass",
                          title: emptyTitle, message: emptyMessage)
        } else if !rows.isEmpty && reachedEnd {
            Text("That's everything").monoLabel(9.5, color: P.textDim)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private var emptyTitle: String {
        if !request.search.isEmpty { return "No matches" }
        switch role {
        case .all: return "Nothing here yet"
        case .own: return "No videos of their own"
        case .featured: return "No appearances yet"
        }
    }

    private var emptyMessage: String {
        if !request.search.isEmpty {
            return "Nothing with \(person.person) matches \u{201C}\(request.search)\u{201D}."
        }
        if sort == .longest { return "None of these have a recorded length yet." }
        switch role {
        case .all: return "Nothing in the library features \(person.person) yet."
        case .own: return "Everything here is \(person.person) appearing on other shows."
        case .featured: return "\(person.person) hasn't turned up on anyone else's show yet."
        }
    }

    // MARK: Loading

    /// Drops what's loaded and fetches the first page of `r`.
    private func reload(_ r: Request) async {
        generation += 1
        let gen = generation
        loaded = r
        rows = []
        sections = []
        sectionCounts = [:]
        matchCount = nil
        reachedEnd = false
        error = nil
        loading = false
        buckets = TimeBuckets()
        if !r.search.isEmpty || r.sort == .longest { countMatches(r, gen: gen) }
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, let r = loaded else { return }
        let gen = generation
        loading = true
        do {
            let page = try await CorpusAPI.personEntries(person: person.person, role: r.role, sort: r.sort,
                                                         search: r.search, after: rows.last?.entry, limit: pageSize)
            guard gen == generation else { return }   // a newer request owns the state now
            loading = false
            error = nil
            let seen = Set(rows.map { row in row.id })
            let fresh = page.filter { row in !seen.contains(row.id) }
            rows.append(contentsOf: fresh)
            appendSections(fresh.map { row in row.entry }, request: r, gen: gen)
            if page.count < pageSize { reachedEnd = true }
        } catch {
            guard gen == generation else { return }
            loading = false
            if CorpusAPI.isCancellation(error) {
                // Left the page mid-request: load again on return.
                if rows.isEmpty { loaded = nil }
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func bucket(for e: Entry, sort: CorpusAPI.PersonSort) -> TimeBuckets.Bucket {
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
        case .longest:
            return TimeBuckets.Bucket(key: "all", title: "", start: nil, end: nil)
        }
    }

    private func appendSections(_ page: [Entry], request r: Request, gen: Int) {
        guard !page.isEmpty else { return }
        var secs = sections
        var fresh: [EntrySection] = []
        for e in page {
            let b = bucket(for: e, sort: r.sort)
            if let i = secs.firstIndex(where: { s in s.id == b.key }) {
                secs[i].entries.append(e)
            } else {
                let s = EntrySection(id: b.key, title: b.title, start: b.start, end: b.end, entries: [e])
                secs.append(s)
                fresh.append(s)
            }
        }
        sections = secs
        if r.sort.isByDate { countSections(fresh, request: r, gen: gen) }
    }

    /// Exact per-section counts for the time sections, as they appear.
    private func countSections(_ new: [EntrySection], request r: Request, gen: Int) {
        let base = CorpusAPI.personFilters(person: person.person, role: r.role, search: r.search, sort: r.sort)
        for s in new {
            guard let start = s.start else { continue }
            var f = base
            f.append(URLQueryItem(name: "created_at", value: "gte." + EntryDates.utc(start)))
            if let end = s.end { f.append(URLQueryItem(name: "created_at", value: "lt." + EntryDates.utc(end))) }
            let key = s.id
            Task { @MainActor in
                guard let n = try? await CorpusAPI.personCount(filters: f), gen == generation else { return }
                sectionCounts[key] = n
            }
        }
    }

    private func countMatches(_ r: Request, gen: Int) {
        let f = CorpusAPI.personFilters(person: person.person, role: r.role, search: r.search, sort: r.sort)
        Task { @MainActor in
            guard let n = try? await CorpusAPI.personCount(filters: f), gen == generation else { return }
            matchCount = n
        }
    }
}
