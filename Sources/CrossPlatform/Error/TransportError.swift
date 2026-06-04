// TransportError.swift
// ConnectionPool / CrossPlatform
//
// Cross-platform transport error taxonomy.
// Mirrors the Kotlin `TransportError.kt` implementation 1:1.
//
// NOTE: Renamed to `CrossPlatformTransportError` (with a `TransportError`
// typealias exposed only inside the CrossPlatform namespace) because the
// legacy `TransportTypes.swift` already defines a `TransportError` for the
// MC / WebSocket relay path. The two are semantically disjoint and have
// different cases. Cross-platform code uses the new type; legacy code
// continues to use the existing one without modification.

import Foundation

/// Closed cross-platform transport error taxonomy. Both the Kotlin and Swift
/// implementations MUST surface errors using exactly these tags so UI strings
/// stay co-translated. Spec §9 + ADR-0003 §3 (`closed`).
public enum CrossPlatformTransportError: String, Sendable, Hashable, CaseIterable {
    /// Wrong tap code or unknown session_id on resume. Recoverable: user retries.
    case badCode = "bad_code"

    /// Pool already at capacity (host has `maxPeers - 1` connected guests).
    case full = "full"

    /// Host has blocked this device. Manual unblock on host.
    case blocked = "blocked"

    /// Protocol-version or capability mismatch. Needs an app update.
    case incompatible = "incompatible"

    /// Too many hello attempts from this IP. Recoverable after the cool-off.
    case rateLimited = "rate_limited"

    /// Encrypted-frame Poly1305 tag invalid. Non-recoverable; close and start over.
    case authFail = "auth_fail"

    /// Inbound seq not strictly increasing. Non-recoverable; close and start over.
    case seqReplay = "seq_replay"

    /// length > 1 MiB. Non-recoverable.
    case frameTooLarge = "frame_too_large"

    /// length == 0. Non-recoverable.
    case emptyFrame = "empty_frame"

    /// Tag outside {0x01..0x05}. Non-recoverable.
    case unknownFrameType = "unknown_frame_type"

    /// 30 s without inbound + 5 s PING unanswered. May try resume.
    ///
    /// Per ADR-0006 §4: this is reserved for the spec §5.3 timer-driven path.
    /// Wire-write `IOException`-equivalent (peer RST mid-send, socket broken)
    /// MUST surface as ``incompatible`` instead.
    case keepaliveTimeout = "keepalive_timeout"

    /// `.handshaking` for 30 s. Non-recoverable.
    case handshakeTimeout = "handshake_timeout"

    /// Caller invoked a send-class API on an already-closed session.
    /// Recoverable only by starting a new session. ADR-0003 §3.
    case closed = "closed"

    /// Map a wire `err` string from `server_hello{ok:false,…}` back to the
    /// enum. Returns `nil` for unknown values — callers MUST decide the
    /// fallback policy. See ``fromWireOrIncompatible(_:loggingFallback:)``
    /// for the receive-side default per ADR-0004 §2.6.
    public static func fromWire(_ s: String) -> CrossPlatformTransportError? {
        CrossPlatformTransportError(rawValue: s)
    }

    /// Receive-side default per ADR-0004 §2.6: a guest observing a
    /// `server_hello{ok:false, err:<unknown>}` MUST treat the unknown value
    /// as ``incompatible``. Protects guests from buggy/hostile hosts emitting
    /// garbage `err` strings without breaking the typed error contract.
    public static func fromWireOrIncompatible(
        _ s: String,
        loggingFallback: (String) -> Void = { _ in }
    ) -> CrossPlatformTransportError {
        if let known = CrossPlatformTransportError(rawValue: s) { return known }
        loggingFallback(s)
        return .incompatible
    }
}

/// Thrown by transport-internal layers; framing/session catch and surface as
/// `PeerEvent.error(_:_:)` and/or `Disconnected(reason:)`.
public struct CrossPlatformTransportException: Error, Sendable, CustomStringConvertible, Equatable {
    public let tag: CrossPlatformTransportError
    public let message: String

    public init(_ tag: CrossPlatformTransportError, _ message: String? = nil) {
        self.tag = tag
        self.message = message ?? tag.rawValue
    }

    public var description: String { "TransportException(\(tag.rawValue)): \(message)" }
}
