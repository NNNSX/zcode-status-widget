// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zcode-status-light-macos",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ZCodeStatusLight",
            dependencies: ["Core"],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ZCodeStatusHook",
            dependencies: ["Core"],
            path: "Sources/ZCodeStatusHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
