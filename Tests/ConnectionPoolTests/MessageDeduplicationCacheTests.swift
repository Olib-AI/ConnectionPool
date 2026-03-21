// MessageDeduplicationCacheTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class MessageDeduplicationCacheTests: XCTestCase {

    func testMarkProcessedThenHasProcessed() {
        let cache = MessageDeduplicationCache()
        let id = UUID()
        XCTAssertFalse(cache.hasProcessed(id))
        cache.markProcessed(id)
        XCTAssertTrue(cache.hasProcessed(id))
    }

    func testCountIncrementsOnNewEntries() {
        let cache = MessageDeduplicationCache()
        XCTAssertEqual(cache.count, 0)
        cache.markProcessed(UUID())
        cache.markProcessed(UUID())
        XCTAssertEqual(cache.count, 2)
    }

    func testDuplicateMarkDoesNotDuplicateCount() {
        let cache = MessageDeduplicationCache()
        let id = UUID()
        cache.markProcessed(id)
        cache.markProcessed(id) // duplicate
        XCTAssertEqual(cache.count, 1)
    }

    func testPruneExpiredRemovesNothing_WhenFresh() {
        let cache = MessageDeduplicationCache()
        cache.markProcessed(UUID())
        cache.markProcessed(UUID())
        cache.pruneExpired()
        XCTAssertEqual(cache.count, 2, "Fresh entries should survive pruning")
    }

    func testHasProcessedReturnsFalseForUnknownID() {
        let cache = MessageDeduplicationCache()
        XCTAssertFalse(cache.hasProcessed(UUID()))
    }

    func testEvictionUnderPressure() {
        // The cache has a maxCacheSize of 10_000. We add 10_001 entries
        // and verify the count does not exceed 10_000.
        let cache = MessageDeduplicationCache()
        for _ in 0..<10_001 {
            cache.markProcessed(UUID())
        }
        XCTAssertLessThanOrEqual(cache.count, 10_000)
    }
}
