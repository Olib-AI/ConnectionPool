// SourceHygieneTests.swift
// ConnectionPoolTests
//
// Source scans: no stdout logging, and no pasteboard write that bypasses PoolClipboard.

import Foundation
import Testing

@Suite("Source hygiene")
struct SourceHygieneTests {

    /// `Sources/` of this package, found from this file's path.
    static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Hygiene
        .deletingLastPathComponent() // ConnectionPoolTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // package root
        .appendingPathComponent("Sources", isDirectory: true)

    struct SourceLine: CustomStringConvertible {
        let path: String
        let number: Int
        let text: String
        var description: String { "\(path):\(number): \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Every non-comment line of every Swift file under `Sources/`.
    static func sourceLines() throws -> [SourceLine] {
        let enumerator = try #require(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
        var lines: [SourceLine] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(sourcesDirectory.path.count))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                lines.append(SourceLine(path: relative, number: index + 1, text: line))
            }
        }
        return lines
    }

    static func matching(_ pattern: String, in lines: [SourceLine]) throws -> [SourceLine] {
        let regex = try NSRegularExpression(pattern: pattern)
        return lines.filter { regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
    }

    @Test("The scan actually sees the package sources")
    func scanFindsSources() throws {
        let paths = Set(try Self.sourceLines().map(\.path))
        #expect(paths.contains("/Views/ConnectionPoolView.swift"))
        #expect(paths.contains("/Security/PoolClipboard.swift"))
        #expect(paths.count > 40)
    }

    @Test("Sources never print to stdout/stderr")
    func noPrintInSources() throws {
        let offenders = try Self.matching(#"(?<![A-Za-z0-9_.])(print|debugPrint|dump|NSLog)\s*\("#, in: Self.sourceLines())
        #expect(offenders.isEmpty, "Use the package logger instead of: \(offenders)")
    }

    @Test("Only PoolClipboard writes to the system pasteboard")
    func pasteboardWritesGoThroughPoolClipboard() throws {
        let lines = try Self.sourceLines().filter { $0.path != "/Security/PoolClipboard.swift" }
        let offenders = try Self.matching(#"UIPasteboard|NSPasteboard|\.textSelection\(\s*\.enabled"#, in: lines)
        #expect(offenders.isEmpty, "Copy secrets with PoolClipboard.copySecret: \(offenders)")
    }
}
