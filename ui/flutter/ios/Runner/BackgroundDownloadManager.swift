import Foundation
import UIKit

/// Manages iOS NSURLSession background downloads independently of the Flutter/Go engine.
/// Downloads survive app backgrounding, screen lock, and even app suspension.
class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    private let sessionIdentifier = "com.gopeed.gopeed.bgdownload"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // taskIdentifier → gopeed download id
    private var taskIdMap: [Int: String] = [:]
    // gopeed download id → display filename (for Live Activity)
    private var filenameMap: [String: String] = [:]
    // gopeed download id → progress callback (only active while app is foreground)
    private var progressHandlers: [String: (Double, Int64, Int64) -> Void] = [:]
    // gopeed download id → completion callback
    private var completionHandlers: [String: (Error?) -> Void] = [:]
    // Set by AppDelegate when OS wakes the app for a background session event
    var backgroundCompletionHandler: (() -> Void)?
    // Track whether Live Activity has been started for each id
    private var liveActivityStarted: Set<String> = []

    private let lock = NSLock()

    private override init() {
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: "bgdl_taskmap") as? [String: Int] {
            for (downloadId, taskId) in saved {
                taskIdMap[taskId] = downloadId
            }
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "bgdl_filenames") as? [String: String] {
            filenameMap = saved
        }
    }

    // MARK: - Public API

    func startDownload(
        id: String,
        url: String,
        filename: String,
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

        UserDefaults.standard.set(destPath, forKey: "bgdl_dest_\(id)")

        lock.lock()
        filenameMap[id] = filename
        persistFilenameMap()
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        lock.unlock()

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 0
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let task = session.downloadTask(with: request)
        lock.lock()
        taskIdMap[task.taskIdentifier] = id
        persistTaskMap()
        lock.unlock()

        task.resume()
    }

    func pauseDownload(id: String) {
        findTask(for: id) { [weak self] task in
            task?.cancel(byProducingResumeData: { resumeData in
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
            self?.filenameMap.removeValue(forKey: id)
            self?.persistFilenameMap()
            self?.liveActivityStarted.remove(id)
            self?.lock.unlock()
            UserDefaults.standard.removeObject(forKey: "bgdl_dest_\(id)")
            UserDefaults.standard.removeObject(forKey: "bgdl_resume_\(id)")
        }
    }

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
            completion(downloadTasks.first(where: { $0.taskIdentifier == taskId }))
        }
    }

    private func persistTaskMap() {
        let inverted = Dictionary(uniqueKeysWithValues: taskIdMap.map { ($1, $0) })
        UserDefaults.standard.set(inverted, forKey: "bgdl_taskmap")
    }

    private func persistFilenameMap() {
        UserDefaults.standard.set(filenameMap, forKey: "bgdl_filenames")
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
        let filename = id.flatMap { filenameMap[$0] } ?? "Downloading..."
        let needsStart = id.map { !liveActivityStarted.contains($0) } ?? false
        if let downloadId = id, needsStart {
            liveActivityStarted.insert(downloadId)
        }
        lock.unlock()

        guard let downloadId = id else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0

        DispatchQueue.main.async {
            // Start Live Activity on first data received — this is when we know
            // the download is actually running, not just queued
            if needsStart {
                LiveActivityBridge.shared.start(id: downloadId, filename: filename)
            }
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

        if let destPath = UserDefaults.standard.string(forKey: "bgdl_dest_\(downloadId)") {
            let destURL = URL(fileURLWithPath: destPath)
            do {
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: location, to: destURL)
            } catch {
                DispatchQueue.main.async { self.fireComplete(id: downloadId, error: error) }
                return
            }
        }

        DispatchQueue.main.async { self.fireComplete(id: downloadId, error: nil) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }

        lock.lock()
        let id = taskIdMap[task.taskIdentifier]
        lock.unlock()

        guard let downloadId = id else { return }
        DispatchQueue.main.async { self.fireComplete(id: downloadId, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private func fireComplete(id: String, error: Error?) {
        lock.lock()
        let handler = completionHandlers[id]
        taskIdMap = taskIdMap.filter { $0.value != id }
        persistTaskMap()
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        filenameMap.removeValue(forKey: id)
        persistFilenameMap()
        liveActivityStarted.remove(id)
        lock.unlock()

        UserDefaults.standard.removeObject(forKey: "bgdl_dest_\(id)")
        LiveActivityBridge.shared.end(id: id, success: error == nil)
        handler?(error)
    }
}
