import SwiftUI
import AVFoundation
import CoreLocation

/// Settings: permissions, recording preferences, storage, server status, about.
struct SettingsSection: View {
    @AppStorage("titleByPlace") private var titleByPlace = true
    @AppStorage("keepRecordingInBackground") private var keepBackground = true
    @AppStorage("autoApproveRecoveries") private var autoApprove = false
    @AppStorage("defaultDestination") private var defaultDestination = "Claude"
    @AppStorage(TextSizeOption.storageKey) private var textSize = TextSizeOption.standard.rawValue
    @ObservedObject private var up = Uploader.shared
    @State private var serverOK: Bool? = nil
    /// Last known library size (shared with Home/Library), refreshed from the server on open.
    @State private var entryCount: Int = UserDefaults.standard.integer(forKey: "libraryCount")
    @State private var countFailed = false

    private var micStatus: String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "Allowed"; case .denied: return "Off · open Settings"; default: return "Not asked yet"
        }
    }
    private var locStatus: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return "While using"
        case .denied, .restricted: return "Off · open Settings"
        default: return "Not asked yet"
        }
    }
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header("TEXT SIZE")
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(TextSizeOption.allCases) { o in
                                let on = textSize == o.rawValue
                                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { textSize = o.rawValue } } label: {
                                    VStack(spacing: 6) {
                                        Text("A").font(.custom("Geist-SemiBold", fixedSize: o.sample))
                                            .foregroundColor(on ? .black : P.ink)
                                            .frame(maxWidth: .infinity).frame(height: 44)
                                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? P.ink : P.surface2))
                                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Color.clear : P.border))
                                        Text(o.rawValue).font(.custom("GeistMono-Regular", fixedSize: 9)).textCase(.uppercase)
                                            .foregroundColor(on ? P.ink : P.textDim).lineLimit(1).minimumScaleFactor(0.7)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Text size \(o.rawValue)")
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        Text("Transcribed, summarized, searchable — this is how text will look.")
                            .font(.geist(size: 14)).foregroundColor(P.textSec)
                        Text("Default follows your iPhone's Text Size setting.")
                            .font(.geist(size: 12)).foregroundColor(P.textDim)
                    }
                    .padding(.vertical, 14)
                }
                header("PERMISSIONS")
                card {
                    linkRow("Microphone", micStatus, good: micStatus == "Allowed")
                    linkRow("Location (for titles)", locStatus, good: locStatus == "While using")
                }
                header("RECORDING")
                card {
                    toggleRow("Title recordings by place", $titleByPlace)
                    toggleRow("Keep recording in background", $keepBackground)
                    toggleRow("Auto-approve crash recoveries", $autoApprove)
                }
                header("SEND TO")
                card {
                    HStack { Text("Default destination").foregroundColor(P.ink)
                        Spacer()
                        Picker("", selection: $defaultDestination) { ForEach(["Claude", "GPT", "Grok"], id: \.self) { Text($0) } }
                            .pickerStyle(.menu).tint(P.textDim)
                    }.padding(.vertical, 6)
                }
                header("STORAGE")
                card {
                    plainRow("Waiting to upload", up.pendingCount == 0 ? "Nothing" : "\(up.pendingCount) item" + (up.pendingCount == 1 ? "" : "s"))
                }
                header("SERVER")
                card {
                    plainRow("Sharp's Cloud Computer", serverOK == nil ? "Checking…" : (serverOK! ? "Online" : "Unreachable"), good: serverOK == true)
                    plainRow("Library", entryCount > 0
                             ? "\(entryCount.formatted()) entries" + (countFailed ? " (last known)" : "")
                             : (countFailed ? "Couldn't count" : "Counting…"))
                }
                header("ABOUT")
                card {
                    plainRow("Version", version)
                    Link(destination: URL(string: "https://getscribbly.vercel.app/privacy")!) { navRow("Privacy policy") }
                    Link(destination: URL(string: "https://getscribbly.vercel.app/support")!) { navRow("Support") }
                }
            }
            .padding(16)
        }
        .task {
            if let u = URL(string: CorpusAPI.voiceIngestURL.replacingOccurrences(of: "/upload", with: "/health")),
               let (d, _) = try? await URLSession.shared.data(from: u) {
                serverOK = String(data: d, encoding: .utf8)?.contains("\"ok\":true") == true
            } else { serverOK = false }
            do {
                let n = try await CorpusAPI.count(table: "scribbly_entries")
                entryCount = n; countFailed = false
                UserDefaults.standard.set(n, forKey: "libraryCount")
            } catch { countFailed = true }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).sectionHead().padding(.top, 6)
    }
    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }
            .padding(.horizontal, 14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
    }
    private func plainRow(_ l: String, _ v: String, good: Bool = false) -> some View {
        HStack { Text(l).foregroundColor(P.ink); Spacer(); Text(v).foregroundColor(good ? P.good : P.textDim).font(.geist(size: 14)) }
            .padding(.vertical, 12).overlay(Rectangle().fill(P.border).frame(height: 1), alignment: .bottom)
    }
    private func linkRow(_ l: String, _ v: String, good: Bool) -> some View {
        Button { if !good, let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
            plainRow(l, v, good: good)
        }.buttonStyle(.plain)
    }
    private func navRow(_ l: String) -> some View {
        HStack { Text(l).foregroundColor(P.ink); Spacer(); Image(systemName: "chevron.right").foregroundColor(P.textDim) }
            .padding(.vertical, 12).overlay(Rectangle().fill(P.border).frame(height: 1), alignment: .bottom)
    }
    private func toggleRow(_ l: String, _ b: Binding<Bool>) -> some View {
        Toggle(l, isOn: b).tint(P.good).foregroundColor(P.ink).padding(.vertical, 10)
            .overlay(Rectangle().fill(P.border).frame(height: 1), alignment: .bottom)
    }
}

/// Apple Watch page from the mockup: status, how it works, recent.
struct WatchInfoSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("HOW IT WORKS").sectionHead()
                Text("Tap Record on the watch; it records on the wrist without the phone. Finish sends the file to this iPhone — queued until it's nearby — and it lands in the library with the same place title as a phone memo.")
                    .font(.geist(size: 14.5)).foregroundColor(P.textSec).lineSpacing(3)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
                Text("INSTALL").sectionHead().padding(.top, 8)
                Text("Open the Watch app on this iPhone → Available Apps → Scribbly → Install.")
                    .font(.geist(size: 14)).foregroundColor(P.textSec)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.edge))
            }
            .padding(16)
        }
    }
}
