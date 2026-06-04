// ResumeTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Reconnect / resume coverage:
//
//   * Within 30 s window, host re-encrypts plaintext buffer under K_s2c'
//     and the guest decodes the replayed frame under the new keys.
//   * Beyond window → BAD_CODE.
//   * 256-frame outbound buffer overflow → INCOMPATIBLE.
//   * ADR-0006 cross-platform seq preservation: guest's next send after
//     resume carries `seq = N + 1`, NOT `seq = 0`.

import XCTest
@testable import ConnectionPool

final class ResumeTests: XCTestCase {

    // MARK: - Host replays unacked plaintext under new K_s2c'

    func test_resume_replays_unacked_under_new_keys() async throws {
        // Step 1: fresh host + guest, full handshake. Host sends two
        // game_action frames (seq=0, seq=1). Guest receives them.
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        let tapCode = "482917"

        let (rawHostA, rawGuestA) = InMemoryConnection.pair()
        async let hostSA: CrossPlatformSession = hostPool.acceptGuest(raw: rawHostA, tapCode: tapCode)
        async let guestSA: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuestA, tapCode: tapCode)
        let (hostA, guestA) = try await (hostSA, guestSA)

        try await hostA.send(.start(hostColor: .white, startingFEN: CrossPlatformHandshake.standardStartingFEN))
        try await hostA.send(.move(uci: "e2e4"))

        // Drain both guest-side messages.
        var iter = guestA.inbound.makeAsyncIterator()
        _ = await iter.next()
        let firstMove = await iter.next()
        XCTAssertNotNil(firstMove)

        // Snapshot the host's resume state before tearing down.
        let sessionIdB64u = await hostA.sessionIdB64u
        let sessionIdRaw = await hostA.sessionIdRaw
        let outboundBuffer = await hostA.snapshotOutboundBuffer()
        let nextOutboundSeq = await hostA.outboundSeqSnapshot()
        let lastInboundSeq = await hostA.inboundSeqSnapshot()
        XCTAssertEqual(outboundBuffer.count, 2, "two plaintexts buffered")
        XCTAssertEqual(outboundBuffer.map { $0.seq }, [0, 1])
        XCTAssertEqual(nextOutboundSeq, 2)

        await hostPool.rememberDisconnect(
            sessionIdB64u: sessionIdB64u,
            sessionIdRaw: sessionIdRaw,
            outboundBuffer: outboundBuffer,
            nextOutboundSeq: nextOutboundSeq,
            lastInboundSeq: lastInboundSeq
        )
        await hostA.close()
        await guestA.close()

        // Step 2: guest resumes. Announce acked_seq=0 — host should replay
        // seq=1 only (seq=0 is already acked).
        let (rawHostB, rawGuestB) = InMemoryConnection.pair()
        let resume = CrossPlatformClientHelloResume(sessionId: sessionIdB64u, ackedSeq: 0)
        async let hostSB: CrossPlatformSession = hostPool.acceptGuest(raw: rawHostB, tapCode: tapCode)
        async let guestSB: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuestB, tapCode: tapCode, resume: resume)
        let (hostB, guestB) = try await (hostSB, guestSB)

        // Resumed guest should receive the seq=1 frame on its inbound stream.
        var iterB = guestB.inbound.makeAsyncIterator()
        let replayed = await iterB.next()
        XCTAssertNotNil(replayed, "guest should receive replayed seq=1")
        let envelope = try CrossPlatformGameActionEnvelope.decode(replayed!.payload)
        XCTAssertEqual(envelope.seq, 1)
        if case .move(let uci) = envelope.action {
            XCTAssertEqual(uci, "e2e4")
        } else {
            XCTFail("expected replayed action to be move(e2e4)")
        }

        await hostB.close()
        await guestB.close()
    }

    // MARK: - Beyond 30 s window → BAD_CODE

    func test_resume_beyond_window_yields_BAD_CODE() async throws {
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        // Shrink the window to 50ms for test speed.
        await hostPool.setResumeWindowMillis(50)
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        let tapCode = "482917"

        // Build a host-side resume entry with a fake stale session_id.
        let stashedSessionRaw = Data(repeating: 0x77, count: 16)
        let stashedSessionId = CrossPlatformBase64.encode16(stashedSessionRaw)
        await hostPool.rememberDisconnect(
            sessionIdB64u: stashedSessionId,
            sessionIdRaw: stashedSessionRaw,
            outboundBuffer: [],
            nextOutboundSeq: 0,
            lastInboundSeq: nil
        )
        // Wait long enough for the window to expire.
        try await Task.sleep(nanoseconds: 200_000_000)

        let (rawHost, rawGuest) = InMemoryConnection.pair()
        let resume = CrossPlatformClientHelloResume(sessionId: stashedSessionId, ackedSeq: 0)
        async let hostDrive: () = {
            do {
                _ = try await hostPool.acceptGuest(raw: rawHost, tapCode: tapCode)
                XCTFail("host expected BAD_CODE")
            } catch let e as CrossPlatformTransportException {
                XCTAssertEqual(e.tag, .badCode)
            } catch { XCTFail("unexpected \(error)") }
        }()
        async let guestDrive: () = {
            do {
                _ = try await guestPool.connectAsGuest(raw: rawGuest, tapCode: tapCode, resume: resume)
                XCTFail("guest expected BAD_CODE")
            } catch let e as CrossPlatformTransportException {
                XCTAssertEqual(e.tag, .badCode)
            } catch { XCTFail("unexpected \(error)") }
        }()
        await hostDrive
        await guestDrive
    }

    // MARK: - ADR-0006: guest seq preservation across resume

    func test_guest_seq_preservation_after_resume() async throws {
        // Drive a session where the guest sends seq=0 + seq=1, then
        // disconnect, then resume. The resumed guest's next send must carry
        // seq=2, not seq=0.
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        let tapCode = "482917"

        // Step 1: handshake + 2 guest sends.
        let (rawHostA, rawGuestA) = InMemoryConnection.pair()
        async let hostSA: CrossPlatformSession = hostPool.acceptGuest(raw: rawHostA, tapCode: tapCode)
        async let guestSA: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuestA, tapCode: tapCode)
        let (hostA, guestA) = try await (hostSA, guestSA)
        try await guestA.send(.resign) // seq=0
        try await guestA.send(.offerDraw) // seq=1
        // Drain host inbound.
        var hostIter = hostA.inbound.makeAsyncIterator()
        _ = await hostIter.next()
        _ = await hostIter.next()
        let sessionIdB64u = await guestA.sessionIdB64u
        let sessionIdRaw = await hostA.sessionIdRaw
        let lastInboundSeqOnHost = await hostA.inboundSeqSnapshot()
        let nextOutboundSeqOnHost = await hostA.outboundSeqSnapshot()
        let hostBuffer = await hostA.snapshotOutboundBuffer()

        // Remember on host side so the resume handshake can succeed.
        await hostPool.rememberDisconnect(
            sessionIdB64u: sessionIdB64u,
            sessionIdRaw: sessionIdRaw,
            outboundBuffer: hostBuffer,
            nextOutboundSeq: nextOutboundSeqOnHost,
            lastInboundSeq: lastInboundSeqOnHost
        )
        await hostA.close()
        await guestA.close()
        // Wait long enough for `attachGuestResumeStashListener` to fire on
        // the guest pool. The listener is a Task spawned in connectAsGuest;
        // it awaits Disconnected, then snapshots and stashes. A 50ms sleep
        // is generous on M-series simulators.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Step 2: resume.
        let (rawHostB, rawGuestB) = InMemoryConnection.pair()
        let resume = CrossPlatformClientHelloResume(sessionId: sessionIdB64u, ackedSeq: 1)
        async let hostSB: CrossPlatformSession = hostPool.acceptGuest(raw: rawHostB, tapCode: tapCode)
        async let guestSB: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuestB, tapCode: tapCode, resume: resume)
        let (hostB, guestB) = try await (hostSB, guestSB)

        // Verify the resumed guest's nextOutboundSeq is 2 (NOT 0).
        let resumedNextSeq = await guestB.outboundSeqSnapshot()
        XCTAssertEqual(resumedNextSeq, 2, "resumed guest must continue seq space at 2 (ADR-0006)")

        // Have the guest send again; assert the seq embedded in the envelope.
        try await guestB.send(.acceptDraw)
        var hostIterB = hostB.inbound.makeAsyncIterator()
        let received = await hostIterB.next()
        XCTAssertNotNil(received)
        let env = try CrossPlatformGameActionEnvelope.decode(received!.payload)
        XCTAssertEqual(env.seq, 2, "resumed guest's next send must carry seq=2")
        XCTAssertEqual(env.action, .acceptDraw)

        await hostB.close()
        await guestB.close()
    }

    // MARK: - 256-frame overflow → INCOMPATIBLE

    func test_outboundBufferOverflow_yields_INCOMPATIBLE() async throws {
        // Host emits 256 game_action frames. The 257th must trip
        // INCOMPATIBLE via `bufferForResume`.
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        let tapCode = "482917"
        let (rawHost, rawGuest) = InMemoryConnection.pair()
        async let hostS: CrossPlatformSession = hostPool.acceptGuest(raw: rawHost, tapCode: tapCode)
        async let guestS: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuest, tapCode: tapCode)
        let (host, _) = try await (hostS, guestS)

        // Fill the buffer exactly to its cap.
        for _ in 0..<CrossPlatformSession.outboundBufferCap {
            try await host.send(.resign)
        }
        // The 257th must throw INCOMPATIBLE.
        do {
            try await host.send(.resign)
            XCTFail("expected INCOMPATIBLE on buffer overflow")
        } catch let e as CrossPlatformTransportException {
            XCTAssertEqual(e.tag, .incompatible)
        }
    }
}

extension CrossPlatformPool {
    public func setResumeWindowMillis(_ millis: Int64) {
        self.resumeWindowMillis = millis
    }
}
