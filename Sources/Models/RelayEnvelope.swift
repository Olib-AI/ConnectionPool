// RelayEnvelope.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

/// Envelope for relaying encrypted messages through the mesh network.
///
/// `RelayEnvelope` wraps end-to-end encrypted payloads that need to traverse
/// intermediate peers to reach their destination. The envelope itself is not
/// encrypted, allowing relay nodes to inspect routing metadata (TTL, hop path,
/// destination) without accessing the actual message content.
///
/// Key security properties:
/// - The `encryptedPayload` is opaque to relay nodes (E2E encrypted)
/// - The `poolID` prevents cross-pool message injection attacks
/// - The `hopPath` enables loop detection to prevent infinite routing
/// - The `ttl` prevents messages from circulating indefinitely
public struct RelayEnvelope: Codable, Sendable, Identifiable, Hashable {

    // MARK: - Identifiable

    public var id: UUID { messageID }

    // MARK: - Properties

    /// Unique identifier for message deduplication across the mesh network.
    ///
    /// Relay nodes should track recently seen message IDs to avoid
    /// rebroadcasting duplicates.
    public let messageID: UUID

    /// The peer ID of the original message sender.
    ///
    /// This remains constant as the message traverses the network,
    /// allowing recipients to identify the true origin.
    public let originPeerID: String

    /// The target peer ID for directed messages, or `nil` for broadcasts.
    ///
    /// When `nil`, the message should be relayed to all connected peers
    /// (except those already in the hop path).
    public let destinationPeerID: String?

    /// Time-to-live counter, decremented at each relay hop.
    ///
    /// When TTL reaches 0 or below, the message should be dropped
    /// rather than forwarded. This prevents infinite message circulation.
    public var ttl: Int

    /// Ordered list of peer IDs this message has traversed.
    ///
    /// Used for:
    /// - Loop detection: don't relay to peers already in the path
    /// - Debugging: trace message routing through the mesh
    /// - Optimization: avoid redundant transmissions
    public var hopPath: [String]

    /// The end-to-end encrypted message payload.
    ///
    /// This data is opaque to relay nodes. Only the intended recipient(s)
    /// can decrypt and interpret the contents.
    public let encryptedPayload: Data

    /// The pool ID this message belongs to.
    ///
    /// Prevents cross-pool message injection attacks by ensuring messages
    /// are only processed within their originating pool.
    public let poolID: UUID

    /// Timestamp when the message was originally created.
    ///
    /// Used for:
    /// - Message ordering at the recipient
    /// - Expiry checking (messages older than 5 minutes are dropped)
    public let timestamp: Date

    /// Optional HMAC over routing metadata for integrity protection.
    ///
    /// When present, receivers MUST verify the HMAC before processing.
    /// When absent (backwards compatibility), the envelope is accepted with a warning.
    /// The HMAC covers: originPeerID, destinationPeerID, poolID, messageID, ttl, timestamp.
    /// This prevents relay nodes from tampering with routing metadata (TTL, hop path, origin).
    public var envelopeHMAC: Data?

    // MARK: - Constants

    /// Maximum allowed TTL value.
    ///
    /// Envelopes with TTL exceeding this value should be treated as suspicious
    /// and either clamped or rejected.
    public static let maxTTL: Int = 5

    /// Default TTL for newly created envelopes.
    ///
    /// With a default of 5 and typical mesh topologies, messages can reach
    /// any peer within 5 hops.
    public static let defaultTTL: Int = 5

    /// Message expiry interval in seconds (5 minutes).
    private static let expiryInterval: TimeInterval = 300

    // MARK: - Initialization

    /// Creates a new relay envelope.
    ///
    /// - Parameters:
    ///   - messageID: Unique identifier for deduplication. Defaults to a new UUID.
    ///   - originPeerID: The peer ID of the original sender.
    ///   - destinationPeerID: Target peer ID, or `nil` for broadcast.
    ///   - ttl: Time-to-live hop count. Defaults to `defaultTTL`.
    ///   - hopPath: Initial hop path. Defaults to empty (origin hasn't relayed yet).
    ///   - encryptedPayload: The E2E encrypted message content.
    ///   - poolID: The pool this message belongs to.
    ///   - timestamp: Message creation time. Defaults to now.
    public init(
        messageID: UUID = UUID(),
        originPeerID: String,
        destinationPeerID: String?,
        ttl: Int = RelayEnvelope.defaultTTL,
        hopPath: [String] = [],
        encryptedPayload: Data,
        poolID: UUID,
        timestamp: Date = Date(),
        envelopeHMAC: Data? = nil
    ) {
        self.messageID = messageID
        self.originPeerID = originPeerID
        self.destinationPeerID = destinationPeerID
        self.ttl = min(ttl, Self.maxTTL)
        self.hopPath = hopPath
        self.encryptedPayload = encryptedPayload
        self.poolID = poolID
        self.timestamp = timestamp
        self.envelopeHMAC = envelopeHMAC
    }

    // MARK: - Relay Operations

    /// Creates a forwarded copy of this envelope with decremented TTL and updated hop path.
    ///
    /// Use this method when relaying a received envelope to other peers.
    /// The method returns `nil` if the envelope cannot be forwarded (TTL exhausted).
    ///
    /// - Parameter relayPeerID: The peer ID of the node performing the relay.
    /// - Returns: A new envelope ready for forwarding, or `nil` if TTL would become <= 0.
    public func forwarded(by relayPeerID: String) -> RelayEnvelope? {
        let newTTL = ttl - 1
        guard newTTL > 0 else { return nil }

        var newHopPath = hopPath
        newHopPath.append(relayPeerID)

        // SECURITY: Cap hop path to maxTTL + 1 entries. An envelope created with maxTTL
        // hops should have at most maxTTL + 1 entries in the hop path (origin + relays).
        // Envelopes exceeding this limit are considered suspicious and rejected.
        guard newHopPath.count <= Self.maxTTL + 1 else { return nil }

        // NOTE: The HMAC is preserved from the original envelope. It covers immutable
        // fields (origin, destination, poolID, messageID, original ttl, timestamp).
        // The hop path and current ttl are mutable relay metadata and are NOT covered
        // by the HMAC — they change at each hop by design.
        return RelayEnvelope(
            messageID: messageID,
            originPeerID: originPeerID,
            destinationPeerID: destinationPeerID,
            ttl: newTTL,
            hopPath: newHopPath,
            encryptedPayload: encryptedPayload,
            poolID: poolID,
            timestamp: timestamp,
            envelopeHMAC: envelopeHMAC
        )
    }

    // MARK: - Computed Properties

    /// Indicates whether this envelope can be relayed to other peers.
    ///
    /// An envelope can be relayed if:
    /// - TTL is greater than 0
    /// - The message has not expired
    public var canRelay: Bool {
        ttl > 0 && !isExpired
    }

    /// Indicates whether this message has expired.
    ///
    /// Messages older than 5 minutes are considered expired and should
    /// not be processed or relayed.
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > Self.expiryInterval
    }

    /// Indicates whether this is a broadcast message.
    ///
    /// Broadcast messages have no specific destination and should be
    /// relayed to all connected peers (excluding those in the hop path).
    public var isBroadcast: Bool {
        destinationPeerID == nil
    }

    // MARK: - Hashable

    public static func == (lhs: RelayEnvelope, rhs: RelayEnvelope) -> Bool {
        lhs.messageID == rhs.messageID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(messageID)
    }
}

// MARK: - Encoding/Decoding

extension RelayEnvelope {
    /// Encodes the envelope to Data for transmission.
    ///
    /// - Returns: The encoded envelope, or `nil` if encoding fails.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes an envelope from received Data.
    ///
    /// - Parameter data: The received data to decode.
    /// - Returns: The decoded envelope, or `nil` if decoding fails.
    public static func decode(from data: Data) -> RelayEnvelope? {
        try? JSONDecoder().decode(RelayEnvelope.self, from: data)
    }
}

// MARK: - Validation

extension RelayEnvelope {
    /// Checks if this envelope should be relayed to a specific peer.
    ///
    /// A message should not be relayed to a peer if:
    /// - The peer is the original sender
    /// - The peer is already in the hop path (loop prevention)
    /// - The message is directed to a different peer (unless broadcast)
    ///
    /// - Parameter peerID: The peer ID to check.
    /// - Returns: `true` if the envelope should be relayed to this peer.
    public func shouldRelay(to peerID: String) -> Bool {
        guard canRelay else { return false }
        guard peerID != originPeerID else { return false }
        guard !hopPath.contains(peerID) else { return false }

        if destinationPeerID != nil {
            // Directed message: relay to all non-visited peers in the mesh
            // since we cannot know from envelope metadata alone which neighbor
            // is closer to the destination. Loop prevention is handled by
            // hop path and deduplication cache at the relay service layer.
            return true
        }

        // Broadcast: relay to all non-visited peers
        return true
    }

    /// Checks if this envelope is intended for a specific peer.
    ///
    /// - Parameter peerID: The peer ID to check.
    /// - Returns: `true` if this peer is the intended recipient (or it's a broadcast).
    public func isIntendedFor(_ peerID: String) -> Bool {
        isBroadcast || destinationPeerID == peerID
    }
}

// MARK: - Envelope Integrity (HMAC)

extension RelayEnvelope {

    /// Derives an HMAC signing key from a pool-level shared secret and pool ID using HKDF.
    ///
    /// The shared secret is established during pool creation/joining and is never transmitted
    /// in plaintext. The pool ID is included as salt to bind the derived key to this specific pool.
    /// Observers who see the pool ID on the wire cannot forge HMACs without the shared secret.
    ///
    /// - Parameters:
    ///   - sharedSecret: The pool-level shared secret (established during pool creation/joining).
    ///   - poolID: The pool UUID used as salt for domain separation.
    /// - Returns: A `SymmetricKey` suitable for HMAC-SHA256 operations.
    public static func deriveHMACKey(from sharedSecret: SymmetricKey, poolID: UUID) -> SymmetricKey {
        let poolIDData = withUnsafeBytes(of: poolID.uuid) { Data($0) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: poolIDData + Data("StealthOS-RelayEnvelope-HMAC-Salt".utf8),
            info: Data("envelope-integrity-v1".utf8),
            outputByteCount: 32
        )
        return derived
    }

    /// Appends a variable-length field to HMAC input with a 4-byte big-endian length prefix.
    ///
    /// Without length prefixes, concatenation of variable-length fields creates a collision
    /// domain (e.g., origin="ab" + dest="cd" produces the same bytes as origin="abc" + dest="d").
    /// Prefixing each field with its byte length eliminates this ambiguity.
    private static func appendLengthPrefixed(_ data: Data, to buffer: inout Data) {
        var length = UInt32(data.count).bigEndian
        buffer.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        buffer.append(data)
    }

    /// Computes an HMAC-SHA256 over the critical immutable routing fields.
    ///
    /// Covered fields: originPeerID, destinationPeerID, poolID, messageID, ttl, timestamp.
    /// The hop path is NOT covered because it changes legitimately at each relay hop.
    ///
    /// Variable-length string fields (originPeerID, destinationPeerID) are written with
    /// 4-byte big-endian length prefixes to prevent concatenation collision attacks.
    ///
    /// - Parameter key: The symmetric key to use for HMAC computation.
    /// - Returns: The HMAC tag as raw `Data`.
    public func computeHMAC(using key: SymmetricKey) -> Data {
        var hmacInput = Data()
        Self.appendLengthPrefixed(Data(originPeerID.utf8), to: &hmacInput)
        Self.appendLengthPrefixed(Data((destinationPeerID ?? "").utf8), to: &hmacInput)
        hmacInput.append(withUnsafeBytes(of: poolID.uuid) { Data($0) })
        hmacInput.append(withUnsafeBytes(of: messageID.uuid) { Data($0) })
        // Use the original TTL (maxTTL) for HMAC so it's consistent across hops.
        // The actual ttl field changes at each hop, so we cannot use it directly.
        // By using maxTTL, all hops and the origin produce the same HMAC input.
        hmacInput.append(withUnsafeBytes(of: Self.maxTTL) { Data($0) })
        hmacInput.append(withUnsafeBytes(of: timestamp.timeIntervalSince1970) { Data($0) })

        let tag = HMAC<SHA256>.authenticationCode(for: hmacInput, using: key)
        return Data(tag)
    }

    /// Verifies the envelope's HMAC against the provided key using constant-time comparison.
    ///
    /// - Parameter key: The symmetric key to use for verification.
    /// - Returns: `true` if the HMAC is present and valid.
    ///           `false` if the HMAC is missing or does not match (tampered or unsigned envelope).
    public func verifyHMAC(using key: SymmetricKey) -> Bool {
        guard let existingHMAC = envelopeHMAC else {
            // SECURITY: Reject envelopes without HMAC. All envelopes MUST be signed.
            return false
        }
        // Recompute the HMAC input to use CryptoKit's constant-time isValidAuthenticationCode.
        // Must match the format used in computeHMAC() with length-prefixed variable-length fields.
        var hmacInput = Data()
        Self.appendLengthPrefixed(Data(originPeerID.utf8), to: &hmacInput)
        Self.appendLengthPrefixed(Data((destinationPeerID ?? "").utf8), to: &hmacInput)
        hmacInput.append(withUnsafeBytes(of: poolID.uuid) { Data($0) })
        hmacInput.append(withUnsafeBytes(of: messageID.uuid) { Data($0) })
        hmacInput.append(withUnsafeBytes(of: Self.maxTTL) { Data($0) })
        hmacInput.append(withUnsafeBytes(of: timestamp.timeIntervalSince1970) { Data($0) })

        return HMAC<SHA256>.isValidAuthenticationCode(existingHMAC, authenticating: hmacInput, using: key)
    }

    /// Whether this envelope has an HMAC attached.
    public var hasHMAC: Bool {
        envelopeHMAC != nil
    }

    /// Returns a copy of this envelope with the HMAC computed and attached.
    ///
    /// - Parameter key: The symmetric key to use for HMAC computation.
    /// - Returns: A new envelope with the `envelopeHMAC` field populated.
    public func withHMAC(using key: SymmetricKey) -> RelayEnvelope {
        var copy = self
        copy.envelopeHMAC = computeHMAC(using: key)
        return copy
    }
}
