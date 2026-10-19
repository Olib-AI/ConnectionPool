// SecureItemStore.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Security

// MARK: - Secure Item Store

/// Minimal generic-password store used for long-lived identity keys.
///
/// Production uses ``KeychainItemStore``. The abstraction exists so the persistence
/// logic layered on top (scoping, load-or-create, idempotent delete) can be exercised by
/// unit tests running in an unsigned test bundle, which has no Keychain entitlement.
public protocol SecureItemStore: Sendable {
    /// Returns the stored bytes, or `nil` if no item exists for `(service, account)`.
    func load(service: String, account: String) throws -> Data?
    /// Stores `data`, replacing any existing item for `(service, account)`.
    func save(_ data: Data, service: String, account: String) throws
    /// Removes the item. Succeeds if it does not exist.
    func delete(service: String, account: String) throws
}

/// Error raised by a ``SecureItemStore``; mirrors the `SecItem*` status contract.
public struct SecureItemStoreError: Error, Sendable, Equatable {
    public let status: OSStatus
    public let operation: String
}

// MARK: - Keychain

/// `SecItem`-backed store: generic passwords, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// (never backed up to iCloud, never transferred to another device).
public struct KeychainItemStore: SecureItemStore {
    public init() {}

    public func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecureItemStoreError(status: status, operation: "load")
        }
    }

    public func save(_ data: Data, service: String, account: String) throws {
        // Delete any existing slot first so SecItemAdd doesn't fail with errSecDuplicateItem.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureItemStoreError(status: status, operation: "save") }
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureItemStoreError(status: status, operation: "delete")
        }
    }
}

// MARK: - Process-wide Store

/// The store ``RemoteMemberIdentity`` persists through. Defaults to the Keychain.
///
/// Thread safety: NSLock around the current store (synchronous, callable anywhere).
public final class SecureItemStorage: @unchecked Sendable {
    public static let shared = SecureItemStorage()

    private let lock = NSLock()
    private var _store: any SecureItemStore = KeychainItemStore()

    /// The active store.
    public var store: any SecureItemStore {
        get { lock.withLock { _store } }
        set { lock.withLock { _store = newValue } }
    }
}
