// WebSocketOuterLayerTransportTests.swift
// ConnectionPoolTests
//
// End to end through two real WebSocketTransport instances (host and member). A test relay
// takes every frame each transport serializes (the exact JSON text it would put on the
// socket) and routes forward frames as relayed frames, like StealthRelay.

import Foundation
import CryptoKit
import Testing
@testable import ConnectionPool

@MainActor
final class RecordingTransportDelegate: TransportDelegate {
    var received: [(Data, String)] = []
    var errors: [TransportError] = []
    func transport(_ transport: any TransportProvider, didChangeState: TransportState) {}
    func transport(_ transport: any TransportProvider, peerDidConnect peer: TransportPeer) {}
    func transport(_ transport: any TransportProvider, peerDidDisconnect peerID: String) {}
    func transport(_ transport: any TransportProvider, didReceiveData data: Data, from peerID: String) { received.append((data, peerID)) }
    func transport(_ transport: any TransportProvider, didDiscoverPool pool: DiscoveredPool) {}
    func transport(_ transport: any TransportProvider, didLosePool poolID: String) {}
    func transport(_ transport: any TransportProvider, didReceiveJoinRequest peerID: String, displayName: String, context: JoinContext) {}
    func transport(_ transport: any TransportProvider, didFailWithError error: TransportError) { errors.append(error) }
}

@MainActor
@Suite("Remote outer layer through WebSocketTransport", .serialized)
struct WebSocketOuterLayerTransportTests {

    /// A simulated join writes a member record (UserDefaults) like a real one would; remove
    /// every record for the test relay, including any left by an interrupted run.
    static func purgeTestRecords() {
        for record in RemoteMemberRecordStore.allRecords() where record.serverURL == "wss://relay.example/ws" {
            RemoteMemberRecordStore.remove(serverURL: record.serverURL, poolID: record.poolID)
        }
    }

    final class Relay {
        var outbound: [String: [Data]] = [:]   // every frame each peer's transport serialized
        var cursor: [String: Int] = [:]
        var transports: [String: WebSocketTransport] = [:]
        var sequence: UInt64 = 0

        @MainActor func attach(_ t: WebSocketTransport, as id: String) {
            transports[id] = t
            t.outboundFrameObserver = { [unowned self] data in self.outbound[id, default: []].append(data) }
        }

        @MainActor func pump() {
            var progressed = true
            while progressed {
                progressed = false
                for (id, frames) in outbound {
                    let start = cursor[id] ?? 0
                    guard start < frames.count else { continue }
                    cursor[id] = frames.count
                    progressed = true
                    for json in frames[start...] {
                        guard case .forward(let fwd)? = try? ServerFrame.fromJSON(json) else { continue }
                        let targets = fwd.targetPeerIds ?? transports.keys.filter { $0 != id }
                        for target in targets where target != id {
                            sequence += 1
                            transports[target]?.handleFrame(.relayed(RelayedData(data: fwd.data, fromPeerId: id, sequence: sequence)))
                        }
                    }
                }
            }
        }

        var allBytes: [Data] { outbound.values.flatMap { $0 } }
    }

    @Test("Every byte either transport sends is free of the secret, the invite key and app plaintext")
    func transportBytes() throws {
        InMemorySecureItemStore.install()
        let config = RemotePoolConfiguration(serverURL: URL(string: "wss://relay.example/ws")!, poolName: "t")
        let poolID = UUID()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostID = hostKey.publicKey.rawRepresentation.base64EncodedString()
        let memberIdentity = RemoteMemberIdentity(privateKey: Curve25519.Signing.PrivateKey())
        let memberID = memberIdentity.publicKeyBase64

        let host = WebSocketTransport(configuration: config, displayName: "Host")
        let member = WebSocketTransport(configuration: config, displayName: "Member")
        let hostDelegate = RecordingTransportDelegate(), memberDelegate = RecordingTransportDelegate()
        host.delegate = hostDelegate
        member.delegate = memberDelegate
        let relay = Relay()
        relay.attach(host, as: hostID)
        relay.attach(member, as: memberID)
        defer {
            host.disconnect(); member.disconnect()
            Self.purgeTestRecords()
        }

        host.isHostRole = true
        host.hostIdentity = RemoteHostIdentity(privateKey: hostKey)
        host.handleFrame(.hostAuthSuccess(HostAuthSuccessData(poolId: poolID, sessionToken: "host-session")))
        let invite = try #require(host.makeInviteSecret(expiresAt: Date().addingTimeInterval(300)))

        member.memberIdentity = memberIdentity
        member.joinInvitation = ParsedInvitation(serverURL: config.serverURL, poolId: poolID, tokenId: Data(count: 16),
                                                 tokenSecret: Data(count: 32), hostFingerprint: Data(count: 8),
                                                 expiresAt: Date().addingTimeInterval(300), transportSecret: invite)
        let poolInfo = ServerPoolInfo(poolId: poolID, name: "t", hostPeerId: hostID, maxPeers: 8, currentPeers: 2)
        host.handleFrame(.peerJoined(PeerJoinedData(peer: ServerPeerInfo(peerId: memberID, displayName: "Member", publicKey: memberID, connectedAt: 0))))
        member.handleFrame(.joinAccepted(JoinAcceptedData(sessionToken: "member-session", peerId: memberID, peers: [], poolInfo: poolInfo)))
        relay.pump()

        #expect(member.outerLayerStatus == .protected(epoch: 1, excludedLegacyPeers: []))
        #expect(host.outerLayerStatus == .protected(epoch: 1, excludedLegacyPeers: []))

        let marker = "WIRE-MARKER-8f2c1e"
        member.broadcast(Data("\(marker) from member".utf8), reliable: true)
        host.send(Data("\(marker) from host".utf8), to: [memberID], reliable: true)
        relay.pump()
        #expect(hostDelegate.received.map { String(decoding: $0.0, as: UTF8.self) } == ["\(marker) from member"])
        #expect(memberDelegate.received.map { String(decoding: $0.0, as: UTF8.self) } == ["\(marker) from host"])

        let secret = try #require(host.transportSecurity.flatMap { _ in
            TransportSecurityStore().load(HostTransportRecord.self, account: TransportSecurityStore.hostAccount(poolID))?.secret
        })
        #expect(!relay.allBytes.isEmpty)
        for frame in relay.allBytes {
            for needle in leakForms(secret) + leakForms(invite.inviteKey) + [Data(marker.utf8)] {
                #expect(!frame.containsBytes(needle), "the relay received secret material or plaintext")
            }
        }
        // The fragment travels out of band only; it is not in anything sent to the relay.
        for frame in relay.allBytes { #expect(!frame.containsBytes(Data(invite.fragment.utf8))) }
    }

    @Test("A member whose server-named host differs from the invitation fails the connection")
    func hostMismatchFailsConnection() throws {
        InMemorySecureItemStore.install()
        let config = RemotePoolConfiguration(serverURL: URL(string: "wss://relay.example/ws")!, poolName: "t")
        let poolID = UUID()
        let member = WebSocketTransport(configuration: config, displayName: "Member")
        let delegate = RecordingTransportDelegate()
        member.delegate = delegate
        defer {
            member.disconnect()
            Self.purgeTestRecords()
        }
        let identity = RemoteMemberIdentity(privateKey: Curve25519.Signing.PrivateKey())
        member.memberIdentity = identity
        let invite = TransportInviteSecret.generate(hostIdentityKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        member.joinInvitation = ParsedInvitation(serverURL: config.serverURL, poolId: poolID, tokenId: Data(count: 16),
                                                 tokenSecret: Data(count: 32), hostFingerprint: Data(count: 8),
                                                 expiresAt: Date().addingTimeInterval(300), transportSecret: invite)
        let impostorHost = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        member.handleFrame(.joinAccepted(JoinAcceptedData(sessionToken: "s", peerId: identity.publicKeyBase64, peers: [],
                                                          poolInfo: ServerPoolInfo(poolId: poolID, name: "t", hostPeerId: impostorHost, maxPeers: 8, currentPeers: 2))))
        #expect(member.outerLayerStatus == .hostIdentityMismatch)
        #expect(!delegate.errors.isEmpty)
    }
}
