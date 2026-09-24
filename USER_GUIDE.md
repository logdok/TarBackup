# TarBackup User Guide

TarBackup is a Swift library for incremental, append-only TAR backups and selective restoration. It uses Foundation, stores uncompressed regular files in POSIX ustar blocks, and does not require a database or third-party dependency.

This guide covers TarBackup 1.2.0.

## Contents

- [Requirements and installation](#requirements-and-installation)
- [Core concepts](#core-concepts)
- [Create a manager](#create-a-manager)
- [Incremental backup](#incremental-backup)
- [Exclude files and directories](#exclude-files-and-directories)
- [Append files without repacking](#append-files-without-repacking)
- [List archive contents](#list-archive-contents)
- [Compare the archive with disk](#compare-the-archive-with-disk)
- [Extract files](#extract-files)
- [Delete files](#delete-files)
- [Repair an archive](#repair-an-archive)
- [Compact an archive](#compact-an-archive)
- [Background compaction on iOS](#background-compaction-on-ios)
- [Errors](#errors)
- [Safety and operational guidance](#safety-and-operational-guidance)
- [TAR format behavior and limitations](#tar-format-behavior-and-limitations)
- [API summary](#api-summary)

## Requirements and installation

TarBackup requires:

- Swift 5.9 or later;
- iOS 14 or later;
- macOS 11 or later.

Add TarBackup to `Package.swift`:

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

Then import the package where it is used:

```swift
import Foundation
import TarBackup
```

## Core concepts

TarBackup uses an append-only model for normal backups:

1. A new path is written as a new TAR entry.
2. A modified path is appended as another entry with the same name.
3. The latest physical entry for a name is its current logical version.
4. Older physical entries remain available until deletion or compaction rewrites the archive.

The distinction between logical and physical contents matters:

- **Logical contents** contain only the latest version of each archive path.
- **Physical contents** contain every entry in append order, including superseded versions.

Append and incremental backup do not repack existing entries. Delete and compaction must rewrite the archive because TAR cannot remove blocks from its middle in place.

## Create a manager

Create one manager with the archive location and the source directory used for backup and comparison:

```swift
let documentsURL = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
)[0]

let sourceDirectoryURL = documentsURL.appendingPathComponent(
    "AppFiles",
    isDirectory: true
)
let archiveURL = documentsURL.appendingPathComponent("backup.tar")

let manager = TarBackupManager(
    archiveURL: archiveURL,
    sourceDirectoryURL: sourceDirectoryURL
)
```

`sourceDirectoryURL` is used by incremental backup, relative-path append, and comparison. Inspection, extraction, deletion, repair, and compaction operate on `archiveURL`.

The manager does not create the source directory. Append creates the archive's parent directory when needed, and extraction creates its destination directory when at least one file is selected.

## Incremental backup

Create or update an archive from the source directory:

```swift
try manager.performBackup()
```

TarBackup recursively scans regular files. Hidden files and hidden directory trees are skipped. A source file is appended when:

- its relative path is absent from the logical archive index;
- its byte size differs; or
- its whole-second modification time differs.

Whole-second comparison matches the timestamp precision stored in the TAR header and prevents files with fractional filesystem timestamps from being repeatedly appended.

Incremental backup does not remove an archived path when the corresponding source file is deleted. Use `compareSourceDirectory()` to detect it and `deleteFile(named:)` or `deleteFiles(named:)` to remove it.

Before writing, TarBackup validates the archive and removes an incomplete or invalid tail. New entries are then appended in a single batch.

## Exclude files and directories

Pass exclusion patterns to incremental backup:

```swift
let exclusions = [
    ".DS_Store",
    ".git",
    "node_modules",
    "build/",
    "generated/**",
    "**/*.tmp"
]

try manager.performBackup(excluding: exclusions)
```

Exclusion rules use these wildcards:

| Pattern | Meaning |
| --- | --- |
| `*` | Zero or more characters inside one path component; never matches `/`. |
| `?` | Exactly one character inside one path component; never matches `/`. |
| `**` | Zero or more characters across path components and `/` separators. |

A pattern without `/` is checked against every component of the relative path. For example, `node_modules` excludes both `node_modules/package.json` and `packages/client/node_modules/library.js`.

Examples:

- `*.tmp` excludes matching components anywhere in the source tree.
- `build/` excludes a directory named `build` and its descendants.
- `generated/**` excludes the root `generated` subtree.
- `assets/*.cache` excludes direct matches inside the root `assets` directory.
- `**/DerivedData/**` excludes matching nested subtrees.

Empty exclusion strings are ignored. Exclusions affect source scanning only; they do not remove an entry that already exists in the archive.

Use the same exclusion array for backup and comparison when both operations should describe the same working set:

```swift
let difference = try manager.compareSourceDirectory(excluding: exclusions)
try manager.performBackup(excluding: exclusions)
```

## Append files without repacking

Append is useful when the exact files are already known and a full source-directory scan is unnecessary.

### Append from the source directory

Append one source file while preserving its relative path:

```swift
let entry = try manager.appendFile(
    named: "documents/report.txt"
)
```

Append several source files in input order:

```swift
let entries = try manager.appendFiles(named: [
    "documents/report.txt",
    "images/cover.png"
])
```

### Append arbitrary files

Map a file from any location to a chosen archive path:

```swift
let entry = try manager.appendFile(
    at: exportURL,
    as: "exports/latest.json"
)
```

Append a batch with explicit mappings:

```swift
let entries = try manager.appendFiles([
    TarAppendItem(
        fileURL: firstURL,
        archivePath: "imports/first.dat"
    ),
    TarAppendItem(
        fileURL: secondURL,
        archivePath: "imports/second.dat"
    )
])
```

Each append method returns `TarEntryInfo` values describing the new physical entries.

### Append behavior

- Existing archive entries are not copied or repacked.
- File bodies are streamed in 64-KB chunks.
- Every batch item is validated before archive writing begins.
- A failure during batch writing truncates the archive back to the valid entry boundary at which the batch began.
- Standard zero-filled TAR end markers are removed before a new entry is appended.
- Appending an existing archive path creates a new physical version; logical APIs select the newest version.
- A file cannot use the destination archive itself as its append source.
- An empty append batch returns an empty array and does not create an archive.

## List archive contents

List current logical contents, sorted by archive path:

```swift
let entries = try manager.listContents()

for entry in entries {
    print(entry.filename)
    print(entry.size)
    print(entry.modificationDate)
}
```

List every physical entry in append order:

```swift
let history = try manager.listContents(
    includingSupersededVersions: true
)
```

`TarEntryInfo` contains:

| Property | Meaning |
| --- | --- |
| `filename` | Relative archive path. |
| `offset` | Byte offset of the entry's 512-byte header. |
| `size` | Uncompressed file size in bytes. |
| `modificationDate` | Whole-second modification time stored in the TAR header. |

Listing also validates the archive and may repair an invalid or incomplete tail. Listing a missing archive returns an empty array and does not create a file.

## Compare the archive with disk

Compare the source directory with current logical archive contents:

```swift
let difference = try manager.compareSourceDirectory()

print(difference.added)
print(difference.modified)
print(difference.removed)
print(difference.unchanged)
```

Use the same exclusions as backup when required:

```swift
let difference = try manager.compareSourceDirectory(
    excluding: exclusions
)
```

`TarArchiveDiff` groups sorted paths into:

| Property | Meaning |
| --- | --- |
| `added` | Present on disk but absent from the archive. |
| `modified` | Present in both locations with a different size or whole-second modification time. |
| `removed` | Present in the archive but absent from disk. |
| `unchanged` | Size and whole-second modification time match. |
| `hasChanges` | `true` when `added`, `modified`, or `removed` is not empty. |
| `isInSync` | `true` when there are no added, modified, or removed paths. |

Comparison is metadata-based. If file contents change while size and whole-second modification time remain identical, comparison reports the file as unchanged. It does not hash or read complete file bodies.

Comparison applies exclusion patterns to both the source side and archive side. Like listing, it validates the archive and can repair a damaged tail.

## Extract files

All extraction APIs restore the latest logical version of each selected archive path and preserve relative paths below the destination directory.

### Extract one file

```swift
let restoreDirectoryURL = documentsURL.appendingPathComponent(
    "Restore",
    isDirectory: true
)

let restoredURL = try manager.extractFile(
    named: "documents/report.txt",
    to: restoreDirectoryURL
)
```

This writes `Restore/documents/report.txt`. A missing exact path throws `TarBackupError.archiveEntryNotFound`.

### Extract several named files

```swift
let restoredURLs = try manager.extractFiles(
    named: [
        "documents/report.txt",
        "images/cover.png"
    ],
    to: restoreDirectoryURL
)
```

All names are validated and checked before extraction starts. If any requested path is missing, `archiveEntriesNotFound` contains the missing names and none of the requested files is written. Duplicate input names are extracted once in first-appearance order.

An empty name array returns an empty result and does not create the destination.

### Extract with wildcards

```swift
let pngFiles = try manager.extract(
    matching: "images/**/*.png",
    to: restoreDirectoryURL
)
```

Extraction wildcard examples:

- `*.txt` matches text files at the archive root.
- `documents/*.pdf` matches direct children of `documents`.
- `images/?.png` matches `images/a.png`, but not `images/icon.png`.
- `images/**/*.png` matches PNG files directly in `images` and in nested directories.
- `**/*.json` matches JSON files anywhere, including the root.

Regular-expression characters have no special meaning and are matched literally. A pattern with no matches returns an empty array and does not create the destination.

### Extract a complete subdirectory

```swift
let restoredURLs = try manager.extractSubdirectory(
    "documents/reports",
    to: restoreDirectoryURL
)
```

A trailing slash is optional. The selected subdirectory itself is preserved below the destination. A valid folder path with no archived children returns an empty array. An empty or unsafe folder path throws `invalidSubdirectory`.

### Existing destination files

Extraction overwrites an existing regular file by default:

```swift
try manager.extractFile(
    named: "settings.json",
    to: restoreDirectoryURL,
    overwriteExisting: true
)
```

Disable replacement when existing files must be preserved:

```swift
try manager.extractFile(
    named: "settings.json",
    to: restoreDirectoryURL,
    overwriteExisting: false
)
```

The second form throws `destinationAlreadyExists` if the output file exists.

File data is streamed through a temporary file in the destination directory. TarBackup restores the stored modification date and then moves or replaces the destination file.

### Extraction path safety

Extraction rejects:

- absolute archive paths;
- empty path components;
- `.` and `..` components;
- a directory where a regular output file is required;
- a regular file where a destination directory is required;
- symbolic links inside the destination hierarchy.

These checks prevent archive entries from escaping through path traversal or an existing symbolic link.

## Delete files

Delete one logical path and all physical versions of it:

```swift
let wasDeleted = try manager.deleteFile(
    named: "documents/obsolete.txt"
)
```

Delete multiple paths:

```swift
let deletedPaths = try manager.deleteFiles(named: [
    "documents/obsolete.txt",
    "cache/index.bin"
])
```

Delete behavior:

- Missing paths are ignored.
- `deleteFile` returns whether the requested path existed.
- `deleteFiles` returns unique paths that existed, preserving first request order.
- Every historical version of a selected path is removed.
- Every physical version of paths that remain is preserved in original order.
- An empty request returns an empty array without modifying the archive.
- Deleting the final entry leaves a valid zero-byte archive.

TAR cannot remove a block from the middle of a file. Delete therefore copies retained entries to a temporary archive and atomically replaces the original. This operation is proportional to the size of retained data and requires enough free storage for the temporary archive.

## Repair an archive

Build the latest-entry index while validating the archive:

```swift
let index = try manager.repairAndIndexArchive()
let report = index["documents/report.txt"]
```

The method checks:

- complete 512-byte headers;
- valid TAR checksums;
- availability of complete declared bodies and padded blocks;
- incomplete trailing entry data.

An invalid or incomplete tail is truncated at the last valid entry boundary. A standard zero-filled end block stops scanning. Later duplicate paths replace earlier values in the returned dictionary.

Despite its inspection-oriented return value, `repairAndIndexArchive()` is a mutating operation when damage is found. A missing archive returns an empty dictionary.

## Compact an archive

```swift
try manager.compactArchive()
```

Compaction writes a replacement archive containing only the latest physical version of each logical path. It reclaims storage used by superseded versions.

Compaction differs from delete:

- **Delete** removes selected paths and preserves all physical versions of every other path.
- **Compaction** keeps every logical path but discards its older physical versions.

Compaction uses a temporary file and atomically replaces the original archive. Call it only when the archive already exists.

## Background compaction on iOS

`TarCompactorScheduler` integrates compaction with `BGProcessingTask`.

1. Enable the Background processing capability for the application.
2. Add `com.tarbackup.compacting` to `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
3. Register the task when the application starts.
4. Schedule it after backup activity or when compaction is appropriate.

```swift
TarCompactorScheduler.shared.registerBackgroundTask(
    manager: manager
)
TarCompactorScheduler.shared.scheduleCompacting()
```

The request requires external power. The operating system decides whether and when the task runs. Outside iOS, scheduler methods are safe no-ops.

## Errors

TarBackup operations can throw `TarBackupError` or a Foundation filesystem error.

| Error | Meaning |
| --- | --- |
| `archiveEntryNotFound(path)` | A requested exact archive path does not exist. |
| `archiveEntriesNotFound(paths)` | One or more paths in a multi-file extraction request do not exist. |
| `destinationAlreadyExists(path)` | Extraction replacement was disabled and the output exists. |
| `invalidArchivePath(path)` | A path is empty, absolute, unsafe, or conflicts with the destination hierarchy. |
| `archivePathTooLong(path)` | The UTF-8 path exceeds the supported 100-byte ustar name field. |
| `invalidSubdirectory(path)` | A subdirectory extraction path is empty or unsafe. |
| `sourceFileIsArchive(path)` | An append request attempted to use the destination archive as source data. |
| `sourceFileChanged(path)` | A source file became shorter while it was being appended. |
| `sourceFileNotRegular(path)` | An append source is a directory or another non-regular file. |
| `unexpectedEndOfArchive(path)` | Stored entry data ended before its declared length. |

`TarBackupError` conforms to `LocalizedError`, so `error.localizedDescription` provides a readable message.

Foundation errors can report missing files, permissions, unavailable storage, failed replacement, or other filesystem conditions. An application should normally catch and present both categories:

```swift
do {
    try manager.performBackup(excluding: exclusions)
} catch let error as TarBackupError {
    print(error.localizedDescription)
} catch {
    print("Filesystem error: \(error.localizedDescription)")
}
```

## Safety and operational guidance

### Serialize archive operations

Do not run backup, append, extraction, deletion, repair, or compaction against the same archive concurrently. `TarBackupManager` does not provide cross-task or cross-process locking. Serialize access in the application, for example through one actor or operation queue.

### Keep the archive outside the source directory

Store `archiveURL` outside `sourceDirectoryURL`. Otherwise a recursive backup can discover the archive while it is being written. Direct append explicitly rejects using the destination archive itself as source, but keeping the two roots separate avoids all self-inclusion cases.

### Plan storage for rewriting operations

Append normally needs space only for new entries. Delete and compaction need temporary free space for the replacement archive.

### Reuse exclusions consistently

Use the same exclusion array for comparison and backup. Excluding a path from backup does not remove an older archived copy.

### Treat metadata comparison as a fast signal

Comparison and incremental backup use size and whole-second modification time, not hashes. Applications that can preserve both metadata values while changing content should perform their own content validation.

### Handle interruptions

The next scan repairs an incomplete trailing header or body. Append batches also truncate partial batch output back to their starting entry boundary when a write throws.

## TAR format behavior and limitations

- TarBackup writes uncompressed regular-file POSIX ustar headers.
- File bodies are padded to 512-byte blocks.
- Public writing APIs support UTF-8 archive paths up to 100 bytes.
- Paths longer than 100 UTF-8 bytes throw `archivePathTooLong`; the ustar prefix field is not currently used.
- Modification time is stored with whole-second precision.
- New headers use file mode `0644` and zero UID/GID fields.
- Extraction restores file contents and modification time, but does not restore ownership or the original source permissions.
- Source scanning archives regular files only. Directory entries and symbolic links are not written.
- Hidden source files and hidden directory trees are skipped by incremental scanning.
- The package does not append the optional two zero-filled end blocks because its archives remain appendable.
- Append removes existing zero-filled end markers before adding new entries.
- Archive data is not compressed. Use a separate compression layer if a `.tar.gz` or similar format is required.
- The reader is designed around the regular-file headers produced by TarBackup; extended PAX metadata, GNU long-name records, and the ustar prefix field are not currently interpreted.

## API summary

| Operation | API | Rewrites existing entries? |
| --- | --- | --- |
| Incremental backup | `performBackup(excluding:)` | No |
| Append source file | `appendFile(named:)` | No |
| Append source files | `appendFiles(named:)` | No |
| Append arbitrary file | `appendFile(at:as:)` | No |
| Append arbitrary batch | `appendFiles(_:)` | No |
| List latest contents | `listContents()` | Only repairs an invalid tail |
| List physical history | `listContents(includingSupersededVersions: true)` | Only repairs an invalid tail |
| Compare with source | `compareSourceDirectory(excluding:)` | Only repairs an invalid tail |
| Extract one file | `extractFile(named:to:overwriteExisting:)` | Only repairs an invalid tail |
| Extract named files | `extractFiles(named:to:overwriteExisting:)` | Only repairs an invalid tail |
| Extract wildcard | `extract(matching:to:overwriteExisting:)` | Only repairs an invalid tail |
| Extract subdirectory | `extractSubdirectory(_:to:overwriteExisting:)` | Only repairs an invalid tail |
| Delete one path | `deleteFile(named:)` | Yes |
| Delete paths | `deleteFiles(named:)` | Yes |
| Repair and index | `repairAndIndexArchive()` | Only when the tail is invalid |
| Compact | `compactArchive()` | Yes |
