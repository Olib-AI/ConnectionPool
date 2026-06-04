// HkdfVectorTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Vector 00: HKDF-SHA256 round-trip. Asserts byte-equal K_master, K_c2s,
// K_s2c for the pinned `tap_code` + nonces from `docs/vectors/00-hkdf.json`.

import XCTest
@testable import ConnectionPool

final class HkdfVectorTests: XCTestCase {

    func test_hkdf_vector_byteEqual() throws {
        let json = try VectorLoader.parse("00-hkdf.json")
        guard let inputs = json["inputs"] as? [String: Any],
              let expected = json["expected"] as? [String: Any] else {
            XCTFail("vector 00 schema mismatch")
            return
        }
        let tapCode = inputs["tap_code"] as! String
        let nonceC = try CrossPlatformHexCodecs.decode(inputs["nonce_c_hex"] as! String)
        let nonceH = try CrossPlatformHexCodecs.decode(inputs["nonce_h_hex"] as! String)

        let keys = CrossPlatformSessionKeys.derive(tapCode: tapCode, nonceC: nonceC, nonceH: nonceH)
        XCTAssertEqual(CrossPlatformHexCodecs.encode(keys.master), expected["K_master_hex"] as! String, "K_master mismatch")
        XCTAssertEqual(CrossPlatformHexCodecs.encode(keys.c2s), expected["K_c2s_hex"] as! String, "K_c2s mismatch")
        XCTAssertEqual(CrossPlatformHexCodecs.encode(keys.s2c), expected["K_s2c_hex"] as! String, "K_s2c mismatch")
    }
}
