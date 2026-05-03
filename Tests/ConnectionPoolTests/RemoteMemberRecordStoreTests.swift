// RemoteMemberRecordStoreTests.swift
// ConnectionPoolTests
//
// Verifies the on-disk ledger that backs the home-screen "Rejoin" tiles and
// drives `WebSocketTransport.joinAccepted` upserts.

import XCTest
@testable import ConnectionPool

@MainActor
final class RemoteMemberRecordStoreTests: XCTestCase {

    override func tearDown() {
        RemoteMemberRecordStore.clearAll()
        ConnectionPoolConfiguration.remotePoolStateStorageProvider = nil
        super.tearDown()
    }

    // MARK: - Round-trip via UserDefaults

    func testUpsertAndLookup() {
        let record = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "11111111-1111-1111-1111-111111111111",
            memberPublicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            displayName: "Maya"
        )
        RemoteMemberRecordStore.upsert(record)

        let loaded = RemoteMemberRecordStore.record(serverURL: record.serverURL, poolID: record.poolID)
        XCTAssertEqual(loaded?.serverURL, record.serverURL)
        XCTAssertEqual(loaded?.poolID, record.poolID)
        XCTAssertEqual(loaded?.memberPublicKeyBase64, record.memberPublicKeyBase64)
        XCTAssertEqual(loaded?.displayName, "Maya")
    }

    func testUpsertReplacesExisting() {
        let record1 = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "p1",
            memberPublicKeyBase64: "k1",
            displayName: "First"
        )
        RemoteMemberRecordStore.upsert(record1)

        let record2 = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "p1",
            memberPublicKeyBase64: "k1",
            displayName: "Second"
        )
        RemoteMemberRecordStore.upsert(record2)

        let loaded = RemoteMemberRecordStore.record(serverURL: "wss://relay.test", poolID: "p1")
        XCTAssertEqual(loaded?.displayName, "Second")
        XCTAssertEqual(RemoteMemberRecordStore.allRecords().count, 1)
    }

    func testRemoveDeletesEntry() {
        let record = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "p1",
            memberPublicKeyBase64: "k1",
            displayName: "Maya"
        )
        RemoteMemberRecordStore.upsert(record)
        XCTAssertNotNil(RemoteMemberRecordStore.record(serverURL: "wss://relay.test", poolID: "p1"))

        RemoteMemberRecordStore.remove(serverURL: "wss://relay.test", poolID: "p1")
        XCTAssertNil(RemoteMemberRecordStore.record(serverURL: "wss://relay.test", poolID: "p1"))
    }

    func testTouchUpdatesLastSuccessfulConnect() {
        let initial = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "p1",
            memberPublicKeyBase64: "k1",
            displayName: "Maya",
            firstJoinedAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessfulConnectAt: nil
        )
        RemoteMemberRecordStore.upsert(initial)

        let touchTime = Date(timeIntervalSince1970: 5_000)
        RemoteMemberRecordStore.touch(serverURL: "wss://relay.test", poolID: "p1", at: touchTime)

        let loaded = RemoteMemberRecordStore.record(serverURL: "wss://relay.test", poolID: "p1")
        XCTAssertEqual(loaded?.lastSuccessfulConnectAt, touchTime)
        XCTAssertEqual(loaded?.firstJoinedAt, Date(timeIntervalSince1970: 1_000),
                       "touch must NOT modify firstJoinedAt")
    }

    func testTouchOnMissingRecordIsNoOp() {
        RemoteMemberRecordStore.touch(serverURL: "wss://nope", poolID: "missing")
        XCTAssertNil(RemoteMemberRecordStore.record(serverURL: "wss://nope", poolID: "missing"))
    }

    // MARK: - allRecords ordering

    func testAllRecordsSortedByMostRecentActivity() {
        RemoteMemberRecordStore.upsert(RemoteMemberRecord(
            serverURL: "wss://a", poolID: "p1", memberPublicKeyBase64: "k", displayName: "A",
            firstJoinedAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessfulConnectAt: Date(timeIntervalSince1970: 9_000)
        ))
        RemoteMemberRecordStore.upsert(RemoteMemberRecord(
            serverURL: "wss://b", poolID: "p2", memberPublicKeyBase64: "k", displayName: "B",
            firstJoinedAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessfulConnectAt: Date(timeIntervalSince1970: 5_000)
        ))
        RemoteMemberRecordStore.upsert(RemoteMemberRecord(
            serverURL: "wss://c", poolID: "p3", memberPublicKeyBase64: "k", displayName: "C",
            firstJoinedAt: Date(timeIntervalSince1970: 8_000),
            lastSuccessfulConnectAt: nil
        ))

        let ordered = RemoteMemberRecordStore.allRecords()
        XCTAssertEqual(ordered.map { $0.displayName }, ["A", "C", "B"],
                       "records must sort by max(lastSuccessfulConnectAt, firstJoinedAt) descending")
    }

    // MARK: - Composite key

    func testCompositeKeyMatchesStaticHelper() {
        let record = RemoteMemberRecord(
            serverURL: "wss://relay.test",
            poolID: "abc",
            memberPublicKeyBase64: "k",
            displayName: "Maya"
        )
        XCTAssertEqual(record.compositeKey,
                       RemoteMemberRecordStore.compositeKey(serverURL: "wss://relay.test", poolID: "abc"))
    }

    // MARK: - Secure storage provider integration

    func testSecureProviderIsUsedWhenConfigured() {
        let mock = MockMemberStorageProvider()
        ConnectionPoolConfiguration.remotePoolStateStorageProvider = mock

        let record = RemoteMemberRecord(
            serverURL: "wss://secure",
            poolID: "p1",
            memberPublicKeyBase64: "k",
            displayName: "Maya"
        )
        RemoteMemberRecordStore.upsert(record)

        XCTAssertNotNil(mock.storage["remote_member_records"],
                        "saved blob must round-trip through the configured provider")
        XCTAssertNil(UserDefaults.standard.data(forKey: "remote_member_records"),
                     "UserDefaults must NOT be touched when a provider is configured")

        let loaded = RemoteMemberRecordStore.record(serverURL: "wss://secure", poolID: "p1")
        XCTAssertEqual(loaded?.memberPublicKeyBase64, "k")
    }
}

private final class MockMemberStorageProvider: BlockListStorageProvider, @unchecked Sendable {
    var storage: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func load(forKey key: String) throws -> Data? {
        storage[key]
    }
}
