// RemotePoolService.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit
import Security
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Remote Host Identity

/// An Ed25519 signing identity for authenticating as a pool host.
///
/// The private key is stored in the Keychain with device-only protection.
/// The public key is shared with the relay server during host authentication.
public struct RemoteHostIdentity: Sendable {
    /// The Ed25519 private signing key.
    public let privateKey: Curve25519.Signing.PrivateKey

    /// The corresponding Ed25519 public verification key.
    public let publicKey: Curve25519.Signing.PublicKey

    /// Raw bytes of the public key for encoding/transmission.
    public var publicKeyData: Data { publicKey.rawRepresentation }

    /// Create an identity from an existing private key.
    ///
    /// - Parameter privateKey: The Ed25519 private key.
    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
    }

    /// Sign arbitrary data with this identity's private key.
    ///
    /// - Parameter data: The data to sign.
    /// - Returns: The Ed25519 signature.
    /// - Throws: ``CryptoKitError`` if signing fails.
    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    /// Compute the fingerprint of the public key (first 8 bytes of SHA-256 hash).
    ///
    /// Used as a compact identifier for the host in invitation tokens.
    public var fingerprint: Data {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return Data(hash.prefix(8))
    }
}

// MARK: - Remote Invitation

/// An invitation to join a remote pool, created by the host.
public struct RemoteInvitation: Sendable, Identifiable {
    /// Unique identifier for this invitation.
    public let id: UUID

    /// The server-assigned token identifier.
    public let tokenId: String

    /// The shareable invitation URL.
    public let url: URL

    /// When this invitation expires.
    public let expiresAt: Date

    /// Maximum number of times this invitation can be used. Nil means unlimited.
    public let maxUses: Int?

    public init(id: UUID = UUID(), tokenId: String, url: URL, expiresAt: Date, maxUses: Int?) {
        self.id = id
        self.tokenId = tokenId
        self.url = url
        self.expiresAt = expiresAt
        self.maxUses = maxUses
    }

    /// Whether this invitation has expired.
    public var isExpired: Bool {
        Date() > expiresAt
    }
}

// MARK: - Parsed Invitation

/// An invitation parsed from a `stealth://invite/...` URL.
///
/// Contains all the cryptographic material needed to join a remote pool:
/// the server address, pool ID, token secret for proof generation, and
/// the host's fingerprint for identity verification.
public struct ParsedInvitation: Sendable {
    /// The WebSocket URL of the relay server.
    public let serverURL: URL

    /// The pool to join.
    public let poolId: UUID

    /// 16-byte token identifier.
    public let tokenId: Data

    /// 32-byte token secret (used to derive verification key and HMAC proof).
    public let tokenSecret: Data

    /// 8-byte host fingerprint for identity verification.
    public let hostFingerprint: Data

    /// When the invitation expires.
    public let expiresAt: Date

    public init(
        serverURL: URL, poolId: UUID, tokenId: Data,
        tokenSecret: Data, hostFingerprint: Data, expiresAt: Date
    ) {
        self.serverURL = serverURL
        self.poolId = poolId
        self.tokenId = tokenId
        self.tokenSecret = tokenSecret
        self.hostFingerprint = hostFingerprint
        self.expiresAt = expiresAt
    }

    /// Whether this invitation has expired.
    public var isExpired: Bool {
        Date() > expiresAt
    }
}

// MARK: - Remote Pool Service

/// Manages remote pool operations including host identity, invitation creation,
/// and invitation parsing.
///
/// This service is the primary entry point for remote pool management. It handles:
/// - Creating and persisting Ed25519 host identities in the Keychain
/// - Requesting invitation tokens from the relay server
/// - Parsing invitation URLs from deep links
/// - Generating QR codes for invitation sharing
@MainActor
public final class RemotePoolService: ObservableObject {

    // MARK: - Constants

    /// Keychain service identifier for host identity storage.
    private static let keychainService = "com.stealthos.connectionpool.hostidentity"

    /// Keychain account identifier for the host private key.
    private static let keychainAccount = "host_ed25519_private_key"

    /// URL scheme for invitation deep links.
    public static let invitationScheme = "stealth"

    /// URL host for invitation deep links.
    public static let invitationHost = "invite"

    // MARK: - Published Properties

    /// The current host identity, if loaded.
    @Published public private(set) var hostIdentity: RemoteHostIdentity?

    /// Active invitations created during this session.
    @Published public private(set) var activeInvitations: [RemoteInvitation] = []

    // MARK: - Initialization

    public init() {}

    // MARK: - Host Identity Management

    /// Get the existing host identity from the Keychain, or create a new one.
    ///
    /// The private key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// protection, meaning it cannot be backed up or transferred to another device.
    ///
    /// - Returns: The host's Ed25519 signing identity.
    /// - Throws: If Keychain access fails.
    public func getOrCreateHostIdentity() throws -> RemoteHostIdentity {
        if let existing = hostIdentity {
            return existing
        }

        // Try to load from Keychain
        if let keyData = try loadFromKeychain() {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
            let identity = RemoteHostIdentity(privateKey: privateKey)
            hostIdentity = identity
            return identity
        }

        // Generate new identity
        let privateKey = Curve25519.Signing.PrivateKey()
        try saveToKeychain(privateKey.rawRepresentation)

        let identity = RemoteHostIdentity(privateKey: privateKey)
        hostIdentity = identity
        return identity
    }

    /// Delete the stored host identity from the Keychain.
    ///
    /// This is a destructive operation. The identity cannot be recovered after deletion.
    /// Any pools or invitations tied to this identity will become invalid.
    public func deleteHostIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        hostIdentity = nil
    }

    // MARK: - Invitation Management

    /// Request creation of a new invitation from the relay server.
    ///
    /// The transport must be connected and authenticated as the pool host.
    ///
    /// - Parameters:
    ///   - transport: The active WebSocket transport (must be authenticated as host).
    ///   - maxUses: Maximum number of times this invitation can be used.
    ///   - expiresInSecs: How long the invitation is valid, in seconds.
    /// - Returns: The created invitation, or nil if the request failed or timed out.
    public func createInvitation(
        transport: WebSocketTransport,
        maxUses: Int,
        expiresInSecs: UInt64
    ) async -> RemoteInvitation? {
        // Send the create invitation frame directly (not wrapped in Forward)
        transport.sendCreateInvitation(maxUses: UInt8(clamping: maxUses), expiresInSecs: expiresInSecs)

        // Wait for the InvitationCreated response
        guard let created = await transport.waitForInvitationCreated(timeout: 10) else {
            return nil
        }

        guard let url = URL(string: created.url) else { return nil }

        let invitation = RemoteInvitation(
            tokenId: created.tokenId,
            url: url,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(created.expiresAt)),
            maxUses: maxUses > 0 ? maxUses : nil
        )

        activeInvitations.append(invitation)
        return invitation
    }

    // MARK: - Invitation Parsing

    /// Parse an invitation from a `stealth://invite/...` URL.
    ///
    /// The URL payload is a base64url-encoded JSON structure matching the Rust
    /// `TokenWire` format containing the token ID, secret, pool ID, host fingerprint,
    /// expiration, max uses, server address, and host signature.
    ///
    /// - Parameter url: The invitation URL to parse.
    /// - Returns: The parsed invitation, or nil if the URL is invalid.
    public static func parseInvitationURL(_ url: URL) -> ParsedInvitation? {
        // Expected format: stealth://invite/<base64url-payload>
        guard url.scheme == invitationScheme else { return nil }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let host = url.host, host == invitationHost || pathComponents.count >= 1 else {
            return nil
        }

        // The payload is the last path component
        let payload: String
        if url.host == invitationHost {
            // stealth://invite/<payload>
            payload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }

        guard !payload.isEmpty else { return nil }

        // Decode base64url (no padding) to JSON
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let jsonData = Data(base64Encoded: base64) else { return nil }

        // Decode the TokenWire JSON structure
        struct TokenWire: Decodable {
            let id: [UInt8]      // 16 bytes
            let secret: [UInt8]  // 32 bytes
            let pool: [UInt8]    // 16 bytes (UUID)
            let fp: [UInt8]      // 8 bytes (fingerprint)
            let exp: Int64       // Unix timestamp
            let max: UInt8
            let addr: String     // Server address
        }

        guard let wire = try? JSONDecoder().decode(TokenWire.self, from: jsonData) else {
            return nil
        }

        guard wire.id.count == 16,
              wire.secret.count == 32,
              wire.pool.count == 16,
              wire.fp.count == 8 else {
            return nil
        }

        // Construct UUID from raw bytes
        let poolUUID = UUID(uuid: (
            wire.pool[0], wire.pool[1], wire.pool[2], wire.pool[3],
            wire.pool[4], wire.pool[5], wire.pool[6], wire.pool[7],
            wire.pool[8], wire.pool[9], wire.pool[10], wire.pool[11],
            wire.pool[12], wire.pool[13], wire.pool[14], wire.pool[15]
        ))

        // Construct server URL from the addr field.
        // The server embeds its bind address (e.g., "0.0.0.0:9090") which isn't
        // directly reachable. Use ws:// (not wss://) for IP:port addresses.
        let serverAddress = wire.addr
        let serverURL: URL
        if serverAddress.hasPrefix("wss://") || serverAddress.hasPrefix("ws://") {
            guard let url = URL(string: serverAddress) else { return nil }
            serverURL = url
        } else {
            // Default to ws:// for raw address:port
            guard let url = URL(string: "ws://\(serverAddress)") else { return nil }
            serverURL = url
        }

        return ParsedInvitation(
            serverURL: serverURL,
            poolId: poolUUID,
            tokenId: Data(wire.id),
            tokenSecret: Data(wire.secret),
            hostFingerprint: Data(wire.fp),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(wire.exp))
        )
    }

    // MARK: - QR Code Generation

    /// Generate a QR code image for an invitation URL.
    ///
    /// Uses CoreImage's built-in QR code generator. The returned CGImage can be
    /// displayed directly in SwiftUI via `Image(decorative:scale:orientation:)`.
    ///
    /// - Parameters:
    ///   - invitation: The invitation to encode.
    ///   - size: The desired size of the QR code in points.
    /// - Returns: A CGImage of the QR code, or nil if generation fails.
    public static func generateQRCode(for invitation: RemoteInvitation, size: CGFloat) -> CGImage? {
        #if canImport(CoreImage)
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        let urlString = invitation.url.absoluteString
        filter.message = Data(urlString.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale the QR code to the requested size
        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return context.createCGImage(scaledImage, from: scaledImage.extent)
        #else
        return nil
        #endif
    }

    // MARK: - Share URL

    /// Generate a shareable URL for an invitation.
    ///
    /// Returns the invitation's URL directly, which uses the `stealth://invite/...` scheme.
    ///
    /// - Parameter invitation: The invitation to share.
    /// - Returns: The shareable URL.
    public static func shareURL(for invitation: RemoteInvitation) -> URL {
        invitation.url
    }

    // MARK: - Private: Keychain Operations

    /// Save raw key data to the Keychain.
    private func saveToKeychain(_ data: Data) throws {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TransportError.from(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Keychain save failed: \(status)"])
            )
        }
    }

    /// Load raw key data from the Keychain.
    private func loadFromKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw TransportError.from(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Keychain load failed: \(status)"])
            )
        }
    }
}
