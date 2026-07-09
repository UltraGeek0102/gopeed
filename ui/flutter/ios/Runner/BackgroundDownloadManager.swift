import Foundation
import UIKit
import AVFoundation
import CoreLocation
import CoreMotion

class BackgroundDownloadManager: NSObject, CLLocationManagerDelegate {

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

    // Background URLSession — managed by iOS nsurlsessiond, NOT suspended with app
    private lazy var pollSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.pollSessionId)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 5
        // IMPORTANT: nil delegateQueue means iOS uses its own internal serial queue
        // We must NOT block this queue (no semaphores in delegate callbacks)
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // Completion handler provided by iOS via handleEventsForBackgroundURLSession.
    // MUST be called promptly (within ~5s) after all session events are processed.
    // Calling it tells iOS "we're done, you can suspend us again".
    // iOS will NOT send the next wake event until this is called.
    var systemCompletionHandler: (() -> Void)?

    // Accumulate data across didReceive calls (background URLSession can split data)
    private var taskData: [Int: Data] = [:]

    // MARK: - Audio keep-alive

    private var audioPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Location keep-alive (secondary signal alongside audio)
    // CLLocationManager.startMonitoringSignificantLocationChanges() is a
    // long-standing, OS-trusted background mode (used by navigation/fitness apps).
    // Running it alongside the audio session gives the process a second reason
    // for iOS to keep it schedulable, which in practice seems to help the
    // cooperative pool stay available for brief windows more often.
    // This does NOT make updates continuous — it's a best-effort assist.
    private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.allowsBackgroundLocationUpdates = true
        m.pausesLocationUpdatesAutomatically = false
        return m
    }()
    private var locationKeepAliveActive = false

    // MARK: - Discrete background poll schedule
    // Instead of trying to poll every 1s continuously in background (unreliable —
    // relies on the cooperative pool draining a queued Task every single time),
    // we schedule a small number of DISCRETE update points using a
    // DispatchSourceTimer targeting a specific future date. This mirrors the
    // pattern that's known to work for one-shot/few-shot background LA updates:
    // ask the OS for very little (a handful of wake events), not a continuous stream.
    private var backgroundScheduleTimer: DispatchSourceTimer?
    private let backgroundUpdateInterval: TimeInterval = 20 // seconds between discrete background updates

    private func startLocationKeepAlive() {
        guard !locationKeepAliveActive else { return }
        let status = CLLocationManager.authorizationStatus()
        guard status == .authorizedAlways else {
            print("[BgDL] location keep-alive skipped — needs Always authorization (have: \(status.rawValue))")
            return
        }
        locationManager.startMonitoringSignificantLocationChanges()
        locationKeepAliveActive = true
        print("[BgDL] location keep-alive started")
    }

    private func stopLocationKeepAlive() {
        guard locationKeepAliveActive else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        locationKeepAliveActive = false
        print("[BgDL] location keep-alive stopped")
    }

    func requestLocationAuthorizationIfNeeded() {
        let status = CLLocationManager.authorizationStatus()
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        }
    }

    // CLLocationManagerDelegate — significant location changes wake us briefly;
    // use that window to trigger an immediate poll, same as our scheduled timer does.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has {
            print("[BgDL] location update woke us — triggering poll")
            schedulePollTask()
        }
    }

    // MARK: - Motion activity keep-alive (3rd signal alongside audio + location)
    // CMMotionActivityManager's background activity updates use the device's
    // accelerometer/gyro to detect state changes (still → walking → driving, etc.)
    // This is a DIFFERENT detection mechanism than location (radio-based), so it
    // can catch wake opportunities location misses, and vice versa. Like location,
    // it only fires on a detected state CHANGE, not on a timer — if the phone is
    // completely still on a desk, this alone won't fire either. Running both
    // together maximizes the chance of getting occasional background windows.
    private let motionManager = CMMotionActivityManager()
    private var motionKeepAliveActive = false

    private func startMotionKeepAlive() {
        guard !motionKeepAliveActive else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("[BgDL] motion keep-alive unavailable on this device")
            return
        }
        motionManager.startActivityUpdates(to: .main) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); let has = !self.activeIds.isEmpty; self.lock.unlock()
            if has {
                print("[BgDL] motion activity change woke us — triggering poll")
                self.schedulePollTask()
            }
        }
        motionKeepAliveActive = true
        print("[BgDL] motion keep-alive started")
    }

    private func stopMotionKeepAlive() {
        guard motionKeepAliveActive else { return }
        motionManager.stopActivityUpdates()
        motionKeepAliveActive = false
        print("[BgDL] motion keep-alive stopped")
    }

    // MARK: - Discrete background scheduling

    private func startBackgroundSchedule() {
        stopBackgroundSchedule()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + backgroundUpdateInterval,
                       repeating: backgroundUpdateInterval,
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let has = !self.activeIds.isEmpty; self.lock.unlock()
            guard has else { self.stopBackgroundSchedule(); return }
            print("[BgDL] scheduled background update firing")
            self.schedulePollTask()
        }
        timer.resume()
        backgroundScheduleTimer = timer
        print("[BgDL] background schedule started — every \(backgroundUpdateInterval)s")
    }

    private func stopBackgroundSchedule() {
        backgroundScheduleTimer?.cancel()
        backgroundScheduleTimer = nil
    }

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

    func schedulePollTask() {
        lock.lock()
        let has  = !activeIds.isEmpty
        let port = goPort
        lock.unlock()
        guard has, port > 0 else {
            print("[BgDL] no active downloads or port not set, skip poll")
            return
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/tasks?status=running") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { req.setValue(apiToken, forHTTPHeaderField: "X-Api-Token") }
        req.timeoutInterval = 4

        let task = pollSession.dataTask(with: req)
        taskData[task.taskIdentifier] = Data()
        task.resume()
        print("[BgDL] poll task \(task.taskIdentifier) scheduled")
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
            self.requestLocationAuthorizationIfNeeded()
            LiveActivityBridge.shared.start(id: id, filename: filename)
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
        if left == 0 { stopAudio(); endBgTask(); print("[BgDL] all done") }
    }

    func applicationDidEnterBackground() {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        guard has else { return }
        beginBgTask(); startAudio(); startLocationKeepAlive(); startMotionKeepAlive()
        // Switch from continuous 1s polling to discrete scheduled updates —
        // asking the OS for a handful of wake events is more reliable than
        // trying to sustain a continuous stream while backgrounded.
        startBackgroundSchedule()
        print("[BgDL] backgrounded — audio + location + motion keep-alive, discrete schedule active")
    }

    func applicationWillEnterForeground() {
        endBgTask()
        stopLocationKeepAlive()
        stopMotionKeepAlive()
        stopBackgroundSchedule()
        // Immediately fetch fresh progress from the Go engine and push it to the
        // Live Activity + Flutter UI so there's no stale-state lag on foreground.
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has {
            schedulePollTask()
            print("[BgDL] foregrounded — triggered immediate poll for fresh state")
        }
    }
}

// MARK: - URLSessionDataDelegate

extension BackgroundDownloadManager: URLSessionDataDelegate {

    // Accumulate data (background URLSession may deliver in chunks)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        taskData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    // Task complete — process accumulated data, schedule next poll, signal iOS
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {

        defer {
            taskData.removeValue(forKey: task.taskIdentifier)
        }

        if let e = error {
            print("[BgDL] poll error: \(e)")
        } else if let data = taskData[task.taskIdentifier], !data.isEmpty {
            print("[BgDL] poll complete: \(data.count) bytes")
            processData(data)
        }

        // Reschedule immediately ONLY when foregrounded (fast, continuous updates).
        // When backgrounded, the discrete background schedule timer and location
        // keep-alive drive the next poll instead — chaining every poll at 1s in
        // background just queues up cooperative-pool work that may not drain.
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has && UIApplication.shared.applicationState != .background {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                self.schedulePollTask()
            }
        }

        // Signal iOS that we've finished handling this background event.
        // This MUST be called promptly — iOS won't wake us again until it is.
        // Do it here (not in urlSessionDidFinishEvents) so it fires per-task.
        callSystemCompletionHandler()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("[BgDL] urlSessionDidFinishEvents")
        // Belt-and-suspenders: also call from here in case didCompleteWithError missed it
        callSystemCompletionHandler()
    }

    private func callSystemCompletionHandler() {
        DispatchQueue.main.async {
            guard let h = self.systemCompletionHandler else { return }
            self.systemCompletionHandler = nil
            h()
            print("[BgDL] systemCompletionHandler called")
        }
    }

    private func processData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else {
            print("[BgDL] JSON parse failed: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            return
        }

        lock.lock(); let active = activeIds; lock.unlock()

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

            print("[BgDL] \(id) \(String(format:"%.1f",frac*100))% (\(dl)/\(total))")

            // Fire-and-forget — returns immediately, does NOT block delegate queue
            LiveActivityBridge.shared.update(id: id, progress: frac, downloaded: dl, total: total)

            lock.lock(); let h = progressHandlers[id]; lock.unlock()
            if let h = h { DispatchQueue.main.async { h(frac, dl, total) } }
        }
    }
}
