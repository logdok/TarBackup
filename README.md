# TarBackup

TarBackup is a lightweight Swift package for creating, editing, comparing, and restoring TAR backups on iOS and macOS. It supports incremental backup, direct append, deletion, exclusions, archive inspection, selective extraction, recovery, and compaction without external dependencies.

## Features

- **Zero dependencies:** Uses Foundation and the TAR archive itself as the source of truth.
- **Incremental backups:** Adds only new or modified files.
- **Direct append:** Adds one file or a batch to an existing archive without repacking it.
- **Deletion:** Removes one or several paths, including all stored versions.
- **Directory comparison:** Reports added, modified, removed, and unchanged paths.
- **Exclusions:** Skips matching files and entire directory trees during backup.
- **Append-only updates:** New file versions are appended without rewriting existing entries.
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

Add TarBackup 1.2.0 or later to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/logdok/TarBackup.git",
        from: "1.2.0"
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

The same manager provides backup, archive editing, comparison, inspection, extraction, repair, and compaction operations:

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

## Append files without repacking

Append a file from `sourceDirectoryURL` while preserving its relative path:

```swift
let entry = try manager.appendFile(named: "documents/report.txt")
```

Append several source-directory files in one operation:

```swift
let entries = try manager.appendFiles(named: [
    "documents/report.txt",
    "images/cover.png"
])
```

An arbitrary file can be mapped to a chosen archive path:

```swift
try manager.appendFile(
    at: exportURL,
    as: "exports/latest.json"
)
```

Use `TarAppendItem` to append a batch of arbitrary files:

```swift
try manager.appendFiles([
    TarAppendItem(fileURL: firstURL, archivePath: "imports/first.dat"),
    TarAppendItem(fileURL: secondURL, archivePath: "imports/second.dat")
])
```

Append streams file contents in 64-KB chunks. Every item is validated before writing starts, existing archive bytes are not repacked, and a failed batch is rolled back to the valid entry boundary where it began. When a standard TAR contains zero-filled end markers, TarBackup removes those markers before appending the new entry.

Appending an existing path creates a new version. APIs that operate on logical contents use its latest version.

## Incremental backup

```swift
try manager.performBackup()
```

`performBackup()` scans the source directory recursively. Hidden files are skipped. A file is appended when its path is absent from the archive or its size or whole-second modification time differs from the latest archived version.

Before appending data, TarBackup scans the archive and repairs an incomplete or invalid tail. Older versions remain in the archive until compaction.

### Exclude files and directories

Pass exclusion patterns when creating an incremental backup:

```swift
try manager.performBackup(excluding: [
    ".DS_Store",
    ".git",
    "node_modules",
    "build/",
    "**/*.tmp"
])
```

Exclusions use the same `*`, `?`, and `**` wildcards as extraction. A pattern without `/` is checked against every path component, so `node_modules` excludes every directory with that name and all of its descendants. A trailing slash can be used for a directory, and full path patterns such as `generated/**` exclude a subtree.

Exclusions prevent matching source files from being appended. They do not delete matching paths that are already stored in the archive; use the delete APIs for that.

## Compare the archive with files on disk

```swift
let difference = try manager.compareSourceDirectory(excluding: [
    ".git",
    "node_modules"
])

print(difference.added)
print(difference.modified)
print(difference.removed)
print(difference.unchanged)

if difference.isInSync {
    print("The source directory matches the archive")
}
```

`TarArchiveDiff` groups paths into:

- `added`: present on disk but absent from the archive;
- `modified`: present in both locations with different size or modification time;
- `removed`: present in the archive but absent from disk;
- `unchanged`: matching size and modification time.

Comparison is metadata-based and uses whole-second modification time because that is the precision stored in a standard TAR header. It does not read and compare complete file contents. Exclusion patterns are applied to both sides of the comparison.

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

## Delete files from the archive

Delete one logical path and all of its stored versions:

```swift
let wasDeleted = try manager.deleteFile(named: "documents/obsolete.txt")
```

Delete several paths in one operation:

```swift
let deletedPaths = try manager.deleteFiles(named: [
    "documents/obsolete.txt",
    "cache/index.bin"
])
```

Missing paths are ignored. `deleteFiles` returns only paths that existed, preserving their request order.

The TAR format cannot remove a middle entry in place. Deletion therefore writes a temporary archive containing every physical entry except the selected paths, then atomically replaces the original archive. Unlike compaction, delete preserves older versions of all remaining paths.

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

Package-specific failures are reported as `TarBackupError` values:

- `archiveEntryNotFound`: one explicitly requested file does not exist;
- `archiveEntriesNotFound`: one or more files from a multi-file request do not exist;
- `destinationAlreadyExists`: overwrite was disabled and the destination file exists;
- `invalidArchivePath`: an unsafe archive path or destination path collision was detected;
- `archivePathTooLong`: an archive path exceeds the supported 100-byte ustar name field;
- `invalidSubdirectory`: the requested subdirectory path is invalid;
- `sourceFileIsArchive`: an append operation attempted to use the archive as its own source;
- `sourceFileChanged`: a source file became shorter while it was being appended;
- `sourceFileNotRegular`: an append source is not a regular file;
- `unexpectedEndOfArchive`: an entry body ended before its declared size.

Foundation file-system errors may also be thrown.

## Archive format notes

TarBackup currently writes regular-file POSIX ustar headers. Paths are UTF-8 and public archive-writing APIs reject paths longer than the 100-byte ustar name field. File contents are stored without compression and padded to 512-byte TAR blocks.

The package does not append the optional two zero-filled end blocks because the archive is designed to remain appendable. Readers that scan entries by 512-byte headers can read the resulting archive.

## License

TarBackup is available under the MIT License. See [LICENSE](LICENSE).

## Release notes

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the complete version history.
