# Installation

[Back to README](../README.md)

## Contents

- [Swift Package Manager](#swift-package-manager)
- [Local Package (XcodeGen)](#local-package-xcodegen)
- [Requirements](#requirements)
- [Entitlements](#entitlements)

## Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/ConnectionPool.git", from: "1.6.0")
]
```

Then add the dependency to your target:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ConnectionPool", package: "ConnectionPool")
        ]
    )
]
```

## Local Package (XcodeGen)

If using XcodeGen, add to your `project.yml`:

```yaml
packages:
  ConnectionPool:
    path: LocalPackages/ConnectionPool

targets:
  YourApp:
    dependencies:
      - package: ConnectionPool
        product: ConnectionPool
```

Then regenerate: `xcodegen generate`

## Requirements

- iOS 17.0+
- macOS 14.0+
- Swift 6.0+
- Xcode 16+

## Entitlements

MultipeerConnectivity requires the **Multicast Networking** entitlement on iOS 14+ and the **Local Network** usage description in your `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>ConnectionPool uses the local network to discover and communicate with nearby devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_stealthos-pool._tcp</string>
    <string>_stealthos-rly._tcp</string>
</array>
```

## Next Steps

- [Quick Start](QuickStart.md) for hosting, joining, and messaging
- [Configuration](Configuration.md) for logger and storage injection
