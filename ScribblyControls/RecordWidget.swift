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

struct RecordWidgetView: View {
    var body: some View {
        ZStack {
            ContainerRelativeShape().fill(
                LinearGradient(colors: [Color(red:0.66,green:0.33,blue:0.97),
                                        Color(red:0.75,green:0.15,blue:0.83)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 34)).foregroundColor(.white)
                Text("Record").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            }
        }
        // Tapping the widget runs the same intent → opens app recording.
        .widgetURL(URL(string: "scribbly://record"))
    }
}

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.connor.scribbly.widget", provider: RecordProvider()) { _ in
            RecordWidgetView()
        }
        .configurationDisplayName("Scribbly Record")
        .description("Tap to open Scribbly and start recording.")
        .supportedFamilies([.systemSmall])
    }
}
