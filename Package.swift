// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioBunny",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AudioBunny",
            path: "Sources/AudioBunny",
            resources: [
                .process("PluginCatalog.json"),
                .process("SettingsCatalog.json")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .executableTarget(
            name: "VST2Prober",
            path: "Sources/VST2Prober"
        ),
        .testTarget(
            name: "AudioBunnyTests",
            dependencies: ["AudioBunny"],
            path: "Tests/AudioBunnyTests"
        )
    ]
)
