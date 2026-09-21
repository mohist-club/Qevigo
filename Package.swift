// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Poptro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Poptro", targets: ["Poptro"]),
        .library(name: "PoptroCore", targets: ["PoptroCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0")
    ],
    targets: [
        .target(name: "PoptroCore", path: "Sources/PoptroCore"),
        .executableTarget(
            name: "Poptro",
            dependencies: ["PoptroCore", "KeyboardShortcuts"],
            path: "Sources/Poptro"
        ),
        .testTarget(
            name: "PoptroCoreTests",
            dependencies: ["PoptroCore"],
            path: "Tests/PoptroCoreTests"
        )
    ]
)
