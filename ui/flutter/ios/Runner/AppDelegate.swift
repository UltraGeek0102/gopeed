import UIKit
import Flutter
import Libgopeed

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    // The background download channel — separate from the existing libgopeed channel
    private var bgChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // ── Existing libgopeed channel (unchanged) ────────────────────────────────
        let gopeedChannel = FlutterMethodChannel(
            name: "gopeed.com/libgopeed",
            binaryMessenger: controller.binaryMessenger
        )
        gopeedChannel.setMethodCallHandler({ (call, result) in
            switch call.method {
            case "start":
                let args = call.arguments as? Dictionary<String, Any>
                let cfg = args?["cfg"] as? String
                let portPrt = UnsafeMutablePointer<Int>.allocate(capacity: MemoryLayout<Int>.stride)
                var error: NSError?
                if LibgopeedStart(cfg, portPrt, &error) {
                    result(portPrt.pointee)
                } else {
                    result(FlutterError(code: "ERROR", message: error.debugDescription, details: nil))
                }
            case "stop":
                LibgopeedStop()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        })

        // ── New background download channel ───────────────────────────────────────
        bgChannel = FlutterMethodChannel(
            name: "gopeed.com/background_download",
            binaryMessenger: controller.binaryMessenger
        )
        bgChannel?.setMethodCallHandler({ [weak self] (call, result) in
            self?.handleBgDownload(call: call, result: result)
        })

        GeneratedPluginRegistrant.register(with: self)
        SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback(registerPlugins)
        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── Required: hand background URLSession events back to NSURLSession ──────────
    override func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Only handle our own session
        if identifier == "com.gopeed.gopeed.bgdownload" {
            BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }

    // MARK: - Background download method handler

    private func handleBgDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        case "startDownload":
            guard
                let id       = args["id"]       as? String,
                let url      = args["url"]       as? String,
                let filename = args["filename"]  as? String,
                let destPath = args["destPath"]  as? String
            else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "startDownload requires id, url, filename, destPath",
                                    details: nil))
                return
            }
            let headers = args["headers"] as? [String: String] ?? [:]

            BackgroundDownloadManager.shared.startDownload(
                id: id,
                url: url,
                filename: filename,
                headers: headers,
                destPath: destPath,
                onProgress: { [weak self] progress, downloaded, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id":         id,
                        "progress":   progress,
                        "downloaded": downloaded,
                        "total":      total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id":    id,
                        "error": error?.localizedDescription as Any
                    ])
                }
            )
            result(nil)

        case "pauseDownload":
            guard let id = args["id"] as? String else { result(FlutterMethodNotImplemented); return }
            BackgroundDownloadManager.shared.pauseDownload(id: id)
            result(nil)

        case "resumeDownload":
            guard let id = args["id"] as? String else { result(FlutterMethodNotImplemented); return }
            BackgroundDownloadManager.shared.resumeDownload(
                id: id,
                onProgress: { [weak self] progress, downloaded, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id":         id,
                        "progress":   progress,
                        "downloaded": downloaded,
                        "total":      total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id":    id,
                        "error": error?.localizedDescription as Any
                    ])
                }
            )
            result(nil)

        case "cancelDownload":
            guard let id = args["id"] as? String else { result(FlutterMethodNotImplemented); return }
            BackgroundDownloadManager.shared.cancelDownload(id: id)
            LiveActivityBridge.shared.end(id: id, success: false)
            result(nil)

        case "reattach":
            // Called when app foregrounds and wants progress callbacks re-hooked
            guard let id = args["id"] as? String else { result(FlutterMethodNotImplemented); return }
            BackgroundDownloadManager.shared.reattach(
                id: id,
                onProgress: { [weak self] progress, downloaded, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id":         id,
                        "progress":   progress,
                        "downloaded": downloaded,
                        "total":      total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id":    id,
                        "error": error?.localizedDescription as Any
                    ])
                }
            )
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

func registerPlugins(registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
}
