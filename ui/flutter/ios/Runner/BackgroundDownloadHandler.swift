import UIKit
import BackgroundTasks

/// Handles iOS background download tasks
class BackgroundDownloadHandler {
    static let backgroundTaskIdentifier = "com.gopeed.background.download"
    static let backgroundProcessingIdentifier = "com.gopeed.background.processing"
    
    // Reference to the Go download engine
    private static var downloadEnginePointer: UnsafeMutableRawPointer?
    
    /// Register background task handlers
    static func registerBackgroundTasks() {
        // Register background download task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            handleBackgroundDownload(task: task as! BGAppRefreshTask)
        }
        
        // Register background processing task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundProcessingIdentifier,
            using: nil
        ) { task in
            handleBackgroundProcessing(task: task as! BGProcessingTask)
        }
    }
    
    /// Schedule a background download task
    static func scheduleBackgroundDownloadTask() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 1 minute delay
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[Background] Download task scheduled")
        } catch {
            print("[Background] Unable to schedule download task: \(error)")
        }
    }
    
    /// Schedule a background processing task
    static func scheduleBackgroundProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundProcessingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[Background] Processing task scheduled")
        } catch {
            print("[Background] Unable to schedule processing task: \(error)")
        }
    }
    
    /// Handle background download task
    private static func handleBackgroundDownload(task: BGAppRefreshTask) {
        // Schedule next background task
        scheduleBackgroundDownloadTask()
        
        // Set expiration handler
        task.expirationHandler = {
            print("[Background] Download task expired")
            task.setTaskAsComplete(success: false)
        }
        
        // Perform download operations in background
        DispatchQueue.global(qos: .background).async {
            if resumeAllBackgroundDownloads() {
                task.setTaskAsComplete(success: true)
            } else {
                task.setTaskAsComplete(success: false)
            }
        }
    }
    
    /// Handle background processing task
    private static func handleBackgroundProcessing(task: BGProcessingTask) {
        // Schedule next background task
        scheduleBackgroundProcessingTask()
        
        // Set expiration handler
        task.expirationHandler = {
            print("[Background] Processing task expired")
            task.setTaskAsComplete(success: false)
        }
        
        // Perform download operations in background
        DispatchQueue.global(qos: .utility).async {
            if resumeAllBackgroundDownloads() {
                task.setTaskAsComplete(success: true)
            } else {
                task.setTaskAsComplete(success: false)
            }
        }
    }
    
    /// Resume all paused downloads
    private static func resumeAllBackgroundDownloads() -> Bool {
        print("[Background] Attempting to resume downloads")
        
        // Call the Go backend through the platform channel
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        
        DispatchQueue.main.async {
            if let controller = UIApplication.shared.windows.first?.rootViewController as? FlutterViewController {
                let channel = FlutterMethodChannel(
                    name: "com.gopeed.app/background_download",
                    binaryMessenger: controller.binaryMessenger
                )
                
                channel.invokeMethod("resumeAllBackgroundDownloads") { (r) in
                    if let r = r as? Bool {
                        result = r
                    }
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }
        
        semaphore.wait(timeout: .now() + 25) // BGProcessingTask timeout is ~30s
        return result
    }
    
    /// Check if any downloads are active
    static func isDownloadActive() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        
        DispatchQueue.main.async {
            if let controller = UIApplication.shared.windows.first?.rootViewController as? FlutterViewController {
                let channel = FlutterMethodChannel(
                    name: "com.gopeed.app/background_download",
                    binaryMessenger: controller.binaryMessenger
                )
                
                channel.invokeMethod("isDownloadActive") { (r) in
                    if let r = r as? Bool {
                        result = r
                    }
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }
        
        semaphore.wait(timeout: .now() + 5)
        return result
    }
    
    /// Handle app entering background
    static func onAppBackground() {
        print("[Background] App entering background")
        
        // Check if downloads are active
        if isDownloadActive() {
            scheduleBackgroundDownloadTask()
            scheduleBackgroundProcessingTask()
            print("[Background] Scheduled background tasks")
        }
    }
    
    /// Handle app entering foreground
    static func onAppForeground() {
        print("[Background] App entering foreground")
        // Cancel any pending background tasks if needed
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}
