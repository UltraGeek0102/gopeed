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
    private var lastBytes: [String: Int64] = [:]
    private var lastTime: [String: Date] = [:]
    
    // Track the last time a background UI update was ACTUALLY pushed to iOS
    private var lastBgWidgetUpdateTime: [String: Date] = [:]

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] activities not enabled")
            return
        }

        if let existing = activities[id] {
            Task.detached(priority: .utility) {
                await existing.end(dismissalPolicy: .immediate)
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
            print("[LiveActivity] started for \(id)")
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func update(id: String, progress: Double, downloaded: Int64, total: Int64) {
        guard let activity = activities[id] else {
            print("[LiveActivity] update called but no activity for \(id)")
            return
        }

        let now = Date()
        
        // Check if the application is currently backgrounded
        let isBackground = UIApplication.shared.applicationState != .active
        
        // Enforce a strict 10-second update limit ONLY if we are in the background.
        if isBackground {
            if let lastWidgetUpdate = lastBgWidgetUpdateTime[id], 
               now.timeIntervalSince(lastWidgetUpdate) < 10.0 {
                // Skip pushing to ActivityKit to preserve system update budget.
                // We return immediately to avoid corrupting speed tracking data on dropped frames.
                return
            }
        }

        let elapsed = now.timeIntervalSince(lastTime[id] ?? now)
        let delta = downloaded - (lastBytes[id] ?? 0)
        let speed: Int64 = elapsed > 0.1 ? Int64(Double(max(delta, 0)) / elapsed) : 0

        lastBytes[id] = downloaded
        lastTime[id] = now
        
        if isBackground {
            // Log the exact execution timestamp of the permitted background update
            lastBgWidgetUpdateTime[id] = now
        }

        let state = DownloadActivityAttributes.ContentState(
            progress: min(max(progress, 0), 1),
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSec: speed,
            statusLabel: "Downloading"
        )

        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached(priority: .utility) {
            await activity.update(content)
            print("[LiveActivity] updated \(id) progress=\(String(format: "%.1f", progress*100))% (Bg: \(isBackground))")
        }
    }

    func end(id: String, success: Bool) {
        guard let activity = activities[id] else { return }

        let state = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0.0,
            downloadedBytes: lastBytes[id] ?? 0,
            totalBytes: 0,
            speedBytesPerSec: 0,
            statusLabel: success ? "Done" : "Failed"
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached(priority: .utility) {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
            print("[LiveActivity] ended \(id) success=\(success)")
        }

        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
        lastBgWidgetUpdateTime.removeValue(forKey: id) // Clean up tracking
    }
}
