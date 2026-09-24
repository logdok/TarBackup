# TarBackup Release Notes

## 1.2.0

TarBackup 1.2.0 adds archive editing, source comparison, and configurable backup exclusions.

Documentation: [TarBackup User Guide](USER_GUIDE.md)

### Added

- Append one file from the manager's source directory with `appendFile(named:)`.
- Append multiple source-directory files with `appendFiles(named:)`.
- Append an arbitrary file at a chosen archive path with `appendFile(at:as:)`.
- Append arbitrary file batches with `TarAppendItem` and `appendFiles(_:)`.
- Stream appended file bodies without loading complete files into memory.
- Remove standard TAR end markers before appending to an existing third-party archive.
- Validate an entire append batch before writing and roll back partial batch writes.
- Delete one path with `deleteFile(named:)`.
- Delete several paths with `deleteFiles(named:)`.
- Remove every historical version of a deleted path while preserving all versions of remaining paths.
- Compare a source directory with the latest archive contents using `compareSourceDirectory(excluding:)`.
- Report added, modified, removed, and unchanged paths through `TarArchiveDiff`.
- Exclude files and directory trees from incremental backup with `performBackup(excluding:)`.
- Support `*`, `?`, and `**` exclusion patterns plus convenient component names such as `node_modules` and `.git`.
- Reject archive paths longer than the supported 100-byte ustar name field.
- Unit coverage for append, batch append, standard end markers, streaming, rollback validation, deletion, comparison, exclusions, and path limits.

### Changed

- Incremental backup now considers both file size and whole-second modification time.
- Files with fractional modification timestamps are no longer repeatedly appended when their stored TAR metadata is unchanged.
- A dedicated User Guide now covers the complete 1.2.0 API, workflows, safety guidance, error handling, and TAR limitations.

### Delete behavior

TAR entries cannot be removed from the middle of a file in place. Delete operations therefore build a temporary archive without the selected paths and atomically replace the original. Other physical entries and their historical versions are preserved.

## 1.1.0

TarBackup 1.1.0 introduced archive inspection and selective restoration.

### Added

- List current logical archive contents with `listContents()`.
- Inspect all physical versions in append order with `listContents(includingSupersededVersions: true)`.
- Extract one explicitly named file.
- Extract multiple explicitly named files with prevalidation.
- Extract files using `*`, `?`, and recursive `**` wildcard patterns.
- Restore every file below a selected archive subdirectory.
- Stream extraction in chunks.
- Control replacement of existing destination files.
- Reject unsafe paths, traversal components, directory collisions, and symbolic-link traversal.
- Public `TarBackupError` values for extraction failures.
- Unit coverage for listing, exact extraction, wildcard matching, subdirectories, overwriting, streaming, and path safety.

## 1.0.0

The initial TarBackup release provided incremental, append-only TAR backup for iOS and macOS.

### Added

- Recursively scan a source directory and archive regular files.
- Append new and newer file versions without rewriting the archive.
- Parse and validate 512-byte POSIX ustar headers.
- Repair incomplete file bodies, partial headers, and invalid trailing checksums.
- Build a latest-entry index from duplicate TAR paths.
- Compact an archive so only the latest version of each file remains.
- Schedule compaction through `BGProcessingTask` on iOS.
- Skip hidden source files.
- MIT License and Swift Package Manager installation documentation.
