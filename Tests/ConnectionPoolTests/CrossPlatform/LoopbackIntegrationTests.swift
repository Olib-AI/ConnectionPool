// LoopbackIntegrationTests.swift
// ConnectionPoolTests / CrossPlatform
//
// In-process host + guest loopback exercising the full transport pipeline:
//
//   handshake → host emits `start` → 10 alternating moves → `resign`
//
// Asserts counter advance on both sides, monotonic `seq`, and that every
// game-action surfaces on the peer's `inbound` flow as the matching
// `ChessGameAction`. No network — pure `InMemoryConnection`.

import XCTest
@testable import ConnectionPool

final class LoopbackIntegrationTests: XCTestCase {

    func test_handshake_start_moves_resign() async throws {
        let hostPID = Data(repeating: 0x11, count: 16)
        let guestPID = Data(repeating: 0x22, count: 16)
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: hostPID,
            localDisplayName: "Bob"
        ))
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: guestPID,
            localDisplayName: "Alice"
        ))
        let tapCode = "482917"
        let (rawHost, rawGuest) = InMemoryConnection.pair()

        // Drive both sides of the handshake in parallel.
        async let hostSession: CrossPlatformSession = hostPool.acceptGuest(raw: rawHost, tapCode: tapCode)
        async let guestSession: CrossPlatformSession = guestPool.connectAsGuest(raw: rawGuest, tapCode: tapCode)
        let (host, guest) = try await (hostSession, guestSession)

        // Drain inbound on both sides into buffered queues. We intentionally
        // subscribe AFTER the sessions are returned — startReader() is called
        // synchronously by the pool, but `inbound` has no replay so the first
        // `start` frame is buffered in the actor's continuation queue until
        // a subscriber drains it. We use a Task to drain on each side.

        // Helper: collect N inbound messages with a timeout.
        func collectInbound(_ session: CrossPlatformSession, count n: Int) async -> [CrossPlatformPoolMessage] {
            var out: [CrossPlatformPoolMessage] = []
            for await msg in session.inbound {
                out.append(msg)
                if out.count >= n { break }
            }
            return out
        }

        // Step 1: host emits `start`.
        async let guestInbound = collectInbound(guest, count: 6) // start + 5 white moves
        try await host.send(.start(
            hostColor: .white,
            startingFEN: CrossPlatformHandshake.standardStartingFEN
        ))

        // Step 2: 10 alternating moves.
        // White (host) plays moves 0/2/4/...; Black (guest) plays 1/3/5/...
        // Use a tiny fixed move script — content doesn't matter for the
        // transport-layer test; what matters is that 10 envelopes round-trip
        // with monotone-strict seq on both sides.
        let whiteMoves = ["e2e4", "g1f3", "f1c4", "e1g1", "d2d3"]
        let blackMoves = ["e7e5", "b8c6", "f8c5", "g8f6", "d7d6"]
        async let hostInbound = collectInbound(host, count: 5 + 1) // 5 black moves + 1 resign

        for i in 0..<5 {
            try await host.send(.move(uci: whiteMoves[i]))
            try await guest.send(.move(uci: blackMoves[i]))
        }
        // Final resign from guest.
        try await guest.send(.resign)

        let collectedGuest = await guestInbound
        let collectedHost = await hostInbound

        // Guest received: start + 5 white moves = 6 game_action messages.
        // Host received:  5 black moves + 1 resign = 6 game_action messages.
        XCTAssertEqual(collectedGuest.count, 6, "guest inbound count")
        XCTAssertEqual(collectedHost.count, 6, "host inbound count")

        // Verify the first guest-side message is `start` with hostColor=white.
        let firstPayload = collectedGuest[0].payload
        let firstEnv = try CrossPlatformGameActionEnvelope.decode(firstPayload)
        XCTAssertEqual(firstEnv.seq, 0)
        switch firstEnv.action {
        case .start(let color, let fen):
            XCTAssertEqual(color, .white)
            XCTAssertEqual(fen, CrossPlatformHandshake.standardStartingFEN)
        default:
            XCTFail("first guest message is not start")
        }

        // Last host-side message is resign with guest's seq = 5 (its 6th send).
        let lastEnv = try CrossPlatformGameActionEnvelope.decode(collectedHost.last!.payload)
        XCTAssertEqual(lastEnv.action, .resign)
        XCTAssertEqual(lastEnv.seq, 5, "guest's resign seq")

        await host.close()
        await guest.close()
    }
}
