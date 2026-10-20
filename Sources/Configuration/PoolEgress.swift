// PoolEgress.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// The host app's routing policy, injected (ConnectionPool cannot import the app's Core):
//
// - Remote pools: the relay WebSocket asks `route(for:)` on every (re)connect. The host
//   answers direct, through an authenticated HTTP CONNECT proxy (its loopback router), or
//   blocked. SPKI pinning stays end to end: TLS runs inside the CONNECT tunnel.
// - Local pools (MultipeerConnectivity, CrossPlatform Bonjour): they talk directly to
//   nearby devices and advertise this device on the local network, which no proxy can
//   hide. While the host reports an anonymity regime (Tor / a proxy / a relay) they do not
//   start unless the user explicitly accepts that exposure for this start
//   (`grantLocalPresenceConsent()`), and a regime that turns on stops them.
//
// With nothing injected (the package on its own, its tests) everything is direct and no
// regime is ever active: the previous behaviour.

import Foundation

/// How a relay WebSocket reaches the server.
public enum PoolNetworkRoute: Sendable, Equatable {
    case direct
    /// An HTTP proxy that requires Basic authentication on CONNECT.
    case httpProxy(host: String, port: Int, username: String, password: String)
    /// Do not connect; `reason` is shown to the user.
    case blocked(reason: String)
}

public enum PoolEgress {

    /// The route for a relay WebSocket URL. Unset: `.direct`.
    @MainActor public static var routeProvider: (@MainActor (URL) -> PoolNetworkRoute)?

    @MainActor static func route(for url: URL) -> PoolNetworkRoute {
        routeProvider?(url) ?? .direct
    }

    /// Request headers that replace the system defaults (User-Agent, Accept-Language) on a
    /// relay connection made through the host's proxy, so the upgrade request does not name
    /// the app build, OS or locale. Set by the host app.
    @MainActor public static var regimeIdentityHeaders: [String: String] = [:]

    /// Posted on the main thread by the host app whenever its routing changes. Open relay
    /// connections re-check their route; local presence stops if a regime appeared.
    public static let routeDidChange = Notification.Name("ConnectionPool.PoolEgress.routeDidChange")

    // MARK: Local presence

    private struct State {
        var regimeActive = false
        var consent = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    /// Set by the host app: Tor / a proxy / a relay governs its egress. Turning it on
    /// withdraws any consent given before.
    public static var isAnonymityRegimeActive: Bool {
        get { lock.withLock { state.regimeActive } }
        set {
            lock.withLock {
                if newValue != state.regimeActive { state.consent = false }
                state.regimeActive = newValue
            }
        }
    }

    /// The user accepted, after a warning, that nearby devices will see this device directly.
    /// Valid for one start; withdrawn when the pool stops or the regime changes.
    public static func grantLocalPresenceConsent() {
        lock.withLock { state.consent = true }
    }

    public static func revokeLocalPresenceConsent() {
        lock.withLock { state.consent = false }
    }

    /// Whether local discovery / advertising may start now.
    public static var mayUseLocalNetwork: Bool {
        lock.withLock { !state.regimeActive || state.consent }
    }
}

/// Why local presence is not running, for the pool UI.
public enum LocalPresenceNotice: Sendable, Equatable {
    /// A start was refused: a regime is active and the user has not accepted the exposure.
    case blockedByRegime
    /// A regime turned on while a local pool was running; it was stopped.
    case stoppedBecauseRegimeActivated
}
