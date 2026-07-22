// PoolMenuIcon.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Menu-safe icon seam for the ConnectionPool + PoolChat UI.
//
// `PoolIcon` / IconKit's `FAIcon` are Text-based, font-glyph views. SwiftUI's
// system menus (`Menu`, `.contextMenu`, `swipeActions`, UIKit-backed toolbar
// items) strip the custom Font Awesome font — the glyph degrades to a "?" tofu
// box and sibling views are dropped. Those contexts render only real images.
//
// The host injects a renderer (wired from App/Integration/ConnectionPoolBridge)
// that rasterizes an FA glyph into a template `Image` via IconKit's
// `faMenuImage`, so menu rows tint it exactly like an SF Symbol (including the
// destructive red tint). When the seam is unset (previews / tests / standalone),
// `poolMenuLabel` falls back to an SF Symbol, which system menus render fine.

import SwiftUI

/// Host-injected renderer that rasterizes a Font Awesome glyph into a template
/// `Image` safe to place inside menus / context menus / swipe actions.
@MainActor
public enum PoolMenuIcon {
    /// Injected from the host bridge (delegates to IconKit's `faMenuImage`).
    /// When `nil`, `poolMenuLabel` falls back to an SF Symbol.
    public static var renderer: (@MainActor (String, CGFloat, PoolIconWeight) -> Image)?
}

/// A menu-row `Label` whose icon is a rasterized FA glyph (via the injected
/// renderer) or an SF-Symbol fallback, and whose title is localized through the
/// pool string seam.
///
/// Use ONLY inside `Menu` / `.contextMenu` / `swipeActions`. Everywhere else use
/// `PoolIcon` + `PoolText`. Returns a concrete `Label<Text, Image>` so both the
/// rasterized-image and SF-Symbol branches unify to one type.
@MainActor
public func poolMenuLabel(
    _ titleKey: String,
    fallback: String,
    icon: String,
    systemFallback: String,
    pointSize: CGFloat = 16,
    weight: PoolIconWeight = .solid
) -> Label<Text, Image> {
    let title = PoolDesign.shared.string(titleKey, nil, fallback: fallback)
    if let image = PoolMenuIcon.renderer?(icon, pointSize, weight) {
        return Label { Text(title) } icon: { image }
    }
    return Label(title, systemImage: systemFallback)
}
