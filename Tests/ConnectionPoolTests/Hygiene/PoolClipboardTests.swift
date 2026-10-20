// PoolClipboardTests.swift
// ConnectionPoolTests
//
// Secret copies: the safe default (local-only, expiring) and the host hook.

import Foundation
import Testing
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import ConnectionPool

@Suite("Secure copy", .serialized)
@MainActor
struct PoolClipboardTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Key material expires after 45 s, other secrets after 90 s")
    func expiryPerKind() {
        #expect(SecureCopyKind.recoveryKey.expiry == 45)
        #expect(SecureCopyKind.inviteSecret.expiry == 90)
        #expect(SecureCopyKind.messageContent.expiry == 90)
        #expect(SecureCopyKind.allCases.filter(\.isKeyMaterial) == [.recoveryKey])
    }

    @Test("Every secret write is local-only and expires", arguments: SecureCopyKind.allCases)
    func secretWriteIsLocalOnlyAndExpires(kind: SecureCopyKind) {
        let write = SecurePasteboardWrite(value: "secret-value", kind: kind, now: now)
        #expect(write.value == "secret-value")
        #expect(write.localOnly)
        #expect(write.expirationDate == now.addingTimeInterval(kind.expiry))
        #expect(write.typeIdentifier == UTType.utf8PlainText.identifier)
    }

    #if canImport(UIKit)
    @Test("UIPasteboard options carry localOnly and the expiration date", arguments: SecureCopyKind.allCases)
    func uiPasteboardOptions(kind: SecureCopyKind) throws {
        let write = SecurePasteboardWrite(value: "secret-value", kind: kind, now: now)
        let options = write.pasteboardOptions
        #expect(options.count == 2)
        #expect(try #require(options[.localOnly] as? Bool) == true)
        #expect(try #require(options[.expirationDate] as? Date) == now.addingTimeInterval(kind.expiry))
        let items = write.pasteboardItems
        #expect(items.count == 1)
        #expect(items.first?.count == 1)
        #expect(items.first?[UTType.utf8PlainText.identifier] as? String == "secret-value")
    }

    @Test("The default copy writes the value as plain text")
    func defaultCopyWritesValue() throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        PoolClipboard.defaultSecureCopy("pool-code-1234", kind: .inviteSecret, to: pasteboard)
        #expect(pasteboard.string == "pool-code-1234")
        #expect(pasteboard.numberOfItems == 1)
    }
    #elseif canImport(AppKit)
    @Test("The default copy writes the value with concealed/transient markers")
    func defaultCopyWritesValue() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        PoolClipboard.defaultSecureCopy("pool-code-1234", kind: .inviteSecret, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "pool-code-1234")
        let types = pasteboard.types ?? []
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }
    #endif

    @Test("An installed host hook receives every secret copy with its kind")
    func hostHookIsCalled() {
        var calls: [(String, SecureCopyKind)] = []
        ConnectionPoolConfiguration.secureCopy = { value, kind in calls.append((value, kind)) }
        defer { ConnectionPoolConfiguration.secureCopy = nil }

        #expect(ConnectionPoolConfiguration.secureCopy != nil)
        PoolClipboard.copySecret("recovery-key", kind: .recoveryKey)
        PoolClipboard.copySecret("ABC123", kind: .inviteSecret)

        #expect(calls.map(\.0) == ["recovery-key", "ABC123"])
        #expect(calls.map(\.1) == [.recoveryKey, .inviteSecret])
    }

    @Test("Removing the hook falls back to the default")
    func hookCanBeRemoved() {
        var called = false
        ConnectionPoolConfiguration.secureCopy = { _, _ in called = true }
        ConnectionPoolConfiguration.secureCopy = nil
        #expect(ConnectionPoolConfiguration.secureCopy == nil)
        #expect(PoolClipboard.secureCopyHandler == nil)
        #expect(!called)
    }
}
