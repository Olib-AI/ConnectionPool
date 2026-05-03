// MemberRejoinTranscriptTests.swift
// ConnectionPoolTests
//
// Verifies the byte-exact transcript layout that both the Rust relay and the
// iOS client sign / verify for the `member_rejoin` flow. Any drift between
// these tests and the Rust implementation breaks auto-rejoin silently.

import XCTest
import CryptoKit
@testable import ConnectionPool

final class MemberRejoinTranscriptTests: XCTestCase {

    // MARK: - Fixed vectors

    /// Hand-built reference transcript using fully deterministic inputs so the
    /// Rust agent can mirror the exact same bytes.
    func testTranscriptLayoutMatchesWireContract() {
        // Pool: 11111111-2222-3333-4444-555555555555 → 16 raw bytes
        let poolUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let poolBytes: [UInt8] = [
            0x11, 0x11, 0x11, 0x11,
            0x22, 0x22,
            0x33, 0x33,
            0x44, 0x44,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        ]

        // Timestamp: 1_714_752_345 = 0x0000_0000_6635_0B59 → big-endian 8 bytes
        let timestamp: Int64 = 1_714_752_345
        let timestampBE: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x66, 0x35, 0x0B, 0x59]

        // Nonce: deterministic 0x00…0x1F (32 bytes)
        let nonce = Data((0..<32).map { UInt8($0) })

        let transcript = WebSocketTransport.memberRejoinTranscript(
            poolID: poolUUID,
            timestamp: timestamp,
            nonce: nonce
        )

        let expectedPrefix = Data("STEALTH_MEMBER_REJOIN_V1:".utf8)
        var expected = expectedPrefix
        expected.append(contentsOf: poolBytes)
        expected.append(contentsOf: timestampBE)
        expected.append(nonce)

        XCTAssertEqual(transcript, expected, """
        Transcript layout drifted from the wire contract.
          expected: \(expected.map { String(format: "%02x", $0) }.joined())
          actual:   \(transcript.map { String(format: "%02x", $0) }.joined())
        """)
    }

    func testTranscriptLengthIs81Bytes() {
        // The domain separator `"STEALTH_MEMBER_REJOIN_V1:"` is exactly 25
        // bytes (24 alphanumerics + the trailing colon). Total transcript:
        // 25 (separator) + 16 (uuid) + 8 (timestamp) + 32 (nonce) = 81 bytes.
        let separator = Data("STEALTH_MEMBER_REJOIN_V1:".utf8)
        XCTAssertEqual(separator.count, 25, "domain separator must be exactly 25 bytes including the trailing colon")

        let transcript = WebSocketTransport.memberRejoinTranscript(
            poolID: UUID(),
            timestamp: 0,
            nonce: Data(count: 32)
        )
        XCTAssertEqual(transcript.count, 81, "expected 25+16+8+32 = 81 bytes; got \(transcript.count)")
    }

    func testDomainSeparatorIsDistinctFromHostAuth() {
        // The `member_rejoin` and `host_auth` separators MUST differ so a
        // signature from one path cannot satisfy verification of the other.
        let memberSep = "STEALTH_MEMBER_REJOIN_V1:"
        let hostSep = "STEALTH_HOST_AUTH_V1:"
        XCTAssertNotEqual(memberSep, hostSep)

        let transcript = WebSocketTransport.memberRejoinTranscript(
            poolID: UUID(),
            timestamp: 0,
            nonce: Data(count: 32)
        )
        let asString = String(data: transcript.prefix(memberSep.count), encoding: .utf8)
        XCTAssertEqual(asString, memberSep)
    }

    // MARK: - End-to-end sign/verify

    func testTranscriptSignAndVerifyRoundTrip() throws {
        let server = "wss://transcript-test.example/\(UUID().uuidString)"
        let pool = UUID()
        defer { try? RemoteMemberIdentity.delete(serverURL: server, poolID: pool.uuidString) }

        let identity = try RemoteMemberIdentity.loadOrCreate(serverURL: server, poolID: pool.uuidString)
        let timestamp = Int64(Date().timeIntervalSince1970)
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let transcript = WebSocketTransport.memberRejoinTranscript(
            poolID: pool,
            timestamp: timestamp,
            nonce: nonce
        )
        let signature = try identity.sign(transcript: transcript)

        XCTAssertTrue(
            identity.publicKey.isValidSignature(signature, for: transcript),
            "signature produced over the transcript must validate against the same public key"
        )

        // Tampered transcript (flip one nonce byte) must NOT verify.
        var tampered = transcript
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertFalse(
            identity.publicKey.isValidSignature(signature, for: tampered),
            "signature must NOT validate against a tampered transcript"
        )
    }
}
