import SwiftUI

/// "Didn't work": every video, link or recording that never made it into the
/// Library — from any batch, any day — with the reason in plain words and a
/// way to retry each one (or all of them) or remove it from the list.
struct FailedSection: View {
    @StateObject private var model = FailedModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.loading ? "Loading…" : "\(model.total) didn't make it into your Library")
                        .font(.system(size: 13)).foregroundColor(P.textSec)
                    Spacer()
                    if model.total > 0 {
                        Button { Task { await model.retryAll() } } label: {
                            Text("Retry all").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                    }
                }
                .padding(.horizontal, 18)

                if let m = model.message {
                    Text(m).font(.system(size: 12)).foregroundColor(P.good).padding(.horizontal, 18)
                }

                // Recordings / uploaded files that failed on the cloud computer
                if !model.voice.isEmpty {
                    group(title: "RECORDINGS & FILES · \(model.voice.count)") {
                        ForEach(model.voice) { j in
                            item(title: j.title ?? "Recording", reason: FailedModel.plain(j.error ?? (j.state == "no_speech" ? "no speech" : "failed")), url: nil,
                                 retry: { await model.retryVoice(j.id) }, remove: { await model.removeVoice(j.id) })
                        }
                    }
                }

                // YouTube videos, grouped by the batch they came from
                ForEach(model.groups, id: \.id) { g in
                    group(title: "\(g.name.uppercased()) · \(g.rows.count)", retryAll: { await model.retryCollection(g.id) }) {
                        ForEach(g.rows) { r in
                            item(title: r.title ?? r.video_id ?? "Video", reason: FailedModel.plain(r.error ?? r.status),
                                 url: r.video_id.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") },
                                 retry: { await model.retry(ids: [r.id]) }, remove: { await model.remove(r.id) })
                        }
                    }
                }

                if !model.loading && model.total == 0 {
                    Text("Nothing failed. Everything you've added is in your Library.")
                        .font(.system(size: 14)).foregroundColor(P.textDim)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func group<C: View>(title: String, retryAll: (() async -> Void)? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim).tracking(0.8).lineLimit(1)
                Spacer()
                if let retryAll {
                    Button { Task { await retryAll() } } label: {
                        Text("Retry these").font(.system(size: 12, weight: .semibold)).foregroundColor(P.accent)
                    }
                }
            }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
        }
        .padding(.horizontal, 16)
    }

    private func item(title: String, reason: String, url: URL?, retry: @escaping () async -> Void, remove: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(2)
            Text(reason).font(.system(size: 12)).foregroundColor(.orange).lineLimit(3)
            HStack(spacing: 16) {
                Button { Task { await retry() } } label: { Text("Retry").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent) }
                if let url { Link("Open video", destination: url).font(.system(size: 13, weight: .semibold)).foregroundColor(P.textSec) }
                Button { Task { await remove() } } label: { Text("Remove").font(.system(size: 13, weight: .semibold)).foregroundColor(P.danger) }
            }
            .buttonStyle(.plain)
            Divider().background(P.border).padding(.top, 6)
        }
        .padding(.top, 10)
    }
}

@MainActor
final class FailedModel: ObservableObject {
    struct Row: Decodable, Identifiable {
        let id: String; let video_id: String?; let title: String?; let collection_id: String?
        let status: String; let error: String?
    }
    struct Group { let id: String; let name: String; var rows: [Row] }

    @Published var groups: [Group] = []
    @Published var voice: [JobsModel.VoiceJob] = []
    @Published var loading = true
    @Published var message: String?
    var total: Int { groups.reduce(0) { $0 + $1.rows.count } + voice.count }

    private let jobs = JobsModel()

    func load() async {
        loading = true
        defer { loading = false }
        // Every failed/skipped queue row, paged past PostgREST's 1,000 cap.
        var all: [Row] = []
        var offset = 0
        while true {
            guard let page: [Row] = try? await get("scribbly_queue?select=id,video_id,title,collection_id,status,error&status=in.(failed,skipped)&order=updated_at.desc.nullslast&limit=1000&offset=\(offset)") else { break }
            all += page; offset += page.count
            if page.count < 1000 { break }
        }
        let ids = Array(Set(all.compactMap { $0.collection_id }))
        var names: [String: String] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 80).map({ Array(ids[$0..<min($0 + 80, ids.count)]) }) {
            struct C: Decodable { let id: String; let name: String }
            let list = chunk.map { "\"\($0)\"" }.joined(separator: ",")
            if let cs: [C] = try? await get("scribbly_collections?select=id,name&id=in.(\(list))") {
                for c in cs { names[c.id] = c.name }
            }
        }
        var byCol: [String: Group] = [:]
        var order: [String] = []
        for r in all {
            let cid = r.collection_id ?? "none"
            if byCol[cid] == nil { byCol[cid] = Group(id: cid, name: names[cid] ?? "Links", rows: []); order.append(cid) }
            byCol[cid]!.rows.append(r)
        }
        groups = order.compactMap { byCol[$0] }
        await jobs.refresh()
        voice = jobs.voiceJobs.filter { $0.state == "failed" || $0.state == "no_speech" }
    }

    func retry(ids: [String]) async {
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let list = chunk.map { "\"\($0)\"" }.joined(separator: ",")
            await patch("scribbly_queue?id=in.(\(list))", ["status": "pending", "attempts": 0, "error": NSNull()])
        }
        message = "Queued \(ids.count) to try again — watch them on Home."
        await load()
    }
    func retryCollection(_ cid: String) async {
        if let g = groups.first(where: { $0.id == cid }) { await retry(ids: g.rows.map(\.id)) }
    }
    func retryAll() async {
        await retry(ids: groups.flatMap { $0.rows.map(\.id) })
        for v in voice { await jobs.op(v.id, "retry") }
        await load()
    }
    func remove(_ id: String) async {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.restBase)/scribbly_queue?id=eq.\(id)")!)
        req.httpMethod = "DELETE"
        CorpusAPI.restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        _ = try? await URLSession.shared.data(for: req)
        for i in groups.indices { groups[i].rows.removeAll { $0.id == id } }
        groups.removeAll { $0.rows.isEmpty }
    }
    func retryVoice(_ id: String) async { await jobs.op(id, "retry"); message = "Retrying that recording."; await load() }
    func removeVoice(_ id: String) async { await jobs.op(id, "cancel"); voice.removeAll { $0.id == id } }

    /// Server error text → what actually happened, in plain words.
    static func plain(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("no speech") || l.contains("produced no speech") { return "No speech in the audio — likely music-only or silent." }
        if l.contains("no captions") { return "No captions, and the audio couldn't be transcribed." }
        if l.contains("live event") || l.contains("no video formats") { return "Video wasn't available — a premiere, livestream, members-only or removed video." }
        if l.contains("sign in") || l.contains("bot") { return "YouTube blocked the download — retry later." }
        if l.contains("500") || l.contains("internal server") { return "Server error while saving — retry should work." }
        if l.contains("rate") || l.contains("429") { return "Hit a rate limit — retry later." }
        if l == "skipped" { return "Stopped before it ran — its batch was cancelled." }
        return e
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.restBase)/\(path)")!)
        req.timeoutInterval = 30
        CorpusAPI.restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (d, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: d)
    }
    private func patch(_ path: String, _ body: [String: Any]) async {
        var req = URLRequest(url: URL(string: "\(CorpusAPI.restBase)/\(path)")!)
        req.httpMethod = "PATCH"
        CorpusAPI.restHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
