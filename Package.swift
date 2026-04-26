// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ConnectionPool",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ConnectionPool", targets: ["ConnectionPool"]),
    ],
    targets: [
        .target(
            name: "ConnectionPool",
            path: "Sources"
        ),
        .testTarget(
            name: "ConnectionPoolTests",
            dependencies: ["ConnectionPool"],
            path: "Tests/ConnectionPoolTests"
        ),
    ]
)
