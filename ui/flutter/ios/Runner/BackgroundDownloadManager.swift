import Foundation
import UIKit
import AVFoundation

/// Drives Live Activity updates via chained background URLSession tasks.
///
/// Architecture:
/// - A background URLSession (managed by iOS networking daemon, NOT the app process)
///   makes repeated GET requests to the Go engine at 127.0.0.1:port
/// - iOS wakes the app via handleEventsForBackgroundURLSession when each completes
/// - In the delegate callback (a real system-granted execution window):
///     1. Parse the response and update the Live Activity — this WORKS here
///     2. Schedule the next background URLSession task immediately
///     3. Call the system completion handler to close this wake window
/// - This creates a self-perpetuating chain that gives continuous real-time updates
///
/// This is the same mechanism used by apps like Flighty for real-time Live Activities.
/// The key: background URLSession completions are system-granted execution windows
/// where ALL async APIs including ActivityKit work correctly.
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    // Background URLSession identifier for polling (different from file download session)
    static let pollSessionId = "com.gopeed.gopeed.lapoll"

    // MARK: - Go engine connection

    private(set) var goPort: Int = 0
    private(set) var apiToken: String = ""

    func configure(port: Int, apiToken: String) {
        self.goPort   = port
        self.apiToken = apiToken
        print("[BgDL] port=\(port)")
    }

    // MARK: - State

    private var activeIds:          Set<String> = []
    private var filenameMap:        [String: String] = [:]
    private let lock =              NSLock()
    private var progressHandlers:   [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: (Error?) -> Void] = [:]

    // Background URLSession for polling — iOS manages this, not our thread
    private lazy var pollSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.pollSessionId)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // Set by AppDelegate when system delivers background session events
    var systemCompletionHandler: (() -> Void)?

    // MARK: - Audio (keeps process alive between URLSession wake events)

    private var audioPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        setupAudio()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
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
        } catch { print("[BgDL] audio: \(error)") }
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
        if bgTaskId != .invalid { UIApplication.shared.endBackgroundTask(bgTaskId); bgTaskId = .invalid }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
            self.beginBgTask()
        }
    }

    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Background URLSession polling chain

    /// Schedule one poll request. iOS delivers the result via URLSessionDelegate
    /// even when the app is backgrounded, because it's a background URLSession.
    func schedulePollTask() {
        lock.lock()
        let has  = !activeIds.isEmpty
        let port = goPort
        lock.unlock()
        guard has, port > 0 else { return }

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks?status=running") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }
        // Short timeout so the chain reschedules quickly
        req.timeoutInterval = 4

        pollSession.dataTask(with: req).resume()
        print("[BgDL] poll task scheduled")
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
            LiveActivityBridge.shared.start(id: id, filename: filename)
            // Start the polling chain — first task fires immediately
            self.schedulePollTask()
        }
    }

    func updateProgress(id: String, progress: Double, downloaded: Int64, total: Int64) {
        LiveActivityBridge.shared.update(id: id, progress: progress,
                                         downloaded: downloaded, total: total)
    }

    func completeDownload(id: String, errorMessage: String?) {
        finishDownload(id: id, failed: errorMessage != nil)
    }
    func cancelDownload(id: String) { finishDownload(id: id, failed: false) }

    func reattach(id: String, onProgress: @escaping (Double, Int64, Int64) -> Void,
                  onComplete: @escaping (Error?) -> Void) {
        lock.lock(); progressHandlers[id] = onProgress; completionHandlers[id] = onComplete; lock.unlock()
    }

    private func finishDownload(id: String, failed: Bool) {
        lock.lock()
        let h = completionHandlers[id]
        activeIds.remove(id); filenameMap.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id); completionHandlers.removeValue(forKey: id)
        let left = activeIds.count
        lock.unlock()

        if let h = h {
            let err: Error? = failed ? NSError(domain: "com.gopeed", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed"]) : nil
            DispatchQueue.main.async { h(err) }
        }
        LiveActivityBridge.shared.end(id: id, success: !failed)
        if left == 0 {
            stopAudio(); endBgTask()
            print("[BgDL] all done")
        }
    }

    func applicationDidEnterBackground() {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        guard has else { return }
        beginBgTask()
        startAudio()
        print("[BgDL] backgrounded — chain continues via URLSession delegate")
    }

    func applicationWillEnterForeground() {
        endBgTask()
    }
}

// MARK: - URLSession delegate (called by iOS in proper execution context)

extension BackgroundDownloadManager: URLSessionDataDelegate {

    /// Called when a poll task receives data. Parse and update Live Activity.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        print("[BgDL] poll response received \(data.count) bytes")
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else {
            print("[BgDL] parse fail: \(String(data: data.prefix(100), encoding: .utf8) ?? "?")")
            return
        }

        lock.lock(); let active = activeIds; lock.unlock()
        let seen = Set(arr.compactMap { $0["id"] as? String })

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

            print("[BgDL] update \(id) \(String(format:"%.1f",frac*100))%")

            // This delegate is called in a system-granted background execution window.
            // ActivityKit update WORKS here — this is the correct context.
            LiveActivityBridge.shared.update(id: id, progress: frac, downloaded: dl, total: total)

            lock.lock(); let h = progressHandlers[id]; lock.unlock()
            if let h = h { DispatchQueue.main.async { h(frac, dl, total) } }
        }

        // Check for completions
        lock.lock(); let active2 = activeIds; lock.unlock()
        for id in active2.subtracting(seen) {
            // Task not in running list — might be done
            // Don't verify here to keep this delegate fast; let next poll catch it
            print("[BgDL] \(id) not in running list")
        }
    }

    /// Called when a poll task completes. Schedule the next one immediately.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let e = error { print("[BgDL] poll task error: \(e)") }

        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()

        if has {
            // Delay 1 second then schedule next poll
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.schedulePollTask()
            }
        }

        // Tell the system we've finished processing this background event
        systemCompletionHandler?()
        systemCompletionHandler = nil
    }

    /// Called when all background tasks for this session have finished.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("[BgDL] all session events finished")
        DispatchQueue.main.async {
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
