// GoldenSupport.swift
// ConnectionPoolTests
//
// Loader for the golden wire vectors in this directory. The v1 files are byte-identical
// copies of StealthOS/Fixtures/golden (checked by `fixtureCopiesMatchMainRepository` when
// this package sits inside the StealthOS checkout); the *_v2 files are new and originate here.

import Foundation
import CryptoKit
import Testing

struct GoldenVector: Sendable, CustomTestStringConvertible {
    let name: String
    let kind: String
    let expect: String
    let inputs: [String: JSONValue]
    let outputs: [String: JSONValue]

    var testDescription: String { "\(kind)/\(name)" }

    struct Missing: Error, CustomStringConvertible { let description: String }

    private func need<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Missing(description: "\(what) missing or mistyped in vector \(name)") }
        return value
    }

    func input(_ key: String) throws -> JSONValue { try need(inputs[key], "input \(key)") }
    func output(_ key: String) throws -> JSONValue { try need(outputs[key], "output \(key)") }
    func inputString(_ key: String) throws -> String { try need(try input(key).string, key) }
    func outputString(_ key: String) throws -> String { try need(try output(key).string, key) }
    func inputHex(_ key: String) throws -> Data { try need(Data(hex: try inputString(key)), key) }
    func outputHex(_ key: String) throws -> Data { try need(Data(hex: try outputString(key)), key) }
    func inputInt(_ key: String) throws -> Int { try need(try input(key).int, key) }
    func outputInt(_ key: String) throws -> Int { try need(try output(key).int, key) }
    func inputDouble(_ key: String) throws -> Double { try need(try input(key).double, key) }
    func outputDouble(_ key: String) throws -> Double { try need(try output(key).double, key) }
    func outputBool(_ key: String) throws -> Bool { try need(try output(key).bool, key) }
    func inputBool(_ key: String) throws -> Bool { try need(try input(key).bool, key) }
    func inputUUID(_ key: String) throws -> UUID { try need(UUID(uuidString: try inputString(key)), key) }
}

enum JSONValue: Sendable, Equatable {
    case string(String), number(Double), integer(Int64), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if !CFNumberIsFloatType(n) {
                self = .integer(n.int64Value)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    var int: Int? {
        switch self {
        case .integer(let i): return Int(exactly: i)
        case .number(let n): return n.rounded() == n ? Int(exactly: n) : nil
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var isNull: Bool { self == .null }
}

enum Golden {
    static let directory: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// `StealthOS/Fixtures/golden` when this package is checked out inside StealthOS.
    static var mainRepositoryDirectory: URL? {
        let url = directory
            .deletingLastPathComponent() // ConnectionPoolTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ConnectionPool
            .deletingLastPathComponent() // LocalPackages
            .deletingLastPathComponent() // StealthOS
            .appendingPathComponent("Fixtures/golden")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func data(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }

    static func document(_ file: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try data(file))
        return try #require(object as? [String: Any])
    }

    static func vectors(_ file: String, kind: String? = nil) -> [GoldenVector] {
        guard let doc = try? document(file), let raw = doc["vectors"] as? [[String: Any]] else { return [] }
        return raw.compactMap { v -> GoldenVector? in
            guard let name = v["name"] as? String, let k = v["kind"] as? String, let e = v["expect"] as? String else { return nil }
            if let kind, kind != k { return nil }
            return GoldenVector(
                name: name, kind: k, expect: e,
                inputs: (v["inputs"] as? [String: Any] ?? [:]).mapValues(JSONValue.init),
                outputs: (v["outputs"] as? [String: Any] ?? [:]).mapValues(JSONValue.init)
            )
        }
    }

    static func vector(_ file: String, named name: String) throws -> GoldenVector {
        try #require(vectors(file).first { $0.name == name }, "no vector \(name) in \(file)")
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

/// SplitMix64: deterministic, seedable, reproducible across runs and platforms.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &self) }) }
}

/// Fuzz seed: `WIRE_FUZZ_SEED` from the environment to reproduce a run, otherwise fixed.
enum FuzzSeed {
    static func value(default fallback: UInt64) -> UInt64 {
        if let raw = ProcessInfo.processInfo.environment["WIRE_FUZZ_SEED"], let seed = UInt64(raw) { return seed }
        return fallback
    }
}
