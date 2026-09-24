// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

public extension TarBackupManager {
    /// Extracts one file from the archive and returns its destination URL.
    @discardableResult
    func extractFile(
        named relativePath: String,
        to destinationDirectoryURL: URL,
        overwriteExisting: Bool = true
    ) throws -> URL {
        try validateArchivePath(relativePath)

        guard let entry = try repairAndIndexArchive()[relativePath] else {
            throw TarBackupError.archiveEntryNotFound(relativePath)
        }

        return try extract(entries: [entry], to: destinationDirectoryURL, overwriteExisting: overwriteExisting)[0]
    }

    /// Extracts several explicitly named files from the archive.
    ///
    /// All names are validated before extraction starts. Duplicate names are extracted once,
    /// in the order of their first appearance.
    @discardableResult
    func extractFiles(
        named relativePaths: [String],
        to destinationDirectoryURL: URL,
        overwriteExisting: Bool = true
    ) throws -> [URL] {
        var requestedPaths = [String]()
        var seenPaths = Set<String>()
        for relativePath in relativePaths {
            try validateArchivePath(relativePath)
            if seenPaths.insert(relativePath).inserted {
                requestedPaths.append(relativePath)
            }
        }

        let index = try repairAndIndexArchive()
        let missingPaths = requestedPaths.filter { index[$0] == nil }
        guard missingPaths.isEmpty else {
            throw TarBackupError.archiveEntriesNotFound(missingPaths)
        }

        let entries = requestedPaths.compactMap { index[$0] }
        return try extract(entries: entries, to: destinationDirectoryURL, overwriteExisting: overwriteExisting)
    }

    /// Extracts the latest version of every file whose archive path matches a wildcard pattern.
    ///
    /// `*` matches characters inside one path component, `?` matches one character inside a
    /// component, and `**` can cross directory separators. For example, `images/**/*.png`
    /// matches PNG files directly in `images` and in all of its nested directories.
    @discardableResult
    func extract(
        matching pattern: String,
        to destinationDirectoryURL: URL,
        overwriteExisting: Bool = true
    ) throws -> [URL] {
        let pathPattern = TarPathPattern(pattern)
        let entries = try listContents().filter { pathPattern.matches($0.filename) }
        return try extract(entries: entries, to: destinationDirectoryURL, overwriteExisting: overwriteExisting)
    }

    /// Extracts the latest version of every file below an archive subdirectory.
    ///
    /// The subdirectory itself is preserved below `destinationDirectoryURL`.
    @discardableResult
    func extractSubdirectory(
        _ relativePath: String,
        to destinationDirectoryURL: URL,
        overwriteExisting: Bool = true
    ) throws -> [URL] {
        let subdirectory = relativePath.hasSuffix("/")
            ? String(relativePath.dropLast())
            : relativePath

        guard !subdirectory.isEmpty else {
            throw TarBackupError.invalidSubdirectory(relativePath)
        }

        do {
            try validateArchivePath(subdirectory)
        } catch {
            throw TarBackupError.invalidSubdirectory(relativePath)
        }

        let prefix = subdirectory + "/"
        let entries = try listContents().filter { $0.filename.hasPrefix(prefix) }
        return try extract(entries: entries, to: destinationDirectoryURL, overwriteExisting: overwriteExisting)
    }
}

private extension TarBackupManager {
    func extract(
        entries: [TarEntryInfo],
        to destinationDirectoryURL: URL,
        overwriteExisting: Bool
    ) throws -> [URL] {
        guard !entries.isEmpty else { return [] }

        for entry in entries {
            try validateArchivePath(entry.filename)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        let destinationRootURL = destinationDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let archiveHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? archiveHandle.close() }

        var extractedURLs = [URL]()
        for entry in entries {
            let destinationURL = try prepareDestination(
                for: entry.filename,
                below: destinationRootURL,
                overwriteExisting: overwriteExisting
            )
            try extract(entry: entry, from: archiveHandle, to: destinationURL)
            extractedURLs.append(destinationURL)
        }

        return extractedURLs
    }

    func validateArchivePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/") else {
            throw TarBackupError.invalidArchivePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TarBackupError.invalidArchivePath(relativePath)
        }
    }

    func prepareDestination(
        for relativePath: String,
        below destinationRootURL: URL,
        overwriteExisting: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let components = relativePath.split(separator: "/").map(String.init)
        var parentURL = destinationRootURL

        for component in components.dropLast() {
            let directoryURL = parentURL.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
                let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard isDirectory.boolValue, values.isSymbolicLink != true else {
                    throw TarBackupError.invalidArchivePath(relativePath)
                }
            } else {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            }
            parentURL = directoryURL
        }

        let destinationURL = parentURL.appendingPathComponent(components.last!)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            let values = try destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard !isDirectory.boolValue, values.isSymbolicLink != true else {
                throw TarBackupError.invalidArchivePath(relativePath)
            }
            guard overwriteExisting else {
                throw TarBackupError.destinationAlreadyExists(relativePath)
            }
        }

        return destinationURL
    }

    func extract(entry: TarEntryInfo, from archiveHandle: FileHandle, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".tarbackup-\(UUID().uuidString).tmp")

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let destinationHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try archiveHandle.seek(toOffset: entry.offset + 512)
            var remainingBytes = entry.size

            while remainingBytes > 0 {
                let requestedCount = Int(min(remainingBytes, 64 * 1_024))
                let data = try archiveHandle.read(upToCount: requestedCount) ?? Data()
                guard !data.isEmpty else {
                    throw TarBackupError.unexpectedEndOfArchive(entry.filename)
                }
                try destinationHandle.write(contentsOf: data)
                remainingBytes -= UInt64(data.count)
            }
            try destinationHandle.close()
        } catch {
            try? destinationHandle.close()
            throw error
        }

        try fileManager.setAttributes(
            [.modificationDate: entry.modificationDate],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}
