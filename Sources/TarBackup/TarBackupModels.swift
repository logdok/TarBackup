// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

/// A file on disk and the relative path it should have inside a TAR archive.
public struct TarAppendItem: Equatable, Sendable {
    public let fileURL: URL
    public let archivePath: String

    public init(fileURL: URL, archivePath: String) {
        self.fileURL = fileURL
        self.archivePath = archivePath
    }
}

/// A metadata-based comparison between the latest archive entries and a source directory.
public struct TarArchiveDiff: Equatable, Sendable {
    /// Paths present on disk but absent from the archive.
    public let added: [String]

    /// Paths present in both locations whose size or modification time differs.
    public let modified: [String]

    /// Paths present in the archive but absent from disk.
    public let removed: [String]

    /// Paths whose size and modification time match.
    public let unchanged: [String]

    public var hasChanges: Bool {
        !added.isEmpty || !modified.isEmpty || !removed.isEmpty
    }

    public var isInSync: Bool { !hasChanges }

    public init(
        added: [String],
        modified: [String],
        removed: [String],
        unchanged: [String]
    ) {
        self.added = added
        self.modified = modified
        self.removed = removed
        self.unchanged = unchanged
    }
}
