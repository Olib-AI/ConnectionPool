// RelayEnvelopeTests.swift
// ConnectionPoolTests

import XCTest
import CryptoKit
@testable import ConnectionPool

final class RelayEnvelopeTests: XCTestCase {

    // MARK: - Helpers

    private func makeEnvelope(
        messageID: UUID = UUID(),
        originPeerID: String = "origin",
        destinationPeerID: String? = "dest",
        ttl: Int = RelayEnvelope.defaultTTL,
        hopPath: [String] = [],
        payload: Data = Data("test".utf8),
        poolID: UUID = UUID(),
        timestamp: Date = Date()
    ) -> RelayEnvelope {
        RelayEnvelope(
            messageID: messageID,
            originPeerID: originPeerID,
            destinationPeerID: destinationPeerID,
            ttl: ttl,
            hopPath: hopPath,
            encryptedPayload: payload,
            poolID: poolID,
            timestamp: timestamp
        )
    }

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - Initialization

    func testInitClampsExcessiveTTL() {
        let env = makeEnvelope(ttl: 100)
        XCTAssertEqual(env.ttl, RelayEnvelope.maxTTL,
                       "TTL exceeding maxTTL must be clamped to maxTTL")
    }

    func testInitPreservesValidTTL() {
        let env = makeEnvelope(ttl: 3)
        XCTAssertEqual(env.ttl, 3)
    }

    func testDefaultTTLEqualsMaxTTL() {
        XCTAssertEqual(RelayEnvelope.defaultTTL, RelayEnvelope.maxTTL)
    }

    // MARK: - Computed Properties

    func testIsBroadcastWhenDestinationNil() {
        let env = makeEnvelope(destinationPeerID: nil)
        XCTAssertTrue(env.isBroadcast)
    }

    func testIsNotBroadcastWhenDestinationSet() {
        let env = makeEnvelope(destinationPeerID: "peer-A")
        XCTAssertFalse(env.isBroadcast)
    }

    func testCanRelayWhenTTLPositiveAndFresh() {
        let env = makeEnvelope(ttl: 3, timestamp: Date())
        XCTAssertTrue(env.canRelay)
    }

    func testCanRelayFalseWhenTTLZero() {
        let env = makeEnvelope(ttl: 0)
        XCTAssertFalse(env.canRelay)
    }

    func testIsExpiredForOldTimestamp() {
        let old = Date().addingTimeInterval(-400) // 400s > 300s expiry
        let env = makeEnvelope(timestamp: old)
        XCTAssertTrue(env.isExpired)
    }

    func testIsNotExpiredForRecentTimestamp() {
        let env = makeEnvelope(timestamp: Date())
        XCTAssertFalse(env.isExpired)
    }

    // MARK: - Forwarding

    func testForwardedDecrementsTTLAndAppendsHopPath() {
        let env = makeEnvelope(ttl: 3, hopPath: ["origin"])
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNotNil(fwd)
        XCTAssertEqual(fwd?.ttl, 2)
        XCTAssertEqual(fwd?.hopPath, ["origin", "relay-A"])
    }

    func testForwardedReturnsNilWhenTTLWouldBeZero() {
        let env = makeEnvelope(ttl: 1)
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNil(fwd, "forwarded() must return nil when TTL would become 0")
    }

    func testForwardedRejectsExcessiveHopPath() {
        // maxTTL is 5, so hop path with 6 entries should be capped at maxTTL+1 = 6
        // Start with 6 entries already, forwarding should make 7 which exceeds maxTTL+1=6
        let env = makeEnvelope(ttl: 5, hopPath: ["a", "b", "c", "d", "e", "f"])
        let fwd = env.forwarded(by: "g")
        XCTAssertNil(fwd, "Hop path exceeding maxTTL+1 must be rejected")
    }

    func testForwardedPreservesHMAC() {
        let key = makeKey()
        let poolID = UUID()
        let env = makeEnvelope(ttl: 5, poolID: poolID).withHMAC(using:
            RelayEnvelope.deriveHMACKey(from: key, poolID: poolID))
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNotNil(fwd?.envelopeHMAC, "HMAC must be preserved through forwarding")
        XCTAssertEqual(fwd?.envelopeHMAC, env.envelopeHMAC)
    }

    // MARK: - shouldRelay / isIntendedFor

    func testShouldRelayRejectsOriginPeer() {
        let env = makeEnvelope(originPeerID: "peer-A", ttl: 3)
        XCTAssertFalse(env.shouldRelay(to: "peer-A"))
    }

    func testShouldRelayRejectsPeerInHopPath() {
        let env = makeEnvelope(ttl: 3, hopPath: ["peer-A", "peer-B"])
        XCTAssertFalse(env.shouldRelay(to: "peer-B"))
    }

    func testShouldRelayAcceptsUnvisitedPeer() {
        let env = makeEnvelope(originPeerID: "origin", ttl: 3, hopPath: [])
        XCTAssertTrue(env.shouldRelay(to: "peer-C"))
    }

    func testIsIntendedForBroadcast() {
        let env = makeEnvelope(destinationPeerID: nil)
        XCTAssertTrue(env.isIntendedFor("anyone"))
    }

    func testIsIntendedForMatchingDestination() {
        let env = makeEnvelope(destinationPeerID: "peer-X")
        XCTAssertTrue(env.isIntendedFor("peer-X"))
        XCTAssertFalse(env.isIntendedFor("peer-Y"))
    }

    // MARK: - JSON Encoding/Decoding

    func testEncodeDecodeRoundTrip() {
        let poolID = UUID()
        let msgID = UUID()
        let env = makeEnvelope(messageID: msgID, poolID: poolID)
        let data = env.encode()
        XCTAssertNotNil(data)
        let decoded = RelayEnvelope.decode(from: data!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.messageID, msgID)
        XCTAssertEqual(decoded?.poolID, poolID)
        XCTAssertEqual(decoded?.originPeerID, "origin")
        XCTAssertEqual(decoded?.destinationPeerID, "dest")
    }

    func testDecodeFromInvalidDataReturnsNil() {
        let garbage = Data("not json".utf8)
        XCTAssertNil(RelayEnvelope.decode(from: garbage))
    }

    // MARK: - HMAC

    func testComputeHMACProducesDeterministicOutput() {
        let key = makeKey()
        let poolID = UUID()
        let env = makeEnvelope(poolID: poolID)
        let hmac1 = env.computeHMAC(using: RelayEnvelope.deriveHMACKey(from: key, poolID: poolID))
        let hmac2 = env.computeHMAC(using: RelayEnvelope.deriveHMACKey(from: key, poolID: poolID))
        XCTAssertEqual(hmac1, hmac2, "Same input must produce same HMAC")
    }

    func testVerifyHMACSucceedsWithCorrectKey() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let env = makeEnvelope(poolID: poolID).withHMAC(using: hmacKey)
        XCTAssertTrue(env.verifyHMAC(using: hmacKey))
    }

    func testVerifyHMACFailsWithWrongKey() {
        let key1 = makeKey()
        let key2 = makeKey()
        let poolID = UUID()
        let hmacKey1 = RelayEnvelope.deriveHMACKey(from: key1, poolID: poolID)
        let hmacKey2 = RelayEnvelope.deriveHMACKey(from: key2, poolID: poolID)
        let env = makeEnvelope(poolID: poolID).withHMAC(using: hmacKey1)
        XCTAssertFalse(env.verifyHMAC(using: hmacKey2))
    }

    func testVerifyHMACFailsWhenNoHMAC() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let env = makeEnvelope(poolID: poolID) // no HMAC attached
        XCTAssertFalse(env.verifyHMAC(using: hmacKey))
    }

    func testHasHMACProperty() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let env1 = makeEnvelope(poolID: poolID)
        XCTAssertFalse(env1.hasHMAC)
        let env2 = env1.withHMAC(using: hmacKey)
        XCTAssertTrue(env2.hasHMAC)
    }

    func testWithHMACReturnsCopyWithHMAC() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let original = makeEnvelope(poolID: poolID)
        let signed = original.withHMAC(using: hmacKey)
        XCTAssertNil(original.envelopeHMAC)
        XCTAssertNotNil(signed.envelopeHMAC)
        XCTAssertEqual(signed.messageID, original.messageID)
    }

    func testDeriveHMACKeyDifferentPoolIDsProduceDifferentKeys() {
        let secret = makeKey()
        let key1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: UUID())
        let key2 = RelayEnvelope.deriveHMACKey(from: secret, poolID: UUID())
        // Derive a test envelope and compare HMACs — different keys produce different tags
        let env = makeEnvelope()
        let hmac1 = env.computeHMAC(using: key1)
        let hmac2 = env.computeHMAC(using: key2)
        XCTAssertNotEqual(hmac1, hmac2)
    }

    func testHMACConsistentAcrossHops() {
        // The HMAC uses maxTTL (constant) rather than the mutable ttl field,
        // so verifyHMAC should succeed even after forwarding changes the ttl.
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let env = makeEnvelope(ttl: 5, hopPath: ["origin"], poolID: poolID)
            .withHMAC(using: hmacKey)
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNotNil(fwd)
        XCTAssertTrue(fwd!.verifyHMAC(using: hmacKey),
                       "HMAC must remain valid after forwarding (TTL change)")
    }

    // MARK: - Hashable / Equatable

    func testEqualityBasedOnMessageIDOnly() {
        let id = UUID()
        let env1 = makeEnvelope(messageID: id, originPeerID: "a")
        let env2 = makeEnvelope(messageID: id, originPeerID: "b")
        XCTAssertEqual(env1, env2, "Equality must be based solely on messageID")
    }

    func testInequalityForDifferentMessageIDs() {
        let env1 = makeEnvelope(messageID: UUID())
        let env2 = makeEnvelope(messageID: UUID())
        XCTAssertNotEqual(env1, env2)
    }
}
