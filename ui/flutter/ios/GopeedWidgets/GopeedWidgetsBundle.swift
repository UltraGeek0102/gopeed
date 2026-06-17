// GopeedWidgets/GopeedWidgetsBundle.swift
// Entry point for the GopeedWidgets extension target.

import WidgetKit
import SwiftUI

@main
struct GopeedWidgetsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            GopeedDownloadWidget()
        }
    }
}
