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

private let purple = Color(red: 0.66, green: 0.33, blue: 0.97)
private let magenta = Color(red: 0.75, green: 0.15, blue: 0.83)
private var brand: LinearGradient {
    LinearGradient(colors: [purple, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Tap target: on iOS 18+ the whole widget is a button that starts recording
/// in place (works locked, in StandBy and CarPlay). Older iOS opens the app
/// straight into recording.
struct RecordTap<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 18.0, *) {
            Button(intent: StartScribblyRecordingIntent()) { content() }.buttonStyle(.plain)
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
                    Image(systemName: "waveform").font(.system(size: 22, weight: .semibold))
                }
            }
        case .accessoryRectangular:
            RecordTap {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scribbly").font(.headline)
                        Text("Tap to record").font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            }
        case .accessoryInline:
            RecordTap { Label("Record · Scribbly", systemImage: "waveform") }
        case .systemMedium:
            RecordTap {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(.white.opacity(0.18)).frame(width: 78, height: 78)
                        Image(systemName: "mic.fill").font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Record").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                        Text("Starts instantly — even locked. Transcribed and saved to your library.")
                            .font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            }
        case .systemLarge:
            RecordTap {
                VStack(spacing: 14) {
                    Spacer()
                    ZStack {
                        Circle().fill(.white.opacity(0.18)).frame(width: 140, height: 140)
                        Image(systemName: "mic.fill").font(.system(size: 60, weight: .semibold)).foregroundColor(.white)
                    }
                    Text("Tap to record").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                    Text("Scribbly").font(.system(size: 14)).foregroundColor(.white.opacity(0.75))
                    Spacer()
                }
            }
        default: // systemSmall (also StandBy, CarPlay)
            RecordTap {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 34)).foregroundColor(.white)
                    Text("Record").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                }
            }
        }
    }
}

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.widget", provider: RecordProvider()) { _ in
            if #available(iOS 17.0, *) {
                RecordWidgetView().containerBackground(for: .widget) { brand }
            } else {
                ZStack { ContainerRelativeShape().fill(brand); RecordWidgetView() }
            }
        }
        .configurationDisplayName("Scribbly Record")
        .description("One tap starts a recording — Home Screen, Lock Screen, StandBy and CarPlay.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
