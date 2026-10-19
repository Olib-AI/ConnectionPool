// KeyExchangeCompatibilityTests.swift
// ConnectionPoolTests

import Foundation
import Testing
@testable import ConnectionPool

@Suite("Key exchange wire compatibility")
struct KeyExchangeCompatibilityTests {

    /// The 1.4.x shape: only these two fields.
    private struct LegacyKeyExchange: Codable { let publicKey: Data; let senderPeerID: String }

    @Test("A 1.5.0 key exchange decodes on 1.4.x (extra keys ignored)")
    func newToOld() throws {
        let message = PoolMessage.keyExchange(from: "a", senderName: "A", publicKey: Data(repeating: 1, count: 32),
                                              signingPublicKey: Data(repeating: 2, count: 32), signingKeyBinding: Data(repeating: 3, count: 64))
        let legacy = try JSONDecoder().decode(LegacyKeyExchange.self, from: message.payload)
        #expect(legacy.publicKey == Data(repeating: 1, count: 32) && legacy.senderPeerID == "a")
    }

    @Test("A 1.4.x key exchange decodes on 1.5.0 without a signing key")
    func oldToNew() throws {
        let data = try JSONEncoder().encode(LegacyKeyExchange(publicKey: Data(repeating: 1, count: 32), senderPeerID: "a"))
        let payload = try JSONDecoder().decode(KeyExchangePayload.self, from: data)
        #expect(payload.signingPublicKey == nil && payload.signingKeyBinding == nil)
    }

    @Test("Without signing fields the JSON keeps the 1.4.x shape")
    func shape() throws {
        let message = PoolMessage.keyExchange(from: "a", senderName: "A", publicKey: Data(repeating: 1, count: 32))
        let object = try #require(try JSONSerialization.jsonObject(with: message.payload) as? [String: Any])
        #expect(Set(object.keys) == ["publicKey", "senderPeerID"])
    }
}
