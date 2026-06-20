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

    // A dedicated OS thread with its own RunLoop.
    // Swift concurrency Tasks created inside this RunLoop use IT as their
    // executor — not the cooperative thread pool that iOS suspends in background.
    private let activityThread = ActivityKitThread()

    func start(id: String, filename: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let old = activities[id] {
            activityThread.run { await old.end(dismissalPolicy: .immediate) }
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

        // Run on the dedicated ActivityKit thread — bypasses cooperative pool suspension.
        activityThread.run {
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
        activityThread.run {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
            print("[LiveActivity] ended \(id)")
        }
        activities.removeValue(forKey: id)
        lastBytes.removeValue(forKey: id)
        lastTime.removeValue(forKey: id)
    }
}

// MARK: - Dedicated RunLoop thread for ActivityKit async calls
//
// Problem: Swift's cooperative thread pool is suspended by iOS when the app
// is backgrounded, so `Task { await activity.update() }` never executes.
//
// Fix: Create a real OS Thread with its own RunLoop that stays alive forever.
// When you schedule work on this thread's RunLoop, Swift async calls use
// *that* thread as their executor — iOS cannot suspend individual threads
// the same way it suspends the cooperative pool.
//
// This is the same pattern UIKit uses internally for animation callbacks
// and how third-party media frameworks handle background playback.

private class ActivityKitThread: NSObject {

    private var thread: Thread!
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        thread = Thread(target: self, selector: #selector(threadMain), object: nil)
        thread.name = "com.gopeed.activitykit"
        thread.qualityOfService = .userInitiated   // high priority — not background
        thread.start()
        ready.wait() // block until RunLoop is ready
    }

    @objc private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        // Add a dummy source so the RunLoop doesn't exit immediately
        let ctx = CFRunLoopSourceContext()
        var mutableCtx = ctx
        let source = CFRunLoopSourceCreate(nil, 0, &mutableCtx)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        ready.signal()
        CFRunLoopRun() // run forever until CFRunLoopStop is called
    }

    /// Schedule an async block on this thread's RunLoop.
    func run(_ block: @escaping () async -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
            // Create the Task while ON this thread — Swift concurrency will
            // use this thread's RunLoop as the executor for the await points.
            Task {
                await block()
            }
        }
        CFRunLoopWakeUp(rl)
    }
}
