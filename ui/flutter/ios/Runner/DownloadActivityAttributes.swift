import ActivityKit
import Foundation

/// Shared between the Runner target and GopeedWidgets extension.
/// Add this file to BOTH targets in Xcode (or use a shared framework).
///
/// Static attributes: set once when the activity is started, never change.
/// ContentState:      updated as download progresses.

@available(iOS 16.2, *)
struct DownloadActivityAttributes: ActivityAttributes {

    /// Dynamic state — updated via ActivityKit as the download progresses
    public struct ContentState: Codable, Hashable {
        /// 0.0 – 1.0
        var progress: Double
        var downloadedBytes: Int64
        var totalBytes: Int64
        /// Bytes per second (rolling average)
        var speedBytesPerSec: Int64
        /// Status string shown to the user: "Downloading", "Done", "Failed", etc.
        var statusLabel: String
    }

    /// Static metadata set at activity creation time
    var downloadId: String
    /// Display name (filename or task name)
    var filename: String
}
