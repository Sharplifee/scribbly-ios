import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Settings → Notifications, laid out like iOS Settings → Sounds & Haptics:
/// allow, previews, badges, banners, then one row per alert kind with its own
/// tone and vibration (3 defaults, the full tone list, custom tones and
/// custom vibrations).
struct NotificationsSection: View {
    @ObservedObject private var s = NotifySettings.shared
    @ObservedObject private var watcher = StatusWatcher.shared
    @State private var editing: NotifyKind?
    @State private var vibrationFor: NotifyKind?
    @State private var testSent = false

    var body: some View {
        if let k = vibrationFor {
            VibrationPicker(kind: k, back: { vibrationFor = nil })
        } else if let k = editing {
            TonePicker(kind: k, back: { editing = nil }, vibration: { vibrationFor = k })
        } else {
            main
        }
    }

    private var main: some View {
        ScrollView {
            VStack(spacing: 0) {
            PageHeader(title: "Notifications", subtitle: "Alerts, sounds, vibrations & badges",
                       back: { BottomChrome.shared.moreSub = .settings }, backLabel: "Settings")
            VStack(alignment: .leading, spacing: 8) {
                NFHead("ALLOW NOTIFICATIONS")
                NFCard {
                    Button {
                        if s.status == .notDetermined { Notifier.shared.requestAuthorization() }
                        else if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                    } label: {
                        NFRow(icon: "bell.badge.fill", label: "Notifications", value: s.statusText, good: s.allowed, chevron: true)
                    }.buttonStyle(.plain)
                    if s.status == .notDetermined {
                        Text("Tap to allow — Scribbly® tells you when a transcript is ready, a batch finishes, or something needs you.")
                            .font(.geist(size: 13)).foregroundColor(P.textSec).padding(.vertical, 10)
                    }
                }
                NFFoot("Lock Screen, Notification Center, banner style and Scheduled Summary are set by iOS — tap Notifications to open them.")

                NFHead("ALERTS")
                NFCard {
                    HStack {
                        Text("Show Previews").foregroundColor(P.ink)
                        Spacer()
                        Picker("", selection: $s.previews) { ForEach(NotifySettings.Previews.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.menu).tint(P.textDim)
                    }.padding(.vertical, 6).overlay(NFDivider(), alignment: .bottom)
                    NFToggle(icon: "rectangle.topthird.inset.filled", label: "Banners While Using Scribbly®", isOn: $s.inAppBanners)
                    NFToggle(icon: "iphone.radiowaves.left.and.right", label: "Vibrate While Using Scribbly®", isOn: $s.inAppHaptics)
                }

                NFHead("BADGES")
                NFCard {
                    NFToggle(icon: "app.badge.fill", label: "App Icon Badge", isOn: $s.appBadge)
                    NFToggle(icon: "circle.badge.fill", label: "Tab Bar Badges", isOn: $s.tabBadges)
                }
                NFFoot("App icon: new library entries + anything that didn't work (now \(watcher.unseenLibrary + watcher.unseenFailures)). Tabs: Library shows what's new, More shows what's processing (\(watcher.activeJobs) now).")

                NFHead("SOUNDS & HAPTICS")
                NFCard {
                    ForEach(NotifyKind.allCases) { k in
                        Button { editing = k } label: {
                            HStack(spacing: 12) {
                                NFIcon(k.icon, tint: k == .needsAttention ? P.danger : P.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(k.title).foregroundColor(s.enabled(k) ? P.ink : P.textDim)
                                    Text(s.enabled(k) ? "\(ToneLibrary.name(s.tone(k))) · \(HapticLibrary.name(s.haptic(k)))" : "Off")
                                        .font(.geist(size: 12.5)).foregroundColor(P.textDim)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(P.textDim)
                            }
                            .padding(.vertical, 10).contentShape(Rectangle())
                            .overlay(NFDivider(), alignment: .bottom)
                        }.buttonStyle(.plain)
                    }
                }

                NFHead("TEST")
                NFCard {
                    Button {
                        if s.status == .notDetermined { Notifier.shared.requestAuthorization { _ in sendTest() } } else { sendTest() }
                    } label: {
                        NFRow(icon: "paperplane.fill", label: testSent ? "Sent — check the banner" : "Send a Test Notification", value: "", chevron: false)
                    }.buttonStyle(.plain)
                }
                NFFoot("Alerts come from this iPhone: they fire while Scribbly® is open, the moment your recording finishes, and on iOS background refresh while it's closed.")
            }
            .padding(16)
            }
        }
        .onAppear { Notifier.shared.refreshStatus() }
    }

    private func sendTest() {
        testSent = true
        Notifier.shared.post(.transcriptReady, title: "Transcript ready",
                             body: "This is how a finished recording will look and sound.", id: "test-\(UUID().uuidString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { testSent = false }
    }
}

// MARK: - Tone picker (per alert kind)

struct TonePicker: View {
    let kind: NotifyKind
    let back: () -> Void
    let vibration: () -> Void
    @ObservedObject private var s = NotifySettings.shared
    @State private var customs = ToneLibrary.customs
    @State private var importing = false
    @State private var importError: String?
    @State private var pendingURL: URL?
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            PageHeader(title: kind.title, subtitle: kind.detail, back: { Notifier.shared.stopPreview(); back() }, backLabel: "Notifications")
            VStack(alignment: .leading, spacing: 8) {
                NFCard {
                    NFToggle(icon: kind.icon, label: "Allow \(kind.title) Alerts", isOn: s.binding(kind))
                }
                NFCard {
                    Button(action: vibration) {
                        NFRow(icon: "iphone.radiowaves.left.and.right", label: "Vibration", value: HapticLibrary.name(s.haptic(kind)), chevron: true)
                    }.buttonStyle(.plain)
                }
                .padding(.top, 8)

                NFHead("SCRIBBLY® DEFAULTS")
                NFCard { ForEach(ToneLibrary.defaults) { t in toneRow(t.id, t.name) } }

                NFHead("ALERT TONES")
                NFCard { ForEach(ToneLibrary.alerts) { t in toneRow(t.id, t.name) } }

                NFHead("CUSTOM")
                NFCard {
                    ForEach(customs) { c in
                        toneRow(c.id, c.name)
                            .contextMenu {
                                Button(role: .destructive) {
                                    ToneLibrary.deleteCustom(c.id)
                                    if s.tone(kind) == c.id { s.setTone(kind, kind.defaultTone) }
                                    customs = ToneLibrary.customs
                                } label: { Label("Delete Tone", systemImage: "trash") }
                            }
                    }
                    Button { importing = true } label: {
                        NFRow(icon: "plus.circle.fill", label: "Add Custom Tone…", value: "From Files", chevron: true)
                    }.buttonStyle(.plain)
                }
                NFFoot("Pick any song, voice memo or sound in Files — the first 29 seconds become the tone (iOS's limit). Press and hold a custom tone to delete it.")
                if let e = importError { Text(e).font(.geist(size: 13)).foregroundColor(P.danger) }

                NFHead("OTHER")
                NFCard {
                    toneRow(ToneLibrary.systemID, "iOS Default")
                    toneRow(ToneLibrary.noneID, "None")
                }
            }
            .padding(16)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff]) { r in
            if case .success(let u) = r {
                pendingURL = u
                newName = u.deletingPathExtension().lastPathComponent
                naming = true
            }
        }
        .alert("Name this tone", isPresented: $naming) {
            TextField("Tone name", text: $newName)
            Button("Save") { importTone() }
            Button("Cancel", role: .cancel) { pendingURL = nil }
        }
        .onDisappear { Notifier.shared.stopPreview() }
    }

    private func importTone() {
        guard let u = pendingURL else { return }
        do {
            let t = try ToneLibrary.importTone(from: u, name: newName)
            customs = ToneLibrary.customs
            s.setTone(kind, t.id)
            importError = nil
            EventLog.shared.log("notify.custom_tone", ["name": t.name])
            Notifier.shared.previewTone(t.id, haptic: s.haptic(kind))
        } catch {
            importError = "Couldn't use that file: \(error.localizedDescription)"
        }
        pendingURL = nil
    }

    private func toneRow(_ id: String, _ name: String) -> some View {
        let on = s.tone(kind) == id
        return Button {
            s.setTone(kind, id)
            Notifier.shared.previewTone(id, haptic: s.haptic(kind))
        } label: {
            HStack {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                    .foregroundColor(P.accent).opacity(on ? 1 : 0).frame(width: 22)
                Text(name).foregroundColor(P.ink)
                Spacer()
                if id == kind.defaultTone { Text("DEFAULT").monoLabel(9.5, color: P.textDim) }
            }
            .padding(.vertical, 11).contentShape(Rectangle())
            .overlay(NFDivider(), alignment: .bottom)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Vibration picker

struct VibrationPicker: View {
    let kind: NotifyKind
    let back: () -> Void
    @ObservedObject private var s = NotifySettings.shared
    @State private var customs = HapticLibrary.customs
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            PageHeader(title: "Vibration", subtitle: kind.title, back: { HapticPlayer.shared.stop(); back() }, backLabel: kind.title)
            VStack(alignment: .leading, spacing: 8) {
                NFHead("SCRIBBLY® DEFAULTS")
                NFCard { ForEach(HapticLibrary.defaults) { p in row(p.id, p.name) } }
                NFFoot("Synchronized taps along with the tone you picked (\(ToneLibrary.name(s.tone(kind)))).")
                NFHead("STANDARD")
                NFCard { ForEach(HapticLibrary.standard) { p in row(p.id, p.name) } }
                NFHead("CUSTOM")
                NFCard {
                    ForEach(customs) { p in
                        row(p.id, p.name).contextMenu {
                            Button(role: .destructive) {
                                HapticLibrary.customs = HapticLibrary.customs.filter { $0.id != p.id }
                                if s.haptic(kind) == p.id { s.setHaptic(kind, kind.defaultHaptic) }
                                customs = HapticLibrary.customs
                            } label: { Label("Delete Vibration", systemImage: "trash") }
                        }
                    }
                    Button { creating = true } label: {
                        NFRow(icon: "plus.circle.fill", label: "Create New Vibration", value: "", chevron: true)
                    }.buttonStyle(.plain)
                }
                NFCard { row(HapticLibrary.noneID, "None") }.padding(.top, 8)
                NFFoot("iOS plays its own vibration for alerts on the Lock Screen; your pattern plays whenever Scribbly® is open and an alert lands.")
            }
            .padding(16)
            }
        }
        .sheet(isPresented: $creating) {
            VibrationRecorder { p in
                HapticLibrary.customs = HapticLibrary.customs + [p]
                customs = HapticLibrary.customs
                s.setHaptic(kind, p.id)
                EventLog.shared.log("notify.custom_vibration", ["name": p.name, "events": p.events.count])
            }
        }
    }

    private func row(_ id: String, _ name: String) -> some View {
        let on = s.haptic(kind) == id
        return Button {
            s.setHaptic(kind, id)
            HapticPlayer.shared.play(haptic: id, tone: s.tone(kind))
        } label: {
            HStack {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                    .foregroundColor(P.accent).opacity(on ? 1 : 0).frame(width: 22)
                Text(name).foregroundColor(P.ink)
                Spacer()
                if id == kind.defaultHaptic { Text("DEFAULT").monoLabel(9.5, color: P.textDim) }
            }
            .padding(.vertical, 11).contentShape(Rectangle())
            .overlay(NFDivider(), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }
}

/// "Create New Vibration": tap for a tap, hold for a long buzz, up to 8 s —
/// then Play, Record again, or Save with a name. Same flow as iOS.
struct VibrationRecorder: View {
    let onSave: (VibrationPattern) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var events: [HapticEvent] = []
    @State private var start: Date?
    @State private var downAt: Date?
    @State private var recording = false
    @State private var naming = false
    @State private var name = ""
    @State private var elapsed: Double = 0
    private let limit = 8.0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("Cancel") { HapticPlayer.shared.stop(); dismiss() }.foregroundColor(P.accent)
                Spacer()
                Text("New Vibration").font(.geist(size: 17, weight: .semibold)).foregroundColor(P.ink)
                Spacer()
                Button("Save") { naming = true }.foregroundColor(events.isEmpty || recording ? P.textDim : P.accent)
                    .disabled(events.isEmpty || recording)
            }
            .padding(.horizontal, 18).padding(.top, 18)

            Text(recording ? "Tap to create a pattern — hold for a long vibration" : (events.isEmpty ? "Tap below to begin" : "Play it back, or record again"))
                .font(.geist(size: 14)).foregroundColor(P.textSec)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(P.surface)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(P.edge))
                Image(systemName: downAt != nil ? "hand.tap.fill" : "hand.tap")
                    .font(.system(size: 44)).foregroundColor(downAt != nil ? P.accent : P.textDim)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 18)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in touchDown() }
                .onEnded { _ in touchUp() })

            // The pattern as dots (taps) and bars (holds), like iOS.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(P.surface2).frame(height: 6)
                    Capsule().fill(P.accent.opacity(0.35)).frame(width: g.size.width * min(1, elapsed / limit), height: 6)
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        Capsule().fill(P.ink)
                            .frame(width: max(6, g.size.width * e.d / limit), height: 12)
                            .offset(x: g.size.width * e.t / limit)
                    }
                }
            }
            .frame(height: 14).padding(.horizontal, 22)

            HStack(spacing: 14) {
                Button { play() } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 48)
                        .background(Capsule().fill(P.surface2)).foregroundColor(events.isEmpty ? P.textDim : P.ink)
                }.disabled(events.isEmpty || recording)
                Button { if recording { finish() } else { reset() } } label: {
                    Label(recording ? "Stop" : "Record", systemImage: recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Capsule().fill(recording ? P.danger.opacity(0.25) : P.surface2)).foregroundColor(P.ink)
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 18).padding(.bottom, 24)
        }
        .background(P.bg.ignoresSafeArea())
        .onReceive(timer) { _ in
            guard recording, let s0 = start else { return }
            elapsed = Date().timeIntervalSince(s0)
            if elapsed >= limit { finish() }
        }
        .alert("Name this vibration", isPresented: $naming) {
            TextField("Vibration name", text: $name)
            Button("Save") {
                onSave(VibrationPattern(id: "custom:\(UUID().uuidString)", name: name.isEmpty ? "Custom Vibration" : name, events: events))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .preferredColorScheme(.dark)
    }

    private func reset() { events = []; start = nil; elapsed = 0; recording = true }

    private func touchDown() {
        guard downAt == nil else { return }
        if !recording && events.isEmpty { recording = true }
        guard recording else { return }
        let now = Date()
        if start == nil { start = now }
        downAt = now
        HapticPlayer.shared.beginHold()
    }
    private func touchUp() {
        HapticPlayer.shared.endHold()
        guard let dn = downAt, let s0 = start else { downAt = nil; return }
        downAt = nil
        let held = Date().timeIntervalSince(dn)
        events.append(HapticEvent(t: dn.timeIntervalSince(s0), d: held < 0.18 ? 0 : held, i: 1, s: 0.5))
    }
    private func finish() {
        if downAt != nil { touchUp() }
        recording = false
    }
    private func play() { HapticPlayer.shared.play(events) }
}

// MARK: - Building blocks (match Settings)

struct NFHead: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).sectionHead().padding(.top, 10) }
}
struct NFFoot: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View {
        Text(t).font(.geist(size: 12.5)).foregroundColor(P.textDim).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
}
struct NFCard<C: View>: View {
    @ViewBuilder let c: () -> C
    var body: some View {
        VStack(spacing: 0) { c() }
            .padding(.horizontal, 14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
    }
}
struct NFDivider: View {
    var body: some View { Rectangle().fill(P.border).frame(height: 1) }
}
struct NFIcon: View {
    let name: String; let tint: Color
    init(_ name: String, tint: Color = P.accent) { self.name = name; self.tint = tint }
    var body: some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundColor(.black)
            .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
    }
}
struct NFRow: View {
    var icon: String? = nil
    let label: String
    var value: String = ""
    var good = false
    var chevron = false
    var body: some View {
        HStack(spacing: 12) {
            if let icon { NFIcon(icon) }
            Text(label).foregroundColor(P.ink)
            Spacer()
            if !value.isEmpty { Text(value).font(.geist(size: 14)).foregroundColor(good ? P.good : P.textDim) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(P.textDim) }
        }
        .padding(.vertical, 10).contentShape(Rectangle())
        .overlay(NFDivider(), alignment: .bottom)
    }
}
struct NFToggle: View {
    let icon: String; let label: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            NFIcon(icon)
            Toggle(label, isOn: $isOn).tint(P.good).foregroundColor(P.ink)
        }
        .padding(.vertical, 8)
        .overlay(NFDivider(), alignment: .bottom)
    }
}
