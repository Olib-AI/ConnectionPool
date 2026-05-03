// TransportProvider.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Transport Provider Protocol

/// Abstraction over the physical transport layer.
///
/// Both MultipeerConnectivity and WebSocket transports conform to this protocol,
/// enabling the ``ConnectionPoolManager`` to operate transparently over either
/// local P2P or remote relay connections.
///
/// All methods and properties are MainActor-isolated to ensure UI-safe state updates
/// and consistent delegate callbacks.
@MainActor
public protocol TransportProvider: AnyObject, Sendable {

    // MARK: - Identity

    /// The unique identifier for the local peer in this transport session.
    var localPeerID: String { get }

    /// The human-readable display name of the local peer.
    var localPeerName: String { get }

    // MARK: - State

    /// The current state of the transport connection.
    var state: TransportState { get }

    /// The delegate that receives transport lifecycle and data events.
    var delegate: (any TransportDelegate)? { get set }

    // MARK: - Host Operations

    /// Begin advertising a pool so that peers can discover and join it.
    ///
    /// - Parameter poolInfo: Metadata about the pool being advertised.
    func startAdvertising(poolInfo: PoolAdvertisementInfo)

    /// Stop advertising the pool. No new peers will be able to discover it.
    func stopAdvertising()

    /// Accept a pending join request from a peer.
    ///
    /// - Parameter peerID: The identifier of the peer whose request to accept.
    func acceptConnection(from peerID: String)

    /// Reject a pending join request from a peer.
    ///
    /// - Parameter peerID: The identifier of the peer whose request to reject.
    func rejectConnection(from peerID: String)

    /// Forcefully disconnect a specific peer from the pool.
    ///
    /// - Parameter peerID: The identifier of the peer to disconnect.
    func disconnectPeer(_ peerID: String)

    // MARK: - Client Operations

    /// Begin discovering available pools.
    func startDiscovery()

    /// Stop discovering pools.
    func stopDiscovery()

    /// Request to join a discovered pool.
    ///
    /// - Parameters:
    ///   - poolID: The identifier of the pool to join.
    ///   - context: Additional context for the join request (e.g., pool code).
    func requestJoin(poolID: String, context: JoinContext)

    // MARK: - Data Transmission

    /// Broadcast data to all connected peers.
    ///
    /// - Parameters:
    ///   - data: The data to broadcast.
    ///   - reliable: Whether to use reliable (ordered, guaranteed) delivery.
    func broadcast(_ data: Data, reliable: Bool)

    /// Send data to specific peers.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - peerIDs: The identifiers of the target peers.
    ///   - reliable: Whether to use reliable (ordered, guaranteed) delivery.
    func send(_ data: Data, to peerIDs: [String], reliable: Bool)

    // MARK: - Lifecycle

    /// Disconnect from the pool and clean up all resources.
    func disconnect()
}

// MARK: - Transport Delegate Protocol

/// Delegate protocol for receiving transport layer events.
///
/// All callbacks are delivered on the MainActor to ensure safe UI updates.
@MainActor
public protocol TransportDelegate: AnyObject, Sendable {

    /// Called when the transport state changes.
    ///
    /// - Parameters:
    ///   - transport: The transport that changed state.
    ///   - didChangeState: The new transport state.
    func transport(_ transport: any TransportProvider, didChangeState: TransportState)

    /// Called when a peer successfully connects.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the connection.
    ///   - peerDidConnect: Information about the connected peer.
    func transport(_ transport: any TransportProvider, peerDidConnect peer: TransportPeer)

    /// Called when a peer disconnects.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the disconnection.
    ///   - peerDidDisconnect: The identifier of the disconnected peer.
    func transport(_ transport: any TransportProvider, peerDidDisconnect peerID: String)

    /// Called when data is received from a peer.
    ///
    /// - Parameters:
    ///   - transport: The transport that received data.
    ///   - didReceiveData: The received data.
    ///   - from: The identifier of the sending peer.
    func transport(_ transport: any TransportProvider, didReceiveData data: Data, from peerID: String)

    /// Called when a pool is discovered during browsing.
    ///
    /// - Parameters:
    ///   - transport: The transport that discovered the pool.
    ///   - didDiscoverPool: Information about the discovered pool.
    func transport(_ transport: any TransportProvider, didDiscoverPool pool: DiscoveredPool)

    /// Called when a previously discovered pool is no longer available.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the loss.
    ///   - didLosePool: The identifier of the lost pool.
    func transport(_ transport: any TransportProvider, didLosePool poolID: String)

    /// Called when the host receives a join request from a peer.
    ///
    /// - Parameters:
    ///   - transport: The transport that received the request.
    ///   - didReceiveJoinRequest: The identifier of the requesting peer.
    ///   - displayName: The display name of the requesting peer.
    ///   - context: Additional context sent with the join request.
    func transport(_ transport: any TransportProvider, didReceiveJoinRequest peerID: String,
                   displayName: String, context: JoinContext)

    /// Called when the transport encounters a non-fatal error.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the error.
    ///   - didFailWithError: The error that occurred.
    func transport(_ transport: any TransportProvider, didFailWithError error: TransportError)

    /// Called when the relay broadcasts a pool-configuration update (e.g. tunnel-exit toggled).
    ///
    /// Default implementation does nothing — only consumers that care about pool-level config
    /// changes (e.g. ``ConnectionPoolViewModel``, the relay-tunnel UI) need to override.
    func transport(_ transport: any TransportProvider, didReceivePoolConfigUpdate update: PoolConfigUpdatedData)

    /// Called when the relay broadcasts a pool host liveness update.
    ///
    /// Default implementation does nothing — only ``ConnectionPoolViewModel`` cares so it can
    /// surface a "Host offline" pill and disable invitation creation while the host is gone.
    /// Existing chat / call / game / tunnel data paths intentionally ignore this event so
    /// pool activity continues uninterrupted past a host disconnect (relay v0.5.0+).
    func transport(_ transport: any TransportProvider, didReceivePoolHostStatus status: PoolHostStatusData)

    /// Called when a JSON-encoded tunnel control-plane frame arrives.
    ///
    /// The relay-tunnel client (`RelayTunnelClient`) is the sole consumer. Default
    /// implementation drops the frame so existing delegates (e.g. ``ConnectionPoolViewModel``)
    /// remain unaffected by tunnel traffic.
    func transport(_ transport: any TransportProvider, didReceiveTunnelFrame frame: ServerFrame)

    /// Called when a binary tunnel frame arrives (`tunnel_data` or `tunnel_udp`).
    ///
    /// Hot-path bytes — delivered straight from the WebSocket receive loop without copying
    /// through JSON. The relay-tunnel client matches `streamID` to its open streams.
    /// Default implementation drops the frame.
    ///
    /// - Parameters:
    ///   - type: `0x01` (data) or `0x02` (udp).
    ///   - streamID: u32 stream identifier.
    ///   - sequence: present for `tunnel_data`; `nil` for `tunnel_udp`.
    ///   - payload: opaque bytes.
    func transport(_ transport: any TransportProvider, didReceiveBinaryTunnelFrame type: UInt8,
                   streamID: UInt32, sequence: UInt32?, payload: Data)
}

public extension TransportDelegate {
    func transport(_ transport: any TransportProvider, didReceivePoolConfigUpdate update: PoolConfigUpdatedData) {
        // Default no-op so existing conformers don't break.
    }

    func transport(_ transport: any TransportProvider, didReceivePoolHostStatus status: PoolHostStatusData) {
        // Default no-op so existing conformers (e.g. RelayTunnelClient internals) ignore
        // host-liveness events. Only ``ConnectionPoolViewModel`` needs to react.
    }

    func transport(_ transport: any TransportProvider, didReceiveTunnelFrame frame: ServerFrame) {
        // Default no-op — only the relay-tunnel client cares.
    }

    func transport(_ transport: any TransportProvider, didReceiveBinaryTunnelFrame type: UInt8,
                   streamID: UInt32, sequence: UInt32?, payload: Data) {
        // Default no-op — only the relay-tunnel client cares.
    }
}
