// TransportTypes.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Transport State

/// Represents the current state of a transport layer connection.
public enum TransportState: Sendable, Equatable {
    /// Transport is idle and not connected.
    case idle

    /// Transport is advertising a pool to potential peers.
    case advertising

    /// Transport is discovering available pools.
    case discovering

    /// Transport is in the process of connecting to a pool.
    case connecting

    /// Transport is fully connected and operational.
    case connected

    /// Transport is attempting to reconnect after a disconnection.
    case reconnecting(attempt: Int)

    /// Transport has encountered a fatal error.
    case failed(TransportError)

    /// Human-readable description of the current state.
    public var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .advertising: return "Advertising"
        case .discovering: return "Discovering"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))"
        case .failed(let error): return "Failed: \(error.localizedDescription)"
        }
    }

    /// Whether the transport is in an active (non-idle, non-failed) state.
    public var isActive: Bool {
        switch self {
        case .advertising, .discovering, .connecting, .connected, .reconnecting:
            return true
        case .idle, .failed:
            return false
        }
    }

    public static func == (lhs: TransportState, rhs: TransportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.advertising, .advertising): return true
        case (.discovering, .discovering): return true
        case (.connecting, .connecting): return true
        case (.connected, .connected): return true
        case (.reconnecting(let a), .reconnecting(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Transport Peer

/// A peer connected through the transport layer.
public struct TransportPeer: Sendable, Equatable, Identifiable {
    /// Unique identifier for this peer within the transport session.
    public let id: String

    /// Human-readable display name for the peer.
    public let displayName: String

    /// How this peer is connected (direct local or via relay server).
    public let connectionType: PeerConnectionType

    /// The peer's public key for identity verification (base64-encoded).
    public let publicKey: String?

    /// Timestamp when this peer connected.
    public let connectedAt: Date

    public init(
        id: String,
        displayName: String,
        connectionType: PeerConnectionType,
        publicKey: String? = nil,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.connectionType = connectionType
        self.publicKey = publicKey
        self.connectedAt = connectedAt
    }
}

// MARK: - Transport Mode

/// The mode of transport for pool connectivity.
public enum TransportMode: String, Sendable, Codable, CaseIterable {
    /// Local peer-to-peer via MultipeerConnectivity (Bluetooth/WiFi).
    case local

    /// Remote connectivity via WebSocket relay server.
    case remote
}

// MARK: - Transport Error

/// Errors that can occur in the transport layer.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection to the peer or server failed.
    case connectionFailed

    /// Authentication with the server or peer was rejected.
    case authenticationFailed

    /// The connection or operation timed out.
    case timeout

    /// The relay server is unreachable.
    case serverUnreachable

    /// The invitation token is invalid or malformed.
    case invalidToken

    /// The session token has expired and reconnection requires re-authentication.
    case sessionExpired

    /// The protocol version does not match between client and server.
    case protocolMismatch

    /// This peer was kicked from the pool.
    case kicked

    /// The server has not been claimed yet and requires a one-time claim code.
    case serverUnclaimed

    /// An underlying system error occurred.
    case underlying(WrappedError)

    public var description: String {
        switch self {
        case .connectionFailed: return "Connection failed"
        case .authenticationFailed: return "Authentication failed"
        case .timeout: return "Connection timed out"
        case .serverUnreachable: return "Server unreachable"
        case .invalidToken: return "Invalid invitation token"
        case .sessionExpired: return "Session expired"
        case .protocolMismatch: return "Protocol version mismatch"
        case .kicked: return "Kicked from pool"
        case .serverUnclaimed: return "Server not yet claimed"
        case .underlying(let wrapped): return "Error: \(wrapped.message)"
        }
    }

    public var localizedDescription: String { description }

    public static func == (lhs: TransportError, rhs: TransportError) -> Bool {
        switch (lhs, rhs) {
        case (.connectionFailed, .connectionFailed),
             (.authenticationFailed, .authenticationFailed),
             (.timeout, .timeout),
             (.serverUnreachable, .serverUnreachable),
             (.invalidToken, .invalidToken),
             (.sessionExpired, .sessionExpired),
             (.protocolMismatch, .protocolMismatch),
             (.kicked, .kicked),
             (.serverUnclaimed, .serverUnclaimed):
            return true
        case (.underlying(let a), .underlying(let b)):
            return a.message == b.message
        default:
            return false
        }
    }

    /// Create a transport error wrapping a non-Sendable system error.
    public static func from(_ error: any Error) -> TransportError {
        .underlying(WrappedError(message: error.localizedDescription))
    }
}

/// A Sendable wrapper around an error message, used to make ``TransportError`` fully Sendable.
public struct WrappedError: Sendable, Equatable {
    /// The localized description of the original error.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Pool Advertisement Info

/// Information advertised by a host when creating a pool.
public struct PoolAdvertisementInfo: Sendable {
    /// Unique identifier for this pool.
    public let poolID: UUID

    /// Human-readable pool name.
    public let poolName: String

    /// Display name of the host.
    public let hostName: String

    /// Whether the pool requires a code to join.
    public let hasPoolCode: Bool

    /// Maximum number of peers allowed in the pool (including host).
    public let maxPeers: Int

    /// The host's user profile, if available.
    public let hostProfile: PoolUserProfile?

    public init(
        poolID: UUID,
        poolName: String,
        hostName: String,
        hasPoolCode: Bool = false,
        maxPeers: Int = 8,
        hostProfile: PoolUserProfile? = nil
    ) {
        self.poolID = poolID
        self.poolName = poolName
        self.hostName = hostName
        self.hasPoolCode = hasPoolCode
        self.maxPeers = maxPeers
        self.hostProfile = hostProfile
    }
}

// MARK: - Discovered Pool

/// A pool discovered through the transport layer.
public struct DiscoveredPool: Sendable, Identifiable, Equatable {
    /// Unique identifier for the discovered pool.
    public let id: String

    /// Human-readable pool name.
    public let name: String

    /// Display name of the host.
    public let hostName: String

    /// Whether the pool requires a code to join.
    public let hasPoolCode: Bool

    /// The transport mode used to discover this pool.
    public let transportMode: TransportMode

    /// The host's user profile, if available.
    public let hostProfile: PoolUserProfile?

    /// The relay server URL (only set for remote pools).
    public let serverURL: URL?

    public init(
        id: String,
        name: String,
        hostName: String,
        hasPoolCode: Bool = false,
        transportMode: TransportMode,
        hostProfile: PoolUserProfile? = nil,
        serverURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.hasPoolCode = hasPoolCode
        self.transportMode = transportMode
        self.hostProfile = hostProfile
        self.serverURL = serverURL
    }

    public static func == (lhs: DiscoveredPool, rhs: DiscoveredPool) -> Bool {
        lhs.id == rhs.id
    }
}
