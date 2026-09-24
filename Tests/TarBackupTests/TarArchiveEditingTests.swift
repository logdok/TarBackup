// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarArchiveEditingTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var sourceDirectoryURL: URL!
    private var archiveURL: URL!
    private var manager: TarBackupManager!
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarArchiveEditingTests-\(UUID().uuidString)", isDirectory: true)
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

    func testAppendFileCanMapAnArbitraryFileToAnArchivePath() throws {
        let externalURL = temporaryDirectoryURL.appendingPathComponent("external.bin")
        let contents = Data([0, 1, 2, 3, 255])
        try write(contents, to: externalURL, modificationDate: baseDate)

        let entry = try manager.appendFile(at: externalURL, as: "manual/data.bin")

        XCTAssertEqual(entry.filename, "manual/data.bin")
        XCTAssertEqual(entry.offset, 0)
        XCTAssertEqual(entry.size, UInt64(contents.count))
        XCTAssertEqual(try manager.listContents(), [entry])

        let destinationURL = temporaryDirectoryURL.appendingPathComponent("Extracted", isDirectory: true)
        let extractedURL = try manager.extractFile(named: entry.filename, to: destinationURL)
        XCTAssertEqual(try Data(contentsOf: extractedURL), contents)
    }

    func testAppendFilesAddsBatchWithoutChangingExistingArchiveBytes() throws {
        try writeSourceFile("existing.txt", contents: Data("existing".utf8), date: baseDate)
        try manager.appendFile(named: "existing.txt")
        let originalArchive = try Data(contentsOf: archiveURL)

        try writeSourceFile("one.txt", contents: Data("one".utf8), date: baseDate)
        try writeSourceFile("nested/two.txt", contents: Data("two".utf8), date: baseDate)
        let entries = try manager.appendFiles(named: ["one.txt", "nested/two.txt"])
        let updatedArchive = try Data(contentsOf: archiveURL)

        XCTAssertEqual(updatedArchive.prefix(originalArchive.count), originalArchive)
        XCTAssertEqual(entries.map(\.filename), ["one.txt", "nested/two.txt"])
        XCTAssertEqual(Set(try manager.listContents().map(\.filename)), [
            "existing.txt", "one.txt", "nested/two.txt"
        ])
    }

    func testAppendStreamsFilesLargerThanOneChunk() throws {
        let contents = Data((0..<150_000).map { UInt8($0 % 251) })
        try writeSourceFile("large.bin", contents: contents, date: baseDate)

        try manager.appendFile(named: "large.bin")

        let destinationURL = temporaryDirectoryURL.appendingPathComponent("Extracted", isDirectory: true)
        let extractedURL = try manager.extractFile(named: "large.bin", to: destinationURL)
        XCTAssertEqual(try Data(contentsOf: extractedURL), contents)
    }

    func testAppendRemovesStandardEndMarkersBeforeWritingNewEntry() throws {
        try writeSourceFile("first.txt", contents: Data("first".utf8), date: baseDate)
        try manager.appendFile(named: "first.txt")

        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 1_024))
        try handle.close()

        try writeSourceFile("second.txt", contents: Data("second".utf8), date: baseDate)
        try manager.appendFile(named: "second.txt")

        XCTAssertEqual(try archiveSize(), 2_048)
        XCTAssertEqual(try manager.listContents().map(\.filename), ["first.txt", "second.txt"])
    }

    func testAppendingSamePathCreatesNewVersionAndLatestEntryWins() throws {
        try writeSourceFile("versioned.txt", contents: Data("old".utf8), date: baseDate)
        try manager.appendFile(named: "versioned.txt")
        try writeSourceFile(
            "versioned.txt",
            contents: Data("new version".utf8),
            date: baseDate.addingTimeInterval(60)
        )
        try manager.appendFile(named: "versioned.txt")

        XCTAssertEqual(
            try manager.listContents(includingSupersededVersions: true).map(\.filename),
            ["versioned.txt", "versioned.txt"]
        )
        XCTAssertEqual(try manager.listContents().first?.size, 11)

        let destinationURL = temporaryDirectoryURL.appendingPathComponent("Extracted", isDirectory: true)
        let extractedURL = try manager.extractFile(named: "versioned.txt", to: destinationURL)
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), "new version")
    }

    func testAppendBatchValidatesEveryItemBeforeChangingArchive() throws {
        try writeSourceFile("existing.txt", contents: Data("existing".utf8), date: baseDate)
        try manager.appendFile(named: "existing.txt")
        let originalArchive = try Data(contentsOf: archiveURL)

        let validURL = try writeSourceFile("valid.txt", contents: Data("valid".utf8), date: baseDate)
        let directoryURL = sourceDirectoryURL.appendingPathComponent("Directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try manager.appendFiles([
                TarAppendItem(fileURL: validURL, archivePath: "valid.txt"),
                TarAppendItem(fileURL: directoryURL, archivePath: "invalid.txt")
            ])
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .sourceFileNotRegular(directoryURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), originalArchive)
        XCTAssertEqual(try manager.listContents().map(\.filename), ["existing.txt"])
    }

    func testAppendRejectsPathLongerThanUstarNameField() throws {
        let fileURL = try writeSourceFile("short.txt", contents: Data(), date: baseDate)
        let longPath = String(repeating: "a", count: 101)

        XCTAssertThrowsError(try manager.appendFile(at: fileURL, as: longPath)) { error in
            XCTAssertEqual(error as? TarBackupError, .archivePathTooLong(longPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testAppendAcceptsExactly100UTF8BytesWithoutTruncation() throws {
        let fileURL = try writeSourceFile("short.txt", contents: Data("data".utf8), date: baseDate)
        let exactPath = String(repeating: "é", count: 50)
        XCTAssertEqual(exactPath.utf8.count, 100)

        try manager.appendFile(at: fileURL, as: exactPath)

        XCTAssertEqual(try manager.listContents().map(\.filename), [exactPath])
    }

    func testAppendRejectsUsingArchiveAsItsOwnSource() throws {
        try writeSourceFile("existing.txt", contents: Data("existing".utf8), date: baseDate)
        try manager.appendFile(named: "existing.txt")
        let originalArchive = try Data(contentsOf: archiveURL)

        XCTAssertThrowsError(try manager.appendFile(at: archiveURL, as: "copy.tar")) { error in
            XCTAssertEqual(error as? TarBackupError, .sourceFileIsArchive(archiveURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), originalArchive)
    }

    func testDeleteFilesRemovesAllVersionsAndPreservesOtherEntries() throws {
        try writeSourceFile("a.txt", contents: Data("a".utf8), date: baseDate)
        try writeSourceFile("b.txt", contents: Data("old b".utf8), date: baseDate)
        try writeSourceFile("c.txt", contents: Data("keep c".utf8), date: baseDate)
        try manager.appendFiles(named: ["a.txt", "b.txt", "c.txt"])
        try writeSourceFile("b.txt", contents: Data("new b".utf8), date: baseDate.addingTimeInterval(60))
        try writeSourceFile("c.txt", contents: Data("new c".utf8), date: baseDate.addingTimeInterval(60))
        try manager.appendFiles(named: ["b.txt", "c.txt"])

        let deleted = try manager.deleteFiles(named: ["b.txt", "missing.txt", "a.txt", "b.txt"])

        XCTAssertEqual(deleted, ["b.txt", "a.txt"])
        XCTAssertEqual(try manager.listContents().map(\.filename), ["c.txt"])
        XCTAssertEqual(
            try manager.listContents(includingSupersededVersions: true).map(\.filename),
            ["c.txt", "c.txt"]
        )
        let destinationURL = temporaryDirectoryURL.appendingPathComponent("Extracted", isDirectory: true)
        let extractedURL = try manager.extractFile(named: "c.txt", to: destinationURL)
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), "new c")
    }

    func testDeleteMissingFileDoesNotRewriteArchive() throws {
        try writeSourceFile("keep.txt", contents: Data("keep".utf8), date: baseDate)
        try manager.appendFile(named: "keep.txt")
        let originalArchive = try Data(contentsOf: archiveURL)

        XCTAssertFalse(try manager.deleteFile(named: "missing.txt"))
        XCTAssertEqual(try Data(contentsOf: archiveURL), originalArchive)
    }

    func testDeleteLastFileLeavesValidEmptyArchive() throws {
        try writeSourceFile("only.txt", contents: Data("only".utf8), date: baseDate)
        try manager.appendFile(named: "only.txt")

        XCTAssertTrue(try manager.deleteFile(named: "only.txt"))
        XCTAssertEqual(try archiveSize(), 0)
        XCTAssertTrue(try manager.listContents().isEmpty)
    }

    @discardableResult
    private func writeSourceFile(_ path: String, contents: Data, date: Date) throws -> URL {
        let fileURL = sourceDirectoryURL.appendingPathComponent(path)
        try write(contents, to: fileURL, modificationDate: date)
        return fileURL
    }

    private func write(_ data: Data, to fileURL: URL, modificationDate: Date) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: fileURL.path
        )
    }

    private func archiveSize() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
    }
}
