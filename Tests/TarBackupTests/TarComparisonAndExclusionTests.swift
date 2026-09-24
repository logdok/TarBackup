// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarComparisonAndExclusionTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var sourceDirectoryURL: URL!
    private var archiveURL: URL!
    private var manager: TarBackupManager!
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarComparisonTests-\(UUID().uuidString)", isDirectory: true)
        sourceDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Source", isDirectory: true)
        archiveURL = temporaryDirectoryURL.appendingPathComponent("backup.tar")
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        manager = TarBackupManager(archiveURL: archiveURL, sourceDirectoryURL: sourceDirectoryURL)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL,
           FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        manager = nil
        archiveURL = nil
        sourceDirectoryURL = nil
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testCompareReportsAddedModifiedRemovedAndUnchangedPaths() throws {
        try writeSourceFile("modified.txt", contents: "before", date: baseDate)
        try writeSourceFile("removed.txt", contents: "removed", date: baseDate)
        try writeSourceFile("unchanged.txt", contents: "unchanged", date: baseDate)
        try manager.performBackup()

        try writeSourceFile("modified.txt", contents: "after!", date: baseDate.addingTimeInterval(60))
        try FileManager.default.removeItem(at: sourceDirectoryURL.appendingPathComponent("removed.txt"))
        try writeSourceFile("added.txt", contents: "added", date: baseDate)

        let difference = try manager.compareSourceDirectory()

        XCTAssertEqual(difference.added, ["added.txt"])
        XCTAssertEqual(difference.modified, ["modified.txt"])
        XCTAssertEqual(difference.removed, ["removed.txt"])
        XCTAssertEqual(difference.unchanged, ["unchanged.txt"])
        XCTAssertTrue(difference.hasChanges)
        XCTAssertFalse(difference.isInSync)
    }

    func testCompareWithoutArchiveReportsEverySourceFileAsAdded() throws {
        try writeSourceFile("a.txt", contents: "a", date: baseDate)
        try writeSourceFile("nested/b.txt", contents: "b", date: baseDate)

        let difference = try manager.compareSourceDirectory()

        XCTAssertEqual(difference.added, ["a.txt", "nested/b.txt"])
        XCTAssertTrue(difference.modified.isEmpty)
        XCTAssertTrue(difference.removed.isEmpty)
        XCTAssertTrue(difference.unchanged.isEmpty)
    }

    func testWholeSecondComparisonAvoidsAppendingUnchangedFractionalDate() throws {
        let fractionalDate = Date(timeIntervalSince1970: 1_700_000_000.75)
        try writeSourceFile("fractional.txt", contents: "same", date: fractionalDate)
        try manager.performBackup()
        let firstArchiveSize = try archiveSize()

        let difference = try manager.compareSourceDirectory()
        try manager.performBackup()

        XCTAssertTrue(difference.isInSync)
        XCTAssertEqual(difference.unchanged, ["fractional.txt"])
        XCTAssertEqual(try archiveSize(), firstArchiveSize)
        XCTAssertEqual(try manager.listContents(includingSupersededVersions: true).count, 1)
    }

    func testBackupExcludesNamesDirectoriesAndWildcardPatterns() throws {
        try writeSourceFile("keep.txt", contents: "keep", date: baseDate)
        try writeSourceFile("nested/keep.swift", contents: "keep", date: baseDate)
        try writeSourceFile("node_modules/package/index.js", contents: "dependency", date: baseDate)
        try writeSourceFile("nested/node_modules/other.js", contents: "dependency", date: baseDate)
        try writeSourceFile("build/output.bin", contents: "build", date: baseDate)
        try writeSourceFile("nested/cache.tmp", contents: "cache", date: baseDate)
        try writeSourceFile("generated/deep/result.swift", contents: "generated", date: baseDate)

        let exclusions = ["node_modules", "build/", "**/*.tmp", "generated/**"]
        try manager.performBackup(excluding: exclusions)

        XCTAssertEqual(try manager.listContents().map(\.filename), ["keep.txt", "nested/keep.swift"])
        XCTAssertTrue(try manager.compareSourceDirectory(excluding: exclusions).isInSync)

        let unfilteredDifference = try manager.compareSourceDirectory()
        XCTAssertEqual(unfilteredDifference.added, [
            "build/output.bin",
            "generated/deep/result.swift",
            "nested/cache.tmp",
            "nested/node_modules/other.js",
            "node_modules/package/index.js"
        ])
    }

    func testExclusionsDoNotRemoveFilesAlreadyStoredInArchive() throws {
        try writeSourceFile("cache/data.bin", contents: "cached", date: baseDate)
        try manager.performBackup()

        try manager.performBackup(excluding: ["cache/"])

        XCTAssertEqual(try manager.listContents().map(\.filename), ["cache/data.bin"])
        XCTAssertTrue(try manager.compareSourceDirectory(excluding: ["cache/"]).isInSync)
    }

    private func writeSourceFile(_ path: String, contents: String, date: Date) throws {
        let fileURL = sourceDirectoryURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }

    private func archiveSize() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
    }
}
