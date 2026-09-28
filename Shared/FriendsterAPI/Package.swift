// swift-tools-version: 6.2
import PackageDescription

// Dependency-free API contract shared by the iOS app and the server.
let package = Package(
    name: "FriendsterAPI",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "FriendsterAPI", targets: ["FriendsterAPI"])
    ],
    targets: [
        .target(name: "FriendsterAPI"),
        .testTarget(name: "FriendsterAPITests", dependencies: ["FriendsterAPI"])
    ]
)
