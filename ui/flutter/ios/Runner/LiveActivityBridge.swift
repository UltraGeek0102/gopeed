import ActivityKit
import Foundation

class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    private init() {}

    func start(id: String, filename: String) {
        if #available(iOS 16.2, *) { _m.start(id: id, filename: filename) }
    }
    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        if #available(iOS 16.2, *) {
            _m.update(id: id, progress: progress, downloaded: downloaded, total: total)
        }
    }
    func end(id: String, success: Bool) {
        if #available(iOS 16.2, *) { _m.end(id: id, success: success) }
    }

    @available(iOS 16.2, *)
    private lazy var _m = LiveActivityManager()
}

@available(iOS 16.2, *)
private class LiveActivityManager {

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastBytes:  [String: Int64] = [:]
    private var lastTime:   [String: Date]  = [:]
    private let lock = NSLock()

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LA] not enabled"); return
        }
        lock.lock()
        if let old = activities[id] {
            Task.detached { await old.end(dismissalPolicy: .immediate) }
        }
        lock.unlock()

        let attrs = DownloadActivityAttributes(downloadId: id, filename: filename)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0, downloadedBytes: 0, totalBytes: 0,
            speedBytesPerSec: 0, statusLabel: "Downloading"
        )
        do {
            let act = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil)
            )
            lock.lock(); activities[id] = act; lock.unlock()
            print("[LA] started \(id)")
        } catch { print("[LA] start error: \(error)") }
    }

    /// Called from background URLSession delegate — this context IS valid for ActivityKit.
    /// No async/await tricks needed; we use a semaphore to wait for completion on-thread.
    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        lock.lock()
        let act = activities[id]
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime[id] ?? now)
        let delta   = downloaded - (lastBytes[id] ?? 0)
        let speed   = elapsed > 0.1 ? Int64(Double(max(delta, 0)) / elapsed) : 0
        lastBytes[id] = downloaded
        lastTime[id]  = now
        lock.unlock()

        guard let activity = act else { return }

        let state = DownloadActivityAttributes.ContentState(
            progress: min(max(progress, 0), 1),
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSec: speed,
            statusLabel: "Downloading"
        )
        let content = ActivityContent(state: state, staleDate: nil)

        // Block current thread until ActivityKit update completes.
        // This is safe because we're called from a background URLSession delegate
        // thread (not main thread, not cooperative pool).
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await activity.update(content)
            print("[LA] updated \(id) \(String(format:"%.1f",progress*100))%")
            sem.signal()
        }
        sem.wait()
    }

    func end(id: String, success: Bool) {
        lock.lock(); let act = activities[id]; lock.unlock()
        guard let activity = act else { return }

        let state = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0.0,
            downloadedBytes: lastBytes[id] ?? 0,
            totalBytes: 0, speedBytesPerSec: 0,
            statusLabel: success ? "Done" : "Failed"
        )
        Task.detached {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(5))
            )
        }
        lock.lock()
        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
        lock.unlock()
    }
}
