// swift-tools-version: 6.4
import PackageDescription

// Swift 7 upcoming features adopted early; compile-time only (no runtime change).
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "ConnectionPool",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ConnectionPool", targets: ["ConnectionPool"]),
    ],
    targets: [
        .target(
            name: "ConnectionPool",
            path: "Sources",
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "ConnectionPoolTests",
            dependencies: ["ConnectionPool"],
            path: "Tests/ConnectionPoolTests",
            swiftSettings: upcomingFeatures
        ),
    ]
)
