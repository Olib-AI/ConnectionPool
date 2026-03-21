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
}
