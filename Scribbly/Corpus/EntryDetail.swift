import SwiftUI

/// Full entry view: summary, transcript, tags, copy, and the grounded Ask chat.
struct EntryDetail: View {
    let entryID: String
    let preloaded: Entry?

    @State private var entry: Entry?
    @State private var loading = true
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

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

                    AskBox(entry: e)
                }
                .padding(18)
            }
        }
        .background(P.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && entry == nil { ProgressView().tint(P.accent) } }
        .task {
            entry = preloaded
            // Always refetch to get the transcript, which list rows omit.
            if let full = try? await CorpusAPI.entry(id: entryID) { entry = full }
            loading = false
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
        }
        .padding(14).background(P.surface.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
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
