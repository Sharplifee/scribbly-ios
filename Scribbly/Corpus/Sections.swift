import SwiftUI

// MARK: - Groups

struct GroupsSection: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if !store.groups.isEmpty {
                    Text("\(store.groups.count) groups · \(fmt(store.groups.reduce(0){$0+$1.totalVideos})) entries")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(P.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.top, 12)
                }
                ForEach(store.groups) { group in
                    NavigationLink { GroupDetail(group: group) } label: { GroupCard(group: group) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .task { await store.loadCollectionsIfNeeded() }
        .overlay { if store.loadingCollections && store.groups.isEmpty { ProgressView().tint(P.accent) } }
    }
    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f.string(from: .init(value: n)) ?? "\(n)"
    }
}

struct GroupCard: View {
    let group: Group
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(group.channel).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                Text("\(group.totalVideos) entries · \(group.batchCount) batches")
                    .font(.system(size: 13)).foregroundColor(P.textSec)
                Text(group.badgeRange).font(.system(size: 12)).foregroundColor(P.textDim)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("\(group.totalVideos)").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                Text("entries").font(.system(size: 11)).foregroundColor(P.textDim)
            }
        }
        .padding(16)
        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
        .padding(.horizontal, 16)
    }
}

struct GroupDetail: View {
    let group: Group
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(group.collections.sorted { ($0.batch_number ?? 0) > ($1.batch_number ?? 0) }) { col in
                    NavigationLink { CollectionDetail(collection: col) } label: { CollectionCard(collection: col) }
                        .buttonStyle(.plain)
                }
            }.padding(.vertical, 14)
        }
        .background(P.bg.ignoresSafeArea())
        .navigationTitle(group.channel).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Collections

struct CollectionsSection: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.collections) { col in
                    NavigationLink { CollectionDetail(collection: col) } label: { CollectionCard(collection: col) }
                        .buttonStyle(.plain)
                }
            }.padding(.vertical, 14)
        }
        .task { await store.loadCollectionsIfNeeded() }
        .overlay { if store.loadingCollections && store.collections.isEmpty { ProgressView().tint(P.accent) } }
    }
}

struct CollectionCard: View {
    let collection: Collection
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(collection.badge).font(.system(size: 13, weight: .bold)).foregroundColor(P.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(P.accent.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 7))
                    Text(collection.name).font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white).lineLimit(1)
                }
                if let ch = collection.channel, !ch.isEmpty {
                    Text("↳ \(ch)").font(.system(size: 13)).foregroundColor(P.textSec)
                }
                Text("\(collection.saved_videos ?? 0) saved · \(collection.skipped_videos ?? 0) skipped")
                    .font(.system(size: 12)).foregroundColor(P.textDim)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("\(collection.saved_videos ?? 0)").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                Text("entries").font(.system(size: 11)).foregroundColor(P.textDim)
            }
        }
        .padding(16).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
        .padding(.horizontal, 16)
    }
}

struct CollectionDetail: View {
    let collection: Collection
    @State private var entries: [Entry] = []
    @State private var loading = true
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { e in
                    NavigationLink { EntryDetail(entryID: e.id, preloaded: e) } label: { EntryRow(entry: e) }
                        .buttonStyle(.plain)
                    Divider().overlay(P.border).padding(.leading, 18)
                }
            }
        }
        .background(P.bg.ignoresSafeArea())
        .navigationTitle(collection.name).navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView().tint(P.accent) } }
        .task {
            defer { loading = false }
            entries = (try? await CorpusAPI.entries(inCollection: collection.id)) ?? []
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
            VStack(spacing: 14) {
                HStack {
                    TextField("Topic, phrase, keyword, concept…", text: $query)
                        .textInputAutocapitalization(.never).submitLabel(.search)
                        .onSubmit { Task { await run() } }
                        .padding(12).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.border))
                    Button { Task { await run() } } label: {
                        Text("Search").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14)

                if searching { ProgressView().tint(P.accent).padding(.top, 30) }
                else if ran && hits.isEmpty {
                    Text("No matches.").foregroundColor(P.textDim).padding(.top, 30)
                } else if !ran {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundColor(P.textDim)
                        Text("Search your corpus").font(.system(size: 18, weight: .semibold))
                        Text("Searches titles, summaries, transcripts, and tags. Ranked by relevance.")
                            .font(.system(size: 13)).foregroundColor(P.textSec).multilineTextAlignment(.center)
                    }.padding(.top, 40).padding(.horizontal, 40)
                }

                ForEach(hits) { hit in HitRow(hit: hit, query: query) }
            }
            .padding(.bottom, 20)
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
            Text(hit.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white).lineLimit(2)
            Text("\(hit.date ?? "") · \(hit.origin ?? "")").font(.system(size: 11)).foregroundColor(P.textDim)
            Text(hit.snippet(for: query)).font(.system(size: 13)).foregroundColor(P.textSec).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(P.border))
        .padding(.horizontal, 16)
    }
}

// MARK: - Ingest (native shell; submission still goes through the server routes)

struct IngestSection: View {
    @State private var mode = 0
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
    @State private var nowProcessing = ""
    @State private var progressSkipped = 0
    @State private var skippedNoCaptions: [[String: String]] = []
    private let modes = ["Channel", "Links", "Audio"]
    @State private var text = ""
    @State private var status: String?
    @State private var showPicker = false
    @ObservedObject private var files = FileIngestModel.shared
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("One link.\nOne library.").font(.system(size: 32, weight: .heavy))
                    .multilineTextAlignment(.center).kerning(-1).padding(.top, 20)
                Text("Channels, playlists, videos, and audio — transcribed, summarized, and searchable.")
                    .font(.system(size: 14)).foregroundColor(P.textSec).multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                Picker("", selection: $mode) {
                    ForEach(modes.indices, id: \.self) { Text(modes[$0]).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 16)

                if mode < 2 {
                    TextField(mode == 0 ? "Paste a channel or playlist URL…" : "One URL per line…",
                              text: $text, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                        .padding(14).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(P.border)).padding(.horizontal, 16)
                    Button { Task { await submit() } } label: {
                        Text(mode == 0 ? "Fetch Videos" : "Queue URLs")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(P.accent).clipShape(RoundedRectangle(cornerRadius: 14))
                    }.padding(.horizontal, 16)

                    if !previewVideos.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(previewName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            Text("\(previewVideos.count) to process" + (previewExisting > 0 ? " · \(previewExisting) already in your Library" : ""))
                                .font(.system(size: 12)).foregroundColor(P.textSec)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(previewVideos.prefix(60).enumerated()), id: \.offset) { i, v in
                                        Text("\(i + 1).  \((v["title"] as? String) ?? (v["videoId"] as? String) ?? "")")
                                            .font(.system(size: 12)).foregroundColor(P.textSec).lineLimit(1)
                                    }
                                    if previewVideos.count > 60 {
                                        Text("… and \(previewVideos.count - 60) more").font(.system(size: 12)).foregroundColor(P.textSec)
                                    }
                                }
                            }.frame(maxHeight: 190)
                            HStack(spacing: 10) {
                                Button { cancelPreview() } label: {
                                    Text("Cancel").font(.system(size: 14, weight: .semibold)).foregroundColor(.red)
                                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Button { Task { await startQueue() } } label: {
                                    Text(countdown > 0 ? "Starting in \(countdown)…" : "Start now")
                                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        .padding(14).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                    }

                    if progressActive || progressTotal > 0 {
                        VStack(spacing: 6) {
                            ProgressView(value: Double(progressDone + progressFailed), total: Double(max(progressTotal, 1)))
                                .tint(P.accent)
                            if progressActive && !nowProcessing.isEmpty {
                                Text("Now: \(nowProcessing)")
                                    .font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Text(progressActive ? "Processing \(progressDone)/\(progressTotal)" : "Finished \(progressDone)/\(progressTotal)")
                                    .font(.system(size: 12, weight: .semibold)).foregroundColor(P.textSec)
                                if progressSkipped > 0 {
                                    Text("· \(progressSkipped) skipped").font(.system(size: 12)).foregroundColor(.yellow)
                                }
                                if progressFailed > 0 {
                                    Text("· \(progressFailed) failed").font(.system(size: 12)).foregroundColor(.orange)
                                }
                                Spacer()
                                if progressActive {
                                    Button {
                                        Task { await cancelBatch() }
                                    } label: {
                                        Text("Cancel").font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
                                    }
                                    ProgressView().controlSize(.small).tint(P.accent)
                                }
                            }
                        }.padding(.horizontal, 16)
                    }

                    if !progressActive && !skippedNoCaptions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Skipped — no captions (\(skippedNoCaptions.count))")
                                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            ForEach(skippedNoCaptions.prefix(8), id: \.self) { v in
                                Text(v["title"] ?? v["videoId"] ?? "").font(.system(size: 12)).foregroundColor(P.textSec).lineLimit(1)
                            }
                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = skippedNoCaptions
                                        .compactMap { $0["videoId"].map { "https://www.youtube.com/watch?v=\($0)" } }
                                        .joined(separator: "\n")
                                } label: {
                                    Text("Copy URLs").font(.system(size: 13, weight: .semibold)).foregroundColor(P.textSec)
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                Button {
                                    Task {
                                        guard let cid = progressCollection else { return }
                                        _ = try? await ingest(["action": "resume-collection", "collectionId": cid])
                                        skippedNoCaptions = []
                                        startProgress(collection: cid, total: progressTotal)
                                    }
                                } label: {
                                    Text("Retry").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(14).background(P.surface.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("AUDIO & VIDEO · MP3 · M4A · WAV · MP4 · MOV · M4V")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim)
                            .kerning(0.4)
                        Button { showPicker = true } label: {
                            VStack(spacing: 8) {
                                if files.working {
                                    ProgressView(value: up.progress).tint(P.accent).padding(.horizontal, 24)
                                }
                                else { Image(systemName: "arrow.up").font(.system(size: 22)).foregroundColor(P.accent) }
                                Text(files.working ? "Working…" : "Tap to upload")
                                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                Text("any audio or video — the audio is transcribed")
                                    .font(.system(size: 12)).foregroundColor(P.textDim)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 34)
                            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundColor(P.border))
                        }
                        .disabled(files.working)
                        .padding(.horizontal, 16)
                        if let s = files.status {
                            Text(s).font(.system(size: 13)).foregroundColor(P.textSec)
                                .multilineTextAlignment(.center).padding(.horizontal, 24)
                        }
                        if let e = files.lastError {
                            Text(e).font(.system(size: 13)).foregroundColor(P.danger)
                                .multilineTextAlignment(.center).padding(.horizontal, 24)
                        }
                    }
                    .padding(.top, 6)
                    .fileImporter(isPresented: $showPicker,
                                  allowedContentTypes: FileIngestModel.contentTypes,
                                  allowsMultipleSelection: false) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            Task { await files.handle(url) }
                        }
                    }
                }

                if let s = status {
                    Text(s).font(.system(size: 13)).foregroundColor(P.textSec)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                Text("Already-saved videos are skipped automatically.")
                    .font(.system(size: 12)).foregroundColor(P.textDim).padding(.top, 4)
            }
            .padding(.bottom, 30)
        }
    }

    private func submit() async {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        do {
            if mode == 0 {
                // Channel / playlist: resolve -> preview with countdown -> queue.
                status = "Fetching video list…"
                let resolved = try await ingest(["action": "resolve", "url": payload])
                guard let videos = resolved["videos"] as? [[String: Any]], !videos.isEmpty else {
                    status = (resolved["error"] as? String) ?? "No videos found."; return
                }
                let name = (resolved["name"] as? String) ?? "Batch"
                let ids = videos.compactMap { $0["videoId"] as? String }
                let existing = try await CorpusAPI.existingVideoIDs(ids)
                let fresh = videos.filter { v in
                    guard let id = v["videoId"] as? String else { return false }
                    return !existing.contains(id)
                }
                if fresh.isEmpty { status = "All \(videos.count) videos are already in your Library."; return }
                // Preview + a 3-2-1 auto-start the user can stop or skip.
                previewName = name
                previewVideos = fresh
                previewExisting = videos.count - fresh.count
                status = nil
                countdown = 3
                countdownTask = Task {
                    for t in stride(from: 3, through: 1, by: -1) {
                        await MainActor.run { countdown = t }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return }
                    }
                    await MainActor.run { countdown = 0 }
                    await startQueue()
                }
            } else {
                // Individual links: one URL per line.
                let urls = payload.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let podcasts = urls.filter { $0.contains("podcasts.apple.com") }
                var podcastNote = ""
                if !podcasts.isEmpty {
                    status = "Processing \(podcasts.count) podcast link(s)…"
                    var okCount = 0
                    for pu in podcasts {
                        if let r = try? await ingest(["action": "process-podcast", "podcastUrl": pu]),
                           (r["success"] as? Bool) == true || r["skipped"] == nil { okCount += 1 }
                    }
                    podcastNote = " \(okCount) podcast(s) saved."
                }
                let videos: [[String: Any]] = urls.compactMap { u in
                    guard let id = CorpusAPI.youtubeID(from: u) else { return nil }
                    return ["videoId": id, "title": u, "url": u]
                }
                let unknown = urls.filter { CorpusAPI.youtubeID(from: $0) == nil && !$0.contains("podcasts.apple.com") }
                guard !videos.isEmpty else {
                    status = podcasts.isEmpty
                        ? "No YouTube or Apple Podcast links recognised."
                        : "Done —\(podcastNote)" + (unknown.isEmpty ? "" : " \(unknown.count) unsupported link(s) skipped.")
                    return
                }
                status = "Queuing \(videos.count) link(s)…"
                let col = try await ingest(["action": "create-collection", "name": "Links — \(Date().formatted(date: .abbreviated, time: .shortened))", "videos": videos])
                guard let cid = col["collectionId"] as? String else { status = "Could not create collection."; return }
                let q = try await ingest(["action": "enqueue", "videos": videos, "collectionId": cid])
                let n = (q["queued"] as? Int) ?? 0
                status = "Queued \(n) YouTube link(s)." + podcastNote + (unknown.isEmpty ? "" : " \(unknown.count) unsupported skipped.")
                startProgress(collection: cid, total: n)
            }
        } catch { status = error.localizedDescription }
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
            status = "Couldn't cancel — try again."
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
            guard let cid = col["collectionId"] as? String else { status = "Could not create collection."; return }
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
        progressActive = true
        Task {
            while progressActive, progressCollection == collection {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let st = try? await ingest(["action": "queue-status", "collectionId": collection]),
                      let byLabel = st["byLabel"] as? [String: [String: Int]] else { continue }
                var done = 0, failed = 0, pending = 0, skipped = 0
                for (_, c) in byLabel {
                    done += c["done"] ?? 0
                    failed += c["failed"] ?? 0
                    skipped += c["skipped"] ?? 0
                    pending += (c["pending"] ?? 0) + (c["processing"] ?? 0)
                }
                progressDone = done
                progressFailed = failed
                progressSkipped = skipped
                nowProcessing = (st["nowProcessing"] as? [String])?.first ?? ""
                skippedNoCaptions = ((st["skippedNoCaptions"] as? [[String: Any]]) ?? []).map { d in
                    ["videoId": (d["videoId"] as? String) ?? "", "title": (d["title"] as? String) ?? ""]
                }
                if pending == 0 && done + failed >= total {
                    progressActive = false
                    status = "Done — \(done) added to Library" + (failed > 0 ? ", \(failed) had no captions." : ".")
                }
            }
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
