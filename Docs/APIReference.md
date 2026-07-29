# API Reference

[Back to README](../README.md)

## Contents

- [Core Services](#core-services)
- [Models](#models)
- [Protocols](#protocols)
- [Enumerations](#enumerations)

## Core Services

| Type | Description |
|------|-------------|
| `ConnectionPoolManager` | Main entry point. Manages hosting, browsing, joining, sending, and peer lifecycle. `@MainActor`, `ObservableObject`. |
| `MeshRelayService` | Coordinates multi-hop message routing, topology broadcasts, deduplication, and HMAC verification. |
| `MultiplayerGameService` | Session management for multiplayer games: invitations, ready checks, state sync, forfeit, disconnect recovery. |
| `DeviceBlockListService` | Persistent block list with pluggable storage backend. |
| `WebSocketTransport` | WebSocket-based transport for remote relay mode. Handles HostAuth, JoinRequest, PoW solving, heartbeats, automatic reconnection, and binary tunnel frames. |
| `RemotePoolService` | Manages host Ed25519 identity (Keychain-stored), invitation creation and parsing, and QR code generation. |
| `ConnectionPoolViewModel` | SwiftUI-ready view model bridging both local and remote transport modes. |
| `RelayTunnelClient` | Actor that opens TCP/UDP streams through the relay (tunnel-exit, VPN-like). Per-stream credit-based flow control, monotonic stream IDs, async-stream-based receive, DNS query continuations. |
| `TunnelStream` | Bidirectional byte pipe for one tunnel stream. `send(_:)`, `receive` (`AsyncThrowingStream<Data, Error>`), `close()`. |

## Models

| Type | Description |
|------|-------------|
| `Peer` | A connected peer with display name, profile, connection type (direct or relayed), and status. |
| `DiscoveredPeer` | A nearby peer found via Bonjour that has not yet joined. Includes relay metadata. |
| `PoolSession` | An active pool session with host info, peer list, max peers, and encryption flag. |
| `PoolConfiguration` | Settings for creating a new pool: name, max peers, encryption, auto-accept, pool code generation. |
| `PoolMessage` | A typed message (chat, game state, game action, system, relay, key exchange, and so on) with encoded payload. |
| `RelayEnvelope` | Routing wrapper for multi-hop messages: TTL, hop path, pool ID, HMAC, encrypted payload. |
| `MeshTopology` | Thread-safe (NSLock) distributed neighbor map with BFS shortest-path routing. |
| `TopologyBroadcast` | Payload for sharing a peer's direct neighbors with the mesh. |
| `PoolUserProfile` | User-facing profile: display name, avatar emoji, color index. |
| `RemotePoolConfiguration` | Settings for remote relay connections: server URL, pool name, max peers, heartbeat interval, SPKI pin hash. |
| `RemotePoolState` | Persisted state for remote pool connections (server URL, pool ID, claim status). Storage is pluggable via `remotePoolStateStorageProvider` (defaults to `UserDefaults`). |
| `RemoteInvitation` | An active invitation with token ID, shareable URL, expiry, and max uses. |
| `ParsedInvitation` | Decoded invitation URL fields: pool ID, token secret, server address, host fingerprint. |
| `RemoteHostIdentity` | Ed25519 signing identity for the pool host (Keychain-stored private key). |
| `RemoteMemberIdentity` | Ed25519 signing identity for a pool member (Keychain-stored private key, scoped per `serverURL + poolID`). Reused across app launches so the relay's `approved_peers` lookup recognizes returning members. |
| `RemoteMemberRecord` | Persistent ledger entry for a remote pool the user has previously joined: serverURL, poolID, memberPublicKeyBase64, displayName, firstJoinedAt, lastSuccessfulConnectAt. Stored via the pluggable `remotePoolStateStorageProvider`. |
| `ServerFrame` | All WebSocket frame types for client-server communication (HostAuth, Forward, JoinRequest, tunnel control plane, `pool_host_status`, and others). |
| `BlockedDevice` | A blocked device entry with peer ID, display name, reason, and timestamp. |
| `TunnelDestination` | Tagged union of `.hostname(host:port:)`, `.ipv4(address:port:)`, `.ipv6(address:port:)` for `tunnel_open`. |
| `PoolHostStatusData` | Payload of the `pool_host_status` server frame: `online: Bool`, `offlineSince: Int64?`. |
| `TunnelOpenData` / `TunnelCloseData` / `TunnelWindowUpdateData` / `TunnelDnsQueryData` / `TunnelDnsResponseData` / `TunnelErrorData` | Tunnel control-plane frame payloads. Field names mirror the wire JSON exactly. |
| `TunnelLimits` | Hot-path constants: `maxDataChunkBytes` (32 KiB), `initialReceiveWindow` (256 KiB), `windowUpdateThreshold` (64 KiB), `connectTimeoutSeconds` (15s). |

## Protocols

| Type | Description |
|------|-------------|
| `ConnectionPoolLogger` | Inject custom logging. Receives message, level, category, file, function, line. |
| `BlockListStorageProvider` | Pluggable persistence for the device block list (save and load `Data` by key). |
| `PoolAppLifecycle` | Lifecycle hooks: activate, background, suspend, terminate, memory warning. |
| `RelayTunnelClientType` | Public surface of `RelayTunnelClient`: `openStream`, `resolveDNS`, `isAvailable`, `hostPeerID`. Lets app code abstract over the concrete actor for testing or alternate transports. |

## Enumerations

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
