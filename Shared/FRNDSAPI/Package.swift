// swift-tools-version: 6.2
import PackageDescription

// Dependency-free API contract shared by the iOS app and the server.
let package = Package(
    name: "FRNDSAPI",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "FRNDSAPI", targets: ["FRNDSAPI"])
    ],
    targets: [
        .target(name: "FRNDSAPI"),
        .testTarget(name: "FRNDSAPITests", dependencies: ["FRNDSAPI"])
    ]
)
