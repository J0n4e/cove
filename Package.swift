// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cove", path: "Sources", resources: [.copy("Resources/AppIcon.png"), .copy("Resources/AppIconClassic.png")]),
        .testTarget(name: "CoveTests", dependencies: ["Cove"], path: "Tests"),
    ]
)
