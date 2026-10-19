// PeerProtocolLedger.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine

// MARK: - Wire Feature

/// A peer-to-peer wire format whose version is negotiated per peer.
///
/// Version numbers are per feature. Version 1 is the format spoken by StealthOS 1.4.x
/// and older; version 2 ships in StealthOS 1.5.0.
public enum WireFeature: String, Sendable, Hashable, CaseIterable, Codable {
    /// `RelayEnvelope` routing integrity (mesh relay).
    case relayEnvelope = "relay_envelope"
    /// Encrypted call media frames.
    case callMedia = "call_media"
    /// The remote pool's WebSocket outer layer (pool transport secret).
    case remoteTransport = "remote_transport"

    /// Highest version this build speaks.
    public var currentVersion: Int { 2 }

    /// Every version this build can still parse.
    public var supportedVersions: [Int] { [1, 2] }
}

// MARK: - Legacy Policy

/// What to do with a peer that has only ever spoken version 1 of a feature.
public enum LegacyPeerPolicy: String, Sendable, Codable {
    /// Accept v1 traffic and flag the peer as running an older, less secure version.
    case warn
    /// Refuse v1 traffic outright.
    case refuse
}

// MARK: - Admission

/// The ledger's verdict on one inbound message or session.
public enum WireAdmission: Sendable, Equatable {
    /// The peer used the current, secure version.
    case accepted(version: Int)
    /// The peer used v1 and has never shown v2; accepted under ``LegacyPeerPolicy/warn``.
    case acceptedLegacy
    /// The peer has shown v2 before and is now sending v1. Always refused.
    case refusedDowngrade
    /// The peer used v1 and policy is ``LegacyPeerPolicy/refuse``.
    case refusedLegacy

    public var isAccepted: Bool {
        switch self {
        case .accepted, .acceptedLegacy: return true
        case .refusedDowngrade, .refusedLegacy: return false
        }
    }
}

// MARK: - Peer Protocol Ledger

/// Remembers, per peer and feature, the highest wire version that peer has proven it
/// speaks, and enforces the downgrade rule: once a peer has been seen speaking v2 through
/// an authenticated channel, v1 from that peer is refused for the rest of the ledger's life.
///
/// Callers must only feed it versions that arrived **authenticated** (a verified v2 MAC, a
/// call signal that decrypted under the peer's E2E key). Otherwise an attacker could pin a
/// peer to v2 and deny service, or worse, never be pinned at all.
///
/// The ledger is process-memory only. StealthOS rotates its E2E identity per pool session,
/// so there is no stable, authenticated peer identity to persist this against.
///
/// Thread safety: `NSLock` around all state (synchronous API, callable from any isolation).
public final class PeerProtocolLedger: @unchecked Sendable {

    private struct Key: Hashable {
        let feature: WireFeature
        let peerID: String
    }

    private let lock = NSLock()
    private var _highestSeen: [Key: Int] = [:]
    private var _legacyPeers: [WireFeature: Set<String>] = [:]
    private var _policy: LegacyPeerPolicy

    private let legacyPeersSubject = PassthroughSubject<(WireFeature, Set<String>), Never>()

    /// Emits `(feature, peers)` whenever the set of peers flagged as legacy changes.
    public var legacyPeersChanged: AnyPublisher<(WireFeature, Set<String>), Never> {
        legacyPeersSubject.eraseToAnyPublisher()
    }

    public init(policy: LegacyPeerPolicy = .warn) {
        self._policy = policy
    }

    /// The policy for peers that have only ever spoken v1.
    public var policy: LegacyPeerPolicy {
        get { lock.withLock { _policy } }
        set { lock.withLock { _policy = newValue } }
    }

    /// Records that `peerID` advertised `versions` for `feature` over an authenticated channel.
    ///
    /// Only raises the remembered version; it never lowers it.
    public func observe(peerID: String, feature: WireFeature, advertisedVersions versions: [Int]) {
        guard let best = versions.filter({ feature.supportedVersions.contains($0) }).max() else { return }
        var changed: Set<String>?
        lock.withLock {
            let key = Key(feature: feature, peerID: peerID)
            if best > (_highestSeen[key] ?? 0) {
                _highestSeen[key] = best
            }
            if best >= 2, _legacyPeers[feature]?.remove(peerID) != nil {
                changed = _legacyPeers[feature] ?? []
            }
        }
        if let changed { legacyPeersSubject.send((feature, changed)) }
    }

    /// Decides whether traffic of `version` from `peerID` is admissible, recording v2 use.
    ///
    /// Call this only after the message authenticated under the claimed version.
    public func admit(peerID: String, feature: WireFeature, version: Int) -> WireAdmission {
        if version >= 2 {
            observe(peerID: peerID, feature: feature, advertisedVersions: [version])
            return .accepted(version: version)
        }
        var changed: Set<String>?
        let verdict: WireAdmission = lock.withLock {
            let key = Key(feature: feature, peerID: peerID)
            if (_highestSeen[key] ?? 0) >= 2 { return .refusedDowngrade }
            if _policy == .refuse { return .refusedLegacy }
            if _highestSeen[key] == nil { _highestSeen[key] = 1 }
            var set = _legacyPeers[feature] ?? []
            if set.insert(peerID).inserted {
                _legacyPeers[feature] = set
                changed = set
            }
            return .acceptedLegacy
        }
        if let changed { legacyPeersSubject.send((feature, changed)) }
        return verdict
    }

    /// The highest version `peerID` has authenticated with, or `nil` if never seen.
    public func highestVersion(of peerID: String, feature: WireFeature) -> Int? {
        lock.withLock { _highestSeen[Key(feature: feature, peerID: peerID)] }
    }

    /// Whether `peerID` has proven it speaks v2 (and so may never fall back to v1).
    public func isPinnedToV2(_ peerID: String, feature: WireFeature) -> Bool {
        (highestVersion(of: peerID, feature: feature) ?? 0) >= 2
    }

    /// Peers currently flagged as running an older, less secure version of `feature`.
    public func legacyPeers(for feature: WireFeature) -> Set<String> {
        lock.withLock { _legacyPeers[feature] ?? [] }
    }

    /// Clears the "legacy" UI flag for one feature (for example once that feature is
    /// protected pool-wide and legacy peers are excluded instead). Pins are kept.
    public func clearLegacyFlag(peerID: String, feature: WireFeature) {
        var changed: Set<String>?
        lock.withLock {
            if _legacyPeers[feature]?.remove(peerID) != nil { changed = _legacyPeers[feature] ?? [] }
        }
        if let changed { legacyPeersSubject.send((feature, changed)) }
    }

    /// Clears the "legacy" UI flag for a peer that left. The downgrade pin is kept.
    public func peerDeparted(_ peerID: String) {
        var changes: [(WireFeature, Set<String>)] = []
        lock.withLock {
            for feature in WireFeature.allCases {
                if _legacyPeers[feature]?.remove(peerID) != nil {
                    changes.append((feature, _legacyPeers[feature] ?? []))
                }
            }
        }
        for change in changes { legacyPeersSubject.send(change) }
    }
}
