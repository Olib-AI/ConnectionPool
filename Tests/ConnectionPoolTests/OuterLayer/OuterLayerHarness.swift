// OuterLayerHarness.swift
// ConnectionPoolTests
//
// In-process pool: one host, N members (each with its own simulated Keychain), and a relay
// that routes frames like StealthRelay, records every byte it is given, and can tamper.

import Foundation
import CryptoKit
@testable import ConnectionPool

@MainActor
final class OuterLayerHarness {
    struct Wire { let from: String; let data: Data; let targets: [String]? }

    let poolID = UUID()
    let serverURL = "wss://relay.example/ws"
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let hostKey = Curve25519.Signing.PrivateKey()
    var hostID: String { hostKey.publicKey.rawRepresentation.base64EncodedString() }

    private(set) var host: PoolTransportSecurity!
    private(set) var members: [String: PoolTransportSecurity] = [:]
    private(set) var memberKeys: [String: Curve25519.Signing.PrivateKey] = [:]
    private(set) var stores: [String: InMemorySecureItemStore] = [:]
    /// Peers that run no outer layer at all (StealthOS 1.4.x).
    private(set) var legacy: Set<String> = []

    /// Every payload any node handed to the relay, in order.
    private(set) var wire: [Wire] = []
    /// Every forward frame exactly as the transport would serialize it.
    private(set) var wireJSON: [Data] = []
    var delivered: [String: [(data: Data, from: String)]] = [:]
    private var queue: [Wire] = []

    /// Relay behaviour hooks.
    var tamper: ((inout Wire) -> Bool)?  // return false to drop

    init() {
        let store = InMemorySecureItemStore()
        stores[hostID] = store
        host = PoolTransportSecurity(
            hostIdentity: hostKey, poolID: poolID, store: Self.store(store), now: { [unowned self] in self.clock },
            localPeerID: { [unowned self] in self.hostID },
            send: { [unowned self] data, targets in self.enqueue(from: self.hostID, data, targets) },
            deliver: { [unowned self] data, from in self.delivered[self.hostID, default: []].append((data, from)) }
        )
    }

    static func store(_ s: InMemorySecureItemStore) -> TransportSecurityStore {
        TransportSecurityStore(store: { s })
    }

    func makeInvite(expiresIn: TimeInterval = 300) -> TransportInviteSecret {
        let secret = TransportInviteSecret.generate(hostIdentityKey: hostKey.publicKey.rawRepresentation)
        host.registerInvite(secret, expiresAt: clock.addingTimeInterval(expiresIn))
        return secret
    }

    /// Adds a 1.5.0 member that joined with `invite` (nil = rejoin from persisted state).
    @discardableResult
    func addMember(invite: TransportInviteSecret?, key: Curve25519.Signing.PrivateKey = .init(),
                   connect: Bool = true, hostPeerIDOverride: String? = nil) -> String {
        let id = key.publicKey.rawRepresentation.base64EncodedString()
        let store = stores[id] ?? InMemorySecureItemStore()
        stores[id] = store
        memberKeys[id] = key
        let member = PoolTransportSecurity(
            memberIdentity: key, serverURL: serverURL, poolID: poolID, invite: invite, store: Self.store(store),
            now: { [unowned self] in self.clock }, localPeerID: { id },
            send: { [unowned self] data, targets in self.enqueue(from: id, data, targets) },
            deliver: { [unowned self] data, from in self.delivered[id, default: []].append((data, from)) }
        )
        members[id] = member
        if connect {
            host.peerJoined(id)
            member.connected(hostPeerID: hostPeerIDOverride ?? hostID)
            pump()
        }
        return id
    }

    /// Adds a StealthOS 1.4.x member (no outer layer; sends plaintext).
    @discardableResult
    func addLegacyMember() -> String {
        let id = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        legacy.insert(id)
        host.peerJoined(id)
        return id
    }

    func removeMember(_ id: String) {
        host.memberRemoved(id)
        members.removeValue(forKey: id)
        pump()
    }

    func legacySend(_ from: String, _ data: Data, to targets: [String]? = nil) {
        enqueue(from: from, data, targets)
        pump()
    }

    func node(_ id: String) -> PoolTransportSecurity? { id == hostID ? host : members[id] }

    func enqueue(from: String, _ data: Data, _ targets: [String]?) {
        let w = Wire(from: from, data: data, targets: targets)
        wire.append(w)
        if let json = try? ServerFrame.forward(ForwardData(data: data.base64EncodedString(), targetPeerIds: targets, sequence: UInt64(wire.count))).toJSON() {
            wireJSON.append(json)
        }
        queue.append(w)
    }

    /// Inject a frame as if the relay delivered it from `from` (attacker / replay).
    func inject(_ data: Data, from: String, to target: String) {
        node(target)?.receive(data, from: from)
        pump()
    }

    func pump() {
        while !queue.isEmpty {
            var w = queue.removeFirst()
            if let tamper, !tamper(&w) { continue }
            let everyone = [hostID] + Array(members.keys) + Array(legacy)
            let targets = w.targets ?? everyone.filter { $0 != w.from }
            for target in targets where target != w.from {
                node(target)?.receive(w.data, from: w.from)
                if legacy.contains(target) { delivered[target, default: []].append((w.data, w.from)) }
            }
        }
    }

    func tick(_ seconds: TimeInterval = 1) {
        clock = clock.addingTimeInterval(seconds)
        host.tick()
        for m in members.values { m.tick() }
        pump()
    }

    func payloads(at id: String) -> [String] {
        (delivered[id] ?? []).map { String(decoding: $0.data, as: UTF8.self) }
    }

    func hostRecord() -> HostTransportRecord? {
        Self.store(stores[hostID]!).load(HostTransportRecord.self, account: TransportSecurityStore.hostAccount(poolID))
    }

    func memberRecord(_ id: String) -> MemberTransportRecord? {
        Self.store(stores[id]!).load(MemberTransportRecord.self, account: TransportSecurityStore.memberAccount(serverURL: serverURL, poolID: poolID))
    }
}

extension Data {
    /// Whether `needle` occurs anywhere in `self` (raw bytes).
    func containsBytes(_ needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return range(of: needle) != nil
    }
}

/// All the encodings a secret could leak in through a JSON/base64 wire.
func leakForms(_ secret: Data) -> [Data] {
    let b64 = secret.base64EncodedString()
    let b64url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let hex = secret.map { String(format: "%02x", $0) }.joined()
    // Also the base64 of base64 (the forward frame base64-encodes the payload once more).
    let b64b64 = Data(b64.utf8).base64EncodedString()
    var forms = [secret, Data(b64.utf8), Data(b64url.utf8), Data(hex.utf8), Data(hex.uppercased().utf8), Data(b64b64.utf8)]
    // Any 16-byte window of the raw secret (partial leaks).
    for start in stride(from: 0, through: secret.count - 16, by: 8) {
        forms.append(secret.subdata(in: start..<(start + 16)))
    }
    return forms
}
