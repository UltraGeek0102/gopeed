import BackgroundTasks
import Foundation
import Libgopeed
import UIKit

@available(iOS 26.0, *)
@objcMembers
final class GopeedContinuedProcessingManager: NSObject {

    static let shared = GopeedContinuedProcessingManager()

    private(set) var isEnabled = false

    private var registeredIdentifiers = Set<String>()
    private var pendingTaskIDs = Set<String>()

    private var activeTasks:
        [String: BGContinuedProcessingTask] = [:]

    private var taskIdentifiers:
        [String: String] = [:]

    private var taskNames:
        [String: String] = [:]

    private var lastProgressUpdate:
        [String: Date] = [:]

    // Gopeed sends progress about every 350 ms.
    // One system-progress update per second is enough.
    private let minimumUpdateInterval:
        TimeInterval = 1.0

    private override init() {
        super.init()
    }


    // MARK: - Availability / setting

    func setEnabled(_ enabled: Bool) -> Bool {

        if Thread.isMainThread {
            return setEnabledOnMain(enabled)
        }

        return DispatchQueue.main.sync {
            setEnabledOnMain(enabled)
        }
    }

    private func setEnabledOnMain(
        _ enabled: Bool
    ) -> Bool {

        isEnabled = enabled

        if !enabled {
            stopAllContinuedTasks()
        }

        print(
            "ContinuedProcessing: enabled =",
            enabled
        )

        return true
    }


    // MARK: - Event entry point

    func handleTaskEventPayload(
        _ payload: String
    ) {

        let work = {
            self.handleTaskEventPayloadOnMain(
                payload
            )
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(
                execute: work
            )
        }
    }

    private func handleTaskEventPayloadOnMain(
        _ payload: String
    ) {

        guard isEnabled else {
            return
        }

        guard
            let data = payload.data(
                using: .utf8
            ),
            let json =
                try? JSONSerialization
                    .jsonObject(
                        with: data
                    ) as? [String: Any],
            let type =
                json["type"] as? String,
            let taskID =
                json["taskId"] as? String
        else {
            print(
                "ContinuedProcessing: invalid event"
            )
            return
        }

        let name =
            json["name"] as? String
            ?? "Download"

        switch type {

        case "task.start":
            beginTask(
                taskID: taskID,
                name: name
            )

        case "task.progress":
            updateProgress(
                taskID: taskID,
                force: false
            )

        case "task.pause":
            finishTask(
                taskID: taskID,
                success: true,
                finalSubtitle: "Paused"
            )

        case "task.done":
            finishTask(
                taskID: taskID,
                success: true,
                finalSubtitle:
                    "Download complete"
            )

        case "task.error":
            finishTask(
                taskID: taskID,
                success: false,
                finalSubtitle:
                    "Download failed"
            )

        case "task.delete":
            finishTask(
                taskID: taskID,
                success: true,
                finalSubtitle:
                    "Download removed"
            )

        default:
            break
        }
    }


    // MARK: - Used by Objective-C forwarder

    @objc(isHandlingTaskId:)
    func isHandlingTaskId(
        _ taskID: String
    ) -> Bool {

        if Thread.isMainThread {
            return isHandlingTaskIdOnMain(
                taskID
            )
        }

        return DispatchQueue.main.sync {
            isHandlingTaskIdOnMain(
                taskID
            )
        }
    }

    private func isHandlingTaskIdOnMain(
        _ taskID: String
    ) -> Bool {

        return pendingTaskIDs.contains(taskID)
            || activeTasks[taskID] != nil
    }


    // MARK: - Start BGCPT

    private func beginTask(
        taskID: String,
        name: String
    ) {

        guard isEnabled else {
            return
        }

        // Continued processing tasks are supposed
        // to originate from a foreground user action.
        guard
            UIApplication.shared
                .applicationState == .active
        else {
            print(
                "ContinuedProcessing:",
                "ignored non-foreground start",
                taskID
            )

            return
        }

        guard
            !pendingTaskIDs.contains(taskID),
            activeTasks[taskID] == nil
        else {
            return
        }

        let identifier =
            makeIdentifier(
                taskID: taskID
            )

        taskIdentifiers[taskID] =
            identifier

        taskNames[taskID] =
            name

        if !registeredIdentifiers
            .contains(identifier) {

            let registered =
                BGTaskScheduler.shared.register(
                    forTaskWithIdentifier:
                        identifier,
                    using:
                        DispatchQueue.main
                ) { [weak self] task in

                    guard
                        let self,
                        let task =
                            task as?
                            BGContinuedProcessingTask
                    else {
                        task.setTaskCompleted(
                            success: false
                        )
                        return
                    }

                    self.activateTask(
                        task,
                        taskID: taskID,
                        name: name
                    )
                }

            guard registered else {

                print(
                    "ContinuedProcessing:",
                    "registration failed:",
                    identifier
                )

                taskIdentifiers.removeValue(
                    forKey: taskID
                )

                taskNames.removeValue(
                    forKey: taskID
                )

                return
            }

            registeredIdentifiers.insert(
                identifier
            )
        }

        let request =
            BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: name,
                subtitle:
                    "Preparing download…"
            )

        // A Gopeed download has already started.
        // A delayed/queued BGCPT would be undesirable,
        // so fall back immediately if iOS cannot run it.
        request.strategy = .fail

        pendingTaskIDs.insert(taskID)

        do {

            try BGTaskScheduler.shared.submit(
                request
            )

            print(
                "ContinuedProcessing:",
                "submitted:",
                identifier
            )

        } catch {

            pendingTaskIDs.remove(
                taskID
            )

            taskIdentifiers.removeValue(
                forKey: taskID
            )

            print(
                "ContinuedProcessing:",
                "submission failed:",
                error
            )
        }
    }


    // MARK: - System launched task

    private func activateTask(
        _ task: BGContinuedProcessingTask,
        taskID: String,
        name: String
    ) {

        guard isEnabled else {

            task.setTaskCompleted(
                success: false
            )

            return
        }

        pendingTaskIDs.remove(taskID)

        activeTasks[taskID] = task

        taskNames[taskID] = name

        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0

        task.expirationHandler = {
            [weak self, weak task] in

            DispatchQueue.main.async {

                guard
                    let self,
                    let task
                else {
                    return
                }

                self.handleExpiration(
                    task,
                    taskID: taskID
                )
            }
        }

        print(
            "ContinuedProcessing:",
            "started:",
            taskID
        )

        updateProgress(
            taskID: taskID,
            force: true
        )
    }


    // MARK: - Progress

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
            let data =
                response.data(
                    using: .utf8
                ),
            let root =
                try? JSONSerialization
                    .jsonObject(
                        with: data
                    ) as? [String: Any],
            let code =
                (root["code"] as? NSNumber)?
                    .intValue,
            code == 0,
            let body =
                root["data"]
                    as? [String: Any]
        else {
            return nil
        }

        return RuntimeStatus(
            status:
                body["status"]
                    as? String ?? "",
            downloaded:
                (body["downloaded"]
                    as? NSNumber)?
                    .int64Value ?? 0,
            total:
                (body["total"]
                    as? NSNumber)?
                    .int64Value ?? 0,
            speed:
                (body["speed"]
                    as? NSNumber)?
                    .int64Value ?? 0
        )
    }

    private func updateProgress(
        taskID: String,
        force: Bool
    ) {

        guard
            let task = activeTasks[taskID]
        else {
            return
        }

        let now = Date()

        if !force,
           let previous =
                lastProgressUpdate[taskID],
           now.timeIntervalSince(previous)
                < minimumUpdateInterval {

            return
        }

        guard
            let runtime =
                getRuntimeStatus(
                    taskID: taskID
                )
        else {
            return
        }

        lastProgressUpdate[taskID] = now

        let downloaded =
            max(runtime.downloaded, 0)

        let name =
            taskNames[taskID]
            ?? task.title

        if runtime.total > 0 {

            let total =
                max(runtime.total, 1)

            let completed =
                min(
                    downloaded,
                    total
                )

            task.progress.totalUnitCount =
                total

            task.progress.completedUnitCount =
                completed

            let percent =
                Int(
                    (
                        Double(completed)
                        / Double(total)
                        * 100.0
                    ).rounded()
                )

            var subtitle =
                "\(percent)% • " +
                "\(formatBytes(completed)) / " +
                "\(formatBytes(total))"

            if runtime.speed > 0 {
                subtitle +=
                    " • \(formatBytes(runtime.speed))/s"
            }

            task.updateTitle(
                name,
                subtitle: subtitle
            )

        } else {

            // Some protocols don't know their
            // total size immediately.
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = 0

            var subtitle =
                formatBytes(downloaded)

            if runtime.speed > 0 {
                subtitle +=
                    " • \(formatBytes(runtime.speed))/s"
            }

            task.updateTitle(
                name,
                subtitle: subtitle
            )
        }
    }


    // MARK: - Completion

    private func finishTask(
        taskID: String,
        success: Bool,
        finalSubtitle: String
    ) {

        if let identifier =
            taskIdentifiers[taskID] {

            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier:
                    identifier
            )
        }

        pendingTaskIDs.remove(taskID)

        if let task =
            activeTasks.removeValue(
                forKey: taskID
            ) {

            if success,
               let runtime =
                    getRuntimeStatus(
                        taskID: taskID
                    ),
               runtime.total > 0 {

                task.progress.totalUnitCount =
                    runtime.total

                task.progress
                    .completedUnitCount =
                    min(
                        runtime.downloaded,
                        runtime.total
                    )
            }

            task.updateTitle(
                taskNames[taskID]
                    ?? task.title,
                subtitle:
                    finalSubtitle
            )

            task.setTaskCompleted(
                success: success
            )
        }

        taskIdentifiers.removeValue(
            forKey: taskID
        )

        taskNames.removeValue(
            forKey: taskID
        )

        lastProgressUpdate.removeValue(
            forKey: taskID
        )

        print(
            "ContinuedProcessing:",
            "finished:",
            taskID,
            "success:",
            success
        )
    }


    // MARK: - Expiration / system cancellation

    private func handleExpiration(
        _ task: BGContinuedProcessingTask,
        taskID: String
    ) {

        // Remove first so the resulting task.pause
        // event cannot complete this BGTask twice.
        activeTasks.removeValue(
            forKey: taskID
        )

        pendingTaskIDs.remove(taskID)

        lastProgressUpdate.removeValue(
            forKey: taskID
        )

        print(
            "ContinuedProcessing:",
            "expired/cancelled:",
            taskID
        )

        // The system Live Activity allows the user
        // to cancel the task. Respect that by
        // pausing the corresponding Gopeed download.
        _ = LibgopeedInvoke(
            "PUT",
            "/api/v1/tasks/\(taskID)/pause",
            "",
            ""
        )

        task.setTaskCompleted(
            success: false
        )

        taskIdentifiers.removeValue(
            forKey: taskID
        )

        taskNames.removeValue(
            forKey: taskID
        )
    }


    // MARK: - Disable all BGCPT tasks

    private func stopAllContinuedTasks() {

        for (
            taskID,
            identifier
        ) in taskIdentifiers {

            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier:
                    identifier
            )

            if let task =
                activeTasks[taskID] {

                task.setTaskCompleted(
                    success: true
                )
            }
        }

        activeTasks.removeAll()
        pendingTaskIDs.removeAll()
        taskIdentifiers.removeAll()
        taskNames.removeAll()
        lastProgressUpdate.removeAll()
    }


    // MARK: - Helpers

    private func makeIdentifier(
        taskID: String
    ) -> String {

        let bundleID =
            Bundle.main.bundleIdentifier
            ?? "com.gopeed.gopeed"

        let safeID =
            taskID.replacingOccurrences(
                of: "[^A-Za-z0-9_-]",
                with: "-",
                options:
                    .regularExpression
            )

        return
            "\(bundleID)" +
            ".continuedDownload." +
            safeID
    }

    private func formatBytes(
        _ bytes: Int64
    ) -> String {

        return ByteCountFormatter.string(
            fromByteCount:
                max(bytes, 0),
            countStyle: .file
        )
    }
}
