// Iso8601Millis.swift
// ConnectionPool / CrossPlatform
//
// ISO-8601 UTC, millisecond precision, trailing `Z`. Required by spec §5.2.1
// for the cross-platform `PoolMessage.timestamp` field. Mirrors Kotlin
// `Iso8601Millis.kt`.
//
// Examples: `2026-05-16T14:23:45.000Z`, `2026-05-16T14:23:50.500Z`.
//
// Sub-millisecond precision is truncated (not rounded) before formatting so a
// `.500499` instant encodes the same on iOS, macOS, and the JVM.

import Foundation

enum CrossPlatformIso8601Millis {

    /// Pinned formatter. We cannot use `ISO8601DateFormatter` with
    /// `.withFractionalSeconds` because that emitter rounds rather than
    /// truncates and emits variable precision in some Locales. We pin a
    /// hand-rolled formatter with a fixed pattern.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Format an `Instant`-equivalent (`Date`) at millisecond precision.
    /// Sub-millisecond fractions are truncated (NOT rounded) before
    /// formatting so cross-platform byte equality holds at the boundary.
    static func format(_ date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
        let truncated = Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        return formatter.string(from: truncated)
    }

    /// Parse an ISO-8601-with-millisecond-precision-and-`Z` string. Also
    /// tolerates the variable-precision forms emitted by an over-helpful
    /// peer (e.g. a Java `Instant.toString()` that emits microseconds when
    /// they're non-zero).
    static func parse(_ s: String) -> Date? {
        if let exact = formatter.date(from: s) { return exact }
        // Fall back to ISO8601 with fractional seconds for tolerant parsing.
        let lenient = ISO8601DateFormatter()
        lenient.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let v = lenient.date(from: s) { return v }
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        return strict.date(from: s)
    }
}
