import SwiftUI
import WidgetKit
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Dynamic Island + Lock Screen (+ CarPlay, which mirrors it) for a Scribbly
/// recording, in the Sinky look: true black, Geist Mono timer, a live
/// copper → tan → teal sound wave driven by the real input level, ink
/// controls, and a white keyline / border.
///
/// No recording dot anywhere — the moving wave is the "recording" signal.
///   • Compact: elapsed time leading, live wave trailing (taps open the app).
///   • Expanded: time top-left, Pause/Resume + ✓ Finish top-right, wave below.
///   • Minimal: a three-bar wave.
///   • Lock Screen: time, wave, Pause/Resume + ✓, gradient rule, copper border.
/// The timer is Text(timerInterval:), so it ticks without any app updates; the
/// app only pushes the waveform (≤ 1 update a second).
@available(iOS 16.2, *)
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { ctx in
            LockScreenRecording(state: ctx.state)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(Sinky.ink)
                .widgetURL(URL(string: "scribbly://open"))
        } dynamicIsland: { ctx in
            // Collapsed (compact): elapsed time far left, live wave right.
            // iOS opens the app on any tap in the collapsed island — buttons
            // there can't be pressed — so the working Pause/✓ live in the
            // expanded island (touch and hold) and on the Lock Screen.
            // Expanded: time top-left, Pause + ✓ top-right, wave across the middle.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Self.timer(ctx.state)
                            .font(Sinky.font(24, .medium, mono: true)).foregroundColor(Sinky.ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .multilineTextAlignment(.leading)
                            .frame(width: 104, alignment: .leading)
                        Self.status(ctx.state).font(Sinky.font(9, .medium, mono: true)).tracking(0.8)
                    }
                    .padding(.leading, 8).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Self.controls(ctx.state, size: 40)
                        .padding(.trailing, 8).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 28, height: 26)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10).padding(.top, 6)
                }
            } compactLeading: {
                Self.timer(ctx.state)
                    .font(Sinky.font(13, .medium, mono: true)).foregroundColor(Sinky.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                    .frame(width: 46, alignment: .leading)
                    .padding(.leading, 2)
            } compactTrailing: {
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 7, height: 14)
                    .frame(width: 34)
            } minimal: {
                Wave(levels: ctx.state.levels, paused: ctx.state.paused, bars: 3, height: 12)
                    .frame(width: 14)
            }
            .keylineTint(Color.white.opacity(0.45))   // clearly there, not glowing
            .widgetURL(URL(string: "scribbly://open"))
        }
    }

    /// Ticks by itself while recording; frozen at the paused moment.
    @ViewBuilder static func timer(_ s: RecordingActivityAttributes.ContentState) -> some View {
        if s.paused {
            Text(clock(s.pausedElapsed))
        } else {
            Text(timerInterval: s.timerStart...Date.distantFuture, countsDown: false).monospacedDigit()
        }
    }

    /// "4:07" / "1:02:09" — the same shape as the running timer.
    static func clock(_ seconds: Int) -> String {
        let t = max(0, seconds)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func status(_ s: RecordingActivityAttributes.ContentState) -> some View {
        Text(s.paused ? "PAUSED" : "RECORDING")
            .foregroundColor(s.paused ? Sinky.tan : Sinky.copperBright)
            .lineLimit(1)
    }

    /// Pause/Resume (glass) + ✓ Finish (ink, like the app's primary button).
    /// Interactive Live Activity buttons need iOS 17; on 16.x a tap opens the app.
    @ViewBuilder static func controls(_ s: RecordingActivityAttributes.ContentState, size: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 8) {
                Button(intent: RecordingPauseIntent()) {
                    Image(systemName: s.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: size * 0.38, weight: .bold)).foregroundColor(Sinky.ink)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                        .overlay(Circle().stroke(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.paused ? "Resume recording" : "Pause recording")
                Button(intent: RecordingFinishIntent()) {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.4, weight: .heavy)).foregroundColor(.black)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Sinky.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish and save recording")
            }
        }
    }
}

/// Lock Screen / banner / CarPlay: elapsed time, live wave, controls, the
/// gradient rule, inside a bright copper border.
@available(iOS 16.2, *)
private struct LockScreenRecording: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    RecordingLiveActivityWidget.timer(state)
                        .font(Sinky.font(26, .medium, mono: true)).foregroundColor(Sinky.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .multilineTextAlignment(.leading)
                        .frame(width: 104, alignment: .leading)
                    RecordingLiveActivityWidget.status(state)
                        .font(Sinky.font(10, .medium, mono: true)).tracking(0.8)
                }
                Wave(levels: state.levels, paused: state.paused, bars: 20, height: 32)
                    .frame(maxWidth: .infinity)
                RecordingLiveActivityWidget.controls(state, size: 40)
            }
            Capsule().fill(Sinky.rule).frame(height: 1.5).opacity(state.paused ? 0.35 : 1)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .overlay {
            ContainerRelativeShape()
                .strokeBorder(Color.white.opacity(state.paused ? 0.25 : 0.4), lineWidth: 1.5)
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

    /// `bars` samples taken evenly from the newest end of `levels`.
    private var samples: [Double] {
        let src = levels.isEmpty ? Array(repeating: 0.08, count: bars) : levels
        let n = max(bars, 1)
        return (0..<n).map { i in
            let pos = n > 1 ? Double(i) / Double(n - 1) : 1
            let idx = Int((pos * Double(src.count - 1)).rounded())
            return src[max(0, min(src.count - 1, idx))]
        }
    }

    var body: some View {
        let s = samples
        // Shifts every update, so the gradient rotates across the wave.
        let phase = (Date().timeIntervalSinceReferenceDate * 0.35).truncatingRemainder(dividingBy: 1)
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<s.count, id: \.self) { i in
                Capsule()
                    .fill(paused ? Color.white.opacity(0.25) : Sinky.rotatingColor(i, of: s.count, phase: phase))
                    .frame(width: 3, height: max(3, height * CGFloat(paused ? 0.12 : min(1, s[i]))))
            }
        }
        .frame(height: height)
        // Short, snappy transitions so the wave tracks the voice, not the default slow fade.
        .animation(.easeOut(duration: 0.2), value: levels)
    }
}
