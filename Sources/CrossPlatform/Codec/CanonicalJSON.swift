// CanonicalJSON.swift
// ConnectionPool / CrossPlatform
//
// Canonical-JSON emitter, byte-exact per spec §5.2.1 and mirroring the Kotlin
// `CanonicalJson.kt` reference. The contract:
//
//   * UTF-8, no BOM
//   * keys sorted by **Unicode code-point** ascending (for ASCII this is
//     identical to byte-lexicographic; for surrogate-pair-containing keys we
//     compare decoded code points so we match Python's `sort_keys=True`)
//   * no insignificant whitespace — no spaces around `:` / `,`, no newlines,
//     no leading/trailing padding
//   * non-ASCII string-value characters emitted as literal UTF-8 (no `\u`
//     escape of printable Unicode; Swift's `.withoutEscapingSlashes` covers
//     `/` but the system encoder still does NOT preserve key order or
//     guarantee whitespace policy, so we hand-roll the emit path)
//   * the only escaped characters are RFC 8259's required set: `"`, `\\`,
//     and the C0 controls (`\b \f \n \r \t` short forms, others as `\u00XX`)
//
// Output is a `Data` (UTF-8 encoded) because every consumer is the wire layer
// or a SHA-256 / AEAD input — they want bytes, not `String`.

import Foundation

/// A minimal JSON-element AST. Mirrors Kotlin's `JsonElement` / `JsonObject` /
/// `JsonArray` / `JsonPrimitive` so the call sites of ``CanonicalJSON`` read
/// identically across both reference implementations.
///
/// Numbers are split between `int` (long-integral) and `number` (arbitrary
/// decimal as string) to preserve byte stability — Swift's `Double` formatting
/// is locale- and platform-sensitive in subtle ways, so for the few number
/// fields the protocol carries (`v`, `seq`) we route through the integral path.
public indirect enum JSONElement: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Raw numeric literal, already formatted. Caller-owned formatting.
    case number(String)
    case string(String)
    case array([JSONElement])
    case object([(String, JSONElement)])

    /// Convenience constructor for an ordered object literal from an array of
    /// `(key, value)` tuples. ``CanonicalJSON/encode(_:)`` re-sorts keys per
    /// the spec; the input order is irrelevant for output bytes but is
    /// preserved as a debug aid.
    public static func obj(_ pairs: [(String, JSONElement)]) -> JSONElement { .object(pairs) }

    public static func == (lhs: JSONElement, rhs: JSONElement) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (lhs, rhs) in zip(a, b) {
                if lhs.0 != rhs.0 || lhs.1 != rhs.1 { return false }
            }
            return true
        default: return false
        }
    }
}

/// Canonical-JSON byte emitter. See file header for the contract.
public enum CanonicalJSON {

    /// Encode [element] to canonical UTF-8 bytes.
    public static func encode(_ element: JSONElement) -> Data {
        var buf = String()
        buf.reserveCapacity(128)
        writeElement(&buf, element)
        return Data(buf.utf8)
    }

    /// Encode and return as a `String` view of the canonical bytes. Useful for
    /// vector tests and debug logging.
    public static func encodeToString(_ element: JSONElement) -> String {
        var buf = String()
        buf.reserveCapacity(128)
        writeElement(&buf, element)
        return buf
    }

    /// Decode an arbitrary RFC-8259-valid JSON byte sequence into a
    /// ``JSONElement`` AST. Receivers MUST accept any valid JSON, even
    /// non-canonical, per spec §5.2.1.
    public static func decode(_ data: Data) throws -> JSONElement {
        let any = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        return try liftFromFoundation(any)
    }

    // ---- Internal: emitter ------------------------------------------------

    private static func writeElement(_ out: inout String, _ element: JSONElement) {
        switch element {
        case .null:
            out.append("null")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .int(let i):
            out.append(String(i))
        case .number(let s):
            out.append(s)
        case .string(let s):
            writeString(&out, s)
        case .array(let arr):
            writeArray(&out, arr)
        case .object(let pairs):
            writeObject(&out, pairs)
        }
    }

    private static func writeObject(_ out: inout String, _ pairs: [(String, JSONElement)]) {
        out.append("{")
        // Re-sort by Unicode code-point. For ASCII keys (the entire v1
        // surface) this is identical to byte-lexicographic order. The
        // comparator also handles surrogate-pair-containing keys correctly
        // so a future emoji-keyed field would stay byte-stable.
        let sorted = pairs.sorted { codePointLess($0.0, $1.0) }
        var first = true
        for (key, value) in sorted {
            if !first { out.append(",") }
            first = false
            writeString(&out, key)
            out.append(":")
            writeElement(&out, value)
        }
        out.append("}")
    }

    private static func writeArray(_ out: inout String, _ arr: [JSONElement]) {
        out.append("[")
        var first = true
        for e in arr {
            if !first { out.append(",") }
            first = false
            writeElement(&out, e)
        }
        out.append("]")
    }

    private static func writeString(_ out: inout String, _ s: String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            // Escape per RFC 8259. Printable non-ASCII (codepoints >= 0x20,
            // excluding `"` and `\`) is emitted literally; the UTF-8 encoder
            // for `Data(buf.utf8)` writes those code points as multi-byte
            // sequences. We MUST NOT `\u`-escape printable Unicode — the
            // vectors include literal `👑` / `🔥` UTF-8 bytes inside the
            // `emoji` field.
            let v = scalar.value
            switch v {
            case 0x22:               out.append("\\\"")
            case 0x5C:               out.append("\\\\")
            case 0x08:               out.append("\\b")
            case 0x0C:               out.append("\\f")
            case 0x0A:               out.append("\\n")
            case 0x0D:               out.append("\\r")
            case 0x09:               out.append("\\t")
            case 0x00...0x1F:
                // Other C0 controls as `\u00XX`.
                out.append(String(format: "\\u%04x", v))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }

    /// Unicode-code-point string comparator. For BMP-only strings this matches
    /// byte-wise UTF-8 compare; for strings that include surrogate pairs it
    /// compares decoded code points so the canonical output matches Python's
    /// `sort_keys=True` semantics (which is the source of vector ordering).
    private static func codePointLess(_ a: String, _ b: String) -> Bool {
        let av = a.unicodeScalars
        let bv = b.unicodeScalars
        var ai = av.startIndex
        var bi = bv.startIndex
        while ai != av.endIndex && bi != bv.endIndex {
            let ac = av[ai].value
            let bc = bv[bi].value
            if ac != bc { return ac < bc }
            ai = av.index(after: ai)
            bi = bv.index(after: bi)
        }
        return av.count < bv.count
    }

    // ---- Internal: Foundation→JSONElement lift ----------------------------

    private static func liftFromFoundation(_ any: Any) throws -> JSONElement {
        if any is NSNull { return .null }
        if let b = any as? Bool {
            // NSNumber bridges through `as? Bool`. Disambiguate Bool from
            // numeric NSNumber by checking the underlying ObjC type.
            if let n = any as? NSNumber, CFNumberGetType(n) == .charType || String(cString: n.objCType) == "c" {
                return .bool(b)
            }
        }
        if let n = any as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                return .bool(n.boolValue)
            }
            // Integral path first — preserves byte stability for `v`/`seq`.
            if type == "q" || type == "Q" || type == "i" || type == "I"
                || type == "l" || type == "L" || type == "s" || type == "S" {
                return .int(n.int64Value)
            }
            // Double / float path — preserve as a string of the shortest
            // round-trippable decimal. Swift's `Double.description` produces
            // the shortest form for most values; we accept it here for
            // inbound decoded JSON since receivers don't need byte-stable
            // re-emission of arbitrary doubles.
            return .number(n.stringValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] {
            return .array(try a.map(liftFromFoundation))
        }
        if let d = any as? [String: Any] {
            var pairs: [(String, JSONElement)] = []
            pairs.reserveCapacity(d.count)
            for k in d.keys {
                pairs.append((k, try liftFromFoundation(d[k] as Any)))
            }
            return .object(pairs)
        }
        throw CrossPlatformTransportException(.incompatible, "unsupported JSON value: \(type(of: any))")
    }
}
