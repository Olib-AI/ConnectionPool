// PoolMessageTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class PoolMessageTests: XCTestCase {

    // MARK: - Factory: chat

    func testChatMessageCreation() {
        let msg = PoolMessage.chat(from: "sender", senderName: "Alice", text: "Hello")
        XCTAssertEqual(msg.type, .chat)
        XCTAssertEqual(msg.senderID, "sender")
        XCTAssertEqual(msg.senderName, "Alice")
        XCTAssertTrue(msg.isReliable)

        let decoded = msg.decodePayload(as: ChatPayload.self)
        XCTAssertEqual(decoded?.text, "Hello")
    }

    // MARK: - Factory: system

    func testSystemMessageCreation() {
        let msg = PoolMessage.system(from: "sys", senderName: "System", text: "joined")
        XCTAssertEqual(msg.type, .system)
        let decoded = msg.decodePayload(as: SystemPayload.self)
        XCTAssertEqual(decoded?.text, "joined")
    }

    // MARK: - Factory: keyExchange

    func testKeyExchangeMessageCreation() {
        let pubKey = Data(repeating: 0xAB, count: 32)
        let msg = PoolMessage.keyExchange(from: "peer-A", senderName: "Alice", publicKey: pubKey)
        XCTAssertEqual(msg.type, .keyExchange)
        let decoded = msg.decodePayload(as: KeyExchangePayload.self)
        XCTAssertEqual(decoded?.publicKey, pubKey)
        XCTAssertEqual(decoded?.senderPeerID, "peer-A")
    }

    // MARK: - Factory: gameState / gameAction

    func testGameStateMessageCreation() {
        struct SimpleState: Codable, Equatable { let score: Int }
        let msg = PoolMessage.gameState(from: "host", senderName: "Host", state: SimpleState(score: 42))
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, .gameState)
        let decoded = msg?.decodePayload(as: SimpleState.self)
        XCTAssertEqual(decoded?.score, 42)
    }

    func testGameActionMessageCreation() {
        struct Move: Codable, Equatable { let x: Int; let y: Int }
        let msg = PoolMessage.gameAction(from: "p1", senderName: "Player", action: Move(x: 1, y: 2), reliable: false)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, .gameAction)
        XCTAssertEqual(msg?.isReliable, false)
        let decoded = msg?.decodePayload(as: Move.self)
        XCTAssertEqual(decoded, Move(x: 1, y: 2))
    }

    // MARK: - Factory: relay

    func testRelayMessageCreation() {
        let envelope = RelayEnvelope(
            originPeerID: "origin",
            destinationPeerID: "dest",
            encryptedPayload: Data("secret".utf8),
            poolID: UUID()
        )
        let msg = PoolMessage.relay(from: "relay-node", senderName: "Relay", envelope: envelope)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, .relay)
        let decoded = msg?.decodePayload(as: RelayEnvelope.self)
        XCTAssertEqual(decoded?.originPeerID, "origin")
        XCTAssertEqual(decoded?.destinationPeerID, "dest")
    }

    // MARK: - Encode / Decode round trip

    func testEncodeDecodeRoundTrip() {
        let original = PoolMessage.chat(from: "s", senderName: "S", text: "roundtrip")
        let data = original.encode()
        XCTAssertNotNil(data)
        let decoded = PoolMessage.decode(from: data!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, original.id)
        XCTAssertEqual(decoded?.type, .chat)
        XCTAssertEqual(decoded?.senderID, "s")
    }

    func testDecodeFromGarbageReturnsNil() {
        XCTAssertNil(PoolMessage.decode(from: Data("garbage".utf8)))
    }

    // MARK: - PoolMessageType raw values

    func testMessageTypeRawValues() {
        XCTAssertEqual(PoolMessageType.chat.rawValue, "chat")
        XCTAssertEqual(PoolMessageType.relay.rawValue, "relay")
        XCTAssertEqual(PoolMessageType.ping.rawValue, "ping")
        XCTAssertEqual(PoolMessageType.pong.rawValue, "pong")
        XCTAssertEqual(PoolMessageType.gameControl.rawValue, "game_control")
    }
}
