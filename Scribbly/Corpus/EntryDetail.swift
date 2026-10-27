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
    @State private var deleting = false
    @State private var deleteError: String?
    /// Settings → Send to → Default destination ("Claude" / "GPT" / "Grok").
    @AppStorage("defaultDestination") private var defaultDestination = "Claude"
    @ObservedObject private var creators = CreatorDirectory.shared
    /// The original link when the entry row has none (master_corpus.source_url).
    @State private var mirrorSource: URL?

    private func originalLink(_ e: Entry) -> URL? { e.sourceLink ?? mirrorSource }
    private func originalLabel(_ u: URL) -> String {
        let h = (u.host ?? "").lowercased()
        if h.contains("youtube") || h.contains("youtu.be") { return "Open on YouTube" }
        if h.contains("instagram") { return "Open on Instagram" }
        if h.contains("tiktok") { return "Open on TikTok" }
        if h.contains("spotify") || h.contains("podcasts.apple") { return "Open the episode" }
        return "Open original"
    }

    /// Copy choices: just the summary, just the transcript, or the full entry.
    private func summaryText() -> String {
        guard let e = entry else { return "" }
        return (e.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func transcriptText() -> String {
        guard let e = entry else { return "" }
        return (e.cleanTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
    }

    private func exportText() -> String {
        guard let e = entry else { return "" }
        var out = "\(e.title)\n\(e.type ?? "") · \(e.displayDate)\n"
        if let t = e.tags, !t.isEmpty { out += "Tags: \(t)\n" }
        if let s = e.summary, !s.isEmpty { out += "\nSUMMARY\n\(s)\n" }
        if let tr = e.cleanTranscript, !tr.isEmpty { out += "\nTRANSCRIPT\n\(tr)\n" }
        return out
    }

    /// What Share sends: the entry itself — title, summary, transcript — plus
    /// its source link when it has one (Notion page, or the YouTube video).
    private func shareText(_ e: Entry) -> String {
        var out = e.title + "\n"
        if let link = e.sourceLink { out += link.absoluteString + "\n" }
        if let s = e.summary, !s.isEmpty { out += "\n" + s + "\n" }
        if let tr = e.cleanTranscript, !tr.isEmpty { out += "\nTranscript:\n" + tr + "\n" }
        return out
    }

    /// Copy / export / delete, as a glass circle beside the wordmark.
    private var moreMenu: some View {
        Menu {
            Button { copy(summaryText()) } label: { Label("Copy summary", systemImage: "text.alignleft") }
            Button { copy(transcriptText()) } label: { Label("Copy transcript", systemImage: "text.quote") }
            Button { copy(exportText()) } label: { Label("Copy both", systemImage: "doc.on.doc") }
            ShareLink(item: exportText(), preview: SharePreview(entry?.title ?? "Entry")) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete entry", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                .foregroundColor(P.ink)
                .frame(width: 38, height: 38)
                .sinkyGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .accessibilityLabel("More actions")
    }

    /// "Voice note · Oct 23" over the banner; the entry's own title follows below it.
    private var bannerSubtitle: String {
        guard let e = entry else { return "Entry" }
        let kind = e.isVoice ? e.kindLabel : e.displayType
        return kind + " · " + e.displayDate
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: "", subtitle: bannerSubtitle, underNavBar: true, accessory: AnyView(moreMenu))
            if let e = entry {
                VStack(alignment: .leading, spacing: 16) {
                    header(e)
                    if !e.tagList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(e.tagList, id: \.self) { TagChip($0) } }
                        }
                    }

                    if let s = e.summary, !s.isEmpty {
                        sectionLabel("Summary")
                        Text(s).font(.geist(size: 15)).foregroundColor(P.textSec)
                    }
                    sectionLabel("Send to")
                    sendToClaudeButton(e)

                    // Copy · Export · Share · Delete
                    HStack {
                        Menu {
                            Button { copy(summaryText()) } label: { Label("Summary", systemImage: "text.alignleft") }
                                .disabled(summaryText().isEmpty)
                            Button { copy(transcriptText()) } label: { Label("Transcript", systemImage: "text.quote") }
                                .disabled(transcriptText().isEmpty)
                            Button { copy(exportText()) } label: { Label("Both — summary + transcript", systemImage: "doc.on.doc") }
                        } label: {
                            Text(copied ? "Copied" : "Copy").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        ShareLink(item: exportText(), preview: SharePreview(e.title)) {
                            Text("Export").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        ShareLink(item: shareText(e), subject: Text(e.title), preview: SharePreview(e.title)) {
                            Text("Share").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                        }
                        Spacer()
                        Button { confirmDelete = true } label: {
                            if deleting { ProgressView().controlSize(.small).tint(P.danger) }
                            else { Text("Delete").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.danger) }
                        }
                        .disabled(deleting)
                    }
                    .padding(.vertical, 2)
                    if let err = deleteError {
                        Text("Couldn't delete: \(err)").font(.geist(size: 12)).foregroundColor(P.danger)
                    }

                    // Add to this recording — record more now; it's transcribed and appended to this transcript.
                    if (e.type ?? "").lowercased().contains("voice") || (e.type ?? "").lowercased().contains("audio") {
                        Button {
                            let rec = Recorder.shared
                            // Uploads queue independently; recording can start while one uploads.
                            guard rec.state == .idle else { return }
                            rec.appendTo = e.id
                            rec.place = nil
                            PlaceTagger.shared.tag { Recorder.shared.place = $0 }
                            rec.start()
                        } label: {
                            // Same record button as the centre of the Home tab bar:
                            // an ink disc with a copper dot, ringed off the background.
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(P.bg).frame(width: 46, height: 46)
                                    Circle().stroke(P.border, lineWidth: 1).frame(width: 46, height: 46)
                                    Circle().fill(P.ink).frame(width: 38, height: 38)
                                    Circle().fill(P.accent).frame(width: 12, height: 12)
                                }
                                Text("Add to this recording").font(.geist(size: 13, weight: .medium)).foregroundColor(P.textSec)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Add to this recording")
                        .accessibilityHint("Records more; it's transcribed and added to the end of this transcript.")
                        .buttonStyle(.plain)
                    }

                    AskBox(entry: e)

                    if let t = e.cleanTranscript, !t.isEmpty {
                        sectionLabel("Transcript")
                        Text(t).font(.geist(size: 14)).foregroundColor(P.textSec.opacity(0.85))
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
            }
            }
        }
        .background(SinkyBackdrop())
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this entry permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleting = true
                deleteError = nil
                Task {
                    do {
                        try await CorpusAPI.deleteEntry(id: entryID)
                        deleting = false
                        NotificationCenter.default.post(name: .init("scribblyEntryDeleted"), object: nil)
                        dismiss()
                    } catch {
                        deleting = false
                        deleteError = error.localizedDescription
                    }
                }
            }
        }
        .overlay { if loading && entry == nil { ProgressView().tint(P.accent) } }
        // The tab bar stays visible here (pages inset for it), so tapping the
        // current tab can always pop back to its root.
        .onAppear { BottomChrome.shared.savedTitle = nil }
        .task {
            entry = preloaded
            await CreatorDirectory.shared.loadIfNeeded()
            // Always refetch to get the transcript, which list rows omit.
            if let full = try? await CorpusAPI.entry(id: entryID) { entry = full }
            loading = false
            if let e = entry, e.sourceLink == nil { mirrorSource = await Self.mirrorSourceURL(e.id) }
        }
    }

    /// Creator, title ("Creator — Title" when the title doesn't name them),
    /// the meta line (voice: time · duration · place), and Open original.
    @ViewBuilder private func header(_ e: Entry) -> some View {
        let creator = creators.creator(for: e)
        if let c = creator {
            Text(c).monoLabel(10.5, color: P.accent)
        }
        Text(e.displayTitle(creator: creator)).font(.geist(size: 26, weight: .semibold)).tracking(-0.8).foregroundColor(P.ink)
        // The creator is already the accent line above, so the meta line skips it.
        Text(e.metaLine(creator: nil)).font(.geist(size: 13)).foregroundColor(P.textSec)
        GradientRule(width: 64)

        if let link = originalLink(e) {
            Link(destination: link) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square.fill").font(.system(size: 16, weight: .semibold))
                    Text(originalLabel(link)).font(.geist(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(link.host ?? "").font(.geist(size: 11)).foregroundColor(P.textDim).lineLimit(1)
                }
                .foregroundColor(P.ink)
                .padding(.horizontal, 14).frame(height: 46)
                .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(P.accent.opacity(0.7), lineWidth: 1.2))
            }
            .accessibilityLabel(originalLabel(link))
        }
    }

    /// The entry's original URL from its master_corpus mirror row, if any.
    private static func mirrorSourceURL(_ id: String) async -> URL? {
        struct Row: Decodable { let source_url: String? }
        let url = CorpusAPI.restURL("master_corpus", [
            URLQueryItem(name: "select", value: "source_url"),
            URLQueryItem(name: "id", value: "eq.scribbly_\(id)")
        ])
        guard let rows = try? await CorpusAPI.getJSON(url, as: [Row].self, timeout: 15),
              let s = rows.first?.source_url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    /// Send to Claude / GPT / Grok: opens a NEW chat in that app/site with the
    /// COMPLETE transcript. If the whole thing fits in the chat link it goes in
    /// directly; if it's too long for that site's link limit (Grok's is ~7,700
    /// characters, measured 2026-10-09), the chat gets a link to the full
    /// plain-text transcript plus as much of it inline as fits — never a
    /// summary — and the full text is also put on the clipboard.
    private func fullBody(_ e: Entry) -> String {
        "Here's the full transcript of \"\(e.title)\" from my Scribbly library (\(e.displayDate)). Let's discuss it.\n\n\(e.cleanTranscript ?? "")"
    }

    private func chatURL(_ dest: Destination, _ text: String) -> URL? {
        var comps = URLComponents(string: dest.base)!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    private func send(_ e: Entry, to dest: Destination) {
        let full = fullBody(e)
        // Everything fits → paste it all, done.
        if let url = chatURL(dest, full), url.absoluteString.count <= dest.cap {
            UIApplication.shared.open(url); return
        }
        UIPasteboard.general.string = full
        Task { @MainActor in
            let link = await shareLink(e.id)
            let words = (e.cleanTranscript ?? "").split { $0 == " " || $0 == "\n" }.count
            let head = link.map {
                "Read the COMPLETE transcript of \"\(e.title)\" (\(words) words) from my Scribbly library here: \($0) — read all of it before answering. It's also below, as much as fits in this message:\n\n"
            } ?? "Here's the transcript of \"\(e.title)\" from my Scribbly library (the full text is on my clipboard; I'll paste the rest):\n\n"
            // Fit as much transcript as the site's link limit allows.
            let transcript = e.cleanTranscript ?? ""
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
        case claude = "Claude", chatgpt = "ChatGPT", grok = "Grok"
        var id: String { rawValue }
        var base: String {
            switch self {
            case .claude:  return "https://claude.ai/new"
            case .chatgpt: return "https://chatgpt.com/"
            case .grok:    return "https://grok.com/"
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
            }
        }
        var label: String {
            switch self {
            case .claude:  return "Claude"
            case .chatgpt: return "GPT"
            case .grok:    return "Grok"
            }
        }
        var logo: String {
            switch self {
            case .claude:  return "logo-claude"
            case .chatgpt: return "logo-gpt"
            case .grok:    return "logo-grok"
            }
        }
    }

    /// Claude · GPT · Grok, with the Settings default first and highlighted.
    private var destinations: [Destination] {
        let all = Destination.allCases
        guard let preferred = all.first(where: { $0.label == defaultDestination }) else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    private func sendToClaudeButton(_ e: Entry) -> some View {
        HStack(spacing: 8) {
            ForEach(destinations) { d in
                let primary = d.label == defaultDestination
                Button { send(e, to: d) } label: {
                    HStack(spacing: 8) {
                        Image(d.logo).resizable().scaledToFit().frame(width: 22, height: 22)
                            .padding(d == .chatgpt ? 3 : 0)
                            .background(d == .chatgpt ? Color.white : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(d.label).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(primary ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.edge), lineWidth: primary ? 1.5 : 1))
                }
                .accessibilityHint(primary ? "Default destination" : "")
            }
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).sectionHead()
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
            Text(title).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink).padding(.top, 8)
            ForEach(turns.indices, id: \.self) { i in
                let turn = turns[i]
                HStack {
                    if turn.role == "user" { Spacer() }
                    Text(turn.text).font(.geist(size: 14))
                        .foregroundColor(turn.role == "user" ? .white : P.textSec)
                        .padding(10)
                        .background(turn.role == "user" ? P.accent.opacity(0.25) : P.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if turn.role != "user" { Spacer() }
                }
            }
            HStack {
                TextField("Ask…", text: $question).submitLabel(.send).onSubmit { Task { await ask() } }
                    .padding(10).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button { Task { await ask() } } label: {
                    if asking { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.geist(size: 26)).foregroundColor(P.accent) }
                }.disabled(asking)
            }
            if !turns.isEmpty {
                Button {
                    Task { await saveDiscussion() }
                } label: {
                    Label(saving ? "Saving…" : (savedNote ?? "Save discussion to library"),
                          systemImage: savedNote == nil ? "tray.and.arrow.down" : "checkmark")
                        .font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(P.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.disabled(saving || savedNote != nil)
            }
        }
        .padding(14).background(P.surface.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
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
