// RemotePoolConfiguration.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Remote Pool Configuration

/// Configuration for creating or joining a remote pool via WebSocket relay.
///
/// This struct captures the server URL, pool metadata, and transport settings
/// needed to establish a remote connection through the StealthRelay server.
public struct RemotePoolConfiguration: Sendable {
    /// The WebSocket URL of the relay server (e.g., `wss://relay.stealthos.app/ws`).
    public var serverURL: URL

    /// Human-readable name for the pool.
    public var poolName: String

    /// Maximum number of peers allowed in the pool (including host).
    public var maxPeers: Int

    /// The transport mode. Always `.remote` for this configuration type.
    public var transportMode: TransportMode

    /// Heartbeat interval in seconds. Default is 15 seconds.
    public var heartbeatInterval: TimeInterval

    /// Maximum number of reconnection attempts before giving up.
    public var maxReconnectAttempts: Int

    /// Initial delay for exponential backoff reconnection, in seconds.
    public var initialReconnectDelay: TimeInterval

    /// Maximum delay cap for exponential backoff reconnection, in seconds.
    public var maxReconnectDelay: TimeInterval

    /// Connection timeout in seconds.
    public var connectionTimeout: TimeInterval

    /// Optional SHA-256 hash of the relay server's SPKI (Subject Public Key Info) for TLS
    /// certificate pinning. When set, only connections to servers whose leaf certificate
    /// matches this pin are accepted. When `nil`, standard CA validation applies.
    public var pinnedSPKIHash: Data?

    /// Creates a remote pool configuration.
    ///
    /// - Parameters:
    ///   - serverURL: The WebSocket URL of the relay server.
    ///   - poolName: Human-readable name for the pool.
    ///   - maxPeers: Maximum number of peers (default: 8).
    ///   - heartbeatInterval: Seconds between heartbeat pings (default: 15).
    ///   - maxReconnectAttempts: Maximum reconnection attempts (default: 5).
    ///   - initialReconnectDelay: Initial backoff delay in seconds (default: 1).
    ///   - maxReconnectDelay: Maximum backoff delay in seconds (default: 30).
    ///   - connectionTimeout: Connection timeout in seconds (default: 15).
    public init(
        serverURL: URL,
        poolName: String,
        maxPeers: Int = 8,
        heartbeatInterval: TimeInterval = 15,
        maxReconnectAttempts: Int = 5,
        initialReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 30,
        connectionTimeout: TimeInterval = 15,
        pinnedSPKIHash: Data? = nil
    ) {
        self.serverURL = serverURL
        self.poolName = poolName
        self.maxPeers = maxPeers
        self.transportMode = .remote
        self.heartbeatInterval = heartbeatInterval
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialReconnectDelay = initialReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.connectionTimeout = connectionTimeout
        self.pinnedSPKIHash = pinnedSPKIHash
    }

    /// Convenience factory for creating a remote configuration with defaults.
    ///
    /// - Parameters:
    ///   - serverURL: The WebSocket URL of the relay server.
    ///   - poolName: Human-readable name for the pool.
    ///   - maxPeers: Maximum number of peers (default: 8).
    /// - Returns: A configured ``RemotePoolConfiguration``.
    public static func remote(serverURL: URL, poolName: String, maxPeers: Int = 8) -> Self {
        Self(serverURL: serverURL, poolName: poolName, maxPeers: maxPeers)
    }
}
