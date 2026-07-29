// ConnectionPoolView.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Helpers

/// Cross-platform clipboard helper
private enum CrossPlatformClipboard {
    static func copyToClipboard(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

/// Cross-platform text field modifier
private struct CrossPlatformTextFieldModifiers: ViewModifier {
    let autocapitalization: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .textInputAutocapitalization(autocapitalization ? .characters : .never)
            .keyboardType(.asciiCapable)
        #else
        content
        #endif
    }
}

private extension View {
    func crossPlatformTextField(autocapitalize: Bool = false) -> some View {
        modifier(CrossPlatformTextFieldModifiers(autocapitalization: autocapitalize))
    }

    @ViewBuilder
    func crossPlatformNavigationBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        self.navigationBarHidden(hidden)
        #else
        if hidden {
            self.toolbar(.hidden, for: .automatic)
        } else {
            self
        }
        #endif
    }

    @ViewBuilder
    func crossPlatformInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Main view for the Connection Pool app
public struct ConnectionPoolView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    // Observe the design store so theme / appearance / language switches re-render
    // the whole pool UI live (alerts, sheets, and every child screen).
    @ObservedObject private var design = PoolDesign.shared

    public init(viewModel: ConnectionPoolViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Main content
            NavigationStack {
                Group {
                    switch viewModel.currentView {
                    case .home:
                        HomeView(viewModel: viewModel)
                    case .browse:
                        BrowsePoolsView(viewModel: viewModel)
                    case .lobby:
                        PoolLobbyView(viewModel: viewModel)
                    case .chat:
                        // Chat is now a standalone app - show a redirect message
                        ChatRedirectView(viewModel: viewModel)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.currentView)
            }
            .sheet(isPresented: $viewModel.showInvitationSheet) {
                InvitationRequestSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showProfileSettings) {
                ProfileSettingsSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showBlockedDevicesSheet) {
                BlockedDevicesSheet(viewModel: viewModel)
            }
            .alert(poolString("connectionpool.error.title", fallback: "Error"), isPresented: $viewModel.showError) {
                Button(poolString("common.ok", fallback: "OK"), role: .cancel) {}
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }

            // Join code overlay - always in view hierarchy when condition is true
            // This ZStack approach is 100% reliable because it's just conditional view rendering
            if viewModel.showJoinCodeOverlay, let peer = viewModel.pendingJoinPeer {
                JoinCodeOverlayView(
                    peer: peer,
                    codeInput: $viewModel.joinCodeInput,
                    onJoin: { viewModel.confirmJoinWithCode() },
                    onCancel: { viewModel.cancelJoin() }
                )
            }
        }
    }
}

// MARK: - Chat Redirect View

private struct ChatRedirectView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingL) {
            PoolIcon("comments", size: 60, systemFallback: "bubble.left.and.bubble.right.fill")
                .foregroundColor(theme.accent)

            PoolText("connectionpool.chatRedirect.title", fallback: "Pool Chat")
                .font(theme.fontHeading)
                .foregroundColor(theme.textPrimary)

            PoolText("connectionpool.chatRedirect.message", fallback: "Chat is available as a standalone app. Open Pool Chat from the App Launcher.")
                .font(theme.fontBody)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.currentView = .lobby
            } label: {
                PoolText("connectionpool.chatRedirect.backToLobby", fallback: "Back to Lobby")
                    .font(theme.fontBody.weight(.semibold))
                    .padding(.horizontal, theme.spacingXL)
                    .padding(.vertical, theme.spacingM)
                    .background(theme.accent)
                    .foregroundColor(theme.textOnAccent)
                    .clipShape(Capsule())
            }
        }
        .padding(theme.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

// MARK: - Home View

private struct HomeView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showRemoteHostSheet = false

    @State private var showDeleteServerAlert = false

    private var theme: PoolThemeSnapshot { design.snapshot(dark: scheme == .dark) }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacingXL) {
                // Profile button in top right
                HStack {
                    Spacer()
                    ProfileButton(viewModel: viewModel)
                }
                .padding(.horizontal)
                .padding(.top, theme.spacingS)

                // App Icon & Title
                VStack(spacing: theme.spacingM) {
                    ZStack {
                        // Solid accent fill (design mandate: no decorative gradients).
                        Circle()
                            .fill(theme.accent.opacity(0.15))
                            .frame(width: 80, height: 80)

                        PoolIcon("tower-broadcast", size: 36, systemFallback: "antenna.radiowaves.left.and.right")
                            .foregroundColor(theme.accent)
                    }

                    PoolText("connectionpool.home.title", fallback: "Connection Pool")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    PoolText("connectionpool.home.subtitle", fallback: "Connect with nearby devices to chat, call, and play — no internet required.")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // Action Buttons
                VStack(spacing: theme.spacingL) {
                    // Host Pool Button
                    Button {
                        viewModel.currentView = .lobby
                    } label: {
                        HStack(spacing: theme.spacingM) {
                            PoolIcon("wifi", size: 22, systemFallback: "wifi.circle.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                PoolText("connectionpool.home.hostPool", fallback: "Host Pool")
                                    .font(theme.fontBody.weight(.semibold))
                                PoolText("connectionpool.home.hostPoolDesc", fallback: "Create a new pool for others to join")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.textOnAccent.opacity(0.8))
                            }
                            Spacer()
                            PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(theme.accent)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }

                    // Join Pool Button
                    Button {
                        viewModel.startBrowsing()
                    } label: {
                        HStack(spacing: theme.spacingM) {
                            PoolIcon("magnifying-glass", size: 22, systemFallback: "magnifyingglass.circle.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                PoolText("connectionpool.home.joinPool", fallback: "Join Pool")
                                    .font(theme.fontBody.weight(.semibold))
                                PoolText("connectionpool.home.joinPoolDesc", fallback: "Find and join nearby pools")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.textOnAccent.opacity(0.8))
                            }
                            Spacer()
                            PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(theme.success)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }
                }
                .padding(.horizontal)

                // Saved Remote Server (if claimed)
                if let saved = RemotePoolState.load(), saved.isClaimed {
                    VStack(spacing: theme.spacingS) {
                        HStack {
                            Button {
                                viewModel.createRemotePool(serverURL: saved.serverURL)
                            } label: {
                                HStack {
                                    PoolIcon("server", size: 16, systemFallback: "server.rack")
                                        .foregroundColor(theme.success)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(saved.poolName.isEmpty ? poolString("connectionpool.home.myServer", fallback: "My Server") : saved.poolName)
                                            .font(theme.fontBody.weight(.semibold))
                                            .foregroundColor(theme.textPrimary)
                                        Text(saved.serverURL)
                                            .font(theme.fontCaption)
                                            .foregroundColor(theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                                        .foregroundColor(theme.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.startEditingServerURL(from: saved.serverURL)
                            } label: {
                                PoolIcon("pen", size: 15, systemFallback: "pencil")
                                    .foregroundColor(theme.accent)
                                    .padding(theme.spacingS)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                showDeleteServerAlert = true
                            } label: {
                                PoolIcon("trash", size: 15, systemFallback: "trash")
                                    .foregroundColor(theme.danger)
                                    .padding(theme.spacingS)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .background(theme.success.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }
                    .padding(.horizontal)
                }

                // Saved member-side pools — auto-rejoin tiles. Each entry maps to a
                // pool the user has been approved into; tapping skips the invitation
                // flow entirely and reuses the persisted Ed25519 identity.
                if !viewModel.savedRemoteMemberPools.isEmpty {
                    SavedMemberPoolsSection(viewModel: viewModel)
                        .padding(.horizontal)
                }

                // Remote Pool Section
                VStack(spacing: theme.spacingM) {
                    PoolText("connectionpool.home.remotePool", fallback: "Remote Pool")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)

                    VStack(spacing: theme.spacingS + 2) {
                        Button(action: { showRemoteHostSheet = true }) {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("server", size: 15, systemFallback: "server.rack")
                                PoolText("connectionpool.home.hostRemotePool", fallback: "Host Remote Pool")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.accent)

                        Button(action: { viewModel.showRemoteJoinSheet = true }) {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("link", size: 15, systemFallback: "link")
                                PoolText("connectionpool.home.joinViaInvitation", fallback: "Join via Invitation")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.accent)
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.top, theme.spacingXS)

                // Info Section
                HStack(spacing: theme.spacingL) {
                    InfoBadge(icon: "lock", systemFallback: "lock.fill", textKey: "connectionpool.home.badge.encrypted", textFallback: "Encrypted")
                    InfoBadge(icon: "wifi-slash", systemFallback: "wifi.slash", textKey: "connectionpool.home.badge.noInternet", textFallback: "No Internet")
                    InfoBadge(icon: "users", systemFallback: "person.3.fill", textKey: "connectionpool.home.badge.upTo8", textFallback: "Up to 8")
                }
                .padding(.top, theme.spacingXS)
                .padding(.bottom, theme.spacingL)
            }
            .padding()
        }
        .alert(poolString("connectionpool.home.removeServerTitle", fallback: "Remove Server"), isPresented: $showDeleteServerAlert) {
            Button(poolString("connectionpool.home.removeServerButton", fallback: "Remove"), role: .destructive) {
                RemotePoolState.clear()
            }
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(poolString("connectionpool.home.removeServerMessage", fallback: "This will remove the saved relay server. You can re-add it later by claiming the server again."))
        }
        .alert(poolString("connectionpool.home.editServerTitle", fallback: "Edit Server URL"), isPresented: $viewModel.showEditServerURL) {
            TextField("wss://relay.example.com", text: $viewModel.editingServerURL)
                .crossPlatformTextField()
            Button(poolString("common.save", fallback: "Save")) {
                viewModel.updateServerURL(viewModel.editingServerURL)
            }
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {
                viewModel.showEditServerURL = false
            }
        } message: {
            Text(poolString("connectionpool.home.editServerMessage", fallback: "Enter the new relay server URL. Use your tunnel URL (wss://) so friends outside your network can connect."))
        }
        .crossPlatformNavigationBarHidden(true)
        .onAppear {
            viewModel.refreshSavedRemoteMemberPools()
        }
        .sheet(isPresented: $showRemoteHostSheet) {
            RemoteHostSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showRemoteJoinSheet) {
            RemoteJoinSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showInvitationShareSheet) {
            if let invitation = viewModel.currentRemoteInvitation {
                InviteCardShareSheet(viewModel: viewModel, invitation: invitation)
            } else {
                Text(poolString("connectionpool.common.noInvitation", fallback: "No invitation available")).padding()
            }
        }
    }
}

// MARK: - Info Badge

private struct InfoBadge: View {
    let icon: String
    let systemFallback: String
    let textKey: String
    let textFallback: String

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingXS) {
            PoolIcon(icon, size: 11, systemFallback: systemFallback)
            PoolText(textKey, fallback: textFallback)
                .font(theme.fontCaption)
        }
        .foregroundColor(theme.textSecondary)
        .padding(.horizontal, theme.spacingS)
        .padding(.vertical, theme.spacingXS)
        .background(theme.surfaceSecondary)
        .clipShape(Capsule())
    }
}

// MARK: - Host Offline Pill

/// Subtle warning pill rendered in the pool lobby whenever the remote relay reports
/// `pool_host_status { online: false }`. The pool itself is still alive — chat, calls,
/// games, and the relay tunnel exit continue to work — but new joins are gated on the
/// host approving them, so we surface this so users know why the "Invite a Friend"
/// action is disabled.
private struct HostOfflinePill: View {
    let offlineSince: Date?

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    /// Shared relative formatter — instantiating `RelativeDateTimeFormatter` is cheap but
    /// repeating it on every body re-render isn't free, so it lives in a static.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingS) {
            PoolIcon("triangle-exclamation", size: 16, systemFallback: "exclamationmark.triangle.fill")
                .foregroundColor(theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.warning)
                PoolText("connectionpool.hostOffline.message", fallback: "New invitations are paused until the host comes back. Existing chat, calls, and tunneling keep working.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warning.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                .stroke(theme.warning.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if let offlineSince {
            let suffix = Self.relativeFormatter.localizedString(for: offlineSince, relativeTo: Date())
            return poolString("connectionpool.hostOffline.titleSince", fallback: "Host offline · \(suffix)", args: ["time": suffix])
        } else {
            return poolString("connectionpool.hostOffline.title", fallback: "Host offline")
        }
    }
}

// MARK: - Browse Pools View

private struct BrowsePoolsView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    viewModel.goBack()
                } label: {
                    PoolIcon("chevron-left", size: 18, systemFallback: "chevron.left")
                        .foregroundColor(theme.accent)
                }

                Spacer()

                PoolText("connectionpool.browse.title", fallback: "Nearby Pools")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                // Refresh button
                Button {
                    viewModel.refreshBrowsing()
                } label: {
                    PoolIcon("arrow-rotate-right", size: 18, systemFallback: "arrow.clockwise")
                        .foregroundColor(theme.accent)
                }
            }
            .padding()
            .background(theme.surface)

            // Scanning indicator
            if viewModel.poolState == .browsing && viewModel.discoveredPeers.isEmpty {
                VStack(spacing: theme.spacingL) {
                    Spacer()

                    // Animated scanning indicator
                    ZStack {
                        ForEach(0..<3) { index in
                            Circle()
                                .stroke(theme.accent.opacity(0.3), lineWidth: 2)
                                .frame(width: CGFloat(60 + index * 40), height: CGFloat(60 + index * 40))
                        }

                        PoolIcon("tower-broadcast", size: 30, systemFallback: "antenna.radiowaves.left.and.right")
                            .foregroundColor(theme.accent)
                    }

                    PoolText("connectionpool.browse.scanning", fallback: "Scanning for nearby pools…")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)

                    PoolText("connectionpool.browse.scanningHint", fallback: "Make sure other devices are hosting a Connection Pool nearby")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                }
            } else if viewModel.discoveredPeers.isEmpty {
                VStack(spacing: theme.spacingL) {
                    Spacer()

                    PoolIcon("wifi-slash", size: 48, systemFallback: "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(theme.textTertiary)

                    PoolText("connectionpool.browse.noneTitle", fallback: "No pools found")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    PoolText("connectionpool.browse.noneMessage", fallback: "Ask someone to host a pool or try again later")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)

                    Button {
                        viewModel.refreshBrowsing()
                    } label: {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon("arrow-rotate-right", size: 14, systemFallback: "arrow.clockwise")
                            PoolText("connectionpool.browse.scanAgain", fallback: "Scan Again")
                        }
                        .padding(.horizontal, theme.spacingL + 4)
                        .padding(.vertical, theme.spacingS + 2)
                        .background(theme.accent)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(Capsule())
                    }

                    Spacer()
                }
            } else {
                // Pool list
                List {
                    ForEach(viewModel.discoveredPeers) { peer in
                        DiscoveredPoolRow(
                            peer: peer,
                            onJoin: { viewModel.joinPool(peer) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(theme.background)
        .crossPlatformNavigationBarHidden(true)
    }
}

// MARK: - Discovered Pool Row

private struct DiscoveredPoolRow: View {
    let peer: DiscoveredPeer
    let onJoin: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        PoolUserProfile.availableColors[peer.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            // Host avatar (shows emoji if profile available, otherwise icon)
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 50, height: 50)

                if let emoji = peer.avatarEmoji {
                    Text(emoji)
                        .font(.system(size: 24))
                } else {
                    PoolIcon("wifi", size: 22, systemFallback: "wifi.circle.fill")
                        .foregroundColor(avatarColor)
                }
            }

            // Pool info
            VStack(alignment: .leading, spacing: theme.spacingXS) {
                HStack(spacing: theme.spacingXS + 2) {
                    Text(peer.displayName)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    // Show lock icon if pool requires code
                    if peer.hasPoolCode {
                        PoolIcon("lock", size: 11, systemFallback: "lock.fill")
                            .foregroundColor(theme.warning)
                    }
                }

                HStack(spacing: theme.spacingXS + 4) {
                    // Show host name if profile available
                    if let hostName = peer.hostProfile?.displayName {
                        HStack(spacing: theme.spacingXS) {
                            PoolIcon("user", size: 11, systemFallback: "person.fill")
                            Text(hostName)
                        }
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                    } else {
                        HStack(spacing: theme.spacingXS) {
                            PoolIcon("mobile", size: 11, systemFallback: "iphone")
                            Text(peer.id)
                        }
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                    }
                }
            }

            Spacer()

            // Join button
            if peer.isInviting {
                VStack(spacing: theme.spacingXS) {
                    ProgressView()
                    PoolText("connectionpool.browse.joining", fallback: "Joining…")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                }
            } else {
                Button {
                    onJoin()
                } label: {
                    PoolText("connectionpool.browse.join", fallback: "Join")
                        .font(theme.fontBody.weight(.semibold))
                        .padding(.horizontal, theme.spacingL)
                        .padding(.vertical, theme.spacingS)
                        .background(theme.accent)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, theme.spacingS)
    }
}

// MARK: - Pool Lobby View

private struct PoolLobbyView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showHostSettings = false
    @State private var showInviteSheet = false

    private var theme: PoolThemeSnapshot { design.snapshot(dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            lobbyHeader

            // Host setup (if not yet hosting)
            if isInHostSetupMode {
                HostSetupView(viewModel: viewModel)
            } else {
                // Pool Info & Participants
                ScrollView {
                    VStack(spacing: 16) {
                        // Pool Code Card
                        if let poolCode = viewModel.currentSession?.poolCode {
                            PoolCodeCard(code: poolCode)
                        }

                        // Connection Status
                        ConnectionStatusCard(viewModel: viewModel)

                        // Host-offline pill (remote pools only — local Multipeer pools
                        // have no concept of "host offline"; the host either is or isn't
                        // in MC range).
                        if viewModel.transportMode == .remote && !viewModel.hostOnline {
                            HostOfflinePill(offlineSince: viewModel.hostOfflineSince)
                        }

                        // Server URL Card (remote mode, host only)
                        if viewModel.transportMode == .remote && viewModel.isHost {
                            ServerURLCard(viewModel: viewModel)
                        }

                        // Pending Invitations (for host)
                        if viewModel.isHost && !viewModel.pendingInvitations.isEmpty {
                            PendingInvitationsCard(viewModel: viewModel)
                        }

                        // Participants
                        ParticipantsCard(viewModel: viewModel)

                        // Tunnel-Exit host control. Remote pools only — local Multipeer pools have
                        // no relay state. Visible to the host immediately, regardless of how many
                        // guests have joined.
                        if viewModel.transportMode == .remote && viewModel.isHost {
                            TunnelExitHostCard(viewModel: viewModel)
                        }

                        // Route-Through-Relay card. Remote pools only — local Multipeer pools
                        // have no relay. Visibility rules:
                        //   • Host: always visible (host can use their own relay regardless of
                        //     whether they've allowed members).
                        //   • Member: visible only when the host has enabled tunnel-exit, OR
                        //     the member is currently routing (so they can stop). Hiding the
                        //     card from non-host members when the feature is off keeps the
                        //     option from being discoverable to peers the host hasn't authorised.
                        if viewModel.transportMode == .remote
                            && (viewModel.isHost
                                || viewModel.hostTunnelExitEnabled
                                || viewModel.memberRelayActive) {
                            RelayTunnelCard(viewModel: viewModel)
                        }

                        // Quick Actions
                        QuickActionsCard(viewModel: viewModel, showInviteSheet: $showInviteSheet)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .crossPlatformNavigationBarHidden(true)
        .sheet(isPresented: $showHostSettings) {
            HostSettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showInviteSheet) {
            InvitePeersSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showInvitationShareSheet) {
            if let invitation = viewModel.currentRemoteInvitation {
                InviteCardShareSheet(viewModel: viewModel, invitation: invitation)
            } else {
                Text(poolString("connectionpool.common.noInvitation", fallback: "No invitation available")).padding()
            }
        }
        .alert(poolString("connectionpool.home.editServerTitle", fallback: "Edit Server URL"), isPresented: $viewModel.showEditServerURL) {
            TextField("wss://relay.example.com", text: $viewModel.editingServerURL)
                .crossPlatformTextField()
            Button(poolString("common.save", fallback: "Save")) {
                viewModel.updateServerURL(viewModel.editingServerURL)
            }
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {
                viewModel.showEditServerURL = false
            }
        } message: {
            Text(poolString("connectionpool.home.editServerMessage", fallback: "Enter the new relay server URL. Use your tunnel URL (wss://) so friends outside your network can connect."))
        }
    }

    private var lobbyHeader: some View {
        HStack {
            Button {
                viewModel.goBack()
            } label: {
                PoolIcon("chevron-left", size: 18, systemFallback: "chevron.left")
                    .foregroundColor(theme.accent)
            }

            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: theme.spacingXS + 2) {
                    Circle()
                        .fill(headerStatusColor(theme))
                        .frame(width: 8, height: 8)
                    Text(headerStatusText)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)
                }
                if let session = viewModel.currentSession {
                    Text(session.name)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                }
            }

            Spacer()

            if isInHostSetupMode {
                Button {
                    showHostSettings = true
                } label: {
                    PoolIcon("gear", size: 18, systemFallback: "gearshape")
                        .foregroundColor(theme.accent)
                }
            } else {
                PoolIcon("gear", size: 18, systemFallback: "gearshape")
                    .foregroundColor(theme.accent)
                    .opacity(0)
            }
        }
        .padding()
        .background(theme.surface)
    }

    /// Whether user is in host setup mode (before starting to host)
    private var isInHostSetupMode: Bool {
        viewModel.poolState == .idle && viewModel.currentSession == nil
    }

    /// Header status text reflecting the actual connection state
    private var headerStatusText: String {
        let state = viewModel.poolState
        switch state {
        case .idle:
            return poolString("connectionpool.lobby.statusSetup", fallback: "Setup")
        case .hosting:
            let peerCount = viewModel.connectedPeers.count
            // Subtract 1 for host themselves
            let guestCount = max(0, peerCount - 1)
            if guestCount == 0 {
                return poolString("connectionpool.lobby.statusHostingWaiting", fallback: "Hosting · Waiting")
            } else {
                return poolString("connectionpool.lobby.statusHosting", fallback: "Hosting")
            }
        case .browsing:
            return poolString("connectionpool.lobby.statusBrowsing", fallback: "Browsing")
        case .connecting:
            return poolString("connectionpool.lobby.statusConnecting", fallback: "Connecting")
        case .connected:
            return poolString("connectionpool.lobby.statusConnected", fallback: "Connected")
        case .error:
            return poolString("connectionpool.lobby.statusError", fallback: "Error")
        }
    }

    /// Header status color reflecting the actual connection state
    private func headerStatusColor(_ theme: PoolThemeSnapshot) -> Color {
        let state = viewModel.poolState
        switch state {
        case .idle:
            return theme.textTertiary
        case .hosting:
            let peerCount = viewModel.connectedPeers.count
            let guestCount = max(0, peerCount - 1)
            // Warning tint while waiting for participants, success once connected.
            return guestCount == 0 ? theme.warning : theme.success
        case .browsing, .connecting:
            return theme.warning
        case .connected:
            return theme.success
        case .error:
            return theme.danger
        }
    }
}

// MARK: - Host Setup View

private struct HostSetupView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        ScrollView {
            VStack(spacing: theme.spacingXL) {
                // Pool Name
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    PoolText("connectionpool.setup.poolName", fallback: "Pool Name")
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    TextField(poolString("connectionpool.setup.poolNamePlaceholder", fallback: "Enter pool name"), text: $viewModel.poolName)
                        .textFieldStyle(.roundedBorder)
                }

                // Max Peers
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    PoolText("connectionpool.setup.maxParticipants", fallback: "Maximum Participants")
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    Picker("Max Peers", selection: $viewModel.maxPeers) {
                        ForEach(2...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Options
                VStack(spacing: theme.spacingM) {
                    Toggle(isOn: $viewModel.requireEncryption) {
                        HStack {
                            PoolIcon("lock", size: 15, systemFallback: "lock.fill")
                                .foregroundColor(theme.success)
                            PoolText("connectionpool.setup.requireEncryption", fallback: "Require Encryption")
                                .foregroundColor(theme.textPrimary)
                        }
                    }

                    Toggle(isOn: $viewModel.autoAcceptPeers) {
                        HStack {
                            PoolIcon("user-plus", size: 15, systemFallback: "person.badge.plus")
                                .foregroundColor(theme.accent)
                            PoolText("connectionpool.setup.autoAccept", fallback: "Auto-accept Join Requests")
                                .foregroundColor(theme.textPrimary)
                        }
                    }
                }
                .padding()
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))

                // Start Hosting Button
                Button {
                    viewModel.startHosting()
                } label: {
                    HStack(spacing: theme.spacingS) {
                        PoolIcon("tower-broadcast", size: 16, systemFallback: "antenna.radiowaves.left.and.right")
                        PoolText("connectionpool.setup.startHosting", fallback: "Start Hosting")
                    }
                    .font(theme.fontBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(theme.accent)
                    .foregroundStyle(theme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                }
            }
            .padding()
        }
    }
}

// MARK: - Pool Code Card

private struct PoolCodeCard: View {
    let code: String
    @State private var copied = false

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingM) {
            PoolText("connectionpool.code.share", fallback: "Share this code to invite others")
                .font(theme.fontCaption)
                .foregroundColor(theme.textSecondary)

            Text(code)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundColor(theme.textPrimary)

            Button {
                CrossPlatformClipboard.copyToClipboard(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                HStack(spacing: theme.spacingXS + 2) {
                    PoolIcon(copied ? "check" : "copy", size: 14, systemFallback: copied ? "checkmark" : "doc.on.doc")
                    Text(copied
                         ? poolString("connectionpool.code.copied", fallback: "Copied!")
                         : poolString("connectionpool.code.copy", fallback: "Copy Code"))
                }
                .font(theme.fontBody.weight(.semibold))
                .padding(.horizontal, theme.spacingL)
                .padding(.vertical, theme.spacingS)
                .background(copied ? theme.success : theme.accent)
                .foregroundStyle(theme.textOnAccent)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

// MARK: - Server URL Card

private struct ServerURLCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack {
                PoolIcon("server", size: 15, systemFallback: "server.rack")
                    .foregroundColor(theme.accent)
                PoolText("connectionpool.server.relayServer", fallback: "Relay Server")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button {
                    viewModel.startEditingServerURL()
                } label: {
                    HStack(spacing: theme.spacingXS) {
                        PoolIcon("pen", size: 11, systemFallback: "pencil")
                        PoolText("connectionpool.server.edit", fallback: "Edit")
                    }
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, theme.spacingS + 2)
                    .padding(.vertical, theme.spacingXS + 1)
                    .background(theme.accent.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(viewModel.serverURL)
                .font(theme.fontCaption)
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let confirmation = viewModel.serverURLUpdateConfirmation {
                HStack(spacing: theme.spacingXS) {
                    PoolIcon("circle-check", size: 12, systemFallback: "checkmark.circle.fill")
                        .foregroundColor(theme.success)
                    Text(confirmation)
                        .foregroundColor(theme.success)
                }
                .font(theme.fontCaption)
                .transition(.opacity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: viewModel.serverURLUpdateConfirmation)
    }
}

// MARK: - Connection Status Card

// MARK: - Tunnel Exit Card (Host)

/// Host-side card that controls whether pool members can route their browser traffic
/// through the StealthRelay server's internet connection. The host's iPhone is NOT in
/// the data path — the relay opens the upstream sockets. This toggle is the per-pool
/// approval gate; the relay's server-side `tunnel.enabled` flag must also be on.
private struct TunnelExitHostCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack(spacing: theme.spacingS) {
                PoolIcon("shield-halved", size: 16, systemFallback: viewModel.hostTunnelExitEnabled ? "shield.checkerboard" : "shield.lefthalf.filled")
                    .foregroundColor(viewModel.hostTunnelExitEnabled ? theme.success : theme.accent)
                PoolText("connectionpool.tunnelExit.title", fallback: "Allow Members to Use Relay Exit")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.hostTunnelExitEnabled },
                    set: { newValue in
                        Task { await viewModel.setHostTunnelExitEnabled(newValue) }
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }

            if viewModel.hostTunnelExitEnabled {
                PoolText("connectionpool.tunnelExit.onDesc", fallback: "Members of this pool can route their browser traffic through the relay server's internet connection. The relay's IP becomes the exit address — your phone is not in the data path.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
            } else {
                PoolText("connectionpool.tunnelExit.offDesc", fallback: "When enabled, members of this pool can route their browser traffic through the relay's internet connection. The relay must also have tunnel-exit turned on in its server config for this to take effect.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
            }
        }
        .padding()
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

// MARK: - Relay Tunnel Card (Member)

/// Member-side card that lets the user opt in to tunnel their device traffic through the
/// pool host. Visible only when (a) we are a member of a remote pool, and (b) the host has
/// enabled `tunnelExitEnabled`. The card delegates the actual `ProxyManager.startRelayMode`
/// call to the host app via `viewModel.onStartMemberRelayMode` so this package stays free
/// of a `Core` dependency.
private struct RelayTunnelCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack(spacing: theme.spacingS) {
                PoolIcon("shield-halved", size: 16, systemFallback: viewModel.memberRelayActive ? "shield.checkerboard" : "shield.lefthalf.filled")
                    .foregroundColor(viewModel.memberRelayActive ? theme.success : theme.accent)
                PoolText("connectionpool.relayTunnel.title", fallback: "Tunnel Through Host")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
            }

            if viewModel.memberRelayActive {
                if let name = viewModel.memberRelayHostName {
                    Text(poolString("connectionpool.relayTunnel.through", fallback: "Tunnelling through \(name)", args: ["host": name]))
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                } else {
                    PoolText("connectionpool.relayTunnel.active", fallback: "Tunnelling active")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                }
                Button(role: .destructive) {
                    Task { await viewModel.onStopMemberRelayMode?() }
                } label: {
                    HStack(spacing: theme.spacingS) {
                        if viewModel.memberRelayPending {
                            ProgressView().controlSize(.small)
                            PoolText("connectionpool.relayTunnel.disconnecting", fallback: "Disconnecting…")
                        } else {
                            PoolText("connectionpool.relayTunnel.stop", fallback: "Stop Tunnelling")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(theme.danger)
                .disabled(viewModel.memberRelayPending)
            } else {
                PoolText("connectionpool.relayTunnel.desc", fallback: "Route your browser traffic through the relay server. Useful when you want a different exit IP than your home network.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
                Button {
                    Task { await viewModel.onStartMemberRelayMode?() }
                } label: {
                    HStack(spacing: theme.spacingS) {
                        if viewModel.memberRelayPending {
                            ProgressView().controlSize(.small).tint(theme.textOnAccent)
                            PoolText("connectionpool.relayTunnel.connecting", fallback: "Connecting to relay…")
                        } else {
                            PoolText("connectionpool.relayTunnel.start", fallback: "Tunnel My Traffic Through Relay")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(viewModel.memberRelayPending)
            }
        }
        .padding()
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

private struct ConnectionStatusCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack {
            // Status indicator
            HStack(spacing: theme.spacingS) {
                Circle()
                    .fill(statusColor(theme))
                    .frame(width: 10, height: 10)

                Text(statusText)
                    .font(theme.fontBody)
                    .foregroundColor(theme.textPrimary)
            }

            Spacer()

            // Encryption badge
            if viewModel.currentSession?.isEncrypted == true {
                HStack(spacing: theme.spacingXS) {
                    PoolIcon("lock", size: 11, systemFallback: "lock.fill")
                    PoolText("connectionpool.home.badge.encrypted", fallback: "Encrypted")
                }
                .font(theme.fontCaption)
                .foregroundColor(theme.success)
                .padding(.horizontal, theme.spacingS + 2)
                .padding(.vertical, theme.spacingXS + 1)
                .background(theme.success.opacity(0.15))
                .clipShape(Capsule())
            }
        }
        .padding()
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }

    /// Number of connected guests (peers excluding the host)
    private var guestCount: Int {
        let peerCount = viewModel.connectedPeers.count
        // If hosting, subtract 1 for the host themselves
        return viewModel.isHost ? max(0, peerCount - 1) : peerCount
    }

    /// Status text that reflects actual connection state with participant context
    private var statusText: String {
        let state = viewModel.poolState
        switch state {
        case .idle:
            return poolString("connectionpool.status.notConnected", fallback: "Not Connected")
        case .hosting:
            if guestCount == 0 {
                return poolString("connectionpool.status.hostingWaiting", fallback: "Hosting · Waiting for participants")
            } else {
                let word = guestCount == 1
                    ? poolString("connectionpool.status.participant", fallback: "participant")
                    : poolString("connectionpool.status.participants", fallback: "participants")
                return poolString("connectionpool.status.hostingCount", fallback: "Hosting · \(guestCount) \(word)", args: ["count": "\(guestCount)", "unit": word])
            }
        case .browsing:
            return poolString("connectionpool.status.lookingForPools", fallback: "Looking for Pools")
        case .connecting:
            return poolString("connectionpool.status.connecting", fallback: "Connecting…")
        case .connected:
            return poolString("connectionpool.status.connected", fallback: "Connected")
        case .error(let message):
            return poolString("connectionpool.status.error", fallback: "Error: \(message)", args: ["message": message])
        }
    }

    private func statusColor(_ theme: PoolThemeSnapshot) -> Color {
        switch viewModel.poolState {
        case .hosting:
            // Warning while waiting for participants, success once connected.
            return guestCount == 0 ? theme.warning : theme.success
        case .connected:
            return theme.success
        case .connecting, .browsing:
            return theme.warning
        case .idle:
            return theme.textTertiary
        case .error:
            return theme.danger
        }
    }
}

// MARK: - Pending Invitations Card

private struct PendingInvitationsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack {
                PoolIcon("user-clock", size: 16, systemFallback: "person.badge.clock")
                    .foregroundColor(theme.warning)
                PoolText("connectionpool.pending.title", fallback: "Pending Requests")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("\(viewModel.pendingInvitations.count)")
                    .font(theme.fontCaption.weight(.bold))
                    .foregroundColor(theme.textOnAccent)
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS)
                    .background(theme.warning)
                    .clipShape(Capsule())
            }

            ForEach(viewModel.pendingInvitations) { invitation in
                HStack(spacing: theme.spacingM) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(theme.warning.opacity(0.2))
                            .frame(width: 40, height: 40)

                        Text(String(invitation.displayName.prefix(1)).uppercased())
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.warning)
                    }

                    // Name
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.displayName)
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)
                        PoolText("connectionpool.pending.wantsToJoin", fallback: "Wants to join")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    // Block/Reject/Accept buttons
                    HStack(spacing: theme.spacingS) {
                        Button {
                            viewModel.blockPendingPeer(invitation)
                        } label: {
                            PoolIcon("hand", size: 14, systemFallback: "hand.raised.fill")
                                .foregroundColor(theme.textOnAccent)
                                .frame(width: 32, height: 32)
                                .background(theme.warning)
                                .clipShape(Circle())
                        }

                        Button {
                            viewModel.rejectInvitation(invitation)
                        } label: {
                            PoolIcon("xmark", size: 14, systemFallback: "xmark")
                                .foregroundColor(theme.textOnAccent)
                                .frame(width: 32, height: 32)
                                .background(theme.danger)
                                .clipShape(Circle())
                        }

                        Button {
                            viewModel.acceptInvitation(invitation)
                        } label: {
                            PoolIcon("check", size: 14, systemFallback: "checkmark")
                                .foregroundColor(theme.textOnAccent)
                                .frame(width: 32, height: 32)
                                .background(theme.success)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.vertical, theme.spacingXS)
            }
        }
        .padding()
        .background(theme.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

// MARK: - Participants Card

private struct ParticipantsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    // Stable per-peer avatar identity palette (no purple/indigo). Identity colors,
    // not chrome — indexed by the peer's persisted avatar index.
    private let avatarColors: [Color] = PoolUserProfile.availableColors

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack {
                PoolText("connectionpool.participants.title", fallback: "Participants")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("\(viewModel.connectedPeers.count)/\(viewModel.currentSession?.maxPeers ?? 8)")
                    .font(theme.fontCaption.weight(.bold))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS)
                    .background(theme.surfaceSecondary)
                    .clipShape(Capsule())
            }

            if viewModel.connectedPeers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: theme.spacingS) {
                        PoolIcon("user-slash", size: 28, systemFallback: "person.slash")
                            .foregroundColor(theme.textTertiary)
                        PoolText("connectionpool.participants.none", fallback: "No participants yet")
                            .font(theme.fontBody)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.vertical, theme.spacingL + 4)
                    Spacer()
                }
            } else {
                ForEach(viewModel.connectedPeers, id: \.id) { peer in
                    ParticipantRow(
                        peer: peer,
                        isLocalPeer: peer.id == viewModel.poolManager.localPeerID,
                        avatarColors: avatarColors,
                        isHost: viewModel.isHost,
                        hostOnline: viewModel.hostOnline,
                        onKick: { viewModel.kickPeer(peer) },
                        onBlock: { viewModel.blockPeer(peer) }
                    )
                }
            }
        }
        .padding()
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

// MARK: - Participant Row

private struct ParticipantRow: View {
    let peer: Peer
    let isLocalPeer: Bool
    let avatarColors: [Color]
    let isHost: Bool
    /// Authoritative host-presence flag (from `pool_host_status`). The relay
    /// deliberately does not emit `peer_left` for the host on disconnect, so
    /// `peer.status` cannot be trusted for the host row — consult this instead.
    let hostOnline: Bool
    let onKick: () -> Void
    let onBlock: () -> Void

    /// `true` when this row represents the pool host AND the host is currently offline.
    private var hostShownAsOffline: Bool {
        peer.isHost && !hostOnline
    }

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var avatarColor: Color {
        avatarColors[peer.avatarColorIndex % avatarColors.count]
    }

    /// FA status icon (name, SF-Symbol fallback) for the peer's connection state.
    private var statusIcon: (String, String) {
        if hostShownAsOffline { return ("wifi-slash", "wifi.slash") }
        switch peer.status {
        case .connecting: return ("circle-notch", "circle.dotted")
        case .connected: return ("circle-check", "checkmark.circle.fill")
        case .disconnected: return ("circle-xmark", "xmark.circle.fill")
        case .notConnected: return ("circle", "circle")
        }
    }

    private var statusText: String {
        if hostShownAsOffline { return poolString("connectionpool.participants.offline", fallback: "Offline") }
        switch peer.status {
        case .connecting: return poolString("connectionpool.status.connecting", fallback: "Connecting…")
        case .connected: return poolString("connectionpool.status.connected", fallback: "Connected")
        case .disconnected: return poolString("connectionpool.participants.disconnected", fallback: "Disconnected")
        case .notConnected: return poolString("connectionpool.status.notConnected", fallback: "Not Connected")
        }
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            // Avatar - shows emoji if profile available
            ZStack {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 40, height: 40)

                if let emoji = peer.avatarEmoji {
                    Text(emoji)
                        .font(.system(size: 20))
                } else {
                    Text(String(peer.effectiveDisplayName.prefix(1)).uppercased())
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textOnAccent)
                }
            }

            // Name & Status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.spacingXS + 2) {
                    Text(peer.effectiveDisplayName)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    if peer.isHost {
                        PoolText("connectionpool.participants.host", fallback: "HOST")
                            .font(.caption2.bold())
                            .foregroundColor(theme.textOnAccent)
                            .padding(.horizontal, theme.spacingXS + 2)
                            .padding(.vertical, 2)
                            .background(theme.warning)
                            .clipShape(Capsule())
                    }

                    if isLocalPeer {
                        PoolText("connectionpool.participants.you", fallback: "YOU")
                            .font(.caption2.bold())
                            .foregroundColor(theme.textOnAccent)
                            .padding(.horizontal, theme.spacingXS + 2)
                            .padding(.vertical, 2)
                            .background(theme.accent)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: theme.spacingXS) {
                    PoolIcon(statusIcon.0, size: 11, systemFallback: statusIcon.1)
                    Text(statusText)
                        .font(theme.fontCaption)
                }
                .foregroundColor(
                    hostShownAsOffline
                        ? theme.textSecondary
                        : (peer.status == .connected ? theme.success : theme.textSecondary)
                )
            }

            Spacer()

            // Block & Kick buttons (for host, not for self or other host)
            if isHost && !isLocalPeer && !peer.isHost {
                Button {
                    onBlock()
                } label: {
                    PoolIcon("hand", size: 15, systemFallback: "hand.raised.fill")
                        .foregroundColor(theme.warning)
                        .padding(theme.spacingS)
                        .background(theme.warning.opacity(0.1))
                        .clipShape(Circle())
                }

                Button {
                    onKick()
                } label: {
                    PoolIcon("user-minus", size: 15, systemFallback: "person.badge.minus")
                        .foregroundColor(theme.danger)
                        .padding(theme.spacingS)
                        .background(theme.danger.opacity(0.1))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.vertical, theme.spacingXS)
    }
}

// MARK: - Quick Actions Card

private struct QuickActionsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Binding var showInviteSheet: Bool
    @State private var showGamesSheet = false

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingM) {
            // Invite button (for host, local mode)
            if viewModel.isHost && viewModel.transportMode == .local {
                Button {
                    showInviteSheet = true
                } label: {
                    HStack {
                        PoolIcon("user-plus", size: 18, systemFallback: "person.badge.plus")
                        PoolText("connectionpool.actions.invitePeers", fallback: "Invite Peers")
                            .font(theme.fontBody.weight(.semibold))
                        Spacer()
                        PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                    }
                    .padding()
                    .background(theme.success.opacity(0.1))
                    .foregroundColor(theme.success)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                }
            }

            // Remote mode invitation actions (available to any connected member)
            if viewModel.transportMode == .remote {
                // The host's own client can always issue invitations — their own auth is
                // the gate, and if they're sitting in front of the UI, they're online.
                // Members can only request invitation links while the host is online,
                // since the relay needs the host to approve new joins.
                let inviteDisabled = !viewModel.isHost && !viewModel.hostOnline

                // Create/request invitation link
                Button {
                    viewModel.requestInviteLink()
                } label: {
                    HStack {
                        PoolIcon("link", size: 18, systemFallback: "link.badge.plus")
                        PoolText("connectionpool.actions.inviteFriend", fallback: "Invite a Friend")
                            .font(theme.fontBody.weight(.semibold))
                        Spacer()
                        PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                    }
                    .padding()
                    .background((inviteDisabled ? theme.textTertiary : theme.success).opacity(0.1))
                    .foregroundColor(inviteDisabled ? theme.textTertiary : theme.success)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                }
                .disabled(inviteDisabled)

                if inviteDisabled {
                    PoolText("connectionpool.actions.hostMustBeOnline", fallback: "Host must be online to issue invitations.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, theme.spacingXS)
                }

                // Active invitations list (host only)
                if viewModel.isHost && !viewModel.remoteInvitations.isEmpty {
                    RemoteInvitationsCard(viewModel: viewModel)
                }
            }

            // Open Pool Chat button
            Button {
                // Signal to open Pool Chat app
                viewModel.openPoolChat()
            } label: {
                HStack {
                    PoolIcon("comments", size: 18, systemFallback: "bubble.left.and.bubble.right.fill")
                    PoolText("connectionpool.actions.openChat", fallback: "Open Pool Chat")
                        .font(theme.fontBody.weight(.semibold))
                    Spacer()
                    PoolIcon("arrow-up-right-from-square", size: 12, systemFallback: "arrow.up.forward.app")
                }
                .padding()
                .background(theme.accent.opacity(0.1))
                .foregroundColor(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            }

            // Games button
            Button {
                showGamesSheet = true
            } label: {
                HStack {
                    PoolIcon("gamepad", size: 18, systemFallback: "gamecontroller.fill")
                    PoolText("connectionpool.actions.playGames", fallback: "Play Games")
                        .font(theme.fontBody.weight(.semibold))
                    Spacer()
                    PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                }
                .padding()
                .background(theme.info.opacity(0.1))
                .foregroundColor(theme.info)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            }

            // Blocked Devices button (host only)
            if viewModel.isHost {
                Button {
                    viewModel.blockedDevices = viewModel.poolManager.blockedDevices
                    viewModel.showBlockedDevicesSheet = true
                } label: {
                    HStack {
                        PoolIcon("hand", size: 18, systemFallback: "hand.raised.fill")
                        PoolText("connectionpool.actions.blockedDevices", fallback: "Blocked Devices")
                            .font(theme.fontBody.weight(.semibold))
                        Spacer()
                        if !viewModel.blockedDevices.isEmpty {
                            Text("\(viewModel.blockedDevices.count)")
                                .font(theme.fontCaption.weight(.bold))
                                .foregroundColor(theme.textOnAccent)
                                .padding(.horizontal, theme.spacingS)
                                .padding(.vertical, theme.spacingXS)
                                .background(theme.warning)
                                .clipShape(Capsule())
                        }
                        PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                    }
                    .padding()
                    .background(theme.warning.opacity(0.1))
                    .foregroundColor(theme.warning)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                }
            }

            // Disconnect Button.
            //
            // For remote *members* this routes through `leaveRemoteMemberPool()`,
            // which deletes the persistent Keychain identity + saved record so the
            // pool no longer auto-rejoins on next launch. We confirm via an alert
            // because the action is destructive (the user must obtain a new
            // invitation to come back). Hosts and local-mode users get the original
            // synchronous disconnect.
            DisconnectControl(viewModel: viewModel)
        }
        .sheet(isPresented: $showGamesSheet) {
            GamesSelectionSheet(viewModel: viewModel)
        }
    }
}

/// Shared "Close Pool" / "Leave Pool" button. Encapsulates the confirm-alert
/// state so the parent body stays a clean expression tree.
private struct DisconnectControl: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showLeaveConfirmation = false

    private var isRemoteMember: Bool {
        viewModel.transportMode == .remote && !viewModel.isHost
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button {
            if isRemoteMember {
                showLeaveConfirmation = true
            } else {
                viewModel.disconnect()
            }
        } label: {
            HStack {
                PoolIcon("circle-xmark", size: 18, systemFallback: "xmark.circle.fill")
                Text(viewModel.isHost
                     ? poolString("connectionpool.actions.closePool", fallback: "Close Pool")
                     : poolString("connectionpool.actions.leavePool", fallback: "Leave Pool"))
                    .font(theme.fontBody.weight(.semibold))
                Spacer()
            }
            .padding()
            .background(theme.danger.opacity(0.1))
            .foregroundColor(theme.danger)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        }
        .alert(poolString("connectionpool.leave.title", fallback: "Leave this pool?"), isPresented: $showLeaveConfirmation) {
            Button(poolString("connectionpool.actions.leavePool", fallback: "Leave Pool"), role: .destructive) {
                viewModel.leaveRemoteMemberPool()
            }
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(poolString("connectionpool.leave.message", fallback: "You'll need a new invitation to join again."))
        }
    }
}

// MARK: - Games Selection Sheet

private struct GamesSelectionSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            VStack(spacing: theme.spacingL + 4) {
                // Header info
                VStack(spacing: theme.spacingS) {
                    PoolIcon("gamepad", size: 40, systemFallback: "gamecontroller.fill")
                        .foregroundColor(theme.info)

                    PoolText("connectionpool.games.title", fallback: "Multiplayer Games")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    PoolText("connectionpool.games.subtitle", fallback: "Challenge someone in your pool to a game!")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Games list
                VStack(spacing: theme.spacingM) {
                    // Chain Reaction
                    GameSelectionRow(
                        title: "Chain Reaction",
                        subtitleKey: "connectionpool.games.chainReaction.desc",
                        subtitleFallback: "Place orbs and create chain reactions",
                        icon: "atom",
                        systemFallback: "circle.hexagongrid.fill",
                        color: .orange,
                        playersKey: "connectionpool.games.players2",
                        playersFallback: "2 players"
                    ) {
                        viewModel.openGame(.chainReaction)
                        dismiss()
                    }

                    // Connect Four
                    GameSelectionRow(
                        title: "Connect Four",
                        subtitleKey: "connectionpool.games.connectFour.desc",
                        subtitleFallback: "Drop discs to connect 4 in a row",
                        icon: "table-cells",
                        systemFallback: "circle.grid.3x3.fill",
                        color: .blue,
                        playersKey: "connectionpool.games.players2",
                        playersFallback: "2 players"
                    ) {
                        viewModel.openGame(.connectFour)
                        dismiss()
                    }

                    // Chess
                    GameSelectionRow(
                        title: "Chess",
                        subtitleKey: "connectionpool.games.chess.desc",
                        subtitleFallback: "The classic game of strategy",
                        icon: "chess",
                        systemFallback: "crown.fill",
                        color: .brown,
                        playersKey: "connectionpool.games.players2",
                        playersFallback: "2 players"
                    ) {
                        viewModel.openGame(.chess)
                        dismiss()
                    }

                    // Prompt Party
                    GameSelectionRow(
                        title: "Prompt Party",
                        subtitleKey: "connectionpool.games.promptParty.desc",
                        subtitleFallback: "AI-powered party game with creative prompts",
                        icon: "comments",
                        systemFallback: "bubble.left.and.bubble.right.fill",
                        color: .pink,
                        playersKey: "connectionpool.games.players2to8",
                        playersFallback: "2-8 players"
                    ) {
                        viewModel.openGame(.promptParty)
                        dismiss()
                    }

                    // Ludo
                    GameSelectionRow(
                        title: "Ludo",
                        subtitleKey: "connectionpool.games.ludo.desc",
                        subtitleFallback: "Classic board game with dice rolling",
                        icon: "dice",
                        systemFallback: "dice.fill",
                        color: .green,
                        playersKey: "connectionpool.games.players2to4",
                        playersFallback: "2-4 players"
                    ) {
                        viewModel.openGame(.ludo)
                        dismiss()
                    }
                }
                .padding(.horizontal)

                // Note about multiplayer
                HStack(spacing: theme.spacingS) {
                    PoolIcon("circle-info", size: 15, systemFallback: "info.circle.fill")
                        .foregroundColor(theme.accent)
                    PoolText("connectionpool.games.note", fallback: "Select \"vs Player\" mode in the game to play with pool members")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                }
                .padding()
                .background(theme.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                .padding(.horizontal)

                Spacer()
            }
            .background(theme.background)
            .navigationTitle(poolString("connectionpool.actions.playGames", fallback: "Play Games"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.close", fallback: "Close")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Game Selection Row

private struct GameSelectionRow: View {
    let title: String
    let subtitleKey: String
    let subtitleFallback: String
    let icon: String
    let systemFallback: String
    let color: Color
    let playersKey: String
    let playersFallback: String
    let action: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button(action: action) {
            HStack(spacing: theme.spacingL) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                        .fill(color.opacity(0.2))
                        .frame(width: 56, height: 56)

                    PoolIcon(icon, size: 24, systemFallback: systemFallback)
                        .foregroundColor(color)
                }

                // Info
                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    Text(title)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    PoolText(subtitleKey, fallback: subtitleFallback)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)

                    HStack(spacing: theme.spacingXS) {
                        PoolIcon("users", size: 10, systemFallback: "person.2.fill")
                        PoolText(playersKey, fallback: playersFallback)
                            .font(.caption2)
                    }
                    .foregroundColor(color)
                }

                Spacer()

                PoolIcon("chevron-right", size: 14, systemFallback: "chevron.right")
                    .foregroundColor(theme.textSecondary)
            }
            .padding()
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Host Settings Sheet

private struct HostSettingsSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(poolString("connectionpool.settings.poolSettings", fallback: "Pool Settings")) {
                    TextField(poolString("connectionpool.setup.poolName", fallback: "Pool Name"), text: $viewModel.poolName)

                    Picker(poolString("connectionpool.settings.maxParticipants", fallback: "Max Participants"), selection: $viewModel.maxPeers) {
                        ForEach(2...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                }

                Section(poolString("connectionpool.settings.security", fallback: "Security")) {
                    Toggle(poolString("connectionpool.setup.requireEncryption", fallback: "Require Encryption"), isOn: $viewModel.requireEncryption)
                    Toggle(poolString("connectionpool.setup.autoAccept", fallback: "Auto-accept Join Requests"), isOn: $viewModel.autoAcceptPeers)
                }

                // Note: the relay-exit toggle lives on the main pool detail page in
                // `TunnelExitHostCard`. The duplicate that used to live here was removed
                // so there is one canonical entry point.
            }
            .navigationTitle(poolString("connectionpool.settings.poolSettings", fallback: "Pool Settings"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(poolString("common.done", fallback: "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Invitation Request Sheet

private struct InvitationRequestSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            VStack(spacing: theme.spacingXL) {
                if let invitation = viewModel.currentInvitation {
                    // Invitation icon
                    ZStack {
                        Circle()
                            .fill(theme.accent.opacity(0.1))
                            .frame(width: 100, height: 100)

                        PoolIcon("user-plus", size: 40, systemFallback: "person.badge.plus")
                            .foregroundColor(theme.accent)
                    }

                    // Invitation text
                    VStack(spacing: theme.spacingS) {
                        PoolText("connectionpool.joinRequest.title", fallback: "Join Request")
                            .font(theme.fontHeading)
                            .foregroundColor(theme.textPrimary)

                        Text(poolString("connectionpool.joinRequest.message", fallback: "\(invitation.displayName) wants to join your pool", args: ["name": invitation.displayName]))
                            .font(theme.fontBody)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    // Action buttons
                    VStack(spacing: theme.spacingM) {
                        Button {
                            viewModel.acceptInvitation(invitation)
                            dismiss()
                        } label: {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("check", size: 16, systemFallback: "checkmark")
                                PoolText("connectionpool.joinRequest.accept", fallback: "Accept")
                            }
                            .font(theme.fontBody.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(theme.success)
                            .foregroundStyle(theme.textOnAccent)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        }

                        Button {
                            viewModel.rejectInvitation(invitation)
                            dismiss()
                        } label: {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("xmark", size: 16, systemFallback: "xmark")
                                PoolText("connectionpool.joinRequest.decline", fallback: "Decline")
                            }
                            .font(theme.fontBody.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(theme.surfaceSecondary)
                            .foregroundColor(theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        }
                    }
                } else {
                    PoolText("connectionpool.joinRequest.none", fallback: "No pending invitation")
                        .foregroundColor(theme.textSecondary)
                }
            }
            .padding()
            .background(theme.background)
            .navigationTitle("")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Join Code Overlay View

/// A centered modal card for entering pool join codes.
/// Uses ZStack overlay approach instead of .sheet() for 100% reliable presentation.
private struct JoinCodeOverlayView: View {
    let peer: DiscoveredPeer
    @Binding var codeInput: String
    let onJoin: () -> Void
    let onCancel: () -> Void

    @FocusState private var isCodeFieldFocused: Bool
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = design.snapshot(dark: colorScheme == .dark)
        ZStack {
            // Dimmed background - tapping dismisses
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Modal card
            VStack(spacing: theme.spacingXL) {
                // Lock icon
                ZStack {
                    Circle()
                        .fill(theme.warning.opacity(0.15))
                        .frame(width: 72, height: 72)

                    PoolIcon("lock", size: 32, systemFallback: "lock.fill")
                        .foregroundColor(theme.warning)
                }

                // Title and pool name
                VStack(spacing: theme.spacingXS + 2) {
                    PoolText("connectionpool.joinCode.title", fallback: "Enter Pool Code")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    Text(poolString("connectionpool.joinCode.toJoin", fallback: "to join \"\(peer.displayName)\"", args: ["name": peer.displayName]))
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                }

                // Code input field
                VStack(spacing: theme.spacingXS + 2) {
                    TextField("XXXXXX", text: $codeInput)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .crossPlatformTextField(autocapitalize: true)
                        .autocorrectionDisabled()
                        .focused($isCodeFieldFocused)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                        .background(theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        .onChange(of: codeInput) { _, newValue in
                            // Limit to 6 characters and uppercase
                            let filtered = String(newValue.uppercased().prefix(6))
                            if filtered != newValue {
                                codeInput = filtered
                            }
                        }

                    PoolText("connectionpool.joinCode.hint", fallback: "Ask the host for the 6-character code")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                }

                // Action buttons
                HStack(spacing: theme.spacingM) {
                    // Cancel button
                    Button {
                        onCancel()
                    } label: {
                        PoolText("common.cancel", fallback: "Cancel")
                            .font(theme.fontBody.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(theme.surfaceSecondary)
                            .foregroundColor(theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }

                    // Join button
                    Button {
                        onJoin()
                    } label: {
                        HStack(spacing: theme.spacingXS + 2) {
                            PoolIcon("check", size: 14, systemFallback: "checkmark")
                            PoolText("connectionpool.browse.join", fallback: "Join")
                        }
                        .font(theme.fontBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(codeInput.count == 6 ? theme.success : theme.textTertiary)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }
                    .disabled(codeInput.count != 6)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                    .fill(theme.surfaceElevated)
                    .shadow(color: theme.shadow.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 32)
            .onAppear {
                // Delay focus to ensure the view is fully rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isCodeFieldFocused = true
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.easeOut(duration: 0.2), value: codeInput)
    }
}

// MARK: - Invite Peers Sheet

private struct InvitePeersSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            VStack(spacing: theme.spacingXL) {
                // Pool Code section
                if let poolCode = viewModel.currentSession?.poolCode {
                    VStack(spacing: theme.spacingM) {
                        PoolText("connectionpool.invite.shareCode", fallback: "Share this code")
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)

                        Text(poolCode)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundColor(theme.textPrimary)

                        Button {
                            CrossPlatformClipboard.copyToClipboard(poolCode)
                        } label: {
                            HStack(spacing: theme.spacingXS + 2) {
                                PoolIcon("copy", size: 14, systemFallback: "doc.on.doc")
                                PoolText("connectionpool.code.copy", fallback: "Copy Code")
                            }
                            .padding(.horizontal, theme.spacingL)
                            .padding(.vertical, theme.spacingS + 2)
                            .background(theme.accent)
                            .foregroundStyle(theme.textOnAccent)
                            .clipShape(Capsule())
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                }

                Divider()

                // Instructions
                VStack(alignment: .leading, spacing: theme.spacingL) {
                    PoolText("connectionpool.invite.howTo", fallback: "How to invite")
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)

                    InviteStep(number: 1, textKey: "connectionpool.invite.step1", textFallback: "Share the pool code with friends")
                    InviteStep(number: 2, textKey: "connectionpool.invite.step2", textFallback: "They open Connection Pool on their device")
                    InviteStep(number: 3, textKey: "connectionpool.invite.step3", textFallback: "They tap 'Join Pool' and find your pool")
                    InviteStep(number: 4, textKey: "connectionpool.invite.step4", textFallback: "Accept their join request")
                }

                Spacer()
            }
            .padding()
            .background(theme.background)
            .navigationTitle(poolString("connectionpool.actions.invitePeers", fallback: "Invite Peers"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(poolString("common.done", fallback: "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Invite Step

private struct InviteStep: View {
    let number: Int
    let textKey: String
    let textFallback: String

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingM) {
            Text("\(number)")
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(theme.textOnAccent)
                .frame(width: 24, height: 24)
                .background(theme.accent)
                .clipShape(Circle())

            PoolText(textKey, fallback: textFallback)
                .font(theme.fontBody)
                .foregroundColor(theme.textPrimary)
        }
    }
}

// MARK: - Blocked Devices Sheet

private struct BlockedDevicesSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            Group {
                if viewModel.blockedDevices.isEmpty {
                    VStack(spacing: theme.spacingL) {
                        Spacer()

                        PoolIcon("hand", size: 48, systemFallback: "hand.raised.slash")
                            .foregroundColor(theme.textTertiary)

                        PoolText("connectionpool.blocked.emptyTitle", fallback: "No Blocked Devices")
                            .font(theme.fontHeading)
                            .foregroundColor(theme.textPrimary)

                        PoolText("connectionpool.blocked.emptyMessage", fallback: "Devices that are blocked from joining your pool will appear here.")
                            .font(theme.fontBody)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                } else {
                    List {
                        ForEach(viewModel.blockedDevices) { device in
                            HStack(spacing: theme.spacingM) {
                                // Icon
                                ZStack {
                                    Circle()
                                        .fill(theme.warning.opacity(0.2))
                                        .frame(width: 40, height: 40)

                                    PoolIcon("hand", size: 15, systemFallback: "hand.raised.fill")
                                        .foregroundColor(theme.warning)
                                }

                                // Info
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.peerDisplayName)
                                        .font(theme.fontBody.weight(.semibold))
                                        .foregroundColor(theme.textPrimary)

                                    HStack(spacing: theme.spacingXS + 2) {
                                        Text(device.reason == .bruteForce
                                             ? poolString("connectionpool.blocked.auto", fallback: "Auto-blocked")
                                             : poolString("connectionpool.blocked.manual", fallback: "Manually blocked"))
                                            .font(theme.fontCaption)
                                            .foregroundColor(theme.textSecondary)

                                        Text(device.blockedAt, style: .relative)
                                            .font(theme.fontCaption)
                                            .foregroundColor(theme.textTertiary)
                                    }
                                }

                                Spacer()

                                // Unblock button
                                Button {
                                    viewModel.unblockDevice(device)
                                } label: {
                                    PoolText("connectionpool.blocked.unblock", fallback: "Unblock")
                                        .font(theme.fontCaption.weight(.bold))
                                        .foregroundColor(theme.textOnAccent)
                                        .padding(.horizontal, theme.spacingM)
                                        .padding(.vertical, theme.spacingXS + 2)
                                        .background(theme.success)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, theme.spacingXS)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(poolString("connectionpool.actions.blockedDevices", fallback: "Blocked Devices"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(poolString("common.done", fallback: "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Profile Button

private struct ProfileButton: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        Button {
            viewModel.startEditingProfile()
        } label: {
            HStack(spacing: theme.spacingS) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(viewModel.localProfile.avatarColor)
                        .frame(width: 36, height: 36)

                    Text(viewModel.localProfile.avatarEmoji)
                        .font(.system(size: 18))
                }

                // Name
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.localProfile.displayName)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)

                    PoolText("connectionpool.profile.edit", fallback: "Edit Profile")
                        .font(.caption2)
                        .foregroundColor(theme.textSecondary)
                }

                PoolIcon("chevron-right", size: 12, systemFallback: "chevron.right")
                    .foregroundColor(theme.textTertiary)
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)
            .background(theme.surface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile Settings Sheet

private struct ProfileSettingsSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            ScrollView {
                VStack(spacing: theme.spacingXL) {
                    // Avatar Preview
                    VStack(spacing: theme.spacingL) {
                        ZStack {
                            Circle()
                                .fill(PoolUserProfile.availableColors[viewModel.editingProfileColorIndex])
                                .frame(width: 100, height: 100)
                                .shadow(color: PoolUserProfile.availableColors[viewModel.editingProfileColorIndex].opacity(0.4), radius: 8, x: 0, y: 4)

                            Text(viewModel.editingProfileEmoji)
                                .font(.system(size: 50))
                        }

                        PoolText("connectionpool.profile.avatarLabel", fallback: "Your Pool Avatar")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.top, theme.spacingL + 4)

                    // Display Name
                    VStack(alignment: .leading, spacing: theme.spacingS) {
                        PoolText("connectionpool.profile.displayName", fallback: "Display Name")
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)

                        TextField(poolString("connectionpool.profile.namePlaceholder", fallback: "Enter your name"), text: $viewModel.editingProfileName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal)

                    // Avatar Emoji Picker
                    VStack(alignment: .leading, spacing: theme.spacingM) {
                        PoolText("connectionpool.profile.avatarEmoji", fallback: "Avatar Emoji")
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)
                            .padding(.horizontal)

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(PoolUserProfile.availableEmojis, id: \.self) { emoji in
                                Button {
                                    viewModel.editingProfileEmoji = emoji
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 28))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            Circle()
                                                .fill(viewModel.editingProfileEmoji == emoji ? theme.accent.opacity(0.2) : Color.clear)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(viewModel.editingProfileEmoji == emoji ? theme.accent : Color.clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Avatar Color Picker
                    VStack(alignment: .leading, spacing: theme.spacingM) {
                        PoolText("connectionpool.profile.avatarColor", fallback: "Avatar Color")
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)
                            .padding(.horizontal)

                        HStack(spacing: theme.spacingM) {
                            ForEach(0..<PoolUserProfile.availableColors.count, id: \.self) { index in
                                Button {
                                    viewModel.editingProfileColorIndex = index
                                } label: {
                                    Circle()
                                        .fill(PoolUserProfile.availableColors[index])
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(theme.surface, lineWidth: viewModel.editingProfileColorIndex == index ? 3 : 0)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(theme.textPrimary.opacity(0.3), lineWidth: viewModel.editingProfileColorIndex == index ? 1 : 0)
                                        )
                                        .shadow(color: viewModel.editingProfileColorIndex == index ? PoolUserProfile.availableColors[index].opacity(0.5) : Color.clear, radius: 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Info text
                    PoolText("connectionpool.profile.info", fallback: "Your profile will be visible to other pool members in chat and games.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .background(theme.background)
            .navigationTitle(poolString("connectionpool.profile.title", fallback: "Edit Profile"))
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel")) {
                        viewModel.cancelProfileEditing()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(poolString("common.save", fallback: "Save")) {
                        viewModel.saveProfile()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Remote Host Sheet

private struct RemoteHostSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var serverURLInput: String = ""
    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationView {
            Group {
                if viewModel.showClaimCodeInput {
                    RemoteHostClaimView(viewModel: viewModel, dismiss: dismiss)
                } else {
                    ScrollView {
                        VStack(spacing: theme.spacingXL) {
                            // Header
                            VStack(spacing: theme.spacingM) {
                                ZStack {
                                    Circle()
                                        .fill(theme.info.opacity(0.15))
                                        .frame(width: 80, height: 80)

                                    PoolIcon("server", size: 36, systemFallback: "server.rack")
                                        .foregroundColor(theme.info)
                                }

                                PoolText("connectionpool.remoteHost.title", fallback: "Host Remote Pool")
                                    .font(theme.fontHeading)
                                    .foregroundColor(theme.textPrimary)

                                PoolText("connectionpool.remoteHost.subtitle", fallback: "Create a pool that anyone can join via invitation link, from anywhere.")
                                    .font(theme.fontBody)
                                    .foregroundColor(theme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top)

                            // Server URL
                            VStack(alignment: .leading, spacing: theme.spacingS) {
                                PoolText("connectionpool.remoteHost.serverURL", fallback: "Server URL")
                                    .font(theme.fontBody.weight(.semibold))
                                    .foregroundColor(theme.textPrimary)

                                TextField("10.0.0.4:9090 or relay.example.com", text: $serverURLInput)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .crossPlatformTextField()

                                PoolText("connectionpool.remoteHost.serverURLHint", fallback: "IP:port for local, domain for internet (via cloudflared)")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.textSecondary)
                            }

                            // Pool Name
                            VStack(alignment: .leading, spacing: theme.spacingS) {
                                PoolText("connectionpool.setup.poolName", fallback: "Pool Name")
                                    .font(theme.fontBody.weight(.semibold))
                                    .foregroundColor(theme.textPrimary)

                                TextField(poolString("connectionpool.setup.poolNamePlaceholder", fallback: "Enter pool name"), text: $viewModel.poolName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            // Max Members
                            VStack(alignment: .leading, spacing: theme.spacingS) {
                                PoolText("connectionpool.remoteHost.maxMembers", fallback: "Max Members")
                                    .font(theme.fontBody.weight(.semibold))
                                    .foregroundColor(theme.textPrimary)

                                Picker(poolString("connectionpool.remoteHost.maxMembers", fallback: "Max Members"), selection: $viewModel.maxPeers) {
                                    ForEach([2, 4, 6, 8, 10, 12, 16], id: \.self) { count in
                                        Text(poolString("connectionpool.remoteHost.membersCount", fallback: "\(count) members", args: ["count": "\(count)"])).tag(count)
                                    }
                                }
                                .pickerStyle(.segmented)

                                PoolText("connectionpool.remoteHost.maxMembersHint", fallback: "Maximum number of peers that can join this pool")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.textSecondary)
                            }

                            Spacer(minLength: 20)

                            // Create Button
                            Button {
                                viewModel.createRemotePool(serverURL: serverURLInput)
                            } label: {
                                HStack(spacing: theme.spacingS) {
                                    if viewModel.isConnectingRemote {
                                        ProgressView()
                                            .tint(theme.textOnAccent)
                                    } else {
                                        PoolIcon("tower-broadcast", size: 16, systemFallback: "antenna.radiowaves.left.and.right")
                                    }
                                    Text(viewModel.isConnectingRemote
                                         ? poolString("connectionpool.status.connecting", fallback: "Connecting…")
                                         : poolString("connectionpool.remoteHost.create", fallback: "Create Remote Pool"))
                                }
                                .font(theme.fontBody.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(serverURLInput.isEmpty || viewModel.isConnectingRemote ? theme.textTertiary : theme.info)
                                .foregroundStyle(theme.textOnAccent)
                                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                            }
                            .disabled(serverURLInput.isEmpty || viewModel.isConnectingRemote)
                        }
                        .padding()
                    }
                    .background(theme.background)
                    .navigationTitle("")
                    .crossPlatformInlineNavigationTitle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel")) {
                        viewModel.showClaimCodeInput = false
                        viewModel.isClaimingServer = false
                        viewModel.serverClaimed = false
                        viewModel.claimCode = ""
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showRecoveryKeySheet) {
                RecoveryKeySheet(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Remote Host Claim View (Step 2)

private struct RemoteHostClaimView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    let dismiss: DismissAction
    @State private var showQRScanner: Bool = false

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        ScrollView {
            VStack(spacing: theme.spacingXL) {
                // Header
                VStack(spacing: theme.spacingM) {
                    PoolIcon("shield-halved", size: 50, systemFallback: "lock.shield")
                        .foregroundColor(theme.warning)

                    PoolText("connectionpool.claim.title", fallback: "Server Claim Required")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    PoolText("connectionpool.claim.subtitle", fallback: "Scan the QR code or enter the claim code from your server's Docker logs.")
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // QR Scanner Button
                #if os(iOS)
                Button {
                    showQRScanner = true
                } label: {
                    HStack(spacing: theme.spacingM) {
                        PoolIcon("qrcode", size: 24, systemFallback: "qrcode.viewfinder")
                        VStack(alignment: .leading, spacing: 2) {
                            PoolText("connectionpool.claim.scanTitle", fallback: "Scan QR Code")
                                .font(theme.fontBody.weight(.semibold))
                            PoolText("connectionpool.claim.scanDesc", fallback: "Point camera at your server's terminal")
                                .font(theme.fontCaption)
                                .foregroundColor(theme.warning.opacity(0.8))
                        }
                        Spacer()
                        PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                            .foregroundColor(theme.warning.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .background(theme.warning.opacity(0.12))
                .foregroundColor(theme.warning)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                .padding(.horizontal)
                #endif

                // Divider
                HStack {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                    PoolText("connectionpool.claim.orManual", fallback: "or enter manually")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                }
                .padding(.horizontal)

                // Manual Entry
                VStack(spacing: theme.spacingL) {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $viewModel.claimCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif

                    Button(action: { viewModel.submitClaimCode() }) {
                        if viewModel.isClaimingServer {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("key", size: 16, systemFallback: "key.fill")
                                PoolText("connectionpool.claim.claimServer", fallback: "Claim Server")
                            }
                            .font(theme.fontBody.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                    }
                    .background(viewModel.claimCode.isEmpty || viewModel.isClaimingServer ? theme.textTertiary : theme.warning)
                    .foregroundStyle(theme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    .disabled(viewModel.claimCode.isEmpty || viewModel.isClaimingServer)
                }
                .padding(.horizontal)

                // Server claimed confirmation
                if viewModel.serverClaimed {
                    HStack(spacing: theme.spacingS) {
                        PoolIcon("badge-check", size: 15, systemFallback: "checkmark.seal.fill")
                            .foregroundColor(theme.success)
                        PoolText("connectionpool.claim.success", fallback: "Server claimed successfully")
                            .font(theme.fontBody)
                            .foregroundColor(theme.success)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(theme.success.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    .padding(.horizontal)
                }
            }
        }
        .background(theme.background)
        .navigationTitle(poolString("connectionpool.claim.navTitle", fallback: "Claim Server"))
        .crossPlatformInlineNavigationTitle()
        .navigationBarBackButtonHidden(viewModel.isClaimingServer)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.isClaimingServer {
                    EmptyView()
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            ClaimScannerSheet(
                scannedCode: $viewModel.claimCode,
                isPresented: $showQRScanner,
                onScanned: {
                    viewModel.handleClaimDeepLink(viewModel.claimCode)
                }
            )
        }
    }
}

// MARK: - Recovery Key Sheet

private struct RecoveryKeySheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @State private var hasCopied = false
    @State private var isSavingToPasswordManager = false

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    private var hasSaved: Bool {
        hasCopied || viewModel.recoveryKeySavedToPasswordManager
    }

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationView {
            VStack(spacing: theme.spacingXL) {
                PoolIcon("key", size: 50, systemFallback: "key.fill")
                    .foregroundColor(theme.warning)

                PoolText("connectionpool.recovery.title", fallback: "Save Your Recovery Key")
                    .font(theme.fontHeading)
                    .foregroundColor(theme.textPrimary)

                PoolText("connectionpool.recovery.subtitle", fallback: "This key is the only way to reclaim your server if the binding is lost. It will not be shown again.")
                    .font(theme.fontBody)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let key = viewModel.serverRecoveryKey {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        .textSelection(.enabled)
                        .padding(.horizontal)

                    // Save to Password Manager
                    if viewModel.onSaveToPasswordManager != nil {
                        Button {
                            isSavingToPasswordManager = true
                            Task {
                                let serverURL = viewModel.serverURL
                                let saved = await viewModel.onSaveToPasswordManager?(
                                    "StealthRelay Recovery Key",
                                    key,
                                    serverURL
                                ) ?? false
                                isSavingToPasswordManager = false
                                if saved {
                                    viewModel.recoveryKeySavedToPasswordManager = true
                                }
                            }
                        } label: {
                            HStack(spacing: theme.spacingS) {
                                if isSavingToPasswordManager {
                                    ProgressView()
                                        .tint(theme.textOnAccent)
                                } else {
                                    PoolIcon(viewModel.recoveryKeySavedToPasswordManager ? "shield-check" : "shield-halved",
                                             size: 16,
                                             systemFallback: viewModel.recoveryKeySavedToPasswordManager ? "checkmark.shield.fill" : "lock.shield")
                                    Text(viewModel.recoveryKeySavedToPasswordManager
                                         ? poolString("connectionpool.recovery.savedToPM", fallback: "Saved to Password Manager")
                                         : poolString("connectionpool.recovery.saveToPM", fallback: "Save to Password Manager"))
                                }
                            }
                            .font(theme.fontBody.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .background(viewModel.recoveryKeySavedToPasswordManager ? theme.success : theme.warning)
                        .foregroundStyle(theme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        .disabled(isSavingToPasswordManager || viewModel.recoveryKeySavedToPasswordManager)
                        .padding(.horizontal)
                    }

                    // Copy to Clipboard
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = key
                        #endif
                        hasCopied = true
                    } label: {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon(hasCopied ? "check" : "copy", size: 16, systemFallback: hasCopied ? "checkmark" : "doc.on.doc")
                            Text(hasCopied
                                 ? poolString("connectionpool.recovery.copied", fallback: "Copied")
                                 : poolString("connectionpool.recovery.copy", fallback: "Copy to Clipboard"))
                        }
                        .font(theme.fontBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .background(theme.warning.opacity(0.15))
                    .foregroundColor(theme.warning)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    .padding(.horizontal)
                }

                Spacer()

                Button {
                    viewModel.acknowledgeRecoveryKey()
                } label: {
                    PoolText("connectionpool.recovery.acknowledge", fallback: "I've Saved My Recovery Key")
                        .font(theme.fontBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .background(hasSaved ? theme.warning : theme.textTertiary)
                .foregroundStyle(theme.textOnAccent)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                .disabled(!hasSaved)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top, 30)
            .background(theme.background)
            .crossPlatformInlineNavigationTitle()
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Remote Join Sheet

private struct RemoteJoinSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReceiveInvitationView(viewModel: viewModel)
    }
}

// MARK: - Saved Member Pools Section

/// Home-screen list of remote pools the user is already a member of. Each row
/// maps to a saved ``RemoteMemberRecord`` and exposes:
///   - Tap: invokes ``ConnectionPoolViewModel/rejoinRemotePool(_:)``, skipping
///     the invitation flow by reusing the persisted Ed25519 identity.
///   - Trash: invokes ``ConnectionPoolViewModel/forgetRemoteMemberPool(_:)``,
///     deleting the Keychain identity and the saved record. After forgetting
///     the user must obtain a new invitation to join again.
private struct SavedMemberPoolsSection: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme
    @State private var pendingForget: RemoteMemberRecord?

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(spacing: theme.spacingS) {
            HStack {
                PoolText("connectionpool.savedPools.title", fallback: "Your Pools")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
                Spacer()
            }
            ForEach(viewModel.savedRemoteMemberPools, id: \.compositeKey) { record in
                SavedMemberPoolRow(
                    record: record,
                    onRejoin: { viewModel.rejoinRemotePool(record) },
                    onForget: { pendingForget = record }
                )
            }
        }
        .alert(
            poolString("connectionpool.savedPools.forgetTitle", fallback: "Forget this pool?"),
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { record in
            Button(poolString("connectionpool.savedPools.forget", fallback: "Forget"), role: .destructive) {
                viewModel.forgetRemoteMemberPool(record)
                pendingForget = nil
            }
            Button(poolString("common.cancel", fallback: "Cancel"), role: .cancel) {
                pendingForget = nil
            }
        } message: { _ in
            Text(poolString("connectionpool.leave.message", fallback: "You'll need a new invitation to join again."))
        }
    }
}

private struct SavedMemberPoolRow: View {
    let record: RemoteMemberRecord
    let onRejoin: () -> Void
    let onForget: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        HStack(spacing: theme.spacingS + 2) {
            Button(action: onRejoin) {
                HStack(spacing: theme.spacingM) {
                    PoolIcon("arrows-rotate", size: 18, systemFallback: "arrow.clockwise.circle.fill")
                        .foregroundColor(theme.info)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName.isEmpty ? poolString("connectionpool.savedPools.remotePool", fallback: "Remote Pool") : record.displayName)
                            .font(theme.fontBody.weight(.semibold))
                            .foregroundColor(theme.textPrimary)
                        Text(record.serverURL)
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let last = record.lastSuccessfulConnectAt {
                            Text(poolString("connectionpool.savedPools.lastConnected", fallback: "Last connected \(last.formatted(.relative(presentation: .named))) ago", args: ["time": last.formatted(.relative(presentation: .named))]))
                                .font(.caption2)
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                    Spacer()
                    PoolIcon("chevron-right", size: 13, systemFallback: "chevron.right")
                        .foregroundColor(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onForget) {
                PoolIcon("trash", size: 15, systemFallback: "trash")
                    .foregroundColor(theme.danger)
                    .padding(theme.spacingS)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(theme.info.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}

// MARK: - Invitation Share Sheet (replaced by InviteCardShareSheet)
// The PIN-driven invite-card flow lives in InviteCardShareSheet.swift.

// MARK: - Remote Invitations Card

private struct RemoteInvitationsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: theme.spacingS + 2) {
            HStack {
                PoolIcon("link", size: 15, systemFallback: "link")
                    .foregroundColor(theme.info)
                PoolText("connectionpool.invitations.title", fallback: "Active Invitations")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("\(viewModel.remoteInvitations.filter { !$0.isExpired }.count)")
                    .font(theme.fontCaption.weight(.bold))
                    .foregroundColor(theme.textOnAccent)
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS)
                    .background(theme.info)
                    .clipShape(Capsule())
            }

            ForEach(viewModel.remoteInvitations) { invitation in
                HStack(spacing: theme.spacingS + 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.tokenId.prefix(8) + "...")
                            .font(.caption.monospaced())
                            .foregroundColor(theme.textPrimary)

                        if invitation.isExpired {
                            PoolText("connectionpool.invitations.expired", fallback: "Expired")
                                .font(.caption2)
                                .foregroundColor(theme.danger)
                        } else {
                            Text(poolString("connectionpool.invitations.expires", fallback: "Expires \(invitation.expiresAt.formatted(.relative(presentation: .named)))", args: ["time": invitation.expiresAt.formatted(.relative(presentation: .named))]))
                                .font(.caption2)
                                .foregroundColor(theme.textSecondary)
                        }
                    }

                    Spacer()

                    if !invitation.isExpired {
                        Button {
                            viewModel.shareInvitation(invitation)
                        } label: {
                            PoolIcon("share", size: 15, systemFallback: "square.and.arrow.up")
                                .foregroundColor(theme.info)
                                .padding(theme.spacingS)
                                .background(theme.info.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }

                    Button {
                        viewModel.remoteInvitations.removeAll { $0.id == invitation.id }
                    } label: {
                        PoolIcon("xmark", size: 11, systemFallback: "xmark")
                            .foregroundColor(theme.textSecondary)
                            .padding(theme.spacingXS + 2)
                            .background(theme.surfaceSecondary)
                            .clipShape(Circle())
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(theme.info.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }
}
