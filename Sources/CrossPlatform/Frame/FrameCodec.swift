// FrameCodec.swift
// ConnectionPool / CrossPlatform
//
// Length-prefixed framing per spec §3:
//
//   frame := u32_be length || body
//   body  := u8 type || data
//
// Bound is 1 MiB. Encrypted-frame layout (for type ∈ {0x01, 0x03, 0x04, 0x05}):
//
//   u8 type
//   u64 counter (big-endian; matches the nonce's counter)
//   ciphertext (variable; equals plaintext length)
//   u8[16] tag (Poly1305 authentication tag)
//
// AAD = the single `type` byte. Per-direction monotone-strict u64 counter
// starts at 0 and increments by 1 per emitted encrypted frame.
//
// Mirrors Kotlin `FrameCodec.kt` byte-for-byte.

import Foundation

enum CrossPlatformFrameCodec {

    static let maxBodyBytes: Int = 1 * 1024 * 1024 // 1 MiB

    // MARK: - Build (out-bound)

    /// Wrap a `body` in the `u32 length` prefix. Returns the full on-wire frame.
    static func frameOf(body: Data) -> Data {
        precondition(!body.isEmpty, "body must be non-empty")
        precondition(body.count <= maxBodyBytes, "body exceeds 1 MiB: \(body.count)")
        var out = Data(capacity: 4 + body.count)
        writeU32Be(into: &out, value: UInt32(body.count))
        out.append(body)
        return out
    }

    /// Build a `HANDSHAKE` body: `u8 0x02 || plaintext JSON`.
    static func handshakeBody(plaintextJson: Data) -> Data {
        var body = Data(capacity: 1 + plaintextJson.count)
        body.append(CrossPlatformFrameType.handshake.rawValue)
        body.append(plaintextJson)
        return body
    }

    /// Build an encrypted body for `type` ∈ {0x01, 0x03, 0x04, 0x05}.
    /// AAD is the single type byte.
    static func encryptedBody(
        type: CrossPlatformFrameType,
        key: Data,
        counter: UInt64,
        plaintext: Data
    ) throws -> Data {
        precondition(type != .handshake, "HANDSHAKE is plaintext")
        let aad = Data([type.rawValue])
        let ct = try CrossPlatformChaCha20Poly1305.encrypt(
            key: key,
            counter: counter,
            plaintext: plaintext,
            aad: aad
        )
        // body = u8 type || u64 counter || (ciphertext || tag_16)
        var body = Data(capacity: 1 + 8 + ct.count)
        body.append(type.rawValue)
        writeU64Be(into: &body, value: counter)
        body.append(ct)
        return body
    }

    // MARK: - Parse (in-bound)

    /// Result of a single inbound-frame body parse.
    struct IncomingFrame: Equatable {
        let type: CrossPlatformFrameType
        let body: Data
    }

    /// Read a single frame from the caller-provided async byte source.
    /// `readExact(n)` returns exactly `n` bytes, `nil` on EOF before any bytes
    /// are read (clean close), and throws on a partial-read EOF or any I/O
    /// error. The caller-provided reader allows the same codec to drive both
    /// `NWConnection.receive(...)` over real TCP and the `InMemoryConnection`
    /// test loopback.
    static func readFrame(
        readExact: @Sendable (Int) async throws -> Data?
    ) async throws -> IncomingFrame? {
        guard let lenBytes = try await readExact(4) else { return nil }
        let length = readU32Be(lenBytes)
        if length == 0 { throw CrossPlatformTransportException(.emptyFrame) }
        if length > UInt32(maxBodyBytes) { throw CrossPlatformTransportException(.frameTooLarge) }
        guard let body = try await readExact(Int(length)) else {
            throw CrossPlatformTransportException(.handshakeTimeout, "EOF after length prefix")
        }
        guard let type = CrossPlatformFrameType.fromTag(body[body.startIndex]) else {
            throw CrossPlatformTransportException(.unknownFrameType)
        }
        return IncomingFrame(type: type, body: body)
    }

    /// Decrypt an encrypted body in-place, returning plaintext. Validates the
    /// `(type, counter)` envelope and strict-monotonic counter against
    /// ``tracker``.
    static func decryptBody(
        body: Data,
        key: Data,
        tracker: CounterTracker
    ) throws -> Data {
        precondition(body.count >= 1 + 8 + 16, "encrypted body too short: \(body.count)")
        let base = body.startIndex
        guard let type = CrossPlatformFrameType.fromTag(body[base]) else {
            throw CrossPlatformTransportException(.unknownFrameType)
        }
        if type == .handshake {
            // Spec §3.1 / FrameCodec.kt: post-handshake HANDSHAKE frames are
            // out-of-phase, not unknown-tag. Map to INCOMPATIBLE.
            throw CrossPlatformTransportException(.incompatible, "HANDSHAKE frame received post-handshake (out of phase)")
        }
        let counter = readU64Be(body, offset: base + 1)
        try tracker.assertStrictMonotonic(counter)

        let ctStart = base + 9
        let ctAndTag = body[ctStart..<body.endIndex]
        let aad = Data([type.rawValue])
        let plaintext: Data
        do {
            plaintext = try CrossPlatformChaCha20Poly1305.decrypt(
                key: key,
                counter: counter,
                ciphertextAndTag: Data(ctAndTag),
                aad: aad
            )
        } catch is AuthFailure {
            throw CrossPlatformTransportException(.authFail, "Poly1305 tag verification failed")
        } catch {
            throw CrossPlatformTransportException(.authFail, "decrypt failed: \(error)")
        }
        tracker.commit(counter)
        return plaintext
    }

    // MARK: - Endian helpers

    static func writeU32Be(into out: inout Data, value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    static func writeU64Be(into out: inout Data, value: UInt64) {
        var v = value
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in (0..<8).reversed() {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        out.append(contentsOf: bytes)
    }

    static func readU32Be(_ src: Data) -> UInt32 {
        let base = src.startIndex
        let a = UInt32(src[base])
        let b = UInt32(src[base + 1])
        let c = UInt32(src[base + 2])
        let d = UInt32(src[base + 3])
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    static func readU64Be(_ src: Data, offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(src[offset + i])
        }
        return v
    }
}

/// Per-direction encryption-counter tracker. Receivers instantiate one per
/// direction and call ``assertStrictMonotonic(_:)`` before AEAD decryption (so
/// a replay never even pays for the Poly1305 verify); on success the framing
/// layer calls ``commit(_:)`` to advance the watermark.
///
/// `Sendable` is unchecked because the tracker is logically owned by the
/// reader actor; concurrent use would be a programming error.
final class CounterTracker: @unchecked Sendable {
    private var lastSeen: Int64 = -1
    private let lock = NSLock()

    func assertStrictMonotonic(_ counter: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        // Strict: must be strictly greater than the last seen one. Counter 0
        // is valid only as the FIRST frame in the direction (lastSeen is -1).
        let cAsInt: Int64
        if counter > UInt64(Int64.max) {
            // unreachable in practice (584M years at 1 frame/ms); be defensive.
            cAsInt = Int64.max
        } else {
            cAsInt = Int64(counter)
        }
        if cAsInt <= lastSeen {
            throw CrossPlatformTransportException(.seqReplay, "counter \(counter) <= lastSeen \(lastSeen)")
        }
    }

    func commit(_ counter: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        lastSeen = Int64(counter)
    }

    func snapshot() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return lastSeen
    }
}

/// Per-direction encryption-counter source. Emitters call ``next()`` to get
/// the counter for the frame they're about to build. Wraps at 2^63-1; we do
/// not defend against overflow — at one frame per millisecond a u64 counter
/// overflows after ~584M years (spec §4.3).
final class CounterSource: @unchecked Sendable {
    private var next_: UInt64 = 0
    private let lock = NSLock()

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let v = next_
        next_ = v &+ 1
        return v
    }
}
