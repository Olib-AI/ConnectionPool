# Architecture

[Back to README](../README.md)

## Contents

- [Component Layout](#component-layout)
- [Mesh Message Flow](#mesh-message-flow)
- [Remote Relay Flow](#remote-relay-flow)

## Component Layout

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

## Mesh Message Flow

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

## Remote Relay Flow

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

## Related Documents

- [Security](Security.md) for the guarantees each layer enforces
- [API Reference](APIReference.md) for the types named above
