import SwiftUI
import WidgetKit
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Dynamic Island + Lock Screen (+ CarPlay, which mirrors it) for a Scribbly
/// recording, in the Sinky look: true black, Geist Mono timer, copper status,
/// a copper → tan → teal sound wave, ink controls and a gradient rule.
/// Layout per Connor: elapsed time on the LEFT, live wave, Pause/Resume + Done on the RIGHT.
@available(iOS 16.2, *)
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { ctx in
            // Lock Screen / banner / CarPlay
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Self.timer(ctx.state).font(Sinky.font(26, .medium, mono: true)).foregroundColor(Sinky.ink)
                        Self.status(ctx.state).font(Sinky.font(10, .medium, mono: true)).tracking(0.8)
                    }
                    Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 18, height: 30)
                        .frame(maxWidth: .infinity)
                    Self.controls(ctx.state, size: 38)
                }
                Capsule().fill(Sinky.rule).frame(height: 1.5).opacity(ctx.state.paused ? 0.35 : 1)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .activityBackgroundTint(Color.black.opacity(0.92))
            .activitySystemActionForegroundColor(Sinky.ink)
            .widgetURL(URL(string: "scribbly://open"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Self.timer(ctx.state).font(Sinky.font(22, .medium, mono: true)).foregroundColor(Sinky.ink)
                        Self.status(ctx.state).font(Sinky.font(9, .medium, mono: true)).tracking(0.8)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Self.controls(ctx.state, size: 34).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 26, height: 26)
                        .padding(.horizontal, 8)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Circle().fill(ctx.state.paused ? Sinky.tan : Sinky.copper).frame(width: 7, height: 7)
                    Self.timer(ctx.state).font(Sinky.font(13, .medium, mono: true)).foregroundColor(Sinky.ink)
                }
                .frame(maxWidth: 62, alignment: .leading)
            } compactTrailing: {
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 5, height: 14)
                    .frame(width: 26)
            } minimal: {
                Circle().fill(ctx.state.paused ? Sinky.tan : Sinky.copper).frame(width: 10, height: 10)
            }
            .keylineTint(Sinky.copper)
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

    static func status(_ s: RecordingActivityAttributes.ContentState) -> some View {
        Text(s.paused ? "PAUSED" : (s.appending ? "ADDING TO ENTRY" : "RECORDING"))
            .foregroundColor(s.paused ? Sinky.tan : Sinky.copper)
    }

    /// Pause/Resume (glass) + Done (ink, like the app's primary button).
    @ViewBuilder static func controls(_ s: RecordingActivityAttributes.ContentState, size: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 8) {
                Button(intent: RecordingPauseIntent()) {
                    Image(systemName: s.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: size * 0.38, weight: .bold)).foregroundColor(Sinky.ink)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                        .overlay(Circle().stroke(Color.white.opacity(0.12)))
                }.buttonStyle(.plain)
                Button(intent: RecordingFinishIntent()) {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.4, weight: .heavy)).foregroundColor(.black)
                        .frame(width: size, height: size).background(Circle().fill(Sinky.ink))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Sound-wave bars drawn from the recent input levels (newest on the right),
/// coloured copper → tan → teal across the width like the app's gradient rule.
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
                    .fill(paused ? Color.white.opacity(0.25) : Sinky.rampColor(i, of: bars))
                    .frame(width: 3, height: max(3, height * CGFloat(paused ? 0.12 : samples[i])))
            }
        }
        .frame(height: height)
    }
}
