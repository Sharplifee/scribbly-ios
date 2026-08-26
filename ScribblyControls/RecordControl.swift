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
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Scribbly Record")
        .description("Start a Scribbly recording.")
    }
}
