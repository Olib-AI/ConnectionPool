// PoolIntegritySecret.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

/// The pool-wide secret behind relay-envelope and topology MACs.
///
/// It is derived from the one secret every member of a local pool already shares: the
/// pool code (the host generates it; joiners type it in). `SHA-256(UTF-8 code)` is the
/// exact derivation StealthOS 1.4.x uses, so 1.4.x relays keep verifying v1 MACs.
///
/// Pools without a code, and remote (relay-server) pools, have no pool-wide secret: for
/// them this returns `nil` and mesh relaying is disabled (fail closed). The secret must
/// never be derived from device-local material (for example a peer's own public key),
/// because then no two peers would agree on it.
public enum PoolIntegritySecret {
    public static func derive(poolCode: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(poolCode.utf8)))
    }

    public static func derive(poolCode: String?) -> SymmetricKey? {
        poolCode.map { derive(poolCode: $0) }
    }
}
