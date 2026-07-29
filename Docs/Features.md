# Features

[Back to README](../README.md)

## Contents

- [Local Mesh (MultipeerConnectivity)](#local-mesh-multipeerconnectivity)
- [Remote Relay Transport](#remote-relay-transport)
- [Cross-Platform Transport (Android Interop)](#cross-platform-transport-android-interop)

## Local Mesh (MultipeerConnectivity)

- **MultipeerConnectivity-based local P2P**: discover and connect to nearby devices over Wi-Fi and Bluetooth with Bonjour service advertising
- **Mesh networking with multi-hop relay**: messages reach peers beyond direct radio range by hopping through intermediate nodes
- **BFS-based topology routing**: shortest-path routing computed from a distributed neighbor map that each node broadcasts periodically
- **Relay envelope with TTL, loop prevention, and dedup**: every relayed message carries a TTL counter, an ordered hop path for cycle detection, and a UUID checked against a bounded deduplication cache (10,000 entries, 5-minute expiry)
- **HMAC-SHA256 envelope integrity**: routing metadata (origin, destination, pool ID, message ID, timestamp) is signed with a key derived via HKDF from the pool ID; tampered envelopes are dropped
- **DTLS encryption enforced on all sessions**: `MCEncryptionPreference.required` on every `MCSession`, primary and relay alike, so all data in transit is encrypted at the transport layer
- **Pool code authentication**: hosts generate a join code that is never included in Bonjour discovery info; joiners send it as invitation context and the host validates it server-side before accepting
- **Brute-force protection with auto-blocking**: after 5 failed join attempts from the same device (within a 1-hour window), the device is permanently added to the block list
- **Per-peer rate limiting**: a 5-second cooldown between connection attempts from the same peer prevents invitation flooding
- **10 MB inbound message size limit**: oversized payloads are dropped before decoding on both the primary and relay sessions
- **Separate relay service type**: relay discovery uses a distinct Bonjour service type (`stealthos-rly`) to avoid DTLS handshake conflicts with the primary session
- **Persistent device block list**: blocked devices survive app restarts; storage is pluggable via `BlockListStorageProvider` (defaults to `UserDefaults`, can be wired to encrypted storage)
- **Multiplayer game service**: built-in session management for turn-based and real-time games, covering invitations, ready checks, state sync, forfeit handling, and disconnect recovery
- **Configurable logging via protocol injection**: inject your own `ConnectionPoolLogger` at startup; falls back to Apple's `os.Logger` with per-category subsystems
- **App lifecycle protocol**: `PoolAppLifecycle` lets the host app suspend, resume, and terminate pool operations cleanly
- **Zero external dependencies**: only Apple frameworks, namely `MultipeerConnectivity`, `CryptoKit`, `Combine`, `Foundation`, and `os`

## Remote Relay Transport

Backed by [StealthRelay](https://github.com/Olib-AI/StealthRelay). See [Relay Server](RelayServer.md) for deployment.

- **WebSocket transport**: connect to a self-hosted relay server from anywhere via `wss://` (default) or `ws://` if explicitly specified
- **Ed25519 host authentication**: the host signs pool creation with a Keychain-stored Ed25519 identity
- **Invitation-based joining**: shareable `stealth://invite/...` URLs with Ed25519 signatures, HMAC proofs, and configurable expiry
- **Proof-of-Work anti-DoS**: joining peers solve a SHA-256 PoW challenge (18-bit difficulty, roughly 50ms) before the server forwards the request to the host
- **End-to-end encrypted relay messages**: messages relayed via WebSocket are AES-GCM encrypted with a key derived from the pool shared secret via HKDF-SHA256; the relay server sees only opaque ciphertext
- **Session tokens**: all privileged operations (create invitation, kick peer, close pool) require a server-issued session token
- **TLS certificate pinning**: SPKI SHA-256 pin verification via custom `URLSessionDelegate`
- **Server claiming**: first-use server binding via QR code or manual claim code from Docker logs
- **Recovery key after claim**: once a server is claimed, the recovery key is displayed in a dedicated sheet with options to save to the password manager or copy to clipboard; the user must acknowledge before proceeding
- **Automatic reconnection**: exponential backoff with invitation expiry checks; previously-approved peers are auto-accepted on reconnect
- **Relay bridge deduplication**: messages bridged between relay and primary sessions are deduplicated by `PoolMessage.id` to prevent double processing
- **1 MB WebSocket frame limit**: incoming WebSocket frames exceeding 1 MB are dropped before processing to prevent memory exhaustion from malicious servers
- **Cloudflare Tunnel support**: production deployment via `cloudflared` for TLS termination without managing certificates
- **Pool persistence past host disconnect**: when the pool host's WebSocket drops, the pool stays alive on the relay; existing peers keep messaging, calling, gaming, and tunneling. The host re-authenticates with the same Ed25519 key plus `pool_id` to rebind in place. New joins are still gated on the host being online (no auto-approve). Surfaced via `ConnectionPoolManager.hostOnline` and the `pool_host_status` server frame
- **Persistent member identity and rejoin without host**: each member's Ed25519 keypair is stored in the iOS Keychain (scoped per `serverURL + poolID`) and reused across app launches. Once the host has approved a member one time, that member can reconnect indefinitely via the `member_rejoin` frame, with no host involvement, whether the host is online or offline. Saved member records survive cold launches via the pluggable `remotePoolStateStorageProvider`; a `403 not_approved` from the relay (kicked) or `404 pool_not_found` (pool destroyed) drops the saved state cleanly
- **Host-offline join rejection (new joiners only)**: join requests received from never-approved peers while the host is offline are rejected with `JoinRejected.reason == "host_offline_unavailable"` and surfaced as `TransportError.hostOffline` for a friendly user message. Returning members are not affected; they take the `member_rejoin` path
- **Tunnel-exit (VPN-like) client**: `RelayTunnelClient` opens TCP/UDP streams through the relay so the relay's IP becomes the visible exit address. Used by StealthOS's in-app proxy to route browser traffic; TLS to the destination remains end-to-end (the relay sees only ciphertext). Per-pool host approval gate via `update_pool_config { tunnel_exit_enabled }`; the host bypasses their own gate
- **Binary hot-path frames**: `TUNNEL_DATA` (`0x01`) and `TUNNEL_UDP` (`0x02`) ride binary WebSocket frames with a fixed-size big-endian header (no base64, no JSON parse on the byte path). The control plane (open, close, window_update, dns, error) stays JSON for debuggability
- **Credit-based flow control**: per-stream send-credit window (256 KiB initial; the relay grants additional credit via `tunnel_window_update` as it consumes bytes). Stops the WebSocket from getting evicted by the relay's slow-consumer threshold under sustained traffic
- **Tunnel kill switch**: a `tunnel_close { reason: "policy_denied" }` from the relay (server flag off, per-pool flag off, denied CIDR/port) trips a `RelayTunnelKillSwitchTriggered` notification consumers can hook to block all egress until the user resolves it

## Cross-Platform Transport (Android Interop)

- **Android interoperability**: the `CrossPlatform` module speaks a platform-neutral wire protocol with a matching Kotlin implementation, so iOS and Android devices can discover each other and exchange encrypted messages over the local network
- **Canonical JSON wire format**: keys sorted by Unicode code point, no insignificant whitespace, ISO-8601 millisecond timestamps, and RFC-4648 padded base64 payloads, guaranteeing byte-identical encoding across Swift and Kotlin
- **Bonjour/mDNS plus TCP discovery**: `NWListener` advertising and `NWBrowser` browsing with TXT records; uses a service type disjoint from the MultipeerConnectivity transport so the two never collide
- **ChaCha20-Poly1305 with HKDF-SHA256**: a 6-digit tap code plus per-side handshake nonces derive directional session keys; frames are length-prefixed AEAD with strict monotone sequence counters and replay rejection
- **Session resume**: guests reconnect after a drop and re-handshake under fresh keys; the host replays unacknowledged frames from its outbound buffer
- **Host-side hardening**: per-IP hello rate limiting, handshake timeouts, device blocking, and a closed error taxonomy mirrored on both platforms
- **Transport-agnostic core**: `CrossPlatformPool` operates on a `RawConnection` abstraction; production wraps `NWConnection` via `SocketConnection`, while tests use in-memory pairs
- **Frozen reference vectors**: cross-platform compatibility is locked by shared test vectors (HKDF, handshake, encrypted frames, game actions) asserted byte-equal on both the Swift and Kotlin sides
- **Fully coexistent**: a separate type set (`CrossPlatformPoolMessage`, `CrossPlatformTransportError`, and friends) keeps the legacy MultipeerConnectivity and relay wire formats byte-identical for existing consumers
