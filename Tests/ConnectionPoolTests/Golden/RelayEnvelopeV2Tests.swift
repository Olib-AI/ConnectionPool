// RelayEnvelopeV2Tests.swift
// ConnectionPoolTests
//
// RelayEnvelope integrity v2 (StealthOS 1.5.0+): golden vectors produced by an independent
// Python reference, per-sender Ed25519 authenticity, tamper resistance, routing invariants,
// and the v1/v2 negotiation and downgrade matrix.

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

/// Rebuilds `e` with selected fields replaced (everything else copied, including all MACs
/// and the signature) - the shape of every tampering attack.
private func tampered(
    _ e: RelayEnvelope,
    origin: String? = nil, destination: String?? = nil, payload: Data? = nil,
    timestamp: Date? = nil, hopPath: [String]? = nil, signature: Data?? = nil
) -> RelayEnvelope {
    RelayEnvelope(
        messageID: e.messageID, originPeerID: origin ?? e.originPeerID,
        destinationPeerID: destination ?? e.destinationPeerID, ttl: e.ttl,
        hopPath: hopPath ?? (origin.map { [$0] } ?? e.hopPath),
        encryptedPayload: payload ?? e.encryptedPayload, poolID: e.poolID,
        timestamp: timestamp ?? e.timestamp, envelopeHMAC: e.envelopeHMAC,
        envelopeVersion: e.envelopeVersion, originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2,
        originSignature: signature ?? e.originSignature
    )
}

@Suite("RelayEnvelope v2 golden vectors")
struct RelayEnvelopeV2VectorTests {

    @Test("v2 vector file inventory")
    func inventory() {
        #expect(Golden.vectors(v2File, kind: "hmac_key_v2").count == 1)
        #expect(Golden.vectors(v2File, kind: "envelope_v2").count == 11)
        #expect(Golden.vectors(v2File, kind: "envelope_v2_tamper").count == 35)
        #expect(Golden.vectors(v2File, kind: "signing_key_binding").count == 8)
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

    @Test("Signing-key binding statements and signatures", arguments: Golden.vectors(v2File, kind: "signing_key_binding"))
    func binding(_ v: GoldenVector) throws {
        let peer = try v.inputString("peer_id")
        let pool = try v.inputUUID("pool_id")
        let x25519 = try v.inputHex("key_agreement_public_hex")
        let registry = EnvelopeSigningKeys()
        if v.expect == "ok" {
            let signer = try TestSigners.signer(seed: try v.inputHex("signing_seed_hex"))
            let signingPub = try v.outputHex("signing_public_hex")
            #expect(signer.localPublicKey == signingPub)
            #expect(EnvelopeSigningKeys.bindingStatement(peerID: peer, poolID: pool, keyAgreementPublicKey: x25519, signingPublicKey: signingPub)
                    == (try v.outputHex("statement_hex")))
            // The frozen (deterministic) reference signature verifies through production...
            #expect(registry.register(peerID: peer, signingPublicKey: signingPub, binding: try v.outputHex("binding_signature_hex"),
                                      keyAgreementPublicKey: x25519, poolID: pool) == .registered)
            // ...and production's own (randomised) binding verifies too.
            let own = try #require(signer.makeBinding(localPeerID: peer, poolID: pool, keyAgreementPublicKey: x25519))
            #expect(EnvelopeSigningKeys().register(peerID: peer, signingPublicKey: signingPub, binding: own,
                                                   keyAgreementPublicKey: x25519, poolID: pool) == .registered)
        } else {
            #expect(registry.register(peerID: peer, signingPublicKey: try v.inputHex("signing_public_hex"),
                                      binding: try v.inputHex("binding_signature_hex"),
                                      keyAgreementPublicKey: x25519, poolID: pool) == .invalidBinding)
            #expect(registry.signingKey(for: peer) == nil)
        }
    }

    @Test("v2 MAC input, tag and origin signature are bit-exact", arguments: Golden.vectors(v2File, kind: "envelope_v2"))
    func envelope(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("receiver_pool_id")
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        let k2 = RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)
        let e = try decodeEnvelope(v, key: "envelope_json")
        let signers = try TestSigners.registry(v.inputs["known_signers"])

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
        #expect(e.originSignature == (try v.outputHex("origin_signature_hex")))
        let originKey = try Curve25519.Signing.PublicKey(rawRepresentation: try v.outputHex("origin_signing_public_hex"))
        #expect(e.verifyOriginSignature(using: originKey))
        #expect(!e.verifyOriginSignature(using: Curve25519.Signing.PrivateKey().publicKey))
        // A 1.4.x receiver checks only the v1 tag, which the 1.5.0 origin also attached.
        #expect(e.verifyHMAC(using: k1))
        #expect(e.envelopeHMAC == (try v.outputHex("hmac_v1_hex")))

        let ledger = PeerProtocolLedger()
        #expect(e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, signers: signers, now: e.timestamp) == .acceptedV2)
        #expect(ledger.isPinnedToV2(e.originPeerID, feature: .relayEnvelope))

        if let introHex = v.outputs["origin_introduction_hex"]?.string {
            #expect(e.originIntroduction == Data(hex: introHex))
            #expect(e.introduction?.keyAgreementKey == (try v.outputHex("introduced_key_agreement_hex")))
            #expect(signers.signingKey(for: e.originPeerID) == nil, "first contact: the receiver had no key")
        }

        // Production re-encoding keeps every v2 field.
        let round = try #require(e.encode().flatMap(RelayEnvelope.decode(from:)))
        #expect(round.verify(sharedSecret: secret, receiverPoolID: pool, ledger: PeerProtocolLedger(), signers: signers, now: e.timestamp) == .acceptedV2)
    }

    @Test("Origin-side signing reproduces the reference MACs and a verifiable signature",
          arguments: Golden.vectors(v2File, kind: "envelope_v2").filter {
              $0.inputs["ttl"]?.int == $0.inputs["origin_ttl"]?.int && $0.outputs["origin_introduction_hex"] == nil
          })
    func originSigning(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("pool_id")
        let origin = try v.inputString("origin_peer_id")
        let signer = try TestSigners.signer(seed: try v.inputHex("origin_signing_seed_hex"))
        let fresh = RelayEnvelope(
            messageID: try v.inputUUID("message_id"), originPeerID: origin,
            destinationPeerID: (try v.input("destination_peer_id")).string, ttl: try v.inputInt("ttl"),
            hopPath: [origin], encryptedPayload: try v.inputHex("payload_hex"), poolID: pool,
            timestamp: Date(timeIntervalSinceReferenceDate: try v.inputDouble("timestamp_since_2001"))
        ).signedForV2(v1Key: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool),
                      v2Key: RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool), signer: signer)
        #expect(fresh.envelopeHMACV2 == (try v.outputHex("hmac_v2_hex")))
        #expect(fresh.envelopeHMAC == (try v.outputHex("hmac_v1_hex")))
        #expect(fresh.originTTL == (try v.inputInt("origin_ttl")))
        #expect(fresh.originSignature?.count == 64)
        #expect(fresh.verifyOriginSignature(using: try Curve25519.Signing.PublicKey(rawRepresentation: try v.outputHex("origin_signing_public_hex"))))
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

    @Test("Tampered or forged v2 envelopes are never delivered", arguments: Golden.vectors(v2File, kind: "envelope_v2_tamper"))
    func tamper(_ v: GoldenVector) throws {
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("receiver_pool_id")
        let e = try decodeEnvelope(v, key: "envelope_json")
        let signers = try TestSigners.registry(v.inputs["known_signers"])
        let ledger = PeerProtocolLedger()
        let verdict = e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, signers: signers, now: e.timestamp)
        #expect(!verdict.isAccepted, "\(v.name): \(verdict)")
        switch try v.outputString("verdict") {
        case "relay_only":
            #expect(verdict == .relayOnlyUnknownSigner, "\(v.name): \(verdict)")
        case "key_change":
            #expect(verdict == .rejectedKeyChange, "\(v.name): \(verdict)")
        default:
            if case .rejectedInvalid = verdict {} else { Issue.record("\(v.name) must be rejected, got \(verdict)") }
            #expect(!verdict.mayForward)
        }
        #expect(e.claimsV2, "every tamper vector still claims v2, so no v1 fallback is possible")
        #expect(!ledger.isPinnedToV2(e.originPeerID, feature: .relayEnvelope), "a forged envelope must not pin")
        #expect(ledger.legacyPeers(for: .relayEnvelope).isEmpty)
    }
}

// MARK: - Programmatic tamper / TTL / timestamp / per-sender authenticity

@Suite("RelayEnvelope v2 tamper, routing invariants and sender authenticity")
struct RelayEnvelopeV2TamperTests {
    let secret = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let pool = UUID(uuidString: "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E4")!
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let receiver = TestSigners.registry(knownPeers: ["peer-origin", "peer-mallory", "ab", "o"])

    func signed(origin: String = "peer-origin", destination: String? = "peer-dest", payload: Data = Data("ciphertext".utf8),
                signer: EnvelopeSigningKeys? = nil, at time: Date? = nil) -> RelayEnvelope {
        MeshRelayService.makeSignedEnvelope(
            origin: origin, destination: destination, payload: payload, poolID: pool,
            sharedSecret: secret, signer: signer ?? TestSigners.signer(for: origin), messageID: UUID(), timestamp: time ?? now
        )
    }

    func verdict(_ e: RelayEnvelope, ledger: PeerProtocolLedger = PeerProtocolLedger()) -> RelayEnvelopeVerdict {
        e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, signers: receiver, now: now)
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

    @Test("A pool member forging another member's origin is refused (valid pool MAC, own signature)")
    func memberForgery() {
        let forged = signed(origin: "peer-origin", payload: Data("evil".utf8), signer: TestSigners.signer(for: "peer-mallory"))
        #expect(forged.verifyHMACV2(using: RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)), "the member can produce the pool MAC")
        #expect(verdict(forged) == .rejectedInvalid(reason: "v2 origin signature invalid"))
    }

    @Test("Signature stripped (both MACs still valid) is refused")
    func signatureStripped() {
        let e = tampered(signed(), signature: .some(nil))
        #expect(verdict(e) == .rejectedInvalid(reason: "v2 origin signature missing"))
    }

    @Test("Key substitution: right bytes, another member's key")
    func keySubstitution() throws {
        let genuine = signed()
        let input = try #require(genuine.hmacInputV2())
        let mallorySig = try #require(TestSigners.signer(for: "peer-mallory").sign(input))
        #expect(verdict(tampered(genuine, signature: .some(mallorySig))) == .rejectedInvalid(reason: "v2 origin signature invalid"))
    }

    @Test("A signature valid for another payload is refused even with an insider's fresh pool MAC")
    func signatureForOtherPayload() throws {
        let a = signed(payload: Data("one".utf8))
        // Insider builds an envelope with the same metadata but another payload, re-MACs it,
        // and re-uses the origin's signature from `a`.
        var b = RelayEnvelope(messageID: a.messageID, originPeerID: a.originPeerID, destinationPeerID: a.destinationPeerID,
                              hopPath: a.hopPath, encryptedPayload: Data("two".utf8), poolID: pool, timestamp: a.timestamp)
            .signedForV2(v1Key: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool),
                         v2Key: RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool),
                         signer: TestSigners.signer(for: "peer-mallory"))
        b.originSignature = a.originSignature
        #expect(verdict(b) == .rejectedInvalid(reason: "v2 origin signature invalid"))
    }

    @Test("Cross-pool replay: an insider of pool 2 re-MACs a pool-1 envelope; the signature still binds pool 1")
    func crossPoolReplay() {
        let otherPool = UUID()
        let original = MeshRelayService.makeSignedEnvelope(origin: "peer-origin", destination: "peer-dest", payload: Data([1]),
                                                           poolID: otherPool, sharedSecret: secret,
                                                           signer: TestSigners.signer(for: "peer-origin"), timestamp: now)
        var replay = RelayEnvelope(messageID: original.messageID, originPeerID: original.originPeerID,
                                   destinationPeerID: original.destinationPeerID, hopPath: original.hopPath,
                                   encryptedPayload: original.encryptedPayload, poolID: pool, timestamp: original.timestamp)
            .signedForV2(v1Key: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool),
                         v2Key: RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool),
                         signer: TestSigners.signer(for: "peer-mallory"))
        replay.originSignature = original.originSignature
        #expect(verdict(replay) == .rejectedInvalid(reason: "v2 origin signature invalid"))
        // And the untouched envelope fails the pool MAC in the wrong pool.
        #expect(verdict(original) == .rejectedInvalid(reason: "v2 HMAC verification failed"))
    }

    @Test("Unknown signer: forward only, never deliver, never pin")
    func unknownSigner() {
        let ledger = PeerProtocolLedger()
        let e = signed(origin: "stranger")
        #expect(verdict(e, ledger: ledger) == .relayOnlyUnknownSigner)
        #expect(verdict(e).mayForward && !verdict(e).isAccepted)
        #expect(!ledger.isPinnedToV2("stranger", feature: .relayEnvelope))
    }

    @Test("Signature truncated, extended or bit-flipped is refused", arguments: [-1, 1, 0])
    func signatureShape(_ mode: Int) throws {
        let e = signed()
        var sig = try #require(e.originSignature)
        switch mode {
        case -1: sig.removeLast()
        case 1: sig.append(0)
        default: sig[sig.startIndex + 17] ^= 0x04
        }
        #expect(!verdict(tampered(e, signature: .some(sig))).isAccepted)
    }

    @Test("Swapped payload is rejected (v2 covers it)")
    func swappedPayload() {
        #expect(verdict(tampered(signed(), payload: Data("other".utf8))) == .rejectedInvalid(reason: "v2 HMAC verification failed"))
    }

    @Test("Payload truncated by one byte or extended by one byte is rejected", arguments: [-1, 1])
    func payloadLength(_ delta: Int) {
        let e = signed(payload: Data(repeating: 7, count: 64))
        var p = e.encryptedPayload
        if delta < 0 { p.removeLast() } else { p.append(0) }
        #expect(!verdict(tampered(e, payload: p)).isAccepted)
    }

    @Test("Destination nil <-> \"\" swaps are rejected", arguments: [true, false])
    func destinationSwap(_ fromNil: Bool) {
        let e = signed(destination: fromNil ? nil : "")
        let swapped = tampered(e, destination: .some(fromNil ? "" : nil))
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
        #expect(!verdict(tampered(e, timestamp: e.timestamp.addingTimeInterval(delta))).isAccepted)
    }

    @Test("Far-future timestamps are rejected even with a valid MAC and signature")
    func futureTimestamp() {
        let future = signed(origin: "o", destination: nil, payload: Data([1]), at: now.addingTimeInterval(RelayEnvelope.maxFutureSkew + 1))
        #expect(verdict(future) == .rejectedInvalid(reason: "timestamp too far in the future"))
        let skewed = signed(origin: "o", destination: nil, payload: Data([1]), at: now.addingTimeInterval(RelayEnvelope.maxFutureSkew - 1))
        #expect(verdict(skewed) == .acceptedV2)
    }

    @Test("Field-boundary shifting across origin/destination is rejected", arguments: [
        ("abc", "d"), ("a", "bcd"), ("", "abcd"), ("abcd", ""), ("abcd", nil)
    ] as [(String, String?)])
    func boundaryShift(_ shifted: (String, String?)) {
        let e = signed(origin: "ab", destination: "cd")
        #expect(!verdict(tampered(e, origin: shifted.0, destination: .some(shifted.1))).isAccepted)
    }

    @Test("Shifting bytes between destination and payload is rejected")
    func destinationPayloadShift() {
        let e = signed(destination: "dest", payload: Data("Xpayload".utf8))
        #expect(!verdict(tampered(e, destination: .some("destX"), payload: Data("payload".utf8))).isAccepted)
    }

    @Test("Wrong pool secret or wrong receiving pool is rejected")
    func wrongPool() {
        let e = signed()
        #expect(!e.verify(sharedSecret: SymmetricKey(data: Data(repeating: 0x43, count: 32)), receiverPoolID: pool,
                          ledger: PeerProtocolLedger(), signers: receiver, now: now).isAccepted)
        #expect(!e.verify(sharedSecret: secret, receiverPoolID: UUID(), ledger: PeerProtocolLedger(), signers: receiver, now: now).isAccepted)
    }

    @Test("MAC/signature input uses big-endian fixed-width integers")
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
        expected += Data([0x00]) // no introduction
        #expect(input == expected)
    }
}

// MARK: - Signing-key registry (TOFU per session)

@Suite("Envelope signing-key registry")
struct EnvelopeSigningKeysTests {
    let pool = UUID()
    let x25519 = Data(repeating: 0x09, count: 32)

    func introduce(_ signer: EnvelopeSigningKeys, as peer: String, to registry: EnvelopeSigningKeys, x: Data? = nil) -> EnvelopeSigningKeys.Registration {
        let binding = signer.makeBinding(localPeerID: peer, poolID: pool, keyAgreementPublicKey: x ?? x25519)!
        return registry.register(peerID: peer, signingPublicKey: signer.localPublicKey, binding: binding,
                                 keyAgreementPublicKey: x ?? x25519, poolID: pool)
    }

    @Test("First key wins; the same key again is unchanged")
    func tofu() {
        let r = EnvelopeSigningKeys(), alice = EnvelopeSigningKeys()
        #expect(introduce(alice, as: "alice", to: r) == .registered)
        #expect(introduce(alice, as: "alice", to: r) == .unchanged)
        #expect(r.signingKey(for: "alice")?.rawRepresentation == alice.localPublicKey)
    }

    @Test("A different key for a known peer is refused and reported")
    func keyChangeRefused() {
        let r = EnvelopeSigningKeys()
        var events: [EnvelopeSigningKeys.Event] = []
        let c = r.events.sink { events.append($0) }
        defer { c.cancel() }
        let alice = EnvelopeSigningKeys(), impostor = EnvelopeSigningKeys()
        #expect(introduce(alice, as: "alice", to: r) == .registered)
        #expect(introduce(impostor, as: "alice", to: r, x: Data(repeating: 0x0A, count: 32)) == .refusedKeyChange)
        #expect(r.signingKey(for: "alice")?.rawRepresentation == alice.localPublicKey, "the first key stays")
        #expect(events.count == 1)
        if case .keyChangeRefused(let peer, let old, let new)? = events.first {
            #expect(peer == "alice")
            #expect(old == EnvelopeSigningKeys.fingerprint(alice.localPublicKey))
            #expect(new == EnvelopeSigningKeys.fingerprint(impostor.localPublicKey))
        }
    }

    @Test("After the peer's direct link drops, a new session key is accepted")
    func forgetOnDisconnect() {
        let r = EnvelopeSigningKeys(), first = EnvelopeSigningKeys(), second = EnvelopeSigningKeys()
        #expect(introduce(first, as: "alice", to: r) == .registered)
        r.forget(peerID: "alice")
        #expect(introduce(second, as: "alice", to: r) == .registered)
    }

    @Test("Bindings for another peer, pool or E2E key are invalid")
    func bindingScope() {
        let r = EnvelopeSigningKeys(), alice = EnvelopeSigningKeys()
        let binding = alice.makeBinding(localPeerID: "alice", poolID: pool, keyAgreementPublicKey: x25519)!
        #expect(r.register(peerID: "mallory", signingPublicKey: alice.localPublicKey, binding: binding, keyAgreementPublicKey: x25519, poolID: pool) == .invalidBinding)
        #expect(r.register(peerID: "alice", signingPublicKey: alice.localPublicKey, binding: binding, keyAgreementPublicKey: x25519, poolID: UUID()) == .invalidBinding)
        #expect(r.register(peerID: "alice", signingPublicKey: alice.localPublicKey, binding: binding, keyAgreementPublicKey: Data(repeating: 1, count: 32), poolID: pool) == .invalidBinding)
        #expect(r.register(peerID: "alice", signingPublicKey: Data(count: 31), binding: binding, keyAgreementPublicKey: x25519, poolID: pool) == .invalidBinding)
        #expect(r.register(peerID: "alice", signingPublicKey: alice.localPublicKey, binding: Data(binding.prefix(63)), keyAgreementPublicKey: x25519, poolID: pool) == .invalidBinding)
        #expect(r.signingKey(for: "alice") == nil && r.signingKey(for: "mallory") == nil)
    }

    @Test("resetSession rotates the local key and forgets peers")
    func reset() {
        let r = EnvelopeSigningKeys(), alice = EnvelopeSigningKeys()
        _ = introduce(alice, as: "alice", to: r)
        let before = r.localPublicKey
        r.resetSession()
        #expect(r.localPublicKey != before)
        #expect(r.signingKey(for: "alice") == nil)
    }
}

// MARK: - Negotiation / downgrade matrix

@Suite("Relay envelope negotiation and downgrade matrix")
struct RelayEnvelopeNegotiationTests {
    let secret = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    let pool = UUID()
    let now = Date()
    let receiver = TestSigners.registry(knownPeers: ["old", "new", "peer", "victim", "fresh", "a", "b", "x"])

    /// What a StealthOS 1.4.x origin emits.
    func v1Envelope(origin: String, payload: Data = Data("p".utf8)) -> RelayEnvelope {
        RelayEnvelope(originPeerID: origin, destinationPeerID: "dest", hopPath: [origin], encryptedPayload: payload,
                      poolID: pool, timestamp: now).withHMAC(using: RelayEnvelope.deriveHMACKey(from: secret, poolID: pool))
    }

    /// What a 1.5.0+ origin emits.
    func v2Envelope(origin: String, payload: Data = Data("p".utf8)) -> RelayEnvelope {
        MeshRelayService.makeSignedEnvelope(origin: origin, destination: "dest", payload: payload, poolID: pool,
                                            sharedSecret: secret, signer: TestSigners.signer(for: origin), timestamp: now)
    }

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
        e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, signers: receiver, now: now)
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

    @Test("Attacker strips only part of v2 or sets an unknown version: fails closed")
    func partialStrip() {
        let ledger = PeerProtocolLedger()
        var a = v2Envelope(origin: "x"); a.envelopeHMACV2 = nil
        var b = v2Envelope(origin: "x"); b.envelopeVersion = nil
        var c = v2Envelope(origin: "x"); c.originTTL = nil
        var d = v2Envelope(origin: "x"); d.envelopeVersion = 3
        var e = v2Envelope(origin: "x"); e.originSignature = nil
        for env in [a, b, c, d, e] {
            if case .rejectedInvalid = receive(env, ledger) {} else { Issue.record("partial strip accepted: \(env)") }
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

    func service(ledger: PeerProtocolLedger = PeerProtocolLedger(),
                 known: [String] = ["peer-A", "peer-B"]) -> (MeshRelayService, UUID, SymmetricKey) {
        let s = MeshRelayService(localPeerID: "local", protocolLedger: ledger, signingKeys: TestSigners.registry(knownPeers: known))
        let pool = UUID()
        let secret = SymmetricKey(size: .bits256)
        s.setCurrentPool(pool)
        s.poolSharedSecret = secret
        return (s, pool, secret)
    }

    func envelope(_ origin: String, to destination: String?, _ payload: Data, pool: UUID, secret: SymmetricKey, signer: String? = nil) -> RelayEnvelope {
        MeshRelayService.makeSignedEnvelope(origin: origin, destination: destination, payload: payload, poolID: pool,
                                            sharedSecret: secret, signer: TestSigners.signer(for: signer ?? origin))
    }

    @Test("Delivers a signed v2 envelope addressed to us")
    func deliversV2() async {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var delivered: [RelayEnvelope] = []
        let c = s.receivedEnvelope.sink { delivered.append($0) }
        defer { c.cancel() }
        s.handleRelayEnvelope(envelope("peer-A", to: "local", Data("x".utf8), pool: pool, secret: secret), from: "peer-A")
        #expect(delivered.count == 1)
        #expect(s.droppedMessageCount == 0)
        #expect(s.legacyEnvelopeOrigins.isEmpty)
        #expect(s.protocolLedger.isPinnedToV2("peer-A", feature: .relayEnvelope))
    }

    @Test("A member's forged origin is not delivered")
    func forgedOriginNotDelivered() {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var delivered = 0
        let c = s.receivedEnvelope.sink { _ in delivered += 1 }
        defer { c.cancel() }
        s.handleRelayEnvelope(envelope("peer-A", to: "local", Data("evil".utf8), pool: pool, secret: secret, signer: "peer-B"), from: "peer-B")
        #expect(delivered == 0)
        #expect(s.droppedMessageCount == 1)
        #expect(!s.protocolLedger.isPinnedToV2("peer-A", feature: .relayEnvelope))
    }

    @Test("Unknown signer addressed to us: not delivered")
    func unknownSignerForwardOnly() {
        let (s, pool, secret) = service(known: [])
        defer { s.clearCurrentPool(); s.cleanup() }
        var delivered = 0
        let c = s.receivedEnvelope.sink { _ in delivered += 1 }
        defer { c.cancel() }
        s.handleRelayEnvelope(envelope("peer-A", to: "local", Data("x".utf8), pool: pool, secret: secret), from: "peer-A")
        #expect(delivered == 0)
        #expect(s.droppedMessageCount == 1)
    }

    @Test("Flags a v1 origin, then refuses its downgrade after v2 is seen, and tells the UI once")
    func flagsAndRefuses() {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var notices: [MeshRelayService.UnverifiableRelayedMessage] = []
        let c = s.unverifiableRelayedMessage.sink { notices.append($0) }
        defer { c.cancel() }
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        let legacy = RelayEnvelope(originPeerID: "peer-A", destinationPeerID: "local", hopPath: ["peer-A"],
                                   encryptedPayload: Data("x".utf8), poolID: pool).withHMAC(using: k1)
        s.handleRelayEnvelope(legacy, from: "peer-A")
        #expect(s.legacyEnvelopeOrigins == ["peer-A"])
        #expect(s.droppedMessageCount == 0)

        s.handleRelayEnvelope(envelope("peer-A", to: "local", Data("y".utf8), pool: pool, secret: secret), from: "peer-A")
        #expect(s.legacyEnvelopeOrigins.isEmpty, "v2 clears the legacy flag")

        for i in 0..<3 {
            let downgrade = RelayEnvelope(originPeerID: "peer-A", destinationPeerID: "local", hopPath: ["peer-A"],
                                          encryptedPayload: Data([UInt8(i)]), poolID: pool).withHMAC(using: k1)
            s.handleRelayEnvelope(downgrade, from: "relay")
        }
        #expect(s.downgradeRejectionCount == 3)
        #expect(s.droppedMessageCount == 3)
        #expect(notices.count == 1, "throttled per origin")
        #expect(notices.first?.originPeerID == "peer-A")
        #expect(notices.first?.wasBroadcast == false)
    }

    @Test("No notice for stripped envelopes addressed to someone else")
    func noNoticeForOthers() {
        let (s, pool, secret) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        var notices = 0
        let c = s.unverifiableRelayedMessage.sink { _ in notices += 1 }
        defer { c.cancel() }
        s.handleRelayEnvelope(envelope("peer-A", to: "local", Data("y".utf8), pool: pool, secret: secret), from: "peer-A")
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        s.handleRelayEnvelope(RelayEnvelope(originPeerID: "peer-A", destinationPeerID: "someone-else", hopPath: ["peer-A"],
                                            encryptedPayload: Data([1]), poolID: pool).withHMAC(using: k1), from: "relay")
        #expect(notices == 0)
        #expect(s.downgradeRejectionCount == 1)
    }

    @Test("Ledger shared through the pool manager outlives a relay service")
    func sharedLedger() {
        let ledger = PeerProtocolLedger()
        let (first, pool, secret) = service(ledger: ledger)
        first.handleRelayEnvelope(envelope("peer-B", to: "local", Data([1]), pool: pool, secret: secret), from: "peer-B")
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
        var e = envelope("peer-A", to: "other", Data([1]), pool: pool, secret: secret)
        e = e.forwarded(by: "r1")!
        e.ttl = 5 // relay tries to restore a full hop budget
        s.handleRelayEnvelope(e, from: "r1")
        #expect(s.droppedMessageCount == 1)
    }

    @Test("A peer's signing key is forgotten when its direct link drops")
    func forgetOnDisconnect() {
        let (s, _, _) = service()
        defer { s.clearCurrentPool(); s.cleanup() }
        #expect(s.signingKeys.signingKey(for: "peer-A") != nil)
        s.peerConnected("peer-A")
        s.peerDisconnected("peer-A")
        #expect(s.signingKeys.signingKey(for: "peer-A") == nil)
    }
}

// MARK: - Pool integrity secret across peers

@MainActor
@Suite("Pool integrity secret: every member derives the same key")
struct PoolIntegritySecretTests {

    /// Two simulated peers configured exactly as ConnectionPoolManager does: the host from
    /// its generated code, the joiner from the code it typed in.
    @Test("Envelopes from the host verify at a joiner and vice versa")
    func crossPeerVerification() throws {
        let poolID = UUID()
        let hostSigning = EnvelopeSigningKeys(), joinerSigning = EnvelopeSigningKeys()
        let host = MeshRelayService(localPeerID: "host", signingKeys: hostSigning)
        let joiner = MeshRelayService(localPeerID: "joiner", signingKeys: joinerSigning)
        defer { host.cleanup(); joiner.cleanup() }
        let hostSecret = try #require(ConnectionPoolManager.configureRelay(host, poolID: poolID, poolCode: "K7Q2XP"))
        let joinerSecret = try #require(ConnectionPoolManager.configureRelay(joiner, poolID: poolID, poolCode: "K7Q2XP"))
        #expect(keyBytes(hostSecret) == keyBytes(joinerSecret))
        #expect(keyBytes(hostSecret) == Data(SHA256.hash(data: Data("K7Q2XP".utf8))), "1.4.x-compatible derivation")

        // Each side learns the other's signing key from the E2E key exchange.
        let x = Data(repeating: 7, count: 32)
        #expect(joinerSigning.register(peerID: "host", signingPublicKey: hostSigning.localPublicKey,
                                       binding: hostSigning.makeBinding(localPeerID: "host", poolID: poolID, keyAgreementPublicKey: x)!,
                                       keyAgreementPublicKey: x, poolID: poolID) == .registered)
        #expect(hostSigning.register(peerID: "joiner", signingPublicKey: joinerSigning.localPublicKey,
                                     binding: joinerSigning.makeBinding(localPeerID: "joiner", poolID: poolID, keyAgreementPublicKey: x)!,
                                     keyAgreementPublicKey: x, poolID: poolID) == .registered)

        var atJoiner = 0, atHost = 0
        let c1 = joiner.receivedEnvelope.sink { _ in atJoiner += 1 }
        let c2 = host.receivedEnvelope.sink { _ in atHost += 1 }
        defer { c1.cancel(); c2.cancel() }
        joiner.handleRelayEnvelope(MeshRelayService.makeSignedEnvelope(origin: "host", destination: "joiner", payload: Data([1]),
                                                                       poolID: poolID, sharedSecret: hostSecret, signer: hostSigning), from: "host")
        host.handleRelayEnvelope(MeshRelayService.makeSignedEnvelope(origin: "joiner", destination: "host", payload: Data([2]),
                                                                     poolID: poolID, sharedSecret: joinerSecret, signer: joinerSigning), from: "joiner")
        #expect(atJoiner == 1 && atHost == 1)
        #expect(joiner.droppedMessageCount == 0 && host.droppedMessageCount == 0)
    }

    @Test("A wrong code or a device-local secret does not interoperate")
    func mismatchedSecrets() throws {
        let poolID = UUID()
        let a = PoolIntegritySecret.derive(poolCode: "K7Q2XP")
        let b = PoolIntegritySecret.derive(poolCode: "K7Q2XQ")
        #expect(keyBytes(a) != keyBytes(b))
        // The pre-fix Pool Chat derivation mixed in each device's own public key, so no two
        // members ever agreed. Reproduced here to document why it was replaced.
        func deviceLocal(_ publicKey: Data) -> Data {
            Data("StealthOS-PoolSharedSecret-v1".utf8) + publicKey + withUnsafeBytes(of: poolID.uuid) { Data($0) }
        }
        #expect(deviceLocal(Data(repeating: 1, count: 32)) != deviceLocal(Data(repeating: 2, count: 32)))
    }

    @Test("Pools without a code have no secret: relaying is disabled, not faked")
    func noCode() {
        let relay = MeshRelayService(localPeerID: "p")
        defer { relay.cleanup() }
        #expect(ConnectionPoolManager.configureRelay(relay, poolID: UUID(), poolCode: nil) == nil)
        #expect(relay.poolSharedSecret == nil)
    }
}
