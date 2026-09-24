# TarBackup.swift

A standalone POSIX TAR backup system for iOS and macOS.

## Features

- **Zero dependencies:** Uses the file system and the TAR structure as its source of truth.
- **Append-only performance:** Appends new and modified files to the end of the archive in $O(1)$ time.
- **Self-healing:** Validates TAR headers and automatically removes incomplete archive tails, such as those left when the operating system terminates the process during a backup.
- **Compaction:** Removes obsolete versions of modified files from the archive.
- **Background tasks:** Includes `TarCompactorScheduler` for running compaction while the device is connected to external power.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/logdok/TarBackup.git",
        from: "1.0.0"
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

## Usage

```swift
import TarBackup

let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let sourceDir = docsURL.appendingPathComponent("AppFiles")
let archiveURL = docsURL.appendingPathComponent("backup.tar")

let manager = TarBackupManager(archiveURL: archiveURL, sourceDirectoryURL: sourceDir)

// Perform an incremental backup
do {
    try manager.performBackup()
} catch {
    print("Backup failed: \(error)")
}

// Compact the archive manually
try? manager.compactArchive()
```

## Background compaction setup (iOS)

1. Add `com.tarbackup.compacting` to the `Permitted background task scheduler identifiers` section of your app's `Info.plist`.
2. Register and schedule the task when the application starts:

```swift
TarCompactorScheduler.shared.registerBackgroundTask(manager: manager)
TarCompactorScheduler.shared.scheduleCompacting()
```

---

> The package is provided as Swift source code. You can copy the files into an existing project or initialize a new Swift package with `swift package init --type library`.
