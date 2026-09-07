import ActivityKit
import Foundation
import Libgopeed
import UIKit

@objcMembers
final class GopeedLiveActivityManager: NSObject {

    static let shared = GopeedLiveActivityManager()

    private var lastUpdate: [String: Date] = [:]

    // Don't feed ActivityKit every 350 ms.
    private let updateInterval: TimeInterval = 2.0

    private override init() {
        super.init()
    }

    @objc
    func handleTaskEventPayload(_ payload: String) {

        guard #available(iOS 16.2, *) else {
            return
        }

        guard
            let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let type = json["type"] as? String,
            let taskId = json["taskId"] as? String
        else {
            return
        }

        let name = json["name"] as? String ?? "Download"

        switch type {

        case "task.start":
            Task {
                await refresh(
                    taskId: taskId,
                    name: name,
                    allowStart: true
                )
            }

        case "task.progress":
            handleProgress(
                taskId: taskId,
                name: name
            )

        case "task.pause":
            Task {
                await refresh(
                    taskId: taskId,
                    name: name,
                    allowStart: false
                )
            }

        case "task.done":
            Task {
                await finish(
                    taskId: taskId,
                    name: name
                )
            }

        case "task.error":
            let error =
                json["error"] as? String ?? "Download failed"

            Task {
                await fail(
                    taskId: taskId,
                    error: error
                )
            }

        case "task.delete":
            Task {
                await remove(taskId: taskId)
            }

        default:
            break
        }
    }
}

@available(iOS 16.2, *)
private extension GopeedLiveActivityManager {

    func handleProgress(
        taskId: String,
        name: String
    ) {
        let now = Date()

        if let previous = lastUpdate[taskId],
           now.timeIntervalSince(previous) < updateInterval {
            return
        }

        lastUpdate[taskId] = now

        Task {
            await refresh(
                taskId: taskId,
                name: name,
                allowStart: true
            )
        }
    }
}
