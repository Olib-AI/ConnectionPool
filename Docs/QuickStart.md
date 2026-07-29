# Quick Start

[Back to README](../README.md)

Install the package first: see [Installation](Installation.md).

## Contents

- [Hosting a Pool](#hosting-a-pool)
- [Joining a Pool](#joining-a-pool)
- [Sending and Receiving Messages](#sending-and-receiving-messages)
- [Hosting a Remote Pool](#hosting-a-remote-pool)
- [Joining a Remote Pool](#joining-a-remote-pool)
- [Disconnecting](#disconnecting)
- [Tunnel Exit Through the Relay](#tunnel-exit-through-the-relay)
- [Returning Members (Auto-Rejoin)](#returning-members-auto-rejoin)
- [Host-Offline Behavior](#host-offline-behavior)

## Hosting a Pool

```swift
import ConnectionPool

let manager = ConnectionPoolManager.shared

// Configure logging (optional, falls back to os.Logger)
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

## Joining a Pool

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

## Sending and Receiving Messages

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

## Hosting a Remote Pool

Requires a running relay server: see [Relay Server](RelayServer.md).

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

## Joining a Remote Pool

```swift
import ConnectionPool

let viewModel = ConnectionPoolViewModel()

// Join using an invitation URL
viewModel.invitationURLInput = "stealth://invite/..."
viewModel.joinViaInvitation()
```

## Disconnecting

```swift
manager.disconnect()
```

## Tunnel Exit Through the Relay

When the relay is configured with `[tunnel] enabled = true` and the pool host has approved tunnel exit, any pool member can route TCP/UDP traffic through the relay's network. The relay's IP becomes the visible exit address; TLS to the destination stays end-to-end. See [Security: Tunnel Exit](Security.md#tunnel-exit-vpn-like) for the gates and visibility model.

```swift
import ConnectionPool

// Host-side: approve members to use the relay as an exit. The host bypasses
// this flag for their own traffic, so it gates members only.
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
    // Ciphertext, because TLS is end-to-end with example.com
}
await stream.close()
```

The relay rejects `tunnel_open` with `tunnel_close { reason: "policy_denied" }` when the server-wide flag is off, the per-pool flag is off (members only), the destination is in the relay's CIDR/port deny list, or the connection is not authenticated to a pool. `policy_denied` posts `RelayTunnelKillSwitchTriggered` so the host app can drive a kill-switch UI.

## Returning Members (Auto-Rejoin)

Once a member has been approved into a pool, they can reopen the app and reconnect without an invitation and without the host being online:

```swift
// Find pools the user has previously joined on this device
let saved = viewModel.savedRemoteMemberPools

// Tap "Rejoin" on a row
viewModel.rejoinRemotePool(saved[0])

// Or explicitly leave and forget the pool. This drops the Keychain identity
// and the record; the user will need a fresh invitation to come back.
viewModel.leaveRemoteMemberPool()
```

If the relay returns `403 not_approved` (host kicked the member) or `404 pool_not_found` (pool destroyed), the identity and saved record are dropped automatically and the user sees a clear message. Network blips during rejoin do NOT drop saved state.

## Host-Offline Behavior

The pool persists when the host's WebSocket drops. Members keep chatting, calling, gaming, and tunneling. Observe the published state to drive a UI pill:

```swift
manager.$hostOnline.combineLatest(manager.$hostOfflineSince)
    .sink { online, since in
        if !online, let since {
            print("Host offline since \(since)")
        }
    }
```

While the host is offline, new join attempts surface as `TransportError.hostOffline` ("The pool host is currently offline. Try again later."). The host re-authenticating with the same Ed25519 identity and `pool_id` rebinds to the existing pool, so no fresh `pool_id` is issued and members reconnect transparently.
