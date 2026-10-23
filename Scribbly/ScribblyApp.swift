import SwiftUI
import UIKit
import PhotosUI

// MARK: - App entry

@main
struct ScribblyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        // Must exist before any view appears: Siri/Control Center/widgets can
        // launch Scribbly in the background just to start a recording.
        CrashReporter.shared.start()
        SinkyAppearance.apply()
        MainActor.assumeIsolated { RecordingLiveActivity.shared.bind() }
        // Watch memos sent over WatchConnectivity arrive even when the app is
        // woken in the background and no view ever appears.
        WatchBridge.shared.activate()
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .modifier(AppTextSize())
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

// MARK: - Palette (Sinky: true black, warm ink, copper + teal)

enum P {
    static let bg = Color.black
    static let surface = Color(hex: 0x0E0F10)
    static let surface2 = Color(hex: 0x16181A)
    static let border = Color(hex: 0x24272A)
    static let divider = Color(hex: 0x1A1C1E)
    static let ink = Color(hex: 0xF3F2EE)
    static let textSec = Color(hex: 0xA3A8AB)
    static let textDim = Color(hex: 0x7C8285)
    static let accent = Color(hex: 0xE8875A)      // copper
    static let tan = Color(hex: 0xC9A27A)
    static let teal = Color(hex: 0x4FA3AE)
    /// Kept for existing call sites; Sinky's second colour is teal.
    static let magenta = teal
    static let danger = Color(hex: 0xF07167)
    static let good = Color(hex: 0x6CC9A1)
    /// Copper → tan → teal, the Sinky "rule".
    static var brand: LinearGradient {
        LinearGradient(colors: [accent, tan, teal], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Root

struct RootView: View {
    @State private var armToken = 0
    @ObservedObject private var files = FileIngestModel.shared
    @State private var photoItem: PhotosPickerItem?
    /// QA hook only: SCRIBBLY_FAILED=1 opens the "Didn't work" screen on launch.
    @State private var qaFailed = ProcessInfo.processInfo.environment["SCRIBBLY_FAILED"] == "1"

    var body: some View {
        ZStack {
            P.bg.ignoresSafeArea()
            // Any size: iPhone portrait/landscape, iPad full screen, Split View,
            // Slide Over, Stage Manager windows. Below 900pt the app fills the
            // window; wider than that it stays a comfortable reading column
            // centred on the dark background (nav bars, lists, recorder, tab bar).
            LibraryScreen(initial: .home)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }
        // The Upload picker lives at the root, outside the TabView: presented from
        // inside a tab page it never appeared (Upload "does nothing", build 220).
        .fullScreenCover(isPresented: $qaFailed) {
            NavigationStack { FailedSection().background(SinkyBackdrop()).navigationTitle("Didn't work") }
                .preferredColorScheme(.dark)
        }
        // Videos from the Photos library (they never show up in the Files picker).
        .photosPicker(isPresented: $files.pickingPhotos, selection: $photoItem, matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task { await files.handlePhoto(item) }
        }
        .fileImporter(isPresented: $files.picking,
                      allowedContentTypes: FileIngestModel.contentTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                CrashReporter.shared.add("upload picked \(urls.count)")
                if let url = urls.first { Task { await files.handle(url) } }
            case .failure(let e):
                CrashReporter.shared.add("upload picker failed: \(e.localizedDescription)")
                files.lastError = e.localizedDescription
            }
        }
        .onAppear { WatchBridge.shared.activate(); RecordingLiveActivity.shared.bind()
            // QA hook: SCRIBBLY_UPLOAD=1 opens the Upload picker after launch.
            if ProcessInfo.processInfo.environment["SCRIBBLY_UPLOAD"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { files.picking = true }
            }
        }
        .onOpenURL { url in
            CrashReporter.shared.add("open url \(url.scheme ?? "")://\(url.host ?? "") file=\(url.isFileURL)")
            if url.scheme == "scribbly" && url.host == "record" { arm(); return }
            // Files shared/opened into Scribbly (share sheet, Files app, AirDrop) → ingest.
            if url.isFileURL {
                Task { await FileIngestModel.shared.handle(url) }
            }
        }
    }

    private func arm() {
        BottomChrome.shared.currentTab = .home
        BottomChrome.shared.armToken += 1   // change triggers RecordBar to auto-start
    }
}

// MARK: - Record

/// Screens that own the bottom edge (an entry's Ask box) raise this so the
/// record bar steps aside instead of covering them.
final class BottomChrome: ObservableObject {
    static let shared = BottomChrome()
    @Published var hideRecordBar = false
    @Published var currentTab: LibraryScreen.Section = .home
    /// Which sub-page More is showing (Collections / Query / Activity), if any.
    @Published var moreSub: LibraryScreen.Section? = nil
    /// True while the paste field owns the keyboard — the glass bar steps out of the way.
    @Published var keyboardUp = false
    @Published var armToken = 0
    /// Measured height of each tab's floating bottom chrome (tab bar + recorder /
    /// upload capsule). Scroll pages inset their content by this (ChromeInset).
    @Published var barHeights: [LibraryScreen.Section: CGFloat] = [:]
    /// Bumped when the already-selected tab is tapped again: that tab pops to its
    /// root and scrolls to the top. `reselectTab` says which tab.
    @Published var reselectTick = 0
    private(set) var reselectTab: LibraryScreen.Section = .home

    func reselect(_ tab: LibraryScreen.Section) {
        reselectTab = tab
        reselectTick += 1
    }

    func setBarHeight(_ h: CGFloat, for tab: LibraryScreen.Section) {
        guard h > 0, abs((barHeights[tab] ?? -1) - h) > 0.5 else { return }
        barHeights[tab] = h
    }

    /// The green "saved" confirmation. It shows on Home only, for 10 seconds,
    /// and is cleared the moment you leave Home or open an entry.
    @Published var savedTitle: String? {
        didSet {
            clearTask?.cancel()
            guard savedTitle != nil else { return }
            clearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.savedTitle = nil
            }
        }
    }
    private var clearTask: Task<Void, Never>?
}

struct RecordBar: View {
    var armToken: Int = 0
    /// Which tab this instance lives on — only the visible one reacts to arm().
    var tab: LibraryScreen.Section = .home
    @ObservedObject private var rec = Recorder.shared
    @State private var showPendingSheet = false
    @ObservedObject private var up = Uploader.shared
    @State private var showDiscardConfirm = false
    private var savedTitle: String? {
        get { chrome.savedTitle } nonmutating set { chrome.savedTitle = newValue }
    }

    private var timeString: String {
        let t = Int(rec.elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// Live while recording, uploading, or while the server works on the
    /// recording that was just handed off (its real progress/stage shows here).
    private var isActive: Bool { rec.state != .idle || up.isUploading || up.serverJob != nil }
    /// Errors and "N waiting" must be visible even when nothing is recording or
    /// uploading — that is exactly when a stuck recording needs attention.
    private var hasNotice: Bool { rec.lastError != nil || up.lastError != nil || up.pendingCount > 0 }
    @ObservedObject private var chrome = BottomChrome.shared

    var body: some View {
        // Idle: no capsule — the Record button IS the centre tab in the glass bar.
        // Idle-time elements: the "saved" line on Home, and any error / waiting notice.
        if (isActive || hasNotice) && chrome.currentTab == tab {
            barBody
        } else if !isActive, tab == .home, chrome.currentTab == .home, let t = chrome.savedTitle {
            Label(t, systemImage: "checkmark.circle.fill")
                .font(.geist(size: 12)).foregroundColor(P.good)
                .padding(.horizontal, 20).padding(.bottom, 6).lineLimit(1)
        } else {
            EmptyView()
        }
    }

    private var barBody: some View {
        VStack(spacing: 6) {
            // The "saved" line shows on Home only, and never follows you around.
            if let t = savedTitle, !up.isUploading, chrome.currentTab == .home {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.geist(size: 12)).foregroundColor(P.good)
                    .padding(.horizontal, 20).lineLimit(1)
            }
            if up.pendingCount > 0 {
                Label("\(up.pendingCount) recording\(up.pendingCount == 1 ? "" : "s") waiting — tap to manage",
                      systemImage: "arrow.clockwise.circle")
                    .font(.geist(size: 12)).foregroundColor(.orange)
                    .onTapGesture { showPendingSheet = true }
            }
            if let e = rec.lastError ?? up.lastError {
                VStack(spacing: 4) {
                    Text(e).font(.geist(size: 12)).foregroundColor(P.danger)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                        // Tap to dismiss once read.
                        .onTapGesture { rec.clearError(); up.lastError = nil }
                    if e.localizedCaseInsensitiveContains("Microphone access") {
                        Button("Open Settings") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                        .font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                    }
                }
            }

            // The bar itself: an expanded panel while live. With only a notice
            // to show, no capsule (the glass tab bar already has Record).
            if isActive {
                SwiftUI.Group {
                    if up.isUploading {
                        uploadingPanel
                    } else if rec.state != .idle {
                        activePanel
                    } else if up.serverJob != nil {
                        serverPanel
                    } else {
                        idleBar
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .sinkyGlass(Capsule(), tint: rec.state == .recording ? P.accent.opacity(0.22) : nil)
                .overlay(alignment: .bottom) {
                    if rec.state == .recording { GradientRule().padding(.horizontal, 28).padding(.bottom, 1) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.88), value: isActive)
            }
        }
        .padding(.top, 4)
        .sinkyHaptic(rec.state == .idle)
        .onChange(of: armToken) { _ in
            guard chrome.currentTab == tab else { return }
            if rec.state == .idle && !up.isUploading {
                savedTitle = nil; rec.place = nil
                PlaceTagger.shared.tag { Recorder.shared.place = $0 }
                rec.start()
            }
        }
        .sheet(isPresented: $showPendingSheet) {
            PendingRecoverySheet(uploader: up).presentationDetents([.medium, .large])
        }
        .alert("Discard this recording?", isPresented: $showDiscardConfirm) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard", role: .destructive) { rec.discard() }
        } message: { Text("The audio will be deleted and cannot be recovered.") }
    }

    // Slim idle capsule: tap the mic to start.
    private var idleBar: some View {
        Button {
            savedTitle = nil
            rec.place = nil
            PlaceTagger.shared.tag { Recorder.shared.place = $0 }
            rec.start()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(P.ink).frame(width: 36, height: 36)
                    Circle().fill(P.accent).frame(width: 12, height: 12)
                }
                Text("Record").font(.geist(size: 15, weight: .semibold)).foregroundColor(P.ink)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Expanded live panel: timer, waveform, transport.
    private var activePanel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(timeString)
                    .font(.geist(size: 16, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundColor(P.ink)
                Text(statusText).monoLabel(8.5, color: statusColor)
            }
            .frame(width: 58, alignment: .leading)
            WaveBars(level: rec.level, active: rec.state == .recording).frame(height: 18)
            controls
        }
    }

    // Upload panel: a true byte-percentage bar with the number.
    private var uploadingPanel: some View {
        UploadProgressBar()
    }

    // After hand-off: the server job's own progress (when it reports one), else its stage.
    private var serverPanel: some View {
        let job = up.serverJob
        let pct: Int? = job?.progress.map { Int($0.rounded()) }
        let stage = job?.stage ?? "Processing on the server…"
        return VStack(spacing: 4) {
            if let p = job?.progress {
                GradientProgress(value: p, total: 100, duration: 1.8)
            }
            HStack(spacing: 8) {
                if pct == nil { ProgressView().controlSize(.small).tint(P.accent) }
                Text(stage).font(.geist(size: 12, weight: .medium)).foregroundColor(P.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let pct {
                    Text("\(pct)%").font(.geist(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit().foregroundColor(P.textSec)
                }
            }
        }
        .contentShape(Rectangle())
        // Tap to tuck it away; the job keeps going on the server (see Activity).
        .onTapGesture { up.stopTrackingServerJob() }
    }

    private var statusText: String {
        if rec.interrupted { return "Interrupted — resuming automatically" }
        switch rec.state {
        case .recording: return rec.appendTo == nil ? "Recording" : "Adding to this entry"
        case .paused:    return "Paused"
        case .finishing: return "Finishing…"
        case .idle:      return ""
        }
    }

    private var statusColor: Color {
        if rec.interrupted { return .orange }
        return rec.state == .recording ? P.accent : P.textDim
    }

    @ViewBuilder private var controls: some View {
        switch rec.state {
        case .idle:
            EmptyView()

        case .recording, .paused:
            HStack(spacing: 8) {
                Button { showDiscardConfirm = true } label: {
                    circleButton(icon: "xmark", tint: P.danger, size: 30)
                }
                Button {
                    rec.state == .recording ? rec.pause() : rec.resume()
                } label: {
                    circleButton(icon: rec.state == .recording ? "pause.fill" : "play.fill",
                                 tint: .white, size: 34)
                }
                // Finish — the ONLY thing that ends a recording
                Button {
                    rec.finishAndUpload()
                } label: {
                    circleButton(icon: "checkmark", tint: P.good, size: 30)
                }
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
                .font(.geist(size: size * 0.34, weight: .semibold))
                .foregroundColor(tint)
        }
    }
}

/// Live input meter. Fits whatever width it's given: the bar count is derived
/// from the available space (8pt per bar), so it can never push the recorder
/// wider than the screen. (A fixed 28-bar row was ~220pt and, with the timer
/// and transport, made the whole page wider than the phone — the "zoom".)
struct WaveBars: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(6, min(28, Int(geo.size.width / 8)))
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    let d = abs(Double(i) - Double(count) / 2) / (Double(count) / 2)
                    let jitter = 0.55 + Double((i &* 37) % 100) / 110.0
                    let h = active
                        ? max(4, Double(level) * 58 * (1 - d * 0.65) * jitter)
                        : 4
                    Capsule()
                        .fill(active ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.border))
                        .frame(width: 4, height: h)
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}


/// Determinate upload bar: real bytes on the wire, with the percentage shown.
/// Once the bytes have landed it says so (the server-side progress takes over
/// in the recorder capsule).
struct UploadProgressBar: View {
    @ObservedObject private var up = Uploader.shared
    var body: some View {
        let frac = min(max(up.uploadFraction, 0), 1)
        let pct = Int((frac * 100).rounded())
        let label = up.stage.isEmpty ? (frac < 1 ? "Uploading…" : "Handed off — finishing on server") : up.stage
        return VStack(spacing: 4) {
            GradientProgress(value: frac)
            HStack(spacing: 8) {
                Text(label).font(.geist(size: 12, weight: .medium)).foregroundColor(P.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(pct)%").font(.geist(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit().foregroundColor(P.textSec)
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
                    Text(e).font(.geist(size: 12)).foregroundColor(.orange)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.geist(size: 14, weight: .semibold)).foregroundColor(P.ink)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)) · \(item.createdAt.formatted(.relative(presentation: .named)))"
                             + (item.attempts > 0 ? " · \(item.attempts) attempt\(item.attempts == 1 ? "" : "s")" : ""))
                            .font(.geist(size: 12)).foregroundColor(P.textSec)
                        HStack(spacing: 14) {
                            Button("Retry") {
                                uploader.resumePending(); dismiss()
                            }.font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                            ShareLink(item: item.fileURL) {
                                Text("Export file").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.accent)
                            }
                            Button("Discard", role: .destructive) {
                                uploader.discard(id: item.id)
                                items = uploader.pendingItems()
                                if items.isEmpty { dismiss() }
                            }.font(.geist(size: 13, weight: .semibold))
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
