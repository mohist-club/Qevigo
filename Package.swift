// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Qevigo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Qevigo", targets: ["Qevigo"]),
        .library(name: "QevigoCore", targets: ["QevigoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "QevigoCore", path: "Sources/QevigoCore"),
        .executableTarget(
            name: "Qevigo",
            dependencies: ["QevigoCore", "KeyboardShortcuts", "Sparkle"],
            path: "Sources/Qevigo"
        ),
        .testTarget(
            name: "QevigoCoreTests",
            dependencies: ["QevigoCore"],
            path: "Tests/QevigoCoreTests"
        )
    ]
)
