// Peer.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Pool User Profile

/// User profile for Pool Chat and Games
/// Stored in SecureDataStore and shared with peers
public struct PoolUserProfile: Codable, Sendable, Equatable {
    /// User's custom display name
    public var displayName: String

    /// Avatar emoji (single emoji character)
    public var avatarEmoji: String

    /// Avatar background color index (0-7)
    public var avatarColorIndex: Int

    /// Available avatar emojis for selection
    public static let availableEmojis: [String] = [
        // People
        "😀", "😎", "🥳", "🤓", "😈", "👻", "🤖", "👽",
        // Animals
        "🦊", "🐱", "🐶", "🐼", "🦁", "🐯", "🐵", "🦄",
        // Objects
        "🎮", "🎯", "🎲", "🎸", "🎨", "🚀", "⚡️", "🔥",
        // Nature
        "🌟", "🌈", "🌙", "☀️", "🌸", "🍀", "💎", "🎭"
    ]

    /// Available avatar colors (no purple/indigo per design mandate).
    public static let availableColors: [Color] = [
        .blue, .green, .orange, .teal, .pink, .cyan, .yellow, .red
    ]

    /// SecureDataStore key for profile
    public static let storageKey = "pool_user_profile"

    public init(
        displayName: String,
        avatarEmoji: String = "😀",
        avatarColorIndex: Int = 0
    ) {
        self.displayName = displayName
        self.avatarEmoji = avatarEmoji
        self.avatarColorIndex = avatarColorIndex % Self.availableColors.count
    }

    /// Cached device name to avoid blocking DNS lookups.
    /// `Host.current().localizedName` performs a synchronous reverse DNS lookup
    /// that can block for 5-6 seconds if DNS is slow or fails.
    /// Computed once via `static let` which is thread-safe by Swift guarantee.
    ///
    /// NOTE: On iOS, UIDevice.current.name requires main actor access in Swift 6.
    /// On macOS, ProcessInfo.hostName is nonisolated and fast.
    private static let _cachedDeviceName: String = {
        #if canImport(UIKit)
        return "iOS User"
        #else
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty && hostName != "localhost" {
            return hostName
        } else {
            return Host.current().localizedName ?? "Mac User"
        }
        #endif
    }()

    /// Get device name (cached, thread-safe)
    private static func getDeviceName() -> String {
        return _cachedDeviceName
    }

    /// Default profile using device name
    public static var defaultProfile: PoolUserProfile {
        return PoolUserProfile(
            displayName: getDeviceName(),
            avatarEmoji: availableEmojis.randomElement() ?? "😀",
            avatarColorIndex: Int.random(in: 0..<availableColors.count)
        )
    }

    /// Get the Color for this profile
    public var avatarColor: Color {
        Self.availableColors[avatarColorIndex % Self.availableColors.count]
    }
}

// MARK: - Peer

/// Represents a peer in the connection pool
public struct Peer: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let isHost: Bool
    public let connectedAt: Date
    public var status: PeerStatus

    /// User's custom profile (optional, received from peer)
    public var profile: PoolUserProfile?

    /// Whether this peer supports mesh relay (advertised during connection)
    public var supportsRelay: Bool

    /// How this peer is connected to us
    public var connectionType: PeerConnectionType

    /// Avatar emoji - uses profile if available, otherwise first letter of name
    public var avatarEmoji: String? {
        profile?.avatarEmoji
    }

    /// Display name to show - uses profile if available
    public var effectiveDisplayName: String {
        profile?.displayName ?? displayName
    }

    /// Avatar color index - uses profile if available, otherwise derived from ID
    public var avatarColorIndex: Int {
        profile?.avatarColorIndex ?? abs(id.hashValue) % 8
    }

    public init(
        id: String,
        displayName: String,
        isHost: Bool = false,
        connectedAt: Date = Date(),
        status: PeerStatus = .connected,
        profile: PoolUserProfile? = nil,
        supportsRelay: Bool = true,
        connectionType: PeerConnectionType = .direct
    ) {
        self.id = id
        self.displayName = displayName
        self.isHost = isHost
        self.connectedAt = connectedAt
        self.status = status
        self.profile = profile
        self.supportsRelay = supportsRelay
        self.connectionType = connectionType
    }

    public static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Status of a peer connection
public enum PeerStatus: String, Sendable, Codable {
    case connecting = "connecting"
    case connected = "connected"
    case disconnected = "disconnected"
    case notConnected = "notConnected"

    public var displayText: String {
        switch self {
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .notConnected: return "Not Connected"
        }
    }

    public var iconName: String {
        switch self {
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .notConnected: return "circle"
        }
    }
}

/// Describes how a peer is connected in the mesh network
public enum PeerConnectionType: String, Codable, Sendable {
    /// Directly connected via MultipeerConnectivity
    case direct

    /// Reachable only through relay peers
    case relayed

    /// Connection type unknown or being determined
    case unknown
}

/// Information about a discovered peer that hasn't joined yet
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let discoveredAt: Date
    public var isInviting: Bool
    /// Whether this pool requires a code to join.
    /// SECURITY: The actual code is never broadcast via Bonjour discovery.
    /// It is sent as invitation context and validated host-side.
    public let hasPoolCode: Bool

    /// Host's profile info (if shared in discovery)
    public var hostProfile: PoolUserProfile?

    // MARK: - Relay Discovery Properties

    /// Whether this peer is a relay (non-host advertising the pool)
    public let isRelay: Bool

    /// Profile of the relay peer (if discovered via relay)
    public var relayProfile: PoolUserProfile?

    /// The original host's peer ID (for relay discoveries)
    public let hostPeerID: String?

    /// Unique pool identifier for deduplication across relay/host discoveries
    public let poolID: String?

    /// Whether this pool supports relay (cascade) discovery
    public let supportsRelay: Bool

    /// Effective display name - uses profile if available
    public var effectiveDisplayName: String {
        hostProfile?.displayName ?? displayName
    }

    /// Avatar emoji from host profile
    public var avatarEmoji: String? {
        hostProfile?.avatarEmoji
    }

    /// Avatar color index from host profile
    public var avatarColorIndex: Int {
        hostProfile?.avatarColorIndex ?? abs(id.hashValue) % 8
    }

    /// Description of connection type for UI display
    public var connectionDescription: String {
        if isRelay, let relayName = relayProfile?.displayName {
            return "via \(relayName)"
        }
        return "direct"
    }

    public init(
        id: String,
        displayName: String,
        discoveredAt: Date = Date(),
        isInviting: Bool = false,
        hasPoolCode: Bool = false,
        hostProfile: PoolUserProfile? = nil,
        isRelay: Bool = false,
        relayProfile: PoolUserProfile? = nil,
        hostPeerID: String? = nil,
        poolID: String? = nil,
        supportsRelay: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.discoveredAt = discoveredAt
        self.isInviting = isInviting
        self.hasPoolCode = hasPoolCode
        self.hostProfile = hostProfile
        self.isRelay = isRelay
        self.relayProfile = relayProfile
        self.hostPeerID = hostPeerID
        self.poolID = poolID
        self.supportsRelay = supportsRelay
    }

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
