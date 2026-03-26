import WidgetKit
import SwiftUI

@main
struct SitchomaticWidgetBundle: WidgetBundle {
    var body: some Widget {
        SitchomaticWidget()
        CommandCenterLiveActivity()
    }
}
