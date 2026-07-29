# Security

[Back to README](../README.md)

Security is not bolted on. It is structural, and every layer enforces its own guarantees.

## Contents

- [Transport Encryption (DTLS)](#transport-encryption-dtls)
- [Pool Code Authentication](#pool-code-authentication)
- [Brute-Force Protection](#brute-force-protection)
- [Remote Relay Security](#remote-relay-security)
- [Relay Envelope Integrity (HMAC-SHA256)](#relay-envelope-integrity-hmac-sha256)
- [Loop and Amplification Prevention](#loop-and-amplification-prevention)
- [Inbound Size Limits](#inbound-size-limits)
- [Separate Relay Service Type](#separate-relay-service-type)
- [Pool Persistence Across Host Disconnect](#pool-persistence-across-host-disconnect)
- [Tunnel Exit (VPN-like)](#tunnel-exit-vpn-like)

## Transport Encryption (DTLS)

All `MCSession` instances, both the primary session and the dedicated relay session, are created with `MCEncryptionPreference.required`. Apple's MultipeerConnectivity framework performs a DTLS handshake before any application data is exchanged.

## Pool Code Authentication

Pool codes are **never** included in Bonjour discovery metadata. A joiner sends the code as part of the invitation context. The host validates it before calling the invitation handler. This prevents passive eavesdroppers from learning the code by observing Bonjour traffic.

## Brute-Force Protection

A global rate limiter tracks total wrong code attempts across all peers: 10 failures in 60 seconds triggers a 30-second cooldown. This cannot be bypassed by rotating peer identities. Per-peer tracking via `DeviceBlockListService` provides supplementary defense.

## Remote Relay Security

Provided by [StealthRelay](https://github.com/Olib-AI/StealthRelay).

| Layer | Mechanism |
|-------|-----------|
| **Host Authentication** | Ed25519 signature over `pool_id \|\| timestamp \|\| nonce` where nonce is a server-issued per-connection challenge; timestamp window tightened to 30 seconds |
| **E2E Relay Encryption** | AES-GCM encryption with a key derived from the pool shared secret via HKDF-SHA256 (`stealth-ws-encrypt` info); the relay server sees only opaque ciphertext |
| **Session Tokens** | 32-byte server-issued token required for all privileged operations from both host and guest peers; included in Forward frames for all roles (constant-time comparison) |
| **Invitation Tokens** | Ed25519-signed URLs with HMAC proof-of-possession, configurable expiry and max uses, `server_address` bound in signature |
| **Proof-of-Work** | SHA-256 hashcash (18-bit difficulty) required before join requests are forwarded to the host |
| **TLS Pinning** | SPKI SHA-256 hash pinning via `URLSessionDelegate` (optional, for production deployments) |
| **Server Claiming** | One-time claim code binds a server to a host identity; the code is destroyed after use |
| **Display Name Sanitization** | All display names are stripped of control characters and newlines, then truncated to 64 characters before logging or storage |
| **Per-Pool Isolation** | Pending joins, session tokens, and server URLs are all scoped per-pool, so there is no cross-pool state leakage |

## Relay Envelope Integrity (HMAC-SHA256)

Every outgoing `RelayEnvelope` is signed with an HMAC computed over its immutable routing fields, each length-prefixed to prevent concatenation forgery:

- `originPeerID` (length-prefixed)
- `destinationPeerID` (length-prefixed)
- `poolID`
- `messageID`
- `maxTTL` (constant, not the mutable per-hop TTL)
- `timestamp`

The HMAC key is derived from a pool-level shared secret (not the pool UUID) using HKDF-SHA256. Verification uses CryptoKit's constant-time `isValidAuthenticationCode`. Envelopes without HMAC are rejected, with no backwards-compatibility fallback.

## Loop and Amplification Prevention

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

## Inbound Size Limits

All received data, on both the primary `MCSessionDelegate` and the relay session delegate, is checked against a 10 MB hard limit before any decoding is attempted.

## Separate Relay Service Type

Relay discovery operates on a distinct Bonjour service type to prevent DTLS handshake state from colliding with the primary session. The relay session uses its own `MCSession`, `MCPeerID`, and delegate handler, fully isolated from the primary connection.

## Pool Persistence Across Host Disconnect

The relay decouples pool authority from host presence: the pool's identity is the bound Ed25519 public key, not the host's current WebSocket connection. When the host's connection drops, the relay marks the pool host-offline (broadcasting `pool_host_status { online: false, offline_since }`) but keeps the pool, peers, invitations, and per-pool config in place. The host's session token is wiped so a leaked token cannot be replayed.

The host reclaims the pool by re-running `host_auth` with the same Ed25519 key and the same `pool_id`. The relay rebinds in place and emits `pool_host_status { online: true }`. A `host_auth` with a different pubkey targeting the same `pool_id` is rejected with `403 pool host pubkey mismatch`. New invitations and join approvals still require the host to be live (no auto-approve): a `JoinRequest` while host-offline returns `JoinRejected.reason = "host_offline_unavailable"`.

A 60-second eviction sweep destroys pools whose host has been offline longer than `[pool] host_offline_ttl_secs` (default 24h) or that are simultaneously empty and host-offline for `empty_grace_secs` (default 5min). Targeted forwards to an offline host buffer in the existing per-peer queue and replay on rebind.

### Member Rejoin Without Host

The host's *approval* is a one-time act. The relay tracks an `approved_peers` set (Ed25519 pubkeys) per pool, populated when the host sends `JoinApproval { approved: true }` and pruned on `KickPeer`. Once approved, a member can reconnect indefinitely via the `member_rejoin` frame:

- Client signs `b"STEALTH_MEMBER_REJOIN_V1:" || pool_uuid_bytes || timestamp_be || nonce_raw` with their persistent Ed25519 key
- Relay verifies the signature, checks the pubkey against `approved_peers`, and issues `JoinAccepted` directly, with no host round-trip
- Works whether the host is online or offline
- Same-pubkey reconnect from a fresh connection evicts the stale connection with `Kicked { reason: "rejoined_elsewhere" }`
- A `403 not_approved` or `404 pool_not_found` is a terminal signal: the iOS client purges the saved identity and `RemoteMemberRecord`, surfacing "membership revoked" or "pool no longer exists"

This makes host disconnection *truly* transparent. Members can close the app, restart their device, or lose Wi-Fi for an hour, and still pick up right where they left off.

## Tunnel Exit (VPN-like)

The relay can act as a network exit for authenticated pool members, opening real TCP/UDP sockets to internet destinations and bridging bytes back over the WebSocket. Three gates apply on every `tunnel_open`:

1. **Server-wide**: the relay operator must set `[tunnel] enabled = true`.
2. **Per-pool**: the pool host approves members via `update_pool_config { tunnel_exit_enabled: true }`. The host themselves bypasses this gate; it controls *member* access.
3. **Authentication**: the connection must have completed `host_auth_success` or `join_accepted`.

Failures at any gate respond with `tunnel_close { reason: "policy_denied" }`. The relay also default-denies SSRF-prone targets (RFC1918, loopback, link-local, ULA) and abuse-prone ports (SMTP, IRC), which operators can override.

Bulk bytes ride binary WebSocket frames on the same port, so there is no second listener and no proxy reconfiguration:

```
TUNNEL_DATA   [0x01][stream_id u32 BE][sequence u32 BE][payload ≤ 32 KiB]
TUNNEL_UDP    [0x02][stream_id u32 BE][datagram]
```

Type byte `0x00` is reserved as a framing-error sentinel and `0x80..=0xFF` is reserved for future channels; both are rejected. Binary frames received before authentication terminate the WebSocket with code `1008 policy violation`. The control plane (`tunnel_open`, `tunnel_close`, `tunnel_window_update`, `tunnel_dns_query`, `tunnel_dns_response`, `tunnel_error`) stays JSON for debuggability.

What the relay can and cannot see when acting as an exit:

| Data | Visible to Relay? | Notes |
|------|-------------------|-------|
| Destination hostname / port | Yes | Required for the upstream connect |
| TCP / UDP byte counts and timing | Yes | Inherent in the bridge |
| **HTTPS payload (TLS body)** | **No** | TLS is end-to-end between member and destination |
| Plain HTTP body | Yes | Plain HTTP is unencrypted by design |

For client-side usage, see [Tunnel Exit Through the Relay](QuickStart.md#tunnel-exit-through-the-relay).

## Reporting a Vulnerability

See [SECURITY.md](../SECURITY.md). Report privately to security@olib.ai rather than opening a public issue.
