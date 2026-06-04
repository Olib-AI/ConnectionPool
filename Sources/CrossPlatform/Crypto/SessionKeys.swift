// SessionKeys.swift
// ConnectionPool / CrossPlatform
//
// Per-session key triple derived from the 6-digit tap-code + the two handshake
// nonces. Spec §4.2; mirror of Kotlin `SessionKeys.kt`. Master key never
// leaves derivation — only `c2s` and `s2c` are used at runtime.
//
// Inputs are the literal 6-char ASCII tap code (e.g. `"482917"`), a 16-byte
// `nonce_c` from `client_hello`, and a 16-byte `nonce_h` from `server_hello`.

import Foundation

struct CrossPlatformSessionKeys: Sendable, Equatable {
    let master: Data
    let c2s: Data
    let s2c: Data

    init(master: Data, c2s: Data, s2c: Data) {
        precondition(master.count == 32, "K_master must be 32 bytes, got \(master.count)")
        precondition(c2s.count == 32, "K_c2s must be 32 bytes, got \(c2s.count)")
        precondition(s2c.count == 32, "K_s2c must be 32 bytes, got \(s2c.count)")
        self.master = master
        self.c2s = c2s
        self.s2c = s2c
    }

    /// Derive the per-session key triple from the tap-code + the two handshake
    /// nonces. Byte-for-byte matches vector 00 in `docs/vectors/00-hkdf.json`.
    static func derive(tapCode: String, nonceC: Data, nonceH: Data) -> CrossPlatformSessionKeys {
        precondition(nonceC.count == 16, "nonce_c must be 16 bytes")
        precondition(nonceH.count == 16, "nonce_h must be 16 bytes")

        // salt = nonce_c || nonce_h
        var salt = Data(capacity: 32)
        salt.append(nonceC)
        salt.append(nonceH)

        // ikm = utf8("chessup-pvp/v1") || utf8(tap_code)
        var ikm = Data(capacity: 14 + tapCode.utf8.count)
        ikm.append(Data("chessup-pvp/v1".utf8))
        ikm.append(Data(tapCode.utf8))

        let infoMaster = Data("chessup-pvp/v1/master".utf8)
        let infoC2S = Data("chessup-pvp/v1/c2s".utf8)
        let infoS2C = Data("chessup-pvp/v1/s2c".utf8)

        let master = CrossPlatformHKDF.derive(salt: salt, ikm: ikm, info: infoMaster, length: 32)
        let c2s = CrossPlatformHKDF.derive(salt: master, ikm: Data(), info: infoC2S, length: 32)
        let s2c = CrossPlatformHKDF.derive(salt: master, ikm: Data(), info: infoS2C, length: 32)
        return CrossPlatformSessionKeys(master: master, c2s: c2s, s2c: s2c)
    }
}
