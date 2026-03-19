# ConnectionPool

**A zero-dependency local P2P mesh networking library for iOS and macOS by [Olib AI](https://www.olib.ai)**

Used in [StealthOS](https://www.stealthos.app) — The privacy-focused operating environment.

---

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://developer.apple.com/ios/)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Overview

ConnectionPool is a Swift package that builds a secure mesh network on top of Apple's MultipeerConnectivity framework. It enables local peer-to-peer communication — chat, multiplayer games, and arbitrary data exchange — without any internet connection or external server.

Every session enforces DTLS encryption, authenticates joiners with pool codes that are never broadcast over Bonjour, and protects relay envelopes with HMAC-SHA256. The library was built for StealthOS, where "privacy by default" is not a feature — it is the architecture.

Zero external dependencies. Everything ships in one Swift package.

## Features

- **MultipeerConnectivity-based local P2P** — Discover and connect to nearby devices over Wi-Fi and Bluetooth with Bonjour service advertising
- **Mesh networking with multi-hop relay** — Messages reach peers beyond direct radio range by hopping through intermediate nodes
- **BFS-based topology routing** — Shortest-path routing computed from a distributed neighbor map that each node broadcasts periodically
- **Relay envelope with TTL, loop prevention, and dedup** — Every relayed message carries a TTL counter, an ordered hop path for cycle detection, and a UUID checked against a bounded deduplication cache (10,000 entries, 5-minute expiry)
- **HMAC-SHA256 envelope integrity** — Routing metadata (origin, destination, pool ID, message ID, timestamp) is signed with a key derived via HKDF from the pool ID; tampered envelopes are dropped
- **DTLS encryption enforced on all sessions** — `MCEncryptionPreference.required` on every `MCSession` — primary and relay — so all data in transit is encrypted at the transport layer
- **Pool code authentication** — Hosts generate a join code that is never included in Bonjour discovery info; joiners send it as invitation context and the host validates it server-side before accepting
- **Brute-force protection with auto-blocking** — After 5 failed join attempts from the same device (within a 1-hour window), the device is permanently added to the block list
- **Per-peer rate limiting** — A 5-second cooldown between connection attempts from the same peer prevents invitation flooding
- **10 MB inbound message size limit** — Oversized payloads are dropped before decoding on both the primary and relay sessions
- **Separate relay service type** — Relay discovery uses a distinct Bonjour service type (`stealthos-rly`) to avoid DTLS handshake conflicts with the primary session
- **Persistent device block list** — Blocked devices survive app restarts; storage is pluggable via `BlockListStorageProvider` (defaults to `UserDefaults`, can be wired to encrypted storage)
- **Multiplayer game service** — Built-in session management for turn-based and real-time games: invitations, ready checks, state sync, forfeit handling, and disconnect recovery
- **Configurable logging via protocol injection** — Inject your own `ConnectionPoolLogger` at startup; falls back to Apple's `os.Logger` with per-category subsystems
- **App lifecycle protocol** — `PoolAppLifecycle` lets the host app suspend, resume, and terminate pool operations cleanly
- **Zero external dependencies** — Only Apple frameworks: `MultipeerConnectivity`, `CryptoKit`, `Combine`, `Foundation`, `os`

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Host App (SwiftUI)                          │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  Chat ViewModel  │  │  Game ViewModel  │  │  Your Code   │  │
│  └────────┬─────────┘  └────────┬─────────┘  └──────┬───────┘  │
│           │                     │                    │          │
├───────────┼─────────────────────┼────────────────────┼──────────┤
│           ▼                     ▼                    ▼          │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              ConnectionPoolManager (@MainActor)            │ │
│  │                                                            │ │
│  │  • Hosting / Browsing / Joining                            │ │
│  │  • MCSession (DTLS .required)                              │ │
│  │  • Pool code validation                                    │ │
│  │  • Brute-force & rate-limit protection                     │ │
│  │  • 10 MB inbound size gate                                 │ │
│  │  • Combine publishers: messageReceived, peerEvent          │ │
│  └──────────┬────────────────────────────────┬────────────────┘ │
│             │                                │                  │
│             ▼                                ▼                  │
│  ┌─────────────────────┐          ┌─────────────────────────┐  │
│  │  MeshRelayService   │          │ MultiplayerGameService  │  │
│  │                     │          │                         │  │
│  │  • RelayEnvelope    │          │  • Session management   │  │
│  │  • HMAC signing     │          │  • Invitations          │  │
│  │  • BFS routing      │          │  • State sync           │  │
│  │  • Dedup cache      │          │  • Forfeit / disconnect │  │
│  │  • Topology bcast   │          └─────────────────────────┘  │
│  └──────────┬──────────┘                                       │
│             │                                                   │
│             ▼                                                   │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐  │
│  │   MeshTopology      │  │   DeviceBlockListService        │  │
│  │                     │  │                                 │  │
│  │  • Neighbor map     │  │  • Persistent block list        │  │
│  │  • BFS pathfinding  │  │  • Pluggable storage backend    │  │
│  │  • Stale pruning    │  │  • Auto-block on brute force    │  │
│  └─────────────────────┘  └─────────────────────────────────┘  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              MultipeerConnectivity (Apple)               │   │
│  │  MCSession / MCNearbyServiceAdvertiser / MCBrowser       │   │
│  │  DTLS transport encryption • Bonjour discovery           │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Mesh Message Flow

```
   Device A                Device B (relay)           Device C
  ┌────────┐              ┌────────────────┐         ┌────────┐
  │ Origin │──envelope──▶ │  Verify HMAC   │         │  Dest  │
  │        │   TTL=5      │  Check dedup   │         │        │
  │ Sign   │              │  Decrement TTL │         │        │
  │ HMAC   │              │  Append to hop │──fwd──▶ │ Verify │
  │        │              │  path          │  TTL=4  │ HMAC   │
  │        │              │  Forward       │         │ Deliver│
  └────────┘              └────────────────┘         └────────┘
```

## Security

Security is not bolted on — it is structural. Every layer enforces its own guarantees.

### Transport Encryption (DTLS)

All `MCSession` instances — both the primary session and the dedicated relay session — are created with `MCEncryptionPreference.required`. Apple's MultipeerConnectivity framework performs a DTLS handshake before any application data is exchanged.

### Pool Code Authentication

Pool codes are **never** included in Bonjour discovery metadata. A joiner sends the code as part of the invitation context. The host validates it before calling the invitation handler. This prevents passive eavesdroppers from learning the code by observing Bonjour traffic.

### Brute-Force Protection

Failed join attempts are tracked per device with a 1-hour expiry window. After 5 failures, the device is permanently added to the persistent block list via `DeviceBlockListService`. A separate 5-second per-peer cooldown prevents rapid-fire invitation flooding.

### Relay Envelope Integrity (HMAC-SHA256)

Every outgoing `RelayEnvelope` is signed with an HMAC computed over its immutable routing fields:

- `originPeerID`
- `destinationPeerID`
- `poolID`
- `messageID`
- `maxTTL` (constant, not the mutable per-hop TTL)
- `timestamp`

The HMAC key is derived from the pool UUID using HKDF-SHA256 with a domain-specific salt and info string. Relay nodes that tamper with routing metadata produce an invalid HMAC and the envelope is dropped.

### Loop and Amplification Prevention

| Mechanism | What it prevents |
|-----------|-----------------|
| **TTL** (default 5, max 5) | Messages circulating indefinitely |
| **Hop path** | Relaying to a peer already in the path |
| **Deduplication cache** (10,000 entries, 5-min expiry) | Processing the same message twice |
| **Message expiry** (5 minutes) | Replay of old messages |
| **Pool ID validation** | Cross-pool message injection |
| **Topology broadcast freshness** (120s max age) | Replay of stale routing info |

### Inbound Size Limits

All received data — on both the primary `MCSessionDelegate` and the relay session delegate — is checked against a 10 MB hard limit before any decoding is attempted.

### Separate Relay Service Type

Relay discovery operates on a distinct Bonjour service type to prevent DTLS handshake state from colliding with the primary session. The relay session uses its own `MCSession`, `MCPeerID`, and delegate handler, fully isolated from the primary connection.

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/ConnectionPool.git", from: "1.1.0")
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

### Local Package (XcodeGen)

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

## Quick Start

### Hosting a Pool

```swift
import ConnectionPool

let manager = ConnectionPoolManager.shared

// Configure logging (optional — falls back to os.Logger)
ConnectionPoolConfiguration.logger = MyAppLogger()

// Set user profile
manager.localProfile = PoolUserProfile(
    displayName: "Alice",
    avatarEmoji: "🦊",
    avatarColorIndex: 1
)

// Start hosting with a pool code
let config = PoolConfiguration(
    name: "My Room",
    maxPeers: 8,
    requireEncryption: true,
    generatePoolCode: true
)
manager.startHosting(configuration: config)

// The pool code is available after hosting starts
if let code = manager.currentSession?.poolCode {
    print("Share this code: \(code)")
}
```

### Joining a Pool

```swift
import ConnectionPool
import Combine

let manager = ConnectionPoolManager.shared
var cancellables = Set<AnyCancellable>()

// Start browsing for nearby pools
manager.startBrowsing()

// Observe discovered pools
manager.$discoveredPeers
    .sink { peers in
        for peer in peers {
            print("Found: \(peer.effectiveDisplayName)")
        }
    }
    .store(in: &cancellables)

// Join a discovered pool with the code
if let pool = manager.discoveredPeers.first {
    manager.joinPool(pool, poolCode: "ABC123")
}
```

### Sending and Receiving Messages

```swift
// Send a chat message to all peers
manager.sendChat("Hello, pool!")

// Send a typed message to specific peers
let message = PoolMessage.chat(
    from: manager.localPeerID,
    senderName: manager.localPeerName,
    text: "Direct message"
)
manager.sendMessage(message, to: ["peer-id-here"])

// Receive messages
manager.messageReceived
    .sink { message in
        switch message.type {
        case .chat:
            if let payload = message.decodePayload(as: ChatPayload.self) {
                print("\(message.senderName): \(payload.text)")
            }
        default:
            break
        }
    }
    .store(in: &cancellables)

// Observe peer events
manager.peerEvent
    .sink { event in
        switch event {
        case .connected(let peer):
            print("\(peer.displayName) joined")
        case .disconnected(let peer):
            print("\(peer.displayName) left")
        }
    }
    .store(in: &cancellables)
```

### Disconnecting

```swift
manager.disconnect()
```

## Configuration

### Injecting a Custom Logger

```swift
struct MyLogger: ConnectionPoolLogger {
    func log(
        _ message: String,
        level: PoolLogLevel,
        category: PoolLogCategory,
        file: String,
        function: String,
        line: Int
    ) {
        print("[\(level.rawValue)] [\(category.rawValue)] \(message)")
    }
}

// Set before using any ConnectionPool APIs
ConnectionPoolConfiguration.logger = MyLogger()
```

### Injecting Encrypted Block List Storage

```swift
struct SecureStorage: BlockListStorageProvider {
    func save(_ data: Data, forKey key: String) throws {
        // Write to Keychain or encrypted file
    }
    func load(forKey key: String) throws -> Data? {
        // Read from Keychain or encrypted file
    }
}

// Set at app startup
ConnectionPoolConfiguration.blockListStorageProvider = SecureStorage()
```

## API Reference

### Core Services

| Type | Description |
|------|-------------|
| `ConnectionPoolManager` | Main entry point. Manages hosting, browsing, joining, sending, and peer lifecycle. `@MainActor`, `ObservableObject`. |
| `MeshRelayService` | Coordinates multi-hop message routing, topology broadcasts, deduplication, and HMAC verification. |
| `MultiplayerGameService` | Session management for multiplayer games: invitations, ready checks, state sync, forfeit, disconnect recovery. |
| `DeviceBlockListService` | Persistent block list with pluggable storage backend. |

### Models

| Type | Description |
|------|-------------|
| `Peer` | A connected peer with display name, profile, connection type (direct/relayed), and status. |
| `DiscoveredPeer` | A nearby peer found via Bonjour that has not yet joined. Includes relay metadata. |
| `PoolSession` | An active pool session with host info, peer list, max peers, and encryption flag. |
| `PoolConfiguration` | Settings for creating a new pool: name, max peers, encryption, auto-accept, pool code generation. |
| `PoolMessage` | A typed message (chat, game state, game action, system, relay, key exchange, etc.) with encoded payload. |
| `RelayEnvelope` | Routing wrapper for multi-hop messages: TTL, hop path, pool ID, HMAC, encrypted payload. |
| `MeshTopology` | Thread-safe (NSLock) distributed neighbor map with BFS shortest-path routing. |
| `TopologyBroadcast` | Payload for sharing a peer's direct neighbors with the mesh. |
| `PoolUserProfile` | User-facing profile: display name, avatar emoji, color index. |
| `BlockedDevice` | A blocked device entry with peer ID, display name, reason, and timestamp. |

### Protocols

| Type | Description |
|------|-------------|
| `ConnectionPoolLogger` | Inject custom logging. Receives message, level, category, file, function, line. |
| `BlockListStorageProvider` | Pluggable persistence for the device block list (save/load `Data` by key). |
| `PoolAppLifecycle` | Lifecycle hooks: activate, background, suspend, terminate, memory warning. |

### Enumerations

| Type | Description |
|------|-------------|
| `PoolState` | `.idle`, `.hosting`, `.browsing`, `.connecting`, `.connected`, `.error(String)` |
| `PeerStatus` | `.connecting`, `.connected`, `.disconnected`, `.notConnected` |
| `PeerConnectionType` | `.direct`, `.relayed`, `.unknown` |
| `PoolMessageType` | `.chat`, `.gameState`, `.gameAction`, `.gameControl`, `.system`, `.ping`, `.pong`, `.peerInfo`, `.profileUpdate`, `.keyExchange`, `.relay`, `.custom` |
| `PeerEvent` | `.connected(Peer)`, `.disconnected(Peer)` |
| `PoolLogLevel` | `.debug`, `.info`, `.warning`, `.error`, `.critical` |
| `PoolLogCategory` | `.general`, `.network`, `.runtime`, `.games` |

## Requirements

- iOS 17.0+
- macOS 14.0+
- Swift 6.0+
- Xcode 16+

### Entitlements

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

## License

MIT License

Copyright (c) 2025 Olib AI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Credits

- [Olib AI](https://www.olib.ai) — Package maintainer and [StealthOS](https://www.stealthos.app) developer
- [Apple MultipeerConnectivity](https://developer.apple.com/documentation/multipeerconnectivity) — Transport layer
- [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit) — HMAC-SHA256 and HKDF key derivation

## Contributing

Contributions are welcome! Please ensure:

1. Code compiles under Swift 6 strict concurrency
2. All public APIs are documented
3. Actor isolation is maintained for thread safety
4. No use of `@preconcurrency` escape hatches unless unavoidable and documented

## Security

If you discover a security vulnerability, please report it privately to security@olib.ai rather than opening a public issue.
