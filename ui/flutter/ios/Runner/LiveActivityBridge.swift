import ActivityKit
import Foundation
import WidgetKit

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
    private var filenames:  [String: String] = [:]
    private let lock = NSLock()

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lock.lock()
        filenames[id] = filename
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

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        // ── Step 1: synchronous — runs on poll thread, NEVER suspended ────────
        // Calculate speed and snapshot all state before any async work.
        lock.lock()
        let act      = activities[id]
        let filename = filenames[id] ?? ""
        let now      = Date()
        let elapsed  = now.timeIntervalSince(lastTime[id] ?? now)
        let delta    = downloaded - (lastBytes[id] ?? 0)
        let speed    = elapsed > 0.1 ? Int64(Double(max(delta, 0)) / elapsed) : 0
        lastBytes[id] = downloaded
        lastTime[id]  = now
        lock.unlock()

        // Write to App Group synchronously — this is a plain dictionary write,
        // no async/await, always executes on the calling (poll) thread.
        SharedProgressStore.shared.update(
            id: id, filename: filename, progress: progress,
            downloaded: downloaded, total: total, speed: speed
        )

        // Wake the widget extension process synchronously.
        // The extension reads from App Group and calls activity.update() from
        // its own process — which is never suspended by iOS.
        WidgetCenter.shared.reloadTimelines(ofKind: "GopeedDownloadWidget")

        // ── Step 2: async direct update (works while foregrounded) ────────────
        // This path may not execute in background due to cooperative pool
        // suspension, but Step 1 already handled the background case reliably.
        guard let activity = act else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: min(max(progress, 0), 1),
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSec: speed,
            statusLabel: "Downloading"
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached(priority: .userInitiated) {
            await activity.update(content)
            print("[LA] updated \(id) \(String(format:"%.1f", progress*100))%")
        }
    }

    func end(id: String, success: Bool) {
        lock.lock()
        let act      = activities[id]
        let dl       = lastBytes[id] ?? 0
        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
        filenames.removeValue(forKey: id)
        lock.unlock()

        // Clean up App Group synchronously
        SharedProgressStore.shared.remove(id: id)
        WidgetCenter.shared.reloadTimelines(ofKind: "GopeedDownloadWidget")

        guard let activity = act else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0.0,
            downloadedBytes: dl,
            totalBytes: 0, speedBytesPerSec: 0,
            statusLabel: success ? "Done" : "Failed"
        )
        Task.detached {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(5))
            )
        }
    }
}
