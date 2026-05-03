// ConnectionPoolManagerHostOnlineTests.swift
// ConnectionPoolTests
//
// Verifies that `ConnectionPoolManager.updateHostOnline(_:offlineSince:)` correctly
// flips the published `hostOnline` and `hostOfflineSince` properties, and that
// `disconnect()` resets them to the optimistic defaults.

import XCTest
@testable import ConnectionPool

@MainActor
final class ConnectionPoolManagerHostOnlineTests: XCTestCase {

    func testHostOnlineDefaultsToTrueAndOfflineSinceDefaultsToNil() {
        let manager = ConnectionPoolManager.shared
        // Reset to a known clean state. `disconnect()` is idempotent on an idle manager.
        manager.disconnect()

        XCTAssertTrue(manager.hostOnline)
        XCTAssertNil(manager.hostOfflineSince)
    }

    func testUpdateHostOnlineFlipsToOffline() {
        let manager = ConnectionPoolManager.shared
        manager.disconnect()

        let timestamp: Int64 = 1_714_752_345
        manager.updateHostOnline(false, offlineSince: timestamp)

        XCTAssertFalse(manager.hostOnline)
        XCTAssertEqual(manager.hostOfflineSince, Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    func testUpdateHostOnlineFlipBackClearsOfflineSince() {
        let manager = ConnectionPoolManager.shared
        manager.disconnect()

        manager.updateHostOnline(false, offlineSince: 1_714_752_345)
        XCTAssertFalse(manager.hostOnline)
        XCTAssertNotNil(manager.hostOfflineSince)

        manager.updateHostOnline(true)
        XCTAssertTrue(manager.hostOnline)
        XCTAssertNil(manager.hostOfflineSince, "flipping back to online must clear offlineSince")
    }

    func testUpdateHostOnlineIgnoresOfflineSinceWhenOnline() {
        let manager = ConnectionPoolManager.shared
        manager.disconnect()

        // The relay should never send `offline_since` together with `online: true`, but
        // even if it does, we ignore it to keep the invariant `online => offlineSince == nil`.
        manager.updateHostOnline(true, offlineSince: 1_714_752_345)
        XCTAssertTrue(manager.hostOnline)
        XCTAssertNil(manager.hostOfflineSince)
    }

    func testDisconnectResetsHostOnlineToDefault() {
        let manager = ConnectionPoolManager.shared
        manager.disconnect()

        manager.updateHostOnline(false, offlineSince: 1_714_752_345)
        XCTAssertFalse(manager.hostOnline)

        manager.disconnect()

        XCTAssertTrue(manager.hostOnline, "disconnect() must reset hostOnline to true")
        XCTAssertNil(manager.hostOfflineSince, "disconnect() must clear hostOfflineSince")
    }

    func testIdempotentUpdateDoesNotChangeState() {
        let manager = ConnectionPoolManager.shared
        manager.disconnect()

        manager.updateHostOnline(false, offlineSince: 1_714_752_345)
        let firstSince = manager.hostOfflineSince

        // Second call with the same timestamp: state is unchanged.
        manager.updateHostOnline(false, offlineSince: 1_714_752_345)
        XCTAssertEqual(manager.hostOfflineSince, firstSince)
    }
}
