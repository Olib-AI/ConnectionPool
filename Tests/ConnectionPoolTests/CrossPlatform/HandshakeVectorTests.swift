// HandshakeVectorTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Vector 01: canonical handshake JSON byte sequences (plaintext, framed
// under type 0x02). Byte-equal assertion on every `client_hello`,
// `server_hello{ok:true}`, and `server_hello{ok:false,err:"bad_code"}`
// produced by the encoder.

import XCTest
@testable import ConnectionPool

final class HandshakeVectorTests: XCTestCase {

    func test_clientHello_bytes_byteEqual() throws {
        let json = try VectorLoader.parse("01-handshake.json")
        guard let outer = json["client_hello"] as? [String: Any],
              let obj = outer["object"] as? [String: Any] else {
            XCTFail("vector 01.client_hello schema mismatch"); return
        }
        let expectedHex = outer["utf8_bytes_hex"] as! String

        // Decode the input fields from the vector's canonical object.
        let pid = CrossPlatformBase64.decodeUrl(obj["pid"] as! String)!
        let name = obj["name"] as! String
        let nonceC = CrossPlatformBase64.decodeUrl(obj["nonce_c"] as! String)!
        let codeHash = CrossPlatformBase64.decodeUrl(obj["code_hash"] as! String)!
        let cap = obj["cap"] as! String

        let hello = ClientHello(pid: pid, name: name, nonceC: nonceC, codeHash: codeHash, cap: cap, resume: nil)
        let bytes = hello.encodeCanonical()
        XCTAssertEqual(CrossPlatformHexCodecs.encode(bytes), expectedHex, "client_hello byte mismatch")
    }

    func test_serverHello_ok_bytes_byteEqual() throws {
        let json = try VectorLoader.parse("01-handshake.json")
        guard let outer = json["server_hello_ok"] as? [String: Any],
              let obj = outer["object"] as? [String: Any] else {
            XCTFail("vector 01.server_hello_ok schema mismatch"); return
        }
        let expectedHex = outer["utf8_bytes_hex"] as! String

        let pid = CrossPlatformBase64.decodeUrl(obj["pid"] as! String)!
        let name = obj["name"] as! String
        let nonceH = CrossPlatformBase64.decodeUrl(obj["nonce_h"] as! String)!
        let sessionId = CrossPlatformBase64.decodeUrl(obj["session_id"] as! String)!
        let hostColor = obj["host_color"] as! String
        let startingFEN = obj["starting_fen"] as! String

        let ok = ServerHello.ok(ServerHello.Ok(
            pid: pid,
            name: name,
            nonceH: nonceH,
            sessionId: sessionId,
            hostColor: hostColor,
            startingFEN: startingFEN
        ))
        XCTAssertEqual(CrossPlatformHexCodecs.encode(ok.encodeCanonical()), expectedHex, "server_hello{ok} byte mismatch")
    }

    func test_serverHello_badCode_bytes_byteEqual() throws {
        let json = try VectorLoader.parse("01-handshake.json")
        guard let outer = json["server_hello_bad_code"] as? [String: Any],
              let obj = outer["object"] as? [String: Any] else {
            XCTFail("vector 01.server_hello_bad_code schema mismatch"); return
        }
        let expectedHex = outer["utf8_bytes_hex"] as! String
        let err = obj["err"] as! String
        let fail = ServerHello.failure(ServerHello.Failure(err: err))
        XCTAssertEqual(CrossPlatformHexCodecs.encode(fail.encodeCanonical()), expectedHex, "server_hello{bad_code} byte mismatch")
    }

    func test_codeHash_derivation_byteEqual() throws {
        let json = try VectorLoader.parse("01-handshake.json")
        guard let derivation = json["code_hash_derivation"] as? [String: Any] else {
            XCTFail("vector 01.code_hash_derivation schema mismatch"); return
        }
        let input = derivation["input_utf8"] as! String
        let expectedHex = derivation["sha256_first_16_hex"] as! String
        let expectedB64u = derivation["sha256_first_16_b64url"] as! String

        // Use the same SHA-256-first-16 path the pool uses, via CryptoKit.
        // Replicating it here keeps the test independent of pool internals.
        let digest = SHA256_first16(Data(input.utf8))
        XCTAssertEqual(CrossPlatformHexCodecs.encode(digest), expectedHex)
        XCTAssertEqual(CrossPlatformBase64.encode16(digest), expectedB64u)
    }

    // SHA-256 first 16 helper, separate from pool's private method.
    private func SHA256_first16(_ data: Data) -> Data {
        // Use CryptoKit directly (already linked).
        let digest = CryptoKit.SHA256.hash(data: data)
        return Data(digest.prefix(16))
    }
}
import CryptoKit
