// HexCodecs.swift
// ConnectionPool / CrossPlatform
//
// Lowercase-hex helpers — mirror of Kotlin `HexCodecs.kt`. Tests + debug logs.

import Foundation

enum CrossPlatformHexCodecs {

    static func encode(_ bytes: Data) -> String {
        var s = String()
        s.reserveCapacity(bytes.count * 2)
        let table: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
        for byte in bytes {
            s.append(table[Int(byte >> 4)])
            s.append(table[Int(byte & 0x0F)])
        }
        return s
    }

    static func decode(_ hex: String) throws -> Data {
        guard hex.count % 2 == 0 else {
            throw CrossPlatformTransportException(.incompatible, "hex length must be even: \(hex.count)")
        }
        var out = Data(capacity: hex.count / 2)
        let chars = Array(hex)
        var i = 0
        while i < chars.count {
            let hi = try digit(chars[i])
            let lo = try digit(chars[i + 1])
            out.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return out
    }

    private static func digit(_ c: Character) throws -> Int {
        switch c {
        case "0"..."9": return Int(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return 10 + Int(c.asciiValue! - Character("a").asciiValue!)
        case "A"..."F": return 10 + Int(c.asciiValue! - Character("A").asciiValue!)
        default: throw CrossPlatformTransportException(.incompatible, "invalid hex char: \(c)")
        }
    }
}
