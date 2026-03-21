// RemotePoolStateTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class RemotePoolStateTests: XCTestCase {

    override func tearDown() {
        // Clean up UserDefaults between tests
        RemotePoolState.clear()
        super.tearDown()
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
}
