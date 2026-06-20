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

    private var activeIds:         Set<String> = []
    private var filenameMap:       [String: String] = [:]
    private let lock =             NSLock()
    private var progressHandlers:  [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers:[String: (Error?) -> Void] = [:]

    // MARK: - Keep-alive resources

    private var bgTaskId:       UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer:    AVAudioPlayer?
    // Poll loop: dedicated background thread using POSIX sockets (can't be suspended)
    private let pollQueue =     DispatchQueue(label: "com.gopeed.bgpoll", qos: .userInitiated)
    private var isPolling =     false
    private var pollShouldStop = false
    // Heartbeat: DispatchSourceTimer on main queue forces the main RunLoop to spin,
    // which drains @MainActor tasks (ActivityKit updates) even when backgrounded.
    private var heartbeat: DispatchSourceTimer?

    private override init() {
        super.init()
        setupAudioSession()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: - AVAudioSession

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("[BgDL] AVAudioSession error: \(error)") }
    }

    private func startSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("[BgDL] setActive error: \(error)") }

        // 30-second silent WAV — longer loop = fewer potential gap issues
        let sr = 44100, seconds = 30, ds = sr * seconds * 2
        var wav = Data(count: 44 + ds)
        wav.withUnsafeMutableBytes { ptr in
            guard let b = ptr.baseAddress else { return }
            let h: [UInt8] = [
                0x52,0x49,0x46,0x46,
                UInt8((ds+36)&0xFF),   UInt8((ds+36)>>8&0xFF),
                UInt8((ds+36)>>16&0xFF),UInt8((ds+36)>>24&0xFF),
                0x57,0x41,0x56,0x45,  0x66,0x6D,0x74,0x20,
                0x10,0x00,0x00,0x00,  0x01,0x00, 0x01,0x00,
                0x44,0xAC,0x00,0x00,  0x88,0x58,0x01,0x00,
                0x02,0x00, 0x10,0x00, 0x64,0x61,0x74,0x61,
                UInt8(ds&0xFF),        UInt8(ds>>8&0xFF),
                UInt8(ds>>16&0xFF),    UInt8(ds>>24&0xFF)
            ]
            h.enumerated().forEach {
                b.storeBytes(of: $0.element, toByteOffset: $0.offset, as: UInt8.self)
            }
        }
        do {
            audioPlayer = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            let ok = audioPlayer?.play() ?? false
            print("[BgDL] Audio started: \(ok)")
        } catch { print("[BgDL] AVAudioPlayer error: \(error)") }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    @objc private func audioInterrupted(_ n: Notification) {
        guard
            let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let t = AVAudioSession.InterruptionType(rawValue: v),
            t == .ended
        else { return }
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        if has { startSilentAudio() }
    }

    // MARK: - Heartbeat timer on main queue
    // Forces the main RunLoop to spin every second.
    // This drains @MainActor tasks — which is where ActivityKit update() runs.
    // Without this, the RunLoop might sleep between audio callbacks.

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: [], queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler {
            // Just waking the main RunLoop is enough — no work needed here.
            // The act of firing this handler spins the RunLoop which drains
            // any pending @MainActor tasks including ActivityKit updates.
        }
        timer.resume()
        heartbeat = timer
        print("[BgDL] Heartbeat started")
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        print("[BgDL] Heartbeat stopped")
    }

    // MARK: - Background task token

    private func beginBgTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed.dl") { [weak self] in
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

    // MARK: - Poll loop using raw POSIX sockets
    // URLSession gets suspended when backgrounded. POSIX sockets to 127.0.0.1
    // use loopback — kernel memory copy, cannot be suspended by iOS.

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollShouldStop = false
        pollQueue.async { [weak self] in self?.pollLoop() }
        print("[BgDL] Poll loop started")
    }

    private func stopPolling() {
        pollShouldStop = true
        isPolling = false
    }

    private func pollLoop() {
        while !pollShouldStop {
            lock.lock()
            let has  = !activeIds.isEmpty
            let port = goPort
            lock.unlock()

            if has && port > 0 {
                if let data = rawHttpGet(path: "/api/v1/tasks?status=running", port: port) {
                    processPollData(data)
                }
            }

            var tv = timeval(tv_sec: 1, tv_usec: 0)
            select(0, nil, nil, nil, &tv)
        }
        isPolling = false
        print("[BgDL] Poll loop exited")
    }

    private func rawHttpGet(path: String, port: Int) -> Data? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            print("[BgDL] connect failed: \(errno)")
            return nil
        }

        var req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept: application/json\r\nConnection: close\r\n"
        if !apiToken.isEmpty { req += "X-Api-Token: \(apiToken)\r\n" }
        req += "\r\n"

        let bytes = Array(req.utf8)
        guard bytes.withUnsafeBytes({ send(sock, $0.baseAddress, bytes.count, 0) }) > 0
        else { return nil }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
        }

        guard let bodyRange = response.range(of: Data([0x0D,0x0A,0x0D,0x0A]))
        else { return nil }
        let body = Data(response[bodyRange.upperBound...])

        if response.range(of: Data("Transfer-Encoding: chunked".utf8)) != nil {
            return dechunk(body)
        }
        return body
    }

    private func dechunk(_ data: Data) -> Data {
        var result = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let nl = data[i...].range(of: Data([0x0D,0x0A])) else { break }
            let hex = String(data: data[i..<nl.lowerBound], encoding: .utf8) ?? "0"
            let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
            if size == 0 { break }
            i = nl.upperBound
            guard data.index(i, offsetBy: size, limitedBy: data.endIndex) != nil else { break }
            result.append(data[i..<data.index(i, offsetBy: size)])
            i = data.index(i, offsetBy: size + 2)
        }
        return result
    }

    private func processPollData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else {
            print("[BgDL] parse fail: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
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

            print("[BgDL] poll \(id) \(String(format:"%.1f",frac*100))% \(dl)/\(total)")
            LiveActivityBridge.shared.update(id: id, progress: frac, downloaded: dl, total: total)

            lock.lock(); let h = progressHandlers[id]; lock.unlock()
            if let h = h { DispatchQueue.main.async { h(frac, dl, total) } }
        }

        for id in active.subtracting(seen) { verifyAndFinish(id: id) }
    }

    private func verifyAndFinish(id: String) {
        lock.lock(); let port = goPort; lock.unlock()
        guard port > 0,
              let data = rawHttpGet(path: "/api/v1/tasks/\(id)", port: port),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = json["data"] as? [String: Any]
        else { return }

        let s: Int
        if      let n = task["status"] as? Int    { s = n }
        else if let str = task["status"] as? String, let n = Int(str) { s = n }
        else    { return }

        if s == 5      { finishDownload(id: id, failed: false) }
        else if s == 4 { finishDownload(id: id, failed: true)  }
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
            self.startHeartbeat()
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

    func cancelDownload(id: String) { finishDownload(id: id, failed: false) }

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

        if let h = handler {
            let err: Error? = failed ? NSError(domain: "com.gopeed", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Download failed"]) : nil
            DispatchQueue.main.async { h(err) }
        }
        LiveActivityBridge.shared.end(id: id, success: !failed)
        if remaining == 0 {
            stopPolling()
            stopHeartbeat()
            stopSilentAudio()
            endBgTask()
            print("[BgDL] All done")
        }
    }

    // MARK: - App lifecycle

    func applicationDidEnterBackground() {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        guard has else { return }
        beginBgTask()
        startSilentAudio()
        startPolling()
        startHeartbeat()
        print("[BgDL] Backgrounded — \(activeIds.count) active")
    }

    func applicationWillEnterForeground() {
        endBgTask()
        print("[BgDL] Foregrounded")
    }
}
