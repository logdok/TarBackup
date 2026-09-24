# TarBackup

TarBackup is a dependency-free Swift package for creating, editing, comparing, inspecting, and restoring TAR backups on iOS and macOS.

## Features

- Incremental and direct append without repacking existing entries
- File and batch deletion
- Source-directory comparison and exclusion patterns
- Archive listing and selective extraction
- Wildcard and subdirectory extraction
- Archive recovery and compaction
- iOS background compaction support

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

## Documentation

See the [TarBackup User Guide](USER_GUIDE.md) for setup, complete API examples, workflows, error handling, safety behavior, and TAR format limitations.

See [Release Notes](RELEASE_NOTES.md) for the version history.

## Requirements

- Swift 5.9 or later
- iOS 14 or later
- macOS 11 or later

## License

TarBackup is available under the [MIT License](LICENSE).
