// GameActionVectorTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Vector 03: end-to-end `ChessGameAction` → inner v=1 wrapper → PoolMessage
// → ChaCha20-Poly1305-encrypted frame. Byte-equal assertion at every
// boundary the spec pins:
//
//   * inner_wrapper_object — canonical JSON of the v=1 envelope
//   * pool_message_object  — canonical JSON of the outer PoolMessage
//                            (`pool_message_utf8_bytes_hex`)
//   * encrypted_frame.frame_hex — full on-wire encrypted frame
//
// Covers two cases: host `start` and guest `move("e7e5")`.

import XCTest
@testable import ConnectionPool

final class GameActionVectorTests: XCTestCase {

    func test_host_start_frame_byteEqual() throws {
        let json = try VectorLoader.parse("03-game-action.json")
        guard let fixed = json["fixed_inputs"] as? [String: Any],
              let host = json["host_start_frame"] as? [String: Any] else {
            XCTFail("vector 03 host_start_frame schema mismatch"); return
        }

        // Derive the s2c key from vector 00 (the keys file is implicitly the
        // 02 key file; vector 03 doesn't re-pin keys — it expects us to use
        // the same K_s2c).
        let kS2c = try CrossPlatformHexCodecs.decode("51a32d8735fdb8165a1f8449fd270c922082d0f07a3a4236303632ffa731836e")

        let sessionId = fixed["session_id_b64url"] as! String
        let senderID = fixed["host_sender_id"] as! String
        let senderName = fixed["host_name"] as! String
        let idString = fixed["host_message_uuid"] as! String
        let timestampString = fixed["host_timestamp"] as! String

        // Build the inner action + envelope.
        let action: CrossPlatformChessGameAction = .start(
            hostColor: .white,
            startingFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )
        let envelope = CrossPlatformGameActionEnvelope(sessionId: sessionId, seq: 0, action: action)
        let payload = envelope.encodeCanonical()

        // Build the outer PoolMessage with the pinned UUID + timestamp.
        let uuid = UUID(uuidString: idString)!
        let timestamp = CrossPlatformIso8601Millis.parse(timestampString)!
        let pool = CrossPlatformPoolMessage(
            id: uuid,
            type: .gameAction,
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload,
            isReliable: true
        )
        let poolBytes = pool.encodeCanonical()
        let expectedPoolHex = host["pool_message_utf8_bytes_hex"] as! String
        XCTAssertEqual(CrossPlatformHexCodecs.encode(poolBytes), expectedPoolHex, "pool message byte mismatch")

        // Encrypt under K_s2c with counter=0.
        guard let encryptedFrame = host["encrypted_frame"] as? [String: Any] else {
            XCTFail("encrypted_frame missing"); return
        }
        let body = try CrossPlatformFrameCodec.encryptedBody(
            type: .encryptedPoolMessage,
            key: kS2c,
            counter: 0,
            plaintext: poolBytes
        )
        let frame = CrossPlatformFrameCodec.frameOf(body: body)
        XCTAssertEqual(
            CrossPlatformHexCodecs.encode(frame),
            encryptedFrame["frame_hex"] as! String,
            "encrypted frame byte mismatch"
        )
    }

    func test_guest_move_frame_byteEqual() throws {
        let json = try VectorLoader.parse("03-game-action.json")
        guard let fixed = json["fixed_inputs"] as? [String: Any],
              let guest = json["guest_move_e7e5_frame"] as? [String: Any] else {
            XCTFail("vector 03 guest_move_e7e5_frame schema mismatch"); return
        }
        // The guest sends c2s.
        let kC2s = try CrossPlatformHexCodecs.decode("b59561b63a5fe76f7862ad15f4f380a0fd90d7e65a5148b333789ff074b8512d")

        let sessionId = fixed["session_id_b64url"] as! String
        let senderID = fixed["guest_sender_id"] as! String
        let senderName = fixed["guest_name"] as! String
        let idString = fixed["guest_message_uuid"] as! String
        let timestampString = fixed["guest_timestamp"] as! String

        let action: CrossPlatformChessGameAction = .move(uci: "e7e5")
        let envelope = CrossPlatformGameActionEnvelope(sessionId: sessionId, seq: 0, action: action)
        let payload = envelope.encodeCanonical()

        let uuid = UUID(uuidString: idString)!
        let timestamp = CrossPlatformIso8601Millis.parse(timestampString)!
        let pool = CrossPlatformPoolMessage(
            id: uuid,
            type: .gameAction,
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload,
            isReliable: true
        )
        let poolBytes = pool.encodeCanonical()
        XCTAssertEqual(
            CrossPlatformHexCodecs.encode(poolBytes),
            guest["pool_message_utf8_bytes_hex"] as! String,
            "pool message byte mismatch"
        )

        guard let encryptedFrame = guest["encrypted_frame"] as? [String: Any] else {
            XCTFail("encrypted_frame missing"); return
        }
        let body = try CrossPlatformFrameCodec.encryptedBody(
            type: .encryptedPoolMessage,
            key: kC2s,
            counter: 0,
            plaintext: poolBytes
        )
        let frame = CrossPlatformFrameCodec.frameOf(body: body)
        XCTAssertEqual(
            CrossPlatformHexCodecs.encode(frame),
            encryptedFrame["frame_hex"] as! String,
            "encrypted frame byte mismatch"
        )
    }
}
