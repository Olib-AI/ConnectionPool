// Handshake.swift
// ConnectionPool / CrossPlatform
//
// Plaintext handshake frames (type 0x02). Spec §5.1. Mirrors Kotlin
// `Handshake.kt`. Two messages:
//
//   * ClientHello (guest → host)
//   * ServerHello (host → guest, either success or rejection)
//
// Receivers MUST accept any key order; emitters MUST emit canonical bytes.
// Unknown handshake `kind` surfaces as `CrossPlatformTransportException(.incompatible)`
// per ADR-0005 §2.2 / ADR-0004 §2.6.

import Foundation

public enum CrossPlatformHandshake {
    public static let protocolVersion: Int = 1
    public static let capChess1: String = "chess.1"
    public static let defaultHostColor: String = "white"
    public static let standardStartingFEN: String =
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
}

public protocol CrossPlatformHandshakeMessage {
    func encodeCanonical() -> Data
}

extension CrossPlatformHandshake {
    /// Decode any plaintext handshake JSON byte sequence. Receivers MUST
    /// tolerate any key order and any unknown fields (forward compatibility).
    public static func decode(_ data: Data) throws -> CrossPlatformHandshakeMessage {
        let element = try CanonicalJSON.decode(data)
        guard case .object(let pairs) = element else {
            throw CrossPlatformTransportException(.incompatible, "handshake must be a JSON object")
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard case .string(let kind)? = map["kind"] else {
            throw CrossPlatformTransportException(.incompatible, "handshake.kind must be a string")
        }
        switch kind {
        case "client_hello":
            return try ClientHello.fromObject(map)
        case "server_hello":
            return try ServerHello.fromObject(map)
        default:
            throw CrossPlatformTransportException(.incompatible, "unknown handshake kind: \(kind)")
        }
    }
}

public struct CrossPlatformClientHelloResume: Sendable, Equatable {
    public let sessionId: String
    public let ackedSeq: UInt32

    public init(sessionId: String, ackedSeq: UInt32) {
        self.sessionId = sessionId
        self.ackedSeq = ackedSeq
    }
}

public struct ClientHello: CrossPlatformHandshakeMessage, Sendable, Equatable {
    public let pid: Data
    public let name: String
    public let nonceC: Data
    public let codeHash: Data
    public let cap: String
    public let resume: CrossPlatformClientHelloResume?
    public let version: Int

    public init(
        pid: Data,
        name: String,
        nonceC: Data,
        codeHash: Data,
        cap: String = CrossPlatformHandshake.capChess1,
        resume: CrossPlatformClientHelloResume? = nil,
        version: Int = CrossPlatformHandshake.protocolVersion
    ) {
        precondition(pid.count == 16, "pid must be 16 bytes")
        precondition(nonceC.count == 16, "nonce_c must be 16 bytes")
        precondition(codeHash.count == 16, "code_hash must be 16 bytes")
        self.pid = pid
        self.name = name
        self.nonceC = nonceC
        self.codeHash = codeHash
        self.cap = cap
        self.resume = resume
        self.version = version
    }

    public func encodeCanonical() -> Data {
        let resumeElement: JSONElement
        if let r = resume {
            resumeElement = .object([
                ("acked_seq", .int(Int64(r.ackedSeq))),
                ("session_id", .string(r.sessionId)),
            ])
        } else {
            resumeElement = .null
        }
        let pairs: [(String, JSONElement)] = [
            ("cap", .string(cap)),
            ("code_hash", .string(CrossPlatformBase64.encode16(codeHash))),
            ("kind", .string("client_hello")),
            ("name", .string(name)),
            ("nonce_c", .string(CrossPlatformBase64.encode16(nonceC))),
            ("pid", .string(CrossPlatformBase64.encode16(pid))),
            ("resume", resumeElement),
            ("v", .int(Int64(version))),
        ]
        return CanonicalJSON.encode(.object(pairs))
    }

    static func fromObject(_ map: [String: JSONElement]) throws -> ClientHello {
        guard case .int(let v)? = map["v"] else {
            throw CrossPlatformTransportException(.incompatible, "client_hello.v must be an int")
        }
        let pid = try decode16(map, key: "pid")
        guard case .string(let name)? = map["name"] else {
            throw CrossPlatformTransportException(.incompatible, "client_hello.name must be a string")
        }
        let nonceC = try decode16(map, key: "nonce_c")
        let codeHash = try decode16(map, key: "code_hash")
        guard case .string(let cap)? = map["cap"] else {
            throw CrossPlatformTransportException(.incompatible, "client_hello.cap must be a string")
        }
        var resume: CrossPlatformClientHelloResume? = nil
        if let resumeElement = map["resume"] {
            switch resumeElement {
            case .null: resume = nil
            case .object(let resumePairs):
                let rmap = Dictionary(uniqueKeysWithValues: resumePairs)
                guard case .string(let sessionId)? = rmap["session_id"] else {
                    throw CrossPlatformTransportException(.incompatible, "client_hello.resume.session_id must be a string")
                }
                guard case .int(let acked)? = rmap["acked_seq"], acked >= 0, acked <= Int64(UInt32.max) else {
                    throw CrossPlatformTransportException(.incompatible, "client_hello.resume.acked_seq must be a u32")
                }
                resume = CrossPlatformClientHelloResume(sessionId: sessionId, ackedSeq: UInt32(acked))
            default:
                throw CrossPlatformTransportException(.incompatible, "client_hello.resume must be null or an object")
            }
        }
        return ClientHello(
            pid: pid,
            name: name,
            nonceC: nonceC,
            codeHash: codeHash,
            cap: cap,
            resume: resume,
            version: Int(v)
        )
    }

    private static func decode16(_ map: [String: JSONElement], key: String) throws -> Data {
        guard case .string(let s)? = map[key] else {
            throw CrossPlatformTransportException(.incompatible, "\(key) must be a string")
        }
        guard s.count == 22 else {
            throw CrossPlatformTransportException(.incompatible, "\(key) must be exactly 22 base64url chars (16 raw bytes), got \(s.count)")
        }
        guard let bytes = CrossPlatformBase64.decodeUrl(s), bytes.count == 16 else {
            throw CrossPlatformTransportException(.incompatible, "\(key) decoded to wrong length; expected 16")
        }
        return bytes
    }
}

public enum ServerHello: CrossPlatformHandshakeMessage, Sendable {
    case ok(Ok)
    case failure(Failure)

    public struct Ok: Sendable, Equatable {
        public let pid: Data
        public let name: String
        public let nonceH: Data
        public let sessionId: Data
        public let hostColor: String
        public let startingFEN: String
        public let version: Int

        public init(
            pid: Data,
            name: String,
            nonceH: Data,
            sessionId: Data,
            hostColor: String = CrossPlatformHandshake.defaultHostColor,
            startingFEN: String = CrossPlatformHandshake.standardStartingFEN,
            version: Int = CrossPlatformHandshake.protocolVersion
        ) {
            precondition(pid.count == 16, "pid must be 16 bytes")
            precondition(nonceH.count == 16, "nonce_h must be 16 bytes")
            precondition(sessionId.count == 16, "session_id must be 16 bytes")
            self.pid = pid
            self.name = name
            self.nonceH = nonceH
            self.sessionId = sessionId
            self.hostColor = hostColor
            self.startingFEN = startingFEN
            self.version = version
        }

        public var sessionIdB64u: String { CrossPlatformBase64.encode16(sessionId) }
    }

    public struct Failure: Sendable, Equatable {
        public let err: String
        public let version: Int

        public init(err: String, version: Int = CrossPlatformHandshake.protocolVersion) {
            self.err = err
            self.version = version
        }
    }

    public func encodeCanonical() -> Data {
        switch self {
        case .ok(let ok):
            let pairs: [(String, JSONElement)] = [
                ("host_color", .string(ok.hostColor)),
                ("kind", .string("server_hello")),
                ("name", .string(ok.name)),
                ("nonce_h", .string(CrossPlatformBase64.encode16(ok.nonceH))),
                ("ok", .bool(true)),
                ("pid", .string(CrossPlatformBase64.encode16(ok.pid))),
                ("session_id", .string(CrossPlatformBase64.encode16(ok.sessionId))),
                ("starting_fen", .string(ok.startingFEN)),
                ("v", .int(Int64(ok.version))),
            ]
            return CanonicalJSON.encode(.object(pairs))
        case .failure(let failure):
            let pairs: [(String, JSONElement)] = [
                ("err", .string(failure.err)),
                ("kind", .string("server_hello")),
                ("ok", .bool(false)),
                ("v", .int(Int64(failure.version))),
            ]
            return CanonicalJSON.encode(.object(pairs))
        }
    }

    static func fromObject(_ map: [String: JSONElement]) throws -> ServerHello {
        guard case .int(let v)? = map["v"] else {
            throw CrossPlatformTransportException(.incompatible, "server_hello.v must be an int")
        }
        guard case .bool(let okFlag)? = map["ok"] else {
            throw CrossPlatformTransportException(.incompatible, "server_hello.ok must be a boolean")
        }
        if okFlag {
            let pid = try decode16(map, key: "pid")
            guard case .string(let name)? = map["name"] else {
                throw CrossPlatformTransportException(.incompatible, "server_hello.name must be a string")
            }
            let nonceH = try decode16(map, key: "nonce_h")
            let sessionId = try decode16(map, key: "session_id")
            guard case .string(let hostColor)? = map["host_color"] else {
                throw CrossPlatformTransportException(.incompatible, "server_hello.host_color must be a string")
            }
            guard case .string(let startingFEN)? = map["starting_fen"] else {
                throw CrossPlatformTransportException(.incompatible, "server_hello.starting_fen must be a string")
            }
            return .ok(Ok(
                pid: pid,
                name: name,
                nonceH: nonceH,
                sessionId: sessionId,
                hostColor: hostColor,
                startingFEN: startingFEN,
                version: Int(v)
            ))
        } else {
            guard case .string(let err)? = map["err"] else {
                throw CrossPlatformTransportException(.incompatible, "server_hello.err must be a string")
            }
            return .failure(Failure(err: err, version: Int(v)))
        }
    }

    private static func decode16(_ map: [String: JSONElement], key: String) throws -> Data {
        guard case .string(let s)? = map[key] else {
            throw CrossPlatformTransportException(.incompatible, "\(key) must be a string")
        }
        guard s.count == 22 else {
            throw CrossPlatformTransportException(.incompatible, "\(key) must be exactly 22 base64url chars (16 raw bytes), got \(s.count)")
        }
        guard let bytes = CrossPlatformBase64.decodeUrl(s), bytes.count == 16 else {
            throw CrossPlatformTransportException(.incompatible, "\(key) decoded to wrong length; expected 16")
        }
        return bytes
    }
}
