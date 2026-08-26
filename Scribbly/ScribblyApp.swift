import SwiftUI
import UIKit

// MARK: - App entry

@main
struct ScribblyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
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
        .onOpenURL { url in if url.scheme == "scribbly" && url.host == "record" { arm() } }
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
                        Text(up.progress < 1 ? "Uploading…" : "Transcribing…")
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
                                if ok { savedTitle = msg ?? "Saved to your library" }
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
