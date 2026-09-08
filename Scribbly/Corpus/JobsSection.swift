import SwiftUI

/// Everything that is (or was recently) processing, in one live list, with the
/// controls to stop, pause, or restart it. Three sources, refreshed every 5s:
///   1. Voice/file jobs on Sharp's Cloud Computer   — pause / resume / retry / cancel
///   2. YouTube batches in the server queue          — cancel / resume the whole batch
///   3. Uploads still waiting on this phone          — retry / discard
struct JobsSection: View {
    @StateObject private var model = JobsModel()
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                // ── Phone-side: not yet uploaded
                let pending = up.pendingItems()
                if !pending.isEmpty {
                    card(title: "WAITING ON THIS PHONE · \(pending.count)") {
                        ForEach(pending) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "iphone").foregroundColor(.orange).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                    Text(pendingSubtitle(item))
                                        .font(.system(size: 12)).foregroundColor(P.textSec)
                                    HStack(spacing: 14) {
                                        action("Retry", tint: P.accent) { up.resumePending() }
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
                        Text("Nothing processing.").font(.system(size: 13)).foregroundColor(P.textDim)
                    }
                    ForEach(model.voiceJobs) { j in
                        HStack(alignment: .top, spacing: 10) {
                            stateIcon(j.state)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(j.title ?? j.id).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                                Text(voiceSubtitle(j))
                                    .font(.system(size: 12)).foregroundColor(P.textSec)
                                if let e = j.error, j.state == "failed" || j.state == "no_speech" {
                                    Text(e).font(.system(size: 11)).foregroundColor(P.danger).lineLimit(3)
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
                        Text("No batches in the queue.").font(.system(size: 13)).foregroundColor(P.textDim)
                    }
                    ForEach(model.batches) { b in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "play.rectangle.fill").foregroundColor(P.accent)
                                Text(b.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                                Spacer()
                            }
                            ProgressView(value: Double(b.done), total: Double(max(b.total, 1))).tint(P.accent)
                            Text(batchSubtitle(b))
                                .font(.system(size: 12)).foregroundColor(P.textSec)
                            if let now = b.now, !now.isEmpty {
                                Text("Now: \(now)").font(.system(size: 12)).foregroundColor(P.textDim).lineLimit(1)
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
                    Text(e).font(.system(size: 12)).foregroundColor(P.danger).multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                Text(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Loading…")
                    .font(.system(size: 11)).foregroundColor(P.textDim)
            }
            .padding(.top, 8).padding(.bottom, 30)
        }
        .task { await model.startPolling() }
        .onDisappear { model.stopPolling() }
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Live jobs").font(.system(size: 22, weight: .heavy)).kerning(-0.5)
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise").foregroundColor(P.accent)
            }
        }
        .padding(.horizontal, 18).padding(.top, 8)
    }

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim).kerning(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(P.surface)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.border)))
        .padding(.horizontal, 16)
    }

    private func action(_ label: String, tint: Color, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
        }.buttonStyle(.borderless)
    }
    private func action(_ label: String, tint: Color, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(tint) }
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

@MainActor
final class JobsModel: ObservableObject {
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

    /// Base of the voice server = the upload URL minus its last path component.
    private var voiceBase: String {
        var u = CorpusAPI.voiceIngestURL
        if let r = u.range(of: "/upload", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }

    func bump() { tick += 1 }

    func startPolling() async {
        stopPolling()
        await refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh()
            }
        }
    }
    func stopPolling() { polling?.cancel(); polling = nil }

    func refresh() async {
        async let v: () = loadVoice()
        async let b: () = loadBatches()
        _ = await (v, b)
        lastRefresh = Date()
    }

    private func loadVoice() async {
        do {
            let (d, _) = try await URLSession.shared.data(from: URL(string: voiceBase + "/jobs")!)
            struct R: Decodable { let jobs: [VoiceJob] }
            voiceJobs = try JSONDecoder().decode(R.self, from: d).jobs
            error = nil
        } catch { self.error = "Cloud computer unreachable: \(error.localizedDescription)" }
    }

    /// One row per collection with anything not finished, plus counts.
    private func loadBatches() async {
        struct QRow: Decodable { let collection_id: String?; let status: String }
        struct CRow: Decodable { let id: String; let name: String }
        do {
            // Only the unfinished rows matter for "what's processing"; done rows are summed per collection.
            let live = try await rest("scribbly_queue?select=collection_id,status&status=in.(pending,failed,skipped)&limit=1000", as: [QRow].self)
            let ids = Array(Set(live.compactMap { $0.collection_id }))
            guard !ids.isEmpty else { batches = []; return }
            let idList = ids.map { "\"\($0)\"" }.joined(separator: ",")
            let names = try await rest("scribbly_collections?select=id,name&id=in.(\(idList))", as: [CRow].self)
            let nameOf = Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.name) })
            var out: [Batch] = []
            for cid in ids {
                let rows = live.filter { $0.collection_id == cid }
                let pending = rows.filter { $0.status == "pending" }.count
                let failed  = rows.filter { $0.status == "failed" }.count
                let skipped = rows.filter { $0.status == "skipped" }.count
                // done count needs a separate exact count (could exceed 1000)
                let done = (try? await count("scribbly_queue?collection_id=eq.\(cid)&status=eq.done&select=id")) ?? 0
                var b = Batch(id: cid, name: nameOf[cid] ?? cid, total: done + pending + failed + skipped,
                              done: done, pending: pending, failed: failed, skipped: skipped, now: nil)
                if pending > 0, let st = try? await ingest(["action": "queue-status", "collectionId": cid]),
                   let now = (st["nowProcessing"] as? [String])?.first ?? ((st["nowProcessing"] as? [[String: Any]])?.first?["title"] as? String) {
                    b.now = now
                }
                out.append(b)
            }
            batches = out.sorted { $0.pending > $1.pending }
        } catch { self.error = "Queue read failed: \(error.localizedDescription)" }
    }

    func op(_ id: String, _ op: String) async {
        var req = URLRequest(url: URL(string: voiceBase + "/job?jobId=\(id)&op=\(op)")!)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    func collection(_ cid: String, _ action: String) async {
        _ = try? await ingest(["action": action, "collectionId": cid])
        await refresh()
    }

    // MARK: helpers
    private func rest<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.restBase)/\(path)")!)
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(CorpusAPI.anonKey)", forHTTPHeaderField: "Authorization")
        let (d, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: d)
    }
    private func count(_ path: String) async throws -> Int {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.restBase)/\(path)")!)
        req.httpMethod = "HEAD"
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(CorpusAPI.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        let (_, r) = try await URLSession.shared.data(for: req)
        let cr = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
        return Int(cr.split(separator: "/").last ?? "") ?? 0
    }
    private func ingest(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/ingest")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}
