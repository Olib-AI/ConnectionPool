// SecureItemStoreTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class SecureItemStoreTests: XCTestCase {

    private struct FailingStore: SecureItemStore {
        func load(service: String, account: String) throws -> Data? { throw SecureItemStoreError(status: -25300, operation: "load") }
        func save(_ data: Data, service: String, account: String) throws { throw SecureItemStoreError(status: -25299, operation: "save") }
        func delete(service: String, account: String) throws { throw SecureItemStoreError(status: -25244, operation: "delete") }
    }

    override func tearDown() {
        InMemorySecureItemStore.install()
        super.tearDown()
    }

    func testProductionDefaultIsTheKeychain() {
        XCTAssertTrue(SecureItemStorage().store is KeychainItemStore,
                      "a fresh process must persist identities in the Keychain")
    }

    func testStoreErrorsSurfaceAsKeychainFailures() {
        SecureItemStorage.shared.store = FailingStore()
        XCTAssertThrowsError(try RemoteMemberIdentity.existing(serverURL: "wss://x", poolID: "p")) {
            XCTAssertEqual($0 as? RemoteMemberIdentityError, .keychainFailure(status: -25300, operation: "load"))
        }
        XCTAssertThrowsError(try RemoteMemberIdentity.delete(serverURL: "wss://x", poolID: "p")) {
            XCTAssertEqual($0 as? RemoteMemberIdentityError, .keychainFailure(status: -25244, operation: "delete"))
        }
    }

    func testInMemoryStoreMirrorsKeychainSemantics() throws {
        let store = InMemorySecureItemStore()
        XCTAssertNil(try store.load(service: "s", account: "a"))
        try store.save(Data([1]), service: "s", account: "a")
        try store.save(Data([2]), service: "s", account: "a")
        XCTAssertEqual(try store.load(service: "s", account: "a"), Data([2]), "save replaces")
        XCTAssertNil(try store.load(service: "other", account: "a"), "scoped by service")
        try store.delete(service: "s", account: "a")
        try store.delete(service: "s", account: "a")
        XCTAssertNil(try store.load(service: "s", account: "a"), "delete is idempotent")
    }
}
