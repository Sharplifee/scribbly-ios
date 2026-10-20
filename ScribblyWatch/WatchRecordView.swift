import SwiftUI

/// Watch recorder in the Sinky look: black, the app's ink-disc + copper-dot
/// record button, Geist Mono timer, copper status, gradient rule.
struct WatchRecordView: View {
    @ObservedObject private var rec = WatchRecorder.shared

    private var time: String {
        let t = Int(rec.elapsed); return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 8) {
            if rec.isRecording {
                Text("RECORDING").font(Sinky.font(10, .medium, mono: true)).tracking(0.8).foregroundColor(Sinky.copper)
                Text(time).font(Sinky.font(34, .medium, mono: true)).monospacedDigit().foregroundColor(Sinky.ink)
                Capsule().fill(Sinky.rule).frame(width: 70, height: 1.5)
                HStack(spacing: 14) {
                    Button { rec.discard() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundColor(Sinky.ink)
                            .frame(width: 50, height: 50).background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Discard")
                    Button { rec.finish() } label: {
                        Image(systemName: "checkmark").font(.system(size: 19, weight: .heavy)).foregroundColor(.black)
                            .frame(width: 58, height: 58).background(Circle().fill(Sinky.ink))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Finish and send")
                }
                .padding(.top, 4)
            } else {
                Button { rec.start() } label: {
                    VStack(spacing: 10) {
                        SinkyRecordMark(size: 74)
                        Text("Record").font(Sinky.font(17, .semibold)).foregroundColor(Sinky.ink)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record")
                if rec.pendingTransfers > 0 {
                    Text("\(rec.pendingTransfers) WAITING FOR IPHONE").font(Sinky.font(9, .medium, mono: true))
                        .tracking(0.6).foregroundColor(Sinky.tan)
                }
            }
            if !rec.status.isEmpty {
                Text(rec.status).font(Sinky.font(11)).foregroundColor(Sinky.dim).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
