// GoldenV1ProductionTests.swift
// ConnectionPoolTests
//
// The frozen v1 wire vectors (copies of StealthOS/Fixtures/golden) verified through the
// PRODUCTION code paths that used to be private inside WebSocketTransport.

import Foundation
import CryptoKit
import Testing
@testable import ConnectionPool

@Suite("Golden v1 vectors through production code")
struct GoldenV1ProductionTests {

    static let copiedFixtures = ["relay_transcripts.json", "relay_envelope_hmac.json", "ws_outer_layer.json"]

    @Test("Fixture copies are byte-identical to StealthOS/Fixtures/golden", arguments: copiedFixtures)
    func fixtureCopiesMatchMainRepository(_ file: String) throws {
        let local = try Golden.data(file)
        #expect(!local.isEmpty)
        guard let main = Golden.mainRepositoryDirectory else { return } // standalone checkout
        let upstream = try Data(contentsOf: main.appendingPathComponent(file))
        #expect(local == upstream, "\(file) drifted from the frozen StealthOS copy")
    }

    @Test("The v1 vector files are present and non-empty")
    func inventory() {
        #expect(Golden.vectors("ws_outer_layer.json").count == 10)
        #expect(Golden.vectors("relay_transcripts.json").count == 15)
        #expect(Golden.vectors("relay_envelope_hmac.json").count == 21)
    }

    // MARK: ws_outer_layer.json

    @Test("WS outer-layer key", arguments: Golden.vectors("ws_outer_layer.json", kind: "ws_key"))
    func wsKey(_ v: GoldenVector) throws {
        #expect(try v.inputString("info") == "stealth-ws-encrypt")
        #expect(WSOuterLayer.keyInfo == Data("stealth-ws-encrypt".utf8))
        let key = WSOuterLayer.deriveKey(poolSharedSecret: SymmetricKey(data: try v.inputHex("pool_secret_hex")))
        #expect(keyBytes(key) == (try v.outputHex("ws_key_hex")))
    }

    @Test("WS outer-layer frames open (or fail closed)", arguments: Golden.vectors("ws_outer_layer.json", kind: "ws_frame"))
    func wsFrame(_ v: GoldenVector) throws {
        let key = SymmetricKey(data: try v.inputHex("ws_key_hex"))
        let opened = WSOuterLayer.open(try v.inputHex("blob_hex"), key: key)
        if v.expect == "ok" {
            #expect(opened == (try v.outputHex("plaintext_hex")))
        } else {
            #expect(opened == nil)
        }
    }

    @Test("WS outer-layer seal is the AES-GCM combined format the vectors describe")
    func wsSealRoundTrip() throws {
        let v = try Golden.vector("ws_outer_layer.json", named: "frame_json")
        let key = SymmetricKey(data: try v.inputHex("ws_key_hex"))
        let plaintext = try v.outputHex("plaintext_hex")
        let sealed = try WSOuterLayer.seal(plaintext, key: key)
        #expect(sealed.count == 12 + plaintext.count + 16)
        #expect(WSOuterLayer.open(sealed, key: key) == plaintext)
        let second = try WSOuterLayer.seal(plaintext, key: key)
        #expect(sealed.prefix(12) != second.prefix(12), "nonces are random per frame")
    }

    // MARK: relay_transcripts.json

    @Test("host_auth transcript", arguments: Golden.vectors("relay_transcripts.json", kind: "host_auth"))
    func hostAuth(_ v: GoldenVector) throws {
        let nonce = try #require(Data(base64Encoded: try v.inputString("server_nonce_b64")))
        #expect(nonce == (try v.inputHex("server_nonce_hex")))
        let transcript = RelayTranscripts.hostAuth(
            poolID: try v.inputUUID("pool_id"), timestamp: Int64(try v.inputInt("timestamp")), serverNonce: nonce
        )
        #expect(transcript == (try v.outputHex("transcript_hex")))
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: try v.inputHex("ed25519_private_hex"))
        #expect(signing.publicKey.rawRepresentation == (try v.outputHex("ed25519_public_hex")))
        #expect(signing.publicKey.isValidSignature(try v.outputHex("signature_hex"), for: transcript))
    }

    @Test("member_rejoin transcript", arguments: Golden.vectors("relay_transcripts.json", kind: "member_rejoin"))
    func memberRejoin(_ v: GoldenVector) throws {
        let transcript = WebSocketTransport.memberRejoinTranscript(
            poolID: try v.inputUUID("pool_id"), timestamp: Int64(try v.inputInt("timestamp")), nonce: try v.inputHex("nonce_hex")
        )
        #expect(transcript == (try v.outputHex("transcript_hex")))
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: try v.outputHex("ed25519_public_hex"))
        #expect(pub.isValidSignature(try v.outputHex("signature_hex"), for: transcript))
    }

    @Test("Invitation join proof", arguments: Golden.vectors("relay_transcripts.json", kind: "invite_join_proof"))
    func joinProof(_ v: GoldenVector) throws {
        let poolID = try v.inputUUID("pool_id")
        let tokenID = try v.inputHex("token_id_hex")
        let secret = try v.inputHex("token_secret_hex")
        let timestamp = Int64(try v.inputInt("timestamp"))
        let nonce = try v.inputHex("nonce_hex")
        #expect(RelayTranscripts.uuidBytes(poolID) == (try v.outputHex("hkdf_salt_hex")))
        #expect(RelayTranscripts.inviteInfoLabel + tokenID == (try v.outputHex("hkdf_info_hex")))
        let vk = RelayTranscripts.inviteVerificationKey(tokenSecret: secret, poolID: poolID, tokenID: tokenID)
        #expect(keyBytes(vk) == (try v.outputHex("verification_key_hex")))
        #expect(RelayTranscripts.joinProofMessage(poolID: poolID, timestamp: timestamp, nonce: nonce) == (try v.outputHex("message_hex")))
        let proof = RelayTranscripts.joinProof(tokenSecret: secret, tokenID: tokenID, poolID: poolID, timestamp: timestamp, nonce: nonce)
        #expect(proof == (try v.outputHex("proof_hex")))
        #expect(proof.base64EncodedString() == (try v.outputString("proof_b64")))
    }

    @Test("PoW solutions from the production solver", arguments: Golden.vectors("relay_transcripts.json", kind: "pow").filter { $0.expect == "ok" })
    func pow(_ v: GoldenVector) throws {
        let challenge = try v.inputHex("challenge_hex")
        #expect(Data(base64Encoded: try v.inputString("challenge_b64")) == challenge)
        let difficulty = UInt8(try v.inputInt("difficulty"))
        let solution = try ProofOfWork.solve(
            challenge: challenge, difficulty: difficulty, deadline: .now.advanced(by: .seconds(60)), isCancelled: { false }
        )
        #expect(Data(solution) == (try v.outputHex("solution_hex")))
        #expect(Data(solution).base64EncodedString() == (try v.outputString("solution_b64")))
        let hash = ProofOfWork.hash(challenge: challenge, solution: solution)
        #expect(hash == (try v.outputHex("hash_hex")))
        #expect(Int(ProofOfWork.leadingZeroBits(hash)) == (try v.outputInt("leading_zero_bits")))
    }

    @Test("An insufficient PoW solution does not meet the difficulty")
    func powInsufficient() throws {
        let v = try Golden.vector("relay_transcripts.json", named: "pow_insufficient")
        let hash = ProofOfWork.hash(challenge: try v.inputHex("challenge_hex"), solution: Array(try v.inputHex("solution_hex")))
        let bits = ProofOfWork.leadingZeroBits(hash)
        #expect(Int(bits) == (try v.outputInt("leading_zero_bits")))
        #expect(bits < UInt32(try v.inputInt("difficulty")))
    }

    @Test("The relay's 428 challenge message parses through production")
    func powChallengeMessage() throws {
        let v = try Golden.vector("relay_transcripts.json", named: "pow_challenge_message")
        let challenge = try ProofOfWork.parse(message: try v.inputString("message")).get()
        #expect(challenge.bytes == (try v.outputHex("challenge_hex")))
        #expect(Int(challenge.difficulty) == (try v.outputInt("difficulty")))
    }

    // MARK: relay_envelope_hmac.json (v1 bytes unchanged)

    @Test("v1 envelope HMAC key")
    func envelopeKey() throws {
        let v = try Golden.vector("relay_envelope_hmac.json", named: "hmac_key")
        let key = RelayEnvelope.deriveHMACKey(from: SymmetricKey(data: try v.inputHex("shared_secret_hex")), poolID: try v.inputUUID("pool_id"))
        #expect(keyBytes(key) == (try v.outputHex("hmac_key_hex")))
    }

    @Test("v1 envelope MAC bytes unchanged", arguments: Golden.vectors("relay_envelope_hmac.json", kind: "envelope"))
    func envelopeV1(_ v: GoldenVector) throws {
        let key = RelayEnvelope.deriveHMACKey(from: SymmetricKey(data: try v.inputHex("shared_secret_hex")), poolID: try v.inputUUID("receiver_pool_id"))
        let decoded = try #require(RelayEnvelope.decode(from: Data(try v.outputString("envelope_json").utf8)))
        #expect(!decoded.claimsV2, "a 1.4.x envelope carries no v2 fields")
        #expect(decoded.verifyHMAC(using: key))
        #expect(decoded.computeHMAC(using: key) == (try v.outputHex("hmac_hex")))
        // A 1.5.0 origin still emits the same v1 tag next to the v2 tag.
        let dual = decoded.withDualHMAC(v1Key: key, v2Key: RelayEnvelope.deriveHMACKeyV2(from: SymmetricKey(data: try v.inputHex("shared_secret_hex")), poolID: decoded.poolID))
        #expect(dual.envelopeHMAC == (try v.outputHex("hmac_hex")))
        // And re-encoding a v1 envelope adds no keys (1.4.x JSON shape preserved).
        let json = try #require(decoded.encode())
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["envelopeVersion"] == nil && object["originTTL"] == nil && object["envelopeHMACV2"] == nil)
    }

    @Test("v1 tamper vectors keep their frozen v1 verdicts", arguments: Golden.vectors("relay_envelope_hmac.json", kind: "envelope_tamper"))
    func envelopeV1Tamper(_ v: GoldenVector) throws {
        let key = RelayEnvelope.deriveHMACKey(from: SymmetricKey(data: try v.inputHex("shared_secret_hex")), poolID: try v.inputUUID("receiver_pool_id"))
        let decoded = try #require(RelayEnvelope.decode(from: Data(try v.inputString("envelope_json").utf8)))
        #expect(decoded.verifyHMAC(using: key) == (try v.outputBool("verifies")))
    }

    @Test("v1-only tamper that v1 cannot see is refused once the origin is pinned to v2",
          arguments: ["swap_payload", "destination_nil_to_empty", "swap_ttl_and_hops"])
    func v1BlindSpotsClosedByPinning(_ name: String) throws {
        let v = try Golden.vector("relay_envelope_hmac.json", named: name)
        let secret = SymmetricKey(data: try v.inputHex("shared_secret_hex"))
        let pool = try v.inputUUID("receiver_pool_id")
        let decoded = try #require(RelayEnvelope.decode(from: Data(try v.inputString("envelope_json").utf8)))
        let ledger = PeerProtocolLedger()
        ledger.observe(peerID: decoded.originPeerID, feature: .relayEnvelope, advertisedVersions: [1, 2])
        let now = decoded.timestamp.addingTimeInterval(1)
        #expect(decoded.verify(sharedSecret: secret, receiverPoolID: pool, ledger: ledger, now: now) == .rejectedDowngrade)
    }
}
