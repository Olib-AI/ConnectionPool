// RemotePoolState.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Persists remote pool connection state across app restarts.

import Foundation

/// Saved state for a remote pool connection.
/// Persisted via the configured secure storage provider (or UserDefaults
/// when no provider is set) so the app can auto-reconnect on launch.
public struct RemotePoolState: Codable, Sendable {
    /// The relay server URL (e.g., "ws://localhost:9090").
    public var serverURL: String

    /// The pool name.
    public var poolName: String

    /// Whether this server has been claimed by this device.
    public var isClaimed: Bool

    /// The pool ID used for this session.
    public var poolID: UUID

    /// Max peers for the pool.
    public var maxPeers: Int

    /// Whether this device is the host.
    public var isHost: Bool

    /// When this state was last saved.
    public var lastConnected: Date

    public init(
        serverURL: String,
        poolName: String,
        isClaimed: Bool,
        poolID: UUID,
        maxPeers: Int,
        isHost: Bool
    ) {
        self.serverURL = serverURL
        self.poolName = poolName
        self.isClaimed = isClaimed
        self.poolID = poolID
        self.maxPeers = maxPeers
        self.isHost = isHost
        self.lastConnected = Date()
    }

    // MARK: - Persistence

    private static let storageKey = "remote_pool_state"

    /// Returns the secure storage provider if configured, otherwise `nil`.
    /// Must be accessed from `@MainActor` since the configuration property is `@MainActor`-isolated.
    @MainActor
    private static var secureProvider: BlockListStorageProvider? {
        ConnectionPoolConfiguration.remotePoolStateStorageProvider
    }

    /// Save state, using the secure storage provider when available,
    /// falling back to UserDefaults when no provider is configured.
    @MainActor
    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }

        if let provider = Self.secureProvider {
            try? provider.save(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Load state, using the secure storage provider when available,
    /// falling back to UserDefaults when no provider is configured.
    @MainActor
    public static func load() -> RemotePoolState? {
        if let provider = secureProvider {
            guard let data = try? provider.load(forKey: storageKey),
                  let state = try? JSONDecoder().decode(RemotePoolState.self, from: data) else {
                return nil
            }
            return state
        }

        // No secure provider — use UserDefaults
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(RemotePoolState.self, from: data) else {
            return nil
        }
        return state
    }

    /// Clear saved state.
    @MainActor
    public static func clear() {
        if let provider = secureProvider {
            try? provider.save(Data(), forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}

// MARK: - Remote Member Record

/// Persisted, member-side record of a remote pool the user has previously
/// joined and been approved into. Lets the iOS client surface a "Rejoin"
/// affordance and drive the auto-rejoin flow without prompting the user for
/// the original invitation.
///
/// One record exists per `(serverURL, poolID)` tuple. The actual signing
/// keypair lives in the Keychain (see ``RemoteMemberIdentity``); this record
/// stores only metadata safe to keep in UserDefaults / the configured
/// secure-storage provider.
public struct RemoteMemberRecord: Codable, Sendable, Equatable {
    /// The relay server URL (e.g., "wss://relay.example.com").
    public let serverURL: String

    /// The pool the user is a member of.
    public let poolID: String

    /// Base64-encoded Ed25519 public key — duplicated here so the UI / view
    /// model can identify the local member without going through the Keychain
    /// on every render.
    public let memberPublicKeyBase64: String

    /// Display name used the last time the member joined this pool. The user
    /// may change their profile display name at the app level; we send the
    /// updated value at rejoin time but keep the historical name here for
    /// the saved-pools list UI.
    public let displayName: String

    /// When this record was first written (i.e. the original successful
    /// `JoinAccepted`).
    public let firstJoinedAt: Date

    /// When the member most recently completed a successful connection (host
    /// approval *or* `member_rejoin`). Updated on every accepted rejoin.
    public let lastSuccessfulConnectAt: Date?

    public init(
        serverURL: String,
        poolID: String,
        memberPublicKeyBase64: String,
        displayName: String,
        firstJoinedAt: Date = Date(),
        lastSuccessfulConnectAt: Date? = nil
    ) {
        self.serverURL = serverURL
        self.poolID = poolID
        self.memberPublicKeyBase64 = memberPublicKeyBase64
        self.displayName = displayName
        self.firstJoinedAt = firstJoinedAt
        self.lastSuccessfulConnectAt = lastSuccessfulConnectAt
    }

    /// Stable lookup key combining server and pool. Pool IDs are not unique
    /// across relays, so the server URL is part of the identity.
    public var compositeKey: String { "\(serverURL):\(poolID)" }
}

// MARK: - Remote Member Record Store

/// Persistent, MainActor-owned registry of every remote pool the user is a
/// member of. Backed by ``ConnectionPoolConfiguration/remotePoolStateStorageProvider``
/// when configured, falling back to UserDefaults otherwise.
///
/// Records survive transient disconnects (network blips, app backgrounding)
/// and are deleted only when:
///   - the relay reports `403 not_approved` (host kicked us / never approved
///     us on this device), or
///   - the relay reports `404 pool_not_found` (pool destroyed), or
///   - the user explicitly invokes "Leave Pool" in the UI.
@MainActor
public enum RemoteMemberRecordStore {

    /// Storage key used for the entire `[compositeKey: RemoteMemberRecord]`
    /// dictionary so the secure-storage provider only ever holds one blob.
    private static let storageKey = "remote_member_records"

    private static var secureProvider: BlockListStorageProvider? {
        ConnectionPoolConfiguration.remotePoolStateStorageProvider
    }

    /// Load the full record map. Returns an empty dictionary on first use or
    /// any decode failure — the ledger is recoverable from the Keychain
    /// identity slots so we never throw on a corrupt blob.
    public static func loadAll() -> [String: RemoteMemberRecord] {
        let data: Data? = {
            if let provider = secureProvider {
                return (try? provider.load(forKey: storageKey)).flatMap { $0.isEmpty ? nil : $0 }
            }
            return UserDefaults.standard.data(forKey: storageKey)
        }()
        guard let blob = data,
              let decoded = try? JSONDecoder().decode([String: RemoteMemberRecord].self, from: blob)
        else {
            return [:]
        }
        return decoded
    }

    /// Persist the full record map. Callers should round-trip through
    /// ``loadAll()`` → mutate → ``saveAll(_:)`` to keep the dictionary
    /// consistent.
    public static func saveAll(_ records: [String: RemoteMemberRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        if let provider = secureProvider {
            try? provider.save(data, forKey: storageKey)
        } else {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Convenience: list every saved record sorted by most-recent activity
    /// (or `firstJoinedAt` when the member has not yet successfully
    /// reconnected).
    public static func allRecords() -> [RemoteMemberRecord] {
        loadAll().values.sorted { lhs, rhs in
            let lKey = lhs.lastSuccessfulConnectAt ?? lhs.firstJoinedAt
            let rKey = rhs.lastSuccessfulConnectAt ?? rhs.firstJoinedAt
            return lKey > rKey
        }
    }

    /// Look up a single record by `(serverURL, poolID)`. Returns `nil` if no
    /// record exists.
    public static func record(serverURL: String, poolID: String) -> RemoteMemberRecord? {
        loadAll()[Self.compositeKey(serverURL: serverURL, poolID: poolID)]
    }

    /// Insert or replace a record. Used after a successful first-time join
    /// (when the host approved us) and again after each successful
    /// `member_rejoin` to bump `lastSuccessfulConnectAt`.
    public static func upsert(_ record: RemoteMemberRecord) {
        var all = loadAll()
        all[record.compositeKey] = record
        saveAll(all)
    }

    /// Update `lastSuccessfulConnectAt` on the existing record for the
    /// supplied pool, leaving the rest of the record untouched. No-op if the
    /// record is missing.
    public static func touch(serverURL: String, poolID: String, at date: Date = Date()) {
        var all = loadAll()
        let key = compositeKey(serverURL: serverURL, poolID: poolID)
        guard let existing = all[key] else { return }
        all[key] = RemoteMemberRecord(
            serverURL: existing.serverURL,
            poolID: existing.poolID,
            memberPublicKeyBase64: existing.memberPublicKeyBase64,
            displayName: existing.displayName,
            firstJoinedAt: existing.firstJoinedAt,
            lastSuccessfulConnectAt: date
        )
        saveAll(all)
    }

    /// Remove the record for the supplied pool. Idempotent.
    public static func remove(serverURL: String, poolID: String) {
        var all = loadAll()
        all.removeValue(forKey: compositeKey(serverURL: serverURL, poolID: poolID))
        saveAll(all)
    }

    /// Remove every saved record. Used by tests and by full app-data resets.
    public static func clearAll() {
        if let provider = secureProvider {
            try? provider.save(Data(), forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Compose the `(serverURL, poolID)` lookup key. Exposed so call sites
    /// that already hold the components can avoid building a record just to
    /// derive the key.
    public static func compositeKey(serverURL: String, poolID: String) -> String {
        "\(serverURL):\(poolID)"
    }
}
