import Foundation
import UIKit
import BackgroundTasks

/// Live status for the whole app: watches the library, the voice server's jobs
/// and fetch batches; posts the notifications; owns every badge (app icon,
/// Library tab, More tab, Activity row). Every 15 s while Scribbly® is open,
/// instantly when one of your recordings finishes, and on iOS background
/// refresh while it's closed.
final class StatusWatcher: ObservableObject {
    static let shared = StatusWatcher()
    static let refreshTaskID = "com.connor.scribbly.refresh"

    /// New library entries since you last opened Library.
    @Published private(set) var unseenLibrary = 0
    /// Recordings uploading + server jobs running + batches fetching.
    @Published private(set) var activeJobs = 0
    /// Failures in the last day you haven't looked at in Activity.
    @Published private(set) var unseenFailures = 0

    /// Read from any thread when a notification is built.
    private(set) var appBadgeCount = 0

    private let d = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private var running = false
    private var lastBatches: [String: (name: String, total: Int, done: Int)] = [:]

    private var notifiedThrough: String? {
        get { d.string(forKey: "status.notifiedThrough") }
        set { d.set(newValue, forKey: "status.notifiedThrough") }
    }
    private var librarySeen: String? {
        get { d.string(forKey: "status.librarySeen") }
        set { d.set(newValue, forKey: "status.librarySeen") }
    }
    private var activitySeen: Double {
        get { d.double(forKey: "status.activitySeen") }
        set { d.set(newValue, forKey: "status.activitySeen") }
    }
    private var notifiedIDs: [String] {
        get { d.stringArray(forKey: "status.notifiedIDs") ?? [] }
        set { d.set(Array(newValue.suffix(400)), forKey: "status.notifiedIDs") }
    }

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func nowISO() -> String { isoOut.string(from: Date()) }

    // MARK: Lifecycle

    /// Foreground loop. Safe to call more than once.
    func start() {
        DispatchQueue.main.async {
            guard self.loop == nil else { return }
            if self.notifiedThrough == nil { self.notifiedThrough = Self.nowISO() }
            if self.librarySeen == nil { self.librarySeen = Self.nowISO() }
            if self.activitySeen == 0 { self.activitySeen = Date().timeIntervalSince1970 }
            self.loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(reason: "foreground")
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
        }
    }
    func stop() {
        DispatchQueue.main.async { self.loop?.cancel(); self.loop = nil }
    }

    // MARK: Seen markers

    func markLibrarySeen() {
        librarySeen = Self.nowISO()
        DispatchQueue.main.async { self.unseenLibrary = 0; self.updateBadges() }
    }
    func markActivitySeen() {
        activitySeen = Date().timeIntervalSince1970
        DispatchQueue.main.async { self.unseenFailures = 0; self.updateBadges() }
    }

    func updateBadges() {
        let n = NotifySettings.shared.appBadge ? unseenLibrary + unseenFailures : 0
        appBadgeCount = n
        Notifier.shared.setBadge(n)
    }

    // MARK: Events from the app itself (instant, no waiting for the poll)

    /// The voice-server job a recording became just finished.
    func serverJobFinished(id: String, state: String, title: String, error: String? = nil) {
        // A failed transcription goes back in automatically (RetryEngine) —
        // you only hear about it once all 4 tries are used ("no speech" is final).
        if state == "no_speech" || (state == "failed" && RetryEngine.shared.exhausted("job:\(id)")) {
            guard !notifiedIDs.contains("job:\(id)") else { return }
            notifiedIDs = notifiedIDs + ["job:\(id)"]
            DispatchQueue.main.async { self.unseenFailures += 1; self.updateBadges() }
            Notifier.shared.post(.needsAttention,
                                 title: state == "no_speech" ? "No speech found" : "Transcription failed",
                                 body: (title.isEmpty ? "A recording" : "“\(title)”") + (state == "no_speech"
                                       ? " had no words to transcribe. It's kept in Activity — retry or remove it."
                                       : " didn't finish\(error.map { ": \($0)" } ?? ""). Retry it from Activity."),
                                 id: "job-\(id)")
        }
        Task { await refresh(reason: "job_\(state)") }
    }

    func uploadFinished(ok: Bool, title: String?, error: String?, watch: Bool = false) {
        if ok {
            Notifier.shared.post(watch ? .watchMemo : .recordingSaved,
                                 title: watch ? "Watch memo received" : "Recording uploaded",
                                 body: (title.map { "“\($0)” " } ?? "Your recording ")
                                     + "is on the Scribbly® server and transcribing now.")
        }
        // A failed upload isn't a failure yet: the recording stays on this
        // iPhone and the uploader retries it by itself — no alert.
        Task { await refresh(reason: "upload") }
    }

    // MARK: Poll

    /// Runs on the main actor so two refreshes (the 15 s loop, "became active",
    /// a finished job, background refresh) can never touch the same state at
    /// once — concurrent runs raced on lastBatches and could crash the app.
    @MainActor func refresh(reason: String) async {
        let signedIn = await MainActor.run { AuthSession.shared.user != nil }
        guard signedIn else { return }
        guard !running else { return }
        running = true
        defer { running = false }
        await RetryEngine.shared.run(reason: reason)
        let (tab, sub) = await MainActor.run { (BottomChrome.shared.currentTab, BottomChrome.shared.moreSub) }
        if tab == .library { librarySeen = Self.nowISO() }
        if tab == .more && sub == .jobs { activitySeen = Date().timeIntervalSince1970 }
        await checkNewEntries()
        await checkJobs()
        if let seen = librarySeen,
           let n = try? await CorpusAPI.count(table: "scribbly_entries",
                                               filters: [URLQueryItem(name: "created_at", value: "gt.\(seen)")]) {
            await MainActor.run { self.unseenLibrary = n }
        }
        await MainActor.run { self.updateBadges() }
    }

    /// Anything new in the library since the last check → "Transcript Ready".
    @MainActor private func checkNewEntries() async {
        guard let since = notifiedThrough else { return }
        guard let rows = try? await CorpusAPI.recentEntries(limit: 25, filters: [
            URLQueryItem(name: "created_at", value: "gt.\(since)")]) else { return }
        guard !rows.isEmpty else { return }
        let fresh = rows.filter { !notifiedIDs.contains($0.id) }.reversed()
        if let newest = rows.compactMap({ $0.created_at }).max() { notifiedThrough = Self.normalize(newest) }
        notifiedIDs = notifiedIDs + rows.map(\.id)
        guard !fresh.isEmpty else { return }
        if fresh.count > 3 {
            Notifier.shared.post(.transcriptReady, title: "\(fresh.count) new in your library",
                                 body: fresh.prefix(3).map { $0.title }.joined(separator: " · ") + " and more",
                                 id: "entries-\(Self.nowISO())")
        } else {
            for e in fresh {
                let what = [e.kind, e.place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                Notifier.shared.post(.transcriptReady, title: "Transcript ready",
                                     body: e.title + (what.isEmpty ? "" : "\n" + what),
                                     entryID: e.id, id: "entry-\(e.id)")
            }
        }
    }

    /// Server jobs + batches: the More / Activity badges, failures, finished batches.
    @MainActor private func checkJobs() async {
        let jm = await MainActor.run { JobsModel.shared }
        await jm.refresh()
        let (voice, batches) = await MainActor.run { (jm.voiceJobs, jm.batches) }
        let pending = await MainActor.run { Uploader.shared.pendingCount }
        let running = voice.filter { $0.isRunning }.count
        let seen = activitySeen
        var newFailures = 0
        for j in voice where (j.state == "no_speech" || (j.state == "failed" && RetryEngine.shared.exhausted("job:\(j.id)")))
                && j.createdAt / (j.createdAt > 1e11 ? 1000 : 1) > seen {
            newFailures += 1
            if !notifiedIDs.contains("job:\(j.id)") {
                notifiedIDs = notifiedIDs + ["job:\(j.id)"]
                Notifier.shared.post(.needsAttention, title: j.state == "no_speech" ? "No speech found" : "Transcription failed",
                                     body: (j.title ?? "A recording") + (j.error.map { " — \($0)" } ?? ""), id: "job-\(j.id)")
            }
        }
        // A batch that was fetching and now isn't → finished.
        var now: [String: (name: String, total: Int, done: Int)] = [:]
        for b in batches { now[b.id] = (b.name, b.total, b.done) }
        for (id, b) in lastBatches where now[id] == nil {
            // Its failures go straight back in. Stay quiet while any are still
            // being retried — one alert when the batch is truly done.
            let retrying = await RetryEngine.shared.batchFinished(collection: id)
            let waiting = retrying > 0 ? retrying : await RetryEngine.shared.retriesLeft(collection: id)
            guard waiting == 0, !notifiedIDs.contains("batchdone:\(id)") else { continue }
            notifiedIDs = notifiedIDs + ["batchdone:\(id)"]
            let stuck = await RetryEngine.shared.failedCount(collection: id)
            Notifier.shared.post(stuck > 0 ? .needsAttention : .batchFinished,
                                 title: stuck > 0 ? "Batch finished — \(stuck) need you" : "Batch finished",
                                 body: stuck > 0
                                    ? "\(b.name) — \(stuck) couldn't be saved after 4 tries. Tap Retry on Home, or Scribbly® tries again in its daily checkup."
                                    : "\(b.name) — everything is fetched and in your library.",
                                 id: "batch-\(id)")
        }
        lastBatches = now
        let active = pending + running + batches.count
        let failuresNow = newFailures
        await MainActor.run {
            self.activeJobs = active
            self.unseenFailures = max(self.unseenFailures, failuresNow)
        }
    }

    /// Postgres timestamps ("…:33.123456+00:00") → "…:33.123456Z" for a clean `gt.` filter.
    static func normalize(_ s: String) -> String {
        s.hasSuffix("+00:00") ? String(s.dropLast(6)) + "Z" : s
    }

    // MARK: Background refresh (Scribbly® closed)

    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.scheduleBackgroundRefresh()
            let work = Task {
                await self.refresh(reason: "background")
                EventLog.shared.log("status.bg_refresh", ["unseen": self.unseenLibrary])
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
        }
    }

    func scheduleBackgroundRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
