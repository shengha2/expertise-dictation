// swift-tools-version:5.9
// Optional SwiftPM manifest for machines with a healthy Xcode / toolchain.
// The supported build path is scripts/build.sh (plain swiftc), which also
// assembles the .app bundle; SwiftPM only produces the bare executable.
import PackageDescription

let package = Package(
    name: "ExpertiseDictation",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FnDictate",
            dependencies: ["Sparkle"],
            path: "Sources/FnDictate",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"), .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"), .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        ),
    ]
)
