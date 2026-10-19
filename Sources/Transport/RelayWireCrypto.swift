// RelayWireCrypto.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Pure, deterministic byte layouts shared by WebSocketTransport and its tests. Every
// function here reproduces the exact bytes WebSocketTransport produced before it was
// extracted; the golden vectors in Tests/ConnectionPoolTests/Golden pin them.

import Foundation
import CryptoKit

// MARK: - WebSocket Outer Layer

/// The pool-secret AES-256-GCM layer applied to every relayed WebSocket payload.
///
/// Key: HKDF-SHA256(ikm = pool shared secret, salt = empty, info = "stealth-ws-encrypt", 32).
/// Frame: AES-GCM combined nonce(12) || ciphertext || tag(16), random nonce, no AAD.
enum WSOuterLayer {
    static let keyInfo = Data("stealth-ws-encrypt".utf8)

    static func deriveKey(poolSharedSecret: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: poolSharedSecret, info: keyInfo, outputByteCount: 32)
    }

    /// Seals with a fresh random nonce. Throws instead of ever returning plaintext.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    /// Opens a combined frame; `nil` on any malformed or tampered input.
    static func open(_ combined: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

// MARK: - Relay Transcripts

/// Signed / MAC'd byte layouts exchanged with StealthRelay. Integers are big-endian and
/// UUIDs are their 16 raw RFC 4122 bytes. These are frozen v1 server contracts.
enum RelayTranscripts {
    static let hostAuthLabel = Data("STEALTH_HOST_AUTH_V1:".utf8)
    static let inviteInfoLabel = Data("STEALTH_INVITE_V1".utf8)
    static let joinLabel = Data("JOIN".utf8)

    static func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func be64(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// `"STEALTH_HOST_AUTH_V1:" || pool_id(16) || timestamp i64 BE || server nonce (raw, any length)`.
    static func hostAuth(poolID: UUID, timestamp: Int64, serverNonce: Data) -> Data {
        hostAuthLabel + uuidBytes(poolID) + be64(timestamp) + serverNonce
    }

    /// Invitation verification key:
    /// HKDF-SHA256(ikm = token secret, salt = pool_id(16), info = "STEALTH_INVITE_V1" || token_id, 32).
    static func inviteVerificationKey(tokenSecret: Data, poolID: UUID, tokenID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tokenSecret),
            salt: uuidBytes(poolID),
            info: inviteInfoLabel + tokenID,
            outputByteCount: 32
        )
    }

    /// `"JOIN" || pool_id(16) || timestamp i64 BE || nonce`.
    static func joinProofMessage(poolID: UUID, timestamp: Int64, nonce: Data) -> Data {
        joinLabel + uuidBytes(poolID) + be64(timestamp) + nonce
    }

    /// HMAC-SHA256(verification key, join proof message).
    static func joinProof(tokenSecret: Data, tokenID: Data, poolID: UUID, timestamp: Int64, nonce: Data) -> Data {
        let key = inviteVerificationKey(tokenSecret: tokenSecret, poolID: poolID, tokenID: tokenID)
        let message = joinProofMessage(poolID: poolID, timestamp: timestamp, nonce: nonce)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

// MARK: - Proof of Work

/// Client side of the StealthRelay hashcash challenge:
/// find the smallest u64 `n` (from 0) with
/// `leading_zero_bits(SHA-256("STEALTH_POW" || challenge || n as 8 bytes BE)) >= difficulty`.
///
/// Hardening (a malicious relay must not be able to pin a CPU core forever):
/// - the challenge must be exactly 32 bytes, as `stealthos-crypto` issues;
/// - the difficulty must be at most ``maxAcceptedDifficulty`` (26, the top tier of
///   `stealthos_crypto::pow::recommended_difficulty`; the relay currently issues 18);
/// - the search runs under a wall-clock budget and honours cancellation.
public enum ProofOfWork {

    /// Highest difficulty the relay can legitimately demand.
    public static let maxAcceptedDifficulty: UInt8 = 26

    /// Length of a relay-issued challenge.
    public static let challengeLength = 32

    /// Wall-clock budget. Shorter than the relay's 120 s challenge lifetime.
    public static let defaultTimeBudget: Duration = .seconds(90)

    /// How often (in hashes) the solver checks the clock and cancellation.
    static let checkInterval: UInt64 = 4096

    static let prefix: [UInt8] = Array("STEALTH_POW".utf8)

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case malformedChallenge
        case difficultyTooHigh(UInt8)
        case timedOut
        case cancelled

        public var description: String {
            switch self {
            case .malformedChallenge:
                return "The relay server sent a malformed proof-of-work challenge."
            case .difficultyTooHigh(let d):
                return "The relay server demanded proof-of-work difficulty \(d), above the maximum of \(ProofOfWork.maxAcceptedDifficulty) this app accepts. The server may be misconfigured or malicious."
            case .timedOut:
                return "Solving the relay server's proof-of-work challenge took too long."
            case .cancelled:
                return "Proof-of-work solving was cancelled."
            }
        }
    }

    public struct Challenge: Sendable, Equatable {
        public let bytes: Data
        public let base64: String
        public let difficulty: UInt8
    }

    /// Parses `"proof-of-work required: {"challenge":"<base64>","difficulty":<n>,"timestamp":<t>}"`
    /// and enforces the length and difficulty limits.
    public static func parse(message: String) -> Result<Challenge, Failure> {
        guard let jsonStart = message.range(of: "{"),
              let jsonData = String(message[jsonStart.lowerBound...]).data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PowChallengeData.self, from: jsonData),
              let bytes = Data(base64Encoded: parsed.challenge),
              bytes.count == challengeLength else {
            return .failure(.malformedChallenge)
        }
        guard parsed.difficulty <= maxAcceptedDifficulty else {
            return .failure(.difficultyTooHigh(parsed.difficulty))
        }
        return .success(Challenge(bytes: bytes, base64: parsed.challenge, difficulty: parsed.difficulty))
    }

    /// Searches for the smallest valid counter.
    ///
    /// - Parameters:
    ///   - deadline: Give up with ``Failure/timedOut`` once this instant passes.
    ///   - isCancelled: Polled every ``checkInterval`` hashes.
    /// - Returns: The 8-byte big-endian solution.
    public static func solve(
        challenge: Data,
        difficulty: UInt8,
        deadline: ContinuousClock.Instant,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws(Failure) -> [UInt8] {
        guard challenge.count == challengeLength else { throw .malformedChallenge }
        guard difficulty <= maxAcceptedDifficulty else { throw .difficultyTooHigh(difficulty) }

        let clock = ContinuousClock()
        var buffer = prefix + Array(challenge) + [UInt8](repeating: 0, count: 8)
        let counterOffset = buffer.count - 8
        let required = UInt32(difficulty)
        var counter: UInt64 = 0

        while true {
            if counter % checkInterval == 0 {
                if isCancelled() { throw .cancelled }
                if clock.now >= deadline { throw .timedOut }
            }
            withUnsafeBytes(of: counter.bigEndian) { raw in
                for i in 0..<8 { buffer[counterOffset + i] = raw[i] }
            }
            let digest = SHA256.hash(data: buffer)
            if leadingZeroBits(digest) >= required {
                return Array(buffer[counterOffset...])
            }
            if counter == UInt64.max { throw .timedOut }
            counter += 1
        }
    }

    /// `SHA-256("STEALTH_POW" || challenge || solution)`.
    public static func hash(challenge: Data, solution: [UInt8]) -> Data {
        Data(SHA256.hash(data: prefix + Array(challenge) + solution))
    }

    /// Leading zero bits of a byte sequence, most significant bit first.
    public static func leadingZeroBits<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var count: UInt32 = 0
        for byte in bytes {
            if byte == 0 {
                count += 8
            } else {
                count += UInt32(byte.leadingZeroBitCount)
                break
            }
        }
        return count
    }
}
