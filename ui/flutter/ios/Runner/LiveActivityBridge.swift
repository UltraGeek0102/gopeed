import ActivityKit
import Foundation

/// Thin bridge callable from BackgroundDownloadManager and AppDelegate.
/// All public methods are safe to call on any iOS version — they are no-ops below 16.2.
class LiveActivityBridge {

    static let shared = LiveActivityBridge()
    private init() {}

    func start(id: String, filename: String) {
        if #available(iOS 16.2, *) {
            _manager.start(id: id, filename: filename)
        }
    }

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        if #available(iOS 16.2, *) {
            _manager.update(id: id, progress: progress, downloaded: downloaded, total: total)
        }
    }

    func end(id: String, success: Bool) {
        if #available(iOS 16.2, *) {
            _manager.end(id: id, success: success)
        }
    }

    // Backing store only accessible when @available check passes
    @available(iOS 16.2, *)
    private lazy var _manager = LiveActivityManager()
}

// MARK: - Actual manager (iOS 16.2+)

@available(iOS 16.2, *)
private class LiveActivityManager {

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastBytes: [String: Int64] = [:]
    private var lastTime: [String: Date] = [:]

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // If an activity for this id already exists, end it first
        if let existing = activities[id] {
            Task { await existing.end(dismissalPolicy: .immediate) }
        }

        let attrs = DownloadActivityAttributes(downloadId: id, filename: filename)
        let initialState = DownloadActivityAttributes.ContentState(
            progress: 0,
            downloadedBytes: 0,
            totalBytes: 0,
            speedBytesPerSec: 0,
            statusLabel: "Downloading"
        )

        do {
            let activity = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(
                    state: initialState,
                    staleDate: Date().addingTimeInterval(4 * 3600)
                )
            )
            activities[id] = activity
        } catch {
            // Live Activities not available or user disabled them — silent fail
            print("[LiveActivity] start failed for \(id): \(error)")
        }
    }

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        guard let activity = activities[id] else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime[id] ?? now)
        let delta = downloaded - (lastBytes[id] ?? 0)
        let speed: Int64 = elapsed > 0.5 ? Int64(Double(delta) / elapsed) : 0

        lastBytes[id] = downloaded
        lastTime[id] = now

        let updatedState = DownloadActivityAttributes.ContentState(
            progress: min(max(progress, 0), 1),
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSec: max(speed, 0),
            statusLabel: "Downloading"
        )

        Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: nil)
            )
        }
    }

    func end(id: String, success: Bool) {
        guard let activity = activities[id] else { return }

        let finalState = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0.0,
            downloadedBytes: lastBytes[id] ?? 0,
            totalBytes: 0,
            speedBytesPerSec: 0,
            statusLabel: success ? "Done" : "Failed"
        )

        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(5))
            )
        }

        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
    }
}
