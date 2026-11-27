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
    /// The kept recording, when there is one.
    @State private var audio: EntryAudio?
    @State private var tab = 0   // 0 Summary · 1 Transcript
    @State private var showBots = false

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

    private var bannerTitle: String {
        guard let e = entry else { return "" }
        return e.displayTitle(creator: creators.creator(for: e))
    }
    private var bannerEyebrow: String? {
        guard let e = entry else { return nil }
        return creators.creator(for: e)?.uppercased()
    }

    /// "Voice note · Oct 23" over the banner; the entry's own title follows below it.
    private var bannerSubtitle: String {
        guard let e = entry else { return "Entry" }
        return e.metaLine(creator: nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            // The entry's title and its details live IN the banner: creator,
            // title, then "Recording · Oct 27, 2:37 PM · 3m 50s · Sleepy Ridge, Orem".
            PageHeader(eyebrow: bannerEyebrow, title: bannerTitle, subtitle: bannerSubtitle,
                       underNavBar: true, titleSize: 26)
            if let e = entry {
                VStack(alignment: .leading, spacing: 16) {
                    header(e)
                    if !e.tagList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(e.tagList, id: \.self) { TagChip($0) } }
                        }
                    }

                    if let a = audio {
                        EntryAudioCard(audio: a, title: e.kindLabel + (e.place.map { " · " + $0 } ?? ""),
                                       onAddMore: isRecordingEntry(e) ? { addMore(e) } : nil)
                    }
                    // Send to + Copy + Share up top, so they never need a scroll.
                    quickActions(e)
                    if hasTranscript(e) {
                        Picker("", selection: $tab) {
                            Text("Summary").tag(0)
                            Text("Transcript").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 2)
                    }
                    if tab == 1 && hasTranscript(e) {
                        ParagraphTranscript(entry: e, audio: audio).padding(.top, 6)
                    } else {
                    if let s = e.summary, !s.isEmpty {
                        sectionLabel("Summary")
                        StructuredSummary(text: s)
                    }
                    // Export · Delete stay at the bottom, small.
                    HStack(spacing: 8) {
                        ShareLink(item: exportText(), preview: SharePreview(e.title)) { smallTile("Export", "arrow.down.doc", P.ink) }
                        Button { confirmDelete = true } label: {
                            if deleting { ProgressView().tint(P.danger).frame(maxWidth: .infinity, minHeight: 36) }
                            else { smallTile("Delete", "trash", P.danger) }
                        }
                        .disabled(deleting)
                    }
                    .padding(.top, 4)
                    if let err = deleteError {
                        Text("Couldn't delete: \(err)").font(.geist(size: 12)).foregroundColor(P.danger)
                    }

                    // Add to this recording lives in the player tile; entries without kept audio still get it here.
                    if isRecordingEntry(e) && audio == nil {
                        Button { addMore(e) } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(P.ink).frame(width: 28, height: 28)
                                    Circle().fill(P.accent).frame(width: 9, height: 9)
                                }
                                Text("Add to this recording").font(.geist(size: 14.5, weight: .semibold)).foregroundColor(P.ink)
                                Spacer(minLength: 6)
                            }
                            .padding(.horizontal, 14).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(P.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.edge))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .accessibilityLabel("Add to this recording")
                        .buttonStyle(.plain)
                    }

                    AskBox(entry: e)
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
        .onDisappear { audio?.stop() }
        .task {
            entry = preloaded
            await CreatorDirectory.shared.loadIfNeeded()
            // Always refetch to get the transcript, which list rows omit.
            if let full = try? await CorpusAPI.entry(id: entryID) { entry = full }
            loading = false
            if let e = entry, e.audio_path != nil, audio == nil {
                let a = EntryAudio(entryID: e.id, knownDuration: e.duration_seconds)
                audio = a
                await a.prepare()
            }
            if let e = entry, e.sourceLink == nil { mirrorSource = await Self.mirrorSourceURL(e.id) }
        }
    }

    /// Creator, title ("Creator — Title" when the title doesn't name them),
    /// the meta line (voice: time · duration · place), and Open original.
    @ViewBuilder private func header(_ e: Entry) -> some View {
        // Creator, title and details are in the banner above.
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

    /// Clear, unmistakable section breaks: Summary · Send to · Transcript.
    private func isRecordingEntry(_ e: Entry) -> Bool {
        let t = (e.type ?? "").lowercased()
        return t.contains("voice") || t.contains("audio")
    }
    private func addMore(_ e: Entry) {
        let rec = Recorder.shared
        // Uploads queue independently; recording can start while one uploads.
        guard rec.state == .idle else { return }
        rec.appendTo = e.id
        rec.place = nil
        PlaceTagger.shared.tag { Recorder.shared.place = $0 }
        rec.start()
    }
    /// One compact row: Claude · GPT · Grok · Bots · Copy · Share.
    @ViewBuilder private func quickActions(_ e: Entry) -> some View {
        HStack(spacing: 6) {
            ForEach(destinations) { d in
                let primary = d.label == defaultDestination
                Button { send(e, to: d) } label: {
                    quickTile(d.label, primary: primary) {
                        Image(d.logo).resizable().scaledToFit().frame(width: 16, height: 16)
                            .padding(d == .chatgpt ? 2 : 0)
                            .background(d == .chatgpt ? Color.white : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to \(d.label)")
            }
            Button { showBots = true } label: {
                quickTile("Bots") { Image("logo-grok").resizable().scaledToFit().frame(width: 16, height: 16) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send to Grok Bots")
            .sheet(isPresented: $showBots) {
                GrokBotsSheet(entryID: e.id, link: { await shareLink(e.id) })
                    .presentationDetents([.medium, .large])
            }
            Menu {
                Button { copy(summaryText()) } label: { Label("Summary", systemImage: "text.alignleft") }
                    .disabled(summaryText().isEmpty)
                Button { copy(transcriptText()) } label: { Label("Transcript", systemImage: "text.quote") }
                    .disabled(transcriptText().isEmpty)
                Button { copy(exportText()) } label: { Label("Both — summary + transcript", systemImage: "doc.on.doc") }
            } label: {
                quickTile(copied ? "Copied" : "Copy") { Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent) }
            }
            ShareLink(item: shareText(e), subject: Text(e.title), preview: SharePreview(e.title)) {
                quickTile("Share") { Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent) }
            }
        }
    }
    private func quickTile<I: View>(_ label: String, primary: Bool = false, @ViewBuilder icon: () -> I) -> some View {
        VStack(spacing: 3) {
            icon().frame(height: 16)
            Text(label).font(.geist(size: 10.5, weight: .semibold)).foregroundColor(P.ink).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(primary ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.edge), lineWidth: primary ? 1.3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func smallTile(_ label: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(label).font(.geist(size: 13, weight: .semibold))
        }
        .foregroundColor(tint)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(P.edge))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func actionTile(_ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            Text(label).font(.geist(size: 13.5, weight: .semibold))
        }
        .foregroundColor(tint)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.edge))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hasTranscript(_ e: Entry) -> Bool { !(e.cleanTranscript ?? "").isEmpty }

    private func sectionLabel(_ t: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.geist(size: 21, weight: .bold)).tracking(-0.5).foregroundColor(P.ink)
            GradientRule(width: 40)
        }
        .padding(.top, 10)
        .accessibilityAddTraits(.isHeader)
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
