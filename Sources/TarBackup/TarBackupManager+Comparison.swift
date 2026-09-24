// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

public extension TarBackupManager {
    /// Compares the source directory with the latest version of each archived path.
    ///
    /// Comparison uses file size and whole-second modification time, matching the metadata
    /// available in the TAR header. Exclusion rules have the same semantics as `performBackup`.
    func compareSourceDirectory(excluding exclusionPatterns: [String] = []) throws -> TarArchiveDiff {
        let sourceFiles = try scanSourceDirectory(excluding: exclusionPatterns)
        let exclusionRules = TarExclusionRules(patterns: exclusionPatterns)
        let archiveIndex = try repairAndIndexArchive().filter {
            !exclusionRules.excludes($0.key, isDirectory: false)
        }
        let sourcePaths = Set(sourceFiles.keys)
        let archivePaths = Set(archiveIndex.keys)

        let added = sourcePaths.subtracting(archivePaths).sorted()
        let removed = archivePaths.subtracting(sourcePaths).sorted()
        var modified = [String]()
        var unchanged = [String]()

        for relativePath in sourcePaths.intersection(archivePaths).sorted() {
            guard let fileURL = sourceFiles[relativePath],
                  let archiveEntry = archiveIndex[relativePath] else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let sourceSize = (attributes[.size] as? NSNumber)?.uint64Value
            let sourceDate = attributes[.modificationDate] as? Date

            if sourceSize != archiveEntry.size
                || sourceDate.map({ Int64($0.timeIntervalSince1970) })
                != Int64(archiveEntry.modificationDate.timeIntervalSince1970) {
                modified.append(relativePath)
            } else {
                unchanged.append(relativePath)
            }
        }

        return TarArchiveDiff(
            added: added,
            modified: modified,
            removed: removed,
            unchanged: unchanged
        )
    }
}
