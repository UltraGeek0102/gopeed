import ActivityKit
import Foundation

class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    private init() {}

    func start(id: String, filename: String) {
        if #available(iOS 16.2, *) { _manager.start(id: id, filename: filename) }
    }
    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        if #available(iOS 16.2, *) {
            _manager.update(id: id, progress: progress, downloaded: downloaded, total: total)
        }
    }
    func end(id: String, success: Bool) {
        if #available(iOS 16.2, *) { _manager.end(id: id, success: success) }
    }

    @available(iOS 16.2, *)
    private lazy var _manager = LiveActivityManager()
}

// MARK: -

@available(iOS 16.2, *)
private class LiveActivityManager {

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastBytes:  [String: Int64] = [:]
    private var lastTime:   [String: Date]  = [:]

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let old = activities[id] {
            // End old activity synchronously via main actor
            Task { @MainActor in
                await old.end(dismissalPolicy: .immediate)
            }
        }
        let attrs = DownloadActivityAttributes(downloadId: id, filename: filename)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0, downloadedBytes: 0, totalBytes: 0,
            speedBytesPerSec: 0, statusLabel: "Downloading"
        )
        do {
            let activity = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil)
            )
            activities[id] = activity
            print("[LiveActivity] started \(id)")
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        guard let activity = activities[id] else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime[id] ?? now)
        let delta   = downloaded - (lastBytes[id] ?? 0)
        let speed   = elapsed > 0.1 ? Int64(Double(max(delta, 0)) / elapsed) : Int64(0)
        lastBytes[id] = downloaded
        lastTime[id]  = now

        let state = DownloadActivityAttributes.ContentState(
            progress: min(max(progress, 0), 1),
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSec: speed,
            statusLabel: "Downloading"
        )
        let content = ActivityContent(state: state, staleDate: nil)

        // @MainActor: runs on the main thread's RunLoop.
        // When AVAudioSession .playback is active, iOS keeps the main RunLoop
        // alive even in background — audio render callbacks require it.
        // This is the ONLY executor guaranteed to run while backgrounded
        // without a server-side push notification.
        Task { @MainActor in
            await activity.update(content)
            print("[LiveActivity] updated \(id) \(String(format:"%.1f",progress*100))%")
        }
    }

    func end(id: String, success: Bool) {
        guard let activity = activities[id] else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0.0,
            downloadedBytes: lastBytes[id] ?? 0,
            totalBytes: 0, speedBytesPerSec: 0,
            statusLabel: success ? "Done" : "Failed"
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task { @MainActor in
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
        }
        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
    }
}
