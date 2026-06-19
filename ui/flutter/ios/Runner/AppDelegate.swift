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

        // ── Libgopeed channel (unchanged) ─────────────────────────────────────
        let gopeedChannel = FlutterMethodChannel(
            name: "gopeed.com/libgopeed",
            binaryMessenger: controller.binaryMessenger
        )
        gopeedChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "start":
                let args = call.arguments as? [String: Any]
                let cfg = args?["cfg"] as? String
                let portPtr = UnsafeMutablePointer<Int>.allocate(
                    capacity: MemoryLayout<Int>.stride)
                var error: NSError?
                if LibgopeedStart(cfg, portPtr, &error) {
                    result(portPtr.pointee)
                } else {
                    result(FlutterError(code: "ERROR",
                                        message: error.debugDescription,
                                        details: nil))
                }
            case "stop":
                LibgopeedStop()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // ── Background download / Live Activity channel ────────────────────────
        bgChannel = FlutterMethodChannel(
            name: "gopeed.com/background_download",
            binaryMessenger: controller.binaryMessenger
        )
        bgChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handleBackground(call: call, result: result)
        }

        GeneratedPluginRegistrant.register(with: self)
        SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback(registerPlugins)
        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate =
                self as? UNUserNotificationCenterDelegate
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        BackgroundDownloadManager.shared.applicationDidEnterBackground()
    }

    override func applicationWillEnterForeground(_ application: UIApplication) {
        super.applicationWillEnterForeground(application)
        BackgroundDownloadManager.shared.applicationWillEnterForeground()
    }

    // ── Channel handler ────────────────────────────────────────────────────────

    private func handleBackground(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        case "configureGoEngine":
            // Called once by Flutter after the Go engine starts,
            // so Swift knows the port for native TCP polling.
            let port     = args["port"]     as? Int    ?? 0
            let apiToken = args["apiToken"] as? String ?? ""
            BackgroundDownloadManager.shared.configure(port: port, apiToken: apiToken)
            result(nil)

        case "registerDownload":
            guard
                let id       = args["id"]       as? String,
                let filename = args["filename"]  as? String
            else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "id and filename required", details: nil))
                return
            }
            BackgroundDownloadManager.shared.registerDownload(
                id: id, filename: filename,
                onProgress: { [weak self] p, dl, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id": id, "progress": p, "downloaded": dl, "total": total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id": id, "error": error?.localizedDescription as Any
                    ])
                }
            )
            result(nil)

        case "updateProgress":
            let id         = args["id"]         as? String ?? ""
            let progress   = args["progress"]   as? Double ?? 0.0
            let downloaded = (args["downloaded"] as? Int64) ?? Int64((args["downloaded"] as? Int) ?? 0)
            let total      = (args["total"]      as? Int64) ?? Int64((args["total"]      as? Int) ?? 0)
            BackgroundDownloadManager.shared.updateProgress(
                id: id, progress: progress, downloaded: downloaded, total: total)
            result(nil)

        case "completeDownload":
            let id  = args["id"]    as? String ?? ""
            let err = args["error"] as? String
            BackgroundDownloadManager.shared.completeDownload(id: id, errorMessage: err)
            result(nil)

        case "cancelDownload":
            let id = args["id"] as? String ?? ""
            BackgroundDownloadManager.shared.cancelDownload(id: id)
            result(nil)

        case "reattach":
            let id = args["id"] as? String ?? ""
            BackgroundDownloadManager.shared.reattach(
                id: id,
                onProgress: { [weak self] p, dl, total in
                    self?.bgChannel?.invokeMethod("onProgress", arguments: [
                        "id": id, "progress": p, "downloaded": dl, "total": total
                    ])
                },
                onComplete: { [weak self] error in
                    self?.bgChannel?.invokeMethod("onComplete", arguments: [
                        "id": id, "error": error?.localizedDescription as Any
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
