// VectorLoader.swift
// ConnectionPoolTests / CrossPlatform
//
// Loads the frozen reference vectors from `Tests/.../CrossPlatform/Vectors/`.
// Because the test target's `Package.swift` does not declare a resource
// bundle, we resolve the path relative to `#file` and read directly from
// the source tree at test time. This is the dev path — for a CI-time
// distribution where the test target is built without source-tree access,
// a `.copy("CrossPlatform/Vectors")` would have to be added to
// `Package.swift`; the audit notes this caveat.

import Foundation
import XCTest

enum VectorLoader {

    /// Resolve the vectors directory by walking up from the test file path.
    static func dataForVector(_ name: String, file: StaticString = #filePath) -> Data {
        let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("Vectors").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return (try? Data(contentsOf: candidate)) ?? Data()
        }
        // Walk up one level — the loader may live inside `CrossPlatform/`
        // while the vectors sit at `CrossPlatform/Vectors/`. We already
        // looked there; fallback to the sibling tree.
        let parentCandidate = dir.deletingLastPathComponent().appendingPathComponent("CrossPlatform/Vectors").appendingPathComponent(name)
        return (try? Data(contentsOf: parentCandidate)) ?? Data()
    }

    static func parse(_ name: String, file: StaticString = #filePath) throws -> [String: Any] {
        let data = dataForVector(name, file: file)
        XCTAssertFalse(data.isEmpty, "missing vector: \(name)")
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return obj as? [String: Any] ?? [:]
    }
}
