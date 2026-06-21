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

@available(iOS 16.2, *)
private class LiveActivityManager {

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastBytes:  [String: Int64] = [:]
    private var lastTime:   [String: Date]  = [:]

    // Serial queue to serialise all ActivityKit mutations
    private let q = DispatchQueue(label: "com.gopeed.liveactivity", qos: .userInitiated)

    func start(id: String, filename: String) {
        q.async {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            if let old = self.activities[id] {
                Task.detached { await old.end(dismissalPolicy: .immediate) }
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
                self.activities[id] = activity
                print("[LA] started \(id)")
            } catch {
                print("[LA] start error: \(error)")
            }
        }
    }

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        q.async {
            guard let activity = self.activities[id] else { return }

            let now     = Date()
            let elapsed = now.timeIntervalSince(self.lastTime[id] ?? now)
            let delta   = downloaded - (self.lastBytes[id] ?? 0)
            let speed   = elapsed > 0.1 ? Int64(Double(max(delta, 0)) / elapsed) : 0
            self.lastBytes[id] = downloaded
            self.lastTime[id]  = now

            let state = DownloadActivityAttributes.ContentState(
                progress: min(max(progress, 0), 1),
                downloadedBytes: downloaded,
                totalBytes: total,
                speedBytesPerSec: speed,
                statusLabel: "Downloading"
            )
            let content = ActivityContent(state: state, staleDate: nil)

            // Use a semaphore to block the serial queue until the async update completes.
            // This ensures updates are sequential and the queue doesn't flood ActivityKit.
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                await activity.update(content)
                print("[LA] updated \(id) \(String(format:"%.1f", progress*100))%")
                sem.signal()
            }
            // Wait max 3s - if this times out the update is dropped but the queue continues
            _ = sem.wait(timeout: .now() + 3)
        }
    }

    func end(id: String, success: Bool) {
        q.async {
            guard let activity = self.activities[id] else { return }
            let state = DownloadActivityAttributes.ContentState(
                progress: success ? 1.0 : 0.0,
                downloadedBytes: self.lastBytes[id] ?? 0,
                totalBytes: 0, speedBytesPerSec: 0,
                statusLabel: success ? "Done" : "Failed"
            )
            let content = ActivityContent(state: state, staleDate: nil)
            Task.detached(priority: .userInitiated) {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
            }
            self.activities.removeValue(forKey: id)
            self.lastBytes.removeValue(forKey: id)
            self.lastTime.removeValue(forKey: id)
        }
    }
}
