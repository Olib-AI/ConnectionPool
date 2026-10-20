// PoolEgressTests.swift
// ConnectionPoolTests
//
// The host-app routing seam (PoolEgress): local-presence consent semantics, the gates on
// MultipeerConnectivity / Bonjour, the relay WebSocket's blocked route and proxy setup.

import XCTest
@testable import ConnectionPool

@MainActor
final class PoolEgressTests: XCTestCase {

    override func tearDown() async throws {
        PoolEgress.isAnonymityRegimeActive = false
        PoolEgress.revokeLocalPresenceConsent()
        PoolEgress.routeProvider = nil
        PoolEgress.regimeIdentityHeaders = [:]
        try await super.tearDown()
    }

    func testDefaultsKeepThePackageStandalone() {
        XCTAssertTrue(PoolEgress.mayUseLocalNetwork)
        XCTAssertEqual(PoolEgress.route(for: URL(string: "wss://relay.example/ws")!), .direct)
    }

    func testConsentCoversOneRegimeOnly() {
        PoolEgress.isAnonymityRegimeActive = true
        XCTAssertFalse(PoolEgress.mayUseLocalNetwork)
        PoolEgress.grantLocalPresenceConsent()
        XCTAssertTrue(PoolEgress.mayUseLocalNetwork)
        // Setting the same value keeps consent; any change withdraws it.
        PoolEgress.isAnonymityRegimeActive = true
        XCTAssertTrue(PoolEgress.mayUseLocalNetwork)
        PoolEgress.isAnonymityRegimeActive = false
        PoolEgress.isAnonymityRegimeActive = true
        XCTAssertFalse(PoolEgress.mayUseLocalNetwork)
        PoolEgress.grantLocalPresenceConsent()
        PoolEgress.revokeLocalPresenceConsent()
        XCTAssertFalse(PoolEgress.mayUseLocalNetwork)
    }

    func testMultipeerDoesNotStartUnderRegime() {
        PoolEgress.isAnonymityRegimeActive = true
        let manager = ConnectionPoolManager()
        manager.startHosting()
        manager.startBrowsing()
        XCTAssertEqual(manager.poolState, .idle)
        XCTAssertFalse(manager.isLocalPresenceActive)
        XCTAssertEqual(manager.localPresenceNotice, .blockedByRegime)
    }

    func testBonjourDoesNotStartUnderRegime() throws {
        PoolEgress.isAnonymityRegimeActive = true
        let advertiser = try BonjourAdvertiser(poolName: "t", hostDisplayName: "t", localPID: Data(count: 16))
        XCTAssertFalse(advertiser.start { _ in })
        XCTAssertFalse(BonjourBrowser().start { _ in })
    }

    func testPeerNameIsSanitizedProfileName() {
        XCTAssertEqual(ConnectionPoolManager.peerDisplayName(from: "  Alice  "), "Alice")
        XCTAssertEqual(ConnectionPoolManager.peerDisplayName(from: ""), "Pool Member")
        XCTAssertLessThanOrEqual(ConnectionPoolManager.peerDisplayName(from: String(repeating: "ü", count: 80)).utf8.count, 63)
    }

    func testBlockedRouteFailsWithoutConnecting() {
        PoolEgress.routeProvider = { _ in .blocked(reason: "kill switch") }
        let transport = WebSocketTransport(
            configuration: RemotePoolConfiguration(serverURL: URL(string: "wss://relay.example/ws")!, poolName: "t"),
            displayName: "t"
        )
        transport.startAdvertising(poolInfo: PoolAdvertisementInfo(poolID: UUID(), poolName: "t", hostName: "t"))
        guard case .failed = transport.state else {
            return XCTFail("a blocked route must fail the transport, state: \(transport.state)")
        }
        XCTAssertEqual(transport.currentRoute, .blocked(reason: "kill switch"))
    }

    func testProxyDictionaryCoversWsAndWss() {
        let dictionary = WebSocketTransport.proxyDictionary(host: "127.0.0.1", port: 8888)
        XCTAssertEqual(dictionary["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary["HTTPSPort"] as? Int, 8888)
        // No credential in the dictionary: it is answered to the proxy challenge only.
        XCTAssertNil(dictionary["HTTPProxyUsername"])
    }
}
