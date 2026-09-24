// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarBackupManagerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var sourceDirectoryURL: URL!
    private var archiveURL: URL!
    private var manager: TarBackupManager!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarBackupTests-\(UUID().uuidString)", isDirectory: true)
        sourceDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Source", isDirectory: true)
        archiveURL = temporaryDirectoryURL.appendingPathComponent("backup.tar")

        try FileManager.default.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )
        manager = TarBackupManager(
            archiveURL: archiveURL,
            sourceDirectoryURL: sourceDirectoryURL
        )
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

    func testRepairReturnsEmptyIndexWhenArchiveDoesNotExist() throws {
        let index = try manager.repairAndIndexArchive()

        XCTAssertTrue(index.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testPerformBackupArchivesFilesRecursivelyAndSkipsHiddenFiles() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "root.txt", data: Data("root".utf8), modificationDate: date)
        try writeFile(path: "nested/photo.bin", data: Data(repeating: 7, count: 700), modificationDate: date)
        try writeFile(path: ".hidden", data: Data("secret".utf8), modificationDate: date)

        try manager.performBackup()
        let index = try manager.repairAndIndexArchive()

        XCTAssertEqual(Set(index.keys), ["root.txt", "nested/photo.bin"])
        XCTAssertEqual(index["root.txt"]?.size, 4)
        XCTAssertEqual(index["nested/photo.bin"]?.size, 700)
        XCTAssertNil(index[".hidden"])
    }

    func testPerformBackupDoesNotAppendUnchangedFiles() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "file.txt", data: Data("content".utf8), modificationDate: date)

        try manager.performBackup()
        let sizeAfterFirstBackup = try archiveSize()

        try manager.performBackup()

        XCTAssertEqual(try archiveSize(), sizeAfterFirstBackup)
        XCTAssertEqual(try manager.repairAndIndexArchive().count, 1)
    }

    func testPerformBackupAppendsNewVersionOfModifiedFile() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = originalDate.addingTimeInterval(60)
        try writeFile(path: "file.txt", data: Data("old".utf8), modificationDate: originalDate)
        try manager.performBackup()

        let firstIndex = try manager.repairAndIndexArchive()
        let firstOffset = try XCTUnwrap(firstIndex["file.txt"]?.offset)
        let sizeAfterFirstBackup = try archiveSize()

        try writeFile(path: "file.txt", data: Data("new content".utf8), modificationDate: updatedDate)
        try manager.performBackup()

        let updatedEntry = try XCTUnwrap(manager.repairAndIndexArchive()["file.txt"])
        XCTAssertGreaterThan(updatedEntry.offset, firstOffset)
        XCTAssertEqual(updatedEntry.size, 11)
        XCTAssertEqual(updatedEntry.modificationDate, updatedDate)
        XCTAssertGreaterThan(try archiveSize(), sizeAfterFirstBackup)
        XCTAssertEqual(try archivedData(for: updatedEntry), Data("new content".utf8))
    }

    func testPerformBackupHandlesEmptyFile() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "empty.txt", data: Data(), modificationDate: date)

        try manager.performBackup()

        let entry = try XCTUnwrap(manager.repairAndIndexArchive()["empty.txt"])
        XCTAssertEqual(entry.size, 0)
        XCTAssertEqual(try archiveSize(), 512)
        XCTAssertEqual(try archivedData(for: entry), Data())
    }

    func testRepairTruncatesPartialTail() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "valid.txt", data: Data("valid".utf8), modificationDate: date)
        try manager.performBackup()
        let validArchiveSize = try archiveSize()

        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 100))
        try handle.close()
        XCTAssertGreaterThan(try archiveSize(), validArchiveSize)

        let index = try manager.repairAndIndexArchive()

        XCTAssertEqual(Set(index.keys), ["valid.txt"])
        XCTAssertEqual(try archiveSize(), validArchiveSize)
    }

    func testRepairTruncatesEntryWithIncompleteBody() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "valid.txt", data: Data("valid".utf8), modificationDate: date)
        try manager.performBackup()
        let validArchiveSize = try archiveSize()

        let incompleteHeader = TarHeader.makeHeader(
            relativePath: "incomplete.bin",
            fileSize: 1_024,
            modificationDate: date
        )
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: incompleteHeader)
        try handle.write(contentsOf: Data(repeating: 1, count: 100))
        try handle.close()

        let index = try manager.repairAndIndexArchive()

        XCTAssertEqual(Set(index.keys), ["valid.txt"])
        XCTAssertEqual(try archiveSize(), validArchiveSize)
    }

    func testRepairTruncatesHeaderWithInvalidChecksum() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "valid.txt", data: Data("valid".utf8), modificationDate: date)
        try manager.performBackup()
        let validArchiveSize = try archiveSize()

        var corruptedHeader = TarHeader.makeHeader(
            relativePath: "corrupted.bin",
            fileSize: 10,
            modificationDate: date
        )
        corruptedHeader[200] = 1
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: corruptedHeader)
        try handle.write(contentsOf: Data(repeating: 1, count: 512))
        try handle.close()

        let index = try manager.repairAndIndexArchive()

        XCTAssertEqual(Set(index.keys), ["valid.txt"])
        XCTAssertEqual(try archiveSize(), validArchiveSize)
    }

    func testRepairStopsAtTarEndMarker() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeFile(path: "valid.txt", data: Data("valid".utf8), modificationDate: date)
        try manager.performBackup()

        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 1_024))
        try handle.close()
        let sizeWithEndMarker = try archiveSize()

        let index = try manager.repairAndIndexArchive()

        XCTAssertEqual(Set(index.keys), ["valid.txt"])
        XCTAssertEqual(try archiveSize(), sizeWithEndMarker)
    }

    func testCompactionKeepsOnlyLatestFileVersions() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = originalDate.addingTimeInterval(60)
        try writeFile(path: "file.txt", data: Data("first".utf8), modificationDate: originalDate)
        try manager.performBackup()
        try writeFile(path: "file.txt", data: Data("second".utf8), modificationDate: updatedDate)
        try manager.performBackup()
        let sizeBeforeCompaction = try archiveSize()

        try manager.compactArchive()

        let index = try manager.repairAndIndexArchive()
        let entry = try XCTUnwrap(index["file.txt"])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(entry.offset, 0)
        XCTAssertEqual(entry.size, 6)
        XCTAssertEqual(try archivedData(for: entry), Data("second".utf8))
        XCTAssertLessThan(try archiveSize(), sizeBeforeCompaction)
        XCTAssertEqual(try archiveSize(), 1_024)
    }

    private func writeFile(path: String, data: Data, modificationDate: Date) throws {
        let fileURL = sourceDirectoryURL.appendingPathComponent(path)
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

    private func archivedData(for entry: TarEntryInfo) throws -> Data {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset + 512)
        return try handle.read(upToCount: Int(entry.size)) ?? Data()
    }
}
