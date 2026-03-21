// MeshRelayService.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine
import CryptoKit

// MARK: - Message Deduplication Cache

/// Thread-safe cache for tracking processed message IDs to prevent loops.
///
/// Uses insertion-ordered tracking for O(1) amortized eviction instead of O(n log n) sort.
///
/// SAFETY: @unchecked Sendable is required because:
/// 1. The class maintains mutable state (seenMessages dictionary, insertionOrder array)
/// 2. It may be accessed from multiple actors/tasks during relay operations
/// 3. All mutable state is protected by NSLock for thread-safe access
final class MessageDeduplicationCache: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()
    /// Maps message ID to its timestamp for expiration checks.
    private var seenMessages: [UUID: Date] = [:]
    /// Tracks insertion order for O(1) eviction of oldest entries.
    private var insertionOrder: [UUID] = []
    private let expirationInterval: TimeInterval = 300 // 5 minutes

    /// Maximum number of entries allowed in the cache. When exceeded, the oldest entries are evicted.
    private let maxCacheSize: Int = 10_000

    // MARK: - Public API

    /// Check if message has already been processed.
    /// - Parameter messageID: The message ID to check.
    /// - Returns: `true` if the message has been processed within the expiration window.
    func hasProcessed(_ messageID: UUID) -> Bool {
        lock.withLock {
            guard let timestamp = seenMessages[messageID] else { return false }
            // Check if the entry has expired
            if Date().timeIntervalSince(timestamp) > expirationInterval {
                seenMessages.removeValue(forKey: messageID)
                // Note: expired entry remains in insertionOrder as a tombstone,
                // cleaned up during eviction or pruning
                return false
            }
            return true
        }
    }

    /// Mark message as processed.
    ///
    /// If the cache exceeds `maxCacheSize`, the oldest entries are evicted in O(1) amortized
    /// by removing from the front of the insertion-order queue.
    /// - Parameter messageID: The message ID to mark as processed.
    func markProcessed(_ messageID: UUID) {
        lock.withLock {
            let now = Date()
            if seenMessages[messageID] == nil {
                // New entry: add to insertion order
                insertionOrder.append(messageID)
            }
            seenMessages[messageID] = now

            // Evict oldest entries when cache exceeds maximum size.
            // O(1) amortized: remove from the front of the insertion order queue.
            while seenMessages.count > maxCacheSize, !insertionOrder.isEmpty {
                let oldest = insertionOrder.removeFirst()
                // Only remove from dict if it still exists (may have been expired already)
                seenMessages.removeValue(forKey: oldest)
            }
        }
    }

    /// Remove expired entries (called periodically).
    func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-expirationInterval)
        lock.withLock {
            seenMessages = seenMessages.filter { $0.value > cutoff }
            // Compact the insertion order by removing entries no longer in the dict
            insertionOrder.removeAll { seenMessages[$0] == nil }
        }
    }

    /// Current count of cached message IDs (for diagnostics).
    var count: Int {
        lock.withLock { seenMessages.count }
    }
}

// MARK: - Mesh Relay Service

/// Service for relaying encrypted messages through the mesh network.
///
/// `MeshRelayService` coordinates message routing, loop prevention, and topology
/// management for the mesh relay layer. It enables messages to reach peers that
/// are not directly connected by routing through intermediate nodes.
///
/// Key responsibilities:
/// - Sending messages to peers (direct or relayed)
/// - Receiving and processing incoming relay envelopes
/// - Preventing message loops via deduplication and hop path tracking
/// - Maintaining mesh topology awareness
/// - Broadcasting topology information to neighbors
@MainActor
public final class MeshRelayService: ObservableObject {
    
    // MARK: - Dependencies
    
    private weak var poolManager: ConnectionPoolManager?
    private let topology: MeshTopology
    private let deduplicationCache: MessageDeduplicationCache
    private let localPeerID: String

    /// Pool-level shared secret for HMAC envelope integrity.
    /// Must be set before sending/receiving envelopes. Derived from a secret
    /// established during pool creation/joining — never transmitted on the wire.
    public var poolSharedSecret: SymmetricKey?
    
    // MARK: - Published State
    
    /// Total count of messages successfully relayed through this node.
    @Published public private(set) var relayedMessageCount: Int = 0
    
    /// Total count of messages dropped (loops, TTL, expiry, etc.).
    @Published public private(set) var droppedMessageCount: Int = 0
    
    // MARK: - Publishers
    
    /// Emits relay envelopes that are destined for THIS peer (after relay chain).
    public let receivedEnvelope = PassthroughSubject<RelayEnvelope, Never>()
    
    /// Emits when a message couldn't be delivered (no path found).
    public let deliveryFailed = PassthroughSubject<(messageID: UUID, destinationPeerID: String), Never>()
    
    // MARK: - Private State

    /// Tracks the last accepted topology broadcast timestamp per peer.
    /// Used to reject stale or replayed topology broadcasts.
    private var lastTopologyTimestamp: [String: Date] = [:]

    /// Maximum age for a topology broadcast (2x the 60s broadcast interval).
    /// Broadcasts older than this are considered stale and rejected.
    private let topologyBroadcastMaxAge: TimeInterval = 120.0

    private var cancellables = Set<AnyCancellable>()
    private var topologyBroadcastTimer: Timer?
    private var pruneTimer: Timer?
    private var currentPoolID: UUID?
    
    /// Interval between topology broadcasts (60 seconds).
    /// Increased from 30s to reduce network chatter during DTLS stabilization periods.
    private let topologyBroadcastInterval: TimeInterval = 60.0
    
    /// Interval between cache pruning operations (60 seconds).
    private let pruneInterval: TimeInterval = 60.0
    
    // MARK: - Initialization
    
    /// Creates a new mesh relay service.
    /// - Parameter localPeerID: The ID of the local peer in the mesh network.
    public init(localPeerID: String) {
        self.localPeerID = localPeerID
        self.topology = MeshTopology(localPeerID: localPeerID)
        self.deduplicationCache = MessageDeduplicationCache()
        // Note: Timers are started lazily in setPoolManager to avoid blocking
        // initialization and to ensure proper run loop scheduling
    }
    
    /// Cleanup method to be called before deallocation.
    /// Since deinit is nonisolated and Timer is not Sendable,
    /// we must clean up timers from the MainActor context.
    public func cleanup() {
        topologyBroadcastTimer?.invalidate()
        topologyBroadcastTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }
    
    /// Sets the pool manager reference for sending messages.
    /// - Parameter manager: The connection pool manager to use for sending.
    public func setPoolManager(_ manager: ConnectionPoolManager) {
        self.poolManager = manager
        // Start the prune timer now that we have a pool manager
        // This is deferred from init to avoid blocking during initialization
        startPruneTimer()
    }
    
    /// Sets the current pool ID for envelope validation.
    /// - Parameter poolID: The pool ID to use for outgoing envelopes.
    public func setCurrentPool(_ poolID: UUID) {
        self.currentPoolID = poolID
        startTopologyBroadcastTimer()
    }
    
    /// Clears the current pool and stops periodic broadcasts.
    public func clearCurrentPool() {
        self.currentPoolID = nil
        self.poolSharedSecret = nil
        self.lastTopologyTimestamp = [:]
        stopTopologyBroadcastTimer()
    }
    
    // MARK: - Sending
    
    /// Send encrypted payload to a specific peer (direct or relayed).
    ///
    /// This method determines the best route to the destination peer and sends
    /// the payload either directly or through relay hops as needed.
    ///
    /// - Parameters:
    ///   - peerID: The destination peer ID.
    ///   - payload: The encrypted payload data to send.
    ///   - poolID: The pool ID for the message.
    /// - Returns: `true` if the message was sent (not necessarily delivered), `false` if no path found.
    public func sendToPeer(_ peerID: String, payload: Data, poolID: UUID) async -> Bool {
        guard let poolManager = poolManager else {
            log("Cannot send: pool manager not set", level: .warning, category: .network)
            return false
        }
        
        // Check if peer is directly reachable
        if topology.canReachDirectly(peerID) {
            // Direct send - no envelope needed, just send the payload
            log("Sending direct message to peer: \(peerID.prefix(8))...", category: .network)
            
            let message = PoolMessage.relayPayload(
                from: localPeerID,
                senderName: poolManager.localPeerName,
                payload: payload
            )
            poolManager.sendMessage(message, to: [peerID])
            return true
        }
        
        // Find relay path
        guard let path = topology.findPath(to: peerID) else {
            log("No path found to peer: \(peerID.prefix(8))...", level: .warning, category: .network)
            deliveryFailed.send((messageID: UUID(), destinationPeerID: peerID))
            return false
        }
        
        guard let firstHop = path.first else {
            log("Empty path returned for peer: \(peerID.prefix(8))...", level: .error, category: .network)
            return false
        }
        
        // SECURITY: Require a pool-level shared secret for HMAC integrity protection.
        // Without a shared secret, we cannot produce a valid HMAC and the receiver would reject the envelope.
        guard let sharedSecret = poolSharedSecret else {
            log("[SECURITY] Cannot send relay envelope: no pool shared secret set", level: .warning, category: .network)
            return false
        }

        // Create relay envelope with HMAC integrity protection
        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)
        let envelope = RelayEnvelope(
            originPeerID: localPeerID,
            destinationPeerID: peerID,
            hopPath: [localPeerID],
            encryptedPayload: payload,
            poolID: poolID
        ).withHMAC(using: hmacKey)

        // Mark as processed to prevent echo
        deduplicationCache.markProcessed(envelope.messageID)

        // Send to first hop
        log("Sending relayed message to \(peerID.prefix(8))... via \(firstHop.prefix(8))..., hops: \(path.count)", category: .network)
        sendEnvelopeToNeighbor(envelope, neighborID: firstHop)

        return true
    }
    
    /// Broadcast encrypted payload to all peers in the pool.
    ///
    /// This creates a broadcast envelope that will be relayed to all reachable
    /// peers in the mesh network.
    ///
    /// - Parameters:
    ///   - payload: The encrypted payload data to broadcast.
    ///   - poolID: The pool ID for the message.
    public func broadcast(_ payload: Data, poolID: UUID) async {
        guard poolManager != nil else {
            log("Cannot broadcast: pool manager not set", level: .warning, category: .network)
            return
        }
        
        // SECURITY: Require a pool-level shared secret for HMAC integrity protection.
        guard let sharedSecret = poolSharedSecret else {
            log("[SECURITY] Cannot broadcast relay envelope: no pool shared secret set", level: .warning, category: .network)
            return
        }

        // Create broadcast envelope (nil destination) with HMAC integrity protection
        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)
        let envelope = RelayEnvelope(
            originPeerID: localPeerID,
            destinationPeerID: nil,
            hopPath: [localPeerID],
            encryptedPayload: payload,
            poolID: poolID
        ).withHMAC(using: hmacKey)
        
        // Mark as processed to prevent echo
        deduplicationCache.markProcessed(envelope.messageID)
        
        let neighbors = topology.directNeighbors
        log("Broadcasting message to \(neighbors.count) neighbors", category: .network)
        
        // Send to all direct neighbors
        for neighborID in neighbors {
            if shouldRelay(envelope, to: neighborID) {
                sendEnvelopeToNeighbor(envelope, neighborID: neighborID)
            }
        }
    }
    
    // MARK: - Receiving
    
    /// Handle incoming relay envelope from a neighbor.
    ///
    /// This method processes incoming envelopes, determines if they should be
    /// delivered locally, relayed forward, or dropped.
    ///
    /// - Parameters:
    ///   - envelope: The received relay envelope.
    ///   - senderPeerID: The peer ID of the direct neighbor that sent this envelope.
    public func handleRelayEnvelope(_ envelope: RelayEnvelope, from senderPeerID: String) {
        // SECURITY FIX: Reject all envelopes when not in a pool.
        // Accepting messages without a pool ID allows cross-pool injection attacks.
        guard let currentPoolID = currentPoolID else {
            log("[SECURITY] Dropping relay envelope: no active pool (possible cross-pool injection). messageID: \(envelope.messageID)",
                level: .warning, category: .network)
            droppedMessageCount += 1
            return
        }

        // Validate pool ID
        if envelope.poolID != currentPoolID {
            log("Dropping envelope: pool ID mismatch", level: .debug, category: .network)
            droppedMessageCount += 1
            return
        }

        // SECURITY: Require pool shared secret for HMAC verification.
        guard let sharedSecret = poolSharedSecret else {
            log("[SECURITY] Dropping envelope: no pool shared secret set. messageID: \(envelope.messageID)",
                level: .warning, category: .network)
            droppedMessageCount += 1
            return
        }

        // SECURITY: ALL envelopes MUST have a valid HMAC. Reject unsigned envelopes.
        guard envelope.hasHMAC else {
            log("[SECURITY] Dropping envelope: missing HMAC (unsigned). messageID: \(envelope.messageID)",
                level: .warning, category: .network)
            droppedMessageCount += 1
            return
        }

        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: currentPoolID)
        guard envelope.verifyHMAC(using: hmacKey) else {
            log("[SECURITY] Dropping envelope: HMAC verification failed (tampered metadata). messageID: \(envelope.messageID)",
                level: .warning, category: .network)
            droppedMessageCount += 1
            return
        }

        // Check deduplication cache
        if deduplicationCache.hasProcessed(envelope.messageID) {
            log("Dropping duplicate envelope: \(envelope.messageID)", level: .debug, category: .network)
            droppedMessageCount += 1
            return
        }
        
        // Mark as processed
        deduplicationCache.markProcessed(envelope.messageID)
        
        // Check if message is expired
        if envelope.isExpired {
            log("Dropping expired envelope: \(envelope.messageID)", level: .debug, category: .network)
            droppedMessageCount += 1
            return
        }
        
        // Check if we are the destination or it's a broadcast
        let isForUs = envelope.isIntendedFor(localPeerID)
        
        if isForUs {
            // Deliver locally
            log("Received envelope for local peer, origin: \(envelope.originPeerID.prefix(8))...", category: .network)
            receivedEnvelope.send(envelope)
        }
        
        // For broadcasts, we both deliver locally AND relay forward
        // For directed messages, only relay if we're not the final destination
        let shouldRelayForward = envelope.isBroadcast || !isForUs
        
        if shouldRelayForward {
            relayEnvelopeForward(envelope, receivedFrom: senderPeerID)
        }
    }
    
    // MARK: - Loop Prevention
    
    /// Check if this envelope should be relayed to a specific peer.
    ///
    /// Multi-layer prevention checks:
    /// - TTL > 0
    /// - Not expired (< 5 min old)
    /// - Message ID not in deduplication cache (already checked during receive)
    /// - Pool ID matches our pool
    /// - Origin is not us
    /// - Target peer not in hop path
    /// - We're not already in hop path (checked implicitly by forwarding)
    ///
    /// - Parameters:
    ///   - envelope: The envelope to check.
    ///   - peerID: The target peer ID for relay.
    /// - Returns: `true` if the envelope should be relayed to this peer.
    private func shouldRelay(_ envelope: RelayEnvelope, to peerID: String) -> Bool {
        // TTL check
        guard envelope.ttl > 0 else {
            log("Relay blocked: TTL exhausted", level: .debug, category: .network)
            return false
        }
        
        // Expiry check
        guard !envelope.isExpired else {
            log("Relay blocked: message expired", level: .debug, category: .network)
            return false
        }
        
        // Pool ID check - require active pool and matching ID
        guard let currentPoolID = currentPoolID else {
            log("Relay blocked: no active pool", level: .debug, category: .network)
            return false
        }
        if envelope.poolID != currentPoolID {
            log("Relay blocked: pool ID mismatch", level: .debug, category: .network)
            return false
        }
        
        // Origin check - don't relay back to origin
        guard envelope.originPeerID != peerID else {
            log("Relay blocked: target is origin", level: .debug, category: .network)
            return false
        }
        
        // Hop path check - don't relay to peers already in path
        guard !envelope.hopPath.contains(peerID) else {
            log("Relay blocked: target \(peerID.prefix(8))... already in hop path", level: .debug, category: .network)
            return false
        }
        
        // Don't relay to ourselves
        guard peerID != localPeerID else {
            return false
        }
        
        return true
    }
    
    // MARK: - Topology Management
    
    /// Called when a direct peer connects.
    /// - Parameter peerID: The peer ID that connected.
    /// STABILITY FIX: Topology broadcast is delayed to allow MC DTLS transport to stabilize.
    /// Without this delay, sending immediately after peer connect causes "Not in connected state" errors.
    /// The delay (3500ms) is set to be after the DTLS stabilization period (2500ms) + buffer.
    public func peerConnected(_ peerID: String) {
        topology.addDirectConnection(peerID)
        let connectTime = Date()
        log("Peer connected to mesh: \(peerID.prefix(8))...", category: .network)

        // Broadcast topology update to neighbors with delay
        // Delay must be AFTER DTLS stabilization (2500ms) to avoid "No route to host" errors
        Task { @MainActor in
            log("[CALLER_TRACE] MeshRelayService.peerConnected: starting 3500ms delay for topology broadcast (peerID: \(peerID.prefix(8))..., connected at \(connectTime))", category: .network)
            try? await Task.sleep(for: .milliseconds(3500))

            // Verify peer is still connected before broadcasting
            guard let pm = self.poolManager,
                  pm.poolState == .hosting || pm.poolState == .connected else {
                log("Topology broadcast skipped - pool state changed", level: .debug, category: .network)
                return
            }

            let sendTime = Date()
            let elapsed = sendTime.timeIntervalSince(connectTime)
            log("[CALLER_TRACE] MeshRelayService.peerConnected: sending topology broadcast after \(String(format: "%.0f", elapsed * 1000))ms", category: .network)
            self.broadcastTopology()
        }
    }
    
    /// Called when a direct peer disconnects.
    /// - Parameter peerID: The peer ID that disconnected.
    public func peerDisconnected(_ peerID: String) {
        topology.removePeer(peerID)
        lastTopologyTimestamp.removeValue(forKey: peerID)
        log("Peer disconnected from mesh: \(peerID.prefix(8))...", category: .network)
        
        // Broadcast topology update to neighbors
        broadcastTopology()
    }
    
    /// Update topology from a received broadcast.
    ///
    /// SECURITY: Uses `authenticatedSenderID` from the transport layer (PoolMessage.senderID)
    /// rather than the self-reported `broadcast.peerID` for all routing and rate-limiting decisions.
    /// This prevents a pool member from poisoning the routing table by claiming to be another peer.
    ///
    /// Validates broadcast freshness before applying:
    /// 1. Rejects broadcasts older than `topologyBroadcastMaxAge` (120s) to prevent replay attacks.
    /// 2. Rejects broadcasts with a timestamp older than the last seen from the same peer,
    ///    preventing injection of stale routing information.
    ///
    /// - Parameters:
    ///   - broadcast: The topology broadcast message.
    ///   - authenticatedSenderID: The transport-authenticated peer ID of the sender
    ///     (from PoolMessage.senderID, verified by the MC session delegate).
    public func handleTopologyBroadcast(_ broadcast: TopologyBroadcast, from authenticatedSenderID: String) {
        // SECURITY: Detect topology spoofing — the self-reported peerID in the broadcast payload
        // must match the transport-authenticated sender. If they differ, someone is trying to
        // inject routing information on behalf of another peer.
        if broadcast.peerID != authenticatedSenderID {
            log("[SECURITY] Topology spoofing detected: broadcast claims peerID \(broadcast.peerID.prefix(8))... but authenticated sender is \(authenticatedSenderID.prefix(8)).... Dropping.",
                level: .warning, category: .network)
            return
        }

        let now = Date()
        let broadcastAge = now.timeIntervalSince(broadcast.timestamp)

        // Reject broadcasts that are too old (stale or replayed)
        if broadcastAge > topologyBroadcastMaxAge {
            log("[SECURITY] Dropping stale topology broadcast from \(authenticatedSenderID.prefix(8))...: age \(String(format: "%.0f", broadcastAge))s exceeds \(topologyBroadcastMaxAge)s limit",
                level: .warning, category: .network)
            return
        }

        // Reject broadcasts with a future timestamp (clock skew tolerance: 10s)
        if broadcastAge < -10.0 {
            log("[SECURITY] Dropping topology broadcast from \(authenticatedSenderID.prefix(8))...: timestamp is \(String(format: "%.0f", -broadcastAge))s in the future",
                level: .warning, category: .network)
            return
        }

        // Reject broadcasts older than the last one we accepted from this peer
        // SECURITY: Keyed by authenticatedSenderID, not self-reported broadcast.peerID
        if let lastTimestamp = lastTopologyTimestamp[authenticatedSenderID],
           broadcast.timestamp <= lastTimestamp {
            log("[SECURITY] Dropping outdated topology broadcast from \(authenticatedSenderID.prefix(8))...: stale timestamp",
                level: .debug, category: .network)
            return
        }

        // Accept the broadcast and update tracking using the authenticated sender ID
        lastTopologyTimestamp[authenticatedSenderID] = broadcast.timestamp

        let neighbors = Set(broadcast.directNeighbors)
        topology.updateNeighbors(for: authenticatedSenderID, neighbors: neighbors)
        log("Updated topology for peer: \(authenticatedSenderID.prefix(8))..., neighbors: \(broadcast.directNeighbors.count)", level: .debug, category: .network)
    }
    
    /// Broadcast our topology to all direct neighbors.
    public func broadcastTopology() {
        guard let poolManager = poolManager else { return }

        let directNeighbors = Array(topology.directNeighbors)
        let broadcast = TopologyBroadcast(
            peerID: localPeerID,
            directNeighbors: directNeighbors
        )

        // Encode the topology broadcast
        guard let broadcastData = try? JSONEncoder().encode(broadcast) else {
            log("Failed to encode topology broadcast", level: .error, category: .network)
            return
        }

        // Create topology broadcast message
        let message = PoolMessage.topologyBroadcast(
            from: localPeerID,
            senderName: poolManager.localPeerName,
            payload: broadcastData
        )

        log("[CALLER_TRACE] MeshRelayService.broadcastTopology() sending topology with \(directNeighbors.count) neighbors", category: .network)
        poolManager.sendMessage(message)
        log("Broadcast topology: \(directNeighbors.count) neighbors", level: .debug, category: .network)
    }

    /// Process a received system message to check if it's a topology broadcast.
    ///
    /// Call this method when receiving `.system` type messages to check if
    /// they contain topology information.
    ///
    /// SECURITY: Uses `message.senderID` as the transport-authenticated sender identity.
    /// The `senderID` field in `PoolMessage` is set by the MC session delegate based on
    /// the transport-level peer identity, not self-reported by the sender in the payload.
    ///
    /// - Parameter message: The received pool message.
    public func processSystemMessage(_ message: PoolMessage) {
        guard message.type == .system else { return }

        if let topologyBroadcast = TopologyBroadcastWrapper.unwrap(message.payload) {
            handleTopologyBroadcast(topologyBroadcast, from: message.senderID)
        }
    }
    
    /// Check if peer is reachable (directly or via relay).
    /// - Parameter peerID: The peer ID to check.
    /// - Returns: `true` if the peer can be reached.
    public func canReach(_ peerID: String) -> Bool {
        if peerID == localPeerID { return true }
        return topology.findPath(to: peerID) != nil
    }
    
    /// Check if peer is directly connected.
    /// - Parameter peerID: The peer ID to check.
    /// - Returns: `true` if the peer is a direct neighbor.
    public func isDirectlyConnected(_ peerID: String) -> Bool {
        topology.canReachDirectly(peerID)
    }
    
    /// Get the current mesh topology for debugging/display.
    public var meshTopology: MeshTopology {
        topology
    }
    
    // MARK: - Private Helpers
    
    /// Forward an envelope to appropriate next hops.
    private func relayEnvelopeForward(_ envelope: RelayEnvelope, receivedFrom senderPeerID: String) {
        // Create forwarded envelope with decremented TTL and updated hop path
        guard let forwardedEnvelope = envelope.forwarded(by: localPeerID) else {
            log("Cannot relay: TTL would be exhausted", level: .debug, category: .network)
            droppedMessageCount += 1
            return
        }
        
        if let destination = envelope.destinationPeerID {
            // Directed message - find best next hop
            if let path = topology.findPath(to: destination), let nextHop = path.first {
                if shouldRelay(forwardedEnvelope, to: nextHop) {
                    sendEnvelopeToNeighbor(forwardedEnvelope, neighborID: nextHop)
                    relayedMessageCount += 1
                    log("Relayed directed message toward \(destination.prefix(8))... via \(nextHop.prefix(8))...", category: .network)
                }
            } else {
                log("No path to destination \(destination.prefix(8))..., dropping", level: .warning, category: .network)
                droppedMessageCount += 1
            }
        } else {
            // Broadcast - send to all neighbors except sender and those in hop path
            var relayedCount = 0
            for neighborID in topology.directNeighbors {
                // Skip the sender to avoid immediate echo
                guard neighborID != senderPeerID else { continue }
                
                if shouldRelay(forwardedEnvelope, to: neighborID) {
                    sendEnvelopeToNeighbor(forwardedEnvelope, neighborID: neighborID)
                    relayedCount += 1
                }
            }
            
            if relayedCount > 0 {
                relayedMessageCount += 1
                log("Relayed broadcast to \(relayedCount) neighbors", category: .network)
            }
        }
    }
    
    /// Send an envelope to a specific neighbor.
    private func sendEnvelopeToNeighbor(_ envelope: RelayEnvelope, neighborID: String) {
        guard let poolManager = poolManager else { return }
        guard let data = envelope.encode() else {
            log("Failed to encode relay envelope", level: .error, category: .network)
            return
        }

        let message = PoolMessage.relayEnvelope(
            from: localPeerID,
            senderName: poolManager.localPeerName,
            envelopeData: data
        )

        log("[CALLER_TRACE] MeshRelayService.sendEnvelopeToNeighbor() to \(neighborID.prefix(8))...", category: .network)
        poolManager.sendMessage(message, to: [neighborID])
    }
    
    // MARK: - Timers
    
    private func startTopologyBroadcastTimer() {
        stopTopologyBroadcastTimer()
        
        // Use a weak reference to avoid retain cycle
        topologyBroadcastTimer = Timer.scheduledTimer(
            withTimeInterval: topologyBroadcastInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastTopology()
                self?.topology.pruneStale()
            }
        }
        
        log("Started topology broadcast timer (interval: \(topologyBroadcastInterval)s)", level: .debug, category: .network)
    }
    
    private func stopTopologyBroadcastTimer() {
        topologyBroadcastTimer?.invalidate()
        topologyBroadcastTimer = nil
    }
    
    private func startPruneTimer() {
        // Guard against multiple timer starts
        guard pruneTimer == nil else { return }

        pruneTimer = Timer.scheduledTimer(
            withTimeInterval: pruneInterval,
            repeats: true
        ) { [weak self] _ in
            self?.deduplicationCache.pruneExpired()
        }
    }
}

// MARK: - PoolMessage Extensions for Relay

extension PoolMessage {
    /// Creates a relay envelope message using the existing `.relay` type.
    ///
    /// This wraps a `RelayEnvelope` for transmission through the mesh network.
    /// The envelope data should be encoded before calling this method.
    ///
    /// - Parameters:
    ///   - senderID: The peer ID of the immediate sender (relay node).
    ///   - senderName: The display name of the immediate sender.
    ///   - envelopeData: The JSON-encoded `RelayEnvelope` data.
    /// - Returns: A configured `PoolMessage` with type `.relay`.
    static func relayEnvelope(from senderID: String, senderName: String, envelopeData: Data) -> PoolMessage {
        PoolMessage(
            type: .relay,
            senderID: senderID,
            senderName: senderName,
            payload: envelopeData
        )
    }

    /// Creates a topology broadcast message.
    ///
    /// Topology broadcasts share neighbor information between peers in the mesh
    /// network, enabling multi-hop routing decisions.
    ///
    /// - Parameters:
    ///   - senderID: The peer ID broadcasting its topology.
    ///   - senderName: The display name of the sender.
    ///   - payload: The JSON-encoded `TopologyBroadcast` data.
    /// - Returns: A configured `PoolMessage` with type `.system`.
    static func topologyBroadcast(from senderID: String, senderName: String, payload: Data) -> PoolMessage {
        // Use system message type with a topology broadcast payload wrapper
        let wrapper = TopologyBroadcastWrapper(topologyData: payload)
        let wrappedData = (try? JSONEncoder().encode(wrapper)) ?? payload
        return PoolMessage(
            type: .system,
            senderID: senderID,
            senderName: senderName,
            payload: wrappedData
        )
    }

    /// Creates a relay payload message for direct delivery.
    ///
    /// When a peer is directly reachable, we can send the encrypted payload
    /// directly without wrapping it in a `RelayEnvelope`.
    ///
    /// - Parameters:
    ///   - senderID: The peer ID of the sender.
    ///   - senderName: The display name of the sender.
    ///   - payload: The encrypted payload data.
    /// - Returns: A configured `PoolMessage` with type `.custom`.
    static func relayPayload(from senderID: String, senderName: String, payload: Data) -> PoolMessage {
        PoolMessage(
            type: .custom,
            senderID: senderID,
            senderName: senderName,
            payload: payload
        )
    }
}

// MARK: - Topology Broadcast Wrapper

/// Wrapper for topology broadcast payloads to distinguish them from other system messages.
///
/// This wrapper enables the receiver to identify that a system message contains
/// topology information rather than a regular system notification.
struct TopologyBroadcastWrapper: Codable, Sendable {
    /// Marker to identify this as a topology broadcast.
    var type: String = "topology_broadcast"

    /// The encoded `TopologyBroadcast` data.
    let topologyData: Data

    /// Checks if a payload is a topology broadcast wrapper.
    /// - Parameter data: The data to check.
    /// - Returns: The unwrapped `TopologyBroadcast` if this is a topology message, `nil` otherwise.
    static func unwrap(_ data: Data) -> TopologyBroadcast? {
        guard let wrapper = try? JSONDecoder().decode(TopologyBroadcastWrapper.self, from: data),
              wrapper.type == "topology_broadcast" else {
            return nil
        }
        return try? JSONDecoder().decode(TopologyBroadcast.self, from: wrapper.topologyData)
    }
}
