// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import XCTest
@testable import TarBackup

final class TarPathPatternTests: XCTestCase {
    func testStarDoesNotCrossDirectorySeparator() {
        let pattern = TarPathPattern("images/*.png")

        XCTAssertTrue(pattern.matches("images/photo.png"))
        XCTAssertFalse(pattern.matches("images/nested/photo.png"))
    }

    func testQuestionMarkMatchesExactlyOneNonSeparatorCharacter() {
        let pattern = TarPathPattern("file-?.txt")

        XCTAssertTrue(pattern.matches("file-a.txt"))
        XCTAssertFalse(pattern.matches("file-.txt"))
        XCTAssertFalse(pattern.matches("file-ab.txt"))
        XCTAssertFalse(pattern.matches("file-/.txt"))
    }

    func testDoubleStarCrossesDirectorySeparators() {
        let pattern = TarPathPattern("images/**/photo.png")

        XCTAssertTrue(pattern.matches("images/photo.png"))
        XCTAssertTrue(pattern.matches("images/2026/photo.png"))
        XCTAssertTrue(pattern.matches("images/2026/events/photo.png"))
    }

    func testRegularExpressionCharactersAreTreatedLiterally() {
        let pattern = TarPathPattern("reports/[draft]+(1).txt")

        XCTAssertTrue(pattern.matches("reports/[draft]+(1).txt"))
        XCTAssertFalse(pattern.matches("reports/draft1.txt"))
    }
}
