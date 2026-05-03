// RelayTunnelClient.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Public Surface

/// Errors surfaced by `RelayTunnelClient`.
public enum RelayTunnelError: Error, LocalizedError, Sendable {
    /// No remote pool / WebSocket transport is active, or the host has not approved
    /// tunnel-exit for this pool yet.
    case notAvailable
    /// The relay refused to open a stream. Either the host has the per-pool flag off,
    /// or the relay's server-side `tunnel.enabled` is off — both surface as `policy_denied`.
    case policyDenied(String)
    /// The relay could not reach the destination (DNS failure, no route, etc).
    case destinationUnreachable(String)
    /// The destination refused the connection.
    case connectionRefused(String)
    /// The relay or destination took too long.
    case timeout
    /// Catch-all protocol mismatch.
    case protocolError(String)
    /// Relay-side resource exhaustion (per-peer or relay-global stream cap).
    case resourceExhausted(String)
    /// Stream was closed by the peer.
    case closed(TunnelCloseReason)
    /// The tunnel client itself was torn down (transport disconnect, user toggle off).
    case clientShutdown

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Relay tunnel is not available."
        case .policyDenied(let m):
            return "Relay refused tunnel — host or relay disabled it. \(m)"
        case .destinationUnreachable(let m):
            return "Destination unreachable: \(m)"
        case .connectionRefused(let m):
            return "Connection refused: \(m)"
        case .timeout:
            return "Tunnel request timed out."
        case .protocolError(let m):
            return "Tunnel protocol error: \(m)"
        case .resourceExhausted(let m):
            return "Tunnel resource exhausted: \(m)"
        case .closed(let r):
            return "Stream closed (\(r.rawValue))."
        case .clientShutdown:
            return "Tunnel client shut down."
        }
    }
}

/// Public consumer surface used by `LocalProxyServer` when relay mode is active.
public protocol RelayTunnelClientType: Sendable {
    func openStream(to destination: TunnelDestination, network: TunnelNetwork) async throws -> TunnelStream
    func resolveDNS(name: String, type: DnsRecordType) async throws -> [DnsAnswer]
    var isAvailable: Bool { get async }
    /// Legacy property retained so callers from the previous (host-as-exit) implementation
    /// keep compiling. Always returns `nil` — the relay is the exit, not any pool peer.
    var hostPeerID: String? { get async }
}

// MARK: - Tunnel Stream

/// One bidirectional byte-pipe between the local proxy and the relay.
///
/// `send` blocks when outbound credit is exhausted; `receive` is an `AsyncThrowingStream`
/// that surfaces inbound bytes (and errors) until the stream is closed.
public final class TunnelStream: @unchecked Sendable {
    public let streamId: UInt32
    public let destination: TunnelDestination
    public let network: TunnelNetwork

    /// Inbound byte stream. Yields a `Data` per `tunnel_data`/`tunnel_udp` frame, terminates on close.
    public var receive: AsyncThrowingStream<Data, Error> { _receive }

    fileprivate let _receive: AsyncThrowingStream<Data, Error>
    fileprivate let _receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private let lock = NSLock()
    private weak var client: RelayTunnelClient?

    /// Outbound credit (bytes the relay has authorised us to send before next `windowUpdate`).
    private var _outboundCredit: Int

    /// Bytes received and consumed since the last `windowUpdate` we emitted to the relay.
    private var _consumedBytesSinceLastUpdate: UInt32 = 0

    /// Outbound monotonic sequence number used in `tunnel_data` binary frames.
    private var _outboundSequence: UInt32 = 0

    /// Set once the stream is closed (locally or remotely).
    private var _isClosed: Bool = false

    /// Pending `send` continuations waiting for credit to free up. FIFO.
    private var _waiters: [(amount: Int, continuation: CheckedContinuation<Void, Error>)] = []

    fileprivate init(
        streamId: UInt32,
        destination: TunnelDestination,
        network: TunnelNetwork,
        initialOutboundCredit: Int,
        client: RelayTunnelClient
    ) {
        self.streamId = streamId
        self.destination = destination
        self.network = network
        self._outboundCredit = initialOutboundCredit
        self.client = client

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self._receive = AsyncThrowingStream { c in continuation = c }
        self._receiveContinuation = continuation
    }

    // MARK: Outbound

    /// Send `data` over the tunnel. Blocks if outbound credit is exhausted; chunks at
    /// `TunnelLimits.maxDataChunkBytes` (32 KiB).
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let remaining = data.count - offset
            let chunkSize = min(remaining, TunnelLimits.maxDataChunkBytes)
            try await waitForCredit(chunkSize)
            let chunk = data.subdata(in: offset..<offset + chunkSize)
            try await sendChunk(chunk)
            offset += chunkSize
        }
    }

    /// Close this stream. Idempotent.
    public func close() async {
        await closeInternal(reason: .peerClosed, sendCloseFrame: true)
    }

    // MARK: Internal hooks (called from RelayTunnelClient)

    /// Called when an inbound `tunnel_data` / `tunnel_udp` binary frame arrives for this stream.
    fileprivate func didReceiveInbound(_ payload: Data) {
        lock.lock()
        let alreadyClosed = _isClosed
        if !alreadyClosed {
            _consumedBytesSinceLastUpdate &+= UInt32(payload.count)
        }
        let pendingCredit: UInt32?
        if !alreadyClosed && _consumedBytesSinceLastUpdate >= TunnelLimits.windowUpdateThreshold {
            pendingCredit = _consumedBytesSinceLastUpdate
            _consumedBytesSinceLastUpdate = 0
        } else {
            pendingCredit = nil
        }
        let client = self.client
        let streamId = self.streamId
        lock.unlock()

        guard !alreadyClosed else { return }
        _receiveContinuation.yield(payload)

        if let credit = pendingCredit, let client = client {
            Task { await client.sendWindowUpdate(streamId: streamId, additionalCredit: credit) }
        }
    }

    /// Called when the relay grants additional outbound credit.
    fileprivate func didReceiveWindowUpdate(_ additionalCredit: UInt32) {
        let waitersToResume: [(amount: Int, continuation: CheckedContinuation<Void, Error>)] = lock.withLock {
            _outboundCredit += Int(additionalCredit)
            // Wake waiters in FIFO order while credit allows.
            var resumed: [(amount: Int, continuation: CheckedContinuation<Void, Error>)] = []
            while let next = _waiters.first, next.amount <= _outboundCredit {
                _outboundCredit -= next.amount
                _waiters.removeFirst()
                resumed.append(next)
            }
            return resumed
        }
        for waiter in waitersToResume {
            waiter.continuation.resume()
        }
    }

    /// Called when the relay closes this stream.
    fileprivate func didReceiveClose(reason: TunnelCloseReason) {
        Task { await closeInternal(reason: reason, sendCloseFrame: false) }
    }

    /// Called when an `tunnel_error` frame for this stream arrives.
    fileprivate func didReceiveError(_ error: RelayTunnelError) {
        let waitersSnapshot: [(amount: Int, continuation: CheckedContinuation<Void, Error>)] = lock.withLock {
            guard !_isClosed else { return [] }
            _isClosed = true
            let waiters = _waiters
            _waiters.removeAll()
            return waiters
        }
        for waiter in waitersSnapshot {
            waiter.continuation.resume(throwing: error)
        }
        _receiveContinuation.finish(throwing: error)
        Task { [weak client, streamId] in
            await client?.removeStream(streamId: streamId)
        }
    }

    // MARK: Private

    private func waitForCredit(_ amount: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let immediate: Bool = lock.withLock {
                if _isClosed {
                    continuation.resume(throwing: RelayTunnelError.closed(.peerClosed))
                    return false
                }
                if _outboundCredit >= amount {
                    _outboundCredit -= amount
                    return true
                }
                _waiters.append((amount, continuation))
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    private func sendChunk(_ chunk: Data) async throws {
        let (closed, seq, client) = lock.withLock { () -> (Bool, UInt32, RelayTunnelClient?) in
            if _isClosed { return (true, 0, nil) }
            _outboundSequence &+= 1
            return (false, _outboundSequence, self.client)
        }
        if closed { throw RelayTunnelError.closed(.peerClosed) }
        guard let client = client else { throw RelayTunnelError.clientShutdown }
        await client.sendBinaryChunk(streamId: streamId, sequence: seq, payload: chunk, network: network)
    }

    private func closeInternal(reason: TunnelCloseReason, sendCloseFrame: Bool) async {
        let (alreadyClosed, waiters, client): (Bool, [(amount: Int, continuation: CheckedContinuation<Void, Error>)], RelayTunnelClient?) = lock.withLock {
            if _isClosed { return (true, [], nil) }
            _isClosed = true
            let w = _waiters
            _waiters.removeAll()
            return (false, w, self.client)
        }
        guard !alreadyClosed else { return }

        for waiter in waiters {
            waiter.continuation.resume(throwing: RelayTunnelError.closed(reason))
        }
        _receiveContinuation.finish()

        if sendCloseFrame, let client = client {
            await client.sendCloseFrame(streamId: streamId, reason: reason)
        }
        await client?.removeStream(streamId: streamId)
    }
}

// MARK: - RelayTunnelClient

/// Member-side relay-tunnel actor. Owns:
/// - per-stream state and routing
/// - DNS-query continuations
/// - send pipeline directly to `WebSocketTransport` (no per-peer encryption layer; the
///   pool-shared-secret AES-GCM layer that already wraps WebSocket frames is enough)
///
/// Inbound frames arrive via `WebSocketTransport`'s delegate hooks and are forwarded into
/// the actor by the host app's wiring (see `AppWindow`).
public actor RelayTunnelClient: RelayTunnelClientType {

    // MARK: Types

    /// MainActor-isolated wrapper around `WebSocketTransport` used for sending.
    /// The transport is `@MainActor`; the actor uses these closures so it doesn't need to hop
    /// to MainActor from arbitrary call sites in `TunnelStream`.
    ///
    /// `internal` so tests can construct one directly without spinning up a real WebSocket.
    struct TransportSendBridge: Sendable {
        let sendServerFrame: @Sendable (ServerFrame) async -> Void
        let sendTunnelData: @Sendable (UInt32, UInt32, Data) async -> Void
        let sendTunnelUdp: @Sendable (UInt32, Data) async -> Void

        init(
            sendServerFrame: @escaping @Sendable (ServerFrame) async -> Void,
            sendTunnelData: @escaping @Sendable (UInt32, UInt32, Data) async -> Void,
            sendTunnelUdp: @escaping @Sendable (UInt32, Data) async -> Void
        ) {
            self.sendServerFrame = sendServerFrame
            self.sendTunnelData = sendTunnelData
            self.sendTunnelUdp = sendTunnelUdp
        }
    }

    // MARK: Private state

    private let transport: TransportSendBridge
    /// Snapshot accessor for `ConnectionPoolManager.hostTunnelExitEnabled` and remote-mode flag.
    private let availabilityProvider: @Sendable () async -> Bool

    private var nextStreamId: UInt32 = 1
    private var streams: [UInt32: TunnelStream] = [:]

    private var nextDnsQueryId: UInt32 = 1
    private var pendingDnsQueries: [UInt32: CheckedContinuation<[DnsAnswer], Error>] = [:]

    /// `true` once `shutdown()` has been called or the websocket dropped — fail every new op.
    private var isShutdown: Bool = false

    // MARK: Init

    /// Internal init taking a pre-built bridge. Tests use this to drive the client without
    /// spinning up a real WebSocket.
    init(transportBridge: TransportSendBridge,
         availabilityProvider: @escaping @Sendable () async -> Bool) {
        self.transport = transportBridge
        self.availabilityProvider = availabilityProvider
    }

    public init(
        transport: WebSocketTransport,
        availabilityProvider: @escaping @Sendable () async -> Bool
    ) {
        // Bridge the @MainActor transport behind Sendable closures so the actor can call into
        // it without a MainActor hop at every send site.
        self.transport = TransportSendBridge(
            sendServerFrame: { [weak transport] frame in
                await MainActor.run {
                    transport?.sendServerFrame(frame)
                }
            },
            sendTunnelData: { [weak transport] streamID, seq, payload in
                await MainActor.run {
                    transport?.sendTunnelDataBinary(streamID: streamID, sequence: seq, payload: payload)
                }
            },
            sendTunnelUdp: { [weak transport] streamID, payload in
                await MainActor.run {
                    transport?.sendTunnelUdpBinary(streamID: streamID, payload: payload)
                }
            }
        )
        self.availabilityProvider = availabilityProvider
    }

    // MARK: Lifecycle

    /// Tear the client down. Cancels every outstanding stream with `aborted` and fails every
    /// pending DNS query. Idempotent.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        let snapshot = streams
        streams.removeAll()
        for (_, stream) in snapshot {
            stream.didReceiveError(.clientShutdown)
        }
        let dnsSnapshot = pendingDnsQueries
        pendingDnsQueries.removeAll()
        for (_, cont) in dnsSnapshot {
            cont.resume(throwing: RelayTunnelError.clientShutdown)
        }
        // Inform the relay we're abandoning every stream so it releases resources.
        let txn = transport
        for (id, _) in snapshot {
            Task {
                await txn.sendServerFrame(.tunnelClose(TunnelCloseData(streamId: id, reason: .aborted)))
            }
        }
    }

    // MARK: RelayTunnelClientType

    public var hostPeerID: String? { nil }

    public var isAvailable: Bool {
        get async {
            guard !isShutdown else { return false }
            return await availabilityProvider()
        }
    }

    public func openStream(to destination: TunnelDestination, network: TunnelNetwork) async throws -> TunnelStream {
        guard !isShutdown else { throw RelayTunnelError.clientShutdown }
        guard await availabilityProvider() else { throw RelayTunnelError.notAvailable }

        let streamId = nextStreamId
        nextStreamId &+= 1

        let stream = TunnelStream(
            streamId: streamId,
            destination: destination,
            network: network,
            initialOutboundCredit: Int(TunnelLimits.initialReceiveWindow),
            client: self
        )
        streams[streamId] = stream

        await transport.sendServerFrame(.tunnelOpen(TunnelOpenData(
            streamId: streamId,
            destination: destination,
            network: network,
            initialWindow: TunnelLimits.initialReceiveWindow
        )))

        return stream
    }

    public func resolveDNS(name: String, type: DnsRecordType) async throws -> [DnsAnswer] {
        guard !isShutdown else { throw RelayTunnelError.clientShutdown }
        guard await availabilityProvider() else { throw RelayTunnelError.notAvailable }

        let queryId = nextDnsQueryId
        nextDnsQueryId &+= 1

        let answers: [DnsAnswer] = try await withThrowingTaskGroup(of: [DnsAnswer].self) { group in
            group.addTask { [transport] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[DnsAnswer], Error>) in
                    Task { [weak self] in
                        await self?.installDnsContinuation(queryId: queryId, continuation: continuation)
                        await transport.sendServerFrame(.tunnelDnsQuery(TunnelDnsQueryData(
                            queryId: queryId,
                            name: name,
                            type: type
                        )))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(TunnelLimits.connectTimeoutSeconds * 1_000_000_000))
                throw RelayTunnelError.timeout
            }
            // Take whichever finishes first.
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        // If the timeout branch won the race, the continuation may still be pending.
        // Clean it up so a late dnsResponse doesn't double-resume.
        cancelDnsQueryIfPending(queryId: queryId)
        return answers
    }

    private func installDnsContinuation(
        queryId: UInt32,
        continuation: CheckedContinuation<[DnsAnswer], Error>
    ) {
        if isShutdown {
            continuation.resume(throwing: RelayTunnelError.clientShutdown)
            return
        }
        pendingDnsQueries[queryId] = continuation
    }

    private func cancelDnsQueryIfPending(queryId: UInt32) {
        if let cont = pendingDnsQueries.removeValue(forKey: queryId) {
            cont.resume(throwing: RelayTunnelError.timeout)
        }
    }

    // MARK: Inbound entry points (called by AppWindow's transport-delegate forwarder)

    /// Handle an inbound JSON tunnel control-plane frame.
    public func handleIncomingTunnelFrame(_ frame: ServerFrame) {
        switch frame {
        case .tunnelClose(let c):
            handleClose(c)
        case .tunnelWindowUpdate(let w):
            streams[w.streamId]?.didReceiveWindowUpdate(w.additionalCredit)
        case .tunnelDnsResponse(let r):
            handleDnsResponse(r)
        case .tunnelError(let e):
            handleError(e)
        default:
            // Defensive: WebSocketTransport only forwards close/window_update/dns_response/error
            // to us — anything else is a server-side bug.
            log("[TUNNEL] Unexpected control-plane frame", level: .warning, category: .network)
        }
    }

    /// Handle an inbound binary tunnel frame.
    public func handleIncomingBinaryFrame(type: UInt8, streamID: UInt32, sequence: UInt32?, payload: Data) {
        guard let typed = TunnelBinaryType(rawValue: type) else {
            // Unknown binary type — protocol error scoped to the originating stream.
            // We don't know whether the stream still exists, but if we have it, treat as
            // closed; emit a tunnel_error upstream so the relay sees us complain.
            let txn = transport
            Task {
                await txn.sendServerFrame(.tunnelError(TunnelErrorData(
                    streamId: streamID,
                    code: .protocolError,
                    message: "Unknown binary frame type \(type)"
                )))
            }
            if let stream = streams.removeValue(forKey: streamID) {
                stream.didReceiveError(.protocolError("Unknown binary frame type \(type)"))
            }
            return
        }
        guard let stream = streams[streamID] else {
            // Stream not open locally — silently drop. The relay may have buffered late frames.
            log("[TUNNEL] Dropping \(typed.rawValue) for unknown stream \(streamID)", level: .debug, category: .network)
            return
        }
        _ = sequence  // currently unused on member side; relay enforces ordering
        stream.didReceiveInbound(payload)
    }

    // MARK: Frame handlers

    private func handleClose(_ c: TunnelCloseData) {
        if c.reason == .policyDenied {
            // Trip the kill switch — the relay or host explicitly refused. The Core layer
            // listens for `relayTunnelKillSwitchTriggered` and the user-facing message lives
            // in `RelayTunnelError.policyDenied`.
            NotificationCenter.default.post(
                name: Notification.Name("RelayTunnelKillSwitchTriggered"),
                object: nil
            )
        }
        streams[c.streamId]?.didReceiveClose(reason: c.reason)
        streams.removeValue(forKey: c.streamId)
    }

    private func handleError(_ e: TunnelErrorData) {
        let mapped = mapTunnelError(e)
        if e.code == .policyDenied {
            NotificationCenter.default.post(
                name: Notification.Name("RelayTunnelKillSwitchTriggered"),
                object: nil
            )
        }
        if let streamId = e.streamId {
            streams[streamId]?.didReceiveError(mapped)
            streams.removeValue(forKey: streamId)
        } else {
            // Connection-scoped error: surface as a generic failure to all pending operations.
            shutdownAllStreamsAndQueries(error: mapped)
        }
    }

    private func handleDnsResponse(_ r: TunnelDnsResponseData) {
        guard let cont = pendingDnsQueries.removeValue(forKey: r.queryId) else { return }
        if let answers = r.answers {
            cont.resume(returning: answers)
        } else if let err = r.error {
            cont.resume(throwing: RelayTunnelError.protocolError("DNS error \(err.code.rawValue): \(err.message)"))
        } else {
            cont.resume(throwing: RelayTunnelError.protocolError("DNS response missing answers and error"))
        }
    }

    // MARK: Outbound helpers (called from TunnelStream)

    fileprivate nonisolated func sendBinaryChunk(streamId: UInt32, sequence: UInt32, payload: Data, network: TunnelNetwork) async {
        let txn = await transportBridge()
        switch network {
        case .tcp:
            await txn.sendTunnelData(streamId, sequence, payload)
        case .udp:
            await txn.sendTunnelUdp(streamId, payload)
        }
    }

    fileprivate nonisolated func sendCloseFrame(streamId: UInt32, reason: TunnelCloseReason) async {
        let txn = await transportBridge()
        await txn.sendServerFrame(.tunnelClose(TunnelCloseData(streamId: streamId, reason: reason)))
    }

    fileprivate func sendWindowUpdate(streamId: UInt32, additionalCredit: UInt32) async {
        await transport.sendServerFrame(.tunnelWindowUpdate(TunnelWindowUpdateData(
            streamId: streamId,
            additionalCredit: additionalCredit
        )))
    }

    fileprivate func removeStream(streamId: UInt32) {
        streams.removeValue(forKey: streamId)
    }

    // MARK: Helpers

    /// Actor-isolated read of the transport bridge so non-isolated helpers can hop in.
    private func transportBridge() -> TransportSendBridge { transport }

    private func shutdownAllStreamsAndQueries(error: RelayTunnelError) {
        for (_, cont) in pendingDnsQueries {
            cont.resume(throwing: error)
        }
        pendingDnsQueries.removeAll()
        for (_, stream) in streams {
            stream.didReceiveError(error)
        }
        streams.removeAll()
    }

    private func mapTunnelError(_ err: TunnelErrorData) -> RelayTunnelError {
        switch err.code {
        case .policyDenied: return .policyDenied(err.message)
        case .destinationUnreachable: return .destinationUnreachable(err.message)
        case .connectionRefused: return .connectionRefused(err.message)
        case .timeout: return .timeout
        case .protocolError: return .protocolError(err.message)
        case .resourceExhausted: return .resourceExhausted(err.message)
        }
    }
}
