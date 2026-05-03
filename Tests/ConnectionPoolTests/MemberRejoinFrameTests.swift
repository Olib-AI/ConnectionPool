// MemberRejoinFrameTests.swift
// ConnectionPoolTests
//
// Wire-contract tests for the relay v0.5.0+ `member_rejoin` frame. The Rust
// relay agent must produce JSON that decodes into the exact same Swift values
// asserted here — any deviation between the two sides is a wire-contract
// break and the auto-rejoin flow stops working.

import XCTest
@testable import ConnectionPool

final class MemberRejoinFrameTests: XCTestCase {

    // MARK: - Round-trip

    func testMemberRejoinRoundTrip() throws {
        let payload = MemberRejoinData(
            poolId: "11111111-1111-1111-1111-111111111111",
            clientPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            timestamp: 1714752345,
            nonce: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",
            signature: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=",
            displayName: "Maya"
        )
        let frame: ServerFrame = .memberRejoin(payload)
        let data = try frame.toJSON()
        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
    }

    // MARK: - Wire field names

    func testMemberRejoinJSONUsesSnakeCaseFieldNames() throws {
        let payload = MemberRejoinData(
            poolId: "11111111-1111-1111-1111-111111111111",
            clientPublicKey: "ZmFrZS1wdWJsaWMta2V5",
            timestamp: 1714752345,
            nonce: "ZmFrZS1ub25jZQ==",
            signature: "ZmFrZS1zaWc=",
            displayName: "Maya"
        )
        let data = try ServerFrame.memberRejoin(payload).toJSON()
        let json = String(decoding: data, as: UTF8.self)

        // Frame discriminator
        XCTAssertTrue(json.contains("\"frame_type\":\"member_rejoin\""),
                      "frame_type must be `member_rejoin` (snake_case): \(json)")

        // All payload fields
        XCTAssertTrue(json.contains("\"pool_id\":\"11111111-1111-1111-1111-111111111111\""), json)
        XCTAssertTrue(json.contains("\"client_public_key\":\"ZmFrZS1wdWJsaWMta2V5\""), json)
        XCTAssertTrue(json.contains("\"timestamp\":1714752345"), json)
        XCTAssertTrue(json.contains("\"nonce\":\"ZmFrZS1ub25jZQ==\""), json)
        XCTAssertTrue(json.contains("\"signature\":\"ZmFrZS1zaWc=\""), json)
        XCTAssertTrue(json.contains("\"display_name\":\"Maya\""), json)

        // Verify camelCase variants are NOT present.
        XCTAssertFalse(json.contains("poolId"), "must use snake_case, not camelCase: \(json)")
        XCTAssertFalse(json.contains("clientPublicKey"), json)
        XCTAssertFalse(json.contains("displayName"), json)
    }

    // MARK: - Decode from Rust wire format

    func testMemberRejoinDecodesFromRustWireFormat() throws {
        // Verbatim JSON the Rust relay agent will accept (per the wire contract).
        let wire = """
        {
          "frame_type": "member_rejoin",
          "data": {
            "pool_id": "55555555-5555-5555-5555-555555555555",
            "client_public_key": "Y2xpZW50LXB1Yi1rZXk=",
            "timestamp": 1714752345,
            "nonce": "bm9uY2UtZGF0YQ==",
            "signature": "c2lnbmF0dXJlLWRhdGE=",
            "display_name": "Maya"
          }
        }
        """
        let frame = try ServerFrame.fromJSON(wire.data(using: .utf8)!)
        guard case .memberRejoin(let payload) = frame else {
            return XCTFail("expected .memberRejoin, got \(frame)")
        }
        XCTAssertEqual(payload.poolId, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(payload.clientPublicKey, "Y2xpZW50LXB1Yi1rZXk=")
        XCTAssertEqual(payload.timestamp, 1714752345)
        XCTAssertEqual(payload.nonce, "bm9uY2UtZGF0YQ==")
        XCTAssertEqual(payload.signature, "c2lnbmF0dXJlLWRhdGE=")
        XCTAssertEqual(payload.displayName, "Maya")
    }

    // MARK: - FrameType discriminator equality

    func testHostAuthAndMemberRejoinHaveDistinctFrameTypes() throws {
        // Both frames carry similar fields; the discriminator MUST differ so
        // the relay routes them to different handlers and a host_auth signature
        // can never satisfy a member_rejoin verification.
        let host = ServerFrame.hostAuth(HostAuthData(
            hostPublicKey: "h",
            timestamp: 1,
            signature: "s",
            poolId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            nonce: "n"
        ))
        let member = ServerFrame.memberRejoin(MemberRejoinData(
            poolId: "11111111-1111-1111-1111-111111111111",
            clientPublicKey: "k",
            timestamp: 1,
            nonce: "n",
            signature: "s",
            displayName: "M"
        ))
        let hostJSON = String(decoding: try host.toJSON(), as: UTF8.self)
        let memberJSON = String(decoding: try member.toJSON(), as: UTF8.self)
        XCTAssertTrue(hostJSON.contains("\"frame_type\":\"host_auth\""))
        XCTAssertTrue(memberJSON.contains("\"frame_type\":\"member_rejoin\""))
        XCTAssertFalse(hostJSON.contains("member_rejoin"))
        XCTAssertFalse(memberJSON.contains("host_auth"))
    }
}
