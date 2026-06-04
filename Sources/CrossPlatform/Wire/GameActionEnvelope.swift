// GameActionEnvelope.swift
// ConnectionPool / CrossPlatform
//
// Inner v=1 wrapper around `ChessGameAction`, carried inside
// `PoolMessage.payload` for `type == "game_action"`. Spec §5.2.2.
//
//   v          — protocol version, currently 1
//   sessionId  — value the host minted in `server_hello`; detects
//                cross-session traffic post-reconnect
//   seq        — monotonically increasing per *sender*. Receivers reject
//                non-strictly-greater seq with SEQ_REPLAY
//   action     — the raw ChessGameAction JSON
//
// `seq` and the encryption counter (spec §4.3) are independent — the counter
// advances on every encrypted frame (including PING/PONG), `seq` only
// advances per game action.

import Foundation

public struct CrossPlatformGameActionEnvelope: Sendable, Equatable {
    public static let protocolVersion: Int = 1

    public let sessionId: String
    public let seq: UInt32
    public let action: CrossPlatformChessGameAction
    public let version: Int

    public init(
        sessionId: String,
        seq: UInt32,
        action: CrossPlatformChessGameAction,
        version: Int = CrossPlatformGameActionEnvelope.protocolVersion
    ) {
        self.sessionId = sessionId
        self.seq = seq
        self.action = action
        self.version = version
    }

    public func encodeCanonical() -> Data {
        let pairs: [(String, JSONElement)] = [
            ("action", action.toJsonElement()),
            ("seq", .int(Int64(seq))),
            ("session_id", .string(sessionId)),
            ("v", .int(Int64(version))),
        ]
        return CanonicalJSON.encode(.object(pairs))
    }

    public static func decode(_ data: Data) throws -> CrossPlatformGameActionEnvelope {
        let element = try CanonicalJSON.decode(data)
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "GameActionEnvelope must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard case .int(let v)? = map["v"], v == Int64(protocolVersion) else {
            throw CrossPlatformTransportException(.incompatible, "unsupported GameActionEnvelope version")
        }
        guard case .string(let sessionId)? = map["session_id"] else {
            throw CrossPlatformTransportException(.incompatible, "GameActionEnvelope.session_id must be a string")
        }
        guard case .int(let rawSeq)? = map["seq"], rawSeq >= 0, rawSeq <= Int64(UInt32.max) else {
            throw CrossPlatformTransportException(.incompatible, "GameActionEnvelope.seq must be a u32")
        }
        guard let actionElement = map["action"] else {
            throw CrossPlatformTransportException(.incompatible, "GameActionEnvelope.action is required")
        }
        let action = try CrossPlatformChessGameAction.fromJsonElement(actionElement)
        return CrossPlatformGameActionEnvelope(
            sessionId: sessionId,
            seq: UInt32(rawSeq),
            action: action,
            version: Int(v)
        )
    }
}
