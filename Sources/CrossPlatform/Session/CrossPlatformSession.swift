// CrossPlatformSession.swift
// ConnectionPool / CrossPlatform
//
// One peer-to-peer connected session (host or guest role). Owns the
// post-handshake encrypted exchange of `CrossPlatformPoolMessage`s. Mirrors
// Kotlin `PeerSession.kt`.
//
// Lifecycle:
//   1. `connectAsGuest` / `acceptGuest` on `CrossPlatformPool` drives the
//      handshake to completion, then constructs the session.
//   2. The pool calls `startReader()` once any caller-attached subscribers
//      are listening — `events` and `inbound` are async streams with no
//      "replay" semantics; subscribing after the reader emits silently
//      loses early frames (e.g. the post-resume replay burst). This
//      eliminates the race noted in ADR-0004 lap-2 test gap #1.
//   3. Caller invokes `send(_:)` for each outbound action; `bye(reason:)`
//      / `close()` tear down cleanly.
//
// Outbound replay buffer (ADR-0003 §2.2): keeps the last N=256 plaintext
// payloads alongside their `seq` and `frameType` so a host-side resume can
// re-encrypt and replay them under the new directional keys. Storing
// encrypted bodies would be wrong — `K_s2c` rotates on resume and the
// buffered counters reset to 0. Guests track no plaintext buffer (M0
// asymmetry): the guest never replays.

import Foundation

public actor CrossPlatformSession {

    public enum Role: Sendable { case host, guest }

    public let role: Role
    public let peer: CrossPlatformPeerInfo
    public let sessionIdRaw: Data
    public let sessionIdB64u: String
    public let hostColor: String
    public let startingFEN: String

    /// Outbound-buffer entry. Stored as plaintext alongside the original
    /// `seq` (the value embedded in the `GameActionEnvelope`). On resume the
    /// host re-encrypts each entry under the new `K_s2c'`, preserving `seq`.
    public struct BufferedFrame: Sendable {
        public let seq: UInt32
        public let frameType: CrossPlatformFrameType
        public let plaintext: Data
    }

    /// Spec §3.7 cap.
    public static let outboundBufferCap: Int = 256

    /// Spec §5.4 + ADR-0005 §2.5 cap on the BYE plaintext reason.
    public static let byeReasonMaxBytes: Int = 256

    private let raw: any RawConnection
    private let sendKey: Data
    private let recvKey: Data
    private let localSenderID: String
    private let localDisplayName: String
    private let clock: @Sendable () -> Date

    private let sendCounter = CounterSource()
    private let recvCounter = CounterTracker()

    private var nextOutboundSeq: UInt32
    private var lastInboundSeq: UInt32?

    private var outboundBuffer: [BufferedFrame] = []

    private var closed = false
    private var readerTask: Task<Void, Never>? = nil

    private let eventsContinuation: AsyncStream<CrossPlatformPeerEvent>.Continuation
    public nonisolated let events: AsyncStream<CrossPlatformPeerEvent>

    private let inboundContinuation: AsyncStream<CrossPlatformPoolMessage>.Continuation
    public nonisolated let inbound: AsyncStream<CrossPlatformPoolMessage>

    /// Construct a fully-wired session. Called by `CrossPlatformPool` after the
    /// handshake completes. `seedOutboundSeq` / `seedLastInboundSeq` carry
    /// per-side seq state across a resume boundary (ADR-0006 §2 / §3).
    public init(
        role: Role,
        peer: CrossPlatformPeerInfo,
        sessionIdRaw: Data,
        sessionIdB64u: String,
        hostColor: String,
        startingFEN: String,
        raw: any RawConnection,
        sendKey: Data,
        recvKey: Data,
        localSenderID: String,
        localDisplayName: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        seedOutboundSeq: UInt32 = 0,
        seedLastInboundSeq: UInt32? = nil
    ) {
        self.role = role
        self.peer = peer
        self.sessionIdRaw = sessionIdRaw
        self.sessionIdB64u = sessionIdB64u
        self.hostColor = hostColor
        self.startingFEN = startingFEN
        self.raw = raw
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.localSenderID = localSenderID
        self.localDisplayName = localDisplayName
        self.clock = clock
        self.nextOutboundSeq = seedOutboundSeq
        self.lastInboundSeq = seedLastInboundSeq

        var ec: AsyncStream<CrossPlatformPeerEvent>.Continuation!
        self.events = AsyncStream { c in ec = c }
        self.eventsContinuation = ec
        var ic: AsyncStream<CrossPlatformPoolMessage>.Continuation!
        self.inbound = AsyncStream { c in ic = c }
        self.inboundContinuation = ic

        eventsContinuation.yield(.connected(peer))
    }

    /// Idempotent: a second call is a no-op so callers wiring up via the
    /// public API don't risk a double-launch. The pool calls this exactly
    /// once, AFTER its post-handshake hook returns so subscribers attached in
    /// the hook see every frame.
    public func startReader() {
        if readerTask != nil { return }
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runReader()
        }
    }

    // MARK: - Outbound API

    /// Send a chess game action. Throws `CrossPlatformTransportException(.closed)` if the
    /// session has already closed. The `seq` value embedded in the envelope
    /// is the value of `nextOutboundSeq` BEFORE advancing; the post-resume
    /// host-side replay path also threads this same value through
    /// `replayBuffered`.
    public func send(_ action: CrossPlatformChessGameAction) async throws {
        if closed { throw CrossPlatformTransportException(.closed, "session closed") }
        // Atomic seq claim. Swift actors are re-entrant across `await`, so
        // a "read seq → await → write seq" shape lets two concurrent senders
        // both observe `nextOutboundSeq=N` and emit duplicate-seq frames.
        // The receiver correctly rejects the duplicate as SEQ_REPLAY and
        // tears down the session (see iOS task #165: cross-platform Android
        // guest disconnecting on the iOS host's start+gameSettings burst).
        // Claiming the seq BEFORE the first suspension closes the race —
        // the read and write are now contiguous in the synchronous prelude.
        //
        // If `sendEncryptedLocked` throws below we've consumed a seq
        // number without putting a frame on the wire. Acceptable: every
        // throw path here is fatal to the session (buffer overflow →
        // `close(.incompatible)`, socket write failure → same) per
        // ADR-0006 §4, so a "gap in the seq sequence" is moot — there is
        // no surviving session to observe it.
        let seq = nextOutboundSeq
        nextOutboundSeq = seq &+ 1
        let envelope = CrossPlatformGameActionEnvelope(
            sessionId: sessionIdB64u,
            seq: seq,
            action: action
        )
        let payload = envelope.encodeCanonical()
        let pool = CrossPlatformPoolMessage(
            id: UUID(),
            type: .gameAction,
            senderID: localSenderID,
            senderName: localDisplayName,
            timestamp: clock(),
            payload: payload,
            isReliable: true
        )
        let plaintext = pool.encodeCanonical()
        try await sendEncryptedLocked(.encryptedPoolMessage, plaintext: plaintext, seq: seq)
    }

    /// Send a chat payload (UTF-8 bytes). Wraps the bytes in a
    /// `CrossPlatformPoolMessage{type=chat}` and frames it the same way
    /// as a game action, so the wire encoding stays uniform. The
    /// envelope is sent under the encrypted-pool-message frame type and
    /// advances `seq` so the receiver can detect replay on the chat
    /// channel as well.
    ///
    /// The caller passes raw payload bytes (no canonical-JSON wrapping)
    /// — the chess-up chat payload is just the UTF-8 text. If the
    /// payload exceeds the outbound replay-buffer plaintext cap the
    /// underlying `sendEncryptedLocked` will surface that as an
    /// `INCOMPATIBLE` exception, same as a too-large game-action would.
    public func sendChat(payload: Data) async throws {
        if closed { throw CrossPlatformTransportException(.closed, "session closed") }
        // Atomic seq claim — same actor-re-entrancy reasoning as `send(_:)`
        // above. Two concurrent chat sends from different tasks would
        // otherwise both observe `nextOutboundSeq=N` and produce duplicate
        // wire frames, which the peer rejects as SEQ_REPLAY.
        let seq = nextOutboundSeq
        nextOutboundSeq = seq &+ 1
        let pool = CrossPlatformPoolMessage(
            id: UUID(),
            type: .chat,
            senderID: localSenderID,
            senderName: localDisplayName,
            timestamp: clock(),
            payload: payload,
            isReliable: true
        )
        let plaintext = pool.encodeCanonical()
        try await sendEncryptedLocked(.encryptedPoolMessage, plaintext: plaintext, seq: seq)
    }

    public func ping() async throws {
        if closed { throw CrossPlatformTransportException(.closed, "session closed") }
        try await sendEncryptedLocked(.ping, plaintext: Data(), seq: nil)
    }

    public func pong() async throws {
        if closed { throw CrossPlatformTransportException(.closed, "session closed") }
        try await sendEncryptedLocked(.pong, plaintext: Data(), seq: nil)
    }

    /// Send a BYE then close. Reason MUST be ≤256 UTF-8 bytes per ADR-0005 §2.5.
    public func bye(reason: String? = nil) async {
        if closed { return }
        let payload = (reason?.data(using: .utf8)) ?? Data()
        precondition(
            payload.count <= CrossPlatformSession.byeReasonMaxBytes,
            "BYE reason exceeds \(CrossPlatformSession.byeReasonMaxBytes) bytes (got \(payload.count))"
        )
        // Best-effort: a broken socket is not fatal here, we close either way.
        _ = try? await sendEncryptedLocked(.bye, plaintext: payload, seq: nil)
        await close(reason: nil)
    }

    public func close(reason: CrossPlatformTransportError? = nil) async {
        if closed { return }
        closed = true
        await raw.close()
        eventsContinuation.yield(.disconnected(reason: reason))
        eventsContinuation.finish()
        inboundContinuation.finish()
        readerTask?.cancel()
    }

    // MARK: - Resume bookkeeping snapshots

    /// Snapshot the outbound replay buffer. Used by the host-side
    /// resume-bookkeeping path; entries are plaintexts ordered by seq
    /// ascending and the caller MUST re-encrypt before transmitting.
    public func snapshotOutboundBuffer() -> [BufferedFrame] { outboundBuffer }

    /// The value of the NEXT outbound seq this session will emit on the next
    /// `send`. ADR-0006 §A.4.
    public func outboundSeqSnapshot() -> UInt32 { nextOutboundSeq }

    /// The highest inbound seq this session has accepted, or `nil` if no
    /// inbound frame has yet advanced the tracker. ADR-0006 §A.4.
    public func inboundSeqSnapshot() -> UInt32? { lastInboundSeq }

    /// Re-send a list of buffered frames on this session. Used by
    /// `CrossPlatformPool` immediately after constructing the resumed host
    /// session: each entry is re-encrypted under the new `K_s2c'`, the
    /// encryption counter advances from 0, and the outbound replay buffer
    /// is re-populated so a *second* disconnect-resume cycle replays
    /// correctly. The inner `GameActionEnvelope.seq` is already baked into
    /// the plaintext, so the caller MUST NOT re-serialize.
    ///
    /// `highestKnownSeq` advances `nextOutboundSeq` so a post-resume
    /// application `send` does not collide with an already-delivered seq.
    public func replayBuffered(
        entries: [BufferedFrame],
        highestKnownSeq: UInt32?
    ) async throws {
        for entry in entries {
            try await sendEncryptedLocked(entry.frameType, plaintext: entry.plaintext, seq: entry.seq)
        }
        if let h = highestKnownSeq, h &+ 1 > nextOutboundSeq {
            nextOutboundSeq = h &+ 1
        }
    }

    // MARK: - Internals

    private func sendEncryptedLocked(
        _ type: CrossPlatformFrameType,
        plaintext: Data,
        seq: UInt32?
    ) async throws {
        // Buffer-for-resume runs BEFORE the wire write so an overflow-induced
        // close() prevents transmitting a frame we cannot reconstruct on resume.
        if type == .encryptedPoolMessage {
            guard let seq else {
                throw CrossPlatformTransportException(.incompatible, "ENCRYPTED_POOL_MESSAGE requires a seq")
            }
            try bufferForResume(type: type, seq: seq, plaintext: plaintext)
        }
        let counter = sendCounter.next()
        let body = try CrossPlatformFrameCodec.encryptedBody(
            type: type,
            key: sendKey,
            counter: counter,
            plaintext: plaintext
        )
        let frame = CrossPlatformFrameCodec.frameOf(body: body)
        do {
            try await raw.write(frame)
        } catch {
            // ADR-0006 §4: wire-write IOException-equivalent surfaces as
            // INCOMPATIBLE, NOT KEEPALIVE_TIMEOUT.
            await close(reason: .incompatible)
            throw CrossPlatformTransportException(.incompatible, "socket write failed")
        }
    }

    private func bufferForResume(
        type: CrossPlatformFrameType,
        seq: UInt32,
        plaintext: Data
    ) throws {
        // Only ENCRYPTED_POOL_MESSAGEs participate in resume — PING/PONG/BYE
        // are session-scoped events that don't survive a key rotation.
        if type != .encryptedPoolMessage { return }
        // Guest role does NOT retransmit unacked frames in M0 — its buffer
        // is never read. Skip the append AND the cap check for guests to
        // avoid an application-visible INCOMPATIBLE after the 257th send.
        if role == .guest { return }
        if outboundBuffer.count >= CrossPlatformSession.outboundBufferCap {
            // We can't await close() from a non-async context cleanly here,
            // but the function is already async at the call site — defer the
            // close to the caller by throwing first.
            Task { await self.close(reason: .incompatible) }
            throw CrossPlatformTransportException(
                .incompatible,
                "outbound buffer overflow (\(CrossPlatformSession.outboundBufferCap))"
            )
        }
        outboundBuffer.append(BufferedFrame(seq: seq, frameType: type, plaintext: plaintext))
    }

    private func runReader() async {
        do {
            while !closed {
                let optionalFrame = try await CrossPlatformFrameCodec.readFrame { n in
                    try await self.raw.readExact(n)
                }
                guard let frame = optionalFrame else { break }
                try await handleFrame(type: frame.type, body: frame.body)
            }
            await close(reason: nil)
        } catch let e as CrossPlatformTransportException {
            eventsContinuation.yield(.error(e.tag, message: e.message))
            await close(reason: e.tag)
        } catch is CancellationError {
            // Normal teardown.
        } catch {
            // Any non-Cancellation, non-Transport error during read: surface
            // as INCOMPATIBLE per ADR-0006 §4.
            if !closed {
                eventsContinuation.yield(.error(.incompatible, message: "reader: \(error)"))
                await close(reason: .incompatible)
            }
        }
    }

    private func handleFrame(type: CrossPlatformFrameType, body: Data) async throws {
        switch type {
        case .handshake:
            // Spec §3.1: post-handshake the wire MUST NOT carry plaintext
            // HANDSHAKE frames. Out-of-phase, not unknown-tag.
            throw CrossPlatformTransportException(.incompatible, "unexpected HANDSHAKE post-connect")
        case .ping:
            _ = try CrossPlatformFrameCodec.decryptBody(body: body, key: recvKey, tracker: recvCounter)
            // Respond with PONG (spec §5.3 caps response time at 5 s).
            _ = try? await sendEncryptedLocked(.pong, plaintext: Data(), seq: nil)
        case .pong:
            _ = try CrossPlatformFrameCodec.decryptBody(body: body, key: recvKey, tracker: recvCounter)
        case .bye:
            let plaintext = try CrossPlatformFrameCodec.decryptBody(body: body, key: recvKey, tracker: recvCounter)
            if plaintext.count > CrossPlatformSession.byeReasonMaxBytes {
                throw CrossPlatformTransportException(
                    .incompatible,
                    "BYE reason exceeds \(CrossPlatformSession.byeReasonMaxBytes) bytes (got \(plaintext.count))"
                )
            }
            await close(reason: nil)
        case .encryptedPoolMessage:
            let plaintext = try CrossPlatformFrameCodec.decryptBody(body: body, key: recvKey, tracker: recvCounter)
            let pool: CrossPlatformPoolMessage
            do { pool = try CrossPlatformPoolMessage.decode(plaintext) }
            catch let e as CrossPlatformTransportException { throw e }
            catch {
                throw CrossPlatformTransportException(.incompatible, "malformed PoolMessage: \(error)")
            }
            if pool.type == .gameAction {
                let envelope: CrossPlatformGameActionEnvelope
                do { envelope = try CrossPlatformGameActionEnvelope.decode(pool.payload) }
                catch let e as CrossPlatformTransportException { throw e }
                catch {
                    throw CrossPlatformTransportException(.incompatible, "malformed GameActionEnvelope: \(error)")
                }
                if envelope.sessionId != sessionIdB64u {
                    throw CrossPlatformTransportException(
                        .seqReplay,
                        "cross-session payload: \(envelope.sessionId) vs \(sessionIdB64u)"
                    )
                }
                if let last = lastInboundSeq, envelope.seq <= last {
                    throw CrossPlatformTransportException(.seqReplay, "seq \(envelope.seq) <= last \(last)")
                }
                lastInboundSeq = envelope.seq
            }
            inboundContinuation.yield(pool)
        }
    }
}
