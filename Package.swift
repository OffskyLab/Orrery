// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orrery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "orrery", targets: ["orrery"]),
        .library(name: "OrreryCore", targets: ["OrreryCore"]),
        .plugin(name: "L10nCodegen", targets: ["L10nCodegen"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "orrery",
            dependencies: ["OrreryCore"],
            path: "Sources/orrery"
        ),
        .target(
            name: "OrreryCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/OrreryCore",
            plugins: [.plugin(name: "L10nCodegen")]
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
    ]
)
