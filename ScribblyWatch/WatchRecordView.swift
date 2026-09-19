import SwiftUI

struct WatchRecordView: View {
    @StateObject private var rec = WatchRecorder()

    private var time: String {
        let t = Int(rec.elapsed); return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            if rec.isRecording {
                Text(time).font(.system(size: 30, weight: .semibold, design: .monospaced))
                Text("Recording").font(.footnote).foregroundColor(.purple)
                HStack(spacing: 14) {
                    Button { rec.discard() } label: { Image(systemName: "trash").font(.title3) }
                        .tint(.red)
                    Button { rec.finish() } label: { Image(systemName: "checkmark").font(.title2) }
                        .tint(.green)
                }
                .buttonStyle(.bordered)
            } else {
                Button { rec.start() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.system(size: 30))
                        Text("Record").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                if rec.pendingTransfers > 0 {
                    Text("\(rec.pendingTransfers) waiting for iPhone").font(.caption2).foregroundColor(.secondary)
                }
            }
            if !rec.status.isEmpty {
                Text(rec.status).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
    }
}
