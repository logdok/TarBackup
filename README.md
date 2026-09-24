# TarBackup

TarBackup is a lightweight Swift package for incremental, append-only TAR backups on iOS and macOS. It can create and repair archives, inspect their contents, restore exact files, extract groups of files with wildcard patterns, restore complete archive subdirectories, and compact obsolete file versions.

## Features

- **Zero dependencies:** Uses Foundation and the TAR archive itself as the source of truth.
- **Incremental backups:** Adds only new or modified files.
- **Append-only writes:** New file versions are appended without rewriting the existing archive.
- **Archive recovery:** Validates TAR headers and removes incomplete or corrupted archive tails.
- **Content listing:** Lists the current archive contents or every stored physical version.
- **Selective extraction:** Restores one file or several explicitly named files.
- **Wildcard extraction:** Supports `*`, `?`, and recursive `**` path patterns.
- **Subdirectory extraction:** Restores every file below a selected archive folder.
- **Safe paths:** Rejects absolute paths, `.` and `..` path components, directory collisions, and symbolic-link traversal inside the destination.
- **Streaming restore:** Extracts file bodies in chunks instead of loading an entire file into memory.
- **Compaction:** Rewrites the archive with only the latest version of each file.
- **Background compaction:** Includes `TarCompactorScheduler` for iOS background processing while external power is connected.

## Requirements

- Swift 5.9 or later
- iOS 14 or later
- macOS 11 or later

## Installation

Add TarBackup 1.1.0 or later to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/logdok/TarBackup.git",
        from: "1.1.0"
    ),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "TarBackup", package: "TarBackup"),
        ]
    ),
]
```

## Create a manager

The same manager provides backup, inspection, extraction, repair, and compaction operations:

```swift
import Foundation
import TarBackup

let documentsURL = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
)[0]

let sourceDirectoryURL = documentsURL.appendingPathComponent("AppFiles")
let archiveURL = documentsURL.appendingPathComponent("backup.tar")

let manager = TarBackupManager(
    archiveURL: archiveURL,
    sourceDirectoryURL: sourceDirectoryURL
)
```

`sourceDirectoryURL` is used when creating a backup. Extraction reads from `archiveURL`; extracted files can be written to any destination directory supplied to an extraction method.

## Incremental backup

```swift
try manager.performBackup()
```

`performBackup()` scans the source directory recursively. Hidden files are skipped. A file is appended when its path is not yet in the archive or its modification date is newer than the latest archived version.

Before appending data, TarBackup scans the archive and repairs an incomplete or invalid tail. Older versions remain in the archive until compaction.

## List archive contents

List the latest version of every path, sorted by filename:

```swift
let entries = try manager.listContents()

for entry in entries {
    print(entry.filename, entry.size, entry.modificationDate)
}
```

Inspect every physical entry in append order, including superseded versions:

```swift
let history = try manager.listContents(includingSupersededVersions: true)
```

Each `TarEntryInfo` contains:

- `filename`: the relative archive path;
- `offset`: the byte offset of the entry header;
- `size`: the uncompressed file size in bytes;
- `modificationDate`: the stored modification date.

## Extract one file

```swift
let restoreDirectoryURL = documentsURL.appendingPathComponent("Restore")

let restoredURL = try manager.extractFile(
    named: "documents/report.txt",
    to: restoreDirectoryURL
)
```

The relative archive path is preserved, so this example writes `Restore/documents/report.txt`. When several versions exist, the latest archived version is restored.

## Extract several named files

```swift
let restoredURLs = try manager.extractFiles(
    named: [
        "documents/report.txt",
        "images/cover.png"
    ],
    to: restoreDirectoryURL
)
```

All requested paths are checked before extraction starts. If any path is missing, `archiveEntriesNotFound` is thrown and no requested file is written. Duplicate names in the input are extracted once, in first-appearance order.

## Extract files with wildcards

```swift
let pngFiles = try manager.extract(
    matching: "images/**/*.png",
    to: restoreDirectoryURL
)
```

Wildcard rules:

| Pattern | Meaning |
| --- | --- |
| `*` | Zero or more characters within one path component; it does not match `/`. |
| `?` | Exactly one character within one path component; it does not match `/`. |
| `**` | Zero or more characters across directory separators. |

Examples:

- `*.txt` matches text files at the archive root.
- `documents/*.pdf` matches PDF files directly inside `documents`.
- `images/?.png` matches `images/a.png`, but not `images/icon.png`.
- `images/**/*.png` matches PNG files directly inside `images` and in all nested directories.
- `**/*.json` matches JSON files anywhere in the archive, including the root.

Only the latest archived version of each matching path is extracted. An unmatched pattern returns an empty array.

## Extract a complete subdirectory

```swift
let restoredURLs = try manager.extractSubdirectory(
    "documents/reports",
    to: restoreDirectoryURL
)
```

A trailing slash is optional. The selected archive subdirectory is preserved below the destination. If no archived files exist below a valid path, the method returns an empty array; an empty or unsafe path throws `invalidSubdirectory`.

## Existing destination files

Extraction overwrites an existing regular file by default:

```swift
try manager.extractFile(
    named: "settings.json",
    to: restoreDirectoryURL,
    overwriteExisting: true
)
```

Pass `overwriteExisting: false` to preserve the existing file and receive `TarBackupError.destinationAlreadyExists`.

All extraction methods reject unsafe archive paths and refuse to follow symbolic links inside the destination hierarchy.

## Repair and inspect the latest-entry index

```swift
let index = try manager.repairAndIndexArchive()
let latestReport = index["documents/report.txt"]
```

`repairAndIndexArchive()` validates the archive, truncates an incomplete or invalid tail, and returns a dictionary containing the latest entry for every path. Because this method can truncate damaged trailing data, it is not a read-only operation.

## Compact the archive

```swift
try manager.compactArchive()
```

Compaction creates a replacement archive containing only the latest version of every file. This reclaims space used by superseded versions.

## Background compaction on iOS

1. Enable the Background processing capability for the application.
2. Add `com.tarbackup.compacting` to `BGTaskSchedulerPermittedIdentifiers` in the app's `Info.plist`.
3. Register and schedule compaction when the application starts:

```swift
TarCompactorScheduler.shared.registerBackgroundTask(manager: manager)
TarCompactorScheduler.shared.scheduleCompacting()
```

The scheduler requests external power and runs compaction through `BGProcessingTask`. Outside iOS, these methods are safe no-ops.

## Errors

Extraction-specific failures are reported as `TarBackupError` values:

- `archiveEntryNotFound`: one explicitly requested file does not exist;
- `archiveEntriesNotFound`: one or more files from a multi-file request do not exist;
- `destinationAlreadyExists`: overwrite was disabled and the destination file exists;
- `invalidArchivePath`: an unsafe archive path or destination path collision was detected;
- `invalidSubdirectory`: the requested subdirectory path is invalid;
- `unexpectedEndOfArchive`: an entry body ended before its declared size.

Foundation file-system errors may also be thrown.

## Archive format notes

TarBackup currently writes regular-file POSIX ustar headers. Paths are UTF-8 and the current writer uses the 100-byte ustar name field; longer UTF-8 paths are truncated to that field. File contents are stored without compression and padded to 512-byte TAR blocks.

The package does not append the optional two zero-filled end blocks because the archive is designed to remain appendable. Readers that scan entries by 512-byte headers can read the resulting archive.

## License

TarBackup is available under the MIT License. See [LICENSE](LICENSE).
