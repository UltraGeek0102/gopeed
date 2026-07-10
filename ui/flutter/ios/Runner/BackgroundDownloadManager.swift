import Foundation
import UIKit
import AVFoundation
import UserNotifications

/// Keeps the Go engine's downloads tracked while the app is backgrounded, and
/// fires a local notification when each download completes.
///
/// No Live Activity, no location/motion tracking — just:
/// 1. AVAudioSession keeps the process alive so the Go engine keeps downloading
/// 2. A background URLSession chain polls the Go engine to detect completion
/// 3. A local notification fires the moment a download finishes
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()
    static let pollSessionId = "com.gopeed.gopeed.lapoll"

    // MARK: - Go engine connection

    private(set) var goPort: Int = 0
    private(set) var apiToken: String = ""

    func configure(port: Int, apiToken: String) {
        self.goPort   = port
        self.apiToken = apiToken
        print("[BgDL] configured port=\(port)")
    }

    // MARK: - State

    private var activeIds:          Set<String> = []
    private var filenameMap:        [String: String] = [:]
    private let lock =              NSLock()
    private var progressHandlers:   [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: (Error?) -> Void] = [:]

    // Background URLSession — managed by iOS nsurlsessiond, not suspended with app
    private lazy var pollSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.pollSessionId)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // Completion handler provided by iOS via handleEventsForBackgroundURLSession.
    var systemCompletionHandler: (() -> Void)?

    private var taskData: [Int: Data] = [:]

    // Prevents overlapping poll requests from piling up against the Go engine's
    // TCP listener. Without this, foreground 1s chaining + foreground triggers +
    // background wake events can all fire schedulePollTask() concurrently,
    // saturating the Go server's connection queue until it stops responding
    // (surfacing as "REQUEST TIMEOUT" on unrelated new requests) until the
    // process is killed and relaunched.
    private var pollInFlight = false

    // Tracks ids currently being checked via checkFinalStatus so a task that
    // drops out of the "running" list on two consecutive polls (a normal race,
    // since checkFinalStatus is async) doesn't fire two overlapping status
    // checks — and doesn't risk finishDownload running twice for the same id.
    private var checkingFinalStatus: Set<String> = []

    // Maps a URLSessionTask.taskIdentifier to the download id it's checking the
    // final status of. Background URLSessionConfiguration does not support
    // completion-handler-based tasks, so final-status checks must also go
    // through the shared delegate — this lets didCompleteWithError tell them
    // apart from regular /tasks?status=running polls.
    private var finalStatusTaskIds: [Int: String] = [:]

    // MARK: - Audio keep-alive (keeps the Go engine's download running in background)

    private var audioPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        setupAudio()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("[BgDL] audio setup: \(error)") }
    }

    private func startAudio() {
        audioPlayer?.stop(); audioPlayer = nil
        do { try AVAudioSession.sharedInstance().setActive(true) } catch {}
        let sr = 44100, secs = 30, ds = sr * secs * 2
        var wav = Data(count: 44 + ds)
        wav.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            let h: [UInt8] = [
                0x52,0x49,0x46,0x46,
                UInt8((ds+36)&0xFF),    UInt8((ds+36)>>8&0xFF),
                UInt8((ds+36)>>16&0xFF),UInt8((ds+36)>>24&0xFF),
                0x57,0x41,0x56,0x45,   0x66,0x6D,0x74,0x20,
                0x10,0x00,0x00,0x00,   0x01,0x00, 0x01,0x00,
                0x44,0xAC,0x00,0x00,   0x88,0x58,0x01,0x00,
                0x02,0x00, 0x10,0x00,  0x64,0x61,0x74,0x61,
                UInt8(ds&0xFF),         UInt8(ds>>8&0xFF),
                UInt8(ds>>16&0xFF),     UInt8(ds>>24&0xFF)
            ]
            h.enumerated().forEach {
                b.storeBytes(of: $0.element, toByteOffset: $0.offset, as: UInt8.self)
            }
        }
        do {
            audioPlayer = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.play()
            print("[BgDL] audio playing")
        } catch { print("[BgDL] audio error: \(error)") }
    }

    private func stopAudio() { audioPlayer?.stop(); audioPlayer = nil }

    @objc private func audioInterrupted(_ n: Notification) {
        guard
            let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: v) == .ended
        else { return }
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has { startAudio() }
    }

    private func beginBgTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId); bgTaskId = .invalid
        }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
            self.beginBgTask()
        }
    }

    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId); bgTaskId = .invalid
    }

    // MARK: - Poll scheduling
    // Polls the Go engine to detect progress/completion. In foreground this
    // chains every ~1s for live progress in the app UI. In background it just
    // needs to catch completion eventually — the download itself keeps running
    // via the Go engine regardless of how often we poll.

    func schedulePollTask() {
        lock.lock()
        let has  = !activeIds.isEmpty
        let port = goPort
        let inFlight = pollInFlight
        if has && port > 0 && !inFlight {
            pollInFlight = true
        }
        lock.unlock()

        guard has, port > 0 else {
            print("[BgDL] no active downloads or port not set, skip poll")
            return
        }
        guard !inFlight else {
            // A poll is already outstanding — skip this trigger rather than
            // stacking another request on top of it.
            print("[BgDL] poll already in flight, skipping")
            return
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks?status=running") else {
            lock.lock(); pollInFlight = false; lock.unlock()
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }
        req.timeoutInterval = 4

        let task = pollSession.dataTask(with: req)
        taskData[task.taskIdentifier] = Data()
        task.resume()
    }

    // MARK: - Public API

    func registerDownload(id: String, filename: String,
                          onProgress: @escaping (Double, Int64, Int64) -> Void,
                          onComplete: @escaping (Error?) -> Void) {
        lock.lock()
        activeIds.insert(id); filenameMap[id] = filename
        progressHandlers[id] = onProgress; completionHandlers[id] = onComplete
        lock.unlock()
        DispatchQueue.main.async {
            self.beginBgTask()
            self.startAudio()
            self.schedulePollTask()
        }
    }

    func updateProgress(id: String, progress: Double, downloaded: Int64, total: Int64) {
        // No-op hook retained for API compatibility with the Flutter side.
    }

    func completeDownload(id: String, errorMessage: String?) {
        finishDownload(id: id, failed: errorMessage != nil)
    }
    func cancelDownload(id: String) {
        lock.lock()
        activeIds.remove(id)
        filenameMap.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        let left = activeIds.count
        lock.unlock()
        if left == 0 { stopAudio(); endBgTask() }
    }

    func reattach(id: String, onProgress: @escaping (Double, Int64, Int64) -> Void,
                  onComplete: @escaping (Error?) -> Void) {
        lock.lock(); progressHandlers[id] = onProgress; completionHandlers[id] = onComplete; lock.unlock()
    }

    private func finishDownload(id: String, failed: Bool) {
        lock.lock()
        let h = completionHandlers[id]
        let filename = filenameMap[id] ?? "Download"
        activeIds.remove(id); filenameMap.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id); completionHandlers.removeValue(forKey: id)
        let left = activeIds.count
        lock.unlock()

        if let h = h {
            let err: Error? = failed ? NSError(domain: "com.gopeed", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed"]) : nil
            DispatchQueue.main.async { h(err) }
        }

        notifyDownloadFinished(filename: filename, failed: failed)

        if left == 0 { stopAudio(); endBgTask(); print("[BgDL] all done") }
    }

    // MARK: - Local notification

    private func notifyDownloadFinished(filename: String, failed: Bool) {
        let content = UNMutableNotificationContent()
        content.title = failed ? "Download failed" : "Download complete"
        content.body  = filename
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "gopeed-download-\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BgDL] notification error: \(error)")
            }
        }
    }

    // MARK: - App lifecycle

    func applicationDidEnterBackground() {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        guard has else { return }
        beginBgTask(); startAudio()
        print("[BgDL] backgrounded — \(activeIds.count) active downloads, audio keep-alive on")
    }

    func applicationWillEnterForeground() {
        endBgTask()
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has {
            schedulePollTask()
            print("[BgDL] foregrounded — triggered immediate poll for fresh state")
        }
    }
}

// MARK: - URLSessionDataDelegate

extension BackgroundDownloadManager: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        taskData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let completedData = taskData[task.taskIdentifier]
        defer { taskData.removeValue(forKey: task.taskIdentifier) }

        lock.lock()
        let finalStatusId = finalStatusTaskIds.removeValue(forKey: task.taskIdentifier)
        // Only the regular polling path (not final-status checks) holds the
        // in-flight guard, since final-status checks are already de-duplicated
        // per-id via checkingFinalStatus and should not block the next poll.
        if finalStatusId == nil { pollInFlight = false }
        lock.unlock()

        if let e = error {
            print("[BgDL] task error: \(e)")
            if let id = finalStatusId {
                // Treat a network error on the status check as inconclusive —
                // don't mark it failed just because the check itself timed out.
                lock.lock(); checkingFinalStatus.remove(id); lock.unlock()
            }
            return
        }

        if let id = finalStatusId {
            handleFinalStatusResponse(id: id, data: completedData)
        } else if let data = completedData, !data.isEmpty {
            processData(data)
        }

        // Reschedule continuously while foregrounded for live progress in the app UI.
        // While backgrounded, rely on the next natural background URLSession wake
        // (iOS decides timing) rather than trying to force a fixed cadence.
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has && UIApplication.shared.applicationState != .background {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                self.schedulePollTask()
            }
        }

        callSystemCompletionHandler()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        callSystemCompletionHandler()
    }

    private func callSystemCompletionHandler() {
        DispatchQueue.main.async {
            guard let h = self.systemCompletionHandler else { return }
            self.systemCompletionHandler = nil
            h()
        }
    }

    private func processData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else { return }

        lock.lock(); let active = activeIds; lock.unlock()
        let stillRunning = Set(arr.compactMap { $0["id"] as? String })

        for t in arr {
            guard
                let id   = t["id"] as? String, active.contains(id),
                let prog = t["progress"] as? [String: Any],
                let meta = t["meta"] as? [String: Any]
            else { continue }

            let dl    = (prog["downloaded"] as? Int64) ?? Int64((prog["downloaded"] as? Int) ?? 0)
            let res   = meta["res"] as? [String: Any]
            let total = (res?["size"] as? Int64) ?? Int64((res?["size"] as? Int) ?? 0)
            let frac  = total > 0 ? Double(dl) / Double(total) : 0.0

            lock.lock(); let h = progressHandlers[id]; lock.unlock()
            if let h = h { DispatchQueue.main.async { h(frac, dl, total) } }
        }

        // Any tracked id no longer in the "running" list has finished or errored —
        // check its actual status and fire the completion notification.
        for id in active.subtracting(stillRunning) {
            checkFinalStatus(id: id)
        }
    }

    /// A task that dropped out of the "running" list needs one more check to
    /// find out whether it finished successfully or errored, so we can show
    /// the right notification. De-duplicated per id since processData can run
    /// again (a normal race with the async check below) before the first
    /// check has resolved and removed the id from activeIds.
    ///
    /// Uses the same delegate-based pollSession as regular polls — background
    /// URLSessionConfiguration does not support completion-handler-based tasks,
    /// so this must be routed through didReceive/didCompleteWithError like
    /// every other request on this session.
    private func checkFinalStatus(id: String) {
        lock.lock()
        guard !checkingFinalStatus.contains(id) else { lock.unlock(); return }
        checkingFinalStatus.insert(id)
        let port = goPort
        lock.unlock()

        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks/\(id)") else {
            lock.lock(); checkingFinalStatus.remove(id); lock.unlock()
            finishDownload(id: id, failed: false)
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }
        req.timeoutInterval = 4

        let task = pollSession.dataTask(with: req)
        taskData[task.taskIdentifier] = Data()
        lock.lock(); finalStatusTaskIds[task.taskIdentifier] = id; lock.unlock()
        task.resume()
    }

    /// Called from didCompleteWithError once a final-status-check task finishes.
    private func handleFinalStatusResponse(id: String, data: Data?) {
        var failed = false
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let task = json["data"] as? [String: Any],
           let status = task["status"] as? String {
            failed = (status == "error")
        }
        lock.lock(); checkingFinalStatus.remove(id); lock.unlock()
        finishDownload(id: id, failed: failed)
    }
}
