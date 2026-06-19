import UIKit
import Flutter
import Libgopeed

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    private var bgChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // ── Existing libgopeed channel ────────────────────────────────────────
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

        // ── Background download channel ───────────────────────────────────────
        // This channel does NOT handle the actual HTTP download — the Go engine does.
        // It manages the keep-alive (AVAudioSession + BGTask) and Live Activities.
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

    // ── App lifecycle → keep-alive ────────────────────────────────────────────

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        BackgroundDownloadManager.shared.applicationDidEnterBackground()
    }

    override func applicationWillEnterForeground(_ application: UIApplication) {
        super.applicationWillEnterForeground(application)
        BackgroundDownloadManager.shared.applicationWillEnterForeground()
    }

    // ── Method channel handler ────────────────────────────────────────────────

    private func handleBgDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        case "registerDownload":
            // Called by Flutter when a download task starts.
            // The Go engine does the actual HTTP work.
            // We register here to: track active downloads, start keep-alive, start Live Activity.
            guard
                let id       = args["id"]       as? String,
                let filename = args["filename"]  as? String
            else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "registerDownload requires id and filename",
                                    details: nil))
                return
            }

            BackgroundDownloadManager.shared.registerDownload(
                id: id,
                filename: filename,
                onProgress: { [weak self] progress, downloaded, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id": id, "progress": progress,
                        "downloaded": downloaded, "total": total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id": id,
                        "error": error?.localizedDescription as Any
                    ])
                }
            )
            result(nil)

        case "updateProgress":
            // Flutter/Go engine sends progress updates → we forward to Live Activity
            guard let id = args["id"] as? String else { result(nil); return }
            let progress   = (args["progress"]   as? Double) ?? 0.0
            let downloaded = (args["downloaded"] as? Int64)  ?? 0
            let total      = (args["total"]      as? Int64)  ?? 0
            BackgroundDownloadManager.shared.updateProgress(
                id: id, progress: progress, downloaded: downloaded, total: total)
            result(nil)

        case "completeDownload":
            // Called when Go engine finishes (success or error)
            guard let id = args["id"] as? String else { result(nil); return }
            let errorMsg = args["error"] as? String
            BackgroundDownloadManager.shared.completeDownload(id: id, errorMessage: errorMsg)
            result(nil)

        case "cancelDownload":
            guard let id = args["id"] as? String else { result(nil); return }
            BackgroundDownloadManager.shared.cancelDownload(id: id)
            result(nil)

        case "reattach":
            guard let id = args["id"] as? String else { result(nil); return }
            BackgroundDownloadManager.shared.reattach(
                id: id,
                onProgress: { [weak self] progress, downloaded, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id": id, "progress": progress,
                        "downloaded": downloaded, "total": total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id": id,
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
