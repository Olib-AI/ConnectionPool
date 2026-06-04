// FrameType.swift
// ConnectionPool / CrossPlatform
//
// Closed enum of on-the-wire frame tags. Spec §3.1. Receivers reject anything
// outside this set with `CrossPlatformTransportError.unknownFrameType`. Mirrors Kotlin
// `FrameType.kt`.

import Foundation

public enum CrossPlatformFrameType: UInt8, Sendable, Hashable, CaseIterable {
    case encryptedPoolMessage = 0x01
    case handshake = 0x02
    case ping = 0x03
    case pong = 0x04
    case bye = 0x05

    static func fromTag(_ b: UInt8) -> CrossPlatformFrameType? {
        CrossPlatformFrameType(rawValue: b)
    }
}
