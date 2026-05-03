// RemoteMemberIdentity.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Persistent Ed25519 keypair used by a pool *member* to prove its identity to
// the StealthRelay server when reconnecting after a disconnect. This is the
// load-bearing piece of the v0.5.0 "auto-rejoin" flow: once the host has
// approved a peer one time, the relay records that peer's public key in the
// pool's `approved_peers` set and lets the same key reconnect indefinitely
// via `member_rejoin` — no host involvement required.
//
// Storage scheme: one Keychain entry per (server_url, pool_id) pair, keyed by
// `member_identity:<sha256(server_url + ":" + pool_id)>`. This guarantees
// identity continuity per pool while keeping pools cryptographically isolated.

import Foundation
import CryptoKit
import Security

// MARK: - Remote Member Identity

/// An Ed25519 signing identity used to authenticate a *member* (non-host) of a
/// remote pool against the StealthRelay server.
///
/// Mirrors the host-side ``RemoteHostIdentity`` design: a thin value type that
/// wraps a `Curve25519.Signing` keypair and provides Keychain-backed
/// persistence scoped to a `(serverURL, poolID)` tuple.
///
/// The private key is stored in the Keychain with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` protection — matching the
/// host identity — so identities cannot be backed up to iCloud or transferred
/// to another device.
public struct RemoteMemberIdentity: Sendable {

    // MARK: - Keychain Constants

    /// Keychain `kSecAttrService` shared by every member identity. The
    /// `kSecAttrAccount` is what scopes the entry to a specific pool.
    private static let keychainService = "com.stealthos.connectionpool.memberidentity"

    /// Keychain account prefix. Combined with the SHA-256 of
    /// `serverURL + ":" + poolID` it produces a unique per-pool slot.
    fileprivate static let keychainAccountPrefix = "member_identity:"

    // MARK: - Stored Values

    /// The Ed25519 private signing key.
    public let privateKey: Curve25519.Signing.PrivateKey

    /// The corresponding Ed25519 public verification key.
    public let publicKey: Curve25519.Signing.PublicKey

    /// Raw bytes of the public key for encoding/transmission.
    public var publicKeyData: Data { publicKey.rawRepresentation }

    /// Base64-encoded representation of the public key, suitable for embedding
    /// in `MemberRejoinData.clientPublicKey` and `JoinRequestData.clientPublicKey`.
    public var publicKeyBase64: String { publicKeyData.base64EncodedString() }

    // MARK: - Initialization

    /// Create an identity from an existing Ed25519 private key.
    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
    }

    // MARK: - Signing

    /// Produce an Ed25519 signature over the supplied transcript bytes.
    ///
    /// For the `member_rejoin` flow the transcript is:
    /// `"STEALTH_MEMBER_REJOIN_V1:" || pool_id_raw_bytes(16) || timestamp_be(8) || nonce_raw(32)`
    ///
    /// - Parameter transcript: The exact bytes to sign.
    /// - Returns: The Ed25519 signature.
    /// - Throws: ``CryptoKitError`` if signing fails.
    public func sign(transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript)
    }

    // MARK: - Keychain Persistence

    /// Load an existing member identity for the supplied pool, returning `nil`
    /// if no identity has been persisted yet.
    public static func existing(serverURL: String, poolID: String) throws -> RemoteMemberIdentity? {
        let account = keychainAccount(serverURL: serverURL, poolID: poolID)
        guard let raw = try loadFromKeychain(account: account) else {
            return nil
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return RemoteMemberIdentity(privateKey: privateKey)
    }

    /// Load the existing member identity for the supplied pool, or generate
    /// and persist a fresh one on the first call.
    ///
    /// This is the call site that fixes the "returning users can't rejoin" bug:
    /// every member-side join goes through `loadOrCreate` so the public key
    /// presented to the relay is stable across app launches and reconnects.
    public static func loadOrCreate(serverURL: String, poolID: String) throws -> RemoteMemberIdentity {
        if let existing = try existing(serverURL: serverURL, poolID: poolID) {
            return existing
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        try saveToKeychain(privateKey.rawRepresentation,
                           account: keychainAccount(serverURL: serverURL, poolID: poolID))
        return RemoteMemberIdentity(privateKey: privateKey)
    }

    /// Remove the persisted identity for the supplied pool. Idempotent.
    ///
    /// Called when the relay reports `403 not_approved` (the user was kicked
    /// or never approved on this device) or `404 pool_not_found` (pool
    /// destroyed), and from the explicit "Leave Pool" UI surface so the user
    /// can opt out of auto-rejoin.
    public func delete(serverURL: String, poolID: String) throws {
        try Self.delete(serverURL: serverURL, poolID: poolID)
    }

    /// Static variant of ``delete(serverURL:poolID:)`` for callers that don't
    /// already hold an instance.
    public static func delete(serverURL: String, poolID: String) throws {
        try deleteFromKeychain(account: keychainAccount(serverURL: serverURL, poolID: poolID))
    }

    // MARK: - Account Derivation

    /// Compute the Keychain account string for a `(serverURL, poolID)` pair.
    ///
    /// The hash binds the identity to *both* the server and the pool, so the
    /// same pool ID against a different relay never collides — and a fresh
    /// pool with the same UUID on the same relay cannot reuse a stale key.
    static func keychainAccount(serverURL: String, poolID: String) -> String {
        let composite = "\(serverURL):\(poolID)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keychainAccountPrefix)\(hex)"
    }

    // MARK: - Private Keychain Helpers

    private static func saveToKeychain(_ data: Data, account: String) throws {
        // Delete any existing slot first so SecItemAdd doesn't fail with errSecDuplicateItem.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemoteMemberIdentityError.keychainFailure(status: status, operation: "save")
        }
    }

    private static func loadFromKeychain(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw RemoteMemberIdentityError.keychainFailure(status: status, operation: "load")
        }
    }

    private static func deleteFromKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteMemberIdentityError.keychainFailure(status: status, operation: "delete")
        }
    }
}

// MARK: - Errors

/// Errors emitted by ``RemoteMemberIdentity`` Keychain operations.
public enum RemoteMemberIdentityError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A `SecItem*` call returned a non-success status code.
    case keychainFailure(status: OSStatus, operation: String)

    public var description: String {
        switch self {
        case .keychainFailure(let status, let op):
            return "Keychain \(op) failed with OSStatus \(status)"
        }
    }
}
