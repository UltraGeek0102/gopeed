import Foundation
import UIKit

/// Manages iOS NSURLSession background downloads independently of the Flutter/Go engine.
/// Downloads survive app backgrounding, screen lock, and even app suspension.
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    private let sessionIdentifier = "com.gopeed.gopeed.bgdownload"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false          // start immediately, not deferred
        config.sessionSendsLaunchEvents = true  // wake app when done
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // taskIdentifier → gopeed download id
    private var taskIdMap: [Int: String] = [:]
    // gopeed download id → progress callback (only active while app is running)
    private var progressHandlers: [String: (Double, Int64, Int64) -> Void] = [:]
    // gopeed download id → completion callback
    private var completionHandlers: [String: (Error?) -> Void] = [:]
    // Set by AppDelegate when OS wakes the app for a background session event
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()

    private override init() {
        super.init()
        // Rehydrate taskIdMap from UserDefaults so it survives app restarts
        if let saved = UserDefaults.standard.dictionary(forKey: "bgdl_taskmap") as? [String: Int] {
            for (downloadId, taskId) in saved {
                taskIdMap[taskId] = downloadId
            }
        }
    }

    // MARK: - Public API

    func startDownload(
        id: String,
        url: String,
        headers: [String: String],
        destPath: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        guard let downloadURL = URL(string: url) else {
            onComplete(NSError(domain: "com.gopeed", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(url)"]))
            return
        }

        // Persist destination so the delegate can find it after a relaunch
        UserDefaults.standard.set(destPath, forKey: "bgdl_dest_\(id)")

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 0  // no timeout for background sessions
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        lock.lock()
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()

        let task = session.downloadTask(with: request)
        lock.lock()
        taskIdMap[task.taskIdentifier] = id
        persistTaskMap()
        lock.unlock()

        task.resume()
    }

    func pauseDownload(id: String) {
        findTask(for: id) { task in
            task?.cancel(byProducingResumeData: { [weak self] resumeData in
                if let data = resumeData {
                    UserDefaults.standard.set(data, forKey: "bgdl_resume_\(id)")
                }
                self?.lock.lock()
                if let taskId = task?.taskIdentifier {
                    self?.taskIdMap.removeValue(forKey: taskId)
                    self?.persistTaskMap()
                }
                self?.lock.unlock()
            })
        }
    }

    func resumeDownload(
        id: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        lock.lock()
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()

        if let resumeData = UserDefaults.standard.data(forKey: "bgdl_resume_\(id)") {
            let task = session.downloadTask(withResumeData: resumeData)
            lock.lock()
            taskIdMap[task.taskIdentifier] = id
            persistTaskMap()
            lock.unlock()
            UserDefaults.standard.removeObject(forKey: "bgdl_resume_\(id)")
            task.resume()
        } else {
            // No resume data → restart from scratch using stored URL (not ideal but safe)
            onComplete(NSError(domain: "com.gopeed", code: -2,
                               userInfo: [NSLocalizedDescriptionKey: "No resume data for \(id)"]))
        }
    }

    func cancelDownload(id: String) {
        findTask(for: id) { [weak self] task in
            task?.cancel()
            self?.lock.lock()
            if let taskId = task?.taskIdentifier {
                self?.taskIdMap.removeValue(forKey: taskId)
                self?.persistTaskMap()
            }
            self?.progressHandlers.removeValue(forKey: id)
            self?.completionHandlers.removeValue(forKey: id)
            self?.lock.unlock()
            UserDefaults.standard.removeObject(forKey: "bgdl_dest_\(id)")
            UserDefaults.standard.removeObject(forKey: "bgdl_resume_\(id)")
        }
    }

    /// Re-attach callbacks to an existing in-flight task (e.g. after app foregrounded)
    func reattach(
        id: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        lock.lock()
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()
    }

    // MARK: - Private helpers

    private func findTask(for id: String, completion: @escaping (URLSessionDownloadTask?) -> Void) {
        lock.lock()
        let taskId = taskIdMap.first(where: { $0.value == id })?.key
        lock.unlock()

        session.getTasksWithCompletionHandler { _, _, downloadTasks in
            let found = downloadTasks.first(where: { $0.taskIdentifier == taskId })
            completion(found)
        }
    }

    private func persistTaskMap() {
        // Invert for storage: downloadId → taskId
        let inverted = Dictionary(uniqueKeysWithValues: taskIdMap.map { ($1, $0) })
        UserDefaults.standard.set(inverted, forKey: "bgdl_taskmap")
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let id = taskIdMap[downloadTask.taskIdentifier]
        let handler = id.flatMap { progressHandlers[$0] }
        lock.unlock()

        guard let downloadId = id else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0

        DispatchQueue.main.async {
            handler?(progress, totalBytesWritten, totalBytesExpectedToWrite)
            LiveActivityBridge.shared.update(
                id: downloadId,
                progress: progress,
                downloaded: totalBytesWritten,
                total: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let id = taskIdMap[downloadTask.taskIdentifier]
        lock.unlock()

        guard let downloadId = id else { return }

        // Move the temp file to the final destination
        if let destPath = UserDefaults.standard.string(forKey: "bgdl_dest_\(downloadId)") {
            let destURL = URL(fileURLWithPath: destPath)
            do {
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: location, to: destURL)
            } catch {
                // Move failed: leave it in the temp location and report error
                DispatchQueue.main.async {
                    self.fireComplete(id: downloadId, error: error)
                }
                return
            }
        }

        DispatchQueue.main.async {
            self.fireComplete(id: downloadId, error: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Only handle actual errors here; success is handled in didFinishDownloadingTo
        guard let error = error else { return }

        // Cancelled tasks (pause) are NSURLErrorCancelled – ignore them
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }

        lock.lock()
        let id = taskIdMap[task.taskIdentifier]
        lock.unlock()

        guard let downloadId = id else { return }

        DispatchQueue.main.async {
            self.fireComplete(id: downloadId, error: error)
        }
    }

    // Called by iOS when ALL background tasks for this session have finished
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: - Internal helper

    private func fireComplete(id: String, error: Error?) {
        lock.lock()
        let handler = completionHandlers[id]
        // Clean up maps
        taskIdMap = taskIdMap.filter { $0.value != id }
        persistTaskMap()
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        lock.unlock()

        UserDefaults.standard.removeObject(forKey: "bgdl_dest_\(id)")

        LiveActivityBridge.shared.end(id: id, success: error == nil)
        handler?(error)
    }
}
