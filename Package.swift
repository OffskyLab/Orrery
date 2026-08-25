// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orrery",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "orrery-bin", targets: ["orrery-bin"]),
        .executable(name: "orrery-agent", targets: ["orrery-agent"]),
        .executable(name: "orrery-claude-hook", targets: ["orrery-claude-hook"]),
        .executable(name: "orrery-claude", targets: ["orrery-claude"]),
        .library(name: "OrreryCore", targets: ["OrreryCore"]),
        .library(name: "OrreryThirdParty", targets: ["OrreryThirdParty"]),
        .library(name: "OrreryAccountKit", targets: ["OrreryAccountKit"]),
        .plugin(name: "L10nCodegen", targets: ["L10nCodegen"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/OffskyLab/Orrery-AIToolKit", exact: "0.0.1-dev.7"),
    ],
    targets: [
        .executableTarget(
            name: "orrery-bin",
            dependencies: [
                "OrreryCore",
                "OrreryThirdParty",
                "OrreryAccountKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/orrery"
        ),
        .executableTarget(
            name: "orrery-agent",
            dependencies: ["OrreryCore"],
            path: "Sources/orrery-agent"
        ),
        .executableTarget(
            name: "orrery-claude-hook",
            dependencies: ["OrreryCore"],
            path: "Sources/orrery-claude-hook"
        ),
        .executableTarget(
            name: "orrery-claude",
            dependencies: [
                .product(name: "AIToolKit", package: "Orrery-AIToolKit"),
            ],
            path: "Sources/orrery-claude"
        ),
        .target(
            name: "OrreryCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AIToolKit", package: "Orrery-AIToolKit"),
            ],
            path: "Sources/OrreryCore",
            exclude: [
                "Resources/Localization/README.md",
                "Resources/Localization/keys.md",
            ],
            plugins: [.plugin(name: "L10nCodegen")]
        ),
        .target(
            name: "OrreryThirdParty",
            dependencies: ["OrreryCore"],
            path: "Sources/OrreryThirdParty",
            resources: [.process("Manifests")]
        ),
        .target(
            name: "OrreryAccountKit",
            dependencies: ["OrreryCore"],
            path: "Sources/OrreryAccountKit"
        ),
        .executableTarget(
            name: "L10nCodegenTool",
            path: "Plugins/L10nCodegenTool"
        ),
        .plugin(
            name: "L10nCodegen",
            capability: .buildTool(),
            dependencies: ["L10nCodegenTool"]
        ),
        .testTarget(
            name: "OrreryTests",
            dependencies: [
                "OrreryCore",
                "OrreryAccountKit",
                .product(name: "AIToolKit", package: "Orrery-AIToolKit"),
            ],
            path: "Tests/OrreryTests",
            exclude: [
                "Fixtures/sidecar/fake-sidecar.sh",
            ]
        ),
        .testTarget(
            name: "OrreryThirdPartyTests",
            dependencies: ["OrreryThirdParty"],
            path: "Tests/OrreryThirdPartyTests"
        ),
        .testTarget(
            name: "OrreryAccountKitTests",
            dependencies: ["OrreryAccountKit"],
            path: "Tests/OrreryAccountKitTests"
        ),
    ]
)
