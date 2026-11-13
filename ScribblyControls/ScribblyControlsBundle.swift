import WidgetKit
import SwiftUI

@main
struct ScribblyControlsBundle: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        RecordControl()
        StopControl()
        ToggleControl()
        PauseControl()
        RecordingLiveActivityWidgetPlus()        // Lock Screen, island, + CarPlay / Watch small layout
    }
}
