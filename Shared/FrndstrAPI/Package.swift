// swift-tools-version: 6.2
import PackageDescription

// Dependency-free API contract shared by the iOS app and the server.
let package = Package(
    name: "FrndstrAPI",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "FrndstrAPI", targets: ["FrndstrAPI"])
    ],
    targets: [
        .target(name: "FrndstrAPI"),
        .testTarget(name: "FrndstrAPITests", dependencies: ["FrndstrAPI"])
    ]
)
