// RelayEnvelopeV2Tests.swift
// ConnectionPoolTests
//
// RelayEnvelope integrity v2 (StealthOS 1.5.0+): golden vectors produced by an independent
// Python reference, tamper resistance, routing invariants, and the v1/v2 negotiation and
// downgrade matrix.

import Foundation
import Combine
import CryptoKit
import Testing
@testable import ConnectionPool

private let v2File = "relay_envelope_hmac_v2.json"

private func decodeEnvelope(_ v: GoldenVector, key: String) throws -> RelayEnvelope {
    let json = try #require(v.inputs[key]?.string ?? v.outputs[key]?.string, "\(key) in \(v.name)")
    return try #require(RelayEnvelope.decode(from: Data(json.utf8)), "decode \(v.name)")
}

@Suite("RelayEnvelope v2 golden vectors")
struct RelayEnvelopeV2VectorTests {

    @Test("v2 vector file inventory")
    func inventory() {
        #expect(Golden.vectors(v2File, kind: "hmac_key_v2").count == 1)
        #expect(Golden.vectors(v2File, kind: "envelope_v2").count == 10)
        #expect(Golden.vectors(v2File, kind: "envelope_v2_tamper").count == 22)
    }

    @Test("v2 key differs from v1 and matches the reference")
    func key() throws {
        let v = try Golden.vector(v2File, named: "hmac_key_v2")
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("pool_id")
        #expect(keyBytes(RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)) == (try v.outputHex("hmac_key_v2_hex")))
        #expect(keyBytes(RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)) == (try v.outputHex("hmac_key_v1_hex")))
        #expect(try v.outputHex("hmac_key_v2_hex") != (try v.outputHex("hmac_key_v1_hex")))
    }

    @Test("v2 MAC input and tag are bit-exact", arguments: Golden.vectors(v2File, kind: "envelope_v2"))
    func envelope(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("receiver_pool_id")
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        let k2 = RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)
        let e = try decodeEnvelope(v, key: "envelope_json")

        #expect(e.originPeerID == (try v.inputString("origin_peer_id")))
        #expect(e.destinationPeerID == (try v.input("destination_peer_id")).string)
        #expect((try v.input("destination_peer_id")).isNull == (e.destinationPeerID == nil))
        #expect(e.ttl == (try v.inputInt("ttl")))
        #expect(e.originTTL == (try v.inputInt("origin_ttl")))
        #expect(e.encryptedPayload == (try v.inputHex("payload_hex")))
        #expect(e.timestamp.timeIntervalSinceReferenceDate == (try v.inputDouble("timestamp_since_2001")))
        #expect(e.envelopeVersion == 2)

        #expect(e.hmacInputV2() == (try v.outputHex("hmac_v2_input_hex")))
        #expect(e.computeHMACV2(using: k2) == (try v.outputHex("hmac_v2_hex")))
        #expect(e.envelopeHMACV2 == (try v.outputHex("hmac_v2_hex")))
        #expect(e.verifyHMACV2(using: k2))
        #expect(!e.verifyHMACV2(using: k1), "the v1 key never verifies a v2 tag")
        #expect(e.verifyV2RoutingInvariants())
        // A 1.4.x receiver checks only the v1 tag, which the 1.5.0 origin also attached.
        #expect(e.verifyHMAC(using: k1))
        #expect(e.envelopeHMAC == (try v.outputHex("hmac_v1_hex")))

        let ledger = PeerProtocolLedger()
        #expect(e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, now: e.timestamp) == .acceptedV2)
        #expect(ledger.isPinnedToV2(e.originPeerID, feature: .relayEnvelope))

        // Production re-encoding keeps every v2 field.
        let round = try #require(e.encode().flatMap(RelayEnvelope.decode(from:)))
        #expect(round.verifyHMACV2(using: k2) && round.verifyV2RoutingInvariants())
    }

    @Test("Origin-side signing reproduces the reference bytes", arguments: Golden.vectors(v2File, kind: "envelope_v2").filter { $0.inputs["ttl"]?.int == $0.inputs["origin_ttl"]?.int })
    func originSigning(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("pool_id")
        let origin = try v.inputString("origin_peer_id")
        let fresh = RelayEnvelope(
            messageID: try v.inputUUID("message_id"),
            originPeerID: origin,
            destinationPeerID: (try v.input("destination_peer_id")).string,
            ttl: try v.inputInt("ttl"),
            hopPath: [origin],
            encryptedPayload: try v.inputHex("payload_hex"),
            poolID: pool,
            timestamp: Date(timeIntervalSinceReferenceDate: try v.inputDouble("timestamp_since_2001"))
        ).withDualHMAC(
            v1Key: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool),
            v2Key: RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)
        )
        #expect(fresh.envelopeHMACV2 == (try v.outputHex("hmac_v2_hex")))
        #expect(fresh.envelopeHMAC == (try v.outputHex("hmac_v1_hex")))
        #expect(fresh.originTTL == (try v.inputInt("origin_ttl")))
    }

    @Test("nil and \"\" destinations produce different v2 MACs")
    func presenceTag() throws {
        let nilDest = try Golden.vector(v2File, named: "broadcast_nil_destination")
        let empty = try Golden.vector(v2File, named: "empty_string_destination")
        #expect(try nilDest.outputHex("hmac_v2_hex") != (try empty.outputHex("hmac_v2_hex")))
        #expect(try nilDest.outputHex("hmac_v2_input_hex") != (try empty.outputHex("hmac_v2_input_hex")))
    }

    @Test("Length prefixes separate ab/cd from abc/d")
    func lengthPrefix() throws {
        let a = try Golden.vector(v2File, named: "length_prefix_ab_cd")
        let b = try Golden.vector(v2File, named: "length_prefix_abc_d")
        #expect(try a.outputHex("hmac_v2_hex") != (try b.outputHex("hmac_v2_hex")))
    }

    @Test("Tampered v2 envelopes are rejected", arguments: Golden.vectors(v2File, kind: "envelope_v2_tamper"))
    func tamper(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("receiver_pool_id")
        let e = try decodeEnvelope(v, key: "envelope_json")
        let ledger = PeerProtocolLedger()
        let verdict = e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, now: e.timestamp)
        #expect(!verdict.isAccepted, "\(v.name): \(verdict)")
        if case .rejectedInvalid = verdict {} else {
            Issue.record("\(v.name) must fail authentication or invariants, got \(verdict)")
        }
        #expect(e.claimsV2, "every tamper vector still claims v2, so no v1 fallback is possible")
        #expect(!ledger.isPinnedToV2(e.originPeerID, feature: .relayEnvelope), "a forged envelope must not pin")
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }
}

// MARK: - Programmatic tamper / TTL / timestamp

@Suite("RelayEnvelope v2 tamper and routing invariants")
struct RelayEnvelopeV2TamperTests {
    let secret = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let pool = UUID(uuidString: "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E4")!
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func signed(origin: String = "peer-origin", destination: String? = "peer-dest", payload: Data = Data("ciphertext".utf8)) -> RelayEnvelope {
        MeshRelayService.makeSignedEnvelope(
            origin: origin, destination: destination, payload: payload, poolID: pool,
            sharedSecret: secret, messageID: UUID(), timestamp: now
        )
    }

    func verdict(_ e: RelayEnvelope, ledger: PeerProtocolLedger = PeerProtocolLedger()) -> RelayEnvelopeVerdict {
        e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, now: now)
    }

    @Test("Fresh, forwarded once, twice, three and four times all verify")
    func forwardingKeepsV2Valid() throws {
        var e = signed()
        #expect(verdict(e) == .acceptedV2)
        for hop in 1...4 {
            e = try #require(e.forwarded(by: "relay-\(hop)"))
            #expect(verdict(e) == .acceptedV2, "after \(hop) hops")
            #expect(e.originTTL == 5)
        }
        #expect(e.forwarded(by: "relay-5") == nil, "ttl exhausted")
    }

    @Test("Swapped payload is rejected (v2 covers it)")
    func swappedPayload() {
        let e = signed()
        let swapped = RelayEnvelope(messageID: e.messageID, originPeerID: e.originPeerID, destinationPeerID: e.destinationPeerID,
                                    ttl: e.ttl, hopPath: e.hopPath, encryptedPayload: Data("other".utf8), poolID: e.poolID,
                                    timestamp: e.timestamp, envelopeHMAC: e.envelopeHMAC, envelopeVersion: 2,
                                    originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2)
        #expect(verdict(swapped) == .rejectedInvalid(reason: "v2 HMAC verification failed"))
    }

    @Test("Payload truncated by one byte or extended by one byte is rejected", arguments: [-1, 1])
    func payloadLength(_ delta: Int) {
        let e = signed(payload: Data(repeating: 7, count: 64))
        var p = e.encryptedPayload
        if delta < 0 { p.removeLast() } else { p.append(0) }
        var t = e
        t = RelayEnvelope(messageID: t.messageID, originPeerID: t.originPeerID, destinationPeerID: t.destinationPeerID, ttl: t.ttl,
                          hopPath: t.hopPath, encryptedPayload: p, poolID: t.poolID, timestamp: t.timestamp,
                          envelopeHMAC: t.envelopeHMAC, envelopeVersion: 2, originTTL: t.originTTL, envelopeHMACV2: t.envelopeHMACV2)
        #expect(!verdict(t).isAccepted)
    }

    @Test("Destination nil <-> \"\" swaps are rejected", arguments: [true, false])
    func destinationSwap(_ fromNil: Bool) {
        let e = signed(destination: fromNil ? nil : "")
        let swapped = RelayEnvelope(messageID: e.messageID, originPeerID: e.originPeerID, destinationPeerID: fromNil ? "" : nil,
                                    ttl: e.ttl, hopPath: e.hopPath, encryptedPayload: e.encryptedPayload, poolID: e.poolID,
                                    timestamp: e.timestamp, envelopeHMAC: e.envelopeHMAC, envelopeVersion: 2,
                                    originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2)
        #expect(!verdict(swapped).isAccepted)
        #expect(swapped.verifyHMAC(using: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)),
                "the v1 MAC alone cannot see this swap; v2 receivers never consult it")
    }

    @Test("TTL tampering", arguments: [
        (ttl: 6, hops: 1), (ttl: 5, hops: 2), (ttl: 4, hops: 3), (ttl: 0, hops: 6), (ttl: -1, hops: 1), (ttl: 3, hops: 1)
    ])
    func ttlTamper(_ c: (ttl: Int, hops: Int)) {
        var e = signed()
        e.ttl = c.ttl
        e.hopPath = ["peer-origin"] + (0..<max(0, c.hops - 1)).map { "r\($0)" }
        #expect(verdict(e) == .rejectedInvalid(reason: "v2 TTL / hop path invariant violated"))
    }

    @Test("originTTL tampering is caught by the MAC", arguments: [1, 4, 6, 1000])
    func originTTLTamper(_ value: Int) {
        var e = signed()
        e.originTTL = value
        e.ttl = min(value, 5)
        e.hopPath = ["peer-origin"]
        #expect(!verdict(e).isAccepted)
    }

    @Test("Timestamp tampering", arguments: [1e-6, 1.0, -1.0, 3600.0])
    func timestampTamper(_ delta: Double) {
        let e = signed()
        let t = RelayEnvelope(messageID: e.messageID, originPeerID: e.originPeerID, destinationPeerID: e.destinationPeerID,
                              ttl: e.ttl, hopPath: e.hopPath, encryptedPayload: e.encryptedPayload, poolID: e.poolID,
                              timestamp: e.timestamp.addingTimeInterval(delta), envelopeHMAC: e.envelopeHMAC, envelopeVersion: 2,
                              originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2)
        #expect(!verdict(t).isAccepted)
    }

    @Test("Far-future timestamps are rejected even with a valid MAC")
    func futureTimestamp() {
        let future = MeshRelayService.makeSignedEnvelope(origin: "o", destination: nil, payload: Data([1]), poolID: pool,
                                                         sharedSecret: secret, timestamp: now.addingTimeInterval(RelayEnvelope.maxFutureSkew + 1))
        #expect(verdict(future) == .rejectedInvalid(reason: "timestamp too far in the future"))
        let skewed = MeshRelayService.makeSignedEnvelope(origin: "o", destination: nil, payload: Data([1]), poolID: pool,
                                                         sharedSecret: secret, timestamp: now.addingTimeInterval(RelayEnvelope.maxFutureSkew - 1))
        #expect(verdict(skewed) == .acceptedV2)
    }

    @Test("Field-boundary shifting across origin/destination is rejected", arguments: [
        ("abc", "d"), ("a", "bcd"), ("", "abcd"), ("abcd", ""), ("abcd", nil)
    ] as [(String, String?)])
    func boundaryShift(_ shifted: (String, String?)) {
        let e = signed(origin: "ab", destination: "cd")
        let t = RelayEnvelope(messageID: e.messageID, originPeerID: shifted.0, destinationPeerID: shifted.1,
                              ttl: e.ttl, hopPath: [shifted.0], encryptedPayload: e.encryptedPayload, poolID: e.poolID,
                              timestamp: e.timestamp, envelopeHMAC: e.envelopeHMAC, envelopeVersion: 2,
                              originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2)
        #expect(!verdict(t).isAccepted)
    }

    @Test("Shifting bytes between destination and payload is rejected")
    func destinationPayloadShift() {
        let e = signed(destination: "dest", payload: Data("Xpayload".utf8))
        let t = RelayEnvelope(messageID: e.messageID, originPeerID: e.originPeerID, destinationPeerID: "destX",
                              ttl: e.ttl, hopPath: e.hopPath, encryptedPayload: Data("payload".utf8), poolID: e.poolID,
                              timestamp: e.timestamp, envelopeHMAC: e.envelopeHMAC, envelopeVersion: 2,
                              originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2)
        #expect(!verdict(t).isAccepted)
    }

    @Test("Wrong pool secret or wrong receiving pool is rejected")
    func wrongPool() {
        let e = signed()
        #expect(!e.verify(sharedSecret: SymmetricKey(data: Data(repeating: 0x43, count: 32)), receiverPoolID: pool, ledger: PeerProtocolLedger(), now: now).isAccepted)
        #expect(!e.verify(sharedSecret: secret, receiverPoolID: UUID(), ledger: PeerProtocolLedger(), now: now).isAccepted)
    }

    @Test("MAC input uses big-endian fixed-width integers")
    func endianness() throws {
        let e = signed(origin: "o", destination: nil, payload: Data([0xAA]))
        let input = try #require(e.hmacInputV2())
        let label = RelayEnvelope.v2DomainLabel
        var expected = Data([0, 0, 0, UInt8(label.count)]) + label
        expected += Data([0, 0, 0, 1]) + Data("o".utf8) + Data([0x00])
        expected += withUnsafeBytes(of: pool.uuid) { Data($0) } + withUnsafeBytes(of: e.messageID.uuid) { Data($0) }
        expected += Data([0, 0, 0, 5])
        expected += withUnsafeBytes(of: now.timeIntervalSinceReferenceDate.bitPattern.bigEndian) { Data($0) }
        expected += Data([0, 0, 0, 0, 0, 0, 0, 1, 0xAA])
        #expect(input == expected)
    }
}

// MARK: - Negotiation / downgrade matrix

@Suite("Relay envelope negotiation and downgrade matrix")
struct RelayEnvelopeNegotiationTests {
    let secret = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    let pool = UUID()
    let now = Date()

    /// What a StealthOS 1.4.x origin emits.
    func v1Envelope(origin: String, payload: Data = Data("p".utf8)) -> RelayEnvelope {
        RelayEnvelope(originPeerID: origin, destinationPeerID: "dest", hopPath: [origin], encryptedPayload: payload,
                      poolID: pool, timestamp: now).withHMAC(using: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool))
    }

    /// What a 1.5.0+ origin emits.
    func v2Envelope(origin: String, payload: Data = Data("p".utf8)) -> RelayEnvelope {
        MeshRelayService.makeSignedEnvelope(origin: origin, destination: "dest", payload: payload, poolID: pool,
                                            sharedSecret: secret, timestamp: now)
    }

    /// What a 1.4.x relay does to any envelope: decode known fields, rebuild, forward.
    /// The 1.4.x struct has no v2 properties, so decoding drops them and `forwarded(by:)`
    /// rebuilds the envelope from the v1 fields only.
    func throughLegacyRelay(_ e: RelayEnvelope) throws -> RelayEnvelope {
        let wire = try #require(e.encode().flatMap(RelayEnvelope.decode(from:)))
        let stripped = RelayEnvelope(messageID: wire.messageID, originPeerID: wire.originPeerID,
                                     destinationPeerID: wire.destinationPeerID, ttl: wire.ttl, hopPath: wire.hopPath,
                                     encryptedPayload: wire.encryptedPayload, poolID: wire.poolID,
                                     timestamp: wire.timestamp, envelopeHMAC: wire.envelopeHMAC)
        #expect(!stripped.claimsV2)
        return try #require(stripped.forwarded(by: "legacy-relay"))
    }

    func receive(_ e: RelayEnvelope, _ ledger: PeerProtocolLedger) -> RelayEnvelopeVerdict {
        e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, now: now)
    }

    @Test("v1 -> v1: a 1.4.x receiver accepts a 1.4.x envelope (v1 MAC)")
    func v1ToV1() {
        #expect(v1Envelope(origin: "old").verifyHMAC(using: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)))
    }

    @Test("v2 -> v1: a 1.4.x receiver accepts a 1.5.0 envelope through the v1 MAC")
    func v2ToV1() throws {
        let e = v2Envelope(origin: "new")
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        #expect(e.verifyHMAC(using: k1))
        #expect(try throughLegacyRelay(e).verifyHMAC(using: k1), "and a 1.4.x relay can still forward it")
    }

    @Test("v1 -> v2: a 1.5.0 receiver accepts a 1.4.x origin and flags it legacy")
    func v1ToV2() {
        let ledger = PeerProtocolLedger()
        #expect(receive(v1Envelope(origin: "old"), ledger) == .acceptedLegacy)
        #expect(ledger.legacyPeers(for: .relayEnvelope) == ["old"])
        #expect(ledger.highestVersion(of: "old", feature: .relayEnvelope) == 1)
    }

    @Test("v2 -> v2: accepted and the origin is pinned")
    func v2ToV2() {
        let ledger = PeerProtocolLedger()
        #expect(receive(v2Envelope(origin: "new"), ledger) == .acceptedV2)
        #expect(ledger.isPinnedToV2("new", feature: .relayEnvelope))
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }

    @Test("Downgrade after v2 was seen is refused")
    func downgradeAfterV2() {
        let ledger = PeerProtocolLedger()
        #expect(receive(v2Envelope(origin: "peer"), ledger) == .acceptedV2)
        #expect(receive(v1Envelope(origin: "peer"), ledger) == .rejectedDowngrade)
        #expect(receive(v1Envelope(origin: "peer"), ledger) == .rejectedDowngrade, "stays refused")
        #expect(receive(v2Envelope(origin: "peer"), ledger) == .acceptedV2, "v2 keeps working")
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }

    @Test("Attacker strips the v2 fields (and swaps the payload) from a pinned origin: refused")
    func strippedCapabilitiesPinned() throws {
        let ledger = PeerProtocolLedger()
        #expect(receive(v2Envelope(origin: "victim"), ledger) == .acceptedV2)
        var stripped = try throughLegacyRelay(v2Envelope(origin: "victim"))
        #expect(receive(stripped, ledger) == .rejectedDowngrade)
        stripped = RelayEnvelope(messageID: stripped.messageID, originPeerID: stripped.originPeerID,
                                 destinationPeerID: stripped.destinationPeerID, ttl: stripped.ttl, hopPath: stripped.hopPath,
                                 encryptedPayload: Data("attacker".utf8), poolID: stripped.poolID, timestamp: stripped.timestamp,
                                 envelopeHMAC: stripped.envelopeHMAC)
        #expect(receive(stripped, ledger) == .rejectedDowngrade)
    }

    @Test("Attacker strips only the v2 tag, or only the version, or sets an unknown version: fails closed")
    func partialStrip() {
        let ledger = PeerProtocolLedger()
        var a = v2Envelope(origin: "x"); a.envelopeHMACV2 = nil
        var b = v2Envelope(origin: "x"); b.envelopeVersion = nil
        var c = v2Envelope(origin: "x"); c.originTTL = nil
        var d = v2Envelope(origin: "x"); d.envelopeVersion = 3
        for e in [a, b, c, d] {
            if case .rejectedInvalid = receive(e, ledger) {} else { Issue.record("partial strip accepted: \(e)") }
        }
        #expect(!ledger.isPinnedToV2("x", feature: .relayEnvelope))
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }

    @Test("Full strip from an origin never seen with v2 is accepted only as legacy (documented limit)")
    func strippedCapabilitiesUnpinned() throws {
        let ledger = PeerProtocolLedger()
        let stripped = try throughLegacyRelay(v2Envelope(origin: "fresh"))
        #expect(receive(stripped, ledger) == .acceptedLegacy)
        #expect(ledger.legacyPeers(for: .relayEnvelope).contains("fresh"), "the UI is told this peer is unprotected")
        // The moment the real origin's own v2 traffic arrives, it is pinned and un-flagged.
        #expect(receive(v2Envelope(origin: "fresh"), ledger) == .acceptedV2)
        #expect(!ledger.legacyPeers(for: .relayEnvelope).contains("fresh"))
        #expect(receive(try throughLegacyRelay(v2Envelope(origin: "fresh")), ledger) == .rejectedDowngrade)
    }

    @Test("Refuse policy rejects every v1 envelope but still accepts v2")
    func refusePolicy() {
        let ledger = PeerProtocolLedger(policy: .refuse)
        #expect(receive(v1Envelope(origin: "old"), ledger) == .rejectedLegacy)
        #expect(receive(v2Envelope(origin: "new"), ledger) == .acceptedV2)
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }

    @Test("Pins are per origin and per feature")
    func pinScope() {
        let ledger = PeerProtocolLedger()
        #expect(receive(v2Envelope(origin: "a"), ledger) == .acceptedV2)
        #expect(receive(v1Envelope(origin: "b"), ledger) == .acceptedLegacy)
        #expect(!ledger.isPinnedToV2("a", feature: .callMedia))
        #expect(ledger.admit(peerID: "a", feature: .callMedia, version: 1) == .acceptedLegacy)
    }

    @Test("A departed peer loses its legacy flag but keeps its v2 pin")
    func departure() {
        let ledger = PeerProtocolLedger()
        _ = receive(v1Envelope(origin: "old"), ledger)
        _ = receive(v2Envelope(origin: "new"), ledger)
        ledger.peerDeparted("old")
        ledger.peerDeparted("new")
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
        #expect(receive(v1Envelope(origin: "new"), ledger) == .rejectedDowngrade)
    }
}

// MARK: - MeshRelayService integration

@MainActor
@Suite("MeshRelayService v2 integration")
struct MeshRelayServiceV2Tests {

    func service(ledger: PeerProtocolLedger = PeerProtocolLedger()) -> (MeshRelayService, UUID, SymmetricKey) {
        let s = MeshRelayService(localPeerID: "local", protocolLedger: ledger)
        let pool = UUID()
        let secret = SymmetricKey(size: .bits256)
        s.setCurrentPool(pool)
        s.poolSharedSecret = secret
        return (s, pool, secret)
    }

    @Test("Delivers a v2 envelope addressed to us")
    func deliversV2() async {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var delivered: [RelayEnvelope] = []
        let c = s.receivedEnvelope.sink { delivered.append($0) }
        defer { c.cancel() }
        let e = MeshRelayService.makeSignedEnvelope(origin: "peer-A", destination: "local", payload: Data("x".utf8), poolID: pool, sharedSecret: secret)
        s.handleRelayEnvelope(e, from: "peer-A")
        #expect(delivered.count == 1)
        #expect(s.droppedMessageCount == 0)
        #expect(s.legacyEnvelopeOrigins.isEmpty)
        #expect(s.protocolLedger.isPinnedToV2("peer-A", feature: .relayEnvelope))
    }

    @Test("Flags a v1 origin, then refuses its downgrade after v2 is seen")
    func flagsAndRefuses() {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        let legacy = RelayEnvelope(originPeerID: "peer-A", destinationPeerID: "local", hopPath: ["peer-A"],
                                   encryptedPayload: Data("x".utf8), poolID: pool).withHMAC(using: k1)
        s.handleRelayEnvelope(legacy, from: "peer-A")
        #expect(s.legacyEnvelopeOrigins == ["peer-A"])
        #expect(s.droppedMessageCount == 0)

        s.handleRelayEnvelope(MeshRelayService.makeSignedEnvelope(origin: "peer-A", destination: "local", payload: Data("y".utf8), poolID: pool, sharedSecret: secret), from: "peer-A")
        #expect(s.legacyEnvelopeOrigins.isEmpty, "v2 clears the legacy flag")

        let downgrade = RelayEnvelope(originPeerID: "peer-A", destinationPeerID: "local", hopPath: ["peer-A"],
                                      encryptedPayload: Data("z".utf8), poolID: pool).withHMAC(using: k1)
        s.handleRelayEnvelope(downgrade, from: "peer-A")
        #expect(s.downgradeRejectionCount == 1)
        #expect(s.droppedMessageCount == 1)
    }

    @Test("Ledger shared through the pool manager outlives a relay service")
    func sharedLedger() {
        let ledger = PeerProtocolLedger()
        let (first, pool, secret) = service(ledger: ledger)
        first.handleRelayEnvelope(MeshRelayService.makeSignedEnvelope(origin: "peer-B", destination: "local", payload: Data([1]), poolID: pool, sharedSecret: secret), from: "peer-B")
        first.clearCurrentPool(); first.cleanup()

        let second = MeshRelayService(localPeerID: "local", protocolLedger: ledger)
        second.setCurrentPool(pool)
        second.poolSharedSecret = secret
        defer { second.clearCurrentPool(); second.cleanup() }
        let legacy = RelayEnvelope(originPeerID: "peer-B", destinationPeerID: "local", hopPath: ["peer-B"],
                                   encryptedPayload: Data([2]), poolID: pool).withHMAC(using: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool))
        second.handleRelayEnvelope(legacy, from: "peer-B")
        #expect(second.downgradeRejectionCount == 1)
    }

    @Test("Tampered TTL on a v2 envelope is dropped")
    func ttlDrop() {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var e = MeshRelayService.makeSignedEnvelope(origin: "peer-A", destination: "other", payload: Data([1]), poolID: pool, sharedSecret: secret)
        e = e.forwarded(by: "r1")!
        e.ttl = 5 // relay tries to restore a full hop budget
        s.handleRelayEnvelope(e, from: "r1")
        #expect(s.droppedMessageCount == 1)
    }
}
