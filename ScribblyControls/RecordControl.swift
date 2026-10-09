import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center / Lock Screen control. Tapping it starts recording in
/// place — no unlock, no app opening — via StartScribblyRecordingIntent.
@available(iOS 18.0, *)
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.connor.scribbly.record") {
            ControlWidgetButton(action: StartScribblyRecordingIntent()) {
                Label("Scribbly", image: "scribbly.mark")   // our own mark, not a stock mic
            }
            .tint(Color(red: 0.66, green: 0.33, blue: 0.97))
        }
        .displayName("Scribbly Record")
        .description("Start a Scribbly recording instantly, even when locked.")
    }
}
