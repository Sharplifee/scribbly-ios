import SwiftUI
import WidgetKit
import AppIntents

struct RecordEntry: TimelineEntry { let date: Date }

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        completion(Timeline(entries: [RecordEntry(date: Date())], policy: .never))
    }
}


/// Tap target: the widget is a button that starts a recording in place (works
/// locked, in StandBy and CarPlay) — and tapped again while recording, stops
/// and saves it. Runs in Scribbly's own process.
struct RecordTap<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 18.0, *) {
            Button(intent: ToggleScribblyRecordingIntent()) { content() }.buttonStyle(.plain)
        } else {
            content().widgetURL(URL(string: "scribbly://record"))
        }
    }
}

struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            RecordTap {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "record.circle.fill").font(.system(size: 30, weight: .regular))
                }
            }
        case .accessoryRectangular:
            RecordTap {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scribbly").font(Sinky.font(15, .semibold))
                        Text("TAP · TAP AGAIN TO SAVE").font(Sinky.font(10, .medium, mono: true)).tracking(0.6)
                    }
                    Spacer(minLength: 0)
                }
            }
        case .accessoryInline:
            RecordTap { Label("Record · Scribbly", systemImage: "record.circle") }
        case .systemMedium:
            HStack(spacing: 12) {
                RecordTap {
                    HStack(spacing: 14) {
                        SinkyRecordMark(size: 58)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Record").font(Sinky.font(24, .semibold)).tracking(-0.8).foregroundColor(Sinky.ink)
                            Text("TAP AGAIN TO SAVE").font(Sinky.font(9.5, .medium, mono: true)).tracking(0.6)
                                .foregroundColor(Sinky.ink.opacity(0.85))
                            Capsule().fill(Sinky.rule).frame(width: 64, height: 1.5)
                        }
                        Spacer(minLength: 0)
                    }
                }
                ActionStack()
            }
            .padding(.horizontal, 4)
        case .systemLarge:
            RecordTap {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Scribbly").font(Sinky.font(22, .semibold)).tracking(-0.8).foregroundColor(Sinky.ink)
                    Spacer()
                    HStack { Spacer(); SinkyRecordMark(size: 110); Spacer() }
                    Spacer()
                    Text("Tap to record").font(Sinky.font(28, .semibold)).tracking(-1).foregroundColor(Sinky.ink)
                    Text("TAP AGAIN TO STOP & SAVE").font(Sinky.font(9.5, .medium, mono: true)).tracking(0.6)
                        .foregroundColor(Sinky.ink.opacity(0.85)).padding(.top, 4)
                }
                .padding(4)
            }
            .overlay(alignment: .topTrailing) { ActionStack(horizontal: true) }
        default: // systemSmall (also StandBy, CarPlay)
            RecordTap {
                VStack(alignment: .leading, spacing: 0) {
                    SinkyRecordMark(size: 44, ring: false)
                    Spacer()
                    Text("Record").font(Sinky.font(24, .semibold)).tracking(-0.8).foregroundColor(Sinky.ink)
                    Text("SCRIBBLY").font(Sinky.font(9.5, .medium, mono: true)).tracking(0.8).foregroundColor(Sinky.ink.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

/// Pause / Stop & Save buttons for the bigger widgets (iOS 18+).
struct ActionStack: View {
    var horizontal = false
    var body: some View {
        if #available(iOS 18.0, *) {
            let pause = Button(intent: PauseScribblyRecordingIntent()) { pill("pause.fill", "Pause") }.buttonStyle(.plain)
            let stop = Button(intent: StopScribblyRecordingIntent()) { pill("stop.fill", "Save") }.buttonStyle(.plain)
            if horizontal {
                HStack(spacing: 6) { pause; stop }
            } else {
                VStack(spacing: 8) { pause; stop }
            }
        }
    }
    private func pill(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(label).font(Sinky.font(12, .semibold))
        }
        .foregroundColor(Sinky.ink)
        .padding(.horizontal, 10).frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().stroke(Sinky.copperBright.opacity(0.6), lineWidth: 1))
        .accessibilityLabel(label == "Save" ? "Stop and save" : "Pause or resume")
    }
}

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.widget", provider: RecordProvider()) { _ in
            if #available(iOS 17.0, *) {
                RecordWidgetView().containerBackground(for: .widget) { SinkyFins() }
            } else {
                ZStack { SinkyFins().clipShape(ContainerRelativeShape()); RecordWidgetView().padding() }
            }
        }
        .configurationDisplayName("Scribbly Record")
        .description("Tap to record, tap again to stop and save — Home Screen, Lock Screen, StandBy and CarPlay.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
