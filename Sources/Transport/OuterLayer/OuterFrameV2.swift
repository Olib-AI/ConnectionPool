// OuterFrameV2.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

/// WebSocket outer-layer frame, v2 (StealthOS 1.5.0+).
///
/// ```
/// offset size
///  0     4   "SWO2"
///  4     4   epoch            u32 BE   (transport-secret generation)
///  8     8   sender session   random per sender connection
/// 16     8   counter          u64 BE, strictly increasing per session
/// 24     8   timestamp        i64 BE, sender clock, milliseconds since 1970
/// 32    12   nonce            random
/// 44     n   AES-256-GCM ciphertext of the app frame
/// 44+n  16   tag
/// key = HKDF-SHA256(ikm = pool transport secret, salt = poolID (16),
///                   info = "STEALTH_WS_OUTER_V2" || epoch BE, 32)
/// AAD = bytes 0..<44 || poolID (16) || u32 BE len || sender peer ID (UTF-8, as the relay
///       reports it in from_peer_id)
/// ```
/// The AAD binds the frame to its pool, epoch and claimed sender, so the relay cannot
/// re-attribute it. Receivers reject frames older than ``maxAge`` or more than
/// ``maxFutureSkew`` ahead, and keep a sliding window per (sender, session) so a captured
/// frame is accepted once at most.
public enum OuterFrameV2 {
    public static let magic: [UInt8] = Array("SWO2".utf8)
    public static let headerLength = 44
    public static let tagLength = 16
    public static let maxAge: TimeInterval = 300
    public static let maxFutureSkew: TimeInterval = 60
    static let keyInfo = Data("STEALTH_WS_OUTER_V2".utf8)

    public struct Header: Sendable, Equatable {
        public let epoch: UInt32
        public let session: UInt64
        public let counter: UInt64
        public let timestampMillis: Int64
        public let nonce: Data

        func encoded() -> Data {
            var out = Data(OuterFrameV2.magic)
            withUnsafeBytes(of: epoch.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: session.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: counter.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: timestampMillis.bigEndian) { out.append(contentsOf: $0) }
            out.append(nonce)
            return out
        }
    }

    public static func isOuterFrame(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(magic)
    }

    public static func frameKey(secret: SymmetricKey, poolID: UUID, epoch: UInt32) -> SymmetricKey {
        var info = keyInfo
        withUnsafeBytes(of: epoch.bigEndian) { info.append(contentsOf: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: secret,
                                      salt: withUnsafeBytes(of: poolID.uuid) { Data($0) },
                                      info: info, outputByteCount: 32)
    }

    static func aad(header: Data, poolID: UUID, senderPeerID: String) -> Data {
        var out = header
        withUnsafeBytes(of: poolID.uuid) { out.append(contentsOf: $0) }
        let sender = Data(senderPeerID.utf8)
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: sender.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(sender)
        return out
    }

    /// Seals an app frame. `nonce` must be 12 fresh random bytes.
    public static func seal(_ plaintext: Data, key: SymmetricKey, header: Header, poolID: UUID, senderPeerID: String) -> Data? {
        guard header.nonce.count == 12, let nonce = try? AES.GCM.Nonce(data: header.nonce) else { return nil }
        let encodedHeader = header.encoded()
        guard let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce,
                                          authenticating: aad(header: encodedHeader, poolID: poolID, senderPeerID: senderPeerID)) else {
            return nil
        }
        return encodedHeader + box.ciphertext + box.tag
    }

    /// Parses the header (no authentication). `nil` for anything malformed.
    public static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= headerLength + tagLength, isOuterFrame(data) else { return nil }
        let b = [UInt8](data.prefix(headerLength))
        func be<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            var v: T = 0
            for i in 0..<MemoryLayout<T>.size { v = (v << 8) | T(b[offset + i]) }
            return v
        }
        return Header(epoch: be(4, UInt32.self), session: be(8, UInt64.self), counter: be(16, UInt64.self),
                      timestampMillis: Int64(bitPattern: be(24, UInt64.self)), nonce: Data(b[32..<44]))
    }

    /// Authenticates and decrypts. `nil` for any failure.
    public static func open(_ data: Data, key: SymmetricKey, poolID: UUID, senderPeerID: String) -> (header: Header, plaintext: Data)? {
        guard let header = parseHeader(data), let nonce = try? AES.GCM.Nonce(data: header.nonce) else { return nil }
        let start = data.startIndex
        let ciphertext = data[(start + headerLength)..<(data.endIndex - tagLength)]
        let tag = data[(data.endIndex - tagLength)...]
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? AES.GCM.open(box, using: key,
                                                authenticating: aad(header: Data(data.prefix(headerLength)), poolID: poolID, senderPeerID: senderPeerID)) else {
            return nil
        }
        return (header, plaintext)
    }
}

/// Per-(sender, session) replay windows plus freshness for outer frames.
struct OuterFrameReplayGuard {
    private struct Key: Hashable { let sender: String; let session: UInt64 }
    private var windows: [Key: SlidingReplayWindow] = [:]
    private var order: [Key] = []
    static let maxSessions = 512

    func isFresh(_ header: OuterFrameV2.Header, now: Date) -> Bool {
        let sent = Date(timeIntervalSince1970: TimeInterval(header.timestampMillis) / 1000)
        let age = now.timeIntervalSince(sent)
        return age <= OuterFrameV2.maxAge && age >= -OuterFrameV2.maxFutureSkew
    }

    func wouldAccept(_ header: OuterFrameV2.Header, sender: String) -> Bool {
        windows[Key(sender: sender, session: header.session)]?.wouldAccept(header.counter) ?? true
    }

    mutating func accept(_ header: OuterFrameV2.Header, sender: String) -> Bool {
        let key = Key(sender: sender, session: header.session)
        if windows[key] == nil {
            order.append(key)
            if order.count > Self.maxSessions {
                windows.removeValue(forKey: order.removeFirst())
            }
        }
        return windows[key, default: SlidingReplayWindow()].accept(header.counter)
    }
}
