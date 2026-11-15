// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bnet-sleepguard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SleepGuardCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "bnet-sleepguard",
            dependencies: ["SleepGuardCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "SleepGuardCoreTests", dependencies: ["SleepGuardCore"]),
    ]
)
