// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

public extension TarBackupManager {
    /// Appends one file to the archive without repacking existing entries.
    @discardableResult
    func appendFile(at fileURL: URL, as archivePath: String) throws -> TarEntryInfo {
        try appendFiles([TarAppendItem(fileURL: fileURL, archivePath: archivePath)])[0]
    }

    /// Appends a file from `sourceDirectoryURL`, preserving its relative path.
    @discardableResult
    func appendFile(named relativePath: String) throws -> TarEntryInfo {
        try TarArchivePath.validate(relativePath)
        return try appendFile(
            at: sourceDirectoryURL.appendingPathComponent(relativePath),
            as: relativePath
        )
    }

    /// Appends files from `sourceDirectoryURL`, preserving their relative paths.
    @discardableResult
    func appendFiles(named relativePaths: [String]) throws -> [TarEntryInfo] {
        let items = try relativePaths.map { relativePath in
            try TarArchivePath.validate(relativePath)
            return TarAppendItem(
                fileURL: sourceDirectoryURL.appendingPathComponent(relativePath),
                archivePath: relativePath
            )
        }
        return try appendFiles(items)
    }

    /// Appends a batch of files to the archive in one operation without repacking it.
    ///
    /// Every item is validated before writing starts. If a read or write fails during the
    /// operation, the archive is rolled back to its size before this batch was appended.
    @discardableResult
    func appendFiles(_ items: [TarAppendItem]) throws -> [TarEntryInfo] {
        guard !items.isEmpty else { return [] }

        let preparedItems = try items.map(prepareAppendItem)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: archiveURL.path) {
            guard fileManager.createFile(atPath: archiveURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let initialArchiveSize = try prepareArchiveForAppending()
        let archiveHandle = try FileHandle(forWritingTo: archiveURL)

        do {
            try archiveHandle.seek(toOffset: initialArchiveSize)
            var nextOffset = initialArchiveSize
            var appendedEntries = [TarEntryInfo]()

            for item in preparedItems {
                let header = TarHeader.makeHeader(
                    relativePath: item.archivePath,
                    fileSize: item.size,
                    modificationDate: item.modificationDate
                )
                try archiveHandle.write(contentsOf: header)
                try appendFileBody(item, to: archiveHandle)

                let paddingSize = (512 - (item.size % 512)) % 512
                if paddingSize > 0 {
                    try archiveHandle.write(contentsOf: Data(count: Int(paddingSize)))
                }

                let storedDate = Date(
                    timeIntervalSince1970: TimeInterval(Int64(item.modificationDate.timeIntervalSince1970))
                )
                appendedEntries.append(
                    TarEntryInfo(
                        filename: item.archivePath,
                        offset: nextOffset,
                        size: item.size,
                        modificationDate: storedDate
                    )
                )
                nextOffset += 512 + item.size + paddingSize
            }

            try archiveHandle.close()
            return appendedEntries
        } catch {
            try? archiveHandle.truncate(atOffset: initialArchiveSize)
            try? archiveHandle.close()
            throw error
        }
    }

    /// Deletes one logical path and all of its stored versions from the archive.
    ///
    /// Returns `true` when the path existed. TAR cannot remove a middle entry in place, so
    /// deletion atomically rewrites the archive while copying every entry that remains.
    @discardableResult
    func deleteFile(named relativePath: String) throws -> Bool {
        try !deleteFiles(named: [relativePath]).isEmpty
    }

    /// Deletes several logical paths and all of their stored versions from the archive.
    ///
    /// Missing paths are ignored. The returned paths preserve the request order and contain
    /// only names that were present in the archive.
    @discardableResult
    func deleteFiles(named relativePaths: [String]) throws -> [String] {
        var requestedPaths = [String]()
        var requestedSet = Set<String>()
        for relativePath in relativePaths {
            try TarArchivePath.validate(relativePath)
            if requestedSet.insert(relativePath).inserted {
                requestedPaths.append(relativePath)
            }
        }
        guard !requestedPaths.isEmpty else { return [] }

        let entries = try repairAndListArchiveEntries()
        let storedPaths = Set(entries.map(\.filename))
        let deletedPaths = requestedPaths.filter(storedPaths.contains)
        guard !deletedPaths.isEmpty else { return [] }

        try rewriteArchive(entries: entries.filter { !requestedSet.contains($0.filename) })
        return deletedPaths
    }
}

private extension TarBackupManager {
    struct PreparedAppendItem {
        let fileURL: URL
        let archivePath: String
        let size: UInt64
        let modificationDate: Date
    }

    func prepareAppendItem(_ item: TarAppendItem) throws -> PreparedAppendItem {
        try TarArchivePath.validate(item.archivePath)

        let normalizedSourceURL = item.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedArchiveURL = archiveURL.standardizedFileURL.resolvingSymlinksInPath()
        guard normalizedSourceURL != normalizedArchiveURL else {
            throw TarBackupError.sourceFileIsArchive(item.fileURL.path)
        }

        let values = try item.fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw TarBackupError.sourceFileNotRegular(item.fileURL.path)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: item.fileURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw TarBackupError.sourceFileNotRegular(item.fileURL.path)
        }

        return PreparedAppendItem(
            fileURL: item.fileURL,
            archivePath: item.archivePath,
            size: size,
            modificationDate: modificationDate
        )
    }

    func appendFileBody(_ item: PreparedAppendItem, to archiveHandle: FileHandle) throws {
        let sourceHandle = try FileHandle(forReadingFrom: item.fileURL)
        defer { try? sourceHandle.close() }
        var remainingBytes = item.size

        while remainingBytes > 0 {
            let requestedCount = Int(min(remainingBytes, 64 * 1_024))
            let data = try sourceHandle.read(upToCount: requestedCount) ?? Data()
            guard !data.isEmpty else {
                throw TarBackupError.sourceFileChanged(item.fileURL.path)
            }
            try archiveHandle.write(contentsOf: data)
            remainingBytes -= UInt64(data.count)
        }
    }

    func rewriteArchive(entries: [TarEntryInfo]) throws {
        let fileManager = FileManager.default
        let temporaryURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".tarbackup-\(UUID().uuidString).tmp")

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let readHandle = try FileHandle(forReadingFrom: archiveURL)
        let writeHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            for entry in entries {
                let paddedSize = entry.size + (512 - (entry.size % 512)) % 512
                try copyBytes(
                    count: 512 + paddedSize,
                    fromOffset: entry.offset,
                    source: readHandle,
                    destination: writeHandle,
                    entryPath: entry.filename
                )
            }

            try writeHandle.close()
            try readHandle.close()
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporaryURL)
        } catch {
            try? writeHandle.close()
            try? readHandle.close()
            throw error
        }
    }

    func copyBytes(
        count: UInt64,
        fromOffset offset: UInt64,
        source: FileHandle,
        destination: FileHandle,
        entryPath: String
    ) throws {
        try source.seek(toOffset: offset)
        var remainingBytes = count

        while remainingBytes > 0 {
            let requestedCount = Int(min(remainingBytes, 64 * 1_024))
            let data = try source.read(upToCount: requestedCount) ?? Data()
            guard !data.isEmpty else {
                throw TarBackupError.unexpectedEndOfArchive(entryPath)
            }
            try destination.write(contentsOf: data)
            remainingBytes -= UInt64(data.count)
        }
    }
}
