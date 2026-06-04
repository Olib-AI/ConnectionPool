// CrossPlatformPool.swift
// ConnectionPool / CrossPlatform
//
// Top-level transport lifecycle. Mirrors Kotlin `ConnectionPool.kt`. Owns:
//
//   - server-side (host): per-connection handshake, rate limiting per remote
//     IP, resume-state bookkeeping;
//   - client-side (guest): connection initiation, tap-code derivation, resume
//     re-handshake.
//
// The pool is *transport-agnostic* — it accepts and produces `RawConnection`s
// rather than `NWConnection`. Real callers wrap a connected `NWConnection`
// via the `SocketConnection` adapter; tests use `InMemoryConnection.pair()`.

import CryptoKit
import Foundation

public actor CrossPlatformPool {

    public let config: CrossPlatformConfig

    // Test seams — public so adversarial tests can shrink windows.
    public var handshakeTimeoutMillis: Int = 30_000
    public var helloAttemptWindowMillis: Int64 = 60_000
    public var helloAttemptCap: Int = 10
    public var rateLimitedHoldMillis: Int64 = 30_000
    public var resumeWindowMillis: Int64 = 30_000

    private let random: () -> Data
    private let clock: @Sendable () -> Date

    // Host-side state.
    private var helloHistory: [String: [Int64]] = [:]
    private var rateLimitedUntil: [String: Int64] = [:]
    private var resumeBuffers: [String: ResumeState] = [:]
    private var blockedDevices: Set<String> = []
    private var activeSessionCount: Int = 0

    // Guest-side state.
    private var guestResumeStates: [String: GuestResumeState] = [:]

    private struct ResumeState {
        let sessionIdRaw: Data
        let outboundBuffer: [CrossPlatformSession.BufferedFrame]
        let nextOutboundSeq: UInt32
        let lastInboundSeq: UInt32?
        let disconnectedAtMillis: Int64
    }

    private struct GuestResumeState {
        let sessionIdB64u: String
        let nextOutboundSeq: UInt32
        let lastInboundSeq: UInt32?
        let disconnectedAtMillis: Int64
    }

    public struct GuestResumeSnapshot: Sendable, Equatable {
        public let sessionIdB64u: String
        public let nextOutboundSeq: UInt32
        public let lastInboundSeq: UInt32?
        public let disconnectedAtMillis: Int64
    }

    public init(
        config: CrossPlatformConfig,
        random: @escaping () -> Data = { CrossPlatformPool.defaultRandom() },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.random = random
        self.clock = clock
    }

    public static func defaultRandom(count: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    // MARK: - Tap code + session_id minting

    /// Pre-mint a 6-character decimal tap-code (CSPRNG-uniform 000000..999999).
    public func generateTapCode() -> String {
        let bytes = random()
        let n = UInt32(bytes[0]) << 24
              | UInt32(bytes[1]) << 16
              | UInt32(bytes[2]) << 8
              | UInt32(bytes[3])
        return String(format: "%06d", Int(n) % 1_000_000)
    }

    private func mintSessionId() -> Data { random() }
    private func mintNonce() -> Data { random() }

    // MARK: - Block list

    public func block(_ remoteKey: String) { blockedDevices.insert(remoteKey) }
    public func unblock(_ remoteKey: String) { blockedDevices.remove(remoteKey) }

    // MARK: - Host (acceptGuest)

    /// Drive the host side of the handshake to completion on an
    /// already-connected `raw` connection. Returns a `CrossPlatformSession`
    /// on success or throws `CrossPlatformTransportException` mapped to the on-wire `err`.
    ///
    /// `remoteKey` defaults to `raw.remoteDescription` — the rate-limit key.
    /// Per ADR-0005 §2.4 it MUST be source-IP only (port excluded). The
    /// `SocketConnection` adapter constructs `remoteDescription` IP-only;
    /// `InMemoryConnection` uses a synthetic label.
    public func acceptGuest(
        raw: any RawConnection,
        tapCode: String,
        remoteKey: String? = nil
    ) async throws -> CrossPlatformSession {
        let key = remoteKey ?? raw.remoteDescription

        // Rate limit BEFORE reading any bytes from the peer.
        do {
            try rateLimitCheck(key)
        } catch let e as CrossPlatformTransportException {
            _ = try? await sendFailure(raw, err: e.tag)
            await raw.close()
            throw e
        }

        // Spec §5.1 rule 6 (pre-byte-read): refuse new accepts at capacity.
        if activeSessionCount >= config.maxPeers - 1 {
            _ = try? await sendFailure(raw, err: .full)
            await raw.close()
            throw CrossPlatformTransportException(.full, "pool at capacity")
        }

        // Read the handshake frame with a 30 s budget per spec §6.
        let helloFrame: CrossPlatformFrameCodec.IncomingFrame
        do {
            helloFrame = try await readHandshakeFrameWithTimeout(raw)
        } catch let e as CrossPlatformTransportException where e.tag == .incompatible {
            // Pre-handshake non-HANDSHAKE frame — close wire without sending
            // server_hello (we don't have a parsed client_hello to derive
            // anything; the wire-level signal is just disconnect).
            await raw.close()
            throw e
        } catch {
            await raw.close()
            throw error
        }

        let hello: ClientHello
        do {
            hello = try decodeClientHello(from: helloFrame)
        } catch let e as CrossPlatformTransportException {
            _ = try? await sendFailure(raw, err: .incompatible)
            await raw.close()
            throw e
        }

        recordHelloAttempt(key)

        // 1. v != 1
        if hello.version != CrossPlatformHandshake.protocolVersion {
            _ = try? await sendFailure(raw, err: .incompatible)
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "unsupported v=\(hello.version)")
        }
        // 2. cap must contain chess.1
        let capList = hello.cap.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !capList.contains(CrossPlatformHandshake.capChess1) {
            _ = try? await sendFailure(raw, err: .incompatible)
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "cap missing chess.1: \(hello.cap)")
        }
        // 5. block list
        if blockedDevices.contains(key) {
            _ = try? await sendFailure(raw, err: .blocked)
            await raw.close()
            throw CrossPlatformTransportException(.blocked, key)
        }
        // 7. code_hash
        let expectedCodeHash = sha256First16(Data(tapCode.utf8))
        if expectedCodeHash != hello.codeHash {
            _ = try? await sendFailure(raw, err: .badCode)
            await raw.close()
            throw CrossPlatformTransportException(.badCode)
        }
        // 8. resume validation
        var resumeAccepted: ResumeState? = nil
        if let r = hello.resume {
            let state = resumeBuffers[r.sessionId]
            let now = currentMillis()
            let withinWindow = state.map { (now - $0.disconnectedAtMillis) <= resumeWindowMillis } ?? false
            if state == nil || !withinWindow {
                _ = try? await sendFailure(raw, err: .badCode)
                await raw.close()
                throw CrossPlatformTransportException(.badCode, "unknown/expired resume session")
            }
            resumeAccepted = state
        }
        let resumeAckedSeq: UInt32? = hello.resume?.ackedSeq

        // Mint or reuse session_id.
        let sessionIdRaw = resumeAccepted?.sessionIdRaw ?? mintSessionId()
        let nonceH = mintNonce()
        let keys = CrossPlatformSessionKeys.derive(tapCode: tapCode, nonceC: hello.nonceC, nonceH: nonceH)
        let serverHello = ServerHello.ok(ServerHello.Ok(
            pid: config.localPID,
            name: config.localDisplayName,
            nonceH: nonceH,
            sessionId: sessionIdRaw,
            hostColor: CrossPlatformHandshake.defaultHostColor,
            startingFEN: CrossPlatformHandshake.standardStartingFEN
        ))
        do {
            try await writePlaintextHandshake(raw, plaintext: serverHello.encodeCanonical())
        } catch let e as CrossPlatformTransportException {
            await raw.close()
            throw e
        }

        // ADR-0004 §2.4: a successful resume consumes the prior session_id.
        // Drop the resume entry from the map IMMEDIATELY after emitting
        // server_hello{ok:true} and BEFORE the replay burst.
        if let r = hello.resume, resumeAccepted != nil {
            resumeBuffers.removeValue(forKey: r.sessionId)
        }

        let sessionIdB64u = CrossPlatformBase64.encode16(sessionIdRaw)
        let seedOutboundSeq: UInt32 = resumeAccepted?.nextOutboundSeq ?? 0
        let seedLastInboundSeq: UInt32? = resumeAccepted?.lastInboundSeq

        let session = CrossPlatformSession(
            role: .host,
            peer: CrossPlatformPeerInfo(
                pid: hello.pid,
                displayName: hello.name,
                senderID: "guest-" + CrossPlatformBase64.encode16(hello.pid)
            ),
            sessionIdRaw: sessionIdRaw,
            sessionIdB64u: sessionIdB64u,
            hostColor: CrossPlatformHandshake.defaultHostColor,
            startingFEN: CrossPlatformHandshake.standardStartingFEN,
            raw: raw,
            sendKey: keys.s2c,
            recvKey: keys.c2s,
            localSenderID: "host-" + CrossPlatformBase64.encode16(config.localPID),
            localDisplayName: config.localDisplayName,
            clock: clock,
            seedOutboundSeq: seedOutboundSeq,
            seedLastInboundSeq: seedLastInboundSeq
        )

        // ADR-0003 §2.2: re-encrypt and replay unacked plaintexts under the
        // new K_s2c', filtered by the guest's `resume.acked_seq`.
        if let r = resumeAccepted {
            let toReplay: [CrossPlatformSession.BufferedFrame]
            if let acked = resumeAckedSeq {
                toReplay = r.outboundBuffer.filter { $0.seq > acked }
            } else {
                toReplay = r.outboundBuffer
            }
            let highestKnownSeq = r.outboundBuffer.map { $0.seq }.max()
            try await session.replayBuffered(entries: toReplay, highestKnownSeq: highestKnownSeq)
        }

        activeSessionCount += 1
        attachAutoReleaseListener(session: session)
        await session.startReader()
        return session
    }

    // MARK: - Guest (connectAsGuest)

    public func connectAsGuest(
        raw: any RawConnection,
        tapCode: String,
        resume: CrossPlatformClientHelloResume? = nil,
        onPostHandshake: ((CrossPlatformSession) async -> Void)? = nil
    ) async throws -> CrossPlatformSession {
        let nonceC = mintNonce()
        let codeHash = sha256First16(Data(tapCode.utf8))
        let hello = ClientHello(
            pid: config.localPID,
            name: config.localDisplayName,
            nonceC: nonceC,
            codeHash: codeHash,
            resume: resume
        )
        do {
            try await writePlaintextHandshake(raw, plaintext: hello.encodeCanonical())
        } catch let e as CrossPlatformTransportException where e.tag != .handshakeTimeout {
            await raw.close()
            throw e
        } catch {
            // Half-closed pipe — fall through to read so the typed
            // server_hello{ok:false,err:…} is still surfaced.
        }

        let reply: CrossPlatformFrameCodec.IncomingFrame
        do {
            reply = try await readHandshakeFrameWithTimeout(raw)
        } catch let e as CrossPlatformTransportException {
            await raw.close()
            throw e
        }

        let message: CrossPlatformHandshakeMessage
        do {
            let plaintext = reply.body.dropFirst() // drop the type tag
            message = try CrossPlatformHandshake.decode(Data(plaintext))
        } catch {
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "bad handshake JSON: \(error)")
        }

        if let serverHello = message as? ServerHello {
            switch serverHello {
            case .ok(let okPayload):
                return try await finishGuestHandshake(
                    raw: raw,
                    tapCode: tapCode,
                    nonceC: nonceC,
                    resume: resume,
                    okPayload: okPayload,
                    onPostHandshake: onPostHandshake
                )
            case .failure(let failurePayload):
                await raw.close()
                let tag = CrossPlatformTransportError.fromWireOrIncompatible(failurePayload.err) { unknown in
                    print("[ConnectionPool] connectAsGuest: unknown server_hello.err='\(unknown)' (treating as INCOMPATIBLE per ADR-0004 §2.6)")
                }
                let messageOut = CrossPlatformTransportError.fromWire(failurePayload.err) != nil
                    ? failurePayload.err
                    : "unknown server_hello.err: \(failurePayload.err)"
                throw CrossPlatformTransportException(tag, messageOut)
            }
        } else if message is ClientHello {
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "got client_hello as guest")
        } else {
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "unexpected handshake message")
        }
    }

    private func finishGuestHandshake(
        raw: any RawConnection,
        tapCode: String,
        nonceC: Data,
        resume: CrossPlatformClientHelloResume?,
        okPayload: ServerHello.Ok,
        onPostHandshake: ((CrossPlatformSession) async -> Void)?
    ) async throws -> CrossPlatformSession {
        let keys = CrossPlatformSessionKeys.derive(tapCode: tapCode, nonceC: nonceC, nonceH: okPayload.nonceH)
        let sessionIdB64u = CrossPlatformBase64.encode16(okPayload.sessionId)

        // Defensive: on resume, the host MUST echo the announced session_id.
        if let r = resume, r.sessionId != sessionIdB64u {
            await raw.close()
            throw CrossPlatformTransportException(.incompatible, "host echoed different session_id on resume")
        }

        // ADR-0006 §3.1: on resume, seed seq state from the stash.
        var guestStash: GuestResumeState? = nil
        if let r = resume, let candidate = guestResumeStates[r.sessionId] {
            if currentMillis() - candidate.disconnectedAtMillis > resumeWindowMillis {
                guestResumeStates.removeValue(forKey: r.sessionId)
            } else {
                guestStash = candidate
            }
        }
        let seedOutboundSeq: UInt32 = guestStash?.nextOutboundSeq ?? 0
        // ADR-0006 §3.1 resolution: the resumed guest's lastInboundSeq MUST
        // be seeded from the announced `acked_seq`, NOT from the guest's
        // local snapshot, so the host's replay-buffer filter
        // (`seq > acked_seq`) aligns with the guest's `SEQ_REPLAY` check.
        // Source-of-truth: Kotlin `ConnectionPool.kt` L480-497.
        let seedLastInboundSeq: UInt32? = resume?.ackedSeq

        let session = CrossPlatformSession(
            role: .guest,
            peer: CrossPlatformPeerInfo(
                pid: okPayload.pid,
                displayName: okPayload.name,
                senderID: "host-" + CrossPlatformBase64.encode16(okPayload.pid)
            ),
            sessionIdRaw: okPayload.sessionId,
            sessionIdB64u: sessionIdB64u,
            hostColor: okPayload.hostColor,
            startingFEN: okPayload.startingFEN,
            raw: raw,
            sendKey: keys.c2s,
            recvKey: keys.s2c,
            localSenderID: "guest-" + CrossPlatformBase64.encode16(config.localPID),
            localDisplayName: config.localDisplayName,
            clock: clock,
            seedOutboundSeq: seedOutboundSeq,
            seedLastInboundSeq: seedLastInboundSeq
        )

        if guestStash != nil, let r = resume {
            guestResumeStates.removeValue(forKey: r.sessionId)
        }
        attachGuestResumeStashListener(session: session, sessionIdB64u: sessionIdB64u)

        await onPostHandshake?(session)
        await session.startReader()
        return session
    }

    // MARK: - Resume-state callbacks

    /// Record a host-side session disconnect so a re-handshake within the
    /// resume window can replay unacked plaintexts. The state captures
    /// per-side seq snapshots so the resumed session preserves the seq
    /// space across the boundary (ADR-0006 §3.2).
    public func rememberDisconnect(
        sessionIdB64u: String,
        sessionIdRaw: Data,
        outboundBuffer: [CrossPlatformSession.BufferedFrame],
        nextOutboundSeq: UInt32,
        lastInboundSeq: UInt32?
    ) {
        resumeBuffers[sessionIdB64u] = ResumeState(
            sessionIdRaw: sessionIdRaw,
            outboundBuffer: outboundBuffer,
            nextOutboundSeq: nextOutboundSeq,
            lastInboundSeq: lastInboundSeq,
            disconnectedAtMillis: currentMillis()
        )
    }

    public func forgetResume(sessionId: String) {
        resumeBuffers.removeValue(forKey: sessionId)
    }

    /// Test seam: peek the guest-side resume-state stash. Applies the GC
    /// window on access so a stale entry returns `nil`.
    public func peekGuestResumeState(sessionIdB64u: String) -> GuestResumeSnapshot? {
        guard let state = guestResumeStates[sessionIdB64u] else { return nil }
        if currentMillis() - state.disconnectedAtMillis > resumeWindowMillis {
            guestResumeStates.removeValue(forKey: sessionIdB64u)
            return nil
        }
        return GuestResumeSnapshot(
            sessionIdB64u: state.sessionIdB64u,
            nextOutboundSeq: state.nextOutboundSeq,
            lastInboundSeq: state.lastInboundSeq,
            disconnectedAtMillis: state.disconnectedAtMillis
        )
    }

    /// Decrement the active-session counter. Idempotent per call site — the
    /// pool's auto-release listener fires exactly once per session lifetime.
    public func releaseSession(_ session: CrossPlatformSession) {
        activeSessionCount = max(0, activeSessionCount - 1)
    }

    /// Test seam.
    public func activeSessionCountSnapshot() -> Int { activeSessionCount }

    // MARK: - Internals

    private func currentMillis() -> Int64 {
        Int64(clock().timeIntervalSince1970 * 1000.0)
    }

    private func sha256First16(_ input: Data) -> Data {
        let digest = SHA256.hash(data: input)
        return Data(digest.prefix(16))
    }

    private func rateLimitCheck(_ key: String) throws {
        let now = currentMillis()
        if let cooledOff = rateLimitedUntil[key], cooledOff > now {
            throw CrossPlatformTransportException(.rateLimited, "in cool-off for \(cooledOff - now) ms")
        }
        var history = helloHistory[key] ?? []
        while let first = history.first, now - first > helloAttemptWindowMillis {
            history.removeFirst()
        }
        if history.count >= helloAttemptCap {
            rateLimitedUntil[key] = now + rateLimitedHoldMillis
            helloHistory[key] = history
            throw CrossPlatformTransportException(.rateLimited, "\(history.count) attempts in window")
        }
        helloHistory[key] = history
    }

    private func recordHelloAttempt(_ key: String) {
        var history = helloHistory[key] ?? []
        history.append(currentMillis())
        helloHistory[key] = history
    }

    private func readHandshakeFrameWithTimeout(_ raw: any RawConnection) async throws -> CrossPlatformFrameCodec.IncomingFrame {
        let timeoutMs = handshakeTimeoutMillis
        return try await withThrowingTaskGroup(of: CrossPlatformFrameCodec.IncomingFrame.self) { group in
            group.addTask {
                let frame = try await CrossPlatformFrameCodec.readFrame { n in
                    try await raw.readExact(n)
                }
                guard let frame else {
                    throw CrossPlatformTransportException(.handshakeTimeout, "peer closed before hello")
                }
                if frame.type != .handshake {
                    let tagHex = String(format: "0x%02x", frame.type.rawValue)
                    throw CrossPlatformTransportException(.incompatible, "non-HANDSHAKE frame received pre-handshake: type=\(tagHex)")
                }
                return frame
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                throw CrossPlatformTransportException(.handshakeTimeout)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func decodeClientHello(from frame: CrossPlatformFrameCodec.IncomingFrame) throws -> ClientHello {
        let plaintext = frame.body.dropFirst()
        let message: CrossPlatformHandshakeMessage
        do {
            message = try CrossPlatformHandshake.decode(Data(plaintext))
        } catch let e as CrossPlatformTransportException {
            throw e
        } catch {
            throw CrossPlatformTransportException(.incompatible, "bad handshake JSON: \(error)")
        }
        guard let hello = message as? ClientHello else {
            throw CrossPlatformTransportException(.incompatible, "expected client_hello, got server_hello")
        }
        return hello
    }

    private func writePlaintextHandshake(_ raw: any RawConnection, plaintext: Data) async throws {
        let body = CrossPlatformFrameCodec.handshakeBody(plaintextJson: plaintext)
        do {
            try await raw.write(CrossPlatformFrameCodec.frameOf(body: body))
        } catch {
            throw CrossPlatformTransportException(.handshakeTimeout, "socket write failed: \(error)")
        }
    }

    private func sendFailure(_ raw: any RawConnection, err: CrossPlatformTransportError) async throws {
        let failure = ServerHello.failure(ServerHello.Failure(err: err.rawValue))
        try await writePlaintextHandshake(raw, plaintext: failure.encodeCanonical())
    }

    private func attachAutoReleaseListener(session: CrossPlatformSession) {
        Task { [weak self] in
            for await event in session.events {
                if case .disconnected = event {
                    await self?.releaseSession(session)
                    return
                }
            }
        }
    }

    private func attachGuestResumeStashListener(session: CrossPlatformSession, sessionIdB64u: String) {
        Task { [weak self] in
            for await event in session.events {
                if case .disconnected = event {
                    guard let self else { return }
                    let lastOutbound = await session.outboundSeqSnapshot()
                    let lastInbound = await session.inboundSeqSnapshot()
                    await self.stashGuestResume(
                        sessionIdB64u: sessionIdB64u,
                        nextOutboundSeq: lastOutbound,
                        lastInboundSeq: lastInbound
                    )
                    return
                }
            }
        }
    }

    private func stashGuestResume(sessionIdB64u: String, nextOutboundSeq: UInt32, lastInboundSeq: UInt32?) {
        guestResumeStates[sessionIdB64u] = GuestResumeState(
            sessionIdB64u: sessionIdB64u,
            nextOutboundSeq: nextOutboundSeq,
            lastInboundSeq: lastInboundSeq,
            disconnectedAtMillis: currentMillis()
        )
    }
}
