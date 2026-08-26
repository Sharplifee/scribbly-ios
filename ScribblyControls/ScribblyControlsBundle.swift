import WidgetKit
import SwiftUI

@main
struct ScribblyControlsBundle: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        if #available(iOS 18.0, *) { RecordControl() }
    }
}
