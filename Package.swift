// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "unsit",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "unsit",
            path: "Sources/unsit"
        ),
        .testTarget(name: "unsitTests", dependencies: ["unsit"], resources: [.copy("Fixtures")]),
    ]
)
