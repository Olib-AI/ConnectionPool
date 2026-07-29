# ConnectionPool

**A zero-dependency P2P mesh networking library for iOS and macOS with local and remote relay support, plus a cross-platform transport for Android interop, by [Olib AI](https://www.olib.ai)**

Used in [StealthOS](https://www.stealthos.app), the privacy-focused operating environment.

---

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://developer.apple.com/ios/)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Overview

ConnectionPool is a Swift package that builds a secure mesh network with three transport modes:

1. **Local mode**: MultipeerConnectivity over Wi-Fi and Bluetooth. No internet required.
2. **Remote mode**: WebSocket transport via [StealthRelay](https://github.com/Olib-AI/StealthRelay), a self-hosted Rust relay server. Connect from anywhere.
3. **Cross-platform mode**: Bonjour/mDNS plus TCP with a platform-neutral wire protocol, interoperable with **Android** peers. Swift and Kotlin devices join the same session over the local network.

Every mode enforces end-to-end encryption, authenticates joiners with pool codes or invitation tokens, and protects relay envelopes with HMAC-SHA256. The library was built for StealthOS, where "privacy by default" is not a feature, it is the architecture.

Zero external dependencies. Everything ships in one Swift package.

## Documentation

| Document | Contents |
|----------|----------|
| [Features](Docs/Features.md) | Full capability list for the local mesh, the remote relay transport, and Android interop |
| [Architecture](Docs/Architecture.md) | Component layout, mesh message flow, remote relay handshake flow |
| [Security](Docs/Security.md) | DTLS, pool codes, brute-force protection, envelope HMAC, loop prevention, host-offline persistence, tunnel exit |
| [Installation](Docs/Installation.md) | Swift Package Manager, XcodeGen, requirements, entitlements |
| [Quick Start](Docs/QuickStart.md) | Hosting, joining, messaging, remote pools, tunnel exit, auto-rejoin |
| [Configuration](Docs/Configuration.md) | Injecting a logger, encrypted block list storage, encrypted remote pool state |
| [Relay Server](Docs/RelayServer.md) | Self-hosting StealthRelay with Docker or Cloudflare Tunnel |
| [API Reference](Docs/APIReference.md) | Services, models, protocols, enumerations |

## At a Glance

- **Mesh networking with multi-hop relay**: BFS shortest-path routing over a distributed neighbor map, with TTL, hop-path loop detection, and a bounded dedup cache
- **Encrypted everywhere**: DTLS on every `MCSession`, AES-GCM over the relay WebSocket, ChaCha20-Poly1305 on the cross-platform transport, HMAC-SHA256 on routing metadata
- **Authenticated joins**: pool codes that never touch Bonjour metadata, Ed25519-signed invitation URLs, proof-of-work anti-DoS, session tokens for privileged operations
- **Hardened by default**: brute-force auto-blocking, per-peer rate limits, 10 MB inbound cap, 1 MB WebSocket frame cap, persistent block list
- **Survives host disconnect**: pools live on the relay past the host's WebSocket drop, and approved members rejoin without the host being online
- **Tunnel exit**: route TCP/UDP through the relay so its IP is the visible exit address, with TLS still end-to-end to the destination
- **Multiplayer game service**: invitations, ready checks, state sync, forfeit handling, disconnect recovery
- **Zero external dependencies**: only `MultipeerConnectivity`, `CryptoKit`, `Combine`, `Foundation`, and `os`

See [Features](Docs/Features.md) for the complete list.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/ConnectionPool.git", from: "1.6.0")
]
```

XcodeGen setup, platform requirements, and the entitlements MultipeerConnectivity needs are in [Installation](Docs/Installation.md).

## Hello, Pool

```swift
import ConnectionPool

let manager = ConnectionPoolManager.shared

manager.startHosting(configuration: PoolConfiguration(
    name: "My Room",
    maxPeers: 8,
    requireEncryption: true,
    generatePoolCode: true
))

if let code = manager.currentSession?.poolCode {
    print("Share this code: \(code)")
}

manager.sendChat("Hello, pool!")
```

Browsing, joining, receiving, remote pools, and tunnel streams are covered in [Quick Start](Docs/QuickStart.md).

## Requirements

iOS 17.0+, macOS 14.0+, Swift 6.0+, Xcode 16+. Details in [Installation](Docs/Installation.md#requirements).

## License

MIT License. Copyright (c) 2025 Olib AI. See [LICENSE](LICENSE) for the full text.

## Credits

- [Olib AI](https://www.olib.ai): package maintainer and [StealthOS](https://www.stealthos.app) developer
- [StealthRelay](https://github.com/Olib-AI/StealthRelay): self-hosted Rust relay server for remote pool connections
- [Apple MultipeerConnectivity](https://developer.apple.com/documentation/multipeerconnectivity): local transport layer
- [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit): HMAC-SHA256, HKDF key derivation, Ed25519 signing

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and please ensure:

1. Code compiles under Swift 6 strict concurrency
2. All public APIs are documented
3. Actor isolation is maintained for thread safety
4. No use of `@preconcurrency` escape hatches unless unavoidable and documented

## Security

If you discover a security vulnerability, please report it privately to security@olib.ai rather than opening a public issue. See [SECURITY.md](SECURITY.md).
