// GopeedWidgets/GopeedWidgetsBundle.swift

import WidgetKit
import SwiftUI

@main
struct GopeedWidgetsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            GopeedDownloadTimelineWidget()  // wakes extension to update Live Activities
            GopeedDownloadWidget()           // Live Activity UI (Dynamic Island + Lock Screen)
        }
    }
}
