// PoolDesign.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Design injection seam for the ConnectionPool + PoolChat UI.
//
// LocalPackages MUST NOT depend on the app's Packages/ (no ThemeKit / IconKit /
// LanguageKit imports). Instead the host app injects three closures at startup
// (wired from App/Integration/ConnectionPoolBridge.swift + PoolChatBridge.swift):
//
//   • a theme resolver  — hands the package a `PoolThemeSnapshot` of the live
//                          ThemeKit tokens for a given color scheme,
//   • a string provider — resolves a LanguageKit key to a localized string,
//   • an icon renderer  — renders an FA icon name via IconKit's `FAIcon`.
//
// When a seam is unset (previews, tests, standalone builds) the package falls
// back to neutral SwiftUI colors, its built-in English strings, and SF Symbols,
// so it always renders something sane and never crashes.
//
// Views observe `PoolDesign.shared` and read `poolTheme(scheme)` so theme,
// appearance, and language switches re-render live.

import SwiftUI

/// Weight of an injected icon glyph (maps to IconKit's regular / solid faces).
public enum PoolIconWeight: Sendable, Equatable {
    case regular
    case solid
}

/// A plain snapshot of the host theme's semantic tokens for ONE color scheme.
///
/// The host (which can import ThemeKit) translates its `ThemeTokens` into this
/// struct; the package renders from it without ever importing ThemeKit.
public struct PoolThemeSnapshot: Sendable {

    // Backgrounds / surfaces (furthest-back to nearest-front)
    public var background: Color
    public var backgroundSecondary: Color
    public var surface: Color
    public var surfaceSecondary: Color
    public var surfaceElevated: Color

    // Text hierarchy
    public var textPrimary: Color
    public var textSecondary: Color
    public var textTertiary: Color
    public var textOnAccent: Color

    // Accent
    public var accent: Color
    public var accentMuted: Color

    // Status
    public var success: Color
    public var warning: Color
    public var danger: Color
    public var info: Color
    public var privacyAccent: Color

    // Lines / selection / shadow
    public var border: Color
    public var separator: Color
    public var selection: Color
    public var selectionText: Color
    public var shadow: Color

    // Corner radii
    public var radiusSmall: CGFloat
    public var radiusMedium: CGFloat
    public var radiusLarge: CGFloat

    // Spacing scale
    public var spacingXS: CGFloat
    public var spacingS: CGFloat
    public var spacingM: CGFloat
    public var spacingL: CGFloat
    public var spacingXL: CGFloat

    // Typography roles
    public var fontHeading: Font
    public var fontBody: Font
    public var fontCaption: Font
    public var fontMono: Font

    public init(
        background: Color,
        backgroundSecondary: Color,
        surface: Color,
        surfaceSecondary: Color,
        surfaceElevated: Color,
        textPrimary: Color,
        textSecondary: Color,
        textTertiary: Color,
        textOnAccent: Color,
        accent: Color,
        accentMuted: Color,
        success: Color,
        warning: Color,
        danger: Color,
        info: Color,
        privacyAccent: Color,
        border: Color,
        separator: Color,
        selection: Color,
        selectionText: Color,
        shadow: Color,
        radiusSmall: CGFloat,
        radiusMedium: CGFloat,
        radiusLarge: CGFloat,
        spacingXS: CGFloat,
        spacingS: CGFloat,
        spacingM: CGFloat,
        spacingL: CGFloat,
        spacingXL: CGFloat,
        fontHeading: Font,
        fontBody: Font,
        fontCaption: Font,
        fontMono: Font
    ) {
        self.background = background
        self.backgroundSecondary = backgroundSecondary
        self.surface = surface
        self.surfaceSecondary = surfaceSecondary
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textOnAccent = textOnAccent
        self.accent = accent
        self.accentMuted = accentMuted
        self.success = success
        self.warning = warning
        self.danger = danger
        self.info = info
        self.privacyAccent = privacyAccent
        self.border = border
        self.separator = separator
        self.selection = selection
        self.selectionText = selectionText
        self.shadow = shadow
        self.radiusSmall = radiusSmall
        self.radiusMedium = radiusMedium
        self.radiusLarge = radiusLarge
        self.spacingXS = spacingXS
        self.spacingS = spacingS
        self.spacingM = spacingM
        self.spacingL = spacingL
        self.spacingXL = spacingXL
        self.fontHeading = fontHeading
        self.fontBody = fontBody
        self.fontCaption = fontCaption
        self.fontMono = fontMono
    }

    /// Neutral fallback used before the host injects a resolver (previews / tests
    /// / standalone). Grayscale surfaces + standard SwiftUI status colors — no
    /// purple, no gradients. In-app the host always replaces this with real
    /// ThemeKit tokens.
    public static func fallback(dark: Bool) -> PoolThemeSnapshot {
        PoolThemeSnapshot(
            background: dark ? Color(white: 0.07) : Color(white: 0.96),
            backgroundSecondary: dark ? Color(white: 0.11) : Color(white: 0.93),
            surface: dark ? Color(white: 0.14) : .white,
            surfaceSecondary: dark ? Color(white: 0.18) : Color(white: 0.97),
            surfaceElevated: dark ? Color(white: 0.20) : .white,
            textPrimary: dark ? .white : Color(white: 0.10),
            textSecondary: dark ? Color(white: 0.72) : Color(white: 0.38),
            textTertiary: dark ? Color(white: 0.52) : Color(white: 0.58),
            textOnAccent: .white,
            accent: .blue,
            accentMuted: Color.blue.opacity(0.5),
            success: .green,
            warning: .orange,
            danger: .red,
            info: .teal,
            privacyAccent: .teal,
            border: dark ? Color(white: 0.28) : Color(white: 0.82),
            separator: dark ? Color(white: 0.24) : Color(white: 0.88),
            selection: Color.blue.opacity(dark ? 0.32 : 0.16),
            selectionText: dark ? .white : Color(white: 0.10),
            shadow: .black,
            radiusSmall: 5,
            radiusMedium: 8,
            radiusLarge: 14,
            spacingXS: 4,
            spacingS: 8,
            spacingM: 12,
            spacingL: 16,
            spacingXL: 24,
            fontHeading: .title3.weight(.semibold),
            fontBody: .body,
            fontCaption: .caption,
            fontMono: .system(.body, design: .monospaced)
        )
    }
}

/// The runtime design store the pool UI observes. A single shared instance backs
/// both ConnectionPool and PoolChat (PoolChat depends on ConnectionPool).
@MainActor
public final class PoolDesign: ObservableObject {

    public static let shared = PoolDesign()

    private init() {}

    /// Bumped by the host whenever the theme, appearance, OR language changes so
    /// every observing pool view re-renders.
    @Published public private(set) var revision: Int = 0

    /// Resolves a `PoolThemeSnapshot` for the given color scheme. Injected by the
    /// host; when nil the package uses `PoolThemeSnapshot.fallback`.
    public var themeResolver: (@MainActor (ColorScheme) -> PoolThemeSnapshot)?

    /// Resolves a LanguageKit key (+ optional interpolation args) to a localized
    /// string. Injected by the host; when nil the caller's English fallback wins.
    public var stringProvider: (@MainActor (String, [String: String]?) -> String)?

    /// Renders an FA icon name at a point size + weight. Injected by the host;
    /// when nil `PoolIcon` falls back to an SF Symbol.
    public var iconRenderer: (@MainActor (String, CGFloat, PoolIconWeight) -> AnyView)?

    /// Snapshot of tokens for a color scheme (real tokens if injected, else fallback).
    public func snapshot(dark: Bool) -> PoolThemeSnapshot {
        if let resolver = themeResolver {
            return resolver(dark ? .dark : .light)
        }
        return .fallback(dark: dark)
    }

    /// Localized string for a key, or `fallback` if no provider is wired.
    public func string(_ key: String, _ args: [String: String]?, fallback: String) -> String {
        stringProvider?(key, args) ?? fallback
    }

    /// Type-erased icon view, or nil if no renderer is wired.
    public func icon(_ name: String, size: CGFloat, weight: PoolIconWeight) -> AnyView? {
        iconRenderer?(name, size, weight)
    }

    /// Force a re-render (host calls this on theme / appearance / language change).
    public func invalidate() {
        revision &+= 1
    }
}

// MARK: - View-side conveniences

public extension View {
    /// Reads the live pool theme snapshot for the environment's color scheme.
    /// Screen roots should also hold `@ObservedObject var design = PoolDesign.shared`
    /// so theme + language switches re-render.
    @MainActor
    func poolTheme(_ scheme: ColorScheme) -> PoolThemeSnapshot {
        PoolDesign.shared.snapshot(dark: scheme == .dark)
    }
}

/// An icon rendered through the injected renderer (IconKit `FAIcon` in-app),
/// falling back to an SF Symbol when the seam is unset.
///
/// `name` is the Font Awesome name (verified against IconKit's catalog);
/// `systemFallback` is the legacy SF Symbol used only when no renderer is wired.
public struct PoolIcon: View {

    @ObservedObject private var design = PoolDesign.shared

    private let name: String
    private let size: CGFloat
    private let weight: PoolIconWeight
    private let systemFallback: String?

    public init(
        _ name: String,
        size: CGFloat = 16,
        weight: PoolIconWeight = .solid,
        systemFallback: String? = nil
    ) {
        self.name = name
        self.size = size
        self.weight = weight
        self.systemFallback = systemFallback
    }

    public var body: some View {
        if let rendered = design.icon(name, size: size, weight: weight) {
            rendered
        } else if let systemFallback {
            Image(systemName: systemFallback)
                .font(.system(size: size))
        } else {
            Image(systemName: "questionmark.circle")
                .font(.system(size: size))
        }
    }
}

/// A localized `Text` resolved through the injected string provider, falling back
/// to the supplied English literal when the seam is unset. Re-renders on language
/// change via the observed `PoolDesign`.
public struct PoolText: View {

    @ObservedObject private var design = PoolDesign.shared

    private let key: String
    private let args: [String: String]?
    private let fallback: String

    public init(_ key: String, fallback: String, args: [String: String]? = nil) {
        self.key = key
        self.args = args
        self.fallback = fallback
    }

    public var body: some View {
        Text(design.string(key, args, fallback: fallback))
    }
}

/// Resolve a localized string for non-`Text` contexts (accessibility labels,
/// alert titles, `Menu` labels, model `displayName`s).
///
/// `nonisolated` so it drops into view bodies AND plain (non-isolated) computed
/// properties on `View` structs without an `@MainActor` annotation — mirroring
/// LanguageKit's `L(_:)`. It resolves via `MainActor.assumeIsolated`, so it MUST
/// be called on the main thread (all UI string resolution is).
public func poolString(_ key: String, fallback: String, args: [String: String]? = nil) -> String {
    MainActor.assumeIsolated {
        PoolDesign.shared.string(key, args, fallback: fallback)
    }
}

// MARK: - Deferred Label

/// Builds its content inside `body` instead of at the call site.
///
/// Some SwiftUI builder closures are declared `@Sendable` in the SDK - notably
/// `PhotosPicker(selection:matching:label:)`. A `@Sendable` closure does not
/// inherit the caller's actor isolation, so its body is nonisolated even though
/// SwiftUI only ever runs it while evaluating a view body on the main actor.
/// That makes themed views such as `PoolIcon` (which stores the `@MainActor`
/// `PoolDesign.shared` as an `@ObservedObject`, and therefore has a main-actor
/// isolated initializer) unusable directly inside those closures.
///
/// This wrapper stores the content as a `@MainActor` closure - creating a closure
/// is nonisolated, only calling it is not - and invokes it from `body`, which is
/// main-actor isolated. Rendering is unchanged: `body` returns the content
/// verbatim, with no added layout.
public struct PoolDeferredLabel<Content: View>: View {
    @ViewBuilder private let content: @MainActor () -> Content

    /// `nonisolated` because an explicit initializer on a `View` otherwise infers
    /// `@MainActor` from the conformance, which is exactly the isolation this
    /// type exists to sidestep. Storing a `@MainActor` closure is safe anywhere;
    /// only calling it requires the main actor, and that happens in `body`.
    public nonisolated init(@ViewBuilder content: @escaping @MainActor () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
    }
}
