// InMemoryConnection.swift
// ConnectionPool / CrossPlatform
//
// Pair of `RawConnection`s wired together with bounded async byte buffers
// (one per direction). Each buffer is backed by a Swift actor + waiting
// continuations, so reads await new bytes asynchronously and `close()` ends
// both sides cleanly without leaking suspended tasks. Mirrors Kotlin's
// `InMemoryConnection.kt`.
//
// The frame/crypto/state-machine layers exercise their full code paths
// exactly as they would over TCP. Intended for the loopback integration
// test and the adversarial-case tests.

import Foundation
import os

public enum InMemoryConnection {

    /// Create a pair of connected `RawConnection`s. Writes to `a` appear as
    /// reads on `b` and vice versa. Closing either end EOFs both pipes
    /// (mirrors a TCP socket's RST behaviour).
    public static func pair(aLabel: String = "A", bLabel: String = "B") -> (RawConnection, RawConnection) {
        let aToB = ByteStreamBuffer()
        let bToA = ByteStreamBuffer()
        let a = Conn(label: aLabel, readFrom: bToA, writeTo: aToB, onClose: {
            await aToB.close()
            await bToA.close()
        })
        let b = Conn(label: bLabel, readFrom: aToB, writeTo: bToA, onClose: {
            await aToB.close()
            await bToA.close()
        })
        return (a, b)
    }

    /// Async-actor-backed bounded byte buffer. Writes are immediate; reads
    /// suspend until at least 1 byte is available, the buffer closes, or
    /// the calling Task is cancelled.
    actor ByteStreamBuffer {
        private var buffer = Data()
        private var closed = false
        /// Parked readers, identified by a monotonic id so cancellation can
        /// find and resume the right continuation.
        private var waiters: [(id: UInt64, cont: CheckedContinuation<Void, Never>)] = []
        private var nextWaiterId: UInt64 = 0

        func write(_ bytes: Data) throws {
            if closed { throw CrossPlatformTransportException(.incompatible, "buffer closed") }
            buffer.append(bytes)
            wakeAll()
        }

        /// Read up to `max` bytes. Honors Task cancellation: if the caller's
        /// Task is cancelled while we're waiting on a continuation, we wake
        /// the waiter so the loop checks `Task.isCancelled` and returns EOF.
        func readSome(max: Int) async -> Data {
            while buffer.isEmpty && !closed {
                if Task.isCancelled { return Data() }
                let id = nextWaiterId
                nextWaiterId &+= 1
                // Park, but watch for Task cancellation via withTaskCancellationHandler.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        waiters.append((id: id, cont: cont))
                    }
                } onCancel: {
                    Task { await self.wakeAndDrop(id: id) }
                }
                if Task.isCancelled { return Data() }
            }
            if buffer.isEmpty { return Data() } // EOF
            let chunk = buffer.prefix(max)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }

        func close() {
            closed = true
            wakeAll()
        }

        private func wakeAll() {
            let snapshot = waiters
            waiters.removeAll(keepingCapacity: false)
            for w in snapshot { w.cont.resume() }
        }

        /// Cancellation path: resume just the matching waiter if still parked.
        func wakeAndDrop(id: UInt64) {
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                w.cont.resume()
            }
        }
    }

    /// `RawConnection` backed by a pair of `ByteStreamBuffer`s. The `onClose`
    /// closure tears down both directions when either side closes.
    /// `OSAllocatedUnfairLock` is the async-safe replacement for `NSLock`
    /// (Swift strict concurrency rejects raw `NSLock.lock()` from async).
    final class Conn: RawConnection, @unchecked Sendable {
        let remoteDescription: String
        private let readFrom: ByteStreamBuffer
        private let writeTo: ByteStreamBuffer
        private let onClose: @Sendable () async -> Void
        private let stateLock = OSAllocatedUnfairLock<Bool>(initialState: false)

        init(label: String,
             readFrom: ByteStreamBuffer,
             writeTo: ByteStreamBuffer,
             onClose: @escaping @Sendable () async -> Void) {
            self.remoteDescription = "in-memory[\(label)]"
            self.readFrom = readFrom
            self.writeTo = writeTo
            self.onClose = onClose
        }

        func readExact(_ n: Int) async throws -> Data? {
            var out = Data()
            out.reserveCapacity(n)
            while out.count < n {
                if Task.isCancelled { return nil }
                let chunk = await readFrom.readSome(max: n - out.count)
                if chunk.isEmpty {
                    if Task.isCancelled { return nil }
                    if out.isEmpty { return nil } // clean EOF
                    throw CrossPlatformTransportException(.handshakeTimeout, "short read: \(out.count)/\(n)")
                }
                out.append(chunk)
            }
            return out
        }

        func write(_ data: Data) async throws {
            try await writeTo.write(data)
        }

        func close() async {
            let firstClose = stateLock.withLock { closed in
                if closed { return false }
                closed = true
                return true
            }
            if firstClose { await onClose() }
        }
    }
}
