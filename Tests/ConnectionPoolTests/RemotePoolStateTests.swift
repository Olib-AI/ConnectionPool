// RemotePoolStateTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

@MainActor
final class RemotePoolStateTests: XCTestCase {

    // Async tearDown inherits the class's @MainActor isolation.
    override func tearDown() async throws {
        // Clean up UserDefaults between tests
        RemotePoolState.clear()
        try await super.tearDown()
    }

    func testSaveAndLoad() {
        let poolID = UUID()
        let state = RemotePoolState(
            serverURL: "ws://localhost:9090",
            poolName: "TestPool",
            isClaimed: true,
            poolID: poolID,
            maxPeers: 8,
            isHost: true
        )
        state.save()

        let loaded = RemotePoolState.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.serverURL, "ws://localhost:9090")
        XCTAssertEqual(loaded?.poolName, "TestPool")
        XCTAssertEqual(loaded?.isClaimed, true)
        XCTAssertEqual(loaded?.poolID, poolID)
        XCTAssertEqual(loaded?.maxPeers, 8)
        XCTAssertEqual(loaded?.isHost, true)
    }

    func testLoadReturnsNilWhenNoState() {
        RemotePoolState.clear()
        XCTAssertNil(RemotePoolState.load())
    }

    func testClearRemovesState() {
        let state = RemotePoolState(
            serverURL: "ws://test",
            poolName: "P",
            isClaimed: false,
            poolID: UUID(),
            maxPeers: 4,
            isHost: false
        )
        state.save()
        XCTAssertNotNil(RemotePoolState.load())
        RemotePoolState.clear()
        XCTAssertNil(RemotePoolState.load())
    }

    func testLastConnectedIsSetOnInit() {
        let before = Date()
        let state = RemotePoolState(
            serverURL: "ws://test",
            poolName: "P",
            isClaimed: false,
            poolID: UUID(),
            maxPeers: 4,
            isHost: false
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(state.lastConnected, before)
        XCTAssertLessThanOrEqual(state.lastConnected, after)
    }

    func testSaveOverwritesPrevious() {
        let state1 = RemotePoolState(
            serverURL: "ws://first",
            poolName: "First",
            isClaimed: false,
            poolID: UUID(),
            maxPeers: 2,
            isHost: false
        )
        state1.save()

        let state2 = RemotePoolState(
            serverURL: "ws://second",
            poolName: "Second",
            isClaimed: true,
            poolID: UUID(),
            maxPeers: 10,
            isHost: true
        )
        state2.save()

        let loaded = RemotePoolState.load()
        XCTAssertEqual(loaded?.serverURL, "ws://second")
        XCTAssertEqual(loaded?.poolName, "Second")
    }

    func testSecureProviderIsUsedWhenConfigured() {
        // Create a mock storage provider
        let mockProvider = MockStorageProvider()
        ConnectionPoolConfiguration.remotePoolStateStorageProvider = mockProvider

        let poolID = UUID()
        let state = RemotePoolState(
            serverURL: "ws://secure-test",
            poolName: "SecurePool",
            isClaimed: true,
            poolID: poolID,
            maxPeers: 4,
            isHost: true
        )
        state.save()

        // Verify it was saved through the provider, not UserDefaults
        XCTAssertNotNil(mockProvider.storage["remote_pool_state"])
        XCTAssertNil(UserDefaults.standard.data(forKey: "remote_pool_state"))

        // Verify it loads back through the provider
        let loaded = RemotePoolState.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.serverURL, "ws://secure-test")
        XCTAssertEqual(loaded?.poolID, poolID)

        // Clean up
        ConnectionPoolConfiguration.remotePoolStateStorageProvider = nil
    }

}

// MARK: - Mock Storage Provider

private final class MockStorageProvider: BlockListStorageProvider, @unchecked Sendable {
    var storage: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func load(forKey key: String) throws -> Data? {
        storage[key]
    }
}
