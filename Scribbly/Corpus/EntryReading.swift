import SwiftUI
import AVFoundation

// MARK: - Recording playback

/// Plays an entry's kept recording. The cloud computer hands out a short-lived
/// private link (only to the entry's owner); playback streams from it.
@MainActor
final class EntryAudio: ObservableObject {
    @Published var ready = false
    @Published var failed: String?
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1
    @Published var scrubbing = false

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private let entryID: String

    init(entryID: String, knownDuration: Double?) {
        self.entryID = entryID
        self.duration = knownDuration ?? 0
    }

    func prepare() async {
        guard player == nil, failed == nil else { return }
        var base = CorpusAPI.voiceIngestURL
        if let r = base.range(of: "/upload", options: .backwards) { base = String(base[..<r.lowerBound]) }
        guard var c = URLComponents(string: base + "/audio-url") else { return }
        c.queryItems = [URLQueryItem(name: "entry", value: entryID)]
        var req = URLRequest(url: c.url!); req.timeoutInterval = 20
        if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let s = obj["url"] as? String, let url = URL(string: s) else {
                failed = code == 404 ? "No audio kept for this one." : "Couldn't load the audio (HTTP \(code))."
                EventLog.shared.log("audio.url_fail", ["entry": entryID, "code": code])
                return
            }
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.scrubbing { self.time = t.seconds.isFinite ? t.seconds : 0 }
                    if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playing = false; self?.seek(0) }
            }
            ready = true
            EventLog.shared.log("audio.ready", ["entry": entryID])
        } catch {
            failed = "Couldn't load the audio: \(error.localizedDescription)"
            EventLog.shared.log("audio.url_fail", ["entry": entryID, "error": error.localizedDescription])
        }
    }

    func toggle() {
        guard let p = player else { return }
        if playing { p.pause(); playing = false; return }
        guard Recorder.shared.state == .idle else { failed = "Finish the recording in progress first."; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.playImmediately(atRate: rate); playing = true
        EventLog.shared.log("audio.play", ["entry": entryID, "at": Int(time)])
    }
    func skip(_ by: Double) { seek(max(0, min(duration, time + by))) }
    func seek(_ to: Double) {
        time = to
        player?.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    /// Jump to a paragraph and start playing from there.
    func play(from t: Double) {
        seek(t)
        if !playing { toggle() }
    }
    func cycleRate() {
        let steps: [Float] = [1, 1.25, 1.5, 2, 0.75]
        rate = steps[((steps.firstIndex(of: rate) ?? 0) + 1) % steps.count]
        if playing { player?.rate = rate }
    }
    func stop() {
        player?.pause(); playing = false
        if let o = observer { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        observer = nil; endObserver = nil
    }

    static func clock(_ s: Double) -> String {
        let n = Int(max(0, s.isFinite ? s : 0))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
                         : String(format: "%02d:%02d", n / 60, n % 60)
    }
}

struct EntryAudioCard: View {
    @ObservedObject var audio: EntryAudio
    let title: String
    /// When set, the tile also carries "Add to this recording" — one place to
    /// listen back or keep talking.
    var onAddMore: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let f = audio.failed {
                Text(f).font(.geist(size: 13)).foregroundColor(P.textDim).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    Button { audio.toggle() } label: {
                        ZStack {
                            Circle().fill(P.ink).frame(width: 44, height: 44)
                            if !audio.ready { ProgressView().tint(P.bg).controlSize(.small) }
                            else {
                                Image(systemName: audio.playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17, weight: .bold)).foregroundColor(P.bg)
                                    .offset(x: audio.playing ? 0 : 1.5)
                            }
                        }
                    }
                    .disabled(!audio.ready)
                    .accessibilityLabel(audio.playing ? "Pause" : "Play")
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { audio.time }, set: { audio.time = $0 }),
                               in: 0...max(1, audio.duration),
                               onEditingChanged: { editing in
                                   audio.scrubbing = editing
                                   if !editing { audio.seek(audio.time) }
                               })
                            .tint(P.accent)
                            .controlSize(.mini)
                        HStack {
                            Text(EntryAudio.clock(audio.time))
                            Spacer()
                            Text(EntryAudio.clock(audio.duration))
                        }
                        .font(.geist(size: 10.5, design: .monospaced)).monospacedDigit().foregroundColor(P.textDim)
                    }
                    Button { audio.skip(-15) } label: {
                        Image(systemName: "gobackward.15").font(.system(size: 17)).foregroundColor(P.ink).frame(width: 30, height: 40)
                    }
                    .accessibilityLabel("Back 15 seconds")
                    Button { audio.skip(15) } label: {
                        Image(systemName: "goforward.15").font(.system(size: 17)).foregroundColor(P.ink).frame(width: 30, height: 40)
                    }
                    .accessibilityLabel("Forward 15 seconds")
                    Button { audio.cycleRate() } label: {
                        Text(audio.rate == 1 ? "1x" : String(format: "%gx", audio.rate))
                            .font(.geist(size: 12.5, weight: .semibold)).foregroundColor(P.ink)
                            .frame(width: 38, height: 26).background(Capsule().fill(P.surface2))
                    }
                    .accessibilityLabel("Playback speed")
                    // Add to this recording sits opposite the play button: a record dot.
                    if let add = onAddMore {
                        Button(action: add) {
                            ZStack {
                                Circle().stroke(P.edge, lineWidth: 1).background(Circle().fill(P.surface2)).frame(width: 36, height: 36)
                                Circle().fill(P.accent).frame(width: 12, height: 12)
                            }
                        }
                        .accessibilityLabel("Add to this recording")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(P.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.border))
    }
}

// MARK: - Send to Grok Bots

/// Hands an entry to one of Connor's Grok Bots (Donna first) — the same
/// hand-off Claude and ChatGPT use; the bot is woken and gets the title,
/// summary and a link to the full transcript.
@MainActor
final class GrokBots: ObservableObject {
    static let shared = GrokBots()
    struct Bot: Decodable, Identifiable { let name: String; let about: String?; var id: String { name } }
    @Published var bots: [Bot] = []
    @Published var sending: String?
    @Published var result: String?

    private var base: String {
        var u = CorpusAPI.voiceIngestURL
        if let r = u.range(of: "/upload", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }
    func load() async {
        guard bots.isEmpty, let url = URL(string: base + "/bots") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
        struct R: Decodable { let bots: [Bot] }
        if let (d, _) = try? await URLSession.shared.data(for: req), let r = try? JSONDecoder().decode(R.self, from: d) { bots = r.bots }
    }
    func send(entryID: String, to bot: String, link: String?) async {
        sending = bot; result = nil
        defer { sending = nil }
        var req = URLRequest(url: URL(string: base + "/send-to-bot")!)
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
        var body: [String: Any] = ["entryId": entryID, "bot": bot]
        if let link { body["link"] = link }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { result = "Sent to \(bot)."; EventLog.shared.log("grokbot.sent", ["bot": bot, "entry": entryID]) }
            else {
                let err = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
                result = "Didn't send: \(err ?? "HTTP \(code)")"
                EventLog.shared.log("grokbot.send_fail", ["bot": bot, "code": code, "error": err ?? ""])
            }
        } catch {
            result = "Didn't send: \(error.localizedDescription)"
        }
    }
}

struct GrokBotsSheet: View {
    let entryID: String
    let link: () async -> String?
    @ObservedObject private var gb = GrokBots.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let r = gb.result {
                    Text(r).font(.geist(size: 14, weight: .semibold)).foregroundColor(r.hasPrefix("Sent") ? P.good : P.danger)
                }
                ForEach(gb.bots) { b in
                    Button {
                        Task { await gb.send(entryID: entryID, to: b.name, link: await link()) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name).font(.geist(size: 16, weight: .semibold)).foregroundColor(P.ink)
                                if let a = b.about, !a.isEmpty { Text(a).font(.geist(size: 12)).foregroundColor(P.textDim).lineLimit(2) }
                            }
                            Spacer()
                            if gb.sending == b.name { ProgressView() } else { Image(systemName: "paperplane").foregroundColor(P.accent) }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(gb.sending != nil)
                }
                if gb.bots.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            }
            .scrollContentBackground(.hidden).background(P.bg)
            .navigationTitle("Send to Grok Bots").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { gb.result = nil; await gb.load() }
        }
    }
}

// MARK: - Readable summary

/// The summary laid out with room to breathe: paragraphs, "Key Points:"-style
/// headings, and real bullets instead of one block of text.
struct StructuredSummary: View {
    let text: String

    private enum Block: Hashable { case heading(String), bullet(String), para(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let b = ["• ", "- ", "* ", "· "].first(where: { line.hasPrefix($0) }) {
                out.append(.bullet(String(line.dropFirst(b.count))))
            } else if line.hasSuffix(":") && line.count <= 40 {
                out.append(.heading(String(line.dropLast())))
            } else {
                out.append(.para(line))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).font(.geist(size: 16.5, weight: .semibold)).foregroundColor(P.ink).padding(.top, 8)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(P.accent).frame(width: 5, height: 5).offset(y: -3)
                        Text(t).font(.geist(size: 15)).foregroundColor(P.textSec).lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case .para(let t):
                    Text(t).font(.geist(size: 15.5)).foregroundColor(P.textSec).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Readable transcript

/// The transcript as spaced paragraphs, each with its time in the recording.
/// Tapping a time plays from there. Older entries (no timing) are split into
/// paragraphs of a few sentences each so they never read as one solid block.
struct ParagraphTranscript: View {
    let entry: Entry
    var audio: EntryAudio?

    private var paras: [TranscriptPara] {
        if let p = entry.paragraphs, !p.isEmpty {
            return p.map { TranscriptPara(t: $0.t, text: TranscriptCleaner.clean($0.text)) }.filter { !$0.text.isEmpty }
        }
        return Self.split(entry.cleanTranscript ?? "").map { TranscriptPara(t: -1, text: $0) }
    }

    /// Existing breaks are kept; otherwise ~4 sentences (or ~600 characters) per paragraph.
    static func split(_ t: String) -> [String] {
        let blocks = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [String] = []
        for b in blocks {
            var cur = "", count = 0
            b.enumerateSubstrings(in: b.startIndex..., options: .bySentences) { s, _, _, _ in
                guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return }
                cur += (cur.isEmpty ? "" : " ") + s; count += 1
                if count >= 4 || cur.count >= 600 { out.append(cur); cur = ""; count = 0 }
            }
            if !cur.isEmpty { out.append(cur) }
        }
        return out
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 6) {
                    if p.t >= 0 {
                        Button { audio?.play(from: p.t) } label: {
                            Text(EntryAudio.clock(p.t))
                                .font(.geist(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
                                .foregroundColor(audio?.ready == true ? P.accent : P.textDim)
                        }
                        .buttonStyle(.plain)
                        .disabled(audio?.ready != true)
                        .accessibilityLabel("Play from \(EntryAudio.clock(p.t))")
                    }
                    Text(p.text).font(.geist(size: 15.5)).foregroundColor(P.ink.opacity(0.9)).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
