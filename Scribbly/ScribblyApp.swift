import SwiftUI
import UIKit

// MARK: - App entry

@main
struct ScribblyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                // Anything that didn't finish uploading is retried here, so a
                // recording can never be stranded by a crash, a dead network,
                // or the app being swiped away mid-upload.
                .onAppear { Uploader.shared.resumePending() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification)) { _ in
                    Uploader.shared.resumePending()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches us here when a background upload finishes after termination.
    func application(_ app: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundCompletionHandler = completionHandler
    }
}

// MARK: - Palette (matches the web app)

enum P {
    static let bg = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let surface = Color.white.opacity(0.045)
    static let border = Color.white.opacity(0.09)
    static let textSec = Color(red: 0.60, green: 0.63, blue: 0.68)
    static let textDim = Color(red: 0.42, green: 0.44, blue: 0.50)
    static let accent = Color(red: 0.66, green: 0.33, blue: 0.97)
    static let magenta = Color(red: 0.75, green: 0.15, blue: 0.83)
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.52)
    static let good = Color(red: 0.20, green: 0.83, blue: 0.60)
    static var brand: LinearGradient {
        LinearGradient(colors: [accent, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Root

struct RootView: View {
    @State private var tab = 0
    @State private var armToken = 0

    var body: some View {
        ZStack {
            P.bg.ignoresSafeArea()
            TabView(selection: $tab) {
                RecordView(armToken: armToken)
                    .tabItem { Label("Record", systemImage: "mic.fill") }.tag(0)
                NavigationStack { LibraryScreen() }
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(1)
            }
            .tint(P.accent)
        }
        .onOpenURL { url in
            if url.scheme == "scribbly" && url.host == "record" { arm(); return }
            // Files shared/opened into Scribbly (share sheet, Files app, AirDrop) → ingest.
            if url.isFileURL {
                tab = 1
                Task { await FileIngestModel.shared.handle(url) }
            }
        }
    }

    private func arm() {
        tab = 0
        armToken += 1   // change triggers RecordView to auto-start
    }
}

// MARK: - Record

struct RecordView: View {
    var armToken: Int = 0
    @StateObject private var rec = Recorder()
    @State private var showPendingSheet = false
    @StateObject private var up = Uploader.shared
    @State private var savedTitle: String?
    @State private var showDiscardConfirm = false

    private var timeString: String {
        let t = Int(rec.elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        ZStack {
            P.bg.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()

                Text("Scribbly")
                    .font(.system(size: 30, weight: .heavy, design: .default))
                    .kerning(-0.8)

                if rec.state == .idle && !up.isUploading {
                    Text("Record anything. It keeps going in your pocket,\nthrough calls, until you tap Finish.")
                        .font(.system(size: 14))
                        .foregroundColor(P.textSec)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                // Timer + status
                if rec.state != .idle {
                    VStack(spacing: 6) {
                        Text(timeString)
                            .font(.system(size: 54, weight: .semibold, design: .monospaced))
                            .kerning(-1)
                        Text(statusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(statusColor)
                    }
                }

                WaveBars(level: rec.level, active: rec.state == .recording)
                    .frame(height: 58)
                    .padding(.horizontal, 30)

                Spacer()

                if up.isUploading {
                    VStack(spacing: 10) {
                        ProgressView(value: up.progress)
                            .tint(P.accent)
                            .frame(width: 200)
                        Text(up.stage.isEmpty ? (up.progress < 1 ? "Uploading…" : "Transcribing…") : up.stage)
                            .font(.system(size: 14, weight: .medium))
                        Text("Safe to leave — this finishes in the background.")
                            .font(.system(size: 12)).foregroundColor(P.textDim)
                    }
                } else {
                    controls
                }

                if let t = savedTitle {
                    Label(t, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundColor(P.good)
                        .padding(.horizontal, 24).multilineTextAlignment(.center)
                    Button {
                        Task {
                            // Newest voice entry is the one just saved; hand it to Claude.
                            if let e = try? await CorpusAPI.latestVoiceEntry() {
                                let transcript = e.transcript ?? ""
                                let body = transcript.count <= 13_000
                                    ? "Here's a recording I just made, \"\(e.title)\". Let's discuss it before I file it.\n\n\(transcript)"
                                    : "Here's the summary of a recording I just made, \"\(e.title)\" (full transcript too long to paste). Let's discuss it.\n\n\(e.summary ?? "")"
                                var c = URLComponents(string: "https://claude.ai/new")!
                                c.queryItems = [URLQueryItem(name: "q", value: body)]
                                if let u = c.url { await MainActor.run { UIApplication.shared.open(u) } }
                            }
                        }
                    } label: {
                        Label("Discuss with Claude", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(P.brand).clipShape(Capsule())
                    }
                }
                if up.pendingCount > 0 && !up.isUploading {
                    Label("\(up.pendingCount) recording\(up.pendingCount == 1 ? "" : "s") waiting to upload — tap to manage",
                          systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 12)).foregroundColor(.orange)
                        .padding(.horizontal, 24).multilineTextAlignment(.center)
                        .onTapGesture { showPendingSheet = true }
                }
                if let e = rec.lastError ?? up.lastError {
                    Text(e).font(.system(size: 13)).foregroundColor(P.danger)
                        .multilineTextAlignment(.center).padding(.horizontal, 28)
                }

                Spacer().frame(height: 12)
            }
        }
        .onChange(of: armToken) { _ in
            if rec.state == .idle && !up.isUploading { savedTitle = nil; rec.start() }
        }
        .sheet(isPresented: $showPendingSheet) {
            PendingRecoverySheet(uploader: up).presentationDetents([.medium, .large])
        }
        .alert("Discard this recording?", isPresented: $showDiscardConfirm) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard", role: .destructive) { rec.discard() }
        } message: { Text("The audio will be deleted and cannot be recovered.") }
    }

    private var statusText: String {
        if rec.interrupted { return "Interrupted — resuming automatically" }
        switch rec.state {
        case .recording: return "Recording"
        case .paused:    return "Paused"
        case .finishing: return "Finishing…"
        case .idle:      return ""
        }
    }

    private var statusColor: Color {
        if rec.interrupted { return .orange }
        return rec.state == .recording ? P.magenta : P.textDim
    }

    @ViewBuilder private var controls: some View {
        switch rec.state {
        case .idle:
            Button {
                savedTitle = nil
                rec.start()
            } label: {
                ZStack {
                    Circle().fill(P.brand)
                        .frame(width: 96, height: 96)
                        .shadow(color: P.accent.opacity(0.55), radius: 24, y: 8)
                    Image(systemName: "mic.fill").font(.system(size: 36)).foregroundColor(.white)
                }
            }

        case .recording, .paused:
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    // Discard
                    Button { showDiscardConfirm = true } label: {
                        circleButton(icon: "trash", tint: P.danger)
                    }
                    // Pause / Resume
                    Button {
                        rec.state == .recording ? rec.pause() : rec.resume()
                    } label: {
                        circleButton(icon: rec.state == .recording ? "pause.fill" : "play.fill",
                                     tint: .white, size: 76)
                    }
                    // Finish — the ONLY thing that ends a recording
                    Button {
                        rec.finish { url, dur in
                            guard let url else { return }
                            up.upload(fileURL: url, duration: dur) { ok, msg in
                                savedTitle = ok ? (msg ?? "Saved to your library") : nil
                            }
                        }
                    } label: {
                        circleButton(icon: "checkmark", tint: P.good)
                    }
                }
                Text("Only Finish stops the recording")
                    .font(.system(size: 11)).foregroundColor(P.textDim)
            }

        case .finishing:
            ProgressView().tint(P.accent)
        }
    }

    private func circleButton(icon: String, tint: Color, size: CGFloat = 60) -> some View {
        ZStack {
            Circle().fill(P.surface)
                .overlay(Circle().stroke(P.border, lineWidth: 1))
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundColor(tint)
        }
    }
}

/// Live input meter. Mirrors the web app's 28-bar waveform.
struct WaveBars: View {
    let level: Float
    let active: Bool
    private let count = 28

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let d = abs(Double(i) - Double(count) / 2) / (Double(count) / 2)
                let jitter = 0.55 + Double((i &* 37) % 100) / 110.0
                let h = active
                    ? max(4, Double(level) * 58 * (1 - d * 0.65) * jitter)
                    : 4
                Capsule()
                    .fill(active ? AnyShapeStyle(P.brand) : AnyShapeStyle(P.border))
                    .frame(width: 4, height: h)
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}


/// Every stuck upload is actionable: retry it, export the raw bytes, or
/// discard it knowingly. Nothing is ever lost silently.
struct PendingRecoverySheet: View {
    @ObservedObject var uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Uploader.PendingItem] = []

    var body: some View {
        NavigationStack {
            List {
                if let e = uploader.lastError {
                    Text(e).font(.system(size: 12)).foregroundColor(.orange)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)) · \(item.createdAt.formatted(.relative(presentation: .named)))"
                             + (item.attempts > 0 ? " · \(item.attempts) attempt\(item.attempts == 1 ? "" : "s")" : ""))
                            .font(.system(size: 12)).foregroundColor(P.textSec)
                        HStack(spacing: 14) {
                            Button("Retry") {
                                uploader.resumePending(); dismiss()
                            }.font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                            ShareLink(item: item.fileURL) {
                                Text("Export file").font(.system(size: 13, weight: .semibold)).foregroundColor(P.accent)
                            }
                            Button("Discard", role: .destructive) {
                                uploader.discard(id: item.id)
                                items = uploader.pendingItems()
                                if items.isEmpty { dismiss() }
                            }.font(.system(size: 13, weight: .semibold))
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("Waiting to upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .onAppear { items = uploader.pendingItems() }
        }
    }
}
