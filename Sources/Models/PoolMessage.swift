// PoolMessage.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Types of messages that can be sent through the connection pool
public enum PoolMessageType: String, Codable, Sendable {
    case chat = "chat"
    case gameState = "game_state"
    case gameAction = "game_action"
    case gameControl = "game_control"  // For invites, session updates, ready status, etc.
    case system = "system"
    case ping = "ping"
    case pong = "pong"
    case peerInfo = "peer_info"
    case profileUpdate = "profile_update"  // For user profile broadcast
    case keyExchange = "key_exchange"  // For E2E encryption key exchange
    case relay = "relay"  // Mesh relay message containing a RelayEnvelope
    case custom = "custom"
}

/// A message sent through the connection pool
public struct PoolMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: PoolMessageType
    public let senderID: String
    public let senderName: String
    public let timestamp: Date
    public let payload: Data
    public var isReliable: Bool

    public init(
        id: UUID = UUID(),
        type: PoolMessageType,
        senderID: String,
        senderName: String,
        timestamp: Date = Date(),
        payload: Data,
        isReliable: Bool = true
    ) {
        self.id = id
        self.type = type
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.payload = payload
        self.isReliable = isReliable
    }

    /// Create a chat message
    public static func chat(
        from senderID: String,
        senderName: String,
        text: String
    ) -> PoolMessage {
        let chatPayload = ChatPayload(text: text)
        let payloadData = (try? JSONEncoder().encode(chatPayload)) ?? Data()
        return PoolMessage(
            type: .chat,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Create a game state message
    public static func gameState<T: Encodable>(
        from senderID: String,
        senderName: String,
        state: T
    ) -> PoolMessage? {
        guard let payloadData = try? JSONEncoder().encode(state) else { return nil }
        return PoolMessage(
            type: .gameState,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Create a game action message
    public static func gameAction<T: Encodable>(
        from senderID: String,
        senderName: String,
        action: T,
        reliable: Bool = true
    ) -> PoolMessage? {
        guard let payloadData = try? JSONEncoder().encode(action) else { return nil }
        return PoolMessage(
            type: .gameAction,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: reliable
        )
    }

    /// Create a system message
    public static func system(
        from senderID: String,
        senderName: String,
        text: String
    ) -> PoolMessage {
        let systemPayload = SystemPayload(text: text)
        let payloadData = (try? JSONEncoder().encode(systemPayload)) ?? Data()
        return PoolMessage(
            type: .system,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Create a typed system-event message (e.g. "you were removed from the pool").
    ///
    /// Rides the existing `.system` message path so it flows through both the local
    /// MultipeerConnectivity pipeline and the remote WebSocket transport unchanged.
    /// The extra fields in `SystemPayload` are optional, so a plain informational
    /// system message (no `event`) decodes exactly as before — wire-compatible.
    public static func systemEvent(
        from senderID: String,
        senderName: String,
        event: PoolSystemEvent,
        targetPeerID: String,
        text: String
    ) -> PoolMessage {
        let systemPayload = SystemPayload(text: text, event: event, targetPeerID: targetPeerID)
        let payloadData = (try? JSONEncoder().encode(systemPayload)) ?? Data()
        return PoolMessage(
            type: .system,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Create a key exchange message for E2E encryption
    public static func keyExchange(
        from senderID: String,
        senderName: String,
        publicKey: Data
    ) -> PoolMessage {
        let payload = KeyExchangePayload(publicKey: publicKey, senderPeerID: senderID)
        let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        return PoolMessage(
            type: .keyExchange,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Create a profile update message
    public static func profileUpdate(
        from senderID: String,
        senderName: String,
        profile: PoolUserProfile
    ) -> PoolMessage {
        let payload = ProfileUpdatePayload(peerID: senderID, profile: profile)
        let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        return PoolMessage(
            type: .profileUpdate,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Creates a relay message containing a RelayEnvelope
    /// - Parameters:
    ///   - senderID: The peer ID of the sender
    ///   - senderName: The display name of the sender
    ///   - envelope: The relay envelope to transmit through the mesh network
    /// - Returns: A configured PoolMessage, or nil if encoding fails
    public static func relay(
        from senderID: String,
        senderName: String,
        envelope: RelayEnvelope
    ) -> PoolMessage? {
        guard let payloadData = try? JSONEncoder().encode(envelope) else { return nil }
        return PoolMessage(
            type: .relay,
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }

    /// Decode the payload as a specific type
    public func decodePayload<T: Decodable>(as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Payload Types

/// Payload for chat messages
public struct ChatPayload: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// A typed control event carried by a `.system` message.
///
/// Used for administrative signals that a peer must act on, as opposed to plain
/// informational chat notices. New cases can be added without breaking older
/// clients: an unknown raw value simply decodes as `nil` (the field is optional).
public enum PoolSystemEvent: String, Codable, Sendable {
    /// The host removed the recipient from the pool. On receipt, the targeted peer
    /// leaves the pool (member-side `disconnect()`) and surfaces a notice.
    case removedFromPool = "removed_from_pool"
}

/// Payload for system messages.
///
/// `event` / `targetPeerID` are optional and default to `nil`, so a message created
/// via `SystemPayload(text:)` encodes to the exact same JSON as before this field was
/// added — existing peers decode it unchanged (forward/backward compatible).
public struct SystemPayload: Codable, Sendable {
    public let text: String
    /// Optional control event. `nil` for a plain informational system message.
    public let event: PoolSystemEvent?
    /// The peer ID this event is directed at. Receivers ignore events not aimed at them.
    public let targetPeerID: String?

    public init(text: String, event: PoolSystemEvent? = nil, targetPeerID: String? = nil) {
        self.text = text
        self.event = event
        self.targetPeerID = targetPeerID
    }
}

/// Payload for peer info exchange
public struct PeerInfoPayload: Codable, Sendable {
    public let peerID: String
    public let displayName: String
    public let isHost: Bool
    public let capabilities: [String]
    public let profile: PoolUserProfile?

    public init(
        peerID: String,
        displayName: String,
        isHost: Bool,
        capabilities: [String] = [],
        profile: PoolUserProfile? = nil
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.isHost = isHost
        self.capabilities = capabilities
        self.profile = profile
    }
}

/// Payload for profile update broadcast
public struct ProfileUpdatePayload: Codable, Sendable {
    public let peerID: String
    public let profile: PoolUserProfile

    public init(peerID: String, profile: PoolUserProfile) {
        self.peerID = peerID
        self.profile = profile
    }
}

/// Payload for E2E encryption key exchange
public struct KeyExchangePayload: Codable, Sendable {
    public let publicKey: Data
    public let senderPeerID: String

    public init(publicKey: Data, senderPeerID: String) {
        self.publicKey = publicKey
        self.senderPeerID = senderPeerID
    }
}

// MARK: - Message Encoding/Decoding

extension PoolMessage {
    /// Encode the message to Data for transmission
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode a message from received Data.
    ///
    /// **Size Safety:** All inbound data is checked against `ConnectionPoolManager.maxInboundMessageSize`
    /// (10 MB) before reaching this method. Both `MCSessionDelegate.session(_:didReceive:fromPeer:)`
    /// and the relay session handler drop oversized payloads prior to calling `decode(from:)`.
    /// No additional size check is needed here.
    public static func decode(from data: Data) -> PoolMessage? {
        try? JSONDecoder().decode(PoolMessage.self, from: data)
    }
}
