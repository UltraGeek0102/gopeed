import Flutter
import BackgroundTasks

/// Extension for background download method channel setup
extension GeneratedPluginRegistrant {
    /// Setup background download method channel
    static func setupBackgroundDownloadChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "com.gopeed.app/background_download",
            binaryMessenger: controller.binaryMessenger
        )
        
        channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "initializeBackgroundDownloads":
                BackgroundDownloadHandler.registerBackgroundTasks()
                result(true)
                
            case "scheduleBackgroundDownloadTask":
                BackgroundDownloadHandler.scheduleBackgroundDownloadTask()
                result(true)
                
            case "onAppBackground":
                BackgroundDownloadHandler.onAppBackground()
                result(true)
                
            case "onAppForeground":
                BackgroundDownloadHandler.onAppForeground()
                result(true)
                
            case "isDownloadActive":
                let active = BackgroundDownloadHandler.isDownloadActive()
                result(active)
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
