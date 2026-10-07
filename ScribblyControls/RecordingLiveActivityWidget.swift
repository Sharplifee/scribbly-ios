import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Dynamic Island + Lock Screen view for an in-progress Scribbly recording.
@available(iOS 16.2, *)
struct RecordingLiveActivityWidget: Widget {
    private let purple = Color(red: 0.66, green: 0.33, blue: 0.97)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { ctx in
            // Lock Screen / banner
            HStack(spacing: 12) {
                Image(systemName: ctx.state.paused ? "pause.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 30)).foregroundColor(ctx.state.paused ? .orange : purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.appending ? "Adding to this entry" : (ctx.state.paused ? "Paused" : "Recording"))
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text("Scribbly").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                timer(ctx.state).font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundColor(.white)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .widgetURL(URL(string: "scribbly://open"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.state.paused ? "Paused" : (ctx.state.appending ? "Adding" : "Recording"),
                          systemImage: ctx.state.paused ? "pause.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ctx.state.paused ? .orange : purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(ctx.state).font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Scribbly — tap to return").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: ctx.state.paused ? "pause.fill" : "mic.fill")
                    .foregroundColor(ctx.state.paused ? .orange : purple)
            } compactTrailing: {
                timer(ctx.state).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "mic.fill").foregroundColor(purple)
            }
            .widgetURL(URL(string: "scribbly://open"))
        }
    }

    @ViewBuilder private func timer(_ s: RecordingActivityAttributes.ContentState) -> some View {
        if s.paused {
            Text(String(format: "%d:%02d", s.pausedElapsed / 60, s.pausedElapsed % 60))
        } else {
            Text(timerInterval: s.timerStart...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        }
    }
}
