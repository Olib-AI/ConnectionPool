// TunnelTypes.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Tunnel Wire Contract (control plane)
//
// The relay-tunnel feature has TWO transports on the same WebSocket:
//
//   1. Control plane — JSON text frames carried as `ServerFrame` variants
//      (`tunnelOpen`, `tunnelClose`, `tunnelWindowUpdate`, `tunnelDnsQuery`,
//       `tunnelDnsResponse`, `tunnelError`).
//
//   2. Hot path — binary WebSocket frames for `tunnel_data` (TCP byte stream)
//      and `tunnel_udp` (UDP datagram). See `TunnelBinaryFrame.swift` for layout.
//
// This file defines the supporting types shared by both planes. They MUST stay
// byte-for-byte compatible with the Rust StealthRelay agent's `tunnel.rs`.
//
// All JSON keys are snake_case to match Rust serde `rename_all = "snake_case"`.

// MARK: - Tunnel Limits

/// Static limits for the tunnel protocol. These constants are part of the wire contract
/// (the Rust side enforces matching values) and must change in lockstep with that side.
public enum TunnelLimits {
    /// Maximum payload bytes per `tunnel_data` binary frame. Sized to fit comfortably inside
    /// the relay's WebSocket frame cap after the 9-byte binary header.
    public static let maxDataChunkBytes: Int = 32_768           // 32 KiB

    /// Default initial receive window granted to a newly opened stream (bytes).
    public static let initialReceiveWindow: UInt32 = 262_144    // 256 KiB

    /// Window-update threshold: emit a credit grant after this many bytes have been consumed.
    public static let windowUpdateThreshold: UInt32 = 65_536    // 64 KiB

    /// Per-peer cap on simultaneously open tunnel streams (enforced by the relay).
    public static let maxConcurrentStreamsPerPeer: Int = 64

    /// Global cap on simultaneously open tunnel streams across all pool peers (enforced by the relay).
    public static let maxConcurrentStreamsHostTotal: Int = 256

    /// Connection establishment timeout in seconds.
    public static let connectTimeoutSeconds: Double = 15

    /// Idle stream timeout: a stream with no data flow for this long is closed.
    public static let idleStreamTimeoutSeconds: Double = 120
}

// MARK: - Tunnel Destination

/// Endpoint a tunnel stream targets.
///
/// JSON encoding uses `kind` discriminator with snake_case values:
/// ```json
/// { "kind": "hostname", "host": "example.com", "port": 443 }
/// { "kind": "ipv4", "address": "1.2.3.4", "port": 443 }
/// { "kind": "ipv6", "address": "::1", "port": 443 }
/// ```
public enum TunnelDestination: Sendable, Equatable {
    /// Hostname + TCP/UDP port. Resolved by the relay (closer to a SOCKS5h semantic).
    case hostname(host: String, port: UInt16)
    /// Pre-resolved IPv4 address + port.
    case ipv4(address: String, port: UInt16)
    /// Pre-resolved IPv6 address + port.
    case ipv6(address: String, port: UInt16)
}

extension TunnelDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case host
        case address
        case port
    }

    private enum Kind: String, Codable {
        case hostname
        case ipv4
        case ipv6
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let port = try container.decode(UInt16.self, forKey: .port)
        switch kind {
        case .hostname:
            let host = try container.decode(String.self, forKey: .host)
            self = .hostname(host: host, port: port)
        case .ipv4:
            let addr = try container.decode(String.self, forKey: .address)
            self = .ipv4(address: addr, port: port)
        case .ipv6:
            let addr = try container.decode(String.self, forKey: .address)
            self = .ipv6(address: addr, port: port)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostname(let host, let port):
            try container.encode(Kind.hostname, forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case .ipv4(let address, let port):
            try container.encode(Kind.ipv4, forKey: .kind)
            try container.encode(address, forKey: .address)
            try container.encode(port, forKey: .port)
        case .ipv6(let address, let port):
            try container.encode(Kind.ipv6, forKey: .kind)
            try container.encode(address, forKey: .address)
            try container.encode(port, forKey: .port)
        }
    }
}

// MARK: - Tunnel Network

/// Transport-layer protocol requested for a stream.
public enum TunnelNetwork: String, Codable, Sendable, Equatable {
    case tcp
    case udp
}

// MARK: - Close Reason

/// Why a tunnel stream was closed.
public enum TunnelCloseReason: String, Codable, Sendable, Equatable {
    case peerClosed = "peer_closed"
    case aborted
    case idleTimeout = "idle_timeout"
    case policyDenied = "policy_denied"
    case destinationUnreachable = "destination_unreachable"
    case connectionRefused = "connection_refused"
    case timeout
    case streamLimit = "stream_limit"
    case protocolError = "protocol_error"
}

// MARK: - DNS Types

/// Subset of DNS record types the tunnel exposes. Start minimal; extend in lockstep with Rust.
public enum DnsRecordType: String, Codable, Sendable, Equatable {
    case a
    case aaaa
    case cname
    case txt
}

/// Single DNS answer record returned by a `tunnel_dns_response` frame.
public struct DnsAnswer: Codable, Sendable, Equatable {
    public let name: String
    public let type: DnsRecordType
    public let ttl: UInt32
    public let value: String

    public init(name: String, type: DnsRecordType, ttl: UInt32, value: String) {
        self.name = name
        self.type = type
        self.ttl = ttl
        self.value = value
    }
}

/// DNS resolution failure detail.
public struct DnsError: Codable, Sendable, Equatable {
    public let code: DnsErrorCode
    public let message: String

    public init(code: DnsErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// DNS error categories per the wire contract.
public enum DnsErrorCode: String, Codable, Sendable, Equatable {
    case nxDomain = "nx_domain"
    case servFail = "serv_fail"
    case timeout
    case policyDenied = "policy_denied"
    case protocolError = "protocol_error"
}

// MARK: - Tunnel Error Code

/// Tunnel-level error categories surfaced via `tunnel_error` frames.
public enum TunnelErrorCode: String, Codable, Sendable, Equatable {
    case policyDenied = "policy_denied"
    case destinationUnreachable = "destination_unreachable"
    case connectionRefused = "connection_refused"
    case timeout
    case protocolError = "protocol_error"
    case resourceExhausted = "resource_exhausted"
}

// MARK: - Control-plane Frame Payloads
//
// Each of these is the `data` payload for one `ServerFrame` variant. JSON shape is
// `{ "frame_type": "<snake_case>", "data": <payload> }`, matching the existing
// `ServerFrame` Codable implementation.

/// Client → server: open a new tunnel stream towards `destination`.
public struct TunnelOpenData: Codable, Sendable, Equatable {
    public let streamId: UInt32
    public let destination: TunnelDestination
    public let network: TunnelNetwork
    /// Initial receive window the opener is willing to buffer (bytes).
    public let initialWindow: UInt32

    public init(streamId: UInt32, destination: TunnelDestination, network: TunnelNetwork, initialWindow: UInt32) {
        self.streamId = streamId
        self.destination = destination
        self.network = network
        self.initialWindow = initialWindow
    }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case destination
        case network
        case initialWindow = "initial_window"
    }
}

/// Bidirectional: tear down a tunnel stream.
public struct TunnelCloseData: Codable, Sendable, Equatable {
    public let streamId: UInt32
    public let reason: TunnelCloseReason

    public init(streamId: UInt32, reason: TunnelCloseReason) {
        self.streamId = streamId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case reason
    }
}

/// Bidirectional: grants `additionalCredit` more bytes of receive window to the peer.
public struct TunnelWindowUpdateData: Codable, Sendable, Equatable {
    public let streamId: UInt32
    public let additionalCredit: UInt32

    public init(streamId: UInt32, additionalCredit: UInt32) {
        self.streamId = streamId
        self.additionalCredit = additionalCredit
    }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case additionalCredit = "additional_credit"
    }
}

/// Client → server: resolve `name` via the relay's DNS.
public struct TunnelDnsQueryData: Codable, Sendable, Equatable {
    public let queryId: UInt32
    public let name: String
    /// JSON key is `type` (clashes with Swift's `Type`); we use `recordType` as the property name.
    public let recordType: DnsRecordType

    public init(queryId: UInt32, name: String, type: DnsRecordType) {
        self.queryId = queryId
        self.name = name
        self.recordType = type
    }

    enum CodingKeys: String, CodingKey {
        case queryId = "query_id"
        case name
        case recordType = "type"
    }
}

/// Server → client: result of a DNS query. Either `answers` or `error` is populated, never both.
public struct TunnelDnsResponseData: Codable, Sendable, Equatable {
    public let queryId: UInt32
    public let answers: [DnsAnswer]?
    public let error: DnsError?

    public init(queryId: UInt32, answers: [DnsAnswer]? = nil, error: DnsError? = nil) {
        self.queryId = queryId
        self.answers = answers
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case queryId = "query_id"
        case answers
        case error
    }
}

/// Bidirectional: tunnel-level error.
///
/// `streamId` is `nil` when the error is connection-scoped rather than stream-scoped
/// (e.g. global resource exhaustion before any stream was created).
///
/// Named `TunnelErrorData` (not `ErrorData`) because `ServerFrame` already exposes a
/// `public struct ErrorData` for relay-server error frames; renaming here avoids ambiguity
/// at every use site.
public struct TunnelErrorData: Codable, Sendable, Equatable {
    public let streamId: UInt32?
    public let code: TunnelErrorCode
    public let message: String

    public init(streamId: UInt32?, code: TunnelErrorCode, message: String) {
        self.streamId = streamId
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case code
        case message
    }
}
