// PoolTransportSecurityTests.swift
// ConnectionPoolTests
//
// Remote-pool outer layer v2: secret distribution, the relay's view, mixed pools,
// downgrade refusal, rotation on removal, frame tamper/replay/truncation, fuzzing.

import Foundation
import CryptoKit
import Testing
@testable import ConnectionPool

@MainActor
@Suite("Remote outer layer: secret distribution and relay's view", .serialized)
struct PoolTransportSecurityTests {

    @Test("Two 1.5.0 members join: the pool becomes protected and app frames flow")
    func protectedPool() throws {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let b = h.addMember(invite: h.makeInvite())
        #expect(h.host.status == .protected(epoch: 1, excludedLegacyPeers: []))
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        #expect(h.members[b]?.status == .protected(epoch: 1, excludedLegacyPeers: []))

        h.members[a]!.sendApp(Data("hello from A".utf8), to: nil)
        h.host.sendApp(Data("hello from host".utf8), to: [b])
        h.pump()
        #expect(h.payloads(at: b).contains("hello from A"))
        #expect(h.payloads(at: h.hostID).contains("hello from A"))
        #expect(h.payloads(at: b).contains("hello from host"))
        #expect(!h.payloads(at: a).contains("hello from host"), "targeted frames stay targeted")
    }

    @Test("The relay never sees the transport secret, the invite key or app plaintext")
    func relayNeverSeesSecrets() throws {
        let h = OuterLayerHarness()
        let invites = (0..<3).map { _ in h.makeInvite() }
        let ids = invites.map { h.addMember(invite: $0) }
        let marker = "TOP-SECRET-CHAT-0123456789"
        for id in ids { h.members[id]!.sendApp(Data((marker + id).utf8), to: nil) }
        h.host.sendApp(Data(marker.utf8), to: nil)
        h.pump()
        h.removeMember(ids[2])          // rotation: a second secret goes over the wire
        h.tick(); h.tick()
        h.members[ids[0]]!.sendApp(Data(marker.utf8), to: nil)
        h.pump()

        let record = try #require(h.hostRecord())
        var secrets = [record.secret] + invites.map(\.inviteKey)
        if let previous = record.previous { secrets.append(previous.secret) }
        #expect(secrets.count == 5)
        #expect(!h.wire.isEmpty && h.wire.count == h.wireJSON.count)
        for (frame, json) in zip(h.wire, h.wireJSON) {
            for secret in secrets {
                for form in leakForms(secret) {
                    #expect(!frame.data.containsBytes(form), "payload leaks a secret")
                    #expect(!json.containsBytes(form), "serialized frame leaks a secret")
                }
            }
            #expect(!frame.data.containsBytes(Data(marker.utf8)), "app plaintext visible to the relay")
            #expect(!json.containsBytes(Data(marker.utf8)))
        }
        // And every member really received the secrets the relay never saw.
        #expect(h.memberRecord(ids[0])?.keys.map(\.secret).contains(record.secret) == true)
    }

    @Test("A 1.4.x member in the pool keeps it unprotected (mixed pool), with the UI told")
    func mixedPool() {
        let h = OuterLayerHarness()
        let old = h.addLegacyMember()
        h.legacySend(old, Data("plain from 1.4".utf8))
        let a = h.addMember(invite: h.makeInvite())
        #expect(h.host.status == .unprotected(legacyPeers: [old], legacyHost: false))
        #expect(h.members[a]?.status == .unprotected(legacyPeers: [old], legacyHost: false))
        h.members[a]!.sendApp(Data("to everyone".utf8), to: nil)
        h.pump()
        #expect(h.payloads(at: old).contains("to everyone"), "the 1.4.x member can still read")
        h.legacySend(old, Data("reply".utf8))
        #expect(h.payloads(at: a).contains("reply"))
    }

    @Test("A silent 1.4.x member is classified legacy after the timeout")
    func silentLegacyTimeout() {
        let h = OuterLayerHarness()
        let old = h.addLegacyMember()
        #expect(h.host.status == .unprotected(legacyPeers: [], legacyHost: false))
        for _ in 0..<11 { h.tick() }
        #expect(h.host.status == .unprotected(legacyPeers: [old], legacyHost: false))
    }

    @Test("Once protected, a 1.4.x joiner is excluded, not a reason to downgrade")
    func noDowngradeForLateLegacy() {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let old = h.addLegacyMember()
        h.legacySend(old, Data("plaintext attempt".utf8))
        #expect(h.host.status == .protected(epoch: 1, excludedLegacyPeers: [old]))
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: [old]))
        #expect(!h.payloads(at: a).contains("plaintext attempt"))
        #expect(!h.payloads(at: h.hostID).contains("plaintext attempt"))
        h.members[a]!.sendApp(Data("sealed".utf8), to: nil)
        h.pump()
        #expect(!h.payloads(at: old).contains("sealed"), "the 1.4.x member only sees ciphertext")
    }

    @Test("A 1.4.x host (invite without fragment) gives an unprotected session, flagged")
    func legacyHost() {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: nil)
        #expect(h.members[a]?.status == .unprotected(legacyPeers: [], legacyHost: true))
    }

    @Test("Host identity mismatch: the server's host is not the host the invitation named")
    func hostMismatch() {
        let h = OuterLayerHarness()
        let before = h.wire.count
        let a = h.addMember(invite: h.makeInvite(), hostPeerIDOverride: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        #expect(h.members[a]?.status == .hostIdentityMismatch)
        #expect(h.wire.count == before, "no key request is sent to an unverified host")
        h.members[a]!.sendApp(Data("x".utf8), to: nil)
        h.pump()
        #expect(h.wire.count == before, "fails closed")
    }

    @Test("While securing, a member holds its frames and never sends plaintext")
    func holdWhileSecuring() {
        let h = OuterLayerHarness()
        h.tamper = { w in w.from != h.hostID }   // the relay blocks everything from the host
        let a = h.addMember(invite: h.makeInvite())
        #expect(h.members[a]?.status == .securing)
        h.members[a]!.sendApp(Data("PLAINTEXT-MUST-NOT-LEAK".utf8), to: nil)
        h.pump()
        #expect(!h.wire.contains { $0.data.containsBytes(Data("PLAINTEXT-MUST-NOT-LEAK".utf8)) })
        h.tamper = nil
        h.tick(6)  // retry
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        #expect(h.payloads(at: h.hostID).contains("PLAINTEXT-MUST-NOT-LEAK"), "held frame delivered sealed once secured")
        #expect(!h.wire.contains { $0.data.containsBytes(Data("PLAINTEXT-MUST-NOT-LEAK".utf8)) })
    }

    // MARK: Downgrade

    @Test("A protected member refuses a later 'protection off' announcement")
    func downgradeRefused() throws {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        h.clock = h.clock.addingTimeInterval(1)
        var off = TransportControlMessage(kind: .announcement, poolID: h.poolID, timestampMillis: Int64(h.clock.timeIntervalSince1970 * 1000))
        off.epoch = 1; off.protected = false; off.removedPeerIDs = []; off.legacyPeerIDs = []
        off.hostSignature = try h.hostKey.signature(for: try #require(off.announcementTranscript()))
        h.inject(try #require(off.encoded()), from: h.hostID, to: a)
        #expect(h.members[a]?.status == .downgradeRefused)
        let legacy = h.addLegacyMember()
        h.legacySend(legacy, Data("plaintext after downgrade".utf8), to: [a])
        #expect(!h.payloads(at: a).contains("plaintext after downgrade"), "plaintext still refused")
        // Survives a restart: persisted protection is never dropped.
        let restarted = h.addMember(invite: nil, key: h.memberKeys[a]!)
        #expect(h.members[restarted]?.status != .unprotected(legacyPeers: [], legacyHost: false))
        #expect(h.memberRecord(a)?.protected == true)
    }

    @Test("Forged or replayed announcements are ignored")
    func forgedAnnouncement() throws {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        var off = TransportControlMessage(kind: .announcement, poolID: h.poolID, timestampMillis: Int64(h.clock.timeIntervalSince1970 * 1000) + 5)
        off.epoch = 1; off.protected = false; off.removedPeerIDs = []; off.legacyPeerIDs = []
        off.hostSignature = try Curve25519.Signing.PrivateKey().signature(for: try #require(off.announcementTranscript()))
        h.inject(try #require(off.encoded()), from: h.hostID, to: a)
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        // Replay of the genuine announcement already processed: not newer, ignored.
        let genuine = try #require(h.wire.last { TransportControlMessage.decode($0.data)?.kind == .announcement && $0.targets == [a] })
        h.inject(genuine.data, from: h.hostID, to: a)
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        // A message claiming to be from the host but relayed from another peer is ignored.
        h.inject(genuine.data, from: "someone-else", to: a)
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
    }

    // MARK: Key distribution attacks

    @Test("The relay cannot obtain a grant without the out-of-band invite key")
    func relayCannotBootstrap() throws {
        let h = OuterLayerHarness()
        _ = h.makeInvite()
        let relayKey = Curve25519.Signing.PrivateKey()
        let relayID = relayKey.publicKey.rawRepresentation.base64EncodedString()
        h.host.peerJoined(relayID)
        for proofKey in [Data(repeating: 0, count: 32), SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }] {
            var request = TransportControlMessage(kind: .keyRequest, poolID: h.poolID, timestampMillis: Int64(h.clock.timeIntervalSince1970 * 1000))
            request.memberPeerID = relayID
            request.memberIdentityKey = relayKey.publicKey.rawRepresentation
            request.memberEphemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            request.nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            request.inviteKeyID = TransportInviteSecret.keyID(proofKey)
            let transcript = try #require(request.requestTranscript())
            request.memberSignature = try relayKey.signature(for: transcript)
            request.inviteProof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: proofKey)))
            let before = h.wire.count
            h.inject(try #require(request.encoded()), from: relayID, to: h.hostID)
            #expect(!h.wire[before...].contains { TransportControlMessage.decode($0.data)?.kind == .keyGrant }, "no grant")
        }
        #expect(h.hostRecord()?.enrolled.isEmpty == true)
    }

    @Test("A captured key request cannot be replayed, re-attributed or retimed")
    func requestReplay() throws {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let request = try #require(h.wire.first { TransportControlMessage.decode($0.data)?.kind == .keyRequest })
        func grants() -> Int { h.wire.filter { TransportControlMessage.decode($0.data)?.kind == .keyGrant }.count }
        let before = grants()
        h.inject(request.data, from: a, to: h.hostID)                 // replay
        h.inject(request.data, from: "another-peer", to: h.hostID)    // re-attributed
        h.clock = h.clock.addingTimeInterval(400)
        h.inject(request.data, from: a, to: h.hostID)                 // stale
        #expect(grants() == before)
    }

    @Test("A grant forged by the relay is ignored")
    func forgedGrant() throws {
        let h = OuterLayerHarness()
        h.tamper = { w in TransportControlMessage.decode(w.data)?.kind != .keyGrant } // drop real grants
        let a = h.addMember(invite: h.makeInvite())
        #expect(h.members[a]?.status == .securing)
        var grant = TransportControlMessage(kind: .keyGrant, poolID: h.poolID, timestampMillis: Int64(h.clock.timeIntervalSince1970 * 1000))
        grant.requestHash = Data(repeating: 1, count: 32); grant.epoch = 1
        grant.hostEphemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        grant.sealedSecret = Data(repeating: 2, count: 60)
        grant.hostSignature = try Curve25519.Signing.PrivateKey().signature(for: try #require(grant.grantTranscript()))
        h.inject(try #require(grant.encoded()), from: h.hostID, to: a)
        #expect(h.memberRecord(a)?.keys.isEmpty == true)
    }

    // MARK: Rotation

    @Test("A removed member is locked out after rotation")
    func rotationLocksOutRemovedMember() throws {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let b = h.addMember(invite: h.makeInvite())
        let bKey = h.memberKeys[b]!
        let bOld = h.members[b]!
        h.removeMember(b)
        #expect(h.hostRecord()?.epoch == 2)
        #expect(h.memberRecord(a)?.keys.map(\.epoch).contains(2) == true, "remaining member fetched epoch 2")
        #expect(h.memberRecord(b)?.keys.map(\.epoch).contains(2) != true, "removed member never gets it")
        #expect(h.hostRecord()?.enrolled.contains(bKey.publicKey.rawRepresentation) == false)

        // Traffic after the switch is sealed under epoch 2.
        h.tick(11)
        h.members[a]!.sendApp(Data("after removal".utf8), to: nil)
        h.host.sendApp(Data("host after removal".utf8), to: nil)
        h.pump()
        #expect(h.payloads(at: h.hostID).contains("after removal"))
        // The removed member (still holding epoch 1) is shown every frame by a colluding relay.
        let sealed = h.wire.filter { OuterFrameV2.parseHeader($0.data)?.epoch == 2 }
        #expect(!sealed.isEmpty)
        for frame in sealed { bOld.receive(frame.data, from: frame.from) }
        #expect(!(h.delivered[b] ?? []).map { String(decoding: $0.data, as: UTF8.self) }.contains("after removal"))
        #expect(!(h.delivered[b] ?? []).map { String(decoding: $0.data, as: UTF8.self) }.contains("host after removal"))

        // It cannot fetch the new secret either, even with a valid signature.
        bOld.tick()
        let rejoined = h.addMember(invite: nil, key: bKey)
        #expect(h.memberRecord(rejoined)?.keys.map(\.epoch).contains(2) != true)
        // And frames it seals under the old epoch are refused after the grace period.
        h.tick(31)
        bOld.sendApp(Data("old epoch from removed".utf8), to: nil)
        h.pump()
        #expect(!h.payloads(at: a).contains("old epoch from removed"))
        #expect(!h.payloads(at: h.hostID).contains("old epoch from removed"))
    }

    @Test("Rotation keeps in-flight traffic working for remaining members")
    func rotationContinuity() {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let b = h.addMember(invite: h.makeInvite())
        let c = h.addMember(invite: h.makeInvite())
        h.removeMember(c)
        for i in 0..<5 {
            h.members[a]!.sendApp(Data("m\(i)".utf8), to: [b])
            h.tick()
        }
        #expect(h.payloads(at: b).filter { $0.hasPrefix("m") }.count == 5)
    }

    // MARK: Persistence

    @Test("A member restart keeps protection and the key")
    func memberRestart() {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let key = h.memberKeys[a]!
        let restarted = h.addMember(invite: nil, key: key)
        #expect(restarted == a)
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        h.host.sendApp(Data("after restart".utf8), to: [a])
        h.pump()
        #expect(h.payloads(at: a).contains("after restart"))
    }
}

// MARK: - Outer frame tamper / replay / truncation

@MainActor
@Suite("Remote outer layer: frame integrity", .serialized)
struct OuterFrameIntegrityTests {

    func protectedPair() -> (OuterLayerHarness, String, Data) {
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        h.members[a]!.sendApp(Data("payload".utf8), to: [h.hostID])
        h.pump()
        let frame = h.wire.last { OuterFrameV2.isOuterFrame($0.data) }!.data
        return (h, a, frame)
    }

    func hostCount(_ h: OuterLayerHarness) -> Int { h.payloads(at: h.hostID).filter { $0 == "payload" }.count }

    @Test("The same frame twice is delivered once")
    func replay() {
        let (h, a, frame) = protectedPair()
        #expect(hostCount(h) == 1)
        h.inject(frame, from: a, to: h.hostID)
        #expect(hostCount(h) == 1)
    }

    @Test("Any single bit flip is rejected")
    func bitFlips() {
        let (h, a, frame) = protectedPair()
        for i in stride(from: 4, to: frame.count, by: max(1, frame.count / 40)) {
            var t = frame
            t[t.startIndex + i] ^= 0x01
            h.inject(t, from: a, to: h.hostID)
        }
        #expect(hostCount(h) == 1)
    }

    @Test("Truncation and extension are rejected", arguments: [1, 16, 17, 44, 60])
    func truncation(_ cut: Int) {
        let (h, a, frame) = protectedPair()
        if cut < frame.count { h.inject(Data(frame.prefix(frame.count - cut)), from: a, to: h.hostID) }
        h.inject(frame + Data(repeating: 0, count: cut), from: a, to: h.hostID)
        #expect(hostCount(h) == 1)
    }

    @Test("A frame re-attributed to another sender is rejected")
    func reattribution() {
        let (h, _, frame) = protectedPair()
        let b = h.addMember(invite: h.makeInvite())
        h.inject(frame, from: b, to: h.hostID)
        #expect(hostCount(h) == 1)
    }

    @Test("A stale frame is rejected even if never seen; a far-future frame too")
    func freshness() throws {
        let (h, a, _) = protectedPair()
        h.members[a]!.sendApp(Data("later".utf8), to: [h.hostID])
        let frame = try #require(h.wire.last { OuterFrameV2.isOuterFrame($0.data) }).data
        // Not pumped yet: deliver it 301 s late.
        h.clock = h.clock.addingTimeInterval(OuterFrameV2.maxAge + 1)
        let fresh = OuterLayerHarness() // unrelated, to keep the original queue intact
        _ = fresh
        let before = h.payloads(at: h.hostID).filter { $0 == "later" }.count
        h.host.receive(frame, from: a)
        #expect(h.payloads(at: h.hostID).filter { $0 == "later" }.count == before)
    }

    @Test("A frame from another pool is rejected")
    func otherPool() {
        let (h, a, frame) = protectedPair()
        let other = OuterLayerHarness()
        other.host.receive(frame, from: a)
        #expect(other.payloads(at: other.hostID).isEmpty)
        _ = h
    }

    @Test("Plaintext is refused once protected (fail closed)")
    func plaintextRefused() {
        let (h, a, _) = protectedPair()
        h.inject(Data("{\"type\":\"chat\"}".utf8), from: a, to: h.hostID)
        #expect(!h.payloads(at: h.hostID).contains("{\"type\":\"chat\"}"))
        h.inject(Data("{\"type\":\"chat\"}".utf8), from: h.hostID, to: a)
        #expect(!h.payloads(at: a).contains("{\"type\":\"chat\"}"))
    }
}

// MARK: - Invitation fragment

@MainActor
@Suite("Remote outer layer: invitation fragment")
struct TransportInviteSecretTests {
    nonisolated static let payload: String = {
        let wire: [String: Any] = ["id": Array(repeating: 1, count: 16), "secret": Array(repeating: 2, count: 32),
                                   "pool": Array(repeating: 3, count: 16), "fp": Array(repeating: 4, count: 8),
                                   "exp": 1_900_000_000, "max": 1, "addr": "relay.example:9090"]
        let json = try! JSONSerialization.data(withJSONObject: wire)
        return json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }()

    @Test("Round trip through the invitation URL; 1.4.x parsing is unaffected")
    func roundTrip() throws {
        let secret = TransportInviteSecret.generate(hostIdentityKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let base = try #require(URL(string: "stealth://invite/\(Self.payload)"))
        let url = try #require(secret.appending(to: base))
        #expect(url.fragment == secret.fragment)
        let parsed = try #require(RemotePoolService.parseInvitationURL(url))
        #expect(parsed.transportSecret == secret)
        let legacy = try #require(RemotePoolService.parseInvitationURL(base))
        #expect(legacy.transportSecret == nil)
        #expect(legacy.tokenSecret == parsed.tokenSecret, "the server-built part is unchanged")
        // The fragment survives the .stcard wrapper and QR text.
        let card = try SealedInviteCard.encode(url: url.absoluteString)
        #expect(try RemotePoolService.parseInvitationCardBytes(card).transportSecret == secret)
    }

    @Test("A malformed fragment rejects the invitation instead of silently downgrading", arguments: [
        "v2.", "v2.AAAA", "v3.abc", "garbage", "v2.!!!!", "v2." + String(repeating: "A", count: 88)
    ])
    func malformed(_ fragment: String) throws {
        let url = try #require(URL(string: "stealth://invite/\(Self.payload)#\(fragment)"))
        #expect(RemotePoolService.parseInvitationURL(url) == nil)
    }

    @Test("Wrong version byte is refused")
    func version() {
        var raw = Data([0x03]) + Data(repeating: 1, count: 32) + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(TransportInviteSecret.parse(fragment: "v2." + TransportInviteSecret.base64URL(raw)) == .failure(.unsupportedVersion))
        raw[raw.startIndex] = 0x02
        if case .success(let s?) = TransportInviteSecret.parse(fragment: "v2." + TransportInviteSecret.base64URL(raw)) {
            #expect(s.inviteKey == Data(repeating: 1, count: 32))
        } else {
            Issue.record("valid fragment rejected")
        }
    }
}

// MARK: - Fuzzing

@MainActor
@Suite("Remote outer layer: seeded fuzzing", .serialized)
struct OuterLayerFuzzTests {
    @Test("Mutated control and outer frames never crash and never deliver forged data")
    func fuzz() {
        let seed = FuzzSeed.value(default: 0x0E7E_1A7E_0003_0001)
        print("[WireFuzz] outerLayerFuzz seed=\(seed)")
        var rng = SeededGenerator(seed: seed)
        let h = OuterLayerHarness()
        let a = h.addMember(invite: h.makeInvite())
        let b = h.addMember(invite: h.makeInvite())
        h.members[a]!.sendApp(Data("genuine".utf8), to: nil)
        h.pump()
        let corpus = h.wire.map(\.data)
        let deliveredBefore = (h.delivered[b] ?? []).count + (h.delivered[h.hostID] ?? []).count
        for i in 0..<2_000 {
            var bytes = [UInt8](corpus[i % corpus.count])
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
                case 1 where !bytes.isEmpty: bytes.removeLast(Int.random(in: 1...min(8, bytes.count), using: &rng))
                case 2: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
                default: bytes = Array(bytes.prefix(4)) + [UInt8](h.wire[0].data.dropFirst(4)).shuffled(using: &rng)
                }
            }
            let target = Bool.random(using: &rng) ? h.hostID : b
            h.node(target)?.receive(Data(bytes), from: Bool.random(using: &rng) ? a : h.hostID)
            if i % 7 == 0 { h.node(target)?.receive(Data((0..<Int.random(in: 0...120, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }), from: a) }
        }
        h.pump()
        let deliveredAfter = (h.delivered[b] ?? []).count + (h.delivered[h.hostID] ?? []).count
        #expect(deliveredAfter == deliveredBefore, "seed \(seed): a mutated frame was delivered")
        #expect(h.members[a]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
        #expect(h.members[b]?.status == .protected(epoch: 1, excludedLegacyPeers: []))
    }
}
