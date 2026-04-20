// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orrery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "orrery-bin", targets: ["orrery-bin"]),
        .library(name: "OrreryCore", targets: ["OrreryCore"]),
        .library(name: "OrreryThirdParty", targets: ["OrreryThirdParty"]),
        .plugin(name: "L10nCodegen", targets: ["L10nCodegen"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "orrery-bin",
            dependencies: ["OrreryCore", "OrreryThirdParty"],
            path: "Sources/orrery"
        ),
        .target(
            name: "OrreryCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
            path: "Sources/OrreryThirdParty"
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
            dependencies: ["OrreryCore"],
            path: "Tests/OrreryTests"
        ),
        .testTarget(
            name: "OrreryThirdPartyTests",
            dependencies: ["OrreryThirdParty"],
            path: "Tests/OrreryThirdPartyTests"
        ),
    ]
)
