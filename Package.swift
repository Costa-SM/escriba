// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperDictation",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CWhisper",
            pkgConfig: nil,
            providers: []
        ),
        .executableTarget(
            name: "WhisperDictation",
            dependencies: ["CWhisper"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
