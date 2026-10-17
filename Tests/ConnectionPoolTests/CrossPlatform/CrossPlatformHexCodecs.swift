// CrossPlatformHexCodecs.swift
// ConnectionPoolTests / CrossPlatform
//
// Lowercase hex encode/decode used to compare bytes against the frozen
// cross-platform reference vectors.

import Foundation

enum CrossPlatformHexCodecs {

    enum DecodeError: Error, Equatable {
        case oddLength(Int)
        case invalidCharacter(Character)
    }

    private static let digits = Array("0123456789abcdef".utf8)

    static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ hex: String) throws(DecodeError) -> Data {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { throw .oddLength(chars.count) }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            data.append(try nibble(chars[index]) << 4 | nibble(chars[index + 1]))
            index += 2
        }
        return data
    }

    private static func nibble(_ char: Character) throws(DecodeError) -> UInt8 {
        guard let value = char.hexDigitValue else { throw .invalidCharacter(char) }
        return UInt8(value)
    }
}
