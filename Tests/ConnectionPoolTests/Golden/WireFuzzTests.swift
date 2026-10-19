// WireFuzzTests.swift
// ConnectionPoolTests
//
// Seeded random fuzzing of the envelope, outer-layer and PoW-challenge parsers. Each test
// prints its seed; rerun one with WIRE_FUZZ_SEED=<seed> in the test environment.

import Foundation
import CryptoKit
import Testing
@testable import ConnectionPool

@Suite("Seeded wire fuzzing (ConnectionPool)")
struct WireFuzzTests {
    static let iterations = 2_000

    /// Mutates bytes: flips, inserts, deletes, truncates, duplicates.
    static func mutate(_ input: Data, rng: inout SeededGenerator) -> Data {
        var bytes = [UInt8](input)
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            switch Int.random(in: 0..<6, using: &rng) {
            case 0 where !bytes.isEmpty:
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                bytes[i] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            case 1:
                bytes.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
            case 2 where !bytes.isEmpty:
                bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
            case 3:
                bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
            case 4 where !bytes.isEmpty:
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                bytes.insert(contentsOf: bytes[i...].prefix(16), at: i)
            default:
                let tokens = ["\"", "{", "}", "[", "]", ",", ":", "null", "true", "-1", "1e309", "\\u0000", "9999999999999999999"]
                let t = Array(tokens[Int.random(in: 0..<tokens.count, using: &rng)].utf8)
                bytes.insert(contentsOf: t, at: Int.random(in: 0...bytes.count, using: &rng))
            }
        }
        return Data(bytes)
    }

    @Test("RelayEnvelope decode + verify never crashes on mutated envelopes")
    func envelopeFuzz() throws {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0001)
        print("[WireFuzz] envelopeFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let secret = SymmetricKey(data: rng.bytes(32))
        let pool = UUID()
        let ledger = PeerProtocolLedger()
        var seeds: [Data] = Golden.vectors("relay_envelope_hmac_v2.json").compactMap {
            ($0.outputs["envelope_json"]?.string ?? $0.inputs["envelope_json"]?.string).map { Data($0.utf8) }
        }
        seeds += Golden.vectors("relay_envelope_hmac.json").compactMap {
            ($0.outputs["envelope_json"]?.string ?? $0.inputs["envelope_json"]?.string).map { Data($0.utf8) }
        }
        let fresh = MeshRelayService.makeSignedEnvelope(origin: "o", destination: "d", payload: Data([1, 2, 3]), poolID: pool,
                                                        sharedSecret: secret, signer: TestSigners.signer(for: "o"))
        let signers = TestSigners.registry(knownPeers: ["o", "peer-origin", "ab", "abc", "a", "peer-mallory"])
        seeds.append(try #require(fresh.encode()))
        #expect(seeds.count > 30)

        var decoded = 0, accepted = 0
        for i in 0..<Self.iterations {
            let base = seeds[i % seeds.count]
            let input = i % 10 == 0 ? rng.bytes(Int.random(in: 0...512, using: &rng)) : Self.mutate(base, rng: &rng)
            guard let e = RelayEnvelope.decode(from: input) else { continue }
            decoded += 1
            _ = e.hmacInputV2()
            _ = e.verifyV2RoutingInvariants()
            _ = e.forwarded(by: "fuzz")
            if e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, signers: signers).isAccepted {
                accepted += 1
                // Anything accepted must really carry a valid MAC (and, for v2, the origin's signature).
                let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
                let k2 = RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)
                let v2ok = e.verifyHMACV2(using: k2) && signers.signingKey(for: e.originPeerID).map(e.verifyOriginSignature(using:)) == true
                #expect(v2ok || (!e.claimsV2 && e.verifyHMAC(using: k1)), "seed \(seed) iteration \(i)")
            }
        }
        print("[WireFuzz] envelopeFuzz decoded=\(decoded) accepted=\(accepted)")
        #expect(decoded > 0)
    }

    @Test("Structure-aware field and signature mutation never verifies unless unchanged")
    func envelopeFieldFuzz() {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0006)
        print("[WireFuzz] envelopeFieldFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let secret = SymmetricKey(data: rng.bytes(32))
        let pool = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let origins = (0..<20).map { "o-\($0)" }
        let signers = Dictionary(uniqueKeysWithValues: origins.map { ($0, TestSigners.signer(for: $0)) })
        let registry = TestSigners.registry(knownPeers: origins)
        let k1 = RelayEnvelope.deriveHMACKey(from: secret, poolID: pool)
        let k2 = RelayEnvelope.deriveHMACKeyV2(from: secret, poolID: pool)

        func copy(_ e: RelayEnvelope, origin: String? = nil, destination: String?? = nil, payload: Data? = nil,
                  messageID: UUID? = nil, timestamp: Date? = nil, signature: Data?? = nil) -> RelayEnvelope {
            RelayEnvelope(messageID: messageID ?? e.messageID, originPeerID: origin ?? e.originPeerID,
                          destinationPeerID: destination ?? e.destinationPeerID, ttl: e.ttl,
                          hopPath: origin.map { [$0] } ?? e.hopPath, encryptedPayload: payload ?? e.encryptedPayload,
                          poolID: e.poolID, timestamp: timestamp ?? e.timestamp, envelopeHMAC: e.envelopeHMAC,
                          envelopeVersion: e.envelopeVersion, originTTL: e.originTTL, envelopeHMACV2: e.envelopeHMACV2,
                          originSignature: signature ?? e.originSignature)
        }

        var rejected = 0
        for i in 0..<Self.iterations {
            let origin = origins[Int.random(in: 0..<origins.count, using: &rng)]
            let original = MeshRelayService.makeSignedEnvelope(
                origin: origin,
                destination: Bool.random(using: &rng) ? nil : "d-\(Int.random(in: 0..<50, using: &rng))",
                payload: rng.bytes(Int.random(in: 0...64, using: &rng)), poolID: pool, sharedSecret: secret,
                signer: signers[origin]!, timestamp: now
            )
            var e = original
            switch Int.random(in: 0..<14, using: &rng) {
            case 0: e = copy(e, origin: e.originPeerID + "x")
            case 1: e = copy(e, destination: .some(e.destinationPeerID == nil ? "" : nil))
            case 2: e = copy(e, payload: e.encryptedPayload + Data([UInt8.random(in: 0...255, using: &rng)]))
            case 3: e = copy(e, messageID: UUID())
            case 4: e = copy(e, timestamp: e.timestamp.addingTimeInterval(Double.random(in: -10...10, using: &rng)))
            case 5: e.originTTL = Int.random(in: -2...9, using: &rng)
            case 6: e.ttl = Int.random(in: -2...9, using: &rng)
            case 7: e.envelopeHMACV2 = e.envelopeHMACV2.map { var d = $0; d[d.startIndex + Int.random(in: 0..<d.count, using: &rng)] ^= 0x80; return d }
            case 8: e.hopPath = (0..<Int.random(in: 0...6, using: &rng)).map { "h\($0)" }
            case 9: // signature bit flip
                e.originSignature = e.originSignature.map { var d = $0; d[d.startIndex + Int.random(in: 0..<d.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng)); return d }
            case 10: // signature stripped
                e.originSignature = nil
            case 11: // another member forges this origin with a fully valid pool MAC
                let forger = origins[(origins.firstIndex(of: origin)! + 1) % origins.count]
                e = RelayEnvelope(messageID: e.messageID, originPeerID: origin, destinationPeerID: e.destinationPeerID,
                                  hopPath: [origin], encryptedPayload: rng.bytes(8), poolID: pool, timestamp: now)
                    .signedForV2(v1Key: k1, v2Key: k2, signer: signers[forger]!)
            case 12: // random 64-byte signature
                e.originSignature = rng.bytes(64)
            default: // signature from a different genuine envelope by the same origin
                let other = MeshRelayService.makeSignedEnvelope(origin: origin, destination: e.destinationPeerID, payload: rng.bytes(9),
                                                                poolID: pool, sharedSecret: secret, signer: signers[origin]!, timestamp: now)
                e.originSignature = other.originSignature
            }
            let unchanged = e.originPeerID == original.originPeerID && e.destinationPeerID == original.destinationPeerID
                && e.encryptedPayload == original.encryptedPayload && e.messageID == original.messageID
                && e.timestamp == original.timestamp && e.originTTL == original.originTTL && e.ttl == original.ttl
                && e.envelopeHMACV2 == original.envelopeHMACV2 && e.hopPath == original.hopPath
                && e.originSignature == original.originSignature
            let verdict = e.verify(sharedSecret: secret, receiverPoolID: pool, ledger: PeerProtocolLedger(), signers: registry, now: now)
            if unchanged {
                #expect(verdict == .acceptedV2, "seed \(seed) iteration \(i)")
            } else {
                #expect(!verdict.isAccepted, "seed \(seed) iteration \(i): \(e)")
                rejected += 1
            }
        }
        print("[WireFuzz] envelopeFieldFuzz rejected=\(rejected)")
        #expect(rejected > Self.iterations / 2)
    }

    @Test("v2 MAC input is injective over random field splits")
    func macInputInjective() {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0002)
        print("[WireFuzz] macInputInjective seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let pool = UUID(), mid = UUID(), ts = Date(timeIntervalSinceReferenceDate: 1)
        var seen: [Data: String] = [:]
        for i in 0..<Self.iterations {
            let all = String((0..<Int.random(in: 0...6, using: &rng)).map { _ in "ab\u{e9}".randomElement(using: &rng)! })
            let utf = Array(all.unicodeScalars)
            let cut1 = Int.random(in: 0...utf.count, using: &rng)
            let cut2 = Int.random(in: cut1...utf.count, using: &rng)
            let origin = String(String.UnicodeScalarView(utf[0..<cut1]))
            let destRaw = String(String.UnicodeScalarView(utf[cut1..<cut2]))
            let dest: String? = Bool.random(using: &rng) ? nil : destRaw
            let payload = Data(String(String.UnicodeScalarView(utf[cut2...])).utf8)
            let e = RelayEnvelope(messageID: mid, originPeerID: origin, destinationPeerID: dest, hopPath: [origin],
                                  encryptedPayload: payload, poolID: pool, timestamp: ts, originTTL: 5)
            let input = e.hmacInputV2()!
            let tag = "\(origin.debugDescription)|\(String(describing: dest?.debugDescription))|\(payload.hexString)"
            if let previous = seen[input] {
                #expect(previous == tag, "collision at iteration \(i), seed \(seed)")
            }
            seen[input] = tag
        }
    }

    @Test("PoW challenge parser never crashes and never accepts out-of-contract challenges")
    func powFuzz() {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0003)
        print("[WireFuzz] powFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let base = Data(ProofOfWorkTests.message().utf8)
        for _ in 0..<Self.iterations {
            let input = Bool.random(using: &rng) ? Self.mutate(base, rng: &rng) : rng.bytes(Int.random(in: 0...200, using: &rng))
            let text = String(decoding: input, as: UTF8.self)
            if case .success(let c) = ProofOfWork.parse(message: text) {
                #expect(c.bytes.count == 32 && c.difficulty <= 26, "seed \(seed)")
            }
        }
    }

    @Test("WS outer layer open never crashes and only opens authentic frames")
    func wsFuzz() throws {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0004)
        print("[WireFuzz] wsFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let key = WSOuterLayer.deriveKey(poolSharedSecret: SymmetricKey(data: rng.bytes(32)))
        let genuine = try WSOuterLayer.seal(Data("{\"type\":\"chat\"}".utf8), key: key)
        var opened = 0
        for _ in 0..<Self.iterations {
            let input = Bool.random(using: &rng) ? Self.mutate(genuine, rng: &rng) : rng.bytes(Int.random(in: 0...80, using: &rng))
            if WSOuterLayer.open(input, key: key) != nil { opened += 1; #expect(input == genuine, "seed \(seed)") }
        }
        #expect(opened <= Self.iterations)
    }

    @Test("Transcript builders accept arbitrary-length inputs without trapping")
    func transcriptFuzz() {
        let seed = FuzzSeed.value(default: 0xE57E_10FE_0002_0005)
        print("[WireFuzz] transcriptFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<Self.iterations {
            let pool = UUID()
            let ts = Int64(bitPattern: rng.next())
            let nonce = rng.bytes(Int.random(in: 0...96, using: &rng))
            let host = RelayTranscripts.hostAuth(poolID: pool, timestamp: ts, serverNonce: nonce)
            #expect(host.count == 21 + 16 + 8 + nonce.count)
            let join = RelayTranscripts.joinProofMessage(poolID: pool, timestamp: ts, nonce: nonce)
            #expect(join.count == 4 + 16 + 8 + nonce.count)
            let rejoin = WebSocketTransport.memberRejoinTranscript(poolID: pool, timestamp: ts, nonce: nonce)
            #expect(rejoin.count == 25 + 16 + 8 + nonce.count)
            _ = RelayTranscripts.joinProof(tokenSecret: rng.bytes(Int.random(in: 0...64, using: &rng)),
                                           tokenID: rng.bytes(Int.random(in: 0...32, using: &rng)),
                                           poolID: pool, timestamp: ts, nonce: nonce)
        }
    }
}
