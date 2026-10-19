// RelayEnvelope+V2.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

// MARK: - Envelope Integrity v2
//
// v1 (StealthOS 1.4.x and older) MACs origin, destination (nil and "" collapse to the same
// bytes), poolID, messageID, the CONSTANT maxTTL in native byte order and the 1970-based
// timestamp in native byte order. It does not cover encryptedPayload, so a relay can swap
// the payload of a signed envelope.
//
// v2 (StealthOS 1.5.0+) adds a second, independent MAC under a separate key. Every integer
// is fixed-width big-endian, every variable-length field is length-prefixed, the
// destination has a presence tag, and the payload is covered. 1.5.0+ senders attach BOTH
// MACs so 1.4.x relays and receivers keep working unchanged; 1.5.0+ receivers verify only
// the v2 MAC when it is present.
//
// v2 MAC input (all integers big-endian):
//
//   u32 len || "STEALTH_RELAY_ENVELOPE_V2"            domain label (25 bytes)
//   u32 len || originPeerID UTF-8
//   u8 0x00                                            destination nil (broadcast)
//   | u8 0x01 || u32 len || destinationPeerID UTF-8    destination present (may be "")
//   poolID      16 raw RFC 4122 bytes
//   messageID   16 raw RFC 4122 bytes
//   u32 originTTL                                      1...maxTTL
//   u64 bitPattern(timestamp.timeIntervalSinceReferenceDate)
//                                                      IEEE-754 binary64, exactly the JSON
//                                                      "timestamp" number (seconds since 2001)
//   u64 len || encryptedPayload
//
// Key: HKDF-SHA256(ikm = pool shared secret,
//                  salt = poolID(16) || "StealthOS-RelayEnvelope-HMAC-Salt",
//                  info = "envelope-integrity-v2", 32).
//
// TTL design: the per-hop ttl and hopPath must change at every hop, so they cannot be
// MAC'd by the origin. v2 MACs the origin's starting TTL instead and receivers enforce
//   1 <= ttl <= originTTL <= maxTTL,  hopPath.first == originPeerID,
//   hopPath.count + ttl == originTTL + 1.
// A relay can still rewrite ttl and hopPath consistently, but it can never give an
// envelope more hops than its origin granted, and the MAC'd messageID feeds the dedup cache.

extension RelayEnvelope {

    /// Current envelope integrity version emitted by this build.
    public static let currentEnvelopeVersion = 2

    /// Domain label at the start of every v2 MAC input.
    static let v2DomainLabel = Data("STEALTH_RELAY_ENVELOPE_V2".utf8)

    /// Largest clock skew tolerated for timestamps in the future (seconds).
    public static let maxFutureSkew: TimeInterval = 120

    /// Derives the v2 HMAC key. Distinct from the v1 key (different HKDF info).
    public static func deriveHMACKeyV2(from sharedSecret: SymmetricKey, poolID: UUID) -> SymmetricKey {
        let poolIDData = withUnsafeBytes(of: poolID.uuid) { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: poolIDData + Data("StealthOS-RelayEnvelope-HMAC-Salt".utf8),
            info: Data("envelope-integrity-v2".utf8),
            outputByteCount: 32
        )
    }

    /// The exact bytes the v2 MAC authenticates, or `nil` if `originTTL` is absent.
    public func hmacInputV2() -> Data? {
        guard let originTTL, originTTL >= 0, originTTL <= Int(UInt32.max) else { return nil }
        var out = Data()
        out.reserveCapacity(128 + encryptedPayload.count)
        Self.appendBE32Prefixed(Self.v2DomainLabel, to: &out)
        Self.appendBE32Prefixed(Data(originPeerID.utf8), to: &out)
        if let destinationPeerID {
            out.append(0x01)
            Self.appendBE32Prefixed(Data(destinationPeerID.utf8), to: &out)
        } else {
            out.append(0x00)
        }
        out.append(contentsOf: withUnsafeBytes(of: poolID.uuid) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: messageID.uuid) { Array($0) })
        Self.appendBE(UInt32(originTTL), to: &out)
        Self.appendBE(timestamp.timeIntervalSinceReferenceDate.bitPattern, to: &out)
        Self.appendBE(UInt64(encryptedPayload.count), to: &out)
        out.append(encryptedPayload)
        return out
    }

    /// Computes the v2 tag, or `nil` if the envelope has no `originTTL`.
    public func computeHMACV2(using key: SymmetricKey) -> Data? {
        guard let input = hmacInputV2() else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    /// Constant-time verification of the v2 tag. `false` when any v2 field is missing.
    public func verifyHMACV2(using key: SymmetricKey) -> Bool {
        guard envelopeVersion == 2, let tag = envelopeHMACV2, let input = hmacInputV2() else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: input, using: key)
    }

    /// Whether this envelope claims to be v2 (carries any v2 field).
    public var claimsV2: Bool {
        envelopeVersion != nil || envelopeHMACV2 != nil || originTTL != nil
    }

    /// Returns a copy signed for both v1 and v2 receivers.
    ///
    /// `originTTL` is set to the envelope's current `ttl`; call this on the origin only.
    public func withDualHMAC(v1Key: SymmetricKey, v2Key: SymmetricKey) -> RelayEnvelope {
        var copy = self
        copy.envelopeHMAC = computeHMAC(using: v1Key)
        copy.envelopeVersion = Self.currentEnvelopeVersion
        copy.originTTL = ttl
        copy.envelopeHMACV2 = copy.computeHMACV2(using: v2Key)
        return copy
    }

    /// Routing invariants that v2 receivers enforce after the MAC verifies.
    public func verifyV2RoutingInvariants() -> Bool {
        guard let originTTL, originTTL >= 1, originTTL <= Self.maxTTL else { return false }
        guard ttl >= 1, ttl <= originTTL else { return false }
        guard hopPath.first == originPeerID else { return false }
        return hopPath.count + ttl == originTTL + 1
    }

    /// Whether the timestamp is unreasonably far in the future.
    ///
    /// A far-future timestamp would never expire and could be replayed after the
    /// deduplication cache forgets the message ID.
    public func isFromTheFuture(now: Date = Date()) -> Bool {
        timestamp.timeIntervalSince(now) > Self.maxFutureSkew
    }

    // MARK: - Fixed-width encoders

    static func appendBE32Prefixed(_ data: Data, to buffer: inout Data) {
        appendBE(UInt32(truncatingIfNeeded: data.count), to: &buffer)
        buffer.append(data)
    }

    static func appendBE<T: FixedWidthInteger>(_ value: T, to buffer: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { buffer.append(contentsOf: $0) }
    }
}

// MARK: - Inbound Verification

/// Result of verifying an inbound envelope against the pool key and the downgrade ledger.
public enum RelayEnvelopeVerdict: Sendable, Equatable {
    /// v2 MAC and routing invariants verified.
    case acceptedV2
    /// v1-only envelope from an origin never seen speaking v2 (legacy policy: warn).
    case acceptedLegacy
    /// The envelope failed authentication or a v2 routing invariant.
    case rejectedInvalid(reason: String)
    /// v1-only envelope from an origin that has been seen speaking v2.
    case rejectedDowngrade
    /// v1-only envelope and the legacy policy is ``LegacyPeerPolicy/refuse``.
    case rejectedLegacy

    public var isAccepted: Bool {
        self == .acceptedV2 || self == .acceptedLegacy
    }
}

extension RelayEnvelope {

    /// Full inbound integrity decision for a receiver or relay.
    ///
    /// - v2 fields present: the v2 MAC and routing invariants must verify. A v2 envelope
    ///   is never downgraded to v1 verification, so stripping or corrupting only the v2
    ///   tag fails closed.
    /// - v2 fields absent: the v1 MAC must verify and the ledger decides (refuses origins
    ///   pinned to v2, and applies the legacy policy otherwise).
    public func verify(
        sharedSecret: SymmetricKey,
        receiverPoolID: UUID,
        ledger: PeerProtocolLedger,
        now: Date = Date()
    ) -> RelayEnvelopeVerdict {
        if isFromTheFuture(now: now) {
            return .rejectedInvalid(reason: "timestamp too far in the future")
        }
        if claimsV2 {
            let key = Self.deriveHMACKeyV2(from: sharedSecret, poolID: receiverPoolID)
            guard verifyHMACV2(using: key) else {
                return .rejectedInvalid(reason: "v2 HMAC verification failed")
            }
            guard verifyV2RoutingInvariants() else {
                return .rejectedInvalid(reason: "v2 TTL / hop path invariant violated")
            }
            _ = ledger.admit(peerID: originPeerID, feature: .relayEnvelope, version: 2)
            return .acceptedV2
        }
        let v1Key = Self.deriveHMACKey(from: sharedSecret, poolID: receiverPoolID)
        guard verifyHMAC(using: v1Key) else {
            return .rejectedInvalid(reason: "v1 HMAC verification failed")
        }
        switch ledger.admit(peerID: originPeerID, feature: .relayEnvelope, version: 1) {
        case .acceptedLegacy, .accepted: return .acceptedLegacy
        case .refusedDowngrade: return .rejectedDowngrade
        case .refusedLegacy: return .rejectedLegacy
        }
    }
}
