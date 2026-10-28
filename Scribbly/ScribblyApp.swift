import SwiftUI
import UIKit
import PhotosUI

// MARK: - App entry

@main
struct ScribblyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        EventLog.configure(url: "https://lbvaosyfikkpvcwksiph.supabase.co", apiKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4", project: "scribbly", accessToken: { AuthTokens.access })   // append-only event log (public.event_log)
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
            AuthGate { RootView() }
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
    @State private var photoItems: [PhotosPickerItem] = []
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
        // Pick up to 10, tap Add, then they upload one after another.
        .photosPicker(isPresented: $files.pickingPhotos, selection: $photoItems, maxSelectionCount: 10,
                      selectionBehavior: .ordered, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            let batch = items
            photoItems = []
            Task { for item in batch { await files.handlePhoto(item) } }
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

/// The short notices that sit just above the glass bar: the green "saved"
/// line (Home only), "N recordings waiting", and recorder / upload errors.
/// The live recorder itself is the glass tab bar (GlassTabBar) — there is no
/// second bar stacked above it. Also owns the arm() auto-start and the
/// pending-recordings sheet.
struct RecordBar: View {
    var armToken: Int = 0
    /// Which tab this instance lives on — only the visible one reacts to arm().
    var tab: LibraryScreen.Section = .home
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var up = Uploader.shared
    @ObservedObject private var chrome = BottomChrome.shared
    @State private var showPendingSheet = false

    private var here: Bool { chrome.currentTab == tab }
    private var savedLine: String? {
        guard here, tab == .home, rec.state == .idle, !up.isUploading else { return nil }
        return chrome.savedTitle
    }
    private var errorText: String? { here ? (rec.lastError ?? up.lastError) : nil }
    private var pending: Int { here ? up.pendingCount : 0 }
    private var hasNotice: Bool { savedLine != nil || errorText != nil || pending > 0 }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 0)   // keeps onChange alive when there's nothing to show
            if let t = savedLine {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.geist(size: 12)).foregroundColor(P.good)
                    .padding(.horizontal, 20).lineLimit(1)
            }
            if pending > 0 {
                Label("\(pending) recording\(pending == 1 ? "" : "s") waiting — tap to manage",
                      systemImage: "arrow.clockwise.circle")
                    .font(.geist(size: 12)).foregroundColor(.orange)
                    .onTapGesture { showPendingSheet = true }
            }
            if let e = errorText {
                errorNotice(e)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, hasNotice ? 6 : 0)
        .animation(.easeOut(duration: 0.2), value: hasNotice)
        .onChange(of: armToken) { _ in
            guard chrome.currentTab == tab else { return }
            if rec.state == .idle && !up.isUploading {
                chrome.savedTitle = nil
                rec.place = nil
                PlaceTagger.shared.tag { Recorder.shared.place = $0 }
                rec.start()
            }
        }
        .sheet(isPresented: $showPendingSheet) {
            PendingRecoverySheet(uploader: up).presentationDetents([.medium, .large])
        }
    }

    private func errorNotice(_ e: String) -> some View {
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
}

/// Live input meter. Fits whatever width and height it's given: the bar count
/// comes from the width (8pt per bar) and every bar is clamped to the height,
/// so it can never push the recorder wider than the screen or spill out of
/// the glass bar.
struct WaveBars: View {
    let level: Float
    let active: Bool

    var body: some View {
        // While recording, the copper → tan → teal gradient rotates across the bars.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { tl in
        let phase = (tl.date.timeIntervalSinceReferenceDate * 0.35).truncatingRemainder(dividingBy: 1)
        GeometryReader { geo in
            let count = max(6, min(28, Int(geo.size.width / 8)))
            let maxH = max(4, geo.size.height)
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(active ? AnyShapeStyle(WaveBars.rotatingColor(i, of: count, phase: phase)) : AnyShapeStyle(P.border))
                        .frame(width: 4, height: Self.barHeight(i, of: count, level: level, active: active, maxH: maxH))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// Copper → tan → teal looped and shifted by `phase`, so the gradient
    /// travels across the bars while recording.
    static func rotatingColor(_ i: Int, of n: Int, phase: Double) -> Color {
        var t = ((n > 1 ? Double(i) / Double(n) : 0) + phase).truncatingRemainder(dividingBy: 1)
        if t < 0 { t += 1 }
        let u = t < 0.5 ? t * 2 : (1 - t) * 2
        let a: (Double, Double, Double) = (0.910, 0.529, 0.353)
        let b: (Double, Double, Double) = (0.788, 0.635, 0.478)
        let c: (Double, Double, Double) = (0.310, 0.639, 0.682)
        func mix(_ x: (Double, Double, Double), _ y: (Double, Double, Double), _ k: Double) -> Color {
            Color(red: x.0 + (y.0 - x.0) * k, green: x.1 + (y.1 - x.1) * k, blue: x.2 + (y.2 - x.2) * k)
        }
        return u < 0.5 ? mix(a, b, u * 2) : mix(b, c, (u - 0.5) * 2)
    }

    static func barHeight(_ i: Int, of count: Int, level: Float, active: Bool, maxH: CGFloat) -> CGFloat {
        guard active else { return 4 }
        let half = Double(count) / 2
        let d = abs(Double(i) - half) / half
        let jitter = 0.55 + Double((i &* 37) % 100) / 110.0
        let h = Double(level) * Double(maxH) * 1.6 * (1 - d * 0.65) * jitter
        return CGFloat(min(Double(maxH), max(4, h)))
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
