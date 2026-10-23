import SwiftUI

/// Everything that is (or was recently) processing, in one live list, with the
/// controls to stop, pause, or restart it. Three sources, refreshed every 5s
/// while this page (or Home's Recent list) is on screen:
///   1. Voice/file jobs on Sharp's Cloud Computer   — pause / resume / retry / cancel
///   2. YouTube batches in the server queue          — cancel / resume the whole batch
///   3. Uploads still waiting on this phone          — retry / discard
struct JobsSection: View {
    @ObservedObject private var model = JobsModel.shared
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                // ── Phone-side: not yet uploaded
                let pending = up.pendingItems()
                if !pending.isEmpty {
                    card(title: "WAITING ON THIS PHONE · \(pending.count)") {
                        ForEach(pending) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "iphone").foregroundColor(.orange).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink)
                                    Text(pendingSubtitle(item))
                                        .font(.geist(size: 12)).foregroundColor(P.textSec)
                                    if item.held {
                                        Text("Recovered after a crash — on hold until you approve it")
                                            .font(.geist(size: 11)).foregroundColor(.orange)
                                    }
                                    HStack(spacing: 14) {
                                        if item.held {
                                            action("Approve & upload", tint: P.good) { up.approve(id: item.id); model.bump() }
                                        } else {
                                            action("Retry", tint: P.accent) { up.resumePending() }
                                        }
                                        action("Discard", tint: P.danger) { up.discard(id: item.id); model.bump() }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // ── Server-side voice/file jobs
                card(title: "VOICE & FILES ON SHARP'S CLOUD COMPUTER · \(model.voiceJobs.count)") {
                    if model.voiceJobs.isEmpty {
                        Text("Nothing processing.").font(.geist(size: 13)).foregroundColor(P.textDim)
                    }
                    ForEach(model.voiceJobs) { j in
                        HStack(alignment: .top, spacing: 10) {
                            stateIcon(j.state)
                            VStack(alignment: .leading, spacing: 4) {
                                if let eid = j.entryId, j.state == "done" {
                                    // Saved: tap opens the entry it became.
                                    NavigationLink { EntryDetail(entryID: eid, preloaded: nil) } label: {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(j.title ?? j.id).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).lineLimit(2).multilineTextAlignment(.leading)
                                                Text(voiceSubtitle(j)).font(.geist(size: 12)).foregroundColor(P.textSec)
                                            }
                                            Spacer(minLength: 6)
                                            Image(systemName: "chevron.right").font(.geist(size: 12, weight: .semibold)).foregroundColor(P.textDim).padding(.top, 3)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text(j.title ?? j.id).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).lineLimit(2)
                                    Text(voiceSubtitle(j))
                                        .font(.geist(size: 12)).foregroundColor(P.textSec)
                                }
                                if let e = j.error, j.state == "failed" || j.state == "no_speech" {
                                    Text(e).font(.geist(size: 11)).foregroundColor(P.danger).lineLimit(3)
                                }
                                HStack(spacing: 14) {
                                    switch j.state {
                                    case "pending", "transcribing", "saving":
                                        action("Pause", tint: .orange) { await model.op(j.id, "pause") }
                                        action("Cancel", tint: P.danger) { await model.op(j.id, "cancel") }
                                    case "paused":
                                        action("Resume", tint: P.good) { await model.op(j.id, "resume") }
                                        action("Cancel", tint: P.danger) { await model.op(j.id, "cancel") }
                                    case "failed", "no_speech":
                                        action("Retry", tint: P.accent) { await model.op(j.id, "retry") }
                                        action("Remove", tint: P.danger) { await model.op(j.id, "cancel") }
                                    default: // done
                                        action("Clear", tint: P.textDim) { await model.op(j.id, "cancel") }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // ── YouTube batches
                card(title: "YOUTUBE BATCHES · \(model.batches.count) active") {
                    if model.batches.isEmpty {
                        Text("No batches in the queue.").font(.geist(size: 13)).foregroundColor(P.textDim)
                    }
                    ForEach(model.batches) { b in
                        VStack(alignment: .leading, spacing: 6) {
                            // Tap the batch name to open what it has saved so far.
                            NavigationLink { CollectionDetail(collection: Collection(id: b.id, name: b.name, channel: nil, type: nil, source_url: nil, total_videos: b.total, saved_videos: b.done, skipped_videos: nil, failed_videos: nil, batch_number: nil, created_at: nil)) } label: {
                                HStack {
                                    Image(systemName: "play.rectangle.fill").foregroundColor(P.accent)
                                    Text(b.name).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.geist(size: 12, weight: .semibold)).foregroundColor(P.textDim)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            GradientProgress(value: Double(b.done), total: Double(max(b.total, 1)))
                            Text(batchSubtitle(b))
                                .font(.geist(size: 12)).foregroundColor(P.textSec)
                            if let now = b.now, !now.isEmpty {
                                Text("Now: \(now)").font(.geist(size: 12)).foregroundColor(P.textDim).lineLimit(1)
                            }
                            HStack(spacing: 14) {
                                if b.pending > 0 {
                                    action("Stop batch", tint: P.danger) { await model.collection(b.id, "cancel-collection") }
                                }
                                if b.skipped > 0 || b.failed > 0 {
                                    action("Re-run stopped", tint: P.good) { await model.collection(b.id, "resume-collection") }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let e = model.error {
                    Text(e).font(.geist(size: 12)).foregroundColor(P.danger).multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                Text(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Loading…")
                    .font(.geist(size: 11)).foregroundColor(P.textDim)
            }
            .padding(.top, 8).padding(.bottom, 30)
        }
        .onAppear { model.watch("activity") }
        .onDisappear { model.unwatch("activity") }
        .refreshable { await model.refresh() }
    }

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.geist(size: 11, weight: .semibold)).foregroundColor(P.textDim).kerning(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(P.surface)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.edge)))
        .padding(.horizontal, 16)
    }

    private func action(_ label: String, tint: Color, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: {
            Text(label).font(.geist(size: 13, weight: .semibold)).foregroundColor(tint)
        }.buttonStyle(.borderless)
    }
    private func action(_ label: String, tint: Color, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Text(label).font(.geist(size: 13, weight: .semibold)).foregroundColor(tint) }
            .buttonStyle(.borderless)
    }

    private func stateIcon(_ s: String) -> some View {
        let (name, color): (String, Color) = {
            switch s {
            case "transcribing", "saving": return ("waveform.circle.fill", P.accent)
            case "pending":               return ("clock.fill", .orange)
            case "paused":                return ("pause.circle.fill", .orange)
            case "done":                  return ("checkmark.circle.fill", P.good)
            case "failed", "no_speech":   return ("exclamationmark.triangle.fill", P.danger)
            default:                      return ("circle", P.textDim)
            }
        }()
        return Image(systemName: name).foregroundColor(color).padding(.top, 2)
    }
    private func voiceSubtitle(_ j: JobsModel.VoiceJob) -> String {
        var parts: [String] = [stateLabel(j.state)]
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(j.bytes), countStyle: .file))
        if j.attempts > 1 { parts.append("\(j.attempts) attempts") }
        let when = Date(timeIntervalSince1970: j.createdAt / 1000)
        parts.append(when.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
    private func pendingSubtitle(_ item: Uploader.PendingItem) -> String {
        var parts: [String] = [ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)]
        parts.append(item.createdAt.formatted(.relative(presentation: .named)))
        if item.attempts > 0 { parts.append("\(item.attempts) attempt" + (item.attempts == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }
    private func batchSubtitle(_ b: JobsModel.Batch) -> String {
        var parts: [String] = ["\(b.done)/\(b.total) done", "\(b.pending) queued"]
        if b.failed > 0 { parts.append("\(b.failed) failed") }
        if b.skipped > 0 { parts.append("\(b.skipped) skipped") }
        return parts.joined(separator: " · ")
    }
    private func stateLabel(_ s: String) -> String {
        switch s {
        case "transcribing": return "Transcribing"
        case "saving":       return "Saving"
        case "pending":      return "Queued"
        case "paused":       return "Paused"
        case "done":         return "Done"
        case "failed":       return "Failed"
        case "no_speech":    return "No speech found"
        default:             return s
        }
    }
}

// MARK: - Model

/// One shared model for Activity and Home → Recent, with a single 5s poller
/// that runs only while at least one of those screens is visible.
@MainActor
final class JobsModel: ObservableObject {
    static let shared = JobsModel()

    struct VoiceJob: Decodable, Identifiable {
        let id: String; let state: String; let title: String?; let attempts: Int
        let bytes: Int; let createdAt: Double; let entryId: String?; let error: String?
    }
    struct Batch: Identifiable {
        let id: String; let name: String
        var total: Int; var done: Int; var pending: Int; var failed: Int; var skipped: Int
        var now: String?
    }

    @Published var voiceJobs: [VoiceJob] = []
    @Published var batches: [Batch] = []
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published private var tick = 0
    private var polling: Task<Void, Never>?
    /// Screens currently showing jobs; polling stops when this is empty.
    private var watchers = Set<String>()
    private var refreshing = false

    /// Base of the voice server = the upload URL minus its last path component.
    private var voiceBase: String {
        var u = CorpusAPI.voiceIngestURL
        if let r = u.range(of: "/upload", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }

    func bump() { tick += 1 }

    /// A screen showing jobs appeared. Idempotent per id.
    func watch(_ id: String) {
        watchers.insert(id)
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    /// That screen went away; the poller stops once no screen is watching.
    func unwatch(_ id: String) {
        watchers.remove(id)
        if watchers.isEmpty { polling?.cancel(); polling = nil }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let v: () = loadVoice()
        async let b: () = loadBatches()
        _ = await (v, b)
        lastRefresh = Date()
    }

    private func loadVoice() async {
        do {
            var req = URLRequest(url: URL(string: voiceBase + "/jobs")!)
            req.timeoutInterval = 20
            let d = try await CorpusAPI.send(req)
            struct R: Decodable { let jobs: [VoiceJob] }
            voiceJobs = try JSONDecoder().decode(R.self, from: d).jobs
            error = nil
        } catch { self.error = "Cloud computer unreachable: \(error.localizedDescription)" }
    }

    /// One row per collection with videos still queued or running. Only
    /// pending/processing rows are "active" (failed is finished, not active);
    /// they come from one queue read (paged past the 1,000-row cap only when a
    /// batch is that big), and done/failed/skipped totals come from the
    /// collections' own counters in one more request — no per-collection polling.
    private func loadBatches() async {
        struct QRow: Decodable { let collection_id: String?; let status: String; let title: String? }
        struct CRow: Decodable {
            let id: String; let name: String
            let total_videos: Int?; let saved_videos: Int?; let failed_videos: Int?; let skipped_videos: Int?
        }
        do {
            var live: [QRow] = []
            var lastID: String? = nil
            while true {
                struct Paged: Decodable { let id: String; let collection_id: String?; let status: String; let title: String? }
                var items: [URLQueryItem] = [
                    URLQueryItem(name: "select", value: "id,collection_id,status,title"),
                    URLQueryItem(name: "status", value: "in.(pending,processing)"),
                    URLQueryItem(name: "order", value: "id.asc"),
                    URLQueryItem(name: "limit", value: "1000")
                ]
                if let lastID { items.append(URLQueryItem(name: "id", value: "gt.\(CorpusAPI.quoted(lastID))")) }
                let page = try await CorpusAPI.getJSON(CorpusAPI.restURL("scribbly_queue", items), as: [Paged].self)
                live += page.map { QRow(collection_id: $0.collection_id, status: $0.status, title: $0.title) }
                guard page.count == 1000, let l = page.last else { break }
                lastID = l.id
            }
            let ids = Array(Set(live.compactMap { $0.collection_id }))
            guard !ids.isEmpty else { batches = []; return }
            let idList = ids.map(CorpusAPI.quoted).joined(separator: ",")
            let cols = try await CorpusAPI.getJSON(CorpusAPI.restURL("scribbly_collections", [
                URLQueryItem(name: "select", value: "id,name,total_videos,saved_videos,failed_videos,skipped_videos"),
                URLQueryItem(name: "id", value: "in.(\(idList))")
            ]), as: [CRow].self)
            let colOf = Dictionary(cols.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var out: [Batch] = []
            for cid in ids {
                let rows = live.filter { $0.collection_id == cid }
                let c = colOf[cid]
                let done = c?.saved_videos ?? 0
                let failed = c?.failed_videos ?? 0
                let skipped = c?.skipped_videos ?? 0
                let total = max(c?.total_videos ?? 0, done + failed + skipped + rows.count)
                let now = rows.first(where: { $0.status == "processing" })?.title
                out.append(Batch(id: cid, name: c?.name ?? cid, total: total, done: done,
                                 pending: rows.count, failed: failed, skipped: skipped, now: now))
            }
            batches = out.sorted { $0.pending > $1.pending }
        } catch { self.error = "Queue read failed: \(error.localizedDescription)" }
    }

    func op(_ id: String, _ op: String) async {
        var c = URLComponents(string: voiceBase + "/job")!
        c.queryItems = [URLQueryItem(name: "jobId", value: id), URLQueryItem(name: "op", value: op)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        do { try await CorpusAPI.send(req) }
        catch { self.error = "Couldn't \(op) that job: \(error.localizedDescription)" }
        await refresh()
    }

    func collection(_ cid: String, _ action: String) async {
        do { _ = try await ingest(["action": action, "collectionId": cid]) }
        catch { self.error = "Couldn't update that batch: \(error.localizedDescription)" }
        await refresh()
    }

    // MARK: helpers
    private func ingest(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/ingest")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let d = try await CorpusAPI.send(req)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}
