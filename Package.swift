// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "unsit",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "unsit", targets: ["unsit"]),
        .executable(name: "UnsitApp", targets: ["UnsitApp"]),
    ],
    targets: [
        .executableTarget(
            name: "unsit",
            dependencies: ["UnsitReport"],
            path: "Sources/unsit"
        ),
        .testTarget(name: "unsitTests", dependencies: ["unsit", "UnsitReport"], resources: [.copy("Fixtures")]),
        .target(name: "UnsitReport"),
        .target(name: "UnsitDesktop", dependencies: ["UnsitReport"]),
        .executableTarget(name: "UnsitApp", dependencies: ["UnsitDesktop", "UnsitReport"]),
        .testTarget(name: "UnsitDesktopTests", dependencies: ["UnsitDesktop", "unsit"]),
    ]
)
