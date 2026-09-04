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
                    if let t = e.transcript, !t.isEmpty {
                        HStack {
                            sectionLabel("Transcript")
                            Spacer()
                            Button {
                                UIPasteboard.general.string = t
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13)).foregroundColor(P.accent)
                            }
                        }
                        Text(t).font(.system(size: 14)).foregroundColor(P.textSec.opacity(0.85))
                    }

                    sendToClaudeButton(e)
                    AskBox(entry: e)
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
        .task {
            entry = preloaded
            // Always refetch to get the transcript, which list rows omit.
            if let full = try? await CorpusAPI.entry(id: entryID) { entry = full }
            loading = false
        }
    }

    /// Opens a brand-new chat in the Claude app with this entry pre-loaded.
    /// claude.ai/new?q= is capped ~14k chars, so long transcripts send the
    /// summary instead of a truncated transcript.
    private func sendToClaudeButton(_ e: Entry) -> some View {
        Button {
            let transcript = e.transcript ?? ""
            let body: String
            if transcript.count <= 13_000 {
                body = "Here's a transcript titled \"\(e.title)\" from my Scribbly library. Let's discuss it.\n\n\(transcript)"
            } else {
                body = "Here's a summary of \"\(e.title)\" from my Scribbly library (the full transcript is \(transcript.count) characters, too long to paste). Let's discuss it.\n\n\(e.summary ?? "")"
            }
            var comps = URLComponents(string: "https://claude.ai/new")!
            comps.queryItems = [URLQueryItem(name: "q", value: body)]
            if let url = comps.url { UIApplication.shared.open(url) }
        } label: {
            Label("Send to Claude", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(P.brand).clipShape(RoundedRectangle(cornerRadius: 12))
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
