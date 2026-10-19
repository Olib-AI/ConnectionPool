# Security

[Back to README](../README.md)

Security is not bolted on. It is structural, and every layer enforces its own guarantees.

## Contents

- [Transport Encryption (DTLS)](#transport-encryption-dtls)
- [Pool Code Authentication](#pool-code-authentication)
- [Brute-Force Protection](#brute-force-protection)
- [Remote Relay Security](#remote-relay-security)
- [Remote Transport Outer Layer](#remote-transport-outer-layer)
- [Relay Envelope Integrity (HMAC-SHA256)](#relay-envelope-integrity-hmac-sha256)
- [Relayed Key Exchange](#relayed-key-exchange)
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
| **Outer encryption layer** | Every frame between members is AES-256-GCM encrypted with a host-generated pool transport secret the relay never sees (StealthOS 1.5.0+; see [Remote Transport Outer Layer](#remote-transport-outer-layer)). Pools with a StealthOS 1.4.x member or host run without it (the inner Pool Chat E2E layer still applies) and the app says so |
| **Session Tokens** | 32-byte server-issued token required for all privileged operations from both host and guest peers; included in Forward frames for all roles (constant-time comparison) |
| **Invitation Tokens** | Ed25519-signed URLs with HMAC proof-of-possession, configurable expiry and max uses, `server_address` bound in signature |
| **Proof-of-Work** | SHA-256 hashcash (18-bit difficulty) required before join requests are forwarded to the host. The client refuses challenges that are not 32 bytes or ask for more than 26 bits (the relay's top tier), solves under a 90 s budget, cancels on disconnect, and fails the connection with a clear error otherwise |
| **TLS Pinning** | SPKI SHA-256 hash pinning via `URLSessionDelegate` (optional, for production deployments) |
| **Server Claiming** | One-time claim code binds a server to a host identity; the code is destroyed after use |
| **Display Name Sanitization** | All display names are stripped of control characters and newlines, then truncated to 64 characters before logging or storage |
| **Per-Pool Isolation** | Pending joins, session tokens, and server URLs are all scoped per-pool, so there is no cross-pool state leakage |

## Remote Transport Outer Layer

Remote pools talk through StealthRelay. Pool Chat content is already end-to-end encrypted per peer pair, but the relay operator would otherwise see every frame's metadata (message types, sender names, key exchanges, timing per peer). The outer layer encrypts every member-to-member frame with a **pool transport secret** that only the host and approved members hold. Before 1.5.0 this layer existed in code but was never switched on, because no secret was ever distributed.

**Distribution (decision).** The relay builds invitations and knows the token secret in them, so neither the invitation's server-built part nor anything sent through the relay in the clear can carry the secret. Design:

1. The host generates a random 256-bit transport secret (epoch 1) when the pool starts, stored in the Keychain.
2. For each invitation the host also generates a random 256-bit *invite key* and appends `#v2.<base64url(0x02 || inviteKey || hostIdentityKey)>` to the invitation URL **locally**. URL fragments are never sent to a server, and the invitation travels out of band (QR, AirDrop, message), so the relay never learns the invite key. StealthOS 1.4.x ignores the fragment. A present but malformed fragment rejects the invitation, so it cannot be silently stripped to "no fragment".
3. After joining, the member checks that the relay's `host_peer_id` is the host key from the fragment (the relay names hosts and members by their Ed25519 identity keys), then sends a key request: an ephemeral X25519 key and a nonce, signed with its member identity key and MAC'd with the invite key.
4. The host verifies the signature, the invite MAC (first join) or the enrolment (later reconnects, rotations), the nonce and the timestamp. It then seals the secret under `HKDF(X25519(hostEphemeral, memberEphemeral), salt: SHA-256(request), info: "STEALTH_WS_TRANSPORT_KEY_V2" || epoch || inviteKey)` and signs the grant with the host identity key.

The relay forwards these control messages (`"SWK2" || JSON`) but never sees the secret. It cannot impersonate a joiner without the invite key, cannot impersonate the host without the host identity key, and cannot learn the secret from the sealed grant. Embedding the secret directly in the invitation was rejected: anyone who saw the link, approved or not, could read the pool's outer layer forever, and the secret could never be rotated.

**Frames.** `"SWO2" || epoch u32 || sender session u64 || counter u64 || timestamp ms i64 || nonce(12) || AES-256-GCM(frame) || tag`, key `HKDF(secret, salt: poolID, info: "STEALTH_WS_OUTER_V2" || epoch)`, AAD = header || poolID || sender peer ID. Receivers reject frames older than 5 minutes or more than 60 s in the future, and keep a replay window per sender session. Once a pool is protected, plaintext frames are refused (fail closed). A member that is still securing holds its outgoing frames rather than send them in the clear.

**Versions and legacy peers.** The host turns protection on when every member present has enrolled. A pool that has a 1.4.x member at that point stays unprotected, and everyone is told (`OuterLayerStatus.unprotected(legacyPeers:)`, fed into the "older version" warning). Once a pool has been protected it is never turned off. A 1.4.x member who joins later is excluded rather than causing a downgrade, and the UI says so. Members persist "this pool is protected" and refuse a later "protection off" announcement (`downgradeRefused`). Invitations without a fragment come from a 1.4.x host: such sessions run unprotected and are flagged.

**Rotation.** When the host removes or kicks a member, its enrolment is deleted and a new secret (epoch + 1) is generated. Remaining members fetch it with a signed request, and the host switches after they have, or after 10 s. Frames under the previous epoch are accepted for 30 s, never from the removed member. A removed member cannot obtain the new secret.

## Relay Envelope Integrity (HMAC-SHA256)

Envelope integrity is versioned. Version 1 is what StealthOS 1.4.x and older emit; version 2 ships in StealthOS 1.5.0.

**v1** (kept bit-exact for older peers) MACs `originPeerID` and `destinationPeerID` (length-prefixed, but `nil` and `""` encode identically), `poolID`, `messageID`, the constant `maxTTL` and the timestamp (native byte order). It does **not** cover `encryptedPayload`.

**v2** adds a second MAC under a separate key, `HKDF-SHA256(secret, salt: poolID || "StealthOS-RelayEnvelope-HMAC-Salt", info: "envelope-integrity-v2")`, over (all integers big-endian):

```
u32 len || "STEALTH_RELAY_ENVELOPE_V2"
u32 len || originPeerID (UTF-8)
0x00 (broadcast)  |  0x01 || u32 len || destinationPeerID (UTF-8)
poolID (16) || messageID (16)
u32 originTTL
u64 IEEE-754 bits of the JSON timestamp (seconds since 2001)
u64 len || encryptedPayload
```

New JSON keys: `envelopeVersion` (2), `originTTL`, `envelopeHMACV2`, `originSignature`. A 1.5.0 origin attaches **both** MACs, so 1.4.x relays and receivers keep working. 1.5.0 receivers verify only the v2 MAC whenever any v2 key is present, so stripping or corrupting part of v2 never falls back to v1.

The per-hop `ttl` and `hopPath` cannot be MAC'd by the origin. v2 binds `originTTL` instead and enforces `1 <= ttl <= originTTL <= 5`, `hopPath[0] == originPeerID` and `hopPath.count + ttl == originTTL + 1`: a relay can never grant more hops than the origin did. Timestamps more than 120 s in the future are rejected so an envelope cannot outlive the deduplication cache.

**Downgrade rule.** `PeerProtocolLedger` (shared through `ConnectionPoolManager.wireProtocolLedger`) remembers every origin that has sent a valid v2 envelope. A v1-only envelope from such an origin is refused for the rest of the session. A v1-only envelope from an origin never seen with v2 is accepted under the default `LegacyPeerPolicy.warn` and the origin is published in `MeshRelayService.legacyEnvelopeOrigins` for an "older, less secure version" indicator. Set the ledger's policy to `.refuse` to drop v1 entirely.

**Per-sender authenticity.** The pool MAC only proves "a member of this pool": any member could forge any origin. v2 therefore also carries `originSignature`, an Ed25519 signature by the origin over exactly the v2 MAC input, made with a per-session signing key (`EnvelopeSigningKeys`).

- The key travels in the E2E key exchange (`KeyExchangePayload.signingPublicKey`) with `signingKeyBinding`, a signature by that key over `u32 len || "STEALTH_ENVELOPE_SIGNING_KEY_V2" || u32 len || peerID || poolID (16) || X25519 key (32) || Ed25519 key (32)`. The signing key is thereby tied to the peer ID, the pool and the peer's E2E key, so verifying the E2E fingerprint out of band also authenticates it.
- Receivers keep the first valid key per peer for the session (TOFU). A different key for the same peer is refused and reported (`EnvelopeSigningKeys.events`) until the peer's direct, transport-authenticated connection drops or the pool session ends; a new session rotates our own key.
- Verification order: pool MAC (cheap filter), routing invariants, then the signature. A missing or invalid signature is rejected. If this node has no key for the origin (it never exchanged keys with it) the envelope may be forwarded but is never delivered.
- The signature covers the pool ID, so a member of another pool cannot replay it even after re-MACing.

The pool MAC key comes from `PoolIntegritySecret`: `SHA-256(pool code)`, the one secret every member of a local pool shares (the host generates the code, joiners type it). This is the derivation 1.4.x already used. Pools without a code, and remote pools, have no pool-wide secret, so mesh relaying is disabled for them rather than run on a made-up key. Feature packages must use `ConnectionPoolManager.meshRelay` instead of creating their own `MeshRelayService`.

**Introductions.** A v2 envelope may carry `originIntroduction`: the origin's X25519 E2E key, Ed25519 signing key and their binding (128 bytes, covered by the MAC and the signature). A destination with no key for the origin verifies the binding (origin ID, pool, both keys) and the signature end to end, then registers the key (TOFU). A different key for an origin it already knows is refused (`rejectedKeyChange`) and offered to the user (`pendingKeyChangeFingerprint` / `acceptPendingKeyChange`). Relays forward introductions addressed to others without learning or judging them.

**Stripped by a 1.4.x relay.** A 1.4.x relay drops the v2 fields when it re-encodes an envelope. If the origin has already proven v2, the stripped copy is refused (fail closed). When it was addressed to us, `MeshRelayService.unverifiableRelayedMessage` reports it (at most once a minute per origin) so the app can tell the user a message from that peer could not be verified. The content is never delivered.

Golden vectors: `Tests/ConnectionPoolTests/Golden/relay_envelope_hmac_v2.json` (generated independently by `generate_relay_envelope_hmac_v2.py`).

## Relayed Key Exchange

Peers connected only through other peers exchange E2E keys over signed v2 envelopes with introductions (Pool Chat's `RelayedKeyExchangeCoordinator`):

- The request and response introduce each side's X25519 and Ed25519 keys. Intermediate hops cannot alter or swap them in transit, because the binding, the MAC and the signature cover them.
- After first contact, a hop cannot substitute keys. A different signing key is refused and reported, and a different X25519 key raises the chat TOFU key-change event, exactly as for a direct peer.
- Replays are refused: envelopes are deduplicated and expire, each nonce is accepted once, and a response must answer our outstanding request.
- **Limit (by design of any first contact without a prior shared secret):** if a malicious device is the *only* path at the very first contact, it can introduce its own keys to both sides. This cannot be prevented automatically, but it is detectable. The safety code on the security-code screen then differs between the two devices, so comparing it in person or on a call exposes the attacker.

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
