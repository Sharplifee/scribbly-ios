import SwiftUI
import WidgetKit

// Watch face complications + Smart Stack widgets — one for every recording
// action. The watch mic only records with the Scribbly app open, so each one
// opens it straight into that action (scribbly-watch://<action>).

struct TickEntry: TimelineEntry { let date: Date }

struct TickProvider: TimelineProvider {
    func placeholder(in context: Context) -> TickEntry { TickEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (TickEntry) -> Void) { completion(TickEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TickEntry>) -> Void) {
        completion(Timeline(entries: [TickEntry(date: Date())], policy: .never))
    }
}

enum WatchAction: String {
    case record, stop, toggle, open
    var url: URL { URL(string: "scribbly-watch://\(rawValue)")! }
    var icon: String {
        switch self {
        case .record: return "record.circle.fill"
        case .stop:   return "stop.circle.fill"
        case .toggle: return "record.circle"
        case .open:   return "waveform"
        }
    }
    var short: String {
        switch self {
        case .record: return "Record"
        case .stop:   return "Save"
        case .toggle: return "Rec/Stop"
        case .open:   return "Scribbly"
        }
    }
    var long: String {
        switch self {
        case .record: return "Start recording"
        case .stop:   return "Stop & save"
        case .toggle: return "Start or stop"
        case .open:   return "Open Scribbly"
        }
    }
}

struct ComplicationView: View {
    let action: WatchAction
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: action.icon).font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Sinky.copper)
                }
            case .accessoryCorner:
                Image(systemName: action.icon).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Sinky.copper)
                    .widgetLabel(action.long)
            case .accessoryInline:
                Label(action.long, systemImage: action.icon)
            default: // accessoryRectangular (also the Smart Stack)
                HStack(spacing: 8) {
                    Image(systemName: action.icon).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Sinky.copper)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scribbly®").font(.system(size: 15, weight: .semibold))
                        Text(action.long).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetURL(action.url)
        .containerBackground(for: .widget) { Color.black }
    }
}

private let families: [WidgetFamily] = [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]

struct RecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.watch.record", provider: TickProvider()) { _ in ComplicationView(action: .record) }
            .configurationDisplayName("Record")
            .description("Starts a Scribbly recording.")
            .supportedFamilies(families)
    }
}
struct StopComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.watch.stop", provider: TickProvider()) { _ in ComplicationView(action: .stop) }
            .configurationDisplayName("Stop & Save")
            .description("Stops the recording and sends it to your library.")
            .supportedFamilies(families)
    }
}
struct ToggleComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.watch.toggle", provider: TickProvider()) { _ in ComplicationView(action: .toggle) }
            .configurationDisplayName("Start or Stop")
            .description("Starts recording, or stops and saves if one is running.")
            .supportedFamilies(families)
    }
}
struct OpenComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.watch.open", provider: TickProvider()) { _ in ComplicationView(action: .open) }
            .configurationDisplayName("Scribbly®")
            .description("Opens Scribbly on your watch.")
            .supportedFamilies(families)
    }
}

@main
struct ScribblyWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordComplication()
        StopComplication()
        ToggleComplication()
        OpenComplication()
    }
}
