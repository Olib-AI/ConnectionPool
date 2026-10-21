// PoolEndTests.swift
// ConnectionPoolTests
//
// A closed pool must end for its members (and only then): the host announces
// `.poolClosed` before it tears down, a member ends on that event, on losing the host
// peer, or on the relay's "pool closed" kick, and an ordinary member leaving or a remote
// host going offline never ends the pool.

import XCTest
import Combine
@testable import ConnectionPool

@MainActor
final class PoolEndTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        InMemorySecureItemStore.install()
    }

    // MARK: - Helpers

    private let hostID = "host-device"
    private let selfID = "member-device"

    /// A member that finished joining a local pool: self first (as the real join inserts
    /// it), then the host.
    private func makeMember() -> (ConnectionPoolManager, EndRecorder) {
        let manager = ConnectionPoolManager()
        manager.remotePeerID = selfID
        let session = PoolSession(name: "Pool", hostPeerID: hostID)
        manager.setRemotePoolState(poolState: .connected, session: session, isHost: false)
        manager.addRemotePeer(Peer(id: selfID, displayName: "Me", isHost: false, status: .connected))
        manager.addRemotePeer(Peer(id: hostID, displayName: "Host", isHost: true, status: .connected))
        return (manager, EndRecorder(manager))
    }

    private func closedMessage(from sender: String) -> PoolMessage {
        PoolMessage.poolClosed(from: sender, senderName: "Host")
    }

    // MARK: - Member: host loss

    func testHostLostWithSelfInRosterEndsPool() {
        let (manager, recorder) = makeMember()
        // The member's own entry is in connectedPeers: the old `isEmpty` check never fired.
        manager.removeRemotePeer(hostID)
        XCTAssertEqual(manager.connectedPeers.map(\.id), [selfID])

        manager.handlePrimaryPeerLost(peerID: hostID, wasHost: true)

        XCTAssertEqual(manager.poolState, .idle)
        XCTAssertNil(manager.currentSession)
        XCTAssertEqual(recorder.reasons, [.hostClosed])
    }

    func testOrdinaryPeerLeavingDoesNotEndPool() {
        let (manager, recorder) = makeMember()
        manager.addRemotePeer(Peer(id: "other", displayName: "Other", isHost: false, status: .connected))
        manager.removeRemotePeer("other")

        manager.handlePrimaryPeerLost(peerID: "other", wasHost: manager.isHostPeer("other"))

        XCTAssertEqual(manager.poolState, .connected)
        XCTAssertNotNil(manager.currentSession)
        XCTAssertTrue(recorder.reasons.isEmpty)
    }

    func testLastOtherPeerLostWithoutHostSignalEndsAsConnectionLost() {
        let (manager, recorder) = makeMember()
        manager.removeRemotePeer(hostID)
        // The roster flag alone must not matter once the host is not the lost peer.
        manager.handlePrimaryPeerLost(peerID: "stranger", wasHost: false)
        XCTAssertEqual(recorder.reasons, [.connectionLost])
        XCTAssertEqual(manager.poolState, .idle)
    }

    func testHostIdentifiedBySessionNotJoinOrder() {
        let (manager, _) = makeMember()
        XCTAssertTrue(manager.isHostPeer(hostID))
        XCTAssertFalse(manager.isHostPeer(selfID))
        XCTAssertFalse(manager.isHostPeer("someone-else"))
    }

    func testHostNeverEndsItsOwnPoolThroughMemberPath() {
        let manager = ConnectionPoolManager()
        manager.remotePeerID = hostID
        manager.setRemotePoolState(poolState: .hosting, session: PoolSession(name: "P", hostPeerID: hostID), isHost: true)
        let recorder = EndRecorder(manager)

        manager.handlePrimaryPeerLost(peerID: "member", wasHost: false)
        manager.endPoolAsMember(.hostClosed)

        XCTAssertEqual(manager.poolState, .hosting)
        XCTAssertTrue(recorder.reasons.isEmpty)
    }

    // MARK: - Member: .poolClosed

    func testPoolClosedFromHostResetsMember() {
        let (manager, recorder) = makeMember()
        let transport = remoteTransport(hostPeerID: hostID)
        manager.remoteTransport = transport

        manager.injectReceivedMessage(closedMessage(from: hostID), from: hostID)

        XCTAssertEqual(recorder.reasons, [.hostClosed])
        XCTAssertEqual(manager.poolState, .idle)
        XCTAssertTrue(manager.connectedPeers.isEmpty)
        XCTAssertNil(manager.remoteTransport)
    }

    func testPoolClosedFromAnotherMemberIsIgnored() {
        let (manager, recorder) = makeMember()
        manager.remoteTransport = remoteTransport(hostPeerID: hostID)

        manager.injectReceivedMessage(closedMessage(from: "intruder"), from: "intruder")
        manager.injectReceivedMessage(closedMessage(from: hostID), from: "intruder")

        XCTAssertTrue(recorder.reasons.isEmpty)
        XCTAssertEqual(manager.poolState, .connected)
    }

    func testPoolClosedIsNeverPublishedAsChat() {
        let (manager, _) = makeMember()
        manager.remoteTransport = remoteTransport(hostPeerID: hostID)
        var published = 0
        let sub = manager.messageReceived.sink { _ in published += 1 }
        manager.injectReceivedMessage(closedMessage(from: hostID), from: hostID)
        sub.cancel()
        XCTAssertEqual(published, 0)
    }

    // MARK: - Host: announces before teardown

    func testHostBroadcastsPoolClosedBeforeTeardown() async {
        let manager = ConnectionPoolManager()
        manager.remotePeerID = hostID
        manager.setRemotePoolState(poolState: .hosting, session: PoolSession(name: "P", hostPeerID: hostID), isHost: true)
        manager.addRemotePeer(Peer(id: hostID, displayName: "Host", isHost: true, status: .connected))

        var stateAtSend: PoolState?
        var sent: PoolMessage?
        manager.sentMessageObserver = { message in
            if message.isPoolClosedEvent {
                sent = message
                stateAtSend = manager.poolState
            }
        }

        await manager.closePoolAsHost()

        XCTAssertNotNil(sent, "the host must broadcast .poolClosed")
        XCTAssertEqual(stateAtSend, .hosting, "the broadcast happens before teardown")
        XCTAssertEqual(sent?.senderID, hostID)
        XCTAssertEqual(manager.poolState, .idle)
        XCTAssertFalse(manager.isHost)
    }

    // MARK: - Remote

    func testRelayPoolClosedKickEndsRemoteMember() {
        let transport = remoteTransport(hostPeerID: hostID)
        let delegate = ErrorRecorder()
        transport.delegate = delegate

        transport.handleFrame(.kicked(KickedData(reason: "pool closed")))

        XCTAssertEqual(delegate.errors, [.poolClosed])
        XCTAssertEqual(transport.state, .failed(.poolClosed))
    }

    func testRelayHostOfflineEvictionKickEndsRemoteMember() {
        let transport = remoteTransport(hostPeerID: hostID)
        let delegate = ErrorRecorder()
        transport.delegate = delegate
        transport.handleFrame(.kicked(KickedData(reason: "pool_closed_host_offline")))
        XCTAssertEqual(delegate.errors, [.poolClosed])
    }

    func testPersonalKickIsNotPoolClosed() {
        let transport = remoteTransport(hostPeerID: hostID)
        let delegate = ErrorRecorder()
        transport.delegate = delegate
        transport.handleFrame(.kicked(KickedData(reason: "Removed by host")))
        XCTAssertEqual(delegate.errors, [.kicked])
    }

    func testViewModelEndsRemoteMemberOnPoolClosed() {
        let vm = ConnectionPoolViewModel()
        vm.transportMode = .remote
        var ended = 0
        vm.onPoolEnded = { ended += 1 }

        vm.transport(remoteTransport(hostPeerID: hostID), didFailWithError: .poolClosed)

        XCTAssertEqual(ended, 1)
        XCTAssertTrue(vm.showPoolEndedNotice)
        XCTAssertEqual(vm.poolEndedMessage, "The host closed the pool")
    }

    func testRemoteHostGoingOfflineDoesNotEndPool() {
        let (manager, recorder) = makeMember()
        manager.remoteTransport = remoteTransport(hostPeerID: hostID)

        manager.updateHostOnline(false, offlineSince: 1_714_752_345)
        manager.removeRemotePeer(hostID)

        XCTAssertEqual(manager.poolState, .connected)
        XCTAssertNotNil(manager.currentSession)
        XCTAssertTrue(recorder.reasons.isEmpty)
    }

    func testHostOfflineTransportErrorDoesNotEndPool() {
        let vm = ConnectionPoolViewModel()
        var ended = 0
        vm.onPoolEnded = { ended += 1 }
        vm.transport(remoteTransport(hostPeerID: hostID), didFailWithError: .hostOffline)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(vm.showPoolEndedNotice)
    }

    func testClosePoolFrameIsEmittedByTransportClosePool() async {
        let transport = remoteTransport(hostPeerID: hostID)
        var frames: [String] = []
        transport.outboundFrameObserver = { data in
            frames.append(String(decoding: data, as: UTF8.self))
        }
        await transport.closePool(flushTimeout: .milliseconds(50))
        XCTAssertTrue(frames.contains { $0.contains("close_pool") })
        XCTAssertEqual(transport.state, .idle)
    }

    // MARK: - Wire compatibility

    func testUnknownSystemEventDecodesWithoutFailing() throws {
        let json = #"{"text":"hello","event":"some_future_event","targetPeerID":"abc"}"#
        let payload = try JSONDecoder().decode(SystemPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.text, "hello")
        XCTAssertNil(payload.event)
        XCTAssertEqual(payload.targetPeerID, "abc")
    }

    func testPlainAndKnownEventsStillDecode() throws {
        let plain = try JSONDecoder().decode(SystemPayload.self, from: Data(#"{"text":"hi"}"#.utf8))
        XCTAssertNil(plain.event)
        let closed = try JSONDecoder().decode(SystemPayload.self, from: Data(#"{"text":"x","event":"pool_closed"}"#.utf8))
        XCTAssertEqual(closed.event, .poolClosed)
        let removed = try JSONDecoder().decode(SystemPayload.self, from: Data(#"{"text":"x","event":"removed_from_pool"}"#.utf8))
        XCTAssertEqual(removed.event, .removedFromPool)
    }

    func testUnknownEventMessageIsNotAPoolClosedEvent() {
        let payload = Data(#"{"text":"t","event":"some_future_event"}"#.utf8)
        let message = PoolMessage(type: .system, senderID: hostID, senderName: "H", payload: payload, isReliable: true)
        XCTAssertFalse(message.isPoolClosedEvent)
        XCTAssertNotNil(message.decodePayload(as: SystemPayload.self))
    }

    func testPoolClosedMessageRoundTrips() throws {
        let message = closedMessage(from: hostID)
        let data = try XCTUnwrap(message.encode())
        let decoded = try XCTUnwrap(PoolMessage.decode(from: data))
        XCTAssertTrue(decoded.isPoolClosedEvent)
        XCTAssertNil(decoded.decodePayload(as: SystemPayload.self)?.targetPeerID)
    }

    // MARK: - Fixtures

    private func remoteTransport(hostPeerID: String) -> WebSocketTransport {
        let config = RemotePoolConfiguration(
            serverURL: URL(string: "wss://pool-end.example/ws")!,
            poolName: "Pool",
            maxPeers: 8,
            maxReconnectAttempts: 0
        )
        let transport = WebSocketTransport(configuration: config, displayName: "Me")
        transport.currentPoolInfo = ServerPoolInfo(
            poolId: UUID(), name: "Pool", hostPeerId: hostPeerID, maxPeers: 8, currentPeers: 2
        )
        return transport
    }
}

@MainActor
private final class EndRecorder {
    var reasons: [ConnectionPoolManager.PoolEndReason] = []
    private var cancellable: AnyCancellable?
    init(_ manager: ConnectionPoolManager) {
        cancellable = manager.poolEnded.sink { [weak self] in self?.reasons.append($0) }
    }
}

@MainActor
private final class ErrorRecorder: TransportDelegate {
    var errors: [TransportError] = []
    func transport(_ transport: any TransportProvider, didChangeState: TransportState) {}
    func transport(_ transport: any TransportProvider, peerDidConnect peer: TransportPeer) {}
    func transport(_ transport: any TransportProvider, peerDidDisconnect peerID: String) {}
    func transport(_ transport: any TransportProvider, didReceiveData data: Data, from peerID: String) {}
    func transport(_ transport: any TransportProvider, didDiscoverPool pool: DiscoveredPool) {}
    func transport(_ transport: any TransportProvider, didLosePool poolID: String) {}
    func transport(_ transport: any TransportProvider, didReceiveJoinRequest peerID: String,
                   displayName: String, context: JoinContext) {}
    func transport(_ transport: any TransportProvider, didFailWithError error: TransportError) {
        errors.append(error)
    }
}
