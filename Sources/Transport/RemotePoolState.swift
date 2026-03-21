// RemotePoolState.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Persists remote pool connection state across app restarts.

import Foundation

/// Saved state for a remote pool connection.
/// Stored in UserDefaults so the app can auto-reconnect on launch.
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

    /// Save to UserDefaults.
    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Load from UserDefaults.
    public static func load() -> RemotePoolState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(RemotePoolState.self, from: data) else {
            return nil
        }
        return state
    }

    /// Clear saved state.
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
