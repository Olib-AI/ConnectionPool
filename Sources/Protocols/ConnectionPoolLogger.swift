// ConnectionPoolLogger.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import os

// MARK: - Log Level

/// Log severity levels for ConnectionPool diagnostics
public enum PoolLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

// MARK: - Log Category

/// Log categories used within the ConnectionPool package
public enum PoolLogCategory: String, Sendable {
    case general = "General"
    case network = "Network"
    case runtime = "Runtime"
    case games = "Games"
}

// MARK: - Logger Protocol

/// Protocol for injecting a custom logger into the ConnectionPool package.
///
/// The host app should implement this protocol to bridge ConnectionPool logging
/// into the app's existing logging infrastructure.
public protocol ConnectionPoolLogger: Sendable {
    func log(
        _ message: String,
        level: PoolLogLevel,
        category: PoolLogCategory,
        file: String,
        function: String,
        line: Int
    )
}

// MARK: - Default os.Logger Fallback

/// Default logger implementation using Apple's os.Logger framework.
/// Used when no external logger is injected via ConnectionPoolConfiguration.
/// Messages carry peer names, hosts and peer-controlled text, so they are
/// `.private`: redacted in logs unless a debugger or profile reveals them.
private struct DefaultOSLogger: ConnectionPoolLogger {
    private static let subsystem = "ai.olib.connectionpool"

    func log(
        _ message: String,
        level: PoolLogLevel,
        category: PoolLogCategory,
        file: String,
        function: String,
        line: Int
    ) {
        let logger = os.Logger(subsystem: Self.subsystem, category: category.rawValue)
        let filename = (file as NSString).lastPathComponent
        let formattedMessage = "[\(filename):\(line)] \(function) - \(message)"

        switch level {
        case .debug:
            logger.debug("\(formattedMessage, privacy: .private)")
        case .info:
            logger.info("\(formattedMessage, privacy: .private)")
        case .warning:
            logger.warning("\(formattedMessage, privacy: .private)")
        case .error:
            logger.error("\(formattedMessage, privacy: .private)")
        case .critical:
            logger.critical("\(formattedMessage, privacy: .private)")
        }
    }
}

// MARK: - Package-Level Free Function

/// Package-level logging function matching the call-site signature used throughout ConnectionPool.
///
/// Delegates to an injected `ConnectionPoolLogger` if configured via
/// `ConnectionPoolConfiguration.logger`, otherwise falls back to `os.Logger`.
///
/// This function exists so that all existing `log(...)` call sites in the package
/// continue to compile without modification after removing the `import Core` dependency.
@available(macOS 14.0, iOS 17.0, *)
internal func log(
    _ message: String,
    level: PoolLogLevel = .info,
    category: PoolLogCategory = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    let logger = ConnectionPoolConfiguration.logger ?? _defaultLogger
    logger.log(message, level: level, category: category, file: file, function: function, line: line)
}

/// Singleton default logger instance — avoids allocation per log call.
private let _defaultLogger: ConnectionPoolLogger = DefaultOSLogger()
