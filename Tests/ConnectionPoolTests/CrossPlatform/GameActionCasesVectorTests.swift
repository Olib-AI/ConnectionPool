// GameActionCasesVectorTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Vector 04: canonical JSON byte shapes for the 5 `ChessGameAction` variants
// not pinned in vector 03 (`resign`, `offerDraw`, `acceptDraw`, `declineDraw`,
// plus two emote variants). Byte-equal assertion at the action-object
// canonical-JSON layer.

import XCTest
@testable import ConnectionPool

final class GameActionCasesVectorTests: XCTestCase {

    func test_all_action_variant_byteShapes() throws {
        let json = try VectorLoader.parse("04-game-action-cases.json")
        guard let cases = json["cases"] as? [[String: Any]] else {
            XCTFail("vector 04 schema mismatch"); return
        }
        for entry in cases {
            let name = entry["name"] as! String
            let expectedHex = entry["utf8_bytes_hex"] as! String
            let expectedUtf8 = entry["utf8_string"] as! String
            let action = try makeAction(named: name)
            let bytes = action.encodeCanonical()
            XCTAssertEqual(CrossPlatformHexCodecs.encode(bytes), expectedHex, "byte mismatch for case '\(name)'")
            XCTAssertEqual(String(data: bytes, encoding: .utf8), expectedUtf8, "utf8 mismatch for case '\(name)'")
        }
    }

    func test_chessUpEmotes_set_matches_vector() throws {
        let json = try VectorLoader.parse("04-game-action-cases.json")
        guard let emotes = json["chessup_emote_set"] as? [String] else {
            XCTFail("vector 04 chessup_emote_set missing"); return
        }
        XCTAssertEqual(CrossPlatformChessGameAction.chessUpEmotes, emotes)
    }

    private func makeAction(named name: String) throws -> CrossPlatformChessGameAction {
        switch name {
        case "resign":      return .resign
        case "offerDraw":   return .offerDraw
        case "acceptDraw":  return .acceptDraw
        case "declineDraw": return .declineDraw
        case "emote_crown": return .emote(emoji: "\u{1F451}") // 👑
        case "emote_fire":  return .emote(emoji: "\u{1F525}") // 🔥
        default:
            XCTFail("unknown vector 04 case: \(name)")
            return .resign
        }
    }
}
