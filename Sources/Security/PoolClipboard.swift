// PoolClipboard.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// The one place ConnectionPool and PoolChat put secrets on the system pasteboard.
//
// LocalPackages cannot import the app's Core, so the host injects its own secure
// pasteboard through `ConnectionPoolConfiguration.secureCopy`. When nothing is
// injected (previews, tests, standalone builds) the built-in default is itself
// safe: the item never enters Universal Clipboard (`.localOnly`) and the system
// removes it at `.expirationDate`, even while the app is suspended or terminated
// (an in-app `asyncAfter` clear never fires once the user switches apps, which is
// exactly when they paste).

import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Kind

/// What a secret copy carries; decides how long it may stay on the pasteboard.
public enum SecureCopyKind: Sendable, Hashable, CaseIterable {
    /// Key material: the relay server's recovery key. Expires after `keyExpiry`.
    case recoveryKey
    /// A credential that admits someone to a pool: the pool join code (which also
    /// derives the pool's relay integrity key). Expires after `secretExpiry`.
    case inviteSecret
    /// Decrypted end-to-end message content (PoolChat). Expires after `secretExpiry`.
    case messageContent

    /// Pasteboard lifetime for key material.
    public static let keyExpiry: TimeInterval = 45
    /// Pasteboard lifetime for every other secret.
    public static let secretExpiry: TimeInterval = 90

    /// True for key material.
    public var isKeyMaterial: Bool { self == .recoveryKey }

    /// How long a copy of this kind may stay on the pasteboard.
    public var expiry: TimeInterval { isKeyMaterial ? Self.keyExpiry : Self.secretExpiry }
}

// MARK: - Write description

/// A platform-neutral description of one secret pasteboard write: what the
/// default implementation puts on the pasteboard and with which restrictions.
public struct SecurePasteboardWrite: Sendable, Equatable {
    public let value: String
    public let kind: SecureCopyKind
    /// Uniform type of the single item (`public.utf8-plain-text`, what
    /// `UIPasteboard.string` reads and writes).
    public let typeIdentifier: String
    /// Kept off Universal Clipboard.
    public let localOnly: Bool
    /// When the system removes the item.
    public let expirationDate: Date

    public init(value: String, kind: SecureCopyKind, now: Date = Date()) {
        self.value = value
        self.kind = kind
        self.typeIdentifier = UTType.utf8PlainText.identifier
        self.localOnly = true
        self.expirationDate = now.addingTimeInterval(kind.expiry)
    }

    #if canImport(UIKit)
    /// Items for `UIPasteboard.setItems(_:options:)`.
    public var pasteboardItems: [[String: Any]] { [[typeIdentifier: value]] }

    /// Options for `UIPasteboard.setItems(_:options:)`.
    public var pasteboardOptions: [UIPasteboard.OptionsKey: Any] {
        [.localOnly: localOnly, .expirationDate: expirationDate]
    }
    #endif
}

// MARK: - Clipboard

/// Copies pool and chat secrets. Every secret copy in ConnectionPool and PoolChat
/// goes through `copySecret(_:kind:)`.
@MainActor
public enum PoolClipboard {

    /// Host-supplied secure copy. Receives the value and its kind and is
    /// responsible for `.localOnly` plus an expiry of at least as short as
    /// `kind.expiry`. Nil: `defaultSecureCopy` is used.
    public typealias SecureCopyHandler = @MainActor (String, SecureCopyKind) -> Void

    /// Set through `ConnectionPoolConfiguration.secureCopy`.
    static var secureCopyHandler: SecureCopyHandler?

    /// Copy a secret through the host hook, or the safe default when none is installed.
    public static func copySecret(_ value: String, kind: SecureCopyKind) {
        if let secureCopyHandler {
            secureCopyHandler(value, kind)
        } else {
            defaultSecureCopy(value, kind: kind)
        }
    }

    #if canImport(UIKit)
    /// The built-in secure copy: one plain-text item, `.localOnly`, expiring after
    /// `kind.expiry`.
    public static func defaultSecureCopy(
        _ value: String,
        kind: SecureCopyKind,
        to pasteboard: UIPasteboard = .general,
        now: Date = Date()
    ) {
        let write = SecurePasteboardWrite(value: value, kind: kind, now: now)
        pasteboard.setItems(write.pasteboardItems, options: write.pasteboardOptions)
    }
    #elseif canImport(AppKit)
    /// The built-in secure copy on macOS. NSPasteboard has no local-only or expiry
    /// option, so the item is tagged with the nspasteboard.org concealed/transient
    /// markers (clipboard managers and history tools skip it) and cleared after
    /// `kind.expiry` unless something else was copied in the meantime.
    public static func defaultSecureCopy(
        _ value: String,
        kind: SecureCopyKind,
        to pasteboard: NSPasteboard = .general,
        now: Date = Date()
    ) {
        let write = SecurePasteboardWrite(value: value, kind: kind, now: now)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(write.value, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let changeCount = pasteboard.changeCount
        let delay = max(0, write.expirationDate.timeIntervalSince(now))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
    }
    #endif
}
