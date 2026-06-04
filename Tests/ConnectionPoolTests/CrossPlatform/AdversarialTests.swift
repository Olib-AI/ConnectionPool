// AdversarialTests.swift
// ConnectionPoolTests / CrossPlatform
//
// Adversarial coverage of every spec §9 error tag that's testable without
// the OS network stack.

import XCTest
import CryptoKit
@testable import ConnectionPool

/// Actor-wrapped byte cursor for adversarial framing tests. Provides the
/// `@Sendable (Int) async throws -> Data?` closure shape `FrameCodec.readFrame`
/// expects without leaking mutable state across concurrency boundaries.
actor ByteCursor {
    private var bytes: Data
    private var pos: Int = 0
    init(bytes: Data) { self.bytes = bytes }
    func take(_ n: Int) -> Data? {
        let end = pos + n
        if end > bytes.count { return nil }
        let slice = bytes.subdata(in: pos..<end)
        pos = end
        return slice
    }
}

extension CrossPlatformPool {
    /// Async setter for the actor-isolated `handshakeTimeoutMillis`.
    public func setHandshakeTimeoutMillis(_ millis: Int) {
        self.handshakeTimeoutMillis = millis
    }
}


fileprivate func adv_expectHostThrows(
    _ pool: CrossPlatformPool,
    raw: any RawConnection,
    tapCode: String,
    expected: CrossPlatformTransportError,
    remoteKey: String? = nil
) async {
    do {
        _ = try await pool.acceptGuest(raw: raw, tapCode: tapCode, remoteKey: remoteKey)
        XCTFail("host expected to throw \(expected)")
    } catch let e as CrossPlatformTransportException {
        XCTAssertEqual(e.tag, expected, "host error tag")
    } catch {
        XCTFail("host: unexpected non-Transport error \(error)")
    }
}

fileprivate func adv_expectGuestThrows(
    _ pool: CrossPlatformPool,
    raw: any RawConnection,
    tapCode: String,
    expected: CrossPlatformTransportError
) async {
    do {
        _ = try await pool.connectAsGuest(raw: raw, tapCode: tapCode)
        XCTFail("guest expected to throw \(expected)")
    } catch let e as CrossPlatformTransportException {
        XCTAssertEqual(e.tag, expected, "guest error tag")
    } catch {
        XCTFail("guest: unexpected non-Transport error \(error)")
    }
}

final class AdversarialTests: XCTestCase {

    private func makePools() -> (CrossPlatformPool, CrossPlatformPool) {
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        return (hostPool, guestPool)
    }


    // MARK: - BAD_CODE

    func test_wrongTapCode_yields_BAD_CODE() async {
        let (hostPool, guestPool) = makePools()
        let (rawHost, rawGuest) = InMemoryConnection.pair()
        async let hostT: () = adv_expectHostThrows(hostPool, raw: rawHost, tapCode: "111111", expected: .badCode)
        async let guestT: () = adv_expectGuestThrows(guestPool, raw: rawGuest, tapCode: "222222", expected: .badCode)
        await hostT
        await guestT
    }

    // MARK: - AUTH_FAIL (tampered ciphertext)

    func test_tamperedCiphertext_yields_AUTH_FAIL() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let plaintext = Data("hello".utf8)
        var body = try CrossPlatformFrameCodec.encryptedBody(
            type: .encryptedPoolMessage,
            key: key,
            counter: 0,
            plaintext: plaintext
        )
        // Flip a bit in the ciphertext to invalidate Poly1305.
        let flipIndex = 9 + 2 // skip type+counter, then poke ciphertext byte 2
        body[flipIndex] ^= 0x01
        let tracker = CounterTracker()
        XCTAssertThrowsError(try CrossPlatformFrameCodec.decryptBody(body: body, key: key, tracker: tracker)) { error in
            guard let e = error as? CrossPlatformTransportException else {
                XCTFail("expected TransportException, got \(error)"); return
            }
            XCTAssertEqual(e.tag, .authFail)
        }
    }

    // MARK: - SEQ_REPLAY (counter replay)

    func test_replayCounter_yields_SEQ_REPLAY() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let body0 = try CrossPlatformFrameCodec.encryptedBody(
            type: .encryptedPoolMessage,
            key: key,
            counter: 0,
            plaintext: Data("hello".utf8)
        )
        let body1 = try CrossPlatformFrameCodec.encryptedBody(
            type: .encryptedPoolMessage,
            key: key,
            counter: 1,
            plaintext: Data("world".utf8)
        )
        let tracker = CounterTracker()
        _ = try CrossPlatformFrameCodec.decryptBody(body: body0, key: key, tracker: tracker)
        _ = try CrossPlatformFrameCodec.decryptBody(body: body1, key: key, tracker: tracker)
        XCTAssertThrowsError(try CrossPlatformFrameCodec.decryptBody(body: body0, key: key, tracker: tracker)) { error in
            guard let e = error as? CrossPlatformTransportException else {
                XCTFail("expected TransportException, got \(error)"); return
            }
            XCTAssertEqual(e.tag, .seqReplay)
        }
    }

    // MARK: - FRAME_TOO_LARGE / EMPTY_FRAME / UNKNOWN_FRAME_TYPE (framing)

    func test_frameTooLarge_yields_FRAME_TOO_LARGE() async {
        var bytes = Data()
        let length: UInt32 = UInt32(CrossPlatformFrameCodec.maxBodyBytes + 1)
        CrossPlatformFrameCodec.writeU32Be(into: &bytes, value: length)
        let cursor = ByteCursor(bytes: bytes)
        let reader: @Sendable (Int) async throws -> Data? = { n in await cursor.take(n) }
        do {
            _ = try await CrossPlatformFrameCodec.readFrame(readExact: reader)
            XCTFail("expected FRAME_TOO_LARGE")
        } catch let e as CrossPlatformTransportException {
            XCTAssertEqual(e.tag, .frameTooLarge)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_emptyFrame_yields_EMPTY_FRAME() async {
        var bytes = Data()
        CrossPlatformFrameCodec.writeU32Be(into: &bytes, value: 0)
        let cursor = ByteCursor(bytes: bytes)
        let reader: @Sendable (Int) async throws -> Data? = { n in await cursor.take(n) }
        do {
            _ = try await CrossPlatformFrameCodec.readFrame(readExact: reader)
            XCTFail("expected EMPTY_FRAME")
        } catch let e as CrossPlatformTransportException {
            XCTAssertEqual(e.tag, .emptyFrame)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_unknownFrameType_yields_UNKNOWN_FRAME_TYPE() async {
        var bytes = Data()
        // length=1, body=[0xFF]
        CrossPlatformFrameCodec.writeU32Be(into: &bytes, value: 1)
        bytes.append(0xFF)
        let cursor = ByteCursor(bytes: bytes)
        let reader: @Sendable (Int) async throws -> Data? = { n in await cursor.take(n) }
        do {
            _ = try await CrossPlatformFrameCodec.readFrame(readExact: reader)
            XCTFail("expected UNKNOWN_FRAME_TYPE")
        } catch let e as CrossPlatformTransportException {
            XCTAssertEqual(e.tag, .unknownFrameType)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - INCOMPATIBLE (pre-handshake non-HANDSHAKE frame)

    func test_preHandshakeNonHandshakeFrame_yields_INCOMPATIBLE() async throws {
        let (hostPool, _) = makePools()
        let (rawHost, rawGuest) = InMemoryConnection.pair()

        // Craft an ENCRYPTED_POOL_MESSAGE (0x01) as the FIRST frame the host
        // sees, with bogus body — the host's pre-handshake fence MUST close
        // with INCOMPATIBLE before doing anything AEAD.
        var body = Data()
        body.append(CrossPlatformFrameType.encryptedPoolMessage.rawValue)
        body.append(Data(repeating: 0, count: 8 + 16))
        let frame = CrossPlatformFrameCodec.frameOf(body: body)
        async let hostThrow: () = adv_expectHostThrows(hostPool, raw: rawHost, tapCode: "111111", expected: .incompatible)
        try await rawGuest.write(frame)
        await hostThrow
    }

    // MARK: - HANDSHAKE_TIMEOUT (peer never sends bytes)

    func test_stalledHandshake_yields_HANDSHAKE_TIMEOUT() async throws {
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        await hostPool.setHandshakeTimeoutMillis(200)
        let (rawHost, _) = InMemoryConnection.pair()
        do {
            _ = try await hostPool.acceptGuest(raw: rawHost, tapCode: "111111")
            XCTFail("expected HANDSHAKE_TIMEOUT")
        } catch let e as CrossPlatformTransportException {
            XCTAssertEqual(e.tag, .handshakeTimeout)
        }
    }

    // MARK: - RATE_LIMITED (11th attempt from same IP within 60 s)

    func test_rateLimit_eleventhAttempt_yields_RATE_LIMITED() async throws {
        let hostPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x11, count: 16),
            localDisplayName: "Bob"
        ))
        let remoteKey = "1.2.3.4"
        // 10 successful BAD_CODE rounds increment the rate-limit counter.
        for _ in 0..<10 {
            let (rawHost, rawGuest) = InMemoryConnection.pair()
            let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
                localPID: Data(repeating: 0x22, count: 16),
                localDisplayName: "Alice"
            ))
            async let hostInner: () = adv_expectHostThrows(
                hostPool, raw: rawHost, tapCode: "111111", expected: .badCode, remoteKey: remoteKey
            )
            async let guestInner: () = adv_expectGuestThrows(
                guestPool, raw: rawGuest, tapCode: "222222", expected: .badCode
            )
            await hostInner
            await guestInner
        }
        // 11th — should hit the cap.
        let (rawHost, rawGuest) = InMemoryConnection.pair()
        let guestPool = CrossPlatformPool(config: CrossPlatformConfig(
            localPID: Data(repeating: 0x22, count: 16),
            localDisplayName: "Alice"
        ))
        async let hostT: () = adv_expectHostThrows(
            hostPool, raw: rawHost, tapCode: "111111", expected: .rateLimited, remoteKey: remoteKey
        )
        async let guestT: () = adv_expectGuestThrows(
            guestPool, raw: rawGuest, tapCode: "222222", expected: .rateLimited
        )
        await hostT
        await guestT
    }
}
