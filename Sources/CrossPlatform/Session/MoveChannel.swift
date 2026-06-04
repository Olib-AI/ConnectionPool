// MoveChannel.swift
// ConnectionPool / CrossPlatform
//
// Domain-typed wrapper on top of `CrossPlatformSession` that hides the JSON
// envelope details from the chess view-model. Callers consume `moves` as a
// stream of `CrossPlatformChessGameAction`s — ordered, deduped, and
// version-validated by the underlying session.
// Mirrors Kotlin `MoveChannel.kt`.

import Foundation

public struct MoveChannel: Sendable {
    public let session: CrossPlatformSession

    public init(session: CrossPlatformSession) {
        self.session = session
    }

    /// Domain-typed move stream. Skips non-game_action `PoolMessage`s and
    /// decodes the envelope; any malformed envelope at this layer means a
    /// corrupted plaintext slipped past the session's AEAD verification,
    /// which would be a CryptoKit bug — the upstream session would have
    /// already raised an INCOMPATIBLE error on the same plaintext, so we
    /// drop here without re-emitting.
    public var moves: AsyncStream<CrossPlatformChessGameAction> {
        AsyncStream { continuation in
            let task = Task {
                for await message in session.inbound {
                    guard message.type == .gameAction else { continue }
                    if let envelope = try? CrossPlatformGameActionEnvelope.decode(message.payload) {
                        continuation.yield(envelope.action)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ action: CrossPlatformChessGameAction) async throws {
        try await session.send(action)
    }
}
