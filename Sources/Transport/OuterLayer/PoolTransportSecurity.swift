// PoolTransportSecurity.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit

// MARK: - Status

/// State of the remote pool's WebSocket outer encryption layer, for the UI.
public enum OuterLayerStatus: Sendable, Equatable {
    /// No remote session.
    case off
    /// Waiting for the host to deliver the pool transport secret. App frames are held.
    case securing
    /// Every frame is encrypted with the pool transport secret. Members on StealthOS 1.4.x
    /// listed here are excluded: they cannot read or send pool traffic until they update.
    case protected(epoch: UInt32, excludedLegacyPeers: [String])
    /// Mixed pool that has never been protected: frames are plaintext to the relay
    /// (inner E2E still applies) because these members, or the host, run 1.4.x.
    case unprotected(legacyPeers: [String], legacyHost: Bool)
    /// The host announced "protection off" for a pool that was already protected. Refused:
    /// plaintext frames are dropped.
    case downgradeRefused
    /// The server's host peer ID does not match the host key in the invitation.
    case hostIdentityMismatch
}

// MARK: - Persistence

struct HostTransportRecord: Codable, Equatable {
    struct InviteKey: Codable, Equatable { var id: Data; var key: Data; var expiresAt: Date }
    struct PreviousEpoch: Codable, Equatable { var epoch: UInt32; var secret: Data; var validUntil: Date }
    var epoch: UInt32
    var secret: Data
    var previous: PreviousEpoch?
    var enabled: Bool
    var enrolled: [Data]
    var inviteKeys: [InviteKey]
}

struct MemberTransportRecord: Codable, Equatable {
    struct EpochKey: Codable, Equatable { var epoch: UInt32; var secret: Data }
    var hostIdentityKey: Data
    var protected: Bool
    var enrolled: Bool
    var keys: [EpochKey]
    var inviteKey: Data?
}

/// JSON records in the secure item store (Keychain in production).
struct TransportSecurityStore: Sendable {
    static let service = "com.stealthos.connectionpool.transportsecurity"
    var store: @Sendable () -> any SecureItemStore = { SecureItemStorage.shared.store }

    static func hostAccount(_ poolID: UUID) -> String { "host:\(poolID.uuidString)" }
    static func memberAccount(serverURL: String, poolID: UUID) -> String {
        "member:" + SHA256.hash(data: Data("\(serverURL):\(poolID.uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = try? store().load(service: Self.service, account: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? store().save(data, service: Self.service, account: account)
    }

    func delete(account: String) {
        try? store().delete(service: Self.service, account: account)
    }
}

// MARK: - Pool Transport Security

/// Distributes the remote pool transport secret and applies the outer layer
/// (``OuterFrameV2``) to every app frame. See `Docs/Security.md` ("Remote transport").
///
/// The host generates a random 256-bit secret per epoch and hands it to each member over
/// an authenticated, ephemeral X25519 exchange through the relay: the member's first
/// request is MAC'd with the out-of-band invite key and signed with its member identity;
/// the host's grant is signed with the host identity the invite named. The relay forwards
/// these messages but never learns the secret.
///
/// The class is pure protocol logic: transport I/O, clock, randomness and storage are
/// injected, so tests can run host, members and a hostile relay in one process.
@MainActor
public final class PoolTransportSecurity {

    enum Role {
        case host(identity: Curve25519.Signing.PrivateKey)
        case member(identity: Curve25519.Signing.PrivateKey, serverURL: String)
    }

    private enum MemberState: Equatable {
        case pending(since: Date)
        case enrolled(identityKey: Data)
        case legacy
    }

    private enum MemberMode: Equatable {
        case securing, protected, unprotected, legacyHost, downgradeRefused, identityMismatch
    }

    // MARK: Constants

    static let controlMaxAge: TimeInterval = 300
    static let pendingLegacyTimeout: TimeInterval = 10
    static let rotationSwitchTimeout: TimeInterval = 10
    static let previousEpochGrace: TimeInterval = 30
    static let requestRetryInterval: TimeInterval = 5
    static let maxQueuedFrames = 256

    // MARK: Dependencies

    private let role: Role
    public let poolID: UUID
    private let localPeerID: () -> String
    private let store: TransportSecurityStore
    private let now: () -> Date
    private let send: (Data, [String]?) -> Void
    private let deliver: (Data, String) -> Void

    // MARK: State

    private var hostRecord: HostTransportRecord?
    private var memberRecord: MemberTransportRecord?
    private let session: UInt64
    private var counter: UInt64 = 0
    private var replayGuard = OuterFrameReplayGuard()
    private var keyCache: [UInt32: SymmetricKey] = [:]

    // host
    private var members: [String: MemberState] = [:]
    private var seenRequestNonces: [Data: Date] = [:]
    private var sendingEpoch: UInt32 = 0
    private var rotationAwaiting: Set<String> = []
    private var rotationDeadline: Date?
    private var removedPeers: Set<String> = []
    private var lastAnnouncementSent: Int64 = .min

    // member
    private var mode: MemberMode = .securing
    private var hostPeerID: String?
    private var outstanding: (transcript: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey, sentAt: Date)?
    private var lastAnnouncementMillis: Int64 = .min
    private var legacyPeers: [String] = []
    private var announcedEpoch: UInt32 = 0
    private var oldEpochsValidUntil: Date?
    private var outboundQueue: [(Data, [String]?)] = []
    private var inboundQueue: [(Data, String)] = []

    public private(set) var status: OuterLayerStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((OuterLayerStatus) -> Void)?

    // MARK: Init

    /// Host side.
    init(hostIdentity: Curve25519.Signing.PrivateKey, poolID: UUID, store: TransportSecurityStore = TransportSecurityStore(),
         now: @escaping () -> Date = Date.init, localPeerID: @escaping () -> String,
         send: @escaping (Data, [String]?) -> Void, deliver: @escaping (Data, String) -> Void) {
        self.role = .host(identity: hostIdentity)
        self.poolID = poolID
        self.store = store
        self.now = now
        self.localPeerID = localPeerID
        self.send = send
        self.deliver = deliver
        self.session = UInt64.random(in: 1...UInt64.max)
        let account = TransportSecurityStore.hostAccount(poolID)
        if let existing = store.load(HostTransportRecord.self, account: account) {
            hostRecord = existing
        } else {
            let record = HostTransportRecord(epoch: 1, secret: Self.randomSecret(), previous: nil,
                                             enabled: false, enrolled: [], inviteKeys: [])
            store.save(record, account: account)
            hostRecord = record
        }
        sendingEpoch = hostRecord?.epoch ?? 1
        refreshHostStatus()
    }

    /// Member side. `invite` is the fragment of the invitation used to join; `nil` when
    /// rejoining (persisted state is used) or when the invitation came from a 1.4.x host.
    init(memberIdentity: Curve25519.Signing.PrivateKey, serverURL: String, poolID: UUID,
         invite: TransportInviteSecret?, store: TransportSecurityStore = TransportSecurityStore(),
         now: @escaping () -> Date = Date.init, localPeerID: @escaping () -> String,
         send: @escaping (Data, [String]?) -> Void, deliver: @escaping (Data, String) -> Void) {
        self.role = .member(identity: memberIdentity, serverURL: serverURL)
        self.poolID = poolID
        self.store = store
        self.now = now
        self.localPeerID = localPeerID
        self.send = send
        self.deliver = deliver
        self.session = UInt64.random(in: 1...UInt64.max)
        let account = TransportSecurityStore.memberAccount(serverURL: serverURL, poolID: poolID)
        var record = store.load(MemberTransportRecord.self, account: account)
        if let invite {
            if var existing = record {
                if existing.hostIdentityKey != invite.hostIdentityKey {
                    mode = .identityMismatch
                } else if !existing.enrolled {
                    existing.inviteKey = invite.inviteKey
                    record = existing
                }
            } else {
                record = MemberTransportRecord(hostIdentityKey: invite.hostIdentityKey, protected: false,
                                               enrolled: false, keys: [], inviteKey: invite.inviteKey)
            }
            if let record { store.save(record, account: account) }
        }
        memberRecord = record
        if mode != .identityMismatch {
            mode = record == nil ? .legacyHost : (record!.protected ? .protected : .securing)
        }
        refreshMemberStatus()
    }

    static func randomSecret() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    private var isHost: Bool { if case .host = role { return true }; return false }

    private var memberAccount: String? {
        if case .member(_, let serverURL) = role { return TransportSecurityStore.memberAccount(serverURL: serverURL, poolID: poolID) }
        return nil
    }

    private func nowMillis() -> Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    private func isFresh(_ millis: Int64) -> Bool {
        let age = now().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
        return age <= Self.controlMaxAge && age >= -OuterFrameV2.maxFutureSkew
    }

    private func frameKey(epoch: UInt32, secret: Data) -> SymmetricKey {
        if let cached = keyCache[epoch] { return cached }
        let key = OuterFrameV2.frameKey(secret: SymmetricKey(data: secret), poolID: poolID, epoch: epoch)
        keyCache[epoch] = key
        return key
    }

    // MARK: - Host API

    /// Registers the invite key of an invitation this host just created.
    public func registerInvite(_ secret: TransportInviteSecret, expiresAt: Date) {
        guard isHost, var record = hostRecord else { return }
        record.inviteKeys.removeAll { $0.expiresAt < now() }
        record.inviteKeys.append(.init(id: secret.inviteKeyID, key: secret.inviteKey, expiresAt: expiresAt))
        persistHost(record)
    }

    /// The host removed or kicked `peerID`: forget its enrollment and rotate the secret.
    public func memberRemoved(_ peerID: String) {
        guard isHost, var record = hostRecord else { return }
        // The relay names members by the base64 of their identity key.
        if case .enrolled(let key)? = members[peerID] {
            record.enrolled.removeAll { $0 == key }
        }
        if let key = Data(base64Encoded: peerID) {
            record.enrolled.removeAll { $0 == key }
        }
        members.removeValue(forKey: peerID)
        record.previous = .init(epoch: record.epoch, secret: record.secret, validUntil: now().addingTimeInterval(Self.previousEpochGrace))
        record.epoch &+= 1
        record.secret = Self.randomSecret()
        persistHost(record)
        removedPeers.insert(peerID)
        rotationAwaiting = Set(members.compactMap { id, state in
            if case .enrolled = state { return id }
            return nil
        })
        rotationDeadline = now().addingTimeInterval(Self.rotationSwitchTimeout)
        if rotationAwaiting.isEmpty { sendingEpoch = record.epoch; rotationDeadline = nil }
        announce(to: nil, removed: [peerID])
        refreshHostStatus()
    }

    private func persistHost(_ record: HostTransportRecord) {
        hostRecord = record
        store.save(record, account: TransportSecurityStore.hostAccount(poolID))
    }

    // MARK: - Membership events

    public func peerJoined(_ peerID: String) {
        guard isHost, peerID != localPeerID() else { return }
        if members[peerID] == nil { members[peerID] = .pending(since: now()) }
        removedPeers.remove(peerID)
        refreshHostStatus()
    }

    public func peerLeft(_ peerID: String) {
        guard isHost else { return }
        members.removeValue(forKey: peerID)
        rotationAwaiting.remove(peerID)
        reevaluateProtection()
    }

    /// Member side: the relay accepted us and named the host.
    public func connected(hostPeerID: String) {
        guard case .member = role else { return }
        self.hostPeerID = hostPeerID
        guard let record = memberRecord else { refreshMemberStatus(); return }
        guard record.hostIdentityKey.base64EncodedString() == hostPeerID else {
            mode = .identityMismatch
            refreshMemberStatus()
            return
        }
        if mode == .identityMismatch { return }
        sendKeyRequest()
        refreshMemberStatus()
    }

    // MARK: - Outbound

    /// Sends an app frame (`nil` targets = broadcast) through the outer layer, as plaintext
    /// in an unprotected pool, or holds it while securing.
    public func sendApp(_ data: Data, to targets: [String]?) {
        if isHost {
            guard let record = hostRecord, record.enabled else { send(data, targets); return }
            // During a rotation the host keeps sending under the previous epoch until every
            // remaining member has fetched the new secret (or the switch timeout passes).
            var epoch = record.epoch, secret = record.secret
            if sendingEpoch != record.epoch, let previous = record.previous, previous.epoch == sendingEpoch {
                epoch = previous.epoch
                secret = previous.secret
            }
            if let sealed = seal(data, epoch: epoch, secret: secret) { send(sealed, targets) }
            return
        }
        switch mode {
        case .unprotected, .legacyHost:
            send(data, targets)
        case .protected:
            if let latest = memberRecord?.keys.max(by: { $0.epoch < $1.epoch }) {
                if let sealed = seal(data, epoch: latest.epoch, secret: latest.secret) { send(sealed, targets) }
            } else {
                enqueueOutbound(data, targets)
            }
        case .securing, .downgradeRefused:
            if mode == .downgradeRefused, let latest = memberRecord?.keys.max(by: { $0.epoch < $1.epoch }) {
                if let sealed = seal(data, epoch: latest.epoch, secret: latest.secret) { send(sealed, targets) }
            } else {
                enqueueOutbound(data, targets)
            }
        case .identityMismatch:
            break // fail closed
        }
    }

    private func enqueueOutbound(_ data: Data, _ targets: [String]?) {
        outboundQueue.append((data, targets))
        if outboundQueue.count > Self.maxQueuedFrames { outboundQueue.removeFirst() }
    }

    private func seal(_ data: Data, epoch: UInt32, secret: Data) -> Data? {
        counter &+= 1
        var nonce = Data(count: 12)
        let ok = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) } == errSecSuccess
        guard ok else { return nil }
        let header = OuterFrameV2.Header(epoch: epoch, session: session, counter: counter, timestampMillis: nowMillis(), nonce: nonce)
        return OuterFrameV2.seal(data, key: frameKey(epoch: epoch, secret: secret), header: header, poolID: poolID, senderPeerID: localPeerID())
    }

    // MARK: - Inbound

    /// Handles one relayed frame; app plaintext is passed to `deliver`.
    public func receive(_ data: Data, from sender: String) {
        guard sender != localPeerID() else { return } // the relay never echoes our own frames
        if TransportControlMessage.isControlFrame(data) {
            guard let message = TransportControlMessage.decode(data), message.poolID == poolID else { return }
            isHost ? hostHandle(message, from: sender) : memberHandle(message, from: sender)
            return
        }
        if OuterFrameV2.isOuterFrame(data) {
            receiveOuter(data, from: sender)
            return
        }
        receivePlain(data, from: sender)
    }

    private func receivePlain(_ data: Data, from sender: String) {
        if isHost {
            guard sender != localPeerID() else { return }
            let enabled = hostRecord?.enabled ?? false
            // Only a peer the relay announced as joined, and that has not enrolled, can be
            // classified as 1.4.x. Unknown sender IDs cannot pollute the legacy list.
            if case .pending? = members[sender] {
                members[sender] = .legacy
                announce(to: nil, removed: [])
                refreshHostStatus()
            }
            if !enabled { deliver(data, sender) }
            return
        }
        switch mode {
        case .unprotected, .legacyHost: deliver(data, sender)
        case .securing: enqueueInbound(data, sender)
        case .protected, .downgradeRefused, .identityMismatch: break // fail closed
        }
    }

    private func enqueueInbound(_ data: Data, _ sender: String) {
        inboundQueue.append((data, sender))
        if inboundQueue.count > Self.maxQueuedFrames { inboundQueue.removeFirst() }
    }

    private func receiveOuter(_ data: Data, from sender: String) {
        guard let header = OuterFrameV2.parseHeader(data), replayGuard.isFresh(header, now: now()),
              replayGuard.wouldAccept(header, sender: sender) else { return }
        guard let secret = secret(forReceiving: header.epoch, from: sender) else {
            if !isHost, mode == .securing || header.epoch > (memberRecord?.keys.map(\.epoch).max() ?? 0) {
                enqueueInbound(data, sender)
            }
            return
        }
        guard let opened = OuterFrameV2.open(data, key: frameKey(epoch: header.epoch, secret: secret), poolID: poolID, senderPeerID: sender),
              replayGuard.accept(opened.header, sender: sender) else { return }
        if isHost, case .pending? = members[sender] {
            // An outer frame proves the sender holds the secret (it enrolled earlier).
        }
        deliver(opened.plaintext, sender)
    }

    private func secret(forReceiving epoch: UInt32, from sender: String) -> Data? {
        if isHost {
            guard let record = hostRecord else { return nil }
            if epoch == record.epoch { return record.secret }
            if let previous = record.previous, previous.epoch == epoch, now() < previous.validUntil, !removedPeers.contains(sender) {
                return previous.secret
            }
            return nil
        }
        guard let keys = memberRecord?.keys, let entry = keys.first(where: { $0.epoch == epoch }) else { return nil }
        let latest = keys.map(\.epoch).max() ?? epoch
        if epoch < latest {
            guard let until = oldEpochsValidUntil, now() < until, !removedPeers.contains(sender) else { return nil }
        }
        return entry.secret
    }

    // MARK: - Host control handling

    private func hostHandle(_ message: TransportControlMessage, from sender: String) {
        guard message.kind == .keyRequest, case .host(let identity) = role, var record = hostRecord,
              message.memberPeerID == sender, isFresh(message.timestampMillis),
              let nonce = message.nonce, seenRequestNonces[nonce] == nil,
              let transcript = message.requestTranscript(),
              let identityKeyData = message.memberIdentityKey,
              identityKeyData.base64EncodedString() == sender, // the relay's peer ID is the identity key
              let memberKey = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData),
              let signature = message.memberSignature, memberKey.isValidSignature(signature, for: transcript),
              let memberEphemeralData = message.memberEphemeral,
              let memberEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: memberEphemeralData) else { return }

        var inviteKey: Data?
        if let keyID = message.inviteKeyID, !keyID.isEmpty {
            guard let invite = record.inviteKeys.first(where: { $0.id == keyID && $0.expiresAt >= now() }),
                  let proof = message.inviteProof,
                  HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: SymmetricKey(data: invite.key)) else { return }
            inviteKey = invite.key
            if !record.enrolled.contains(identityKeyData) { record.enrolled.append(identityKeyData) }
            persistHost(record)
        } else {
            guard record.enrolled.contains(identityKeyData) else { return }
        }
        seenRequestNonces[nonce] = now()

        let hostEphemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? hostEphemeral.sharedSecretFromKeyAgreement(with: memberEphemeral) else { return }
        let sealingKey = TransportControlMessage.sealingKey(sharedSecret: shared, requestTranscript: transcript, epoch: record.epoch, inviteKey: inviteKey)
        guard let sealed = try? AES.GCM.seal(record.secret, using: sealingKey,
                                             authenticating: TransportControlMessage.secretAAD(poolID: poolID, epoch: record.epoch)).combined else { return }
        var grant = TransportControlMessage(kind: .keyGrant, poolID: poolID, timestampMillis: nowMillis())
        grant.requestHash = Data(SHA256.hash(data: transcript))
        grant.epoch = record.epoch
        grant.hostEphemeral = hostEphemeral.publicKey.rawRepresentation
        grant.sealedSecret = sealed
        guard let grantTranscript = grant.grantTranscript(), let hostSig = try? identity.signature(for: grantTranscript) else { return }
        grant.hostSignature = hostSig
        if let wire = grant.encoded() { send(wire, [sender]) }

        members[sender] = .enrolled(identityKey: identityKeyData)
        rotationAwaiting.remove(sender)
        if rotationAwaiting.isEmpty, rotationDeadline != nil {
            sendingEpoch = record.epoch
            rotationDeadline = nil
        }
        reevaluateProtection()
        announce(to: [sender], removed: [])
        pruneNonces()
    }

    private func pruneNonces() {
        let cutoff = now().addingTimeInterval(-Self.controlMaxAge * 2)
        seenRequestNonces = seenRequestNonces.filter { $0.value > cutoff }
    }

    private var hostLegacyPeers: [String] {
        members.filter { $0.value == .legacy }.map(\.key).sorted()
    }

    private func reevaluateProtection() {
        guard isHost, var record = hostRecord else { return }
        if !record.enabled, !members.isEmpty,
           members.values.allSatisfy({ if case .enrolled = $0 { return true }; return false }) {
            record.enabled = true
            persistHost(record)
            announce(to: nil, removed: [])
        }
        refreshHostStatus()
    }

    private func announce(to targets: [String]?, removed: [String]) {
        guard case .host(let identity) = role, let record = hostRecord else { return }
        // Strictly increasing so members, which ignore anything not newer than the last
        // announcement they accepted, never drop two announcements made in one millisecond.
        let stamp = max(nowMillis(), lastAnnouncementSent &+ 1)
        lastAnnouncementSent = stamp
        var message = TransportControlMessage(kind: .announcement, poolID: poolID, timestampMillis: stamp)
        message.epoch = record.epoch
        message.protected = record.enabled
        message.removedPeerIDs = removed
        message.legacyPeerIDs = hostLegacyPeers
        guard let transcript = message.announcementTranscript(), let sig = try? identity.signature(for: transcript) else { return }
        message.hostSignature = sig
        if let wire = message.encoded() { send(wire, targets) }
    }

    private func refreshHostStatus() {
        guard isHost, let record = hostRecord else { return }
        status = record.enabled
            ? .protected(epoch: record.epoch, excludedLegacyPeers: hostLegacyPeers)
            : .unprotected(legacyPeers: hostLegacyPeers, legacyHost: false)
    }

    // MARK: - Member control handling

    private func sendKeyRequest() {
        guard case .member(let identity, _) = role, let record = memberRecord, let hostPeerID else { return }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 32)
        guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { return }
        var message = TransportControlMessage(kind: .keyRequest, poolID: poolID, timestampMillis: nowMillis())
        message.memberPeerID = localPeerID()
        message.memberIdentityKey = identity.publicKey.rawRepresentation
        message.memberEphemeral = ephemeral.publicKey.rawRepresentation
        message.nonce = nonce
        if !record.enrolled, let inviteKey = record.inviteKey {
            message.inviteKeyID = TransportInviteSecret.keyID(inviteKey)
        }
        guard let transcript = message.requestTranscript(), let signature = try? identity.signature(for: transcript) else { return }
        message.memberSignature = signature
        if !record.enrolled, let inviteKey = record.inviteKey {
            message.inviteProof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: inviteKey)))
        }
        outstanding = (transcript, ephemeral, now())
        if let wire = message.encoded() { send(wire, [hostPeerID]) }
    }

    private func memberHandle(_ message: TransportControlMessage, from sender: String) {
        guard sender == hostPeerID, var record = memberRecord,
              let hostKey = try? Curve25519.Signing.PublicKey(rawRepresentation: record.hostIdentityKey),
              isFresh(message.timestampMillis), let signature = message.hostSignature else { return }
        switch message.kind {
        case .keyGrant:
            guard let transcript = message.grantTranscript(), hostKey.isValidSignature(signature, for: transcript),
                  let pending = outstanding, message.requestHash == Data(SHA256.hash(data: pending.transcript)),
                  let epoch = message.epoch, let hostEphData = message.hostEphemeral,
                  let hostEph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEphData),
                  let shared = try? pending.ephemeral.sharedSecretFromKeyAgreement(with: hostEph),
                  let sealedData = message.sealedSecret,
                  let box = try? AES.GCM.SealedBox(combined: sealedData) else { return }
            let key = TransportControlMessage.sealingKey(sharedSecret: shared, requestTranscript: pending.transcript, epoch: epoch,
                                                         inviteKey: record.enrolled ? nil : record.inviteKey)
            guard let secret = try? AES.GCM.open(box, using: key, authenticating: TransportControlMessage.secretAAD(poolID: poolID, epoch: epoch)),
                  secret.count == 32 else { return }
            outstanding = nil
            let previousLatest = record.keys.map(\.epoch).max()
            record.keys.removeAll { $0.epoch == epoch }
            record.keys.append(.init(epoch: epoch, secret: secret))
            record.keys = Array(record.keys.sorted { $0.epoch < $1.epoch }.suffix(2))
            record.enrolled = true
            record.inviteKey = nil
            if let previousLatest, epoch > previousLatest {
                oldEpochsValidUntil = now().addingTimeInterval(Self.previousEpochGrace)
            }
            persistMember(record)
            drainQueues()
        case .announcement:
            guard let transcript = message.announcementTranscript(), hostKey.isValidSignature(signature, for: transcript),
                  message.timestampMillis > lastAnnouncementMillis, let epoch = message.epoch, let protected = message.protected else { return }
            lastAnnouncementMillis = message.timestampMillis
            removedPeers.formUnion(message.removedPeerIDs ?? [])
            legacyPeers = (message.legacyPeerIDs ?? []).sorted()
            announcedEpoch = epoch
            if protected {
                if !record.protected {
                    record.protected = true
                    persistMember(record)
                }
                mode = .protected
                if !record.keys.contains(where: { $0.epoch == epoch }), outstanding == nil { sendKeyRequest() }
            } else if record.protected {
                mode = .downgradeRefused
            } else {
                mode = .unprotected
            }
            refreshMemberStatus()
            drainQueues()
        case .keyRequest:
            return
        }
    }

    private func persistMember(_ record: MemberTransportRecord) {
        memberRecord = record
        if let account = memberAccount { store.save(record, account: account) }
    }

    private func drainQueues() {
        let canSend: Bool = {
            switch mode {
            case .unprotected, .legacyHost: return true
            case .protected, .downgradeRefused: return !(memberRecord?.keys.isEmpty ?? true)
            default: return false
            }
        }()
        if canSend, !outboundQueue.isEmpty {
            let queued = outboundQueue
            outboundQueue.removeAll()
            for (data, targets) in queued { sendApp(data, to: targets) }
        }
        if mode != .securing, !inboundQueue.isEmpty {
            let queued = inboundQueue
            inboundQueue.removeAll()
            for (data, sender) in queued {
                if OuterFrameV2.isOuterFrame(data), let header = OuterFrameV2.parseHeader(data),
                   secret(forReceiving: header.epoch, from: sender) == nil {
                    continue // still no key for it: drop rather than loop
                }
                receive(data, from: sender)
            }
        }
        refreshMemberStatus()
    }

    private func refreshMemberStatus() {
        guard case .member = role else { return }
        switch mode {
        case .securing: status = .securing
        case .protected:
            let epoch = memberRecord?.keys.map(\.epoch).max() ?? announcedEpoch
            status = memberRecord?.keys.isEmpty ?? true ? .securing : .protected(epoch: epoch, excludedLegacyPeers: legacyPeers)
        case .unprotected: status = .unprotected(legacyPeers: legacyPeers, legacyHost: false)
        case .legacyHost: status = .unprotected(legacyPeers: [], legacyHost: true)
        case .downgradeRefused: status = .downgradeRefused
        case .identityMismatch: status = .hostIdentityMismatch
        }
    }

    // MARK: - Timers

    /// Call about once a second.
    public func tick() {
        if isHost {
            var changed = false
            for (peerID, state) in members {
                if case .pending(let since) = state, now().timeIntervalSince(since) > Self.pendingLegacyTimeout {
                    members[peerID] = .legacy
                    changed = true
                }
            }
            if let deadline = rotationDeadline, now() >= deadline, let record = hostRecord {
                sendingEpoch = record.epoch
                rotationDeadline = nil
            }
            if changed { announce(to: nil, removed: []); refreshHostStatus() }
            return
        }
        guard hostPeerID != nil, memberRecord != nil, mode != .identityMismatch else { return }
        let needsKey = mode == .securing || (mode == .protected && !(memberRecord?.keys.contains { $0.epoch == announcedEpoch } ?? false) && announcedEpoch > 0)
        if needsKey, outstanding == nil || now().timeIntervalSince(outstanding!.sentAt) > Self.requestRetryInterval {
            sendKeyRequest()
        }
    }

    // MARK: - Forget

    /// Deletes the member's persisted transport state ("Leave pool").
    public func forgetMemberState() {
        if let account = memberAccount { store.delete(account: account) }
        memberRecord = nil
    }
}
