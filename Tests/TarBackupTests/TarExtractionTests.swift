// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarExtractionTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var sourceDirectoryURL: URL!
    private var archiveURL: URL!
    private var destinationDirectoryURL: URL!
    private var manager: TarBackupManager!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarExtractionTests-\(UUID().uuidString)", isDirectory: true)
        sourceDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Source", isDirectory: true)
        archiveURL = temporaryDirectoryURL.appendingPathComponent("backup.tar")
        destinationDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Extracted", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        manager = TarBackupManager(archiveURL: archiveURL, sourceDirectoryURL: sourceDirectoryURL)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL,
           FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        manager = nil
        destinationDirectoryURL = nil
        archiveURL = nil
        sourceDirectoryURL = nil
        temporaryDirectoryURL = nil

        try super.tearDownWithError()
    }

    func testListContentsReturnsLatestVersionsSortedByPath() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = originalDate.addingTimeInterval(60)
        try writeSourceFile("z.txt", contents: "old", modificationDate: originalDate)
        try writeSourceFile("a.txt", contents: "only", modificationDate: originalDate)
        try manager.performBackup()
        try writeSourceFile("z.txt", contents: "newer", modificationDate: updatedDate)
        try manager.performBackup()

        let logicalEntries = try manager.listContents()
        let physicalEntries = try manager.listContents(includingSupersededVersions: true)

        XCTAssertEqual(logicalEntries.map(\.filename), ["a.txt", "z.txt"])
        XCTAssertEqual(logicalEntries.last?.size, 5)
        XCTAssertEqual(logicalEntries.last?.modificationDate, updatedDate)
        XCTAssertEqual(physicalEntries.filter { $0.filename == "z.txt" }.count, 2)
        XCTAssertEqual(physicalEntries.count, 3)
    }

    func testExtractFileRestoresContentsPathAndModificationDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("documents/report.txt", contents: "quarterly report", modificationDate: date)
        try manager.performBackup()

        let extractedURL = try manager.extractFile(
            named: "documents/report.txt",
            to: destinationDirectoryURL
        )

        XCTAssertEqual(extractedURL, destinationDirectoryURL.appendingPathComponent("documents/report.txt"))
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), "quarterly report")
        let attributes = try FileManager.default.attributesOfItem(atPath: extractedURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, date)
    }

    func testExtractFileStreamsDataLargerThanOneReadChunk() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data((0..<150_000).map { UInt8($0 % 251) })
        try writeSourceFile("large.bin", data: data, modificationDate: date)
        try manager.performBackup()

        let extractedURL = try manager.extractFile(named: "large.bin", to: destinationDirectoryURL)

        XCTAssertEqual(try Data(contentsOf: extractedURL), data)
    }

    func testExtractFileReportsMissingEntry() throws {
        XCTAssertThrowsError(
            try manager.extractFile(named: "missing.txt", to: destinationDirectoryURL)
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .archiveEntryNotFound("missing.txt"))
        }
    }

    func testExtractFilesRestoresSeveralNamedFilesOnlyOnce() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("one.txt", contents: "one", modificationDate: date)
        try writeSourceFile("nested/two.txt", contents: "two", modificationDate: date)
        try writeSourceFile("unused.txt", contents: "unused", modificationDate: date)
        try manager.performBackup()

        let extractedURLs = try manager.extractFiles(
            named: ["nested/two.txt", "one.txt", "nested/two.txt"],
            to: destinationDirectoryURL
        )

        XCTAssertEqual(
            extractedURLs.map(\.path),
            [
                destinationDirectoryURL.appendingPathComponent("nested/two.txt").path,
                destinationDirectoryURL.appendingPathComponent("one.txt").path
            ]
        )
        XCTAssertEqual(try String(contentsOf: extractedURLs[0], encoding: .utf8), "two")
        XCTAssertEqual(try String(contentsOf: extractedURLs[1], encoding: .utf8), "one")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationDirectoryURL.appendingPathComponent("unused.txt").path
        ))
    }

    func testExtractFilesChecksAllRequestedNamesBeforeWritingAnything() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("present.txt", contents: "present", modificationDate: date)
        try manager.performBackup()

        XCTAssertThrowsError(
            try manager.extractFiles(
                named: ["present.txt", "missing.txt", "also-missing.txt"],
                to: destinationDirectoryURL
            )
        ) { error in
            XCTAssertEqual(
                error as? TarBackupError,
                .archiveEntriesNotFound(["missing.txt", "also-missing.txt"])
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationDirectoryURL.appendingPathComponent("present.txt").path
        ))
    }

    func testWildcardExtractionSupportsSingleAndRecursiveWildcards() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("root.txt", contents: "root", modificationDate: date)
        try writeSourceFile("images/a.png", contents: "a", modificationDate: date)
        try writeSourceFile("images/ab.png", contents: "ab", modificationDate: date)
        try writeSourceFile("images/nested/b.png", contents: "b", modificationDate: date)
        try writeSourceFile("images/nested/readme.txt", contents: "readme", modificationDate: date)
        try manager.performBackup()

        let singleCharacterMatches = try manager.extract(
            matching: "images/?.png",
            to: destinationDirectoryURL.appendingPathComponent("Single")
        )
        let recursiveMatches = try manager.extract(
            matching: "images/**/*.png",
            to: destinationDirectoryURL.appendingPathComponent("Recursive")
        )
        let allTextMatches = try manager.extract(
            matching: "**/*.txt",
            to: destinationDirectoryURL.appendingPathComponent("Text")
        )

        XCTAssertEqual(singleCharacterMatches.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(
            relativePaths(of: recursiveMatches, below: destinationDirectoryURL.appendingPathComponent("Recursive")),
            ["images/a.png", "images/ab.png", "images/nested/b.png"]
        )
        XCTAssertEqual(
            relativePaths(of: allTextMatches, below: destinationDirectoryURL.appendingPathComponent("Text")),
            ["images/nested/readme.txt", "root.txt"]
        )
    }

    func testExtractSubdirectoryPreservesSubdirectoryAndExcludesSimilarPrefix() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("docs/readme.txt", contents: "readme", modificationDate: date)
        try writeSourceFile("docs/guides/start.md", contents: "start", modificationDate: date)
        try writeSourceFile("docs-old/legacy.txt", contents: "legacy", modificationDate: date)
        try manager.performBackup()

        let extractedURLs = try manager.extractSubdirectory(
            "docs/",
            to: destinationDirectoryURL
        )

        XCTAssertEqual(
            relativePaths(of: extractedURLs, below: destinationDirectoryURL),
            ["docs/guides/start.md", "docs/readme.txt"]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationDirectoryURL.appendingPathComponent("docs-old/legacy.txt").path
        ))
    }

    func testExtractSubdirectoryRejectsUnsafePath() throws {
        XCTAssertThrowsError(
            try manager.extractSubdirectory("../private", to: destinationDirectoryURL)
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .invalidSubdirectory("../private"))
        }
    }

    func testExtractionUsesLatestArchivedVersion() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("file.txt", contents: "old", modificationDate: originalDate)
        try manager.performBackup()
        try writeSourceFile("file.txt", contents: "latest", modificationDate: originalDate.addingTimeInterval(60))
        try manager.performBackup()

        let extractedURL = try manager.extractFile(named: "file.txt", to: destinationDirectoryURL)

        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), "latest")
    }

    func testExtractionCanRefuseToOverwriteExistingFile() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("file.txt", contents: "archived", modificationDate: date)
        try manager.performBackup()
        let existingURL = destinationDirectoryURL.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingURL)

        XCTAssertThrowsError(
            try manager.extractFile(
                named: "file.txt",
                to: destinationDirectoryURL,
                overwriteExisting: false
            )
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .destinationAlreadyExists("file.txt"))
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "existing")
    }

    func testExtractionOverwritesExistingRegularFileByDefault() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("file.txt", contents: "archived", modificationDate: date)
        try manager.performBackup()
        let existingURL = destinationDirectoryURL.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingURL)

        let extractedURL = try manager.extractFile(named: "file.txt", to: destinationDirectoryURL)

        XCTAssertEqual(extractedURL, existingURL)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "archived")
    }

    func testExtractionRejectsArchivePathTraversal() throws {
        let outsideURL = temporaryDirectoryURL.appendingPathComponent("escape.txt")
        try writeArchiveEntry(path: "../escape.txt", contents: Data("escape".utf8))

        XCTAssertThrowsError(
            try manager.extract(matching: "**", to: destinationDirectoryURL)
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .invalidArchivePath("../escape.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testExtractionRejectsSymbolicLinkInsideDestination() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writeSourceFile("nested/file.txt", contents: "archived", modificationDate: date)
        try manager.performBackup()

        let outsideDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destinationDirectoryURL.appendingPathComponent("nested"),
            withDestinationURL: outsideDirectoryURL
        )

        XCTAssertThrowsError(
            try manager.extractFile(named: "nested/file.txt", to: destinationDirectoryURL)
        ) { error in
            XCTAssertEqual(error as? TarBackupError, .invalidArchivePath("nested/file.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideDirectoryURL.appendingPathComponent("file.txt").path
        ))
    }

    func testNoMatchesAndEmptyFileListProduceNoOutput() throws {
        XCTAssertEqual(
            try manager.extract(matching: "*.missing", to: destinationDirectoryURL),
            []
        )
        XCTAssertEqual(
            try manager.extractFiles(named: [], to: destinationDirectoryURL),
            []
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationDirectoryURL.path))
    }

    private func writeSourceFile(_ path: String, contents: String, modificationDate: Date) throws {
        try writeSourceFile(path, data: Data(contents.utf8), modificationDate: modificationDate)
    }

    private func writeSourceFile(_ path: String, data: Data, modificationDate: Date) throws {
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

    private func writeArchiveEntry(path: String, contents: Data) throws {
        let header = TarHeader.makeHeader(
            relativePath: path,
            fileSize: UInt64(contents.count),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var archive = header
        archive.append(contents)
        archive.append(Data(count: (512 - contents.count % 512) % 512))
        try archive.write(to: archiveURL)
    }

    private func relativePaths(of urls: [URL], below rootURL: URL) -> [String] {
        let prefix = rootURL.path + "/"
        return urls.map { String($0.path.dropFirst(prefix.count)) }.sorted()
    }
}
