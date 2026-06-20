import Foundation
import UIKit
import AVFoundation

class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    // MARK: - Go engine connection

    private(set) var goPort: Int = 0
    private(set) var apiToken: String = ""

    func configure(port: Int, apiToken: String) {
        self.goPort = port
        self.apiToken = apiToken
        print("[BgDL] Configured port=\(port)")
    }

    // MARK: - State

    private var activeIds: Set<String> = []
    private var filenameMap: [String: String] = [:]
    private let lock = NSLock()
    private var progressHandlers: [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: (Error?) -> Void] = [:]

    // MARK: - Keep-alive

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    // Dedicated background queue — not main thread, not suspended by iOS when backgrounded
    private let pollQueue = DispatchQueue(label: "com.gopeed.bgpoll", qos: .utility)
    private var pollWorkItem: DispatchWorkItem?
    private var isPolling = false

    // URLSession with .default config — ephemeral gets suspended in background
    private lazy var httpSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private override init() {
        super.init()
        setupAudioSession()
        // Observe audio session interruptions so we can restart after phone calls etc.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    // MARK: - AVAudioSession

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]  // don't duck others, just mix silently
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[BgDL] AVAudioSession setup error: \(error)")
        }
    }

    private func startSilentAudio() {
        // Always recreate the player to ensure it's active after interruptions
        audioPlayer?.stop()
        audioPlayer = nil

        // Build a minimal silent WAV
        let sr = 44100, n = sr / 10, ds = n * 2
        var wav = Data(count: 44 + ds)
        wav.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            let h: [UInt8] = [
                0x52,0x49,0x46,0x46,
                UInt8((ds+36)&0xFF), UInt8((ds+36)>>8&0xFF),
                UInt8((ds+36)>>16&0xFF), UInt8((ds+36)>>24&0xFF),
                0x57,0x41,0x56,0x45, 0x66,0x6D,0x74,0x20,
                0x10,0x00,0x00,0x00, 0x01,0x00, 0x01,0x00,
                0x44,0xAC,0x00,0x00, 0x88,0x58,0x01,0x00,
                0x02,0x00, 0x10,0x00, 0x64,0x61,0x74,0x61,
                UInt8(ds&0xFF), UInt8(ds>>8&0xFF),
                UInt8(ds>>16&0xFF), UInt8(ds>>24&0xFF)
            ]
            h.enumerated().forEach {
                b.storeBytes(of: $0.element, toByteOffset: $0.offset, as: UInt8.self)
            }
        }

        do {
            // Re-activate session each time — iOS may have deactivated it
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01  // Not truly 0 — iOS 15+ may ignore silent audio
            audioPlayer?.prepareToPlay()
            let started = audioPlayer?.play() ?? false
            print("[BgDL] Audio player started: \(started)")
        } catch {
            print("[BgDL] AVAudioPlayer error: \(error)")
        }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended {
            // Interruption ended (e.g. phone call finished) — restart audio
            lock.lock()
            let hasActive = !activeIds.isEmpty
            lock.unlock()
            if hasActive {
                print("[BgDL] Audio interruption ended — restarting")
                startSilentAudio()
            }
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        // Headphones unplugged etc — restart if needed
        if reason == .oldDeviceUnavailable || reason == .categoryChange {
            lock.lock()
            let hasActive = !activeIds.isEmpty
            lock.unlock()
            if hasActive && audioPlayer?.isPlaying != true {
                print("[BgDL] Audio route changed — restarting audio")
                startSilentAudio()
            }
        }
    }

    // MARK: - Background task token

    private func beginBgTask() {
        // Always end any existing one first, then create a fresh one
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed.dl") {
            // Expiry — audio session should take over, but renew the token anyway
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
            // Immediately try to grab a new one
            self.beginBgTask()
        }
    }

    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Poll timer on background DispatchQueue
    // Using a DispatchQueue with recursive rescheduling instead of Timer/RunLoop.
    // DispatchQueue.asyncAfter on a background queue fires regardless of main
    // thread sleep state, as long as the process itself is alive.

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        scheduleNextPoll()
        print("[BgDL] Polling started on background queue")
    }

    private func stopPolling() {
        isPolling = false
        pollWorkItem?.cancel()
        pollWorkItem = nil
        print("[BgDL] Polling stopped")
    }

    private func scheduleNextPoll() {
        guard isPolling else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPolling else { return }
            self.pollGoEngine()
            // Reschedule immediately after completion (not after 1s from now)
            // so polls don't stack up if network is slow
            self.pollQueue.asyncAfter(deadline: .now() + 1.0) {
                self.scheduleNextPoll()
            }
        }
        pollWorkItem = item
        pollQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func pollGoEngine() {
        lock.lock()
        let hasActive = !activeIds.isEmpty
        let port = goPort
        lock.unlock()
        guard hasActive, port > 0 else { return }

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks?status=running") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }

        // Synchronous-style using semaphore so we know when it's done before rescheduling
        let sem = DispatchSemaphore(value: 0)
        httpSession.dataTask(with: req) { [weak self] data, _, error in
            defer { sem.signal() }
            guard let self = self, let data = data, error == nil else { return }
            self.processPollData(data)
        }.resume()
        // Wait max 2.5s for response (fits within 3s timeout)
        _ = sem.wait(timeout: .now() + 2.5)
    }

    private func processPollData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else { return }

        lock.lock()
        let active = activeIds
        lock.unlock()

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

            // Call LiveActivityBridge directly from poll queue — no main thread needed
            // LiveActivityBridge uses Task{} which is concurrency-safe
            LiveActivityBridge.shared.update(id: id, progress: frac, downloaded: dl, total: total)

            lock.lock()
            let h = progressHandlers[id]
            lock.unlock()
            // Forward to Flutter only if handler exists (foreground only)
            if let h = h {
                DispatchQueue.main.async { h(frac, dl, total) }
            }
        }

        // Detect completions
        for id in active.subtracting(seen) {
            verifyCompleted(id: id)
        }
    }

    private func verifyCompleted(id: String) {
        lock.lock()
        let port = goPort
        lock.unlock()
        guard port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks/\(id)")
        else { return }

        var req = URLRequest(url: url)
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }

        let sem = DispatchSemaphore(value: 0)
        httpSession.dataTask(with: req) { [weak self] data, _, _ in
            defer { sem.signal() }
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let task = json["data"] as? [String: Any],
                  let rawStatus = task["status"]
            else { return }

            let statusInt: Int
            if let s = rawStatus as? Int { statusInt = s }
            else if let s = rawStatus as? String, let i = Int(s) { statusInt = i }
            else { return }

            // 4=error 5=done
            if statusInt == 5 || statusInt == 4 {
                self.finishDownload(id: id, failed: statusInt == 4)
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
    }

    // MARK: - Public API

    func registerDownload(id: String, filename: String,
                          onProgress: @escaping (Double, Int64, Int64) -> Void,
                          onComplete: @escaping (Error?) -> Void) {
        lock.lock()
        activeIds.insert(id)
        filenameMap[id] = filename
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()

        DispatchQueue.main.async {
            self.beginBgTask()
            self.startSilentAudio()
            self.startPolling()
            LiveActivityBridge.shared.start(id: id, filename: filename)
        }
    }

    func updateProgress(id: String, progress: Double, downloaded: Int64, total: Int64) {
        LiveActivityBridge.shared.update(id: id, progress: progress,
                                         downloaded: downloaded, total: total)
    }

    func completeDownload(id: String, errorMessage: String?) {
        finishDownload(id: id, failed: errorMessage != nil)
    }

    func cancelDownload(id: String) {
        finishDownload(id: id, failed: false)
    }

    func reattach(id: String, onProgress: @escaping (Double, Int64, Int64) -> Void,
                  onComplete: @escaping (Error?) -> Void) {
        lock.lock()
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()
    }

    private func finishDownload(id: String, failed: Bool) {
        lock.lock()
        let handler = completionHandlers[id]
        activeIds.remove(id)
        filenameMap.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        let remaining = activeIds.count
        lock.unlock()

        let err: Error? = failed ? NSError(domain: "com.gopeed", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"]) : nil
        if let handler = handler {
            DispatchQueue.main.async { handler(err) }
        }
        LiveActivityBridge.shared.end(id: id, success: !failed)

        if remaining == 0 {
            stopPolling()
            stopSilentAudio()
            endBgTask()
            print("[BgDL] All downloads done")
        }
    }

    // MARK: - App lifecycle

    func applicationDidEnterBackground() {
        lock.lock()
        let hasActive = !activeIds.isEmpty
        lock.unlock()
        guard hasActive else { return }

        // Always refresh everything on background transition
        beginBgTask()       // fresh BGTask token
        startSilentAudio()  // always recreate player (in case of previous interruption)
        startPolling()      // no-op if already polling
        print("[BgDL] Did enter background — \(activeIds.count) active downloads")
    }

    func applicationWillEnterForeground() {
        // Don't stop anything — downloads still running
        // Just end the BGTask since foreground doesn't need it
        endBgTask()
        print("[BgDL] Will enter foreground")
    }
}
