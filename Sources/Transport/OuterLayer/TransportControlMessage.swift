// TransportControlMessage.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

/// Control messages that distribute the pool transport secret. Sent through the relay as
/// `"SWK2" || JSON`; the relay sees them, so every field is either public or protected:
/// the secret itself only ever travels sealed under an ephemeral X25519 agreement, and
/// every message is signed (host identity / member identity) and, for a first join,
/// MAC'd with the out-of-band invite key.
///
/// Transcripts (`lp` = u32 BE length prefix, integers big-endian):
/// ```
/// request      = lp("STEALTH_WS_KEY_REQUEST_V2") || poolID(16) || i64 timestampMillis
///                || lp(memberPeerID) || memberIdentityKey(32) || memberEphemeral(32)
///                || nonce(32) || lp(inviteKeyID or empty)
///   memberSignature = Ed25519(member identity, request)
///   inviteProof     = HMAC-SHA256(inviteKey, request)            (first join only)
/// grant        = lp("STEALTH_WS_KEY_GRANT_V2") || poolID(16) || SHA-256(request)
///                || u32 epoch || hostEphemeral(32) || lp(sealedSecret) || i64 timestampMillis
///   hostSignature   = Ed25519(host identity, grant)
///   sealedSecret    = AES-256-GCM(nonce(12) || ct || tag) of the 32-byte secret,
///                     key = HKDF-SHA256(X25519(hostEphemeral, memberEphemeral),
///                                       salt = SHA-256(request),
///                                       info = "STEALTH_WS_TRANSPORT_KEY_V2" || u32 epoch || inviteKey-or-empty),
///                     AAD = poolID(16) || u32 epoch
/// announcement = lp("STEALTH_WS_ANNOUNCE_V2") || poolID(16) || i64 timestampMillis
///                || u32 epoch || u8 protected || u32 count || lp(removed)...
///                || u32 count || lp(legacy)...
///   hostSignature   = Ed25519(host identity, announcement)
/// ```
public struct TransportControlMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case keyRequest, keyGrant, announcement }

    public static let magic: [UInt8] = Array("SWK2".utf8)

    public var kind: Kind
    public var poolID: UUID
    public var timestampMillis: Int64

    // keyRequest
    public var memberPeerID: String?
    public var memberIdentityKey: Data?
    public var memberEphemeral: Data?
    public var nonce: Data?
    public var inviteKeyID: Data?
    public var inviteProof: Data?
    public var memberSignature: Data?

    // keyGrant
    public var requestHash: Data?
    public var hostEphemeral: Data?
    public var sealedSecret: Data?

    // keyGrant + announcement
    public var epoch: UInt32?
    public var hostSignature: Data?

    // announcement
    public var protected: Bool?
    public var removedPeerIDs: [String]?
    public var legacyPeerIDs: [String]?

    public init(kind: Kind, poolID: UUID, timestampMillis: Int64) {
        self.kind = kind
        self.poolID = poolID
        self.timestampMillis = timestampMillis
    }

    // MARK: Wire

    public static func isControlFrame(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(magic)
    }

    public func encoded() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return Data(Self.magic) + json
    }

    public static func decode(_ data: Data) -> TransportControlMessage? {
        guard isControlFrame(data), data.count <= 16 * 1024 else { return nil }
        return try? JSONDecoder().decode(TransportControlMessage.self, from: data.dropFirst(4))
    }

    // MARK: Transcripts

    static func lp(_ data: Data, into out: inout Data) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(data)
    }

    private func header(_ label: String) -> Data {
        var out = Data()
        Self.lp(Data(label.utf8), into: &out)
        withUnsafeBytes(of: poolID.uuid) { out.append(contentsOf: $0) }
        return out
    }

    /// Request transcript, or nil if a required field is missing or mis-sized.
    public func requestTranscript() -> Data? {
        guard kind == .keyRequest, let memberPeerID,
              let memberIdentityKey, memberIdentityKey.count == 32,
              let memberEphemeral, memberEphemeral.count == 32,
              let nonce, nonce.count == 32 else { return nil }
        var out = header("STEALTH_WS_KEY_REQUEST_V2")
        withUnsafeBytes(of: timestampMillis.bigEndian) { out.append(contentsOf: $0) }
        Self.lp(Data(memberPeerID.utf8), into: &out)
        out.append(memberIdentityKey)
        out.append(memberEphemeral)
        out.append(nonce)
        Self.lp(inviteKeyID ?? Data(), into: &out)
        return out
    }

    public func grantTranscript() -> Data? {
        guard kind == .keyGrant, let requestHash, requestHash.count == 32, let epoch,
              let hostEphemeral, hostEphemeral.count == 32, let sealedSecret else { return nil }
        var out = header("STEALTH_WS_KEY_GRANT_V2")
        out.append(requestHash)
        withUnsafeBytes(of: epoch.bigEndian) { out.append(contentsOf: $0) }
        out.append(hostEphemeral)
        Self.lp(sealedSecret, into: &out)
        withUnsafeBytes(of: timestampMillis.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    public func announcementTranscript() -> Data? {
        guard kind == .announcement, let epoch, let protected else { return nil }
        var out = header("STEALTH_WS_ANNOUNCE_V2")
        withUnsafeBytes(of: timestampMillis.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: epoch.bigEndian) { out.append(contentsOf: $0) }
        out.append(protected ? 1 : 0)
        for list in [removedPeerIDs ?? [], legacyPeerIDs ?? []] {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: list.count).bigEndian) { out.append(contentsOf: $0) }
            for id in list { Self.lp(Data(id.utf8), into: &out) }
        }
        return out
    }

    // MARK: Secret sealing

    static func sealingKey(sharedSecret: SharedSecret, requestTranscript: Data, epoch: UInt32, inviteKey: Data?) -> SymmetricKey {
        var info = Data("STEALTH_WS_TRANSPORT_KEY_V2".utf8)
        withUnsafeBytes(of: epoch.bigEndian) { info.append(contentsOf: $0) }
        info.append(inviteKey ?? Data())
        return sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: requestTranscript)),
                                                    sharedInfo: info, outputByteCount: 32)
    }

    static func secretAAD(poolID: UUID, epoch: UInt32) -> Data {
        var out = withUnsafeBytes(of: poolID.uuid) { Data($0) }
        withUnsafeBytes(of: epoch.bigEndian) { out.append(contentsOf: $0) }
        return out
    }
}
