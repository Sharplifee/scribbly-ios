import SwiftUI
import WidgetKit
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Dynamic Island + Lock Screen (+ CarPlay, which mirrors it) for a Scribbly
/// recording. Layout per Connor: elapsed time on the LEFT, live sound wave,
/// and Pause/Resume + Done on the RIGHT. No mic icon — the wave says it.
@available(iOS 16.2, *)
struct RecordingLiveActivityWidget: Widget {
    static let purple = Color(red: 0.66, green: 0.33, blue: 0.97)
    static let magenta = Color(red: 0.75, green: 0.15, blue: 0.83)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { ctx in
            // Lock Screen / banner / CarPlay
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Self.timer(ctx.state).font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                    Text(ctx.state.paused ? "Paused" : (ctx.state.appending ? "Adding to entry" : "Recording"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ctx.state.paused ? .orange : Self.purple)
                }
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 16, height: 30)
                    .frame(maxWidth: .infinity)
                Self.controls(ctx.state, size: 36)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .widgetURL(URL(string: "scribbly://open"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Self.timer(ctx.state).font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundColor(ctx.state.paused ? .orange : .white)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Self.controls(ctx.state, size: 34).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 24, height: 26)
                        .padding(.horizontal, 8)
                }
            } compactLeading: {
                Self.timer(ctx.state).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(ctx.state.paused ? .orange : .white)
                    .frame(maxWidth: 52, alignment: .leading)
            } compactTrailing: {
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 5, height: 14)
                    .frame(width: 26)
            } minimal: {
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 3, height: 12)
                    .frame(width: 14)
            }
            .widgetURL(URL(string: "scribbly://open"))
        }
    }

    @ViewBuilder static func timer(_ s: RecordingActivityAttributes.ContentState) -> some View {
        if s.paused {
            Text(String(format: "%d:%02d", s.pausedElapsed / 60, s.pausedElapsed % 60))
        } else {
            Text(timerInterval: s.timerStart...Date.distantFuture, countsDown: false).monospacedDigit()
        }
    }

    /// Pause/Resume + Done. Buttons run in the app (LiveActivityIntent).
    @ViewBuilder static func controls(_ s: RecordingActivityAttributes.ContentState, size: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 8) {
                Button(intent: RecordingPauseIntent()) {
                    Image(systemName: s.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: size * 0.4, weight: .bold)).foregroundColor(.white)
                        .frame(width: size, height: size).background(Circle().fill(Color.white.opacity(0.18)))
                }.buttonStyle(.plain)
                Button(intent: RecordingFinishIntent()) {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white)
                        .frame(width: size, height: size).background(Circle().fill(Color.green.opacity(0.85)))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Sound-wave bars drawn from the recent input levels (newest on the right).
@available(iOS 16.2, *)
private struct Wave: View {
    let levels: [Double]
    let paused: Bool
    let bars: Int
    let height: CGFloat

    var body: some View {
        let src = levels.isEmpty ? Array(repeating: 0.08, count: bars) : levels
        let samples: [Double] = (0..<bars).map { i in
            let idx = Int(Double(i) / Double(max(bars - 1, 1)) * Double(src.count - 1))
            return src[max(0, min(src.count - 1, idx))]
        }
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(paused ? AnyShapeStyle(Color.white.opacity(0.3))
                                 : AnyShapeStyle(LinearGradient(colors: [RecordingLiveActivityWidget.purple, RecordingLiveActivityWidget.magenta],
                                                                startPoint: .top, endPoint: .bottom)))
                    .frame(width: 3, height: max(3, height * CGFloat(paused ? 0.12 : samples[i])))
            }
        }
        .frame(height: height)
    }
}
