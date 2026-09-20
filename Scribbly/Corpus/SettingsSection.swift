import SwiftUI
import AVFoundation
import CoreLocation

/// Settings: permissions, recording preferences, storage, server status, about.
struct SettingsSection: View {
    @AppStorage("titleByPlace") private var titleByPlace = true
    @AppStorage("keepRecordingInBackground") private var keepBackground = true
    @AppStorage("autoApproveRecoveries") private var autoApprove = false
    @AppStorage("defaultDestination") private var defaultDestination = "Claude"
    @ObservedObject private var up = Uploader.shared
    @State private var serverOK: Bool? = nil
    @State private var entryCount: Int = 0

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
                    HStack { Text("Default destination").foregroundColor(.white)
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
                    plainRow("Library", entryCount > 0 ? "\(entryCount.formatted()) entries" : "—")
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
            entryCount = (try? await CorpusAPI.count(table: "scribbly_entries")) ?? 0
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim).tracking(0.8).padding(.top, 6)
    }
    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }
            .padding(.horizontal, 14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
    }
    private func plainRow(_ l: String, _ v: String, good: Bool = false) -> some View {
        HStack { Text(l).foregroundColor(.white); Spacer(); Text(v).foregroundColor(good ? P.good : P.textDim).font(.system(size: 14)) }
            .padding(.vertical, 12).overlay(Divider().overlay(P.border), alignment: .bottom)
    }
    private func linkRow(_ l: String, _ v: String, good: Bool) -> some View {
        Button { if !good, let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
            plainRow(l, v, good: good)
        }.buttonStyle(.plain)
    }
    private func navRow(_ l: String) -> some View {
        HStack { Text(l).foregroundColor(.white); Spacer(); Image(systemName: "chevron.right").foregroundColor(P.textDim) }
            .padding(.vertical, 12).overlay(Divider().overlay(P.border), alignment: .bottom)
    }
    private func toggleRow(_ l: String, _ b: Binding<Bool>) -> some View {
        Toggle(l, isOn: b).tint(P.good).foregroundColor(.white).padding(.vertical, 10)
            .overlay(Divider().overlay(P.border), alignment: .bottom)
    }
}

/// Apple Watch page from the mockup: status, how it works, recent.
struct WatchInfoSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("HOW IT WORKS").font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim).tracking(0.8)
                Text("Tap Record on the watch; it records on the wrist without the phone. Finish sends the file to this iPhone — queued until it's nearby — and it lands in the library with the same place title as a phone memo.")
                    .font(.system(size: 14.5)).foregroundColor(P.textSec).lineSpacing(3)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
                Text("INSTALL").font(.system(size: 11, weight: .semibold)).foregroundColor(P.textDim).tracking(0.8).padding(.top, 8)
                Text("Open the Watch app on this iPhone → Available Apps → Scribbly → Install.")
                    .font(.system(size: 14)).foregroundColor(P.textSec)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(P.border))
            }
            .padding(16)
        }
    }
}
