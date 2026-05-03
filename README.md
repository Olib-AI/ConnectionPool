# ConnectionPool

**A zero-dependency P2P mesh networking library for iOS and macOS with local and remote relay support by [Olib AI](https://www.olib.ai)**

Used in [StealthOS](https://www.stealthos.app) — The privacy-focused operating environment.

---

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://developer.apple.com/ios/)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Overview

ConnectionPool is a Swift package that builds a secure mesh network with two transport modes:

1. **Local mode** — MultipeerConnectivity over Wi-Fi and Bluetooth. No internet required.
2. **Remote mode** — WebSocket transport via [StealthRelay](https://github.com/Olib-AI/StealthRelay), a self-hosted Rust relay server. Connect from anywhere.

Both modes enforce end-to-end encryption, authenticate joiners with pool codes or invitation tokens, and protect relay envelopes with HMAC-SHA256. The library was built for StealthOS, where "privacy by default" is not a feature — it is the architecture.

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

### Remote Relay Transport ([StealthRelay](https://github.com/Olib-AI/StealthRelay))

- **WebSocket transport** — Connect to a self-hosted relay server from anywhere via `wss://` (default) or `ws://` if explicitly specified
- **Ed25519 host authentication** — The host signs pool creation with a Keychain-stored Ed25519 identity
- **Invitation-based joining** — Shareable `stealth://invite/...` URLs with Ed25519 signatures, HMAC proofs, and configurable expiry
- **Proof-of-Work anti-DoS** — Joining peers solve a SHA-256 PoW challenge (18-bit difficulty, ~50ms) before the server forwards the request to the host
- **End-to-end encrypted relay messages** — Messages relayed via WebSocket are AES-GCM encrypted with a key derived from the pool shared secret via HKDF-SHA256; the relay server sees only opaque ciphertext
- **Session tokens** — All privileged operations (create invitation, kick peer, close pool) require a server-issued session token
- **TLS certificate pinning** — SPKI SHA-256 pin verification via custom `URLSessionDelegate`
- **Server claiming** — First-use server binding via QR code or manual claim code from Docker logs
- **Recovery key after claim** — After claiming a server, the recovery key is displayed in a dedicated sheet with options to save to the password manager or copy to clipboard; the user must acknowledge before proceeding
- **Automatic reconnection** — Exponential backoff with invitation expiry checks; previously-approved peers are auto-accepted on reconnect
- **Relay bridge deduplication** — Messages bridged between relay and primary sessions are deduplicated by `PoolMessage.id` to prevent double processing
- **1 MB WebSocket frame limit** — Incoming WebSocket frames exceeding 1 MB are dropped before processing to prevent memory exhaustion from malicious servers
- **Cloudflare Tunnel support** — Production deployment via `cloudflared` for TLS termination without managing certificates
- **Pool persistence past host disconnect** — When the pool host's WebSocket drops, the pool stays alive on the relay; existing peers keep messaging, calling, gaming, and tunneling. The host re-authenticates with the same Ed25519 key + `pool_id` to rebind in place. New joins are still gated on the host being online (no auto-approve). Surfaced via `ConnectionPoolManager.hostOnline` and the `pool_host_status` server frame
- **Host-offline join rejection** — Join requests received while the host is offline are rejected with `JoinRejected.reason == "host_offline_unavailable"` and surfaced as `TransportError.hostOffline` to a friendly user message — auto-reconnect is suppressed on this path so devices don't hammer the relay with rejections
- **Tunnel-exit (VPN-like) client** — `RelayTunnelClient` opens TCP/UDP streams through the relay so the relay's IP becomes the visible exit address. Used by StealthOS's in-app proxy to route browser traffic; TLS to the destination remains end-to-end (relay sees only ciphertext). Per-pool host approval gate via `update_pool_config { tunnel_exit_enabled }`; the host bypasses their own gate
- **Binary hot-path frames** — `TUNNEL_DATA` (`0x01`) and `TUNNEL_UDP` (`0x02`) ride binary WebSocket frames with a fixed-size big-endian header (no base64, no JSON parse on the byte path). Control plane (open / close / window_update / dns / error) stays JSON for debuggability
- **Credit-based flow control** — Per-stream send-credit window (256 KiB initial; relay grants additional credit via `tunnel_window_update` as it consumes bytes). Stops the WebSocket from getting evicted by the relay's slow-consumer threshold under sustained traffic
- **Tunnel kill switch** — A `tunnel_close { reason: "policy_denied" }` from the relay (server flag off, per-pool flag off, denied CIDR/port) trips a `RelayTunnelKillSwitchTriggered` notification consumers can hook to block all egress until the user resolves it

## Architecture

```mermaid
graph TD
    subgraph HostApp["Host App - SwiftUI"]
        ChatVM["Chat ViewModel"]
        GameVM["Game ViewModel"]
        YourCode["Your Code"]

        ChatVM --> CPM
        GameVM --> CPM
        YourCode --> CPM

        subgraph CPM["ConnectionPoolManager - @MainActor"]
            direction LR
            CPM_Features["Hosting / Browsing / Joining\nMCSession DTLS .required\nPool code validation\nBrute-force & rate-limit protection\n10 MB inbound size gate\nCombine publishers: messageReceived, peerEvent"]
        end

        CPM --> MeshRelay
        CPM --> GameService

        MeshRelay["MeshRelayService\n\nRelayEnvelope | HMAC signing\nBFS routing | Dedup cache\nTopology broadcast"]
        GameService["MultiplayerGameService\n\nSession management | Invitations\nState sync | Forfeit / disconnect"]

        MeshRelay --> Topology
        MeshRelay --> BlockList

        Topology["MeshTopology\n\nNeighbor map | BFS pathfinding\nStale pruning"]
        BlockList["DeviceBlockListService\n\nPersistent block list\nPluggable storage backend\nAuto-block on brute force"]

        MPC["MultipeerConnectivity - Apple\nMCSession / MCNearbyServiceAdvertiser / MCBrowser\nDTLS transport encryption | Bonjour discovery"]
    end

    Topology --> MPC
    BlockList --> MPC
```

### Mesh Message Flow

```mermaid
sequenceDiagram
    participant A as Device A - Origin
    participant B as Device B - Relay
    participant C as Device C - Destination

    A->>A: Sign HMAC
    A->>B: Envelope (TTL=5)
    B->>B: Verify HMAC
    B->>B: Check dedup
    B->>B: Decrement TTL
    B->>B: Append to hop path
    B->>C: Forward (TTL=4)
    C->>C: Verify HMAC
    C->>C: Deliver message
```

### Remote Relay Flow

```mermaid
sequenceDiagram
    participant Host as Host - iOS
    participant Relay as StealthRelay - Rust
    participant Joiner as Joiner - iOS

    Host->>Relay: Connect (wss)
    Relay->>Host: AuthChallenge (nonce)
    Host->>Relay: HostAuth (Ed25519 signed, nonce-bound)
    Relay->>Relay: Verify Ed25519 + nonce, create pool
    Relay->>Host: Session token

    Host->>Relay: Create invitation (token)
    Relay->>Host: Ed25519 signed invite URL

    Joiner->>Relay: JoinRequest (wss)
    Relay->>Joiner: PoW challenge
    Joiner->>Relay: PoW solution
    Relay->>Host: Forward join request

    Host->>Relay: Approve (token)
    Relay->>Joiner: Connected

    Host->>Relay: Forward (token)
    Relay->>Joiner: Relayed message
```

## Security

Security is not bolted on — it is structural. Every layer enforces its own guarantees.

### Transport Encryption (DTLS)

All `MCSession` instances — both the primary session and the dedicated relay session — are created with `MCEncryptionPreference.required`. Apple's MultipeerConnectivity framework performs a DTLS handshake before any application data is exchanged.

### Pool Code Authentication

Pool codes are **never** included in Bonjour discovery metadata. A joiner sends the code as part of the invitation context. The host validates it before calling the invitation handler. This prevents passive eavesdroppers from learning the code by observing Bonjour traffic.

### Brute-Force Protection

A global rate limiter tracks total wrong code attempts across all peers — 10 failures in 60 seconds triggers a 30-second cooldown. This cannot be bypassed by rotating peer identities. Per-peer tracking via `DeviceBlockListService` provides supplementary defense.

### Remote Relay Security ([StealthRelay](https://github.com/Olib-AI/StealthRelay))

| Layer | Mechanism |
|-------|-----------|
| **Host Authentication** | Ed25519 signature over `pool_id \|\| timestamp \|\| nonce` where nonce is a server-issued per-connection challenge; timestamp window tightened to 30 seconds |
| **E2E Relay Encryption** | AES-GCM encryption with a key derived from the pool shared secret via HKDF-SHA256 (`stealth-ws-encrypt` info); the relay server sees only opaque ciphertext |
| **Session Tokens** | 32-byte server-issued token required for all privileged operations from both host and guest peers; included in Forward frames for all roles (constant-time comparison) |
| **Invitation Tokens** | Ed25519-signed URLs with HMAC proof-of-possession, configurable expiry and max uses, `server_address` bound in signature |
| **Proof-of-Work** | SHA-256 hashcash (18-bit difficulty) required before join requests are forwarded to the host |
| **TLS Pinning** | SPKI SHA-256 hash pinning via `URLSessionDelegate` (optional, for production deployments) |
| **Server Claiming** | One-time claim code binds a server to a host identity; the code is destroyed after use |
| **Display Name Sanitization** | All display names are stripped of control characters, newlines, and truncated to 64 characters before logging or storage |
| **Per-Pool Isolation** | Pending joins, session tokens, and server URLs are all scoped per-pool — no cross-pool state leakage |

### Relay Envelope Integrity (HMAC-SHA256)

Every outgoing `RelayEnvelope` is signed with an HMAC computed over its immutable routing fields, each length-prefixed to prevent concatenation forgery:

- `originPeerID` (length-prefixed)
- `destinationPeerID` (length-prefixed)
- `poolID`
- `messageID`
- `maxTTL` (constant, not the mutable per-hop TTL)
- `timestamp`

The HMAC key is derived from a pool-level shared secret (not the pool UUID) using HKDF-SHA256. Verification uses CryptoKit's constant-time `isValidAuthenticationCode`. Envelopes without HMAC are rejected — no backwards-compatibility fallback.

### Loop and Amplification Prevention

| Mechanism | What it prevents |
|-----------|-----------------|
| **TTL** (default 5, max 5) | Messages circulating indefinitely |
| **Hop path** | Relaying to a peer already in the path |
| **Deduplication cache** (10,000 entries, 5-min expiry) | Processing the same message twice |
| **Message expiry** (5 minutes) | Replay of old messages |
| **Pool ID validation** | Cross-pool message injection |
| **Topology broadcast freshness** (120s max age) | Replay of stale routing info |
| **Topology broadcast HMAC** (HMAC-SHA256) | Unsigned or tampered topology broadcasts are rejected when a pool shared secret is set |
| **WebSocket frame size limit** (1 MB) | Memory exhaustion from oversized frames sent by malicious servers |

### Inbound Size Limits

All received data — on both the primary `MCSessionDelegate` and the relay session delegate — is checked against a 10 MB hard limit before any decoding is attempted.

### Separate Relay Service Type

Relay discovery operates on a distinct Bonjour service type to prevent DTLS handshake state from colliding with the primary session. The relay session uses its own `MCSession`, `MCPeerID`, and delegate handler, fully isolated from the primary connection.

### Pool Persistence Across Host Disconnect

The relay decouples pool authority from host presence: the pool's identity is the bound Ed25519 public key, not the host's current WebSocket connection. When the host's connection drops, the relay marks the pool host-offline (broadcasting `pool_host_status { online: false, offline_since }`) but keeps the pool, peers, invitations, and per-pool config in place. The host's session token is wiped so a leaked token can't be replayed.

The host reclaims the pool by re-running `host_auth` with the same Ed25519 key and the same `pool_id` — the relay rebinds in place and emits `pool_host_status { online: true }`. A `host_auth` with a different pubkey targeting the same `pool_id` is rejected with `403 pool host pubkey mismatch`. New invitations and join approvals still require the host to be live (no auto-approve) — `JoinRequest` while host-offline returns `JoinRejected.reason = "host_offline_unavailable"`.

A 60-second eviction sweep destroys pools whose host has been offline longer than `[pool] host_offline_ttl_secs` (default 24h) or that are simultaneously empty + host-offline for `empty_grace_secs` (default 5min). Targeted forwards to an offline host buffer in the existing per-peer queue and replay on rebind.

### Tunnel Exit (VPN-like)

The relay can act as a network exit for authenticated pool members — opening real TCP/UDP sockets to internet destinations and bridging bytes back over the WebSocket. Three gates apply on every `tunnel_open`:

1. **Server-wide** — the relay operator must set `[tunnel] enabled = true`.
2. **Per-pool** — the pool host approves members via `update_pool_config { tunnel_exit_enabled: true }`. The host themselves bypasses this gate; it controls *member* access.
3. **Authentication** — the connection must have completed `host_auth_success` or `join_accepted`.

Failures at any gate respond with `tunnel_close { reason: "policy_denied" }`. The relay also default-denies SSRF-prone targets (RFC1918, loopback, link-local, ULA) and abuse-prone ports (SMTP / IRC) — operators can override.

Bulk bytes ride binary WebSocket frames on the same port (no second listener, no proxy reconfiguration):

```
TUNNEL_DATA   [0x01][stream_id u32 BE][sequence u32 BE][payload ≤ 32 KiB]
TUNNEL_UDP    [0x02][stream_id u32 BE][datagram]
```

Type byte `0x00` is reserved as a framing-error sentinel and `0x80..=0xFF` is reserved for future channels — both rejected. Binary frames received before authentication terminate the WebSocket with code `1008 policy violation`. The control plane (`tunnel_open`, `tunnel_close`, `tunnel_window_update`, `tunnel_dns_query`, `tunnel_dns_response`, `tunnel_error`) stays JSON for debuggability.

What the relay can and cannot see when acting as an exit:

| Data | Visible to Relay? | Notes |
|------|-------------------|-------|
| Destination hostname / port | Yes | Required for the upstream connect |
| TCP / UDP byte counts and timing | Yes | Inherent in the bridge |
| **HTTPS payload (TLS body)** | **No** | TLS is end-to-end member↔destination |
| Plain HTTP body | Yes | Plain HTTP is unencrypted by design |

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/ConnectionPool.git", from: "1.5.0")
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

### Hosting a Remote Pool

```swift
import ConnectionPool

let viewModel = ConnectionPoolViewModel()

// Set the relay server URL and create the pool
viewModel.createRemotePool(serverURL: "10.0.0.4:9090")

// If the server is unclaimed, provide the claim code from Docker logs
viewModel.claimCode = "abcd-1234-..."
viewModel.submitClaimCode()

// Create an invitation link for others to join
viewModel.createRemoteInvitation(maxUses: 1, expiresInSecs: 300)

// The invitation URL is available via currentRemoteInvitation
if let invitation = viewModel.currentRemoteInvitation {
    print("Share this link: \(invitation.url)")
}
```

### Joining a Remote Pool

```swift
import ConnectionPool

let viewModel = ConnectionPoolViewModel()

// Join using an invitation URL
viewModel.invitationURLInput = "stealth://invite/..."
viewModel.joinViaInvitation()
```

### Disconnecting

```swift
manager.disconnect()
```

### Tunnel-Exit Through the Relay

When the relay is configured with `[tunnel] enabled = true` and the pool host has approved tunnel exit, any pool member can route TCP/UDP traffic through the relay's network. The relay's IP becomes the visible exit address; TLS to the destination stays end-to-end.

```swift
import ConnectionPool

// Host-side: approve members to use the relay as an exit. The host bypasses
// this flag for their own traffic — it gates members.
try await manager.setTunnelExitEnabled(true)

// Member-side (or host using their own approved relay): construct a client
// against the active WebSocketTransport, then open streams.
let client = RelayTunnelClient(
    transport: manager.remoteTransport!,
    availabilityProvider: { @Sendable in
        await MainActor.run {
            manager.remoteTransport != nil
                && (manager.isHost || manager.hostTunnelExitEnabled)
        }
    }
)

let stream = try await client.openStream(
    to: .hostname(host: "example.com", port: 443),
    network: .tcp
)
try await stream.send(httpsClientHello)
for try await chunk in stream.receive {
    // ciphertext — TLS is end-to-end with example.com
}
await stream.close()
```

The relay rejects `tunnel_open` with `tunnel_close { reason: "policy_denied" }` when the server-wide flag is off, the per-pool flag is off (members only), the destination is in the relay's CIDR/port deny list, or the connection isn't authenticated to a pool. `policy_denied` posts `RelayTunnelKillSwitchTriggered` so the host app can drive a kill-switch UI.

### Host-Offline Behavior

The pool persists when the host's WebSocket drops. Members keep chatting, calling, gaming, and tunneling. Observe the published state to drive a UI pill:

```swift
manager.$hostOnline.combineLatest(manager.$hostOfflineSince)
    .sink { online, since in
        if !online, let since {
            print("Host offline since \(since)")
        }
    }
```

While the host is offline, new join attempts surface as `TransportError.hostOffline` ("The pool host is currently offline. Try again later."). The host re-authenticating with the same Ed25519 identity and `pool_id` rebinds to the existing pool — no fresh `pool_id` is issued, members reconnect transparently.

## Self-Hosting the Relay Server

The relay server is a standalone Rust project: [StealthRelay](https://github.com/Olib-AI/StealthRelay)

```bash
# Quick start with Docker
docker run -p 9090:9090 -p 127.0.0.1:9091:9091 ghcr.io/olib-ai/stealth-relay:latest

# With Docker Compose (recommended)
docker compose -f docker/docker-compose.yml up -d

# With Cloudflare Tunnel (production)
docker compose -f docker/docker-compose.yml \
               -f docker/docker-compose.cloudflared.yml up -d
```

See the [StealthRelay README](https://github.com/Olib-AI/StealthRelay) for full deployment documentation.

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

### Injecting Encrypted Remote Pool State Storage

```swift
// Same protocol as block list storage — reuse your SecureStorage implementation
ConnectionPoolConfiguration.remotePoolStateStorageProvider = SecureStorage()
```

When set, `RemotePoolState` persists through this provider instead of plain `UserDefaults`, preventing connection history (server URL, pool ID, host status) from being stored unencrypted.

## API Reference

### Core Services

| Type | Description |
|------|-------------|
| `ConnectionPoolManager` | Main entry point. Manages hosting, browsing, joining, sending, and peer lifecycle. `@MainActor`, `ObservableObject`. |
| `MeshRelayService` | Coordinates multi-hop message routing, topology broadcasts, deduplication, and HMAC verification. |
| `MultiplayerGameService` | Session management for multiplayer games: invitations, ready checks, state sync, forfeit, disconnect recovery. |
| `DeviceBlockListService` | Persistent block list with pluggable storage backend. |
| `WebSocketTransport` | WebSocket-based transport for remote relay mode. Handles HostAuth, JoinRequest, PoW solving, heartbeats, automatic reconnection, and binary tunnel frames. |
| `RemotePoolService` | Manages host Ed25519 identity (Keychain-stored), invitation creation/parsing, and QR code generation. |
| `ConnectionPoolViewModel` | SwiftUI-ready view model bridging both local and remote transport modes. |
| `RelayTunnelClient` | Actor that opens TCP/UDP streams through the relay (tunnel-exit / VPN-like). Per-stream credit-based flow control, monotonic stream IDs, async-stream-based receive, DNS query continuations. |
| `TunnelStream` | Bidirectional byte pipe for one tunnel stream. `send(_:)`, `receive` (`AsyncThrowingStream<Data, Error>`), `close()`. |

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
| `RemotePoolConfiguration` | Settings for remote relay connections: server URL, pool name, max peers, heartbeat interval, SPKI pin hash. |
| `RemotePoolState` | Persisted state for remote pool connections (server URL, pool ID, claim status). Storage is pluggable via `remotePoolStateStorageProvider` (defaults to `UserDefaults`). |
| `RemoteInvitation` | An active invitation with token ID, shareable URL, expiry, and max uses. |
| `ParsedInvitation` | Decoded invitation URL fields: pool ID, token secret, server address, host fingerprint. |
| `RemoteHostIdentity` | Ed25519 signing identity for the pool host (Keychain-stored private key). |
| `ServerFrame` | All WebSocket frame types for client-server communication (HostAuth, Forward, JoinRequest, tunnel control plane, `pool_host_status`, etc.). |
| `BlockedDevice` | A blocked device entry with peer ID, display name, reason, and timestamp. |
| `TunnelDestination` | Tagged union of `.hostname(host:port:)`, `.ipv4(address:port:)`, `.ipv6(address:port:)` for `tunnel_open`. |
| `PoolHostStatusData` | Payload of the `pool_host_status` server frame: `online: Bool`, `offlineSince: Int64?`. |
| `TunnelOpenData` / `TunnelCloseData` / `TunnelWindowUpdateData` / `TunnelDnsQueryData` / `TunnelDnsResponseData` / `TunnelErrorData` | Tunnel control-plane frame payloads. Field names mirror the wire JSON exactly. |
| `TunnelLimits` | Hot-path constants: `maxDataChunkBytes` (32 KiB), `initialReceiveWindow` (256 KiB), `windowUpdateThreshold` (64 KiB), `connectTimeoutSeconds` (15s). |

### Protocols

| Type | Description |
|------|-------------|
| `ConnectionPoolLogger` | Inject custom logging. Receives message, level, category, file, function, line. |
| `BlockListStorageProvider` | Pluggable persistence for the device block list (save/load `Data` by key). |
| `PoolAppLifecycle` | Lifecycle hooks: activate, background, suspend, terminate, memory warning. |
| `RelayTunnelClientType` | Public surface of `RelayTunnelClient`: `openStream`, `resolveDNS`, `isAvailable`, `hostPeerID`. Lets app code abstract over the concrete actor for testing or alternate transports. |

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
| `TunnelNetwork` | `.tcp`, `.udp` |
| `TunnelCloseReason` | `.peerClosed`, `.aborted`, `.idleTimeout`, `.policyDenied`, `.destinationUnreachable`, `.connectionRefused`, `.timeout`, `.streamLimit`, `.protocolError` |
| `DnsRecordType` | `.a`, `.aaaa`, `.cname`, `.txt` |
| `TunnelErrorCode` | `.policyDenied`, `.destinationUnreachable`, `.connectionRefused`, `.timeout`, `.protocolError`, `.resourceExhausted` |
| `TransportError` | `.notConnected`, `.invalidPoolCode`, `.peerNotFound`, `.encryptionFailed`, `.serializationFailed`, `.peerBlocked`, `.connectionFailed(Error)`, `.invalidConfiguration`, `.poolFull`, `.unsupportedOperation`, `.authenticationFailed(String)`, `.hostOffline` |

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
- [StealthRelay](https://github.com/Olib-AI/StealthRelay) — Self-hosted Rust relay server for remote pool connections
- [Apple MultipeerConnectivity](https://developer.apple.com/documentation/multipeerconnectivity) — Local transport layer
- [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit) — HMAC-SHA256, HKDF key derivation, Ed25519 signing

## Contributing

Contributions are welcome! Please ensure:

1. Code compiles under Swift 6 strict concurrency
2. All public APIs are documented
3. Actor isolation is maintained for thread safety
4. No use of `@preconcurrency` escape hatches unless unavoidable and documented

## Security

If you discover a security vulnerability, please report it privately to security@olib.ai rather than opening a public issue.
