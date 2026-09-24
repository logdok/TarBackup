// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

enum TarArchivePath {
    static let maximumUTF8Length = 100

    static func validate(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/") else {
            throw TarBackupError.invalidArchivePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TarBackupError.invalidArchivePath(relativePath)
        }

        guard relativePath.utf8.count <= maximumUTF8Length else {
            throw TarBackupError.archivePathTooLong(relativePath)
        }
    }
}
