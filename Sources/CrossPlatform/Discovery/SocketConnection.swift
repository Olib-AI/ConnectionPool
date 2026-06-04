// SocketConnection.swift
// ConnectionPool / CrossPlatform / Discovery
//
// `RawConnection` adapter over Apple's `NWConnection`. Each `acceptGuest` /
// `connectAsGuest` consumes one of these per peer pair. Bidirectional reads
// suspend on `NWConnection.receive` until at least one byte is delivered or
// the connection drops; writes use `NWConnection.send` with
// `contentContext = .defaultMessage` (TCP-reliable).
//
// `remoteDescription` is **IP-only** per ADR-0005 §2.4 — source-port stripped
// so the rate-limit map cannot be bypassed by a port-rotating attacker.

import Foundation
import Network
import os

public final class SocketConnection: RawConnection, @unchecked Sendable {

    private let connection: NWConnection
    /// IP-only string used as the rate-limit key (ADR-0005 §2.4).
    public let remoteDescription: String
    private let queue: DispatchQueue
    private let stateLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init(connection: NWConnection, queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.connection = connection
        self.queue = queue
        self.remoteDescription = Self.extractIPOnly(endpoint: connection.endpoint)
    }

    /// Wrap an already-connected `NWConnection`. The caller is responsible for
    /// driving it to `.ready` before passing it in; we expose a convenience
    /// `connect(...)` builder below for the symmetric guest path.
    public static func wrap(_ connection: NWConnection) -> SocketConnection {
        SocketConnection(connection: connection)
    }

    /// OSLog channel for the TCP-connect path. The Discovery / SocketConnection
    /// state machine logs every NWConnection state transition here so users
    /// hitting an indefinite "Connecting…" hang on the guest side can grab a
    /// Console.app trace filtered on `subsystem:com.olibai.chessup.transport,
    /// category:socket` and tell us exactly which state the connection got
    /// stuck in (typically `.waiting(reason)` — see iOS task #164).
    private static let connectLog = Logger(subsystem: "com.olibai.chessup.transport", category: "socket")

    /// Maximum wall-clock time we'll wait for an `NWConnection` to reach
    /// `.ready`. Apple's NW stack will sit in `.preparing` / `.waiting(reason)`
    /// indefinitely under common cross-platform Bonjour failure modes (host's
    /// listener not actually accepting on the resolved endpoint, Wi-Fi
    /// isolation between peers, NAT, IPv6 link-local mismatch, DNS failure)
    /// without ever transitioning to `.failed`. 10 s is long enough to ride
    /// out a flaky Wi-Fi handshake yet short enough to surface a failure
    /// inside the user's patience window. Tuned for iOS task #164.
    private static let tcpConnectTimeoutNanos: UInt64 = 10_000_000_000

    /// `NWParameters` for outbound peer-to-peer sockets, with TCP-level
    /// keepalive enabled so a peer that walks out of Wi-Fi range or
    /// silently goes away is detected by the kernel within ~60 s
    /// (30 s idle + 3 × 10 s probes). Apple's `.tcp` default leaves
    /// keepalive off; even when enabled the default idle window is
    /// 2 hours, which is wrong for a session expected to last minutes.
    /// Listener-side parity lives in ``BonjourAdvertiser`` — set on the
    /// NWListener's parameters so accepted NWConnections inherit it.
    public static func defaultTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Bring an `NWConnection` to `.ready` and return a wrapped
    /// `SocketConnection`. Throws on connection failure. Bounded by
    /// ``tcpConnectTimeoutNanos`` — if the underlying NW stack hasn't
    /// reached `.ready` / `.failed` within that window the connection is
    /// cancelled and we throw `CrossPlatformTransportException(.handshakeTimeout,
    /// "tcp connect timed out")`. `.waiting(reason)` is also surfaced as a
    /// terminal failure (the reason types — `.cannotConnectToHost`,
    /// `.cannotFindHost`, `.dnsServiceFailure`, etc. — are usually permanent
    /// and NWConnection will keep retrying until we cancel it).
    public static func connect(
        to endpoint: NWEndpoint,
        using parameters: NWParameters = SocketConnection.defaultTCPParameters()
    ) async throws -> SocketConnection {
        let conn = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "ConnectionPool.SocketConnection.connect")
        connectLog.info("connect: starting to endpoint=\(String(describing: endpoint), privacy: .public)")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        // Resume guard. NWConnection can deliver multiple
                        // terminal states (e.g. `.failed` followed by
                        // `.cancelled` after our timeout fires) and a
                        // CheckedContinuation crashes on double-resume.
                        // `OSAllocatedUnfairLock` is Sendable, so the
                        // handler closure can capture it directly.
                        let resumeLock = OSAllocatedUnfairLock<Bool>(initialState: false)
                        conn.stateUpdateHandler = { state in
                            let isFirstResume: () -> Bool = {
                                resumeLock.withLock { resumed in
                                    if resumed { return false }
                                    resumed = true
                                    return true
                                }
                            }
                            switch state {
                            case .setup:
                                connectLog.debug("connect: state=setup")
                            case .preparing:
                                connectLog.debug("connect: state=preparing")
                            case .waiting(let reason):
                                // NW will keep retrying internally until we
                                // cancel. Treat it as terminal so the user
                                // sees a real error instead of a hung UI.
                                connectLog.error("connect: state=waiting reason=\(String(describing: reason), privacy: .public)")
                                if isFirstResume() {
                                    cont.resume(throwing: CrossPlatformTransportException(
                                        .handshakeTimeout,
                                        "waiting: \(reason)"
                                    ))
                                }
                            case .ready:
                                connectLog.info("connect: state=ready")
                                if isFirstResume() {
                                    cont.resume()
                                }
                            case .failed(let err):
                                connectLog.error("connect: state=failed err=\(String(describing: err), privacy: .public)")
                                if isFirstResume() {
                                    cont.resume(throwing: err)
                                }
                            case .cancelled:
                                connectLog.info("connect: state=cancelled")
                                if isFirstResume() {
                                    cont.resume(throwing: CrossPlatformTransportException(
                                        .handshakeTimeout,
                                        "connection cancelled before ready"
                                    ))
                                }
                            @unknown default:
                                connectLog.debug("connect: state=<unknown>")
                            }
                        }
                        conn.start(queue: queue)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: SocketConnection.tcpConnectTimeoutNanos)
                    throw CrossPlatformTransportException(.handshakeTimeout, "tcp connect timed out")
                }
                // First task to finish (success OR throw) wins; cancel the
                // other so we don't leak the sleep task.
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            // Whether the state-update task threw or the timeout fired,
            // we must cancel the NWConnection. Idempotent — NWConnection's
            // `cancel()` is safe to call from any state, including already
            // `.cancelled`. This is what unblocks the stuck `.waiting`
            // / `.preparing` state machine on the wire.
            conn.stateUpdateHandler = nil
            conn.cancel()
            throw error
        }
        conn.stateUpdateHandler = nil
        return SocketConnection(connection: conn, queue: queue)
    }

    /// Strip source-port from an endpoint description per ADR-0005 §2.4.
    /// IPv4: `1.2.3.4:port` → `1.2.3.4`. IPv6: `[::1]:port` → `::1`.
    /// Bonjour names pass through unchanged (synthetic remoteKey in tests).
    private static func extractIPOnly(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4):
                return "\(v4)"
            case .ipv6(let v6):
                // `IPv6Address.debugDescription` strips the zone identifier.
                return "\(v6)"
            case .name(let name, _):
                return name
            @unknown default:
                return "\(host)"
            }
        case .service(let name, _, _, _):
            return name
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return "\(endpoint)"
        @unknown default:
            return "\(endpoint)"
        }
    }

    public func readExact(_ n: Int) async throws -> Data? {
        var collected = Data()
        collected.reserveCapacity(n)
        while collected.count < n {
            let needed = n - collected.count
            let chunkOrNil: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: Data())
                }
            }
            guard let chunk = chunkOrNil else {
                // EOF.
                if collected.isEmpty { return nil }
                throw CrossPlatformTransportException(.incompatible, "short read: \(collected.count)/\(n)")
            }
            if chunk.isEmpty {
                // Spurious empty callback — try again.
                continue
            }
            collected.append(chunk)
        }
        return collected
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() async {
        let firstClose = stateLock.withLock { closed in
            if closed { return false }
            closed = true
            return true
        }
        if firstClose { connection.cancel() }
    }
}
