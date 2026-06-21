import Foundation
import UIKit
import AVFoundation

class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    // MARK: - Go engine connection

    private(set) var goPort: Int = 0
    private(set) var apiToken: String = ""

    func configure(port: Int, apiToken: String) {
        self.goPort  = port
        self.apiToken = apiToken
        print("[BgDL] configured port=\(port)")
    }

    // MARK: - State

    private var activeIds:          Set<String> = []
    private var filenameMap:        [String: String] = [:]
    private let lock =              NSLock()
    private var progressHandlers:   [String: (Double, Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: (Error?) -> Void] = [:]

    // MARK: - Resources

    private var bgTaskId:      UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer:   AVAudioPlayer?
    private let pollQueue =    DispatchQueue(label: "com.gopeed.poll", qos: .userInitiated)
    private var pollRunning =  false
    private var pollStop =     false

    private override init() {
        super.init()
        setupAudio()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: - Audio (keeps process alive)

    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("[BgDL] audio setup: \(error)") }
    }

    private func startAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("[BgDL] setActive: \(error)") }

        // 30-second silent WAV
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
            let ok = audioPlayer?.play() ?? false
            print("[BgDL] audio play: \(ok)")
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

    // MARK: - Background task token

    private func beginBgTask() {
        if bgTaskId != .invalid { UIApplication.shared.endBackgroundTask(bgTaskId); bgTaskId = .invalid }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
            self.beginBgTask() // renew immediately
        }
    }

    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Poll loop (POSIX sockets — cannot be suspended by iOS)

    private func startPolling() {
        guard !pollRunning else { return }
        pollRunning = true
        pollStop    = false
        pollQueue.async { [weak self] in self?.pollLoop() }
        print("[BgDL] poll started")
    }

    private func stopPolling() { pollStop = true; pollRunning = false }

    private func pollLoop() {
        while !pollStop {
            lock.lock(); let has = !activeIds.isEmpty; let port = goPort; lock.unlock()
            if has && port > 0 {
                if let data = rawGet(path: "/api/v1/tasks?status=running", port: port) {
                    handlePollData(data)
                }
            }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            select(0, nil, nil, nil, &tv)
        }
        pollRunning = false
    }

    // Raw POSIX HTTP GET — loopback only, no URLSession suspension risk
    private func rawGet(path: String, port: Int) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { print("[BgDL] connect errno=\(errno)"); return nil }

        var req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept: application/json\r\nConnection: close\r\n"
        if !apiToken.isEmpty { req += "X-Api-Token: \(apiToken)\r\n" }
        req += "\r\n"

        let rb = Array(req.utf8)
        guard rb.withUnsafeBytes({ send(fd, $0.baseAddress, rb.count, 0) }) > 0 else { return nil }

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; resp.append(contentsOf: buf[0..<n]) }

        guard let sep = resp.range(of: Data([0x0D,0x0A,0x0D,0x0A])) else { return nil }
        let body = Data(resp[sep.upperBound...])
        return resp.range(of: Data("Transfer-Encoding: chunked".utf8)) != nil ? dechunk(body) : body
    }

    private func dechunk(_ d: Data) -> Data {
        var out = Data(); var i = d.startIndex
        while i < d.endIndex {
            guard let nl = d[i...].range(of: Data([0x0D,0x0A])) else { break }
            let sz = Int(String(data: d[i..<nl.lowerBound], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? "0", radix: 16) ?? 0
            if sz == 0 { break }
            i = nl.upperBound
            guard i + sz <= d.endIndex else { break }
            out.append(d[i..<d.index(i, offsetBy: sz)]); i = d.index(i, offsetBy: sz + 2)
        }
        return out
    }

    private func handlePollData(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr  = json["data"] as? [[String: Any]]
        else { print("[BgDL] parse error: \(String(data: data.prefix(100), encoding: .utf8) ?? "?")"); return }

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

            print("[BgDL] \(id) \(String(format:"%.1f",frac*100))%")
            LiveActivityBridge.shared.update(id: id, progress: frac, downloaded: dl, total: total)

            lock.lock(); let h = progressHandlers[id]; lock.unlock()
            if let h = h { DispatchQueue.main.async { h(frac, dl, total) } }
        }

        for id in active.subtracting(seen) { checkFinished(id: id) }
    }

    private func checkFinished(id: String) {
        lock.lock(); let port = goPort; lock.unlock()
        guard port > 0,
              let data = rawGet(path: "/api/v1/tasks/\(id)", port: port),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = json["data"] as? [String: Any]
        else { return }
        let s: Int
        if let n = task["status"] as? Int { s = n }
        else if let str = task["status"] as? String, let n = Int(str) { s = n }
        else { return }
        if s == 5 { finishDownload(id: id, failed: false) }
        else if s == 4 { finishDownload(id: id, failed: true) }
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
            self.beginBgTask(); self.startAudio(); self.startPolling()
            LiveActivityBridge.shared.start(id: id, filename: filename)
        }
    }

    func updateProgress(id: String, progress: Double, downloaded: Int64, total: Int64) {
        LiveActivityBridge.shared.update(id: id, progress: progress, downloaded: downloaded, total: total)
    }

    func completeDownload(id: String, errorMessage: String?) { finishDownload(id: id, failed: errorMessage != nil) }
    func cancelDownload(id: String)                          { finishDownload(id: id, failed: false) }

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
            let err: Error? = failed ? NSError(domain: "com.gopeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed"]) : nil
            DispatchQueue.main.async { h(err) }
        }
        LiveActivityBridge.shared.end(id: id, success: !failed)
        if left == 0 { stopPolling(); stopAudio(); endBgTask(); print("[BgDL] all done") }
    }

    func applicationDidEnterBackground() {
        lock.lock(); let has = !activeIds.isEmpty; lock.unlock()
        guard has else { return }
        beginBgTask(); startAudio(); startPolling()
        print("[BgDL] backgrounded with \(activeIds.count) active")
    }

    func applicationWillEnterForeground() {
        endBgTask()
        print("[BgDL] foregrounded")
    }
}
