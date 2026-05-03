// TransportErrorHostOfflineTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class TransportErrorHostOfflineTests: XCTestCase {

    func testHostOfflineErrorEquality() {
        let a: TransportError = .hostOffline
        let b: TransportError = .hostOffline
        XCTAssertEqual(a, b)
    }

    func testHostOfflineErrorIsDistinctFromAuthenticationFailed() {
        let a: TransportError = .hostOffline
        let b: TransportError = .authenticationFailed
        XCTAssertNotEqual(a, b)
    }

    func testHostOfflineErrorMessageMentionsHost() {
        let error: TransportError = .hostOffline
        let description = error.localizedDescription.lowercased()
        XCTAssertTrue(description.contains("host"), "user-facing message should reference the host: \(error.localizedDescription)")
        XCTAssertTrue(description.contains("offline"), "user-facing message should reference offline status: \(error.localizedDescription)")
    }
}
