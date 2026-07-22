// ConnectionPoolConfiguration.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI

/// Protocol for pluggable block list storage.
///
/// Implement this protocol to provide encrypted or otherwise secure persistence
/// for the device block list. If no provider is configured on
/// `ConnectionPoolConfiguration`, `DeviceBlockListService` falls back to plain
/// `UserDefaults`.
public protocol BlockListStorageProvider: Sendable {
    /// Persist raw data for the given key.
    func save(_ data: Data, forKey key: String) throws
    /// Load previously persisted data for the given key, or `nil` if none exists.
    func load(forKey key: String) throws -> Data?
}

/// Static configuration point for the ConnectionPool package.
///
/// The host app should call `ConnectionPoolConfiguration.logger = ...` at startup
/// to inject its logging infrastructure. If not configured, a default `os.Logger`
/// fallback is used.
public enum ConnectionPoolConfiguration {
    /// Logger instance injected by the host app.
    /// Set this before any ConnectionPool APIs are used.
    private static let _loggerLock = NSLock()
    nonisolated(unsafe) private static var _logger: ConnectionPoolLogger?
    public static var logger: ConnectionPoolLogger? {
        get { _loggerLock.withLock { _logger } }
        set { _loggerLock.withLock { _logger = newValue } }
    }

    /// Optional secure storage provider for the device block list.
    ///
    /// When set, `DeviceBlockListService` persists block list data through this
    /// provider instead of plain `UserDefaults`. The host app should wire this to
    /// an encrypted storage backend (e.g., Keychain or SecureDataStore).
    ///
    /// Set this at app startup alongside the logger, before any ConnectionPool
    /// APIs are used.
    @MainActor public static var blockListStorageProvider: BlockListStorageProvider?

    /// Optional secure storage provider for remote pool connection state.
    ///
    /// When set, `RemotePoolState` persists through this provider instead of
    /// plain `UserDefaults`. The host app should wire this to an encrypted
    /// storage backend (e.g., Keychain or SecureDataStore) to prevent leaking
    /// connection history (server URL, pool ID, host status).
    ///
    /// Set this at app startup alongside the logger, before any ConnectionPool
    /// APIs are used.
    @MainActor public static var remotePoolStateStorageProvider: (any BlockListStorageProvider)?

    // MARK: - UI design injection seams
    //
    // ConnectionPool (and PoolChat, which depends on it) cannot import the app's
    // ThemeKit / IconKit / LanguageKit. The host wires these three seams from
    // `App/Integration/ConnectionPoolBridge.swift` so the pool UI adopts the
    // active theme, iconography, and language. All three delegate to the shared
    // `PoolDesign` store the pool views observe. When unset the package falls
    // back to neutral colors, its built-in English strings, and SF Symbols.

    /// Resolves a `PoolThemeSnapshot` of the live theme tokens for a color scheme.
    @MainActor public static var themeResolver: (@MainActor (ColorScheme) -> PoolThemeSnapshot)? {
        get { PoolDesign.shared.themeResolver }
        set { PoolDesign.shared.themeResolver = newValue }
    }

    /// Resolves a LanguageKit key (+ optional interpolation args) to a string.
    @MainActor public static var stringProvider: (@MainActor (String, [String: String]?) -> String)? {
        get { PoolDesign.shared.stringProvider }
        set { PoolDesign.shared.stringProvider = newValue }
    }

    /// Renders an FA icon name at a point size + weight (host uses IconKit).
    @MainActor public static var iconRenderer: (@MainActor (String, CGFloat, PoolIconWeight) -> AnyView)? {
        get { PoolDesign.shared.iconRenderer }
        set { PoolDesign.shared.iconRenderer = newValue }
    }

    /// Notify the pool UI that the theme, appearance, or language changed so it
    /// re-renders. The host calls this on any `ThemeEngine` / `LanguageEngine`
    /// change.
    @MainActor public static func notifyDesignChanged() {
        PoolDesign.shared.invalidate()
    }
}
