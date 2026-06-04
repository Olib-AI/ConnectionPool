// PeerEvent.swift
// ConnectionPool / CrossPlatform
//
// Lifecycle events emitted by `CrossPlatformSession`. Mirrors Kotlin
// `PeerEvent.kt`. The event stream opens with exactly one `.connected`
// (emitted from the session constructor post-handshake) and closes with
// exactly one `.disconnected`. In between it may emit any number of
// `.error` events for non-fatal protocol surface events the UI may display.
//
// There is intentionally no `.connecting` state: a `CrossPlatformSession`
// only exists after the handshake completes — the pool-level
// `acceptGuest` / `connectAsGuest` driver throws on handshake failure.

import Foundation

/// Summary of a remote peer, surfaced on connection.
public struct CrossPlatformPeerInfo: Sendable, Equatable {
    public let pid: Data
    public let displayName: String
    /// Stable identifier the app uses for `PoolMessage.senderID` — `"host-…"`
    /// or `"guest-…"` per the peer's role in this session.
    public let senderID: String

    public init(pid: Data, displayName: String, senderID: String) {
        precondition(pid.count == 16)
        self.pid = pid
        self.displayName = displayName
        self.senderID = senderID
    }
}

public enum CrossPlatformPeerEvent: Sendable, Equatable {
    case connected(CrossPlatformPeerInfo)
    case disconnected(reason: CrossPlatformTransportError?)
    case error(CrossPlatformTransportError, message: String?)
}
