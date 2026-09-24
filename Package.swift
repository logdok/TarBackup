// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TarBackup",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "TarBackup",
            targets: ["TarBackup"]
        )
    ],
    targets: [
        .target(
            name: "TarBackup",
            dependencies: []
        ),
        .testTarget(
            name: "TarBackupTests",
            dependencies: ["TarBackup"]
        )
    ]
)
