import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center button. Tapping it runs StartRecordingIntent, which
/// opens Scribbly straight into recording.
@available(iOS 18.0, *)
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Scribbly", image: "scribbly.mark")   // our own mark, not a stock mic
            }
            .tint(Color(red: 0.66, green: 0.33, blue: 0.97))
        }
        .displayName("Scribbly Record")
        .description("Start a Scribbly recording.")
    }
}
