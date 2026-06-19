import Foundation
import UIKit
import AVFoundation

/// Keeps the Go engine alive in the background (via AVAudioSession) and
/// updates Live Activities in real-time by polling the Go engine's TCP REST
/// API from a native Swift Timer — completely independent of Flutter.
///
/// When iOS backgrounds the app the Flutter engine suspends (Dart timers stop),
/// but this native Timer keeps firing as long as AVAudioSession holds the
/// process alive, giving continuous Live Activity updates.
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    // MARK: - Configuration (set by Flutter before first download)

    private(set) var goPort: Int = 0
    private(set) var apiToken: String = ""

    func configure(port: Int, apiToken: String) {
        self.goPort = port
        self.apiToken = apiToken
        print("[BgDL] Configured — port: \(port)")
    }

    // MARK: - State

    private var activeIds: Set<String> = []
    private var filenameMap: [String: String] = [:]
    private let lock = NSLock()

    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var pollingTimer: Timer?

    // Flutter callbacks (only meaningful when app is foregrounded)
    private var progressHandlers: [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: (Error?) -> Void] = [:]

    // URLSession for polling the Go engine
    private lazy var httpSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        return URLSession(configuration: cfg)
    }()

    private override init() {
        super.init()
        setupAudioSession()
    }

    // MARK: - Audio session (process keep-alive)

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[BgDL] AVAudioSession error: \(error)")
        }
    }

    private func startSilentAudio() {
        guard audioPlayer?.isPlaying != true else { return }
        let sr = 44100, n = sr / 10, ds = n * 2
        var wav = Data(count: 44 + ds)
        wav.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            let h: [UInt8] = [
                0x52,0x49,0x46,0x46,
                UInt8((ds+36)&0xFF),UInt8((ds+36)>>8&0xFF),
                UInt8((ds+36)>>16&0xFF),UInt8((ds+36)>>24&0xFF),
                0x57,0x41,0x56,0x45,0x66,0x6D,0x74,0x20,
                0x10,0x00,0x00,0x00,0x01,0x00,0x01,0x00,
                0x44,0xAC,0x00,0x00,0x88,0x58,0x01,0x00,
                0x02,0x00,0x10,0x00,0x64,0x61,0x74,0x61,
                UInt8(ds&0xFF),UInt8(ds>>8&0xFF),
                UInt8(ds>>16&0xFF),UInt8(ds>>24&0xFF)
            ]
            h.enumerated().forEach {
                b.storeBytes(of: $0.element, toByteOffset: $0.offset, as: UInt8.self)
            }
        }
        do {
            audioPlayer = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.0
            audioPlayer?.play()
            print("[BgDL] Silent audio playing")
        } catch { print("[BgDL] AVAudioPlayer error: \(error)") }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        print("[BgDL] Silent audio stopped")
    }

    // MARK: - Background task (first ~30s safety net)

    private func beginBgTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed.dl") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
        }
    }

    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Native polling timer
    // Runs every second. Polls Go engine TCP REST API directly from Swift.
    // Fires in background because AVAudioSession keeps the process alive.

    private func startPolling() {
        guard pollingTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollGoEngine()
        }
        RunLoop.main.add(t, forMode: .common)
        pollingTimer = t
        print("[BgDL] Polling timer started")
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        print("[BgDL] Polling timer stopped")
    }

    private func goURL(_ path: String) -> URL? {
        guard goPort > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(goPort)\(path)")
    }

    private func goRequest(_ path: String) -> URLRequest? {
        guard let url = goURL(path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty {
            req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token")
        }
        return req
    }

    private func pollGoEngine() {
        lock.lock()
        let hasActive = !activeIds.isEmpty
        lock.unlock()
        guard hasActive, let req = goRequest("/api/v1/tasks?status=running") else { return }

        httpSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            self.processPollData(data)
        }.resume()
    }

    private func processPollData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else { return }

        lock.lock()
        let active = activeIds
        lock.unlock()

        // Update progress for each running task we're tracking
        let seen = Set(arr.compactMap { $0["id"] as? String })
        for t in arr {
            guard
                let id       = t["id"] as? String, active.contains(id),
                let prog     = t["progress"] as? [String: Any],
                let meta     = t["meta"] as? [String: Any]
            else { continue }

            let dl    = (prog["downloaded"] as? Int64) ?? Int64((prog["downloaded"] as? Int) ?? 0)
            let res   = meta["res"] as? [String: Any]
            let total = (res?["size"] as? Int64) ?? Int64((res?["size"] as? Int) ?? 0)
            let frac  = total > 0 ? Double(dl) / Double(total) : 0.0

            DispatchQueue.main.async {
                LiveActivityBridge.shared.update(id: id, progress: frac,
                                                 downloaded: dl, total: total)
                self.lock.lock()
                let h = self.progressHandlers[id]
                self.lock.unlock()
                h?(frac, dl, total)
            }
        }

        // Check tasks that disappeared from the running list
        let disappeared = active.subtracting(seen)
        for id in disappeared {
            verifyCompleted(id: id)
        }
    }

    /// Re-fetches a single task to distinguish done/error from a transient miss.
    private func verifyCompleted(id: String) {
        guard let req = goRequest("/api/v1/tasks/\(id)") else { return }
        httpSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let task = json["data"] as? [String: Any],
                  let rawStatus = task["status"]
            else { return }

            // Status can be Int or String depending on Go version
            let statusInt: Int
            if let s = rawStatus as? Int { statusInt = s }
            else if let s = rawStatus as? String, let i = Int(s) { statusInt = i }
            else { return }

            // Gopeed status: 0=ready 1=running 2=pause 3=wait 4=error 5=done
            let isDone  = statusInt == 5
            let isError = statusInt == 4
            if isDone || isError {
                DispatchQueue.main.async {
                    self.finishDownload(id: id, failed: isError)
                }
            }
        }.resume()
    }

    // MARK: - Public API (called from AppDelegate / Flutter channel)

    func registerDownload(
        id: String,
        filename: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
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
        // Called by Flutter while foregrounded — just push to Live Activity
        // (The native timer handles this when backgrounded)
        DispatchQueue.main.async {
            LiveActivityBridge.shared.update(id: id, progress: progress,
                                             downloaded: downloaded, total: total)
        }
    }

    func completeDownload(id: String, errorMessage: String?) {
        finishDownload(id: id, failed: errorMessage != nil)
    }

    func cancelDownload(id: String) {
        finishDownload(id: id, failed: false)
        LiveActivityBridge.shared.end(id: id, success: false)
    }

    func reattach(id: String,
                  onProgress: @escaping (Double, Int64, Int64) -> Void,
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

        DispatchQueue.main.async {
            let err: Error? = failed
                ? NSError(domain: "com.gopeed", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Download failed"])
                : nil
            handler?(err)
            LiveActivityBridge.shared.end(id: id, success: !failed)
            if remaining == 0 {
                self.stopPolling()
                self.stopSilentAudio()
                self.endBgTask()
                print("[BgDL] All downloads finished")
            }
        }
    }

    // MARK: - App lifecycle

    func applicationDidEnterBackground() {
        lock.lock()
        let hasActive = !activeIds.isEmpty
        lock.unlock()
        if hasActive {
            beginBgTask()
            startSilentAudio()
            startPolling()
            print("[BgDL] Backgrounded — \(activeIds.count) active")
        }
    }

    func applicationWillEnterForeground() {
        endBgTask()
    }
}
