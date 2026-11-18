// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bnet-mac-fixer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BnetFixerCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "bnet-mac-fixer",
            dependencies: ["BnetFixerCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "BnetFixerCoreTests", dependencies: ["BnetFixerCore"]),
    ]
)
