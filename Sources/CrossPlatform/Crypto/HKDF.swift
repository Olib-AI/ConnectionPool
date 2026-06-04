// HKDF.swift
// ConnectionPool / CrossPlatform
//
// RFC 5869 HKDF-SHA256. We bind to Apple's CryptoKit `HKDF<SHA256>` since
// iOS 14 / macOS 11+ (available on every supported deployment target). The
// vectors in `docs/vectors/00-hkdf.json` exercise the full extract + expand
// path with a non-empty salt and non-empty info string.

import CryptoKit
import Foundation

enum CrossPlatformHKDF {

    /// HKDF-SHA256 per RFC 5869. Inputs and output match the Kotlin reference
    /// (`Hkdf.kt`) byte-for-byte. `length` must be in `1...255 * 32`.
    static func derive(
        salt: Data,
        ikm: Data,
        info: Data,
        length: Int
    ) -> Data {
        // CryptoKit's `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`
        // performs both extract and expand. Salt is the empty Data fallback
        // handled per RFC 5869 §2.2 (defaults to a zero-string of HashLen); our
        // spec always supplies a non-empty salt, so the behaviour is
        // deterministic.
        let key = SymmetricKey(data: ikm)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
