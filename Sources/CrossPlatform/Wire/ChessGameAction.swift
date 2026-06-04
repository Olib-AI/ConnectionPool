// ChessGameAction.swift
// ConnectionPool / CrossPlatform
//
// Cross-platform wire shape of the chess game action. Spec §5.2.3.
// Source-of-truth keys are the Swift Codable defaults for the iOS
// `chess-up/Packages/ChessMultiplayer/Sources/ChessGameMessage.swift` L11-42
// enum: `hostColor`, `startingFEN` (ALL-CAPS `FEN` suffix), `uci`, `emoji`.
//
//   { "start":           { "hostColor": "white"|"black", "startingFEN": "<FEN>" } }
//   { "gameSettings":    { "initialSeconds": <Int>, "incrementSeconds": <Int>,
//                          "maxMovesCap": <Int?|null>, "allowDrawOffers": <Bool>,
//                          "allowTakebacks": <Bool> } }
//   { "move":            { "uci": "<UCI>" } }
//   { "resign":          {} }
//   { "offerDraw":       {} }
//   { "acceptDraw":      {} }
//   { "declineDraw":     {} }
//   { "requestTakeback": {} }
//   { "acceptTakeback":  {} }
//   { "declineTakeback": {} }
//   { "emote":           { "emoji": "<one of CHESS_UP_EMOTES>" } }
//   { "requestResume":   { "blackSecondsRemaining": <Double>, "gid": "<UUID>",
//                          "moveCount": <Int>, "whiteSecondsRemaining": <Double> } }
//   { "acceptResume":    { "gid": "<UUID>" } }
//   { "declineResume":   { "gid": "<UUID>" } }
//
// Move.uci MUST be lowercase on construction so the canonical-JSON bytes are
// platform-independent (Kotlin enforces the same invariant). Receivers
// tolerate case symmetrically and normalize to lowercase.
//
// Resume actions (`requestResume`, `acceptResume`, `declineResume`) are the
// reconnect-handshake extension landed 2026-05-17 (see chess-up iOS task
// #161). They ride the same canonical-JSON path as every other action; the
// only new wrinkle is the requester's payload carries Double clock fields
// emitted via `JSONElement.number(formattedDouble)` so the bytes stay
// platform-stable. Both sides keep a local saved-game record keyed by
// opponent stable ID and the resume protocol just verifies "do we both
// have this gid?" — the actual position/clocks/history come from each
// peer's own SavedGameStore, NOT from over-the-wire state.

import Foundation

/// Wire-stable color enum mirroring the legacy chess-up `WireColor`.
public enum CrossPlatformWireColor: String, Sendable, Hashable, Equatable {
    case white
    case black

    public var opposite: CrossPlatformWireColor { self == .white ? .black : .white }

    static func fromWire(_ s: String) throws -> CrossPlatformWireColor {
        guard let v = CrossPlatformWireColor(rawValue: s) else {
            throw CrossPlatformTransportException(.incompatible, "unknown WireColor: \(s)")
        }
        return v
    }
}

/// Host-broadcast rule + clock configuration. Cross-platform mirror of
/// the iOS `GameSettings` in
/// `chess-up/Packages/ChessMultiplayer/Sources/ChessGameMessage.swift`.
///
/// Wire shape (canonical JSON, keys sorted by the canonical-JSON encoder):
///
/// ```json
/// {
///   "allowDrawOffers": true,
///   "allowTakebacks":  false,
///   "incrementSeconds": 10,
///   "initialSeconds":   900,
///   "maxMovesCap":      null
/// }
/// ```
///
/// `maxMovesCap` is `Int?` because the concept is "no cap"; emitters
/// MUST emit the key with `null` when disabled (not key-absent) so the
/// hex bytes are stable across both platforms.
public struct CrossPlatformGameSettings: Sendable, Equatable, Hashable {
    public let initialSeconds: Int
    public let incrementSeconds: Int
    public let maxMovesCap: Int?
    public let allowDrawOffers: Bool
    public let allowTakebacks: Bool

    public init(
        initialSeconds: Int,
        incrementSeconds: Int,
        maxMovesCap: Int?,
        allowDrawOffers: Bool,
        allowTakebacks: Bool
    ) {
        self.initialSeconds = max(0, initialSeconds)
        self.incrementSeconds = max(0, incrementSeconds)
        self.maxMovesCap = maxMovesCap.flatMap { $0 > 0 ? $0 : nil }
        self.allowDrawOffers = allowDrawOffers
        self.allowTakebacks = allowTakebacks
    }

    /// v1 defaults applied by a guest that receives a `move` without
    /// having seen a prior `gameSettings`. Matches the PvE "Rapid 15+10,
    /// no cap, draws + hints on, takebacks off" baseline.
    public static let defaults = CrossPlatformGameSettings(
        initialSeconds: 15 * 60,
        incrementSeconds: 10,
        maxMovesCap: nil,
        allowDrawOffers: true,
        allowTakebacks: false
    )

    func toJsonElement() -> JSONElement {
        // Inner-key declaration order is cosmetic — the canonical-JSON
        // encoder re-sorts at output time per spec §5.2.1.
        return .object([
            ("initialSeconds", .int(Int64(initialSeconds))),
            ("incrementSeconds", .int(Int64(incrementSeconds))),
            ("maxMovesCap", maxMovesCap.map { .int(Int64($0)) } ?? .null),
            ("allowDrawOffers", .bool(allowDrawOffers)),
            ("allowTakebacks", .bool(allowTakebacks)),
        ])
    }

    static func fromJsonElement(_ element: JSONElement) throws -> CrossPlatformGameSettings {
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "GameSettings must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard case .int(let initial)? = map["initialSeconds"], initial >= 0, initial <= Int64(Int.max) else {
            throw CrossPlatformTransportException(.incompatible, "GameSettings.initialSeconds must be a non-negative int")
        }
        guard case .int(let incr)? = map["incrementSeconds"], incr >= 0, incr <= Int64(Int.max) else {
            throw CrossPlatformTransportException(.incompatible, "GameSettings.incrementSeconds must be a non-negative int")
        }
        // maxMovesCap is optional — null OR missing OR a positive int.
        // Tolerate key-absent symmetrically with key-present-null so a
        // forward-compat emitter doesn't break us.
        let cap: Int?
        switch map["maxMovesCap"] {
        case .none, .null?:
            cap = nil
        case .int(let raw)?:
            guard raw > 0, raw <= Int64(Int.max) else {
                throw CrossPlatformTransportException(.incompatible, "GameSettings.maxMovesCap must be a positive int or null")
            }
            cap = Int(raw)
        default:
            throw CrossPlatformTransportException(.incompatible, "GameSettings.maxMovesCap must be a positive int or null")
        }
        guard case .bool(let allowDraws)? = map["allowDrawOffers"] else {
            throw CrossPlatformTransportException(.incompatible, "GameSettings.allowDrawOffers must be a bool")
        }
        guard case .bool(let allowTakebacks)? = map["allowTakebacks"] else {
            throw CrossPlatformTransportException(.incompatible, "GameSettings.allowTakebacks must be a bool")
        }
        return CrossPlatformGameSettings(
            initialSeconds: Int(initial),
            incrementSeconds: Int(incr),
            maxMovesCap: cap,
            allowDrawOffers: allowDraws,
            allowTakebacks: allowTakebacks
        )
    }
}

/// Verification triple for ``CrossPlatformChessGameAction/requestResume``.
/// Mirror of the iOS ``ResumePayload`` in
/// `chess-up/Packages/ChessMultiplayer/Sources/ChessGameMessage.swift`.
///
/// Wire shape (canonical JSON, keys sorted):
///
/// ```json
/// {
///   "blackSecondsRemaining": 743.5,
///   "gid": "<UUID-string>",
///   "moveCount": 12,
///   "whiteSecondsRemaining": 712.0
/// }
/// ```
///
/// The two `Double` clock fields are emitted via
/// `JSONElement.number(formattedDouble)` so the canonical bytes are stable
/// across platforms — Swift's `Double.description` is the shortest
/// round-trippable decimal which both Kotlin and Swift can re-parse. The
/// receiver MUST tolerate both integral-decimal (e.g. `"712"`) and
/// fractional (`"712.0"`) forms on decode; canonical emission is always the
/// shortest round-trippable form.
public struct CrossPlatformResumePayload: Sendable, Equatable, Hashable {
    public let gid: String
    public let moveCount: Int
    public let whiteSecondsRemaining: Double
    public let blackSecondsRemaining: Double

    public init(
        gid: String,
        moveCount: Int,
        whiteSecondsRemaining: Double,
        blackSecondsRemaining: Double
    ) {
        self.gid = gid
        self.moveCount = moveCount
        self.whiteSecondsRemaining = whiteSecondsRemaining
        self.blackSecondsRemaining = blackSecondsRemaining
    }

    func toJsonElement() -> JSONElement {
        return .object([
            ("gid", .string(gid)),
            ("moveCount", .int(Int64(moveCount))),
            ("whiteSecondsRemaining", .number(CrossPlatformResumePayload.formatDouble(whiteSecondsRemaining))),
            ("blackSecondsRemaining", .number(CrossPlatformResumePayload.formatDouble(blackSecondsRemaining))),
        ])
    }

    static func fromJsonElement(_ element: JSONElement) throws -> CrossPlatformResumePayload {
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "ResumePayload must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard case .string(let gid)? = map["gid"], !gid.isEmpty else {
            throw CrossPlatformTransportException(.incompatible, "ResumePayload.gid must be a non-empty string")
        }
        guard case .int(let moveCount)? = map["moveCount"], moveCount >= 0, moveCount <= Int64(Int.max) else {
            throw CrossPlatformTransportException(.incompatible, "ResumePayload.moveCount must be a non-negative int")
        }
        let white = try Self.parseSeconds(map["whiteSecondsRemaining"], field: "whiteSecondsRemaining")
        let black = try Self.parseSeconds(map["blackSecondsRemaining"], field: "blackSecondsRemaining")
        return CrossPlatformResumePayload(
            gid: gid,
            moveCount: Int(moveCount),
            whiteSecondsRemaining: white,
            blackSecondsRemaining: black
        )
    }

    /// Tolerant decoder for the per-side clock seconds. Accepts either the
    /// integral path (`.int`) — emitted by an emitter that happens to land
    /// on a whole-second value Kotlin chose to encode as `Long` — OR the
    /// stringly-formatted decimal we canonically emit (`.number`). Anything
    /// else is a wire-format violation.
    private static func parseSeconds(_ element: JSONElement?, field: String) throws -> Double {
        switch element {
        case .int(let raw)?:
            return Double(raw)
        case .number(let s)?:
            guard let v = Double(s), v.isFinite, v >= 0 else {
                throw CrossPlatformTransportException(.incompatible, "ResumePayload.\(field) must be a non-negative finite decimal")
            }
            return v
        default:
            throw CrossPlatformTransportException(.incompatible, "ResumePayload.\(field) must be a number")
        }
    }

    /// Format `v` as the shortest round-trippable decimal. Swift's
    /// `Double.description` emits this form (`"712.0"` for whole seconds,
    /// `"743.5"` for fractional). Negative values are clamped to `0.0`
    /// before formatting so a transient sub-zero from a flag-fall race
    /// can't escape the emitter.
    static func formatDouble(_ v: Double) -> String {
        let clamped = max(0, v)
        return clamped.description
    }
}

/// Bare-gid payload for ``CrossPlatformChessGameAction/acceptResume`` and
/// ``CrossPlatformChessGameAction/declineResume``. Mirror of the iOS
/// ``ResumeAck`` struct.
///
/// Wire shape (canonical JSON):
///
/// ```json
/// { "gid": "<UUID-string>" }
/// ```
public struct CrossPlatformResumeAck: Sendable, Equatable, Hashable {
    public let gid: String

    public init(gid: String) {
        self.gid = gid
    }

    func toJsonElement() -> JSONElement {
        return .object([
            ("gid", .string(gid)),
        ])
    }

    static func fromJsonElement(_ element: JSONElement) throws -> CrossPlatformResumeAck {
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "ResumeAck must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard case .string(let gid)? = map["gid"], !gid.isEmpty else {
            throw CrossPlatformTransportException(.incompatible, "ResumeAck.gid must be a non-empty string")
        }
        return CrossPlatformResumeAck(gid: gid)
    }
}

public enum CrossPlatformChessGameAction: Sendable, Equatable, Hashable {
    case start(hostColor: CrossPlatformWireColor, startingFEN: String)
    case gameSettings(CrossPlatformGameSettings)
    case move(uci: String)
    case resign
    case offerDraw
    case acceptDraw
    case declineDraw
    case requestTakeback
    case acceptTakeback
    case declineTakeback
    case emote(emoji: String)
    /// Requester vouches "I have a saved record with this gid + verification
    /// triple". Sent immediately after the reconnect handshake completes,
    /// before any `.start`/`.gameSettings`. See iOS task #161.
    case requestResume(payload: CrossPlatformResumePayload)
    /// Responder accepts: it also has a matching saved record. Both sides
    /// then reconstruct from their LOCAL store and continue play.
    case acceptResume(payload: CrossPlatformResumeAck)
    /// Responder declines (mismatched verification, no local record, or
    /// user opted out). Both sides delete the saved record.
    case declineResume(payload: CrossPlatformResumeAck)

    /// Curated emote set — MUST match the iOS reference at
    /// `ChessGameMessage.swift` L47-50 (`chessUpEmotes`).
    public static let chessUpEmotes: [String] = [
        "\u{1F525}", // 🔥
        "\u{1F44F}", // 👏
        "\u{1F914}", // 🤔
        "\u{1F608}", // 😈
        "\u{1F92F}", // 🤯
        "\u{1F91D}", // 🤝
        "\u{1F605}", // 😅
        "\u{1F451}", // 👑
    ]

    /// Encode this action to a ``JSONElement`` (an object with exactly one
    /// discriminator key). The canonical-JSON emitter sorts keys at output
    /// time; the per-variant inner ordering is irrelevant for bytes.
    func toJsonElement() -> JSONElement {
        switch self {
        case .start(let hostColor, let startingFEN):
            return .object([
                ("start", .object([
                    ("hostColor", .string(hostColor.rawValue)),
                    ("startingFEN", .string(startingFEN)),
                ])),
            ])
        case .gameSettings(let settings):
            return .object([
                ("gameSettings", settings.toJsonElement()),
            ])
        case .move(let uci):
            return .object([
                ("move", .object([
                    ("uci", .string(uci)),
                ])),
            ])
        case .resign:
            return .object([("resign", .object([]))])
        case .offerDraw:
            return .object([("offerDraw", .object([]))])
        case .acceptDraw:
            return .object([("acceptDraw", .object([]))])
        case .declineDraw:
            return .object([("declineDraw", .object([]))])
        case .requestTakeback:
            return .object([("requestTakeback", .object([]))])
        case .acceptTakeback:
            return .object([("acceptTakeback", .object([]))])
        case .declineTakeback:
            return .object([("declineTakeback", .object([]))])
        case .emote(let emoji):
            return .object([
                ("emote", .object([
                    ("emoji", .string(emoji)),
                ])),
            ])
        case .requestResume(let payload):
            return .object([
                ("requestResume", payload.toJsonElement()),
            ])
        case .acceptResume(let payload):
            return .object([
                ("acceptResume", payload.toJsonElement()),
            ])
        case .declineResume(let payload):
            return .object([
                ("declineResume", payload.toJsonElement()),
            ])
        }
    }

    /// Encode this action to its canonical UTF-8 bytes. Mostly useful for the
    /// vector-4 test (which encodes each variant in isolation); production
    /// emission goes through ``GameActionEnvelope/encodeCanonical()``.
    public func encodeCanonical() -> Data {
        CanonicalJSON.encode(toJsonElement())
    }

    /// Construct a `move` ensuring lowercase canonicality. Use this instead of
    /// the raw enum case if the source UCI string is operator-supplied.
    public static func makeMove(uci: String) throws -> CrossPlatformChessGameAction {
        let normalized = uci.lowercased()
        guard CrossPlatformChessGameAction.isValidUCI(normalized) else {
            throw CrossPlatformTransportException(.incompatible, "invalid UCI: \(uci)")
        }
        return .move(uci: normalized)
    }

    /// Decode from a ``JSONElement`` — the object MUST contain exactly one
    /// discriminator key from the closed v1 set.
    static func fromJsonElement(_ element: JSONElement) throws -> CrossPlatformChessGameAction {
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "ChessGameAction must be a JSON object")
        }
        guard pairs.count == 1 else {
            throw CrossPlatformTransportException(
                .incompatible,
                "ChessGameAction must contain exactly one discriminator key, got: \(pairs.map { $0.0 })"
            )
        }
        let (key, inner) = pairs[0]
        switch key {
        case "start":
            guard case .object(let innerPairs) = inner else {
                throw CrossPlatformTransportException(.incompatible, "start payload must be a JSON object")
            }
            let map = Dictionary(uniqueKeysWithValues: innerPairs)
            guard case .string(let hostColorRaw)? = map["hostColor"] else {
                throw CrossPlatformTransportException(.incompatible, "start.hostColor must be a string")
            }
            guard case .string(let startingFEN)? = map["startingFEN"] else {
                throw CrossPlatformTransportException(.incompatible, "start.startingFEN must be a string")
            }
            return .start(hostColor: try CrossPlatformWireColor.fromWire(hostColorRaw), startingFEN: startingFEN)
        case "move":
            guard case .object(let innerPairs) = inner else {
                throw CrossPlatformTransportException(.incompatible, "move payload must be a JSON object")
            }
            let map = Dictionary(uniqueKeysWithValues: innerPairs)
            guard case .string(let uci)? = map["uci"] else {
                throw CrossPlatformTransportException(.incompatible, "move.uci must be a string")
            }
            let normalized = uci.lowercased()
            guard isValidUCI(normalized) else {
                throw CrossPlatformTransportException(.incompatible, "invalid UCI: \(uci)")
            }
            return .move(uci: normalized)
        case "gameSettings":
            return .gameSettings(try CrossPlatformGameSettings.fromJsonElement(inner))
        case "resign":           return .resign
        case "offerDraw":        return .offerDraw
        case "acceptDraw":       return .acceptDraw
        case "declineDraw":      return .declineDraw
        case "requestTakeback":  return .requestTakeback
        case "acceptTakeback":   return .acceptTakeback
        case "declineTakeback":  return .declineTakeback
        case "emote":
            guard case .object(let innerPairs) = inner else {
                throw CrossPlatformTransportException(.incompatible, "emote payload must be a JSON object")
            }
            let map = Dictionary(uniqueKeysWithValues: innerPairs)
            guard case .string(let emoji)? = map["emoji"] else {
                throw CrossPlatformTransportException(.incompatible, "emote.emoji must be a string")
            }
            return .emote(emoji: emoji)
        case "requestResume":
            return .requestResume(payload: try CrossPlatformResumePayload.fromJsonElement(inner))
        case "acceptResume":
            return .acceptResume(payload: try CrossPlatformResumeAck.fromJsonElement(inner))
        case "declineResume":
            return .declineResume(payload: try CrossPlatformResumeAck.fromJsonElement(inner))
        default:
            throw CrossPlatformTransportException(.incompatible, "unknown ChessGameAction discriminator: \(key)")
        }
    }

    /// UCI grammar per the iOS `parseUCI` helper at
    /// `ChessGameMessage.swift` L75-94. 4 or 5 lowercase ASCII chars;
    /// `[a-h][1-8][a-h][1-8](qrbn)?`. Case-insensitive on receive (we
    /// normalize before checking).
    static func isValidUCI(_ s: String) -> Bool {
        let count = s.count
        guard count == 4 || count == 5 else { return false }
        let chars = Array(s)
        for i in 0..<4 {
            let c = chars[i]
            let ok: Bool
            if i % 2 == 0 {
                ok = ("a"..."h").contains(c)
            } else {
                ok = ("1"..."8").contains(c)
            }
            if !ok { return false }
        }
        if count == 5, !["q", "r", "b", "n"].contains(chars[4]) { return false }
        return true
    }
}
