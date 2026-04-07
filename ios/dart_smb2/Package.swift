// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dart_smb2",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "dart-smb2", targets: ["dart_smb2"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "dart_smb2",
            dependencies: [],
            path: "Sources/dart_smb2",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
