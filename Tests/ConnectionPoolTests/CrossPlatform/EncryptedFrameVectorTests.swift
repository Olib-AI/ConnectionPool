// EncryptedFrameVectorTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Vector 02: encrypted-frame layout + AEAD round-trip for tags
// {0x01, 0x03, 0x04, 0x05} keyed under the K_c2s / K_s2c derived from
// vector 00. Byte-equal assertion on `frame_hex` (full on-wire frame
// including length prefix) for PING(c2s,c0), PONG(s2c,c0),
// ENCRYPTED_POOL_MESSAGE(s2c,c1, tiny "{\"hello\":\"world\"}" plaintext),
// and BYE-with-reason(s2c,c2).

import XCTest
@testable import ConnectionPool

final class EncryptedFrameVectorTests: XCTestCase {

    func test_encrypted_frame_vectors() throws {
        let json = try VectorLoader.parse("02-encrypted-frame.json")
        guard let keys = json["keys"] as? [String: Any],
              let frames = json["frames"] as? [String: Any] else {
            XCTFail("vector 02 schema mismatch"); return
        }
        let kC2s = try CrossPlatformHexCodecs.decode(keys["K_c2s_hex"] as! String)
        let kS2c = try CrossPlatformHexCodecs.decode(keys["K_s2c_hex"] as! String)

        for (name, value) in frames {
            guard let entry = value as? [String: Any] else {
                XCTFail("frame \(name) is not an object"); continue
            }
            let typeRaw = entry["frame_type"] as! Int
            let counter = entry["counter"] as! Int
            let plaintextB64 = entry["plaintext_b64"] as! String
            let expectedFrameHex = entry["frame_hex"] as! String

            // Decode the plaintext: empty string for PING/PONG, the b64 of
            // `"{\"hello\":\"world\"}"` / `"goodbye"` for the others.
            let plaintext = plaintextB64.isEmpty
                ? Data()
                : (CrossPlatformBase64.decodeStd(plaintextB64) ?? Data())

            // Pick the key by direction (c2s for ping, s2c for the rest).
            let directionKey: Data
            switch name {
            case "ping_c2s_counter0": directionKey = kC2s
            default:                  directionKey = kS2c
            }

            guard let type = CrossPlatformFrameType(rawValue: UInt8(typeRaw)) else {
                XCTFail("unknown frame type \(typeRaw)"); continue
            }
            let body = try CrossPlatformFrameCodec.encryptedBody(
                type: type,
                key: directionKey,
                counter: UInt64(counter),
                plaintext: plaintext
            )
            let frame = CrossPlatformFrameCodec.frameOf(body: body)
            XCTAssertEqual(
                CrossPlatformHexCodecs.encode(frame),
                expectedFrameHex,
                "frame \(name) byte mismatch"
            )
        }
    }

    func test_decryptRoundTrip() throws {
        // Decrypt-side sanity for the s2c counter=1 PoolMessage frame.
        let json = try VectorLoader.parse("02-encrypted-frame.json")
        guard let frames = json["frames"] as? [String: Any],
              let entry = frames["encrypted_pool_message_s2c_counter1_small"] as? [String: Any],
              let keys = json["keys"] as? [String: Any] else {
            XCTFail("vector 02 schema mismatch"); return
        }
        let kS2c = try CrossPlatformHexCodecs.decode(keys["K_s2c_hex"] as! String)
        let bodyHex = entry["body_hex"] as! String
        let body = try CrossPlatformHexCodecs.decode(bodyHex)
        // Bypass strict-monotonic via two fresh counters; in production the
        // session's CounterTracker takes care of this. For this test we want
        // to assert that counter=1 (the vector's pinned value) decrypts
        // cleanly when nothing has been seen yet — strict-monotonic would
        // reject only `counter <= lastSeen` with lastSeen=-1, so counter=1
        // passes.
        let tracker = CounterTracker()
        let plaintext = try CrossPlatformFrameCodec.decryptBody(body: body, key: kS2c, tracker: tracker)
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), "{\"hello\":\"world\"}")
        XCTAssertEqual(tracker.snapshot(), 1, "tracker should have advanced to 1")
    }
}
