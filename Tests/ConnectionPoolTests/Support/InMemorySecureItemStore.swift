// InMemorySecureItemStore.swift
// ConnectionPoolTests
//
// SPM test bundles run unsigned inside the simulator's xctest host, which has no
// keychain-access-groups entitlement: every SecItem call fails with
// errSecMissingEntitlement (-34018). Tests that exercise the identity persistence logic
// install this store instead. It mirrors the generic-password semantics
// KeychainItemStore relies on: items keyed by (service, account), save replaces, load of a
// missing item returns nil, delete is idempotent.

import Foundation
@testable import ConnectionPool

final class InMemorySecureItemStore: SecureItemStore, @unchecked Sendable {
    /// One store for the whole test process, so parallel test classes share state the
    /// same way they would share the real Keychain.
    static let shared = InMemorySecureItemStore()

    private struct Key: Hashable { let service: String; let account: String }
    private let lock = NSLock()
    private var items: [Key: Data] = [:]

    func load(service: String, account: String) throws -> Data? {
        lock.withLock { items[Key(service: service, account: account)] }
    }

    func save(_ data: Data, service: String, account: String) throws {
        lock.withLock { items[Key(service: service, account: account)] = data }
    }

    func delete(service: String, account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: Key(service: service, account: account)) }
    }

    /// Routes `RemoteMemberIdentity` persistence through this store (idempotent).
    static func install() {
        SecureItemStorage.shared.store = shared
    }
}
