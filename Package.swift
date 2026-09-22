// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokeIRC",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "IRCKit", targets: ["IRCKit"])
    ],
    targets: [
        .target(
            name: "IRCKit",
            path: "Sources/IRCKit"
        ),
        .testTarget(
            name: "IRCKitTests",
            dependencies: ["IRCKit"],
            path: "Tests/IRCKitTests"
        )
    ]
)
