import Foundation
import SwiftUI
import UserNotifications
import AVFoundation
import AudioToolbox

/// Every notification preference, saved on this iPhone.
final class NotifySettings: ObservableObject {
    static let shared = NotifySettings()
    private let d = UserDefaults.standard

    enum Previews: String, CaseIterable, Identifiable { case always = "Always", never = "Never"; var id: String { rawValue } }

    @Published var appBadge: Bool { didSet { save("notify.appBadge", appBadge); StatusWatcher.shared.updateBadges() } }
    @Published var tabBadges: Bool { didSet { save("notify.tabBadges", tabBadges) } }
    @Published var inAppBanners: Bool { didSet { save("notify.inAppBanners", inAppBanners) } }
    @Published var inAppHaptics: Bool { didSet { save("notify.inAppHaptics", inAppHaptics) } }
    @Published var previews: Previews { didSet { save("notify.previews", previews.rawValue) } }
    @Published private var enabledMap: [String: Bool]
    @Published private var toneMap: [String: String]
    @Published private var hapticMap: [String: String]
    /// What iOS says (Allowed / Off / Not asked).
    @Published var status: UNAuthorizationStatus = .notDetermined

    private init() {
        appBadge = d.object(forKey: "notify.appBadge") as? Bool ?? true
        tabBadges = d.object(forKey: "notify.tabBadges") as? Bool ?? true
        inAppBanners = d.object(forKey: "notify.inAppBanners") as? Bool ?? true
        inAppHaptics = d.object(forKey: "notify.inAppHaptics") as? Bool ?? true
        previews = Previews(rawValue: d.string(forKey: "notify.previews") ?? "") ?? .always
        enabledMap = d.dictionary(forKey: "notify.enabled") as? [String: Bool] ?? [:]
        toneMap = d.dictionary(forKey: "notify.tones") as? [String: String] ?? [:]
        hapticMap = d.dictionary(forKey: "notify.haptics") as? [String: String] ?? [:]
    }

    private func save(_ k: String, _ v: Any) {
        d.set(v, forKey: k)
        EventLog.shared.log("notify.setting", ["key": k, "value": "\(v)"])
    }

    func enabled(_ k: NotifyKind) -> Bool { enabledMap[k.rawValue] ?? true }
    func tone(_ k: NotifyKind) -> String { toneMap[k.rawValue] ?? k.defaultTone }
    func haptic(_ k: NotifyKind) -> String { hapticMap[k.rawValue] ?? k.defaultHaptic }

    func setEnabled(_ k: NotifyKind, _ v: Bool) { enabledMap[k.rawValue] = v; save("notify.enabled", enabledMap) }
    func setTone(_ k: NotifyKind, _ id: String) { toneMap[k.rawValue] = id; save("notify.tones", toneMap) }
    func setHaptic(_ k: NotifyKind, _ id: String) { hapticMap[k.rawValue] = id; save("notify.haptics", hapticMap) }
    func binding(_ k: NotifyKind) -> Binding<Bool> {
        Binding(get: { self.enabled(k) }, set: { self.setEnabled(k, $0) })
    }

    var statusText: String {
        switch status {
        case .authorized: return "On"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "On"
        case .denied: return "Off · open iOS Settings"
        default: return "Not asked yet"
        }
    }
    var allowed: Bool { status == .authorized || status == .provisional || status == .ephemeral }
}

/// Posts Scribbly®'s local notifications and decides how they look while the
/// app is open. All alerts come from this iPhone (no push server needed).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private var preview: AVAudioPlayer?

    func configure() {
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let cats = NotifyKind.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "New in Scribbly®", options: [])
        }
        center.setNotificationCategories(Set(cats))
        refreshStatus()
    }

    func refreshStatus() {
        center.getNotificationSettings { s in
            DispatchQueue.main.async { NotifySettings.shared.status = s.authorizationStatus }
        }
    }

    func requestAuthorization(_ done: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings]) { ok, err in
            EventLog.shared.log("notify.permission", ["granted": ok, "error": err?.localizedDescription ?? ""])
            self.refreshStatus()
            DispatchQueue.main.async { done?(ok) }
        }
    }

    /// Posts one alert of `kind` now, honouring its on/off, tone and previews.
    func post(_ kind: NotifyKind, title: String, body: String, entryID: String? = nil, id: String? = nil) {
        let s = NotifySettings.shared
        guard s.enabled(kind) else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = s.previews == .never ? "Open Scribbly® to see it." : body
        c.sound = ToneLibrary.sound(s.tone(kind))
        c.threadIdentifier = kind.threadID
        c.categoryIdentifier = kind.rawValue
        c.interruptionLevel = .active
        c.relevanceScore = kind == .transcriptReady ? 0.9 : 0.5
        var info: [String: Any] = ["kind": kind.rawValue]
        if let entryID { info["entryID"] = entryID }
        c.userInfo = info
        if s.appBadge { c.badge = NSNumber(value: StatusWatcher.shared.appBadgeCount) }
        let req = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: c, trigger: nil)
        center.add(req) { err in
            EventLog.shared.log("notify.posted", ["kind": kind.rawValue, "title": title,
                                                  "error": err?.localizedDescription ?? "",
                                                  "tone": s.tone(kind), "haptic": s.haptic(kind)])
        }
    }

    func setBadge(_ n: Int) {
        if #available(iOS 17.0, *) {
            center.setBadgeCount(n)
        } else {
            DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = n }
        }
    }

    /// Plays a tone in the picker (and its vibration), like tapping a tone in iOS Settings.
    func previewTone(_ id: String, haptic: String?) {
        preview?.stop()
        if let haptic { HapticPlayer.shared.play(haptic: haptic, tone: id) }
        guard id != ToneLibrary.noneID else { return }
        if id == ToneLibrary.systemID { AudioServicesPlaySystemSound(1007); return }
        // Never play a preview into a recording in progress.
        guard let u = ToneLibrary.url(id), Recorder.shared.state == .idle else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        preview = try? AVAudioPlayer(contentsOf: u)
        preview?.play()
    }
    func stopPreview() { preview?.stop(); HapticPlayer.shared.stop() }

    // MARK: UNUserNotificationCenterDelegate

    /// While Scribbly® is open: a real iOS banner + tone (if In-App Banners is
    /// on) and the chosen vibration pattern played on the Taptic Engine.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let s = NotifySettings.shared
        let kind = NotifyKind(rawValue: notification.request.content.userInfo["kind"] as? String ?? "") ?? .transcriptReady
        if s.inAppHaptics, Recorder.shared.state == .idle {
            DispatchQueue.main.async { HapticPlayer.shared.play(haptic: s.haptic(kind), tone: s.tone(kind)) }
        }
        var opts: UNNotificationPresentationOptions = [.list]
        if s.appBadge { opts.insert(.badge) }
        // Never chime over a recording in progress.
        if s.inAppBanners {
            opts.insert(.banner)
            if Recorder.shared.state == .idle { opts.insert(.sound) }
        }
        done(opts)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String ?? ""
        let entry = info["entryID"] as? String
        EventLog.shared.log("notify.opened", ["kind": kind, "entry": entry ?? ""])
        DispatchQueue.main.async {
            let chrome = BottomChrome.shared
            switch NotifyKind(rawValue: kind) {
            case .needsAttention, .recordingSaved, .batchFinished:
                chrome.moreSub = .jobs; chrome.currentTab = .more
            default:
                chrome.currentTab = .library
                if let entry { chrome.openEntryID = entry }
            }
            done()
        }
    }

    /// "Scribbly® Notification Settings" link inside iOS Settings → Notifications → Scribbly®.
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        DispatchQueue.main.async {
            BottomChrome.shared.moreSub = .notifications
            BottomChrome.shared.currentTab = .more
        }
    }
}
