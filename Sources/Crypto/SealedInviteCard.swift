// SealedInviteCard.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Binary `.stcard` envelope that carries an invitation URL inside an opaque
/// file format. The point of the wrapper is purely transport: iMessage,
/// AirDrop, Mail, and other text-handling pipelines won't apply
/// smart-punctuation or URL detection to a binary attachment, so the URL
/// arrives intact. UTI ownership ensures only StealthOS opens the file.
///
/// Layout:
///
///     0    4   magic    "STCD"
///     4    1   version  0x01
///     5    2   urlLen   u16 BE
///     7    N   url      UTF-8 bytes of the `stealth://invite/...` URL
public enum SealedInviteCard {

    public static let magic: [UInt8] = [0x53, 0x54, 0x43, 0x44] // "STCD"
    public static let version: UInt8 = 0x01
    public static let fileExtension = "stcard"
    public static let utiIdentifier = "com.olibai.stealthos.card"
    public static let mimeType = "application/vnd.stealthos.card"
    public static let maxURLLength = 8 * 1024

    /// Marker for a QR-encoded card carried as base64 text.
    /// QR text mode is far more portable than byte-mode binary QRs.
    public static let qrTextPrefix = "stcard1:"

    /// Wrap the binary card as a single text-mode QR string.
    public static func encodeForQRText(_ cardBytes: Data) -> String {
        qrTextPrefix + cardBytes.base64EncodedString()
    }

    /// Inverse of `encodeForQRText`. Returns nil if the string isn't an
    /// invite-card QR.
    public static func decodeFromQRText(_ text: String) -> Data? {
        guard text.hasPrefix(qrTextPrefix) else { return nil }
        let b64 = String(text.dropFirst(qrTextPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: b64)
    }

    public enum Error: Swift.Error, Equatable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt8)
        case urlTooLarge
        case malformedURL
    }

    public static func encode(url: String) throws -> Data {
        let urlBytes = Data(url.utf8)
        guard urlBytes.count <= maxURLLength,
              urlBytes.count <= Int(UInt16.max) else {
            throw Error.urlTooLarge
        }
        var out = Data()
        out.reserveCapacity(7 + urlBytes.count)
        out.append(contentsOf: magic)
        out.append(version)
        let len = UInt16(urlBytes.count)
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8(len & 0xff))
        out.append(urlBytes)
        return out
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count >= 7 else { throw Error.truncated }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else { throw Error.badMagic }
        let v = bytes[4]
        guard v == version else { throw Error.unsupportedVersion(v) }
        let len = (Int(bytes[5]) << 8) | Int(bytes[6])
        guard len <= maxURLLength else { throw Error.urlTooLarge }
        let end = 7 + len
        guard data.count >= end else { throw Error.truncated }
        guard let url = String(data: data.subdata(in: 7..<end), encoding: .utf8) else {
            throw Error.malformedURL
        }
        return url
    }
}
