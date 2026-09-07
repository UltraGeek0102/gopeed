import ActivityKit
import Foundation
import Libgopeed
import UIKit

@objcMembers
final class GopeedLiveActivityManager: NSObject {

    static let shared = GopeedLiveActivityManager()

    // Gopeed emits progress approximately every 350 ms.
    // There is no reason to hit ActivityKit that frequently.
    private let minimumUpdateInterval: TimeInterval = 2.0

    private var lastUpdateTime: [String: Date] = [:]

    private override init() {
        super.init()
    }

    // MARK: - Gopeed event entry point

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
            let taskID = json["taskId"] as? String
        else {
            print("LiveActivity: invalid task event payload")
            return
        }

        let name = json["name"] as? String ?? "Download"

        switch type {

        case "task.start":
            Task {
                await refreshActivity(
                    taskID: taskID,
                    name: name,
                    allowStart: true
                )
            }

        case "task.progress":
            handleProgress(
                taskID: taskID,
                name: name
            )

        case "task.pause":
            Task {
                await refreshActivity(
                    taskID: taskID,
                    name: name,
                    allowStart: false
                )
            }

        case "task.done":
            Task {
                await finishActivity(
                    taskID: taskID
                )
            }

        case "task.error":
            let error =
                json["error"] as? String
                ?? "Download failed"

            Task {
                await failActivity(
                    taskID: taskID,
                    error: error
                )
            }

        case "task.delete":
            Task {
                await removeActivity(
                    taskID: taskID
                )
            }

        default:
            break
        }
    }


    // MARK: - Progress throttling

    @available(iOS 16.2, *)
    private func handleProgress(
        taskID: String,
        name: String
    ) {
        let now = Date()

        if let previous = lastUpdateTime[taskID] {
            let elapsed =
                now.timeIntervalSince(previous)

            if elapsed < minimumUpdateInterval {
                return
            }
        }

        lastUpdateTime[taskID] = now

        Task {
            await refreshActivity(
                taskID: taskID,
                name: name,
                allowStart: true
            )
        }
    }


    // MARK: - Gopeed runtime status

    private struct RuntimeStatus {
        let status: String
        let downloaded: Int64
        let total: Int64
        let speed: Int64
    }

    private func getRuntimeStatus(
        taskID: String
    ) -> RuntimeStatus? {

        let response = LibgopeedInvoke(
            "GET",
            "/api/v1/tasks/\(taskID)/status",
            "",
            ""
        )

        guard
            let data = response.data(using: .utf8),
            let root =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any]
        else {
            print(
                "LiveActivity: failed to decode status for \(taskID)"
            )
            return nil
        }

        let code =
            (root["code"] as? NSNumber)?.intValue
            ?? -1

        guard code == 0 else {
            let message =
                root["msg"] as? String
                ?? "Unknown Gopeed API error"

            print(
                "LiveActivity: Gopeed status error:",
                message
            )

            return nil
        }

        guard
            let body =
                root["data"] as? [String: Any]
        else {
            return nil
        }

        return RuntimeStatus(
            status:
                body["status"] as? String ?? "",
            downloaded:
                (body["downloaded"] as? NSNumber)?
                    .int64Value ?? 0,
            total:
                (body["total"] as? NSNumber)?
                    .int64Value ?? 0,
            speed:
                (body["speed"] as? NSNumber)?
                    .int64Value ?? 0
        )
    }


    // MARK: - Build Live Activity state

    @available(iOS 16.2, *)
    private func makeState(
        from runtime: RuntimeStatus
    ) -> GopeedDownloadAttributes.ContentState {

        let now = Date()

        let total =
            max(runtime.total, 0)

        let downloaded: Int64

        if total > 0 {
            downloaded =
                min(
                    max(runtime.downloaded, 0),
                    total
                )
        } else {
            downloaded =
                max(runtime.downloaded, 0)
        }

        let progress: Double

        if total > 0 {
            progress =
                min(
                    max(
                        Double(downloaded)
                            / Double(total),
                        0
                    ),
                    1
                )
        } else {
            progress = 0
        }

        // If we don't have enough information for an ETA,
        // use the real static progress bar.
        guard
            total > 0,
            runtime.speed > 0,
            downloaded < total,
            progress > 0,
            progress < 1
        else {
            return GopeedDownloadAttributes
                .ContentState(
                    progress: progress,
                    downloaded: downloaded,
                    total: total,
                    speed: runtime.speed,
                    status: runtime.status,
                    estimatedStart: now,
                    estimatedEnd:
                        now.addingTimeInterval(1),
                    usesEstimatedProgress: false
                )
        }

        let remainingBytes =
            Double(total - downloaded)

        var remainingSeconds =
            remainingBytes
            / Double(runtime.speed)

        // Don't allow corrupt speed values to create
        // ridiculous date ranges.
        remainingSeconds =
            min(
                max(remainingSeconds, 1),
                86_400
            )

        let remainingFraction =
            max(1.0 - progress, 0.001)

        let estimatedTotalDuration =
            remainingSeconds
            / remainingFraction

        let elapsedEstimate =
            estimatedTotalDuration
            * progress

        let estimatedStart =
            now.addingTimeInterval(
                -elapsedEstimate
            )

        let estimatedEnd =
            now.addingTimeInterval(
                remainingSeconds
            )

        return GopeedDownloadAttributes
            .ContentState(
                progress: progress,
                downloaded: downloaded,
                total: total,
                speed: runtime.speed,
                status: runtime.status,
                estimatedStart: estimatedStart,
                estimatedEnd: estimatedEnd,
                usesEstimatedProgress: true
            )
    }


    // MARK: - Find existing Activity

    @available(iOS 16.2, *)
    private func findActivity(
        taskID: String
    ) -> Activity<GopeedDownloadAttributes>? {

        return Activity<
            GopeedDownloadAttributes
        >
        .activities
        .first {
            $0.attributes.taskId == taskID
        }
    }


    // MARK: - Start / update Activity

    @available(iOS 16.2, *)
    private func refreshActivity(
        taskID: String,
        name: String,
        allowStart: Bool
    ) async {

        guard
            let runtime =
                getRuntimeStatus(
                    taskID: taskID
                )
        else {
            return
        }

        let state =
            makeState(from: runtime)

        let content =
            ActivityContent(
                state: state,
                staleDate: nil
            )

        // Activity already exists → update it.
        if let activity =
            findActivity(taskID: taskID) {

            await activity.update(content)

            return
        }

        // Don't create a new Activity for pause/etc.
        guard allowStart else {
            return
        }

        guard
            ActivityAuthorizationInfo()
                .areActivitiesEnabled
        else {
            print(
                "LiveActivity: activities disabled"
            )
            return
        }

        // A local Live Activity should be started while
        // the application is in the foreground.
        let appIsActive =
            await MainActor.run {
                UIApplication.shared
                    .applicationState == .active
            }

        guard appIsActive else {
            return
        }

        let attributes =
            GopeedDownloadAttributes(
                taskId: taskID,
                fileName: name
            )

        do {
            let activity =
                try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )

            print(
                "LiveActivity: started",
                activity.id,
                taskID
            )

        } catch {
            print(
                "LiveActivity: start failed:",
                error
            )
        }
    }


    // MARK: - Complete Activity

    @available(iOS 16.2, *)
    private func finishActivity(
        taskID: String
    ) async {

        guard
            let activity =
                findActivity(taskID: taskID)
        else {
            lastUpdateTime.removeValue(
                forKey: taskID
            )
            return
        }

        let oldState =
            activity.content.state

        let finalTotal =
            max(
                oldState.total,
                oldState.downloaded
            )

        let now = Date()

        let finalState =
            GopeedDownloadAttributes
                .ContentState(
                    progress: 1.0,
                    downloaded: finalTotal,
                    total: finalTotal,
                    speed: 0,
                    status: "done",
                    estimatedStart: now,
                    estimatedEnd:
                        now.addingTimeInterval(1),
                    usesEstimatedProgress: false
                )

        let finalContent =
            ActivityContent(
                state: finalState,
                staleDate: nil
            )

        await activity.end(
            finalContent,
            dismissalPolicy:
                .after(
                    Date()
                        .addingTimeInterval(15)
                )
        )

        lastUpdateTime.removeValue(
            forKey: taskID
        )

        print(
            "LiveActivity: completed",
            taskID
        )
    }


    // MARK: - Error Activity

    @available(iOS 16.2, *)
    private func failActivity(
        taskID: String,
        error: String
    ) async {

        guard
            let activity =
                findActivity(taskID: taskID)
        else {
            lastUpdateTime.removeValue(
                forKey: taskID
            )
            return
        }

        let old =
            activity.content.state

        let now = Date()

        let failedState =
            GopeedDownloadAttributes
                .ContentState(
                    progress: old.progress,
                    downloaded: old.downloaded,
                    total: old.total,
                    speed: 0,
                    status: "error",
                    estimatedStart: now,
                    estimatedEnd:
                        now.addingTimeInterval(1),
                    usesEstimatedProgress: false
                )

        let content =
            ActivityContent(
                state: failedState,
                staleDate: nil
            )

        await activity.end(
            content,
            dismissalPolicy:
                .after(
                    Date()
                        .addingTimeInterval(30)
                )
        )

        lastUpdateTime.removeValue(
            forKey: taskID
        )

        print(
            "LiveActivity: task failed:",
            taskID,
            error
        )
    }


    // MARK: - Delete Activity

    @available(iOS 16.2, *)
    private func removeActivity(
        taskID: String
    ) async {

        if let activity =
            findActivity(taskID: taskID) {

            await activity.end(
                nil,
                dismissalPolicy: .immediate
            )
        }

        lastUpdateTime.removeValue(
            forKey: taskID
        )

        print(
            "LiveActivity: removed",
            taskID
        )
    }
}
