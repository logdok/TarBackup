// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

public final class TarCompactorScheduler {
    public static let shared = TarCompactorScheduler()
    public static let bgTaskIdentifier = "com.tarbackup.compacting"

    private init() {}

    /// Registers background task handler for iOS. Call this in AppDelegate or App Init.
    public func registerBackgroundTask(manager: TarBackupManager) {
        #if os(iOS)
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.bgTaskIdentifier,
                using: nil
            ) { task in
                guard let processingTask = task as? BGProcessingTask else { return }
                self.handleBackgroundTask(task: processingTask, manager: manager)
            }
        }
        #endif
    }

    /// Schedules compactor execution when device is charging and idle.
    public func scheduleCompacting() {
        #if os(iOS)
        if #available(iOS 13.0, *) {
            let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("[TarBackup] Failed to schedule compacting task: \(error)")
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 13.0, *)
    private func handleBackgroundTask(task: BGProcessingTask, manager: TarBackupManager) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let operation = BlockOperation {
            do {
                try manager.compactArchive()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            queue.cancelAllOperations()
        }

        queue.addOperation(operation)
    }
    #endif
}
