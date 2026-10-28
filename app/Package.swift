// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portico",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Portico",
            path: "Sources/Portico"
        ),
        .testTarget(
            name: "PorticoTests",
            dependencies: ["Portico"],
            path: "Tests/PorticoTests"
        ),
    ]
)
