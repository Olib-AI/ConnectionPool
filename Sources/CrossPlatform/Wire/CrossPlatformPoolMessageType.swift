// CrossPlatformPoolMessageType.swift
// ConnectionPool / CrossPlatform
//
// Mirror of legacy `PoolMessageType` in `Sources/Models/PoolMessage.swift`
// L10-23, kept as a SEPARATE type so the cross-platform decoder can apply
// its closed-set receive policy (spec §5.2.1 / ADR-0005 §2.2) without
// affecting the legacy MC `PoolMessage` decoder. Wire form: lowercase
// snake_case string.

import Foundation

public enum CrossPlatformPoolMessageType: String, Sendable, Hashable, CaseIterable {
    case chat = "chat"
    case gameState = "game_state"
    case gameAction = "game_action"
    case gameControl = "game_control"
    case system = "system"
    case ping = "ping"
    case pong = "pong"
    case peerInfo = "peer_info"
    case profileUpdate = "profile_update"
    case keyExchange = "key_exchange"
    case relay = "relay"
    case custom = "custom"

    /// Per ADR-0005 §2.2 / spec §5.2.1: an unknown wire value MUST surface as
    /// a typed `CrossPlatformTransportException(.incompatible)` rather than a raw decoding
    /// error. The session reader's outer fence routes `CrossPlatformTransportException` to
    /// the typed `PeerEvent.error(_:_:)` path.
    static func fromWire(_ s: String) throws -> CrossPlatformPoolMessageType {
        if let v = CrossPlatformPoolMessageType(rawValue: s) { return v }
        throw CrossPlatformTransportException(.incompatible, "unknown PoolMessageType wire value: \(s)")
    }
}
