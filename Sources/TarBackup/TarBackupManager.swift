// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

/// Metadata for a regular file stored in a TAR archive.
public struct TarEntryInfo: Equatable, Sendable {
    public let filename: String
    public let offset: UInt64
    public let size: UInt64
    public let modificationDate: Date
}

public final class TarBackupManager {
    public let archiveURL: URL
    public let sourceDirectoryURL: URL
    private let fileManager = FileManager.default

    public init(archiveURL: URL, sourceDirectoryURL: URL) {
        self.archiveURL = archiveURL
        self.sourceDirectoryURL = sourceDirectoryURL
    }

    /// Performs an incremental backup, optionally excluding matching files and directories.
    ///
    /// Exclusion patterns use the same `*`, `?`, and `**` wildcards as extraction.
    /// A pattern without a slash is matched against every path component, making values
    /// such as `node_modules`, `.git`, and `*.tmp` convenient directory-wide exclusions.
    public func performBackup(excluding exclusionPatterns: [String] = []) throws {
        let index = try repairAndIndexArchive()
        let sourceFiles = try scanSourceDirectory(excluding: exclusionPatterns)
        var filesToAppend = [TarAppendItem]()

        for (relativePath, fileURL) in sourceFiles {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let fileDate = attributes[.modificationDate] as? Date,
                  let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else { continue }

            let needsBackup: Bool
            if let existingEntry = index[relativePath] {
                needsBackup = fileSize != existingEntry.size
                    || Int64(fileDate.timeIntervalSince1970)
                    != Int64(existingEntry.modificationDate.timeIntervalSince1970)
            } else {
                needsBackup = true
            }

            if needsBackup {
                filesToAppend.append(TarAppendItem(fileURL: fileURL, archivePath: relativePath))
            }
        }

        if !filesToAppend.isEmpty {
            try appendFiles(filesToAppend)
        }
    }

    /// Compacts the archive by copying only the latest version of each file into a new file.
    public func compactArchive() throws {
        let index = try repairAndIndexArchive()
        let tempURL = archiveURL.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).tmp.tar")

        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }

        let readHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? readHandle.close() }

        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? writeHandle.close() }

        for (_, entry) in index {
            try readHandle.seek(toOffset: entry.offset)
            let paddedSize = entry.size + (512 - (entry.size % 512)) % 512
            let totalBlockSize = 512 + paddedSize

            let blockData = try readHandle.read(upToCount: Int(totalBlockSize)) ?? Data()
            if blockData.count == Int(totalBlockSize) {
                try writeHandle.seekToEnd()
                try writeHandle.write(contentsOf: blockData)
            }
        }

        try writeHandle.close()
        try readHandle.close()

        _ = try fileManager.replaceItemAt(archiveURL, withItemAt: tempURL)
    }

    // MARK: - Internal Recovery & Inspection

    /// Scans TAR headers, truncates broken tails, and builds a map of active files.
    @discardableResult
    public func repairAndIndexArchive() throws -> [String: TarEntryInfo] {
        try latestEntryIndex(from: repairAndListArchiveEntries())
    }

    /// Returns archive contents. By default, only the latest version of each path is returned.
    ///
    /// Set `includingSupersededVersions` to `true` to inspect every physical entry in
    /// append order, including older versions of files that were backed up again.
    public func listContents(includingSupersededVersions: Bool = false) throws -> [TarEntryInfo] {
        let entries = try repairAndListArchiveEntries()
        if includingSupersededVersions {
            return entries
        }

        return latestEntryIndex(from: entries).values.sorted { $0.filename < $1.filename }
    }

    func repairAndListArchiveEntries() throws -> [TarEntryInfo] {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return [] }

        let readHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? readHandle.close() }

        var entries = [TarEntryInfo]()
        var currentOffset: UInt64 = 0
        let totalFileSize = try readHandle.seekToEnd()

        try readHandle.seek(toOffset: 0)

        while currentOffset < totalFileSize {
            if totalFileSize - currentOffset < 512 {
                try truncateTar(at: currentOffset)
                break
            }

            let headerData = try readHandle.read(upToCount: 512) ?? Data()
            if headerData.allSatisfy({ $0 == 0 }) {
                break // End of archive marker
            }

            guard let header = TarHeader.parse(from: headerData), header.isValidChecksum else {
                try truncateTar(at: currentOffset)
                break
            }

            let paddedSize = header.fileSize + (512 - (header.fileSize % 512)) % 512
            let nextOffset = currentOffset + 512 + paddedSize

            if nextOffset > totalFileSize {
                // Incomplete file write detected
                try truncateTar(at: currentOffset)
                break
            }

            entries.append(TarEntryInfo(
                filename: header.filename,
                offset: currentOffset,
                size: header.fileSize,
                modificationDate: header.modificationDate
            ))

            currentOffset = nextOffset
            try readHandle.seek(toOffset: currentOffset)
        }

        return entries
    }

    private func latestEntryIndex(from entries: [TarEntryInfo]) -> [String: TarEntryInfo] {
        var index = [String: TarEntryInfo]()
        for entry in entries {
            // POSIX rule: a later entry with the same name supersedes an earlier one.
            index[entry.filename] = entry
        }
        return index
    }

    func scanSourceDirectory(excluding exclusionPatterns: [String]) throws -> [String: URL] {
        var results = [String: URL]()
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let exclusionRules = TarExclusionRules(patterns: exclusionPatterns)
        let normalizedSourcePath = sourceDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let sourcePathPrefix = normalizedSourcePath + "/"

        guard let enumerator = fileManager.enumerator(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let normalizedFilePath = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard normalizedFilePath.hasPrefix(sourcePathPrefix) else { continue }

            let relativePath = String(normalizedFilePath.dropFirst(sourcePathPrefix.count))
            let isDirectory = resourceValues.isDirectory == true
            if exclusionRules.excludes(relativePath, isDirectory: isDirectory) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if resourceValues.isRegularFile == true {
                results[relativePath] = fileURL
            }
        }
        return results
    }

    /// Removes standard TAR end markers and returns the byte offset for the next entry.
    func prepareArchiveForAppending() throws -> UInt64 {
        let entries = try repairAndListArchiveEntries()
        let appendOffset: UInt64
        if let lastEntry = entries.last {
            let paddedSize = lastEntry.size + (512 - (lastEntry.size % 512)) % 512
            appendOffset = lastEntry.offset + 512 + paddedSize
        } else {
            appendOffset = 0
        }

        guard fileManager.fileExists(atPath: archiveURL.path) else { return appendOffset }
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        let archiveSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if archiveSize != appendOffset {
            try truncateTar(at: appendOffset)
        }
        return appendOffset
    }

    private func truncateTar(at offset: UInt64) throws {
        let writeHandle = try FileHandle(forWritingTo: archiveURL)
        try writeHandle.truncate(atOffset: offset)
        try writeHandle.close()
    }
}
