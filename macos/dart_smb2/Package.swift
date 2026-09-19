// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dart_smb2",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "dart-smb2", targets: ["dart_smb2"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "dart_smb2",
            dependencies: [
                "libsmb2",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/dart_smb2",
            resources: [
                .process("Resources")
            ]
        ),
        // The libsmb2 binary source is toggled by libsmb2-scripts' "Libs"
        // actions (local / remote / clean). Exactly ONE region below is active
        // at a time — the kit comments/uncomments these blocks; do not hand-edit
        // the smb2kit: markers.
        // smb2kit:local:begin
        // .binaryTarget(
            // name: "libsmb2",
            // path: "Frameworks/libsmb2.xcframework"
        // ),
        // smb2kit:local:end
        // smb2kit:remote:begin
        .binaryTarget(
            name: "libsmb2",
            url: "https://github.com/ales-drnz/dart_smb2/releases/download/libsmb2-r8/libsmb2_macos.xcframework.zip",
            checksum: "6a8be8a763683a9fa175e8f6f01e64c2f462039016acc98fc9f40f147673a57f"
        ),
        // smb2kit:remote:end
    ]
)
