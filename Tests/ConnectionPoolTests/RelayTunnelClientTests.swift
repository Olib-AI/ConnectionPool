// RelayTunnelClientTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

// MARK: - Captured Sends

/// Thread-safe capture of every frame the `RelayTunnelClient` pushes through the bridge.
private final class CapturedSends: @unchecked Sendable {
    private let lock = NSLock()
    private var _serverFrames: [ServerFrame] = []
    private var _binaryData: [(streamID: UInt32, sequence: UInt32, payload: Data)] = []
    private var _binaryUdp: [(streamID: UInt32, payload: Data)] = []

    var serverFrames: [ServerFrame] { lock.withLock { _serverFrames } }
    var binaryData: [(streamID: UInt32, sequence: UInt32, payload: Data)] { lock.withLock { _binaryData } }
    var binaryUdp: [(streamID: UInt32, payload: Data)] { lock.withLock { _binaryUdp } }

    func appendServerFrame(_ f: ServerFrame) {
        lock.withLock { _serverFrames.append(f) }
    }
    func appendBinaryData(streamID: UInt32, sequence: UInt32, payload: Data) {
        lock.withLock { _binaryData.append((streamID, sequence, payload)) }
    }
    func appendBinaryUdp(streamID: UInt32, payload: Data) {
        lock.withLock { _binaryUdp.append((streamID, payload)) }
    }
    func reset() {
        lock.withLock {
            _serverFrames.removeAll()
            _binaryData.removeAll()
            _binaryUdp.removeAll()
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
final class RelayTunnelClientTests: XCTestCase {

    private func makeClient(captures: CapturedSends, available: Bool = true) -> RelayTunnelClient {
        let bridge = RelayTunnelClient.TransportSendBridge(
            sendServerFrame: { frame in captures.appendServerFrame(frame) },
            sendTunnelData: { streamID, seq, payload in
                captures.appendBinaryData(streamID: streamID, sequence: seq, payload: payload)
            },
            sendTunnelUdp: { streamID, payload in
                captures.appendBinaryUdp(streamID: streamID, payload: payload)
            }
        )
        return RelayTunnelClient(transportBridge: bridge, availabilityProvider: { available })
    }

    // MARK: - Open stream

    func testOpenStreamEmitsTunnelOpenFrame() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)

        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )
        XCTAssertEqual(stream.streamId, 1)
        XCTAssertEqual(captures.serverFrames.count, 1)
        guard case .tunnelOpen(let data) = captures.serverFrames[0] else {
            return XCTFail("expected tunnelOpen, got \(captures.serverFrames[0])")
        }
        XCTAssertEqual(data.streamId, 1)
        XCTAssertEqual(data.network, .tcp)
        XCTAssertEqual(data.initialWindow, TunnelLimits.initialReceiveWindow)
    }

    func testOpenStreamRejectedWhenUnavailable() async {
        let captures = CapturedSends()
        let client = makeClient(captures: captures, available: false)
        do {
            _ = try await client.openStream(to: .hostname(host: "example.com", port: 443), network: .tcp)
            XCTFail("should have thrown")
        } catch let error as RelayTunnelError {
            if case .notAvailable = error {
                // expected
            } else {
                XCTFail("expected .notAvailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(captures.serverFrames.count, 0)
    }

    // MARK: - Outbound flow control

    func testCreditFlowControlBlocksWhenWindowExhausted() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )
        captures.reset()

        // 256 KiB initial window. 200 KiB fits.
        let firstChunk = Data(repeating: 0xAB, count: 200 * 1024)
        try await stream.send(firstChunk)
        XCTAssertGreaterThan(captures.binaryData.count, 0)

        // Use the rest (56 KiB).
        let secondChunk = Data(repeating: 0xCD, count: 56 * 1024)
        try await stream.send(secondChunk)

        let preBlockCount = captures.binaryData.count

        // Now credit is 0. Spawn a send that should block.
        let nextChunk = Data(repeating: 0xEF, count: 16 * 1024)
        let blockedSendTask = Task {
            try await stream.send(nextChunk)
        }

        // Give the task a moment to enter the wait state.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(captures.binaryData.count, preBlockCount,
                       "send should be blocked while credit is exhausted")

        // Grant 64 KiB — releases the waiter.
        await client.handleIncomingTunnelFrame(.tunnelWindowUpdate(TunnelWindowUpdateData(
            streamId: stream.streamId,
            additionalCredit: UInt32(64 * 1024)
        )))

        // The previously blocked send should now complete.
        try await blockedSendTask.value
        XCTAssertGreaterThan(captures.binaryData.count, preBlockCount,
                             "blocked send should have flushed after window update")
    }

    // MARK: - Inbound binary

    func testInboundBinaryDataPublishesOnReceiveStream() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 80),
            network: .tcp
        )

        let payload = Data("hello".utf8)
        await client.handleIncomingBinaryFrame(
            type: TunnelBinaryType.data.rawValue,
            streamID: stream.streamId,
            sequence: 1,
            payload: payload
        )
        var iter = stream.receive.makeAsyncIterator()
        let received = try await iter.next()
        XCTAssertEqual(received, payload)
    }

    func testInboundBinaryEmitsWindowUpdateAfterThreshold() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )
        captures.reset()

        // Push 64 KiB inbound across two 32 KiB chunks. Stream consumer must drain to advance counters.
        let chunkA = Data(repeating: 0x11, count: 32 * 1024)
        let chunkB = Data(repeating: 0x22, count: 32 * 1024)

        let consumerTask = Task {
            var iter = stream.receive.makeAsyncIterator()
            _ = try await iter.next()
            _ = try await iter.next()
        }

        await client.handleIncomingBinaryFrame(
            type: TunnelBinaryType.data.rawValue,
            streamID: stream.streamId,
            sequence: 1,
            payload: chunkA
        )
        await client.handleIncomingBinaryFrame(
            type: TunnelBinaryType.data.rawValue,
            streamID: stream.streamId,
            sequence: 2,
            payload: chunkB
        )
        try await consumerTask.value

        // Allow the async window-update task to fire.
        try await Task.sleep(nanoseconds: 100_000_000)

        let windowUpdates = captures.serverFrames.compactMap { (frame: ServerFrame) -> TunnelWindowUpdateData? in
            if case .tunnelWindowUpdate(let data) = frame { return data }
            return nil
        }
        XCTAssertGreaterThanOrEqual(windowUpdates.count, 1, "expected at least one window_update after 64 KiB consumed")
        let granted = windowUpdates.reduce(UInt32(0)) { $0 + $1.additionalCredit }
        XCTAssertGreaterThanOrEqual(granted, TunnelLimits.windowUpdateThreshold)
    }

    // MARK: - Policy denial -> kill switch

    func testPolicyDeniedCloseTriggersKillSwitchNotification() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )

        let exp = expectation(forNotification: Notification.Name("RelayTunnelKillSwitchTriggered"), object: nil)

        await client.handleIncomingTunnelFrame(.tunnelClose(TunnelCloseData(
            streamId: stream.streamId,
            reason: .policyDenied
        )))

        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testPolicyDeniedErrorAlsoTriggersKillSwitch() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )
        let exp = expectation(forNotification: Notification.Name("RelayTunnelKillSwitchTriggered"), object: nil)
        await client.handleIncomingTunnelFrame(.tunnelError(TunnelErrorData(
            streamId: stream.streamId,
            code: .policyDenied,
            message: "host says no"
        )))
        await fulfillment(of: [exp], timeout: 1.0)
    }

    // MARK: - Unknown binary type byte

    func testUnknownBinaryTypeEmitsProtocolError() async throws {
        let captures = CapturedSends()
        let client = makeClient(captures: captures)
        let stream = try await client.openStream(
            to: .hostname(host: "example.com", port: 443),
            network: .tcp
        )
        captures.reset()

        // 0x10 is in the unknown-but-defined range — the client should reject.
        await client.handleIncomingBinaryFrame(
            type: 0x10,
            streamID: stream.streamId,
            sequence: nil,
            payload: Data([0xFF])
        )

        // Allow the async send to fire.
        try await Task.sleep(nanoseconds: 100_000_000)

        let errors = captures.serverFrames.compactMap { (frame: ServerFrame) -> TunnelErrorData? in
            if case .tunnelError(let data) = frame { return data }
            return nil
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, .protocolError)
    }
}
