// Base64Codecs.swift
// ConnectionPool / CrossPlatform
//
// Two RFC 4648 base64 dialects. Mirrors Kotlin `Base64Codecs.kt`.
//
//   * Standard (`+ /`, padded) — every byte-array that travels inside a
//     PoolMessage envelope. Matches the Kotlin `java.util.Base64` and the
//     Swift `Data` default. Required by spec §5.2.1.
//   * base64url (`- _`, NO padding) — every fixed-width handshake field
//     (`pid`, `nonce_c`, `nonce_h`, `session_id`, `code_hash`). 16 raw
//     bytes encode to exactly 22 base64url chars. Required by spec §1.

import Foundation

enum CrossPlatformBase64 {

    // ---- Standard (padded, `+` `/` alphabet) -------------------------------

    static func encodeStd(_ bytes: Data) -> String {
        bytes.base64EncodedString()
    }

    static func decodeStd(_ s: String) -> Data? {
        Data(base64Encoded: s)
    }

    // ---- URL-safe (NO padding, `-` `_` alphabet) ---------------------------

    static func encodeUrl(_ bytes: Data) -> String {
        let std = bytes.base64EncodedString()
        // Translate the alphabet and strip the `=` padding.
        var out = ""
        out.reserveCapacity(std.count)
        for ch in std {
            switch ch {
            case "+": out.append("-")
            case "/": out.append("_")
            case "=": break
            default:  out.append(ch)
            }
        }
        return out
    }

    /// Decode an unpadded base64url string. Tolerates input that *does* carry
    /// padding so peers emitting either form interop cleanly.
    static func decodeUrl(_ s: String) -> Data? {
        // Translate alphabet back to standard then re-pad to a multiple of 4.
        var std = ""
        std.reserveCapacity(s.count + 4)
        for ch in s {
            switch ch {
            case "-": std.append("+")
            case "_": std.append("/")
            default:  std.append(ch)
            }
        }
        while std.count % 4 != 0 { std.append("=") }
        return Data(base64Encoded: std)
    }

    /// Convenience: 16 raw bytes → exactly 22 base64url chars. Used for the
    /// `pid` / `nonce_c` / `nonce_h` / `session_id` / `code_hash` fields.
    static func encode16(_ bytes: Data) -> String {
        precondition(bytes.count == 16, "expected 16 bytes, got \(bytes.count)")
        return encodeUrl(bytes)
    }
}
