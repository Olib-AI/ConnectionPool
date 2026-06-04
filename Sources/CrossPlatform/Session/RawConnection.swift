// RawConnection.swift
// ConnectionPool / CrossPlatform
//
// Minimal byte-pipe abstraction. The default real-world implementation
// (``SocketConnection`` in `Discovery/`) wraps an `NWConnection`; tests use
// the in-process pair from ``InMemoryConnection``. Implements the same
// contract as Kotlin's `RawConnection.kt`: framing, crypto, and the
// seq-replay state machine run end-to-end without the OS network stack.
//
// Closing a connection MUST cause subsequent `readExact` calls on the peer's
// side to return `nil` (EOF). Implementations wrapping real sockets get this
// for free; the in-memory pipe mirrors the behaviour.

import Foundation

public protocol RawConnection: Sendable {
    /// Read exactly `n` bytes. Returns `nil` if EOF is hit before any bytes
    /// arrive (clean close). Throws on a partial-read EOF or any I/O error.
    func readExact(_ n: Int) async throws -> Data?

    /// Write all of `data`. Throws on any I/O error.
    func write(_ data: Data) async throws

    /// Idempotent close. Subsequent reads on the peer's stream return `nil`.
    func close() async

    /// Short human-readable description of the remote endpoint. For real
    /// sockets this is the IP-only string used as the rate-limit key per
    /// ADR-0005 §2.4 (port deliberately excluded).
    var remoteDescription: String { get }
}
