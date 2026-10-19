// TransportInviteSecret.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

/// Host-generated material appended to a remote invitation as a URL **fragment**.
///
/// The relay server builds the `stealth://invite/<payload>` URL (and so knows the token
/// secret inside it). The host appends `#v2.<base64url(0x02 || inviteKey || hostKey)>`
/// locally; URL fragments are never sent to the server, so the relay never sees this part.
/// The invitation still travels out of band (QR, AirDrop, message), which is the only
/// channel the relay cannot read.
///
/// - `inviteKey` (32 random bytes) authenticates the joiner's first transport-key request,
///   so a relay that only knows the server-side token cannot impersonate the joiner.
/// - `hostIdentityKey` (the host's Ed25519 public key) lets the joiner verify the host's
///   signed key grants and that the server's `host_peer_id` is really that host.
///
/// StealthOS 1.4.x ignores the fragment, so its users still join (as legacy members).
/// An invitation without the fragment came from a 1.4.x host.
public struct TransportInviteSecret: Sendable, Equatable {
    public static let fragmentPrefix = "v2."
    public static let version: UInt8 = 0x02

    public let inviteKey: Data
    public let hostIdentityKey: Data

    public init(inviteKey: Data, hostIdentityKey: Data) {
        self.inviteKey = inviteKey
        self.hostIdentityKey = hostIdentityKey
    }

    /// Fresh invite key for a host identity.
    public static func generate(hostIdentityKey: Data) -> TransportInviteSecret {
        TransportInviteSecret(inviteKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                              hostIdentityKey: hostIdentityKey)
    }

    /// Identifies the invite key in a request without revealing it: first 8 bytes of SHA-256.
    public var inviteKeyID: Data { Self.keyID(inviteKey) }

    static func keyID(_ key: Data) -> Data { Data(SHA256.hash(data: key).prefix(8)) }

    /// `v2.<base64url(0x02 || inviteKey || hostIdentityKey)>`.
    public var fragment: String {
        var raw = Data([Self.version])
        raw.append(inviteKey)
        raw.append(hostIdentityKey)
        return Self.fragmentPrefix + Self.base64URL(raw)
    }

    /// Returns `url` with the fragment set (replacing any existing fragment).
    public func appending(to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = fragment
        return components.url
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case unsupportedVersion
    }

    /// Parses a URL fragment. `nil` input means "no fragment" (1.4.x host).
    public static func parse(fragment: String?) -> Result<TransportInviteSecret?, ParseError> {
        guard let fragment, !fragment.isEmpty else { return .success(nil) }
        guard fragment.hasPrefix(fragmentPrefix),
              let raw = fromBase64URL(String(fragment.dropFirst(fragmentPrefix.count))) else {
            return .failure(.malformed)
        }
        guard raw.count == 65 else { return .failure(.malformed) }
        guard raw[raw.startIndex] == version else { return .failure(.unsupportedVersion) }
        let bytes = [UInt8](raw)
        let hostKey = Data(bytes[33..<65])
        guard (try? Curve25519.Signing.PublicKey(rawRepresentation: hostKey)) != nil else { return .failure(.malformed) }
        return .success(TransportInviteSecret(inviteKey: Data(bytes[1..<33]), hostIdentityKey: hostKey))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), string.allSatisfy(\.isASCII) else { return nil }
        var b64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b64.count % 4 != 0 { b64 += String(repeating: "=", count: 4 - b64.count % 4) }
        return Data(base64Encoded: b64)
    }
}
