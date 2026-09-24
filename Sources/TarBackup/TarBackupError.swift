// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

public enum TarBackupError: Error, Equatable, LocalizedError {
    case archiveEntryNotFound(String)
    case archiveEntriesNotFound([String])
    case destinationAlreadyExists(String)
    case invalidArchivePath(String)
    case archivePathTooLong(String)
    case invalidSubdirectory(String)
    case sourceFileIsArchive(String)
    case sourceFileChanged(String)
    case sourceFileNotRegular(String)
    case unexpectedEndOfArchive(String)

    public var errorDescription: String? {
        switch self {
        case .archiveEntryNotFound(let path):
            return "Archive entry not found: \(path)"
        case .archiveEntriesNotFound(let paths):
            return "Archive entries not found: \(paths.joined(separator: ", "))"
        case .destinationAlreadyExists(let path):
            return "Destination already exists: \(path)"
        case .invalidArchivePath(let path):
            return "Unsafe or invalid archive path: \(path)"
        case .archivePathTooLong(let path):
            return "Archive path exceeds the 100-byte ustar name field: \(path)"
        case .invalidSubdirectory(let path):
            return "Invalid archive subdirectory: \(path)"
        case .sourceFileIsArchive(let path):
            return "The archive cannot be appended to itself: \(path)"
        case .sourceFileChanged(let path):
            return "Source file changed while it was being appended: \(path)"
        case .sourceFileNotRegular(let path):
            return "Append source is not a regular file: \(path)"
        case .unexpectedEndOfArchive(let path):
            return "Unexpected end of archive while extracting: \(path)"
        }
    }
}
