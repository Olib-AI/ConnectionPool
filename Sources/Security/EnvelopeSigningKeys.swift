// EnvelopeSigningKeys.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine
import CryptoKit

// MARK: - Envelope Signing Keys

/// Per-session Ed25519 keys that give relay envelopes per-sender authenticity.
///
/// The pool-wide v2 MAC only proves "someone in the pool"; any member could forge any
/// origin. Each 1.5.0 peer therefore generates an Ed25519 signing key per pool session
/// and signs the v2 envelope input with it. Receivers verify against the key the origin
/// introduced in its E2E key exchange.
///
/// **Binding.** The key exchange (`KeyExchangePayload.signingPublicKey`) carries a
/// binding signature made with the new signing key over
/// ```
/// u32 len || "STEALTH_ENVELOPE_SIGNING_KEY_V2"
/// u32 len || peerID (UTF-8)
/// poolID (16 raw bytes)
/// X25519 key-agreement public key (32)
/// Ed25519 signing public key (32)
/// ```
/// so a signing key cannot be re-attached to another peer ID, pool or E2E key, and an
/// out-of-band check of the E2E fingerprint authenticates the signing key too.
///
/// **TOFU per session.** The first valid binding for a peer wins. A different key for the
/// same peer is refused and reported via ``events`` until the peer's direct, transport-
/// authenticated connection drops (``forget(peerID:)``) or the pool session ends
/// (``resetSession()``).
///
/// Thread safety: NSLock around all state.
public final class EnvelopeSigningKeys: @unchecked Sendable {

    /// Domain label of the binding statement.
    public static let bindingLabel = Data("STEALTH_ENVELOPE_SIGNING_KEY_V2".utf8)

    /// Outcome of ``register(peerID:signingPublicKey:binding:keyAgreementPublicKey:poolID:)``.
    public enum Registration: Sendable, Equatable {
        case registered
        case unchanged
        case invalidBinding
        case refusedKeyChange
    }

    /// Emitted when a peer presents a second, different signing key in one session.
    public enum Event: Sendable, Equatable {
        case keyChangeRefused(peerID: String, oldFingerprint: String, newFingerprint: String)
    }

    private let lock = NSLock()
    private var _local: Curve25519.Signing.PrivateKey
    private var _peers: [String: Curve25519.Signing.PublicKey] = [:]
    private let eventSubject = PassthroughSubject<Event, Never>()

    public var events: AnyPublisher<Event, Never> { eventSubject.eraseToAnyPublisher() }

    public init() {
        _local = Curve25519.Signing.PrivateKey()
    }

    /// Fixed-key initializer for tests and vectors (internal: `@testable` only).
    init(localKey: Curve25519.Signing.PrivateKey) {
        _local = localKey
    }

    // MARK: Local key

    /// Raw 32-byte Ed25519 public key to advertise in the key exchange.
    public var localPublicKey: Data {
        lock.withLock { _local.publicKey.rawRepresentation }
    }

    /// Binding statement bytes (see type documentation).
    public static func bindingStatement(peerID: String, poolID: UUID, keyAgreementPublicKey: Data, signingPublicKey: Data) -> Data {
        var out = Data()
        RelayEnvelope.appendBE32Prefixed(bindingLabel, to: &out)
        RelayEnvelope.appendBE32Prefixed(Data(peerID.utf8), to: &out)
        withUnsafeBytes(of: poolID.uuid) { out.append(contentsOf: $0) }
        out.append(keyAgreementPublicKey)
        out.append(signingPublicKey)
        return out
    }

    /// Signs the binding for our own key exchange.
    public func makeBinding(localPeerID: String, poolID: UUID, keyAgreementPublicKey: Data) -> Data? {
        lock.withLock {
            let statement = Self.bindingStatement(
                peerID: localPeerID, poolID: poolID,
                keyAgreementPublicKey: keyAgreementPublicKey,
                signingPublicKey: _local.publicKey.rawRepresentation
            )
            return try? _local.signature(for: statement)
        }
    }

    /// Signs envelope bytes with the local session key.
    func sign(_ message: Data) -> Data? {
        lock.withLock { try? _local.signature(for: message) }
    }

    // MARK: Peers

    /// Registers a peer's signing key from its key exchange.
    ///
    /// Call only with a key exchange whose `keyAgreementPublicKey` the E2E layer accepted
    /// for `peerID` in the same message.
    @discardableResult
    public func register(peerID: String, signingPublicKey: Data, binding: Data, keyAgreementPublicKey: Data, poolID: UUID) -> Registration {
        guard signingPublicKey.count == 32, keyAgreementPublicKey.count == 32, binding.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else {
            return .invalidBinding
        }
        let statement = Self.bindingStatement(peerID: peerID, poolID: poolID,
                                              keyAgreementPublicKey: keyAgreementPublicKey,
                                              signingPublicKey: signingPublicKey)
        guard key.isValidSignature(binding, for: statement) else { return .invalidBinding }

        var event: Event?
        let result: Registration = lock.withLock {
            if let existing = _peers[peerID] {
                if existing.rawRepresentation == signingPublicKey { return .unchanged }
                event = .keyChangeRefused(peerID: peerID,
                                          oldFingerprint: Self.fingerprint(existing.rawRepresentation),
                                          newFingerprint: Self.fingerprint(signingPublicKey))
                return .refusedKeyChange
            }
            _peers[peerID] = key
            return .registered
        }
        if let event { eventSubject.send(event) }
        return result
    }

    /// Test seam (internal): install a peer key without a key exchange.
    func install(peerID: String, publicKey: Curve25519.Signing.PublicKey) {
        lock.withLock { _peers[peerID] = publicKey }
    }

    /// The signing key `peerID` introduced this session, if any.
    public func signingKey(for peerID: String) -> Curve25519.Signing.PublicKey? {
        lock.withLock { _peers[peerID] }
    }

    /// Drops a peer's key after its direct, transport-authenticated connection ended.
    public func forget(peerID: String) {
        _ = lock.withLock { _peers.removeValue(forKey: peerID) }
    }

    /// New local key and no peer keys: call when the pool session ends.
    public func resetSession() {
        lock.withLock {
            _local = Curve25519.Signing.PrivateKey()
            _peers.removeAll()
        }
    }

    /// First 8 bytes of SHA-256, uppercase hex pairs joined by ':' (same format as chat TOFU).
    public static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
