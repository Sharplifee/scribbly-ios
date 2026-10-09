import SwiftUI

/// Full entry view: summary, transcript, tags, copy, and the grounded Ask chat.
struct EntryDetail: View {
    let entryID: String
    let preloaded: Entry?

    @State private var entry: Entry?
    @State private var loading = true
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private func exportText() -> String {
        guard let e = entry else { return "" }
        var out = "\(e.title)\n\(e.type ?? "") · \(e.date ?? "")\n"
        if let t = e.tags, !t.isEmpty { out += "Tags: \(t)\n" }
        if let s = e.summary, !s.isEmpty { out += "\nSUMMARY\n\(s)\n" }
        if let tr = e.transcript, !tr.isEmpty { out += "\nTRANSCRIPT\n\(tr)\n" }
        return out
    }

    var body: some View {
        ScrollView {
            if let e = entry {
                VStack(alignment: .leading, spacing: 16) {
                    Text(e.title).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                    Text("\(e.date ?? "") · \(e.displayType)").font(.system(size: 13)).foregroundColor(P.textDim)

                    if !e.tagList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(e.tagList, id: \.self) { TagChip($0) } }
                        }
                    }

                    if let s = e.summary, !s.isEmpty {
                        sectionLabel("Summary")
                        Text(s).font(.system(size: 15)).foregroundColor(P.textSec)
                    }
                    sectionLabel("Send to")
                    sendToClaudeButton(e)

                    // Copy · Export · Share · Delete
                    HStack {
                        Button { UIPasteboard.general.string = exportText(); copied = true } label: {
                            Text(copied ? "Copied" : "Copy").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        ShareLink(item: exportText(), preview: SharePreview(e.title)) {
                            Text("Export").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        ShareLink(item: URL(string: "https://getscribbly.vercel.app/?tab=library")!) {
                            Text("Share").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        Button { confirmDelete = true } label: {
                            Text("Delete").font(.system(size: 13, weight: .semibold)).foregroundColor(P.danger)
                        }
                    }
                    .padding(.vertical, 2)

                    // Add to this recording — record more now; it's transcribed and appended to this transcript.
                    if (e.type ?? "").lowercased().contains("voice") || (e.type ?? "").lowercased().contains("audio") {
                        Button {
                            let rec = Recorder.shared
                            guard rec.state == .idle, !Uploader.shared.isUploading else { return }
                            rec.appendTo = e.id
                            rec.place = nil
                            PlaceTagger.shared.tag { Recorder.shared.place = $0 }
                            rec.start()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(P.brand).frame(width: 38, height: 38)
                                    Image(systemName: "mic.fill").foregroundColor(.white).font(.system(size: 16, weight: .semibold))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add to this recording").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                                    Text("Record more now — it's transcribed and appended to this transcript.")
                                        .font(.system(size: 12)).foregroundColor(P.textSec).multilineTextAlignment(.leading)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(P.accent.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                    }

                    AskBox(entry: e)

                    if let t = e.transcript, !t.isEmpty {
                        sectionLabel("Transcript")
                        Text(t).font(.system(size: 14)).foregroundColor(P.textSec.opacity(0.85))
                    }
                }
                .padding(18)
            }
        }
        .background(P.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = exportText()
                    } label: { Label("Copy entry", systemImage: "doc.on.doc") }
                    ShareLink(item: exportText(), preview: SharePreview(entry?.title ?? "Entry")) {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete entry", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundColor(P.textSec) }
            }
        }
        .confirmationDialog("Delete this entry permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await CorpusAPI.deleteEntry(id: entryID)
                    NotificationCenter.default.post(name: .init("scribblyEntryDeleted"), object: nil)
                    dismiss()
                }
            }
        }
        .overlay { if loading && entry == nil { ProgressView().tint(P.accent) } }
        .onAppear { BottomChrome.shared.hideRecordBar = true }
        .onDisappear { BottomChrome.shared.hideRecordBar = false }
        .task {
            entry = preloaded
            // Always refetch to get the transcript, which list rows omit.
            if let full = try? await CorpusAPI.entry(id: entryID) { entry = full }
            loading = false
        }
    }

    /// Send to Claude / GPT / Grok: opens a NEW chat in that app/site with the
    /// COMPLETE transcript. If the whole thing fits in the chat link it goes in
    /// directly; if it's too long for that site's link limit (Grok's is ~7,700
    /// characters, measured 2026-10-09), the chat gets a link to the full
    /// plain-text transcript plus as much of it inline as fits — never a
    /// summary — and the full text is also put on the clipboard.
    private func fullBody(_ e: Entry) -> String {
        "Here's the full transcript of \"\(e.title)\" from my Scribbly library (\(e.date ?? "")). Let's discuss it.\n\n\(e.transcript ?? "")"
    }

    private func chatURL(_ dest: Destination, _ text: String) -> URL? {
        var comps = URLComponents(string: dest.base)!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    private func send(_ e: Entry, to dest: Destination) {
        let full = fullBody(e)
        if dest == .codex {
            UIPasteboard.general.string = full
            if let url = URL(string: dest.base) { UIApplication.shared.open(url) }
            return
        }
        // Everything fits → paste it all, done.
        if let url = chatURL(dest, full), url.absoluteString.count <= dest.cap {
            UIApplication.shared.open(url); return
        }
        UIPasteboard.general.string = full
        Task { @MainActor in
            let link = await shareLink(e.id)
            let words = (e.transcript ?? "").split { $0 == " " || $0 == "\n" }.count
            let head = link.map {
                "Read the COMPLETE transcript of \"\(e.title)\" (\(words) words) from my Scribbly library here: \($0) — read all of it before answering. It's also below, as much as fits in this message:\n\n"
            } ?? "Here's the transcript of \"\(e.title)\" from my Scribbly library (the full text is on my clipboard; I'll paste the rest):\n\n"
            // Fit as much transcript as the site's link limit allows.
            let transcript = e.transcript ?? ""
            var lo = 0, hi = transcript.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                let candidate = head + String(transcript.prefix(mid)) + "…"
                if let u = chatURL(dest, candidate), u.absoluteString.count <= dest.cap { lo = mid } else { hi = mid - 1 }
            }
            let text = head + String(transcript.prefix(lo)) + (lo < transcript.count ? "…" : "")
            if let url = chatURL(dest, text) { _ = await UIApplication.shared.open(url) }
        }
    }

    /// Unguessable link to the full plain-text transcript (Sharp's Cloud Computer).
    private func shareLink(_ entryID: String) async -> String? {
        let base = CorpusAPI.voiceIngestURL.replacingOccurrences(of: "/upload", with: "")
        guard let u = URL(string: base + "/share") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"; req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entryId": entryID])
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = j["token"] as? String else { return nil }
        return base + "/s/" + t
    }

    private enum Destination: String, CaseIterable, Identifiable {
        case claude = "Claude", chatgpt = "ChatGPT", grok = "Grok", codex = "Codex"
        var id: String { rawValue }
        var base: String {
            switch self {
            case .claude:  return "https://claude.ai/new"
            case .chatgpt: return "https://chatgpt.com/"
            case .grok:    return "https://grok.com/"
            case .codex:   return "https://chatgpt.com/codex"
            }
        }
        /// Max length of the whole chat URL (percent-encoded) per site. Grok
        /// measured: 200 OK up to ~7,700 chars, 431 above — kept under that
        /// with headroom for cookies. Over the cap → link + as much as fits.
        var cap: Int {
            switch self {
            case .claude:  return 13_000
            case .chatgpt: return 8_000
            case .grok:    return 6_000
            case .codex:   return 0
            }
        }
        var label: String {
            switch self {
            case .claude:  return "Claude"
            case .chatgpt: return "GPT"
            case .grok:    return "Grok"
            case .codex:   return "Codex"
            }
        }
        var logo: String {
            switch self {
            case .claude:  return "logo-claude"
            case .chatgpt, .codex: return "logo-gpt"
            case .grok:    return "logo-grok"
            }
        }
    }

    private func sendToClaudeButton(_ e: Entry) -> some View {
        HStack(spacing: 8) {
            ForEach([Destination.claude, .chatgpt, .grok]) { d in
                Button { send(e, to: d) } label: {
                    HStack(spacing: 8) {
                        Image(d.logo).resizable().scaledToFit().frame(width: 22, height: 22)
                            .padding(d == .chatgpt ? 3 : 0)
                            .background(d == .chatgpt ? Color.white : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(d.label).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.border))
                }
            }
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12, weight: .bold)).foregroundColor(P.textDim).kerning(0.5)
    }
}

/// Grounded per-entry chat. Answers strictly from this entry's content.
struct AskBox: View {
    let entry: Entry
    @State private var question = ""
    @State private var turns: [(role: String, text: String)] = []
    @State private var asking = false
    @State private var saving = false
    @State private var savedNote: String?

    private var title: String {
        switch entry.type {
        case "Voice Note": return "Ask this recording"
        case "YouTube":    return "Ask this video"
        default:           return "Ask this note"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.white).padding(.top, 8)
            ForEach(turns.indices, id: \.self) { i in
                let turn = turns[i]
                HStack {
                    if turn.role == "user" { Spacer() }
                    Text(turn.text).font(.system(size: 14))
                        .foregroundColor(turn.role == "user" ? .white : P.textSec)
                        .padding(10)
                        .background(turn.role == "user" ? P.accent.opacity(0.25) : P.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if turn.role != "user" { Spacer() }
                }
            }
            HStack {
                TextField("Ask…", text: $question).submitLabel(.send).onSubmit { Task { await ask() } }
                    .padding(10).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                Button { Task { await ask() } } label: {
                    if asking { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundColor(P.accent) }
                }.disabled(asking)
            }
            if !turns.isEmpty {
                Button {
                    Task { await saveDiscussion() }
                } label: {
                    Label(saving ? "Saving…" : (savedNote ?? "Save discussion to library"),
                          systemImage: savedNote == nil ? "tray.and.arrow.down" : "checkmark")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(P.accent).clipShape(RoundedRectangle(cornerRadius: 12))
                }.disabled(saving || savedNote != nil)
            }
        }
        .padding(14).background(P.surface.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
    }

    /// Appends this Q&A to the entry's transcript, re-summarises, and saves —
    /// the "discuss, then commit the enriched version to the corpus" flow.
    private func saveDiscussion() async {
        saving = true; defer { saving = false }
        do {
            var req = URLRequest(url: URL(string: "\(CorpusAPI.appBase)/api/ingest")!)
            req.httpMethod = "POST"; req.timeoutInterval = 180
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["action": "append-discussion", "id": entry.id,
                                       "turns": turns.map { ["role": $0.role, "text": $0.text] }]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            savedNote = ok ? "Saved to library" : ((json?["error"] as? String) ?? "Save failed")
        } catch { savedNote = error.localizedDescription }
    }

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        asking = true; question = ""
        turns.append((role: "user", text: q))
        let history = turns.suffix(8).map { ["role": $0.role, "content": $0.text] }
        do {
            let answer = try await CorpusAPI.ask(entry: entry, question: q, history: history)
            turns.append((role: "assistant", text: answer))
        } catch {
            turns.append((role: "assistant", text: "Error: \(error.localizedDescription)"))
        }
        asking = false
    }
}
