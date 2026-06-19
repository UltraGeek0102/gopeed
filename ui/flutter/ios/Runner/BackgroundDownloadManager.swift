import Foundation
import UIKit
import AVFoundation

/// Keeps the Go download engine alive while the app is backgrounded.
///
/// iOS suspends apps ~30s after backgrounding. We work around this using:
/// 1. AVAudioSession with a silent looping audio player — keeps the process running
///    indefinitely (same technique used by Infuse, nPlayer, many download managers)
/// 2. UIApplication.beginBackgroundTask as a fallback for the first 30s
///
/// NSURLSession background sessions are NOT used here because the Go HTTP fetcher
/// keeps the resolve response body open and reuses it for downloading — a separate
/// NSURLSession request would open a new connection and break one-time URLs.
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    // MARK: - State

    private var activeDownloadIds: Set<String> = []
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    private let lock = NSLock()

    // Progress/completion callbacks forwarded to Flutter
    var progressHandlers: [String: (Double, Int64, Int64) -> Void] = [:]
    var completionHandlers: [String: (Error?) -> Void] = [:]

    private override init() {
        super.init()
        setupAudioSession()
    }

    // MARK: - Audio session (the real background keep-alive)

    private func setupAudioSession() {
        do {
            // .playback category keeps the app alive even with screen locked
            // .mixWithOthers so we don't interrupt user's music
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[BgDL] AVAudioSession setup failed: \(error)")
        }
    }

    /// Start playing a silent audio loop to hold the background process alive.
    private func startSilentAudio() {
        guard audioPlayer == nil || audioPlayer?.isPlaying == false else { return }

        // Generate a tiny (0.1s) silent PCM WAV in memory — no file needed
        let sampleRate: Double = 44100
        let duration: Double = 0.1
        let numSamples = Int(sampleRate * duration)
        let dataSize = numSamples * 2  // 16-bit mono
        let headerSize = 44
        var wav = Data(count: headerSize + dataSize)

        wav.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            // RIFF header
            let header: [UInt8] = [
                0x52,0x49,0x46,0x46,                              // "RIFF"
                UInt8((dataSize+36) & 0xFF), UInt8((dataSize+36)>>8 & 0xFF),
                UInt8((dataSize+36)>>16 & 0xFF), UInt8((dataSize+36)>>24 & 0xFF),
                0x57,0x41,0x56,0x45,                              // "WAVE"
                0x66,0x6D,0x74,0x20,                              // "fmt "
                0x10,0x00,0x00,0x00,                              // chunk size = 16
                0x01,0x00,                                         // PCM
                0x01,0x00,                                         // mono
                0x44,0xAC,0x00,0x00,                              // 44100 Hz
                0x88,0x58,0x01,0x00,                              // byte rate
                0x02,0x00,                                         // block align
                0x10,0x00,                                         // 16-bit
                0x64,0x61,0x74,0x61,                              // "data"
                UInt8(dataSize & 0xFF), UInt8(dataSize>>8 & 0xFF),
                UInt8(dataSize>>16 & 0xFF), UInt8(dataSize>>24 & 0xFF),
            ]
            header.enumerated().forEach { base.storeBytes(of: $0.element, toByteOffset: $0.offset, as: UInt8.self) }
            // data bytes are already zero (silence)
        }

        do {
            audioPlayer = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            audioPlayer?.numberOfLoops = -1  // loop forever
            audioPlayer?.volume = 0.0        // truly silent
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            print("[BgDL] Silent audio started — app will stay alive in background")
        } catch {
            print("[BgDL] AVAudioPlayer init failed: \(error)")
        }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        print("[BgDL] Silent audio stopped")
    }

    // MARK: - Background task token (fallback, ~30s)

    private func beginBgTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "gopeed.download") {
            // Expiration handler — iOS is about to suspend us
            // The silent audio should have already kicked in, but just in case:
            print("[BgDL] Background task expired — relying on audio session")
            UIApplication.shared.endBackgroundTask(self.bgTaskId)
            self.bgTaskId = .invalid
        }
    }

    private func endBgTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    // MARK: - Public API (called by AppDelegate / Flutter channel)

    func registerDownload(
        id: String,
        filename: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        lock.lock()
        activeDownloadIds.insert(id)
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()

        // Start keep-alive mechanisms
        DispatchQueue.main.async {
            self.beginBgTask()
            self.startSilentAudio()
            LiveActivityBridge.shared.start(id: id, filename: filename)
        }
    }

    func updateProgress(id: String, progress: Double, downloaded: Int64, total: Int64) {
        lock.lock()
        let handler = progressHandlers[id]
        lock.unlock()
        DispatchQueue.main.async {
            handler?(progress, downloaded, total)
            LiveActivityBridge.shared.update(id: id, progress: progress,
                                             downloaded: downloaded, total: total)
        }
    }

    func completeDownload(id: String, errorMessage: String?) {
        lock.lock()
        let handler = completionHandlers[id]
        activeDownloadIds.remove(id)
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        let remaining = activeDownloadIds.count
        lock.unlock()

        let error: Error? = errorMessage.map {
            NSError(domain: "com.gopeed", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: $0])
        }

        DispatchQueue.main.async {
            handler?(error)
            LiveActivityBridge.shared.end(id: id, success: error == nil)

            // Only stop keep-alive when ALL downloads are done
            if remaining == 0 {
                self.stopSilentAudio()
                self.endBgTask()
                print("[BgDL] All downloads complete — released background resources")
            }
        }
    }

    func cancelDownload(id: String) {
        completeDownload(id: id, errorMessage: "cancelled")
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

    // MARK: - App lifecycle hooks (called from AppDelegate)

    func applicationDidEnterBackground() {
        lock.lock()
        let hasActive = !activeDownloadIds.isEmpty
        lock.unlock()
        if hasActive {
            beginBgTask()
            startSilentAudio()
            print("[BgDL] App backgrounded with \(activeDownloadIds.count) active downloads")
        }
    }

    func applicationWillEnterForeground() {
        // Keep audio running until downloads finish — don't stop here
        endBgTask()
        print("[BgDL] App foregrounded")
    }
}
