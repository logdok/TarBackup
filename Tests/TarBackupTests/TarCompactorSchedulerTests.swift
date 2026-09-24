// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarCompactorSchedulerTests: XCTestCase {
    func testBackgroundTaskIdentifierIsStable() {
        XCTAssertEqual(
            TarCompactorScheduler.bgTaskIdentifier,
            "com.tarbackup.compacting"
        )
    }

    #if !os(iOS)
    func testSchedulingMethodsAreSafeNoOpsOutsideIOS() {
        let temporaryURL = FileManager.default.temporaryDirectory
        let manager = TarBackupManager(
            archiveURL: temporaryURL.appendingPathComponent("unused.tar"),
            sourceDirectoryURL: temporaryURL
        )

        TarCompactorScheduler.shared.registerBackgroundTask(manager: manager)
        TarCompactorScheduler.shared.scheduleCompacting()
    }
    #endif
}
