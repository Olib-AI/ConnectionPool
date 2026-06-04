// CrossPlatformPoolMessage.swift
// ConnectionPool / CrossPlatform
//
// Outer cross-platform PoolMessage envelope. Spec §5.2.1. Separate type
// from the legacy MC `PoolMessage` so the canonical-JSON normalization
// (sorted keys, ISO-8601 millisecond timestamps, padded standard base64
// payload) does NOT regress the MC wire format.
//
//   * `payload` is the DECODED bytes — on-the-wire it appears as a base64
//     string. Encoder lives in `encodeCanonical()`, decoder in `decode(_:)`.
//   * `id` is a UUID v4. We emit lowercase 36-char canonical form by
//     pinning `uuidString.lowercased()`.

import Foundation

public struct CrossPlatformPoolMessage: Sendable, Equatable {
    public let id: UUID
    public let type: CrossPlatformPoolMessageType
    /// `"host-" + base64url(pid_16)` or `"guest-" + base64url(pid_16)`. The
    /// receiver MUST NOT introspect the prefix — role is owned by the session
    /// state machine, not the string. Per ADR-0005 §2.1.
    public let senderID: String
    public let senderName: String
    public let timestamp: Date
    public let payload: Data
    public let isReliable: Bool

    public init(
        id: UUID,
        type: CrossPlatformPoolMessageType,
        senderID: String,
        senderName: String,
        timestamp: Date,
        payload: Data,
        isReliable: Bool
    ) {
        self.id = id
        self.type = type
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.payload = payload
        self.isReliable = isReliable
    }

    /// Encode to canonical bytes. Keys sorted ascending by Unicode code-point,
    /// no whitespace, no `\u`-escape of printable Unicode, RFC-4648 standard
    /// base64-with-padding for `payload`, ISO-8601-with-ms-`Z` for `timestamp`.
    public func encodeCanonical() -> Data {
        let pairs: [(String, JSONElement)] = [
            ("id", .string(id.uuidString.lowercased())),
            ("isReliable", .bool(isReliable)),
            ("payload", .string(CrossPlatformBase64.encodeStd(payload))),
            ("senderID", .string(senderID)),
            ("senderName", .string(senderName)),
            ("timestamp", .string(CrossPlatformIso8601Millis.format(timestamp))),
            ("type", .string(type.rawValue)),
        ]
        return CanonicalJSON.encode(.object(pairs))
    }

    /// Decode from any RFC-8259-valid JSON byte sequence. Receivers MUST NOT
    /// depend on canonicality (spec §5.2.1). An unknown `type` value surfaces
    /// as `CrossPlatformTransportException(.incompatible)` per ADR-0005 §2.2.
    public static func decode(_ data: Data) throws -> CrossPlatformPoolMessage {
        let element = try CanonicalJSON.decode(data)
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)

        guard case .string(let idString)? = map["id"],
              let uuid = UUID(uuidString: idString) else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.id must be a UUID string")
        }
        guard case .string(let typeString)? = map["type"] else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.type must be a string")
        }
        let type = try CrossPlatformPoolMessageType.fromWire(typeString)
        guard case .string(let senderID)? = map["senderID"] else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.senderID must be a string")
        }
        guard case .string(let senderName)? = map["senderName"] else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.senderName must be a string")
        }
        guard case .string(let timestampString)? = map["timestamp"],
              let timestamp = CrossPlatformIso8601Millis.parse(timestampString) else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.timestamp must be ISO-8601-ms")
        }
        guard case .string(let payloadB64)? = map["payload"],
              let payload = CrossPlatformBase64.decodeStd(payloadB64) else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.payload must be base64")
        }
        guard case .bool(let isReliable)? = map["isReliable"] else {
            throw CrossPlatformTransportException(.incompatible, "PoolMessage.isReliable must be a boolean")
        }
        return CrossPlatformPoolMessage(
            id: uuid,
            type: type,
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload,
            isReliable: isReliable
        )
    }
}
