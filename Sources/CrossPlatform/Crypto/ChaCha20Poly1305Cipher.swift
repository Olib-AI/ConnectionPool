// ChaCha20Poly1305Cipher.swift
// ConnectionPool / CrossPlatform
//
// ChaCha20-Poly1305 AEAD wrapper. Bound to CryptoKit
// `CryptoKit.ChaChaPoly` (iOS 13+ / macOS 10.15+). Surfaces auth failures
// as a sentinel `AuthFailure` so the framing layer maps them to
// `CrossPlatformTransportError.authFail` without a `catch (_)` swallow.
//
// 12-byte nonce per spec §4.3: `0x00 0x00 0x00 0x00 || counter_u64_be`.
// AAD = the single frame-type byte. Output = `ciphertext || tag_16`.

import CryptoKit
import Foundation

enum CrossPlatformChaCha20Poly1305 {

    static let tagSizeBytes: Int = 16
    static let nonceSizeBytes: Int = 12

    /// Build the 12-byte nonce per spec §4.3: 4 zero bytes || u64 BE counter.
    static func nonce(counter: UInt64) -> Data {
        var n = Data(count: nonceSizeBytes)
        // Bytes 0..3 stay zero; bytes 4..11 carry the big-endian counter.
        var v = counter
        for i in stride(from: 11, through: 4, by: -1) {
            n[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return n
    }

    /// Encrypt `plaintext` with `key`, returning `ciphertext || tag_16`.
    /// AAD is the supplied byte(s) — for the v1 spec this is always a single
    /// frame-type byte.
    static func encrypt(
        key: Data,
        counter: UInt64,
        plaintext: Data,
        aad: Data
    ) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let nonceData = nonce(counter: counter)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: symKey,
            nonce: chaChaNonce,
            authenticating: aad
        )
        // Wire format requires `ciphertext || tag_16`, NOT the combined
        // `nonce || ciphertext || tag`. Re-assemble explicitly.
        var out = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypt `ciphertextAndTag` with `key`. Throws ``AuthFailure`` on Poly1305
    /// verification failure so the caller can map cleanly to
    /// ``CrossPlatformTransportError/authFail``.
    static func decrypt(
        key: Data,
        counter: UInt64,
        ciphertextAndTag: Data,
        aad: Data
    ) throws -> Data {
        guard ciphertextAndTag.count >= tagSizeBytes else {
            throw AuthFailure("ciphertext+tag too short: \(ciphertextAndTag.count)")
        }
        let ctEnd = ciphertextAndTag.count - tagSizeBytes
        let ciphertext = ciphertextAndTag.prefix(ctEnd)
        let tag = ciphertextAndTag.suffix(tagSizeBytes)
        let symKey = SymmetricKey(data: key)
        let nonceData = nonce(counter: counter)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(
                nonce: chaChaNonce,
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw AuthFailure("SealedBox construction failed: \(error)")
        }
        do {
            return try ChaChaPoly.open(sealed, using: symKey, authenticating: aad)
        } catch {
            throw AuthFailure("ChaCha20-Poly1305 tag verification failed: \(error)")
        }
    }
}

/// Thrown by ``CrossPlatformChaCha20Poly1305/decrypt(key:counter:ciphertextAndTag:aad:)``
/// when the Poly1305 tag is invalid (wrong key, tampered ciphertext, or wrong
/// nonce/AAD). Surfaces to the framing layer as ``CrossPlatformTransportError/authFail``.
struct AuthFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { "AuthFailure: \(message)" }
}
