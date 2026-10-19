// SlidingReplayWindow.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Sliding anti-replay window over 64-bit counters (RFC 6479 style ring bitmap).
///
/// Accepts each counter at most once, accepts anything newer than the highest seen, and
/// accepts older counters only within ``width`` of the highest (tolerating loss and
/// reordering). Storage is allocated once (8 KiB); updates are O(advance / 64).
public struct SlidingReplayWindow: Sendable {
    /// Window width in counters. For call media (counter = `sequence << 8 | fragment`)
    /// this is 256 frames: about 5 s of audio and 8.5 s of video.
    public static let width: UInt64 = 1 << 16
    private static let wordCount = Int(width / 64)

    private var words: [UInt64]
    private var top: UInt64 = 0
    private var started = false

    public init() {
        words = [UInt64](repeating: 0, count: Self.wordCount)
    }

    /// Whether `counter` would be accepted (no mutation).
    public func wouldAccept(_ counter: UInt64) -> Bool {
        guard started else { return true }
        if counter > top { return true }
        if top - counter >= Self.width { return false }
        return !isSet(counter)
    }

    /// Accepts and records `counter`; `false` for a replay or a counter older than the window.
    public mutating func accept(_ counter: UInt64) -> Bool {
        guard wouldAccept(counter) else { return false }
        if !started {
            started = true
            top = counter
        } else if counter > top {
            advance(to: counter)
        }
        set(counter)
        return true
    }

    private func isSet(_ counter: UInt64) -> Bool {
        let bit = Int(counter % Self.width)
        return words[bit >> 6] & (1 << UInt64(bit & 63)) != 0
    }

    private mutating func set(_ counter: UInt64) {
        let bit = Int(counter % Self.width)
        words[bit >> 6] |= 1 << UInt64(bit & 63)
    }

    private mutating func advance(to counter: UInt64) {
        let distance = counter - top
        if distance >= Self.width {
            for i in words.indices { words[i] = 0 }
        } else {
            var k = top &+ 1
            var remaining = distance
            while remaining > 0 {
                let bit = Int(k % Self.width)
                if bit & 63 == 0, remaining >= 64 {
                    words[bit >> 6] = 0
                    k &+= 64
                    remaining -= 64
                } else {
                    words[bit >> 6] &= ~(1 << UInt64(bit & 63))
                    k &+= 1
                    remaining -= 1
                }
            }
        }
        top = counter
    }
}
