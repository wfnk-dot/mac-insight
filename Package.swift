// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InsightCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InsightCore", targets: ["InsightCore"]),
    ],
    targets: [
        .target(name: "InsightCore"),
        .testTarget(name: "InsightCoreTests", dependencies: ["InsightCore"]),
    ]
)
