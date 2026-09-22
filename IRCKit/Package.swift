// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IRCKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IRCKit", targets: ["IRCKit"])
    ],
    targets: [
        .target(name: "IRCKit"),
        .testTarget(name: "IRCKitTests", dependencies: ["IRCKit"]),
    ]
)
